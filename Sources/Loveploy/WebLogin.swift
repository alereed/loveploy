import AppKit
import LoveployCore
import WebKit

/// Signing in happens on lovable.dev itself, inside a browser window. Once the page
/// has a Firebase session, Loveploy reads it from the page's storage (the same place
/// the Lovable web app keeps it) and closes the window.
enum LovableWeb {
    static let loginURL = URL(string: "https://lovable.dev/login")!
    static let dashboardURL = URL(string: "https://lovable.dev/dashboard")!
    /// Google refuses to sign in inside apps that don't look like a browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Reads the Firebase user lovable.dev saved in IndexedDB. Never creates the database.
    static let readCredentialsScript = """
    return await new Promise((resolve) => {
      let request;
      try { request = indexedDB.open('firebaseLocalStorageDb'); } catch (e) { resolve(null); return; }
      request.onupgradeneeded = () => { request.transaction.abort(); };
      request.onerror = () => resolve(null);
      request.onsuccess = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains('firebaseLocalStorage')) { db.close(); resolve(null); return; }
        const all = db.transaction('firebaseLocalStorage', 'readonly').objectStore('firebaseLocalStorage').getAll();
        all.onerror = () => { db.close(); resolve(null); };
        all.onsuccess = () => {
          db.close();
          const row = (all.result || []).find(r => String(r.fbase_key || '').startsWith('firebase:authUser:'));
          const user = row && row.value;
          const tokens = user && user.stsTokenManager;
          if (!tokens || !tokens.refreshToken) { resolve(null); return; }
          resolve(JSON.stringify({
            refreshToken: tokens.refreshToken,
            idToken: tokens.accessToken || null,
            expiresAt: tokens.expirationTime || null,
            email: user.email || null,
            uid: user.uid || null
          }));
        };
      };
    });
    """

    @MainActor
    static func makeWebView(frame: NSRect = .zero, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = configuration ?? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            return configuration
        }()
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = userAgent
        return webView
    }

    @MainActor
    static func readCredentials(from webView: WKWebView) async -> LovableCredentials? {
        guard webView.url?.host?.hasSuffix("lovable.dev") == true,
              let json = try? await webView.callAsyncJavaScript(readCredentialsScript, arguments: [:], in: nil, contentWorld: .page) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let refreshToken = object["refreshToken"] as? String
        else {
            return nil
        }
        let expiresAt = (object["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return LovableCredentials(
            refreshToken: refreshToken,
            idToken: object["idToken"] as? String,
            expiresAt: expiresAt,
            email: object["email"] as? String,
            uid: object["uid"] as? String
        )
    }

    /// Opens lovable.dev in the background so its own Firebase SDK renews the session,
    /// then reads the fresh token. Used when renewing directly isn't possible.
    @MainActor
    static func refreshInBackground(timeout: TimeInterval = 45) async throws -> LovableCredentials {
        let webView = makeWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.load(URLRequest(url: dashboardURL))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if let credentials = await readCredentials(from: webView),
               let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow > 120 {
                return credentials
            }
        }
        throw SessionError.refreshFailed("lovable.dev no renovó la sesión")
    }

    /// Forgets the lovable.dev session in the embedded browser too.
    @MainActor
    static func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let lovable = records.filter { $0.displayName.contains("lovable") }
        await store.removeData(ofTypes: types, for: lovable)
    }
}

/// The "Iniciar sesión en Lovable" window.
@MainActor
final class LoginWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private var popups: [NSWindow] = []
    private var timer: Timer?
    private var onSignIn: ((LovableCredentials) -> Void)?
    private var finished = false

    init(onSignIn: @escaping (LovableCredentials) -> Void) {
        self.onSignIn = onSignIn
        webView = LovableWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 760))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Iniciar sesión en Lovable"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        webView.load(URLRequest(url: LovableWeb.loginURL))
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForSession() }
        }
    }

    private func checkForSession() async {
        guard !finished, let credentials = await LovableWeb.readCredentials(from: webView) else { return }
        finished = true
        timer?.invalidate()
        onSignIn?(credentials)
        onSignIn = nil
        popups.forEach { $0.close() }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        popups.forEach { $0.close() }
    }

    // Sign in with Google/GitHub opens a popup that reports back to the page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = LovableWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Iniciar sesión"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let window = popups.first(where: { $0.contentView === webView }) {
            window.close()
            popups.removeAll { $0 === window }
        }
    }
}
