import AVFoundation
import AppKit
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

    func toggle(pane: UUID, view: NSView?) {
        if self.pane == pane { stop(); return }
        if self.pane != nil { cancel() }
        guard let view else { return }
        Task { await start(pane: pane, view: view) }
    }

    private func start(pane: UUID, view: NSView) async {
        guard await Self.allowed() else {
            Self.tell("Permite el micrófono y el reconocimiento de voz a Loveploy en Ajustes del Sistema → Privacidad y seguridad.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-MX")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            Self.tell("El reconocimiento de voz no está disponible ahora. Revisa que Dictado esté activado en Ajustes del Sistema → Teclado.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Self.tell("No se pudo abrir el micrófono: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        self.engine = engine
        self.request = request
        self.target = view
        self.pane = pane
        heard = ""
        finishing = false
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let dictation = Dictation.shared
                    if let text { dictation.heard = text }
                    if final || (error != nil && dictation.finishing) { dictation.deliver() }
                }
            }
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
        if !text.isEmpty, let target { Self.insert(text, into: target) }
        task?.cancel()
        reset()
    }

    private func reset() {
        engine = nil
        request = nil
        task = nil
        target = nil
        pane = nil
        heard = ""
        finishing = false
    }

    /// Types the text where the pane's cursor is (claude.ai's message box, or the terminal).
    static func insert(_ text: String, into view: NSView) {
        if let terminal = view as? TerminalView {
            terminal.send(txt: text)
            terminal.window?.makeFirstResponder(terminal)
        } else if let web = view as? WKWebView {
            let literal = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let js = """
            (function (t) {
              var el = document.activeElement;
              var editable = function (e) { return e && (e.isContentEditable || e.tagName === 'TEXTAREA' || (e.tagName === 'INPUT' && /text|search/.test(e.type))); };
              if (!editable(el)) {
                var all = document.querySelectorAll('[contenteditable="true"], textarea');
                el = all[all.length - 1];
              }
              if (!el) return false;
              el.focus();
              if (!document.execCommand('insertText', false, t)) {
                if ('value' in el) { el.value += t; el.dispatchEvent(new Event('input', { bubbles: true })); }
                else { el.textContent += t; el.dispatchEvent(new InputEvent('input', { bubbles: true })); }
              }
              return true;
            })(\(literal)[0])
            """
            web.window?.makeFirstResponder(web)
            web.evaluateJavaScript(js)
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
        .help(active ? "Clic para terminar: el texto se escribe donde estabas" : "Dictar: habla y el texto se escribe donde estás escribiendo")
    }
}

