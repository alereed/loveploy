import AVFoundation
import AppKit
import LoveployCore
import Speech
import SwiftTerm
import SwiftUI
import WebKit

// Loveploy: dictation in every pane, like the Claude app's microphone. Speech is transcribed on
// the Mac (Apple's speech recognition, on-device when the Mac supports it) and the text goes
// where you were typing: the claude.ai message box or the Claude Code terminal.

@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    /// The pane being dictated into.
    @Published private(set) var pane: UUID?
    /// What's been heard so far.
    @Published private(set) var heard = ""

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private weak var target: NSView?
    private var finishing = false
    /// Press Enter (send the message) after typing the text.
    private var send = false

    /// Dictation into whatever app is in front (the macro pad's knob, ⌃⌥⌘D).
    static let anywhere = UUID()

    func toggle(pane: UUID, view: NSView?, send: Bool = false) {
        if self.pane == pane { stop(); return }
        if self.pane != nil { cancel() }
        guard view != nil || pane == Self.anywhere else { return }
        Task { await start(pane: pane, view: view, send: send) }
    }

    /// ⌃⌥⌘D: the first press starts listening, the second types the text and sends it. Into the
    /// group pane you're typing in, or into whatever app is in front.
    func hotKey() {
        if pane != nil { stop(); return }
        if let found = SessionGroups.shared.focusedPane() {
            toggle(pane: found.0, view: found.1, send: true)
        } else {
            toggle(pane: Self.anywhere, view: nil, send: true)
        }
    }

    /// ⌃⌥⌘Q: queue instead of send. While dictating, the dictated text goes to the pane's
    /// queue; otherwise what's typed in claude.ai's box is moved to the queue.
    private var toQueue = false

    func queueHotKey() {
        if pane != nil, pane != Self.anywhere {
            toQueue = true
            stop()
            return
        }
        guard let found = SessionGroups.shared.focusedPane(), let web = found.1 as? WKWebView else { NSSound.beep(); return }
        let pane = found.0
        web.evaluateJavaScript(Self.takeComposerText) { result, _ in
            MainActor.assumeIsolated {
                guard let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
                MessageQueues.shared.add(text, to: pane)
            }
        }
    }

    /// Takes the text out of claude.ai's message box (and empties it).
    static let takeComposerText = """
    (function () {
      var el = document.activeElement;
      if (!(el && (el.isContentEditable || el.tagName === 'TEXTAREA'))) {
        var all = document.querySelectorAll('[contenteditable="true"], textarea');
        el = all[all.length - 1];
      }
      if (!el) return '';
      var text = el.tagName === 'TEXTAREA' ? el.value : el.innerText;
      el.focus();
      document.execCommand('selectAll', false, null);
      document.execCommand('delete', false, null);
      return text;
    })()
    """

    private func start(pane: UUID, view: NSView?, send: Bool) async {
        guard await Self.allowed() else {
            Self.tell("Permite el micrófono y el reconocimiento de voz a Blender Play en Ajustes del Sistema → Privacidad y seguridad.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-MX")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            Self.tell("El reconocimiento de voz no está disponible ahora. Revisa que Dictado esté activado en Ajustes del Sistema → Teclado.")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let feed = feed
        // nil format: the tap takes the microphone's own format (an AirPods or USB mic with
        // another sample rate made a fixed format fail).
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            feed.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Self.tell("No se pudo abrir el micrófono: \(error.localizedDescription)")
            return
        }
        self.recognizer = recognizer
        self.engine = engine
        self.target = view
        self.pane = pane
        self.send = send
        committed = ""
        segment = ""
        heard = ""
        restarts = 0
        finishing = false
        startSegment()
    }

    // Apple's recognizer ends a request after about a minute or a long pause; dictation keeps
    // going by chaining requests and joining their text, so it doesn't stop on its own.
    private var recognizer: SFSpeechRecognizer?
    private let feed = AudioFeed()
    private var committed = ""
    private var segment = ""
    private var generation = 0
    private var restarts = 0

    private func startSegment() {
        guard let recognizer else { return }
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Apple's servers when there's a connection (better Spanish); on the Mac otherwise.
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        feed.set(request)
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Dictation.shared.segmentUpdate(current, text: text, final: final, failed: failed) }
            }
        }
    }

    private func segmentUpdate(_ id: Int, text: String?, final: Bool, failed: Bool) {
        guard id == generation, pane != nil else { return }
        if let text { segment = text }
        heard = [committed, segment].filter { !$0.isEmpty }.joined(separator: " ")
        guard final || failed else { return }
        if !segment.isEmpty { committed = heard }
        segment = ""
        if finishing {
            deliver()
        } else if restarts < 40 {
            restarts += 1
            startSegment()
        } else {
            stop()
        }
    }

    /// Stops listening; the text goes in once the last words are recognized.
    func stop() {
        guard pane != nil, !finishing else { return }
        finishing = true
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // If the recognizer never sends a final result, use what was heard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.deliver() }
    }

    func cancel() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        reset()
    }

    private func deliver() {
        guard pane != nil else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, toQueue, let pane, pane != Self.anywhere {
            MessageQueues.shared.add(text, to: pane)
        } else if !text.isEmpty {
            if let target {
                let send = self.send
                Self.insert(text, into: target) { if send { Self.submit(target) } }
            } else if pane == Self.anywhere {
                Self.paste(text, pressReturn: send)
            }
        }
        task?.cancel()
        reset()
    }

    private func reset() {
        feed.set(nil)
        recognizer = nil
        committed = ""
        segment = ""
        generation += 1
        engine = nil
        request = nil
        task = nil
        target = nil
        pane = nil
        heard = ""
        finishing = false
        send = false
        toQueue = false
    }

    /// Sends the message: Enter in the terminal, the send button on claude.ai.
    static func submit(_ view: NSView) {
        if let terminal = view as? TerminalView {
            terminal.send(txt: "\r")
        } else if let web = view as? WKWebView {
            web.evaluateJavaScript("""
            (function () {
              var b = document.querySelector('button[aria-label*="Send" i], button[aria-label*="Enviar" i], button[type="submit"]');
              if (b && !b.disabled) { b.click(); return true; }
              var el = document.activeElement;
              if (el) ['keydown', 'keypress', 'keyup'].forEach(function (t) {
                el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
              });
              return false;
            })()
            """)
        }
    }

    /// Into another app: through the clipboard and ⌘V (then Return), which needs Accessibility.
    /// The clipboard gets its text back afterwards.
    static func paste(_ text: String, pressReturn: Bool) {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            tell("Para escribir lo dictado en otras apps, activa Blender Play en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad.")
            return
        }
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        key(9, .maskCommand)   // V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if pressReturn { key(36) }   // Return
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                board.clearContents()
                if let saved { board.setString(saved, forType: .string) }
            }
        }
    }

    /// Types the text where the pane's cursor is (claude.ai's message box, or the terminal).
    /// On claude.ai it's pasted like ⌘V (the page takes a paste the same way as typing), into
    /// the message box with the cursor at the end unless you were already typing in it.
    static func insert(_ text: String, into view: NSView, then: (() -> Void)? = nil) {
        if let terminal = view as? TerminalView {
            terminal.send(txt: text)
            terminal.window?.makeFirstResponder(terminal)
            then?()
        } else if let web = view as? WKWebView {
            web.window?.makeFirstResponder(web)
            web.evaluateJavaScript(focusComposer) { _, _ in
                MainActor.assumeIsolated {
                    paste(text, into: web)
                    if let then { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then) }
                }
            }
        }
    }

    /// Puts the cursor in claude.ai's message box: the field you were in, or else the visible
    /// box lowest on the page, with the cursor at its end.
    static let focusComposer = """
    (function () {
      var visible = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      var field = function (e) { return e && (e.isContentEditable || e.tagName === 'TEXTAREA') && visible(e); };
      var el = document.activeElement;
      if (field(el)) return true;
      var all = Array.prototype.slice.call(document.querySelectorAll('[contenteditable="true"], textarea')).filter(visible);
      all.sort(function (a, b) { return b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom; });
      el = all[0];
      if (!el) return false;
      el.focus();
      if (el.tagName === 'TEXTAREA') {
        el.setSelectionRange(el.value.length, el.value.length);
      } else {
        var range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(false);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
      return true;
    })()
    """

    /// ⌘V into the web view, then the clipboard gets its text back.
    static func paste(_ text: String, into web: WKWebView) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: web, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
        }
    }

    static func tell(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Dictado"
        alert.informativeText = message
        alert.runModal()
    }

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Hands the microphone's audio to whichever recognition request is current (the tap runs on
/// an audio thread while requests are swapped on the main one).
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
}

/// claude.ai's own dictation button relies on Chrome's speech service, which a web pane doesn't
/// have, so it fails. This takes over that button in web panes: a click runs the Mac's
/// dictation (the same as the header's microphone) instead. Voice mode is left alone.
final class ClaudeMicBridge: NSObject, WKScriptMessageHandler {
    static let name = "blenderPlayDictate"
    static let script = """
    (function () {
      var dictation = /dictat|dictar|dictado|micr[oó]fono|microphone|speech|voz a texto|speak/i;
      var voiceMode = /voice mode|modo de voz|conversaci/i;
      addEventListener('click', function (e) {
        var b = e.target.closest && e.target.closest('button');
        if (!b) return;
        var label = (b.getAttribute('aria-label') || '') + ' ' + (b.title || '') + ' ' + (b.getAttribute('data-testid') || '');
        if (!dictation.test(label) || voiceMode.test(label)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        try { window.webkit.messageHandlers.\(ClaudeMicBridge.name).postMessage(1); } catch (err) {}
      }, true);
    })();
    """

    let pane: UUID
    weak var web: WKWebView?

    init(pane: UUID) { self.pane = pane }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let pane = pane
        let web = web
        MainActor.assumeIsolated { Dictation.shared.toggle(pane: pane, view: web) }
    }

    static func install(in configuration: WKWebViewConfiguration, pane: UUID) -> ClaudeMicBridge {
        let bridge = ClaudeMicBridge(pane: pane)
        configuration.userContentController.add(bridge, name: name)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return bridge
    }
}

/// The microphone button in a pane's header.
struct DictationButton: View {
    let pane: SessionPane
    @ObservedObject var hosts: PaneHosts
    @ObservedObject private var dictation = Dictation.shared

    var body: some View {
        let active = dictation.pane == pane.id
        Button {
            dictation.toggle(pane: pane.id, view: hosts.existingView(pane.id))
        } label: {
            HStack(spacing: 3) {
                Image(systemName: active ? "mic.fill" : "mic")
                    .foregroundStyle(active ? Color.red : Color.primary)
                if active {
                    Text(dictation.heard.isEmpty ? "Escuchando…" : String(dictation.heard.suffix(40)))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
        }
        .focusable(false)
        .help(active ? "Clic para terminar: el texto se escribe donde estabas" : "Dictar: habla y el texto se escribe donde estás escribiendo")
    }
}

