import AppKit
import LoveployCore
import SwiftUI
import WebKit

// Loveploy: your own Chrome, with your sign-in. Lists the claude.ai pages open in Chrome (tabs and
// installed Chrome apps), and places a group's Chrome windows over their panes, through
// AppleScript (macOS asks once for permission to control Chrome).

enum ChromeError: Error, LocalizedError {
    case notRunning
    case notAllowed
    case javaScriptOff
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Chrome no está abierto."
        case .notAllowed:
            return "Blender Play no tiene permiso para controlar Chrome. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización → Blender Play → Google Chrome."
        case .javaScriptOff:
            return "Para leer la lista de sesiones desde Chrome, en Chrome activa Ver → Desarrollador → Permitir JavaScript desde eventos de Apple."
        case let .failed(message): return message
        }
    }
}

enum ChromeBridge {
    static let bundleID = "com.google.Chrome"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Runs AppleScript with osascript, off the main thread.
    static func run(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if errors.contains("-1743") { throw ChromeError.notAllowed }
                if errors.lowercased().contains("javascript") { throw ChromeError.javaScriptOff }
                throw ChromeError.failed(errors.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Every tab of every Chrome window, installed apps included. Doesn't open Chrome.
    static func tabs() async throws -> [ChromeTab] {
        guard isRunning else { throw ChromeError.notRunning }
        let script = """
        set T to ASCII character 9
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                set wid to id of w
                set i to 0
                repeat with x in tabs of w
                    set i to i + 1
                    set out to out & wid & T & i & T & (URL of x) & T & (title of x) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        return ChromeTab.parse(try await run(script))
    }

    /// The address in the front Chrome window.
    static func frontURL() async throws -> String {
        guard isRunning else { throw ChromeError.notRunning }
        return try await run("tell application id \"\(bundleID)\" to return URL of active tab of front window")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude Code sessions listed on a claude.ai/code tab, read from the page (needs Chrome's
    /// "Allow JavaScript from Apple Events").
    static func listedSessions(in tab: ChromeTab) async throws -> [(url: String, title: String)] {
        let js = SessionScraper.script
        let script = """
        tell application id "\(bundleID)"
            return execute (tab \(tab.tabIndex) of window id \(tab.windowID)) javascript \(quote(js))
        end tell
        """
        return SessionScraper.parse(try await run(script))
    }

    /// Moves each page's Chrome window to its rectangle (screen coordinates, AppKit origin),
    /// opening a new Chrome window for pages that aren't open, and brings them to the front.
    static func place(_ items: [(url: String, rect: NSRect)]) async throws {
        guard !items.isEmpty else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var lines: [String] = []
        // Last placed ends up on top, so go backwards: the first pane wins any overlap.
        for item in items.reversed() {
            guard let url = ClaudeLink.url(item.url) else { continue }
            let base = "https://\(url.host ?? "claude.ai")\(url.path)"
            let r = item.rect
            let bounds = "{\(Int(r.minX)), \(Int(top - r.maxY)), \(Int(r.maxX)), \(Int(top - r.minY))}"
            lines.append("my placePage(\(quote(base)), \(quote(item.url)), \(bounds))")
        }
        let script = """
        on placePage(base, full, b)
            tell application id "\(bundleID)"
                repeat with w in windows
                    set i to 0
                    repeat with x in tabs of w
                        set i to i + 1
                        if (URL of x) starts with base then
                            set active tab index of w to i
                            set bounds of w to b
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
                set w to make new window
                set URL of active tab of w to full
                set bounds of w to b
            end tell
        end placePage
        \(lines.joined(separator: "\n"))
        """
        _ = try await run(script)
        await MainActor.run { bringForward() }
    }

    /// Chrome, and installed Claude apps (their windows belong to a small app of their own).
    @MainActor
    static func bringForward() {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return id == bundleID || (id.hasPrefix(bundleID + ".app.") && (app.localizedName ?? "").localizedCaseInsensitiveContains("claude"))
        }
        // The installed apps first, then Chrome itself (with all its windows, so every placed
        // window comes over the group's window, not only the last one).
        for app in apps where app.bundleIdentifier != bundleID { app.activate(options: []) }
        for app in apps where app.bundleIdentifier == bundleID { app.activate(options: [.activateAllWindows]) }
    }
}

/// Reads the Claude Code sessions a claude.ai/code page lists.
enum SessionScraper {
    static let script = """
    (function () {
      var seen = {}, out = [];
      document.querySelectorAll('a[href*="/code/session_"]').forEach(function (a) {
        var href = a.href.split('?')[0].split('#')[0];
        if (seen[href]) return;
        seen[href] = 1;
        out.push({ url: href, title: (a.innerText || a.getAttribute('aria-label') || '').trim().split('\\n')[0] });
      });
      return JSON.stringify(out);
    })()
    """

    static func parse(_ text: String) -> [(url: String, title: String)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { item in
            guard let url = item["url"], ClaudeLink.isCodeSession(url) else { return nil }
            return (url, ClaudeLink.cleanTitle(item["title"] ?? ""))
        }
    }
}

/// Loads claude.ai/code out of sight with an account's sign-in (the same one its panes use)
/// and reads the sessions the page lists.
@MainActor
final class CloudSessionLister: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<[(url: String, title: String)], Never>?
    private var tries = 0

    func sessions(account: String?) async -> [(url: String, title: String)] {
        let configuration = WKWebViewConfiguration()
        if let id = account.flatMap(UUID.init(uuidString:)) {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        web.customUserAgent = LovableWeb.userAgent
        web.navigationDelegate = self
        self.web = web
        web.load(URLRequest(url: URL(string: "https://claude.ai/code")!))
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish([]) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        poll()
    }

    private func poll() {
        guard let web, continuation != nil else { return }
        // A redirect to the sign-in page means this account isn't signed in here.
        if web.url?.path.contains("login") == true { finish([]); return }
        web.evaluateJavaScript(SessionScraper.script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let found = SessionScraper.parse(result as? String ?? "")
                self.tries += 1
                if !found.isEmpty || self.tries > 12 {
                    self.finish(found)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.poll() }
                }
            }
        }
    }

    private func finish(_ found: [(url: String, title: String)]) {
        continuation?.resume(returning: found)
        continuation = nil
        web?.stopLoading()
        web = nil
    }
}

/// Where each Chrome pane sits on screen, so its Chrome window can be put on top of it.
@MainActor
final class ChromePlacer {
    static let shared = ChromePlacer()
    private var anchors: [UUID: WeakView] = [:]
    final class WeakView { weak var view: NSView? ; init(_ view: NSView) { self.view = view } }

    func register(_ view: NSView, pane: UUID) { anchors[pane] = WeakView(view) }

    func rect(for pane: UUID) -> NSRect? {
        guard let view = anchors[pane]?.view, let window = view.window, window.isVisible, !window.isMiniaturized else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Puts the group's Chrome windows over their panes. Returns an error to show, if any.
    @discardableResult
    func arrange(_ groupID: UUID) async -> String? {
        guard let group = SessionGroups.shared.group(groupID) else { return nil }
        let items = group.panes.filter { $0.kind == .chrome }.compactMap { pane -> (url: String, rect: NSRect)? in
            guard let url = pane.url, let rect = rect(for: pane.id) else { return nil }
            return (url, rect)
        }
        guard !items.isEmpty else { return nil }
        do {
            try await ChromeBridge.place(items)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// An empty view that tells ChromePlacer where a Chrome pane is.
struct ChromeAnchor: NSViewRepresentable {
    let paneID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ChromePlacer.shared.register(view, pane: paneID)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        ChromePlacer.shared.register(view, pane: paneID)
    }
}

/// What a Chrome pane shows under its Chrome window.
struct ChromePaneView: View {
    let pane: SessionPane
    let groupID: UUID
    @State private var error: String?

    var body: some View {
        ZStack {
            ChromeAnchor(paneID: pane.id)
            VStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("En tu Chrome").font(.headline)
                Text(pane.url ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Traer Chrome aquí") {
                    Task { error = await ChromePlacer.shared.arrange(groupID) }
                }
                .buttonStyle(.borderedProminent)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 320)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
