import AppKit
import LoveployCore
import SwiftTerm
import SwiftUI
import WebKit

// Session groups: saved sets of up to eight Claude Code sessions, local or on claude.ai/code and
// from any account, that open together in one split window. Each group has its own window, which
// remembers where it was and how big, so one click brings back the whole arrangement.

// MARK: - Groups

@MainActor
final class SessionGroups: ObservableObject {
    static let shared = SessionGroups()

    @Published private(set) var groups: [SessionGroup]
    @Published private(set) var openIDs: Set<UUID> = []
    private let store = SessionGroupStore.default()
    private var windows: [UUID: GroupWindowController] = [:]

    private init() {
        groups = store.load()
        // After the Mac sleeps, claude.ai pages show stale state until reloaded.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    for controller in SessionGroups.shared.windows.values { controller.hosts.reloadWeb() }
                }
            }
        }
    }

    func group(_ id: UUID) -> SessionGroup? { groups.first { $0.id == id } }
    func isOpen(_ id: UUID) -> Bool { openIDs.contains(id) }

    @discardableResult
    func create(name: String) -> SessionGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = SessionGroup(name: trimmed.isEmpty ? "Grupo \(groups.count + 1)" : trimmed)
        groups.append(group)
        save()
        open(group.id)
        return group
    }

    func change(_ id: UUID, _ edit: (inout SessionGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let before = (groups[index].layout, groups[index].panes.map(\.id))
        edit(&groups[index])
        save()
        windows[id]?.window?.title = groups[index].name
        // A new arrangement starts evenly split.
        if before.0 != groups[index].layout || before.1 != groups[index].panes.map(\.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.equalize(id) }
        }
    }

    /// Reorders the groups (drag in the Loveploy window); the panel lists them in this order.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Moves one group a place up (-1) or down (+1).
    func move(_ id: UUID, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(index + offset) else { return }
        groups.swapAt(index, index + offset)
        save()
    }

    /// A pane that's loaded in an open group window, with its view.
    func loaded(_ pane: UUID) -> (SessionPane, NSView)? {
        for controller in windows.values {
            guard let group = group(controller.groupID), let model = group.panes.first(where: { $0.id == pane }),
                  let view = controller.hosts.existingView(pane) else { continue }
            return (model, view)
        }
        return nil
    }

    func pane(_ id: UUID) -> SessionPane? {
        for group in groups { if let pane = group.panes.first(where: { $0.id == id }) { return pane } }
        return nil
    }

    func paneTitle(_ id: UUID) -> String? { pane(id)?.title }

    /// The pane you're typing in, in the group window in front.
    func focusedPane() -> (UUID, NSView)? {
        for controller in windows.values {
            guard let window = controller.window, window.isKeyWindow,
                  let responder = window.firstResponder as? NSView,
                  let group = group(controller.groupID) else { continue }
            for pane in group.panes {
                if let view = controller.hosts.existingView(pane.id), responder === view || responder.isDescendant(of: view) {
                    return (pane.id, view)
                }
            }
        }
        return nil
    }

    /// Pauses every pane of the group you're not using right now.
    func freeMemory(_ id: UUID) { windows[id]?.sweep(force: true) }

    /// Every pane of the group's window the same width (and the same height in each column).
    func equalize(_ id: UUID) {
        windows[id]?.equalize()
    }

    /// Adds a pane; false when the group already has eight.
    @discardableResult
    func add(_ pane: SessionPane, to id: UUID) -> Bool {
        var added = false
        change(id) { added = $0.add(pane) }
        return added
    }

    func delete(_ id: UUID) {
        windows[id]?.close()
        let hadShortcut = group(id)?.shortcut != nil
        groups.removeAll { $0.id == id }
        save()
        if hadShortcut { Engine.shared.updateHotKeys() }
    }

    /// Gives the group a global shortcut (taking it from any other group that had it).
    func setShortcut(_ shortcut: GroupShortcut?, for id: UUID) {
        for index in groups.indices where groups[index].id != id && shortcut?.sameKeys(as: groups[index].shortcut) == true {
            groups[index].shortcut = nil
        }
        change(id) { $0.shortcut = shortcut }
        Engine.shared.updateHotKeys()
    }

    /// The pane's new session has started, so from now on it resumes it.
    func markStarted(_ paneID: UUID) {
        guard let index = groups.firstIndex(where: { $0.panes.contains { $0.id == paneID } }),
              var pane = groups[index].panes.first(where: { $0.id == paneID }), pane.startsNew else { return }
        pane.startsNew = false
        groups[index].replace(pane)
        save()
    }

    /// Session id → billing project, from the panes of every group.
    var billingAssignments: [String: UUID] {
        var map: [String: UUID] = [:]
        for group in groups {
            for pane in group.panes {
                guard let project = group.project(of: pane) else { continue }
                if let session = pane.sessionID { map[session] = project }
                // Web and Chrome panes count by pane (see ActivityLog).
                map[ActivityLog.key(pane: pane.id)] = project
            }
        }
        return map
    }

    /// Opens the group, or brings its window forward on whatever screen or Space it's on.
    func open(_ id: UUID) {
        PanelController.shared.close()
        if let controller = windows[id], let window = controller.window {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            controller.followChrome()
            return
        }
        guard group(id) != nil else { return }
        let controller = GroupWindowController(groupID: id)
        windows[id] = controller
        openIDs.insert(id)
        updateActivationPolicy()
        NSApp.activate()
        controller.showWindow(nil)
        controller.enterFullScreenIfWanted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controller.equalize() }
    }

    func openAll() { groups.forEach { open($0.id) } }

    func openAtLaunch() { groups.filter(\.openAtLaunch).forEach { open($0.id) } }

    func windowClosed(_ id: UUID) {
        windows[id] = nil
        openIDs.remove(id)
        updateActivationPolicy()
    }

    /// With a group window open the app shows in the Dock and ⌘-Tab like any app; with none,
    /// it goes back to living in the menu bar.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(windows.isEmpty ? .accessory : .regular)
    }

    private func save() {
        do {
            try store.save(groups)
        } catch {
            NSSound.beep()
        }
    }
}

extension NSAlert {
    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

// MARK: - Accounts

/// The Claude accounts (profiles of the account manager), as panes refer to them.
@MainActor
enum Accounts {
    static func profile(_ account: String?) -> Profile? {
        guard let account else { return nil }
        return Engine.shared.profiles.first { $0.id.uuidString == account }
    }

    static func name(_ account: String?) -> String {
        profile(account)?.name ?? "Cuenta por defecto"
    }

    static func tint(_ account: String?) -> SwiftUI.Color {
        profile(account)?.tint ?? .secondary
    }

    /// Where each account keeps its Claude Code sessions, plus who owns the sessions of the
    /// shared ~/.claude folder (the desktop app's Code tab lists them per account).
    static func localSources() -> (sources: [(root: URL, configDir: String?, account: String?)], owners: [String: String], titles: [String: String]) {
        let index = UsageScan.sessionIndex(Engine.shared.profiles)
        return (localRoots(), index.owners, index.titles)
    }

    /// Each account's `projects/` folder, and any other ~/.claude* folder (accounts set up by
    /// hand with CLAUDE_CONFIG_DIR).
    static func localRoots() -> [(root: URL, configDir: String?, account: String?)] {
        let profiles = Engine.shared.profiles
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sources: [(root: URL, configDir: String?, account: String?)] = [
            (home.appendingPathComponent(".claude/projects"), nil, profiles.first(where: \.isDefault)?.id.uuidString),
        ]
        var seen: Set<String> = [home.appendingPathComponent(".claude").standardizedFileURL.path]
        for profile in profiles {
            guard let config = profile.codeConfigDir else { continue }
            let folder = URL(fileURLWithPath: config).standardizedFileURL
            guard seen.insert(folder.path).inserted else { continue }
            sources.append((folder.appendingPathComponent("projects"), config, profile.id.uuidString))
        }
        let hidden = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        for folder in hidden where folder.lastPathComponent.hasPrefix(".claude") {
            let folder = folder.standardizedFileURL
            let projects = folder.appendingPathComponent("projects")
            guard FileManager.default.fileExists(atPath: projects.path), seen.insert(folder.path).inserted else { continue }
            sources.append((projects, folder.path, nil))
        }
        return sources
    }
}

// MARK: - Window

@MainActor
final class GroupWindowController: NSWindowController, NSWindowDelegate {
    let groupID: UUID
    let hosts = PaneHosts()

    init(groupID: UUID) {
        self.groupID = groupID
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = SessionGroups.shared.group(groupID)?.name ?? "Grupo"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: GroupView(groupID: groupID, hosts: hosts))
        // Each group comes back where it was, at the size it had, on the same screen.
        let name = "LoveployGroup-\(groupID.uuidString)"
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
        startSweeping()
        watchClicks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = hosts.runningTerminals
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Cerrar \(sender.title)?"
        alert.informativeText = running == 1
            ? "Se cierra 1 sesión de Claude Code de esta Mac. Queda guardada y se reanuda al volver a abrir el grupo."
            : "Se cierran \(running) sesiones de Claude Code de esta Mac. Quedan guardadas y se reanudan al volver a abrir el grupo."
        alert.addButton(withTitle: "Cerrar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Splits every row and column of the window evenly, outermost first.
    func equalize() {
        guard let root = window?.contentView else { return }
        Self.equalize(root)
        followChrome()
    }

    private static func equalize(_ view: NSView) {
        if let split = view as? NSSplitView {
            let panes = split.arrangedSubviews.filter { !$0.isHidden }
            if panes.count > 1 {
                let total = split.isVertical ? split.bounds.width : split.bounds.height
                let size = (total - CGFloat(panes.count - 1) * split.dividerThickness) / CGFloat(panes.count)
                for index in 0..<(panes.count - 1) {
                    split.setPosition(CGFloat(index + 1) * size + CGFloat(index) * split.dividerThickness, ofDividerAt: index)
                }
                split.layoutSubtreeIfNeeded()
            }
        }
        for child in view.subviews { equalize(child) }
    }

    // MARK: Memory saver

    private var sweeper: Timer?
    private var awaySince: Date?

    func startSweeping() {
        guard sweeper == nil else { return }
        sweeper = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(sweeper!, forMode: .common)
    }

    func sweep(force: Bool = false) {
        guard let group = SessionGroups.shared.group(groupID) else { return }
        hosts.sweep(group, window: window, awaySince: window?.isKeyWindow == true ? nil : (awaySince ?? Date()), force: force)
    }

    // MARK: Full screen

    /// Groups open full screen (their own Space), unless they hold Chrome windows, which
    /// can't share a full screen Space: those fill the screen instead.
    func enterFullScreenIfWanted() {
        guard let window, UserDefaults.standard.object(forKey: "loveploy.groupsFullScreen") as? Bool ?? true else { return }
        let hasChrome = SessionGroups.shared.group(groupID)?.panes.contains { $0.kind == .chrome } ?? false
        if hasChrome {
            if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true, animate: false) }
        } else if !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { equalize() }
    func windowDidExitFullScreen(_ notification: Notification) { equalize() }

        func windowDidResignKey(_ notification: Notification) { awaySince = Date() }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pages left in the background a long time can stop updating; refresh the quiet ones.
        if let away = awaySince, Date().timeIntervalSince(away) > 15 * 60 { hosts.reloadQuietWeb(olderThan: away) }
        awaySince = nil
        wakeAll()
    }

    func wakeAll() {
        if let group = SessionGroups.shared.group(groupID) { hosts.wakeAll(group) }
    }

    /// One click anywhere in the window brings back every paused pane of the group.
    private var clickMonitor: Any?

    func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window, !self.hosts.sleeping.isEmpty { self.wakeAll() }
            }
            return event
        }
    }

    // Chrome panes follow the window when it moves or changes size.
    private var follow: DispatchWorkItem?

    func windowDidMove(_ notification: Notification) { followChrome() }
    func windowDidEndLiveResize(_ notification: Notification) { followChrome() }
    func windowDidMiniaturize(_ notification: Notification) { hosts.suspendWeb() }
    func windowDidDeminiaturize(_ notification: Notification) {
        hosts.resume()
        followChrome()
    }

    func followChrome() {
        guard SessionGroups.shared.group(groupID)?.panes.contains(where: { $0.kind == .chrome }) == true else { return }
        follow?.cancel()
        let id = groupID
        let item = DispatchWorkItem { Task { @MainActor in await ChromePlacer.shared.arrange(id) } }
        follow = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func windowWillClose(_ notification: Notification) {
        sweeper?.invalidate()
        sweeper = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        hosts.terminateAll()
        SessionGroups.shared.windowClosed(groupID)
    }
}

// MARK: - Pane views (kept alive while the layout changes)

/// Owns each pane's terminal or web view, so rearranging the window never restarts a session.
@MainActor
final class PaneHosts: ObservableObject {
    @Published private(set) var ended: [UUID: String] = [:]
    /// Panes let go to save memory; they come back on a click (or, for web panes, when you
    /// return to the window).
    @Published private(set) var sleeping: Set<UUID> = []
    private var views: [UUID: NSView] = [:]
    private var observers: [UUID: TerminalObserver] = [:]
    private var popups: [WebPopups] = []

    var runningTerminals: Int {
        views.values.compactMap { $0 as? LocalProcessTerminalView }.filter { $0.process?.running == true }.count
    }

    func view(for pane: SessionPane) -> NSView {
        if let view = views[pane.id] { return view }
        let view: NSView = pane.kind == .local ? makeTerminal(pane) : makeWeb(pane)
        views[pane.id] = view
        return view
    }

    func reload(_ pane: SessionPane) {
        drop(pane.id)
        ended[pane.id] = nil
        objectWillChange.send()
    }

    func drop(_ id: UUID) {
        if let terminal = views[id] as? LocalProcessTerminalView, terminal.process?.running == true {
            terminal.terminate()
        }
        views[id]?.removeFromSuperview()
        views[id] = nil
        observers[id] = nil
    }

    func terminateAll() {
        for id in Array(views.keys) { drop(id) }
        popups = []
    }

    /// Each web pane is a WebKit process of its own (hundreds of MB). While the window is
    /// minimized they're let go, and come back when it's shown again; terminals keep running.
    func suspendWeb() {
        for (id, view) in views where view is WKWebView {
            view.removeFromSuperview()
            views[id] = nil
        }
        popups = []
    }

    func resume() { objectWillChange.send() }

    /// The pane's terminal or web view, if it's loaded.
    func existingView(_ id: UUID) -> NSView? { views[id] }

    // MARK: Memory saver

    func sleep(_ id: UUID) {
        guard !sleeping.contains(id) else { return }
        sleeping.insert(id)   // first, so the terminal's exit isn't reported as an ending
        drop(id)
        if views.values.allSatisfy({ !($0 is WKWebView) }) { popups = [] }
    }

    func wake(_ id: UUID) {
        guard sleeping.remove(id) != nil else { return }
        PaneUse.touch(id)
        objectWillChange.send()
    }

    /// Everything paused in the group comes back at once (a click in its window, or returning
    /// to it): web pages and Claude Code terminals alike.
    func wakeAll(_ group: SessionGroup) {
        for pane in group.panes where sleeping.contains(pane.id) { wake(pane.id) }
    }

    /// Reloads the web panes that showed no activity since `date` (the ones you were using
    /// keep what you typed).
    func reloadQuietWeb(olderThan date: Date) {
        for (id, view) in views {
            guard let web = view as? WKWebView, (PaneUse.last[id] ?? .distantPast) < date else { continue }
            web.reload()
        }
    }

    /// claude.ai pages lose their live connection while the Mac sleeps; reload them.
    func reloadWeb() {
        for view in views.values {
            (view as? WKWebView)?.reload()
        }
    }

    /// Puts to sleep what hasn't been used: web panes of a window you left more than N
    /// minutes ago, and Claude Code terminals with no input or output for M minutes. The pane
    /// you're typing in is never touched. `force` sleeps every other web pane now, and
    /// terminals idle for 2 minutes.
    func sweep(_ group: SessionGroup, window: NSWindow?, awaySince: Date?, force: Bool = false) {
        let webLimit = MemorySaver.webMinutes * 60, terminalLimit = MemorySaver.terminalMinutes * 60
        let now = Date()
        let focused = window?.firstResponder as? NSView
        for pane in group.panes where !sleeping.contains(pane.id) {
            guard let view = views[pane.id] else { continue }
            if let focused, focused === view || focused.isDescendant(of: view) { continue }
            // A pane with queued messages stays awake so the queue can go on.
            if MessageQueues.shared.hasPending(pane.id) { continue }
            switch pane.kind {
            case .cloud, .preview:
                let away = awaySince.map { now.timeIntervalSince($0) } ?? 0
                let idle = now.timeIntervalSince(PaneUse.last[pane.id] ?? .distantPast)
                if force || (webLimit > 0 && away > Double(webLimit) && idle > Double(webLimit)) { sleep(pane.id) }
            case .local:
                // Only sessions that can be resumed, and never while Claude Code is writing.
                guard let terminal = view as? TrackedTerminal, terminal.process?.running == true,
                      pane.sessionID != nil, !pane.startsNew else { continue }
                let idle = now.timeIntervalSince(terminal.lastUse)
                if (force && idle > 120) || (terminalLimit > 0 && idle > Double(terminalLimit)) { sleep(pane.id) }
            case .chrome:
                continue
            }
        }
    }

    // A terminal running Claude Code through the user's login shell, signed in as the pane's account.
    private func makeTerminal(_ pane: SessionPane) -> NSView {
        let terminal = TrackedTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let observer = TerminalObserver(paneID: pane.id) { [weak self] id, code in
            guard let self, !self.sleeping.contains(id) else { return }
            self.ended[id] = code == 0 || code == nil ? "La sesión terminó." : "Claude Code salió con código \(code!)."
        }
        observers[pane.id] = observer
        terminal.processDelegate = observer

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "es_MX.UTF-8" }
        environment["CLAUDE_CONFIG_DIR"] = nil
        for (key, value) in pane.environment { environment[key] = value }
        let shell = Self.loginShell
        terminal.startProcess(
            executable: shell,
            args: ["-l", "-i", "-c", pane.shellCommand(settings: MessageQueues.hookSettings(pane: pane.id))],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent
        )
        if pane.startsNew { SessionGroups.shared.markStarted(pane.id) }
        MessageQueues.shared.launched(pane.id)
        return terminal
    }

    // claude.ai in the pane's account: each account has its own web storage, so its sign-in stays separate.
    private func makeWeb(_ pane: SessionPane) -> NSView {
        let configuration = WKWebViewConfiguration()
        if let id = pane.account.flatMap(UUID.init(uuidString:)) {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            configuration.websiteDataStore = .default()
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let isPreview = pane.kind == .preview
        let mic = isPreview ? nil : ClaudeMicBridge.install(in: configuration, pane: pane.id)
        if !isPreview { PaneActivity.install(in: configuration, pane: pane.id) }
        PaneUse.touch(pane.id)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), configuration: configuration)
        mic?.web = web
        if isPreview { PreviewWatcher.shared.watch(pane.id, web: web) }
        web.customUserAgent = LovableWeb.userAgent
        web.allowsBackForwardNavigationGestures = true
        let popups = WebPopups()
        self.popups.append(popups)
        web.uiDelegate = popups
        web.navigationDelegate = popups
        if let url = pane.url.flatMap(URL.init(string:)) {
            web.load(URLRequest(url: url))
        }
        return web
    }

    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}

/// A terminal that knows when it was last used (typed into, or written to by Claude Code).
final class TrackedTerminal: LocalProcessTerminalView {
    private(set) var lastUse = Date()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastUse = Date()
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        lastUse = Date()
        super.send(source: source, data: data)
    }
}

/// When each web pane was last used (input, or new text from Claude).
@MainActor
enum PaneUse {
    static var last: [UUID: Date] = [:]
    static func touch(_ id: UUID) { last[id] = Date() }
}

/// How long unused panes stay loaded (0 = always).
enum MemorySaver {
    static var webMinutes: Int { UserDefaults.standard.object(forKey: "loveploy.sleepWebMinutes") as? Int ?? 10 }
    static var terminalMinutes: Int { UserDefaults.standard.object(forKey: "loveploy.sleepTerminalMinutes") as? Int ?? 30 }
}

/// A paused pane: nothing loaded, one click brings it back where it was.
struct SleepingPaneView: View {
    let pane: SessionPane
    let wake: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("En pausa para ahorrar memoria").font(.headline)
            Text(pane.kind == .local ? "La sesión de Claude Code sigue guardada y se reanuda donde iba." : "Vuelve a cargar la página donde estaba.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reanudar", action: wake).buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: wake)
    }
}

/// Reports a terminal's process ending back to its pane.
final class TerminalObserver: NSObject, LocalProcessTerminalViewDelegate {
    let paneID: UUID
    let onExit: @MainActor (UUID, Int32?) -> Void

    init(paneID: UUID, onExit: @escaping @MainActor (UUID, Int32?) -> Void) {
        self.paneID = paneID
        self.onExit = onExit
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = paneID
        let onExit = onExit
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onExit(id, exitCode) }
        }
    }
}

/// What a browser does that a bare WKWebView doesn't: popups (sign-in with Google reports
/// back through one), downloads (to ~/Downloads) and the file picker for attachments.
@MainActor
final class WebPopups: NSObject, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    private var windows: [NSWindow] = []
    private var destinations: [ObjectIdentifier: URL] = [:]

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = LovableWeb.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
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
        windows.append(window)
        return popup
    }

    /// claude.ai's microphone (voice mode and dictation) works like in a browser.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        origin.host == "claude.ai" || origin.host.hasSuffix(".claude.ai") ? .grant : .prompt
    }

        func webViewDidClose(_ webView: WKWebView) {
        if let window = windows.first(where: { $0.contentView === webView }) {
            window.close()
            windows.removeAll { $0 === window }
        }
    }

    // MARK: Attachments

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.lowercased().hasPrefix("attachment")
        return navigationResponse.canShowMIMEType && !attachment ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let url = Self.freeDownloadURL(for: suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounces the Downloads stack in the Dock, like Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = destinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "No se pudo descargar \(url?.lastPathComponent ?? "el archivo")"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// ~/Downloads/name.ext, or "name 2.ext" and so on when it's taken.
    static func freeDownloadURL(for suggested: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = suggested.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let file = name.isEmpty ? "descarga" : name
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        var candidate = folder.appendingPathComponent(file)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Puts the pane's long-lived view inside whatever container SwiftUI gives it this time.
struct PaneHostView: NSViewRepresentable {
    let pane: SessionPane
    @ObservedObject var hosts: PaneHosts

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let child = hosts.view(for: pane)
        guard child.superview !== container else { return }
        child.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        child.frame = container.bounds
        child.autoresizingMask = [.width, .height]
        container.addSubview(child)
    }
}

// MARK: - Group window content

struct GroupView: View {
    let groupID: UUID
    @ObservedObject var hosts: PaneHosts
    @ObservedObject private var groups = SessionGroups.shared
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        if let group = groups.group(groupID) {
            VStack(spacing: 0) {
                toolbar(group)
                Divider()
                if group.panes.isEmpty {
                    empty
                } else {
                    grid(group)
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            .onAppear { name = group.name }
        } else {
            Text("Este grupo ya no existe.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolbar(_ group: SessionGroup) -> some View {
        HStack(spacing: 12) {
            TextField("Nombre", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: 260)
                .onSubmit { groups.change(groupID) { $0.name = name } }
            Picker("", selection: Binding(get: { group.layout }, set: { layout in groups.change(groupID) { $0.layout = layout } })) {
                ForEach(PaneLayout.allCases) { layout in
                    Image(systemName: layout.symbol).help(layout.label).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Abrir al iniciar", isOn: Binding(get: { group.openAtLaunch }, set: { on in groups.change(groupID) { $0.openAtLaunch = on } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Button {
                groups.freeMemory(groupID)
            } label: { Label("Liberar memoria", systemImage: "moon.zzz") }
            .font(.system(size: 12))
            .help("Pone en pausa los paneles que no estás usando; vuelven con un clic")
            Button {
                groups.equalize(groupID)
            } label: { Label("Igualar", systemImage: "equal.square") }
            .font(.system(size: 12))
            .keyboardShortcut("=", modifiers: [.command, .option])
            .help("Todos los paneles del mismo ancho y alto (⌥⌘=)")
            .disabled(group.panes.count < 2)
            if group.panes.contains(where: { $0.kind == .chrome }) {
                Button {
                    Task { if let error = await ChromePlacer.shared.arrange(groupID) { NSAlert.show(error) } }
                } label: { Label("Acomodar Chrome", systemImage: "macwindow.on.rectangle") }
                .font(.system(size: 12))
                .help("Pone tus ventanas de Chrome sobre sus paneles y las trae al frente")
            }
            ShortcutRecorder(current: group.shortcut) { groups.setShortcut($0, for: groupID) }
                .font(.system(size: 12))
            ProjectMenu(selected: group.project, suggestedName: group.name) { project in
                groups.change(groupID) { $0.project = project }
            }
            .font(.system(size: 12))
            Spacer()
            Text("\(group.panes.count) de \(SessionGroup.maxPanes)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                adding = true
            } label: {
                Label("Agregar sesión", systemImage: "plus")
            }
            .disabled(group.isFull)
            .sheet(isPresented: $adding) {
                AddPaneView(groupID: groupID) { adding = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Agrega hasta 8 sesiones de Claude Code").font(.headline)
            Text("Sesiones de esta Mac o de claude.ai/code, de cualquiera de tus cuentas.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Agregar sesión") { adding = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func grid(_ group: SessionGroup) -> some View {
        let panes = group.panes
        if group.layout == .focus {
            HSplitView {
                cell(panes[0], in: group)
                if panes.count > 1 {
                    VSplitView {
                        ForEach(panes.dropFirst()) { cell($0, in: group) }
                    }
                }
            }
        } else {
            VSplitView {
                ForEach(Array(Self.slices(panes, rows: group.layout.rows(for: panes.count)).enumerated()), id: \.offset) { _, row in
                    HSplitView {
                        ForEach(row) { cell($0, in: group) }
                    }
                }
            }
        }
    }

    private func cell(_ pane: SessionPane, in group: SessionGroup) -> some View {
        let index = group.panes.firstIndex(where: { $0.id == pane.id }) ?? 0
        return PaneCell(pane: pane, groupID: groupID, index: index, count: group.panes.count, hosts: hosts)
    }

    static func slices(_ panes: [SessionPane], rows: [Int]) -> [[SessionPane]] {
        var result: [[SessionPane]] = []
        var start = 0
        for size in rows {
            let end = min(panes.count, start + size)
            if start < end { result.append(Array(panes[start..<end])) }
            start = end
        }
        return result
    }
}

struct PaneCell: View {
    let pane: SessionPane
    let groupID: UUID
    let index: Int
    let count: Int
    @ObservedObject var hosts: PaneHosts

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if pane.kind == .chrome {
                    ChromePaneView(pane: pane, groupID: groupID)
                } else if hosts.sleeping.contains(pane.id) {
                    SleepingPaneView(pane: pane) { hosts.wake(pane.id) }
                } else if pane.kind == .preview && pane.mobile {
                    // A phone's width, centered.
                    PaneHostView(pane: pane, hosts: hosts)
                        .frame(width: 390)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.25))
                } else {
                    PaneHostView(pane: pane, hosts: hosts)
                }
                if let message = hosts.ended[pane.id] {
                    VStack(spacing: 8) {
                        Text(message).font(.system(size: 13, weight: .medium))
                        Button("Reabrir") { hosts.reload(pane) }.buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                }
            }
        }
        .frame(minWidth: 220, minHeight: 160)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Accounts.tint(pane.account)).frame(width: 8, height: 8)
            Image(systemName: pane.kind == .local ? "terminal" : pane.kind == .chrome ? "macwindow" : pane.kind == .preview ? "eye" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(pane.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(Accounts.name(pane.account)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            ProjectMenu(selected: pane.project, inherited: SessionGroups.shared.group(groupID)?.project, isPane: true,
                        cloud: pane.kind != .local, suggestedName: pane.title, folder: pane.directory) { project in
                var changed = pane
                changed.project = project
                SessionGroups.shared.change(groupID) { $0.replace(changed) }
            }
            Button { SessionGroups.shared.change(groupID) { $0.move(pane.id, by: -1) } } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .help("Mover antes")
            Button { SessionGroups.shared.change(groupID) { $0.move(pane.id, by: 1) } } label: { Image(systemName: "chevron.right") }
                .disabled(index >= count - 1)
                .help("Mover después")
            Button {
                if pane.kind == .chrome { Task { await ChromePlacer.shared.arrange(groupID) } } else { hosts.reload(pane) }
            } label: { Image(systemName: "arrow.clockwise") }
                .help(pane.kind == .local ? "Reiniciar la sesión" : pane.kind == .chrome ? "Acomodar Chrome" : "Recargar")
            if pane.kind == .preview {
                PreviewControls(pane: pane, groupID: groupID)
            } else if pane.kind != .chrome && !hosts.sleeping.contains(pane.id) {
                QueueButton(pane: pane)
                DictationButton(pane: pane, hosts: hosts)
            }
                        Button { openOutside() } label: { Image(systemName: "arrow.up.forward.app") }
                .help(pane.kind == .local ? "Abrir en Terminal" : "Abrir en el navegador")
            Button {
                hosts.drop(pane.id)
                SessionGroups.shared.change(groupID) { $0.remove(pane.id) }
            } label: { Image(systemName: "xmark") }
                .help("Quitar del grupo")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Accounts.tint(pane.account).opacity(0.12))
    }

    private func openOutside() {
        switch pane.kind {
        case .cloud, .preview:
            if let url = pane.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        case .chrome:
            if let url = pane.url.flatMap(URL.init(string:)),
               let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeBridge.bundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
            }
        case .local:
            var lines = ["#!/bin/zsh"]
            for (key, value) in pane.environment { lines.append("export \(key)=\(shellQuote(value))") }
            lines += ["clear", pane.shellCommand.replacingOccurrences(of: "exec claude", with: "claude"), "exec $SHELL -l"]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Loveploy-\(pane.id.uuidString.prefix(8)).command")
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                NSWorkspace.shared.open(url)
            } catch {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Adding sessions

/// The claude.ai pages open in Chrome (tabs and installed apps), one click to add.
struct ChromeTabsList: View {
    let groupID: UUID
    let done: () -> Void
    @ObservedObject private var groups = SessionGroups.shared
    @ObservedObject private var engine = Engine.shared
    @State private var tabs: [ChromeTab] = []
    @State private var listed: [(url: String, title: String)] = []
    @State private var loading = true
    @State private var error: String?
    @State private var listError: String?
    @State private var account: String?

    private var group: SessionGroup? { groups.group(groupID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lo que tienes abierto de claude.ai en Chrome, incluidas las apps instaladas de Chrome.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Volver a leer Chrome")
            }
            if loading {
                ProgressView("Leyendo Chrome…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 460)
                    if error.contains("Automatización") {
                        Button("Abrir Ajustes de Automatización") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Abiertas en Chrome (\(tabs.count))") {
                        if tabs.isEmpty { Text("No hay páginas de claude.ai abiertas en Chrome.").foregroundStyle(.secondary) }
                        ForEach(tabs) { tab in row(url: tab.url, title: tab.title, open: true) }
                    }
                    if !listed.isEmpty || listError != nil {
                        Section("Sesiones de Claude Code que lista Chrome (\(listed.count))") {
                            if let listError { Text(listError).font(.caption).foregroundStyle(.secondary) }
                            ForEach(listed.filter { item in !tabs.contains { ClaudeLink.samePage($0.url, item.url) } }, id: \.url) { item in
                                row(url: item.url, title: item.title, open: false)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Text("«Dentro de Blender Play» usa la cuenta:").font(.caption)
                Picker("", selection: $account) {
                    ForEach(engine.profiles) { Text($0.name).tag(Optional($0.id.uuidString)) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Button("Cerrar") { done() }.keyboardShortcut(.cancelAction)
            }
        }
        .task { await load() }
        .onAppear { account = account ?? engine.profiles.first?.id.uuidString }
    }

    private func inGroup(_ url: String) -> Bool {
        group?.panes.contains { $0.url.map { ClaudeLink.samePage($0, url) } ?? false } ?? false
    }

    private func row(url: String, title: String, open: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ClaudeLink.isCodeSession(url) ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(ClaudeLink.cleanTitle(title).isEmpty ? url : ClaudeLink.cleanTitle(title)).lineLimit(1)
                Text(url.replacingOccurrences(of: "https://", with: "")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if inGroup(url) {
                Text("En el grupo").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Ventana de Chrome") { add(url, title, .chrome) }
                    .help("Usa tu Chrome con tu sesión: Blender Play acomoda esa ventana sobre su panel")
                Button("Dentro de Blender Play") { add(url, title, .cloud) }
                    .help("Un panel web dentro de la ventana del grupo, con la cuenta elegida abajo")
            }
        }
        .disabled(group?.isFull ?? true)
    }

    private func add(_ url: String, _ title: String, _ kind: SessionPane.Kind) {
        guard let pane = SessionPane.cloud(url, title: title, account: account, kind: kind) else { return }
        groups.add(pane, to: groupID)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let all = try await ChromeBridge.tabs()
            tabs = ChromeTab.claudeTabs(all)
            // A claude.ai/code tab lists every session in its sidebar.
            if let codeTab = tabs.first(where: { ($0.url as NSString).contains("claude.ai/code") }) {
                do {
                    listed = try await ChromeBridge.listedSessions(in: codeTab)
                    listError = nil
                } catch {
                    listError = error.localizedDescription
                }
            } else {
                listError = "Abre claude.ai/code en Chrome para ver aquí también las sesiones que no tienes abiertas."
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The Claude Code sessions claude.ai lists for an account (read with the account's sign-in
/// inside Loveploy).
struct CloudSessionsList: View {
    let groupID: UUID
    let done: () -> Void
    @ObservedObject private var groups = SessionGroups.shared
    @ObservedObject private var engine = Engine.shared
    @State private var account: String?
    @State private var found: [(url: String, title: String)] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var lister: CloudSessionLister?

    private var group: SessionGroup? { groups.group(groupID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cuenta")
                Picker("", selection: $account) {
                    ForEach(engine.profiles) { Text($0.name).tag(Optional($0.id.uuidString)) }
                }
                .labelsHidden().fixedSize()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Volver a buscar")
                Spacer()
            }
            if loading {
                ProgressView("Leyendo claude.ai/code…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if found.isEmpty {
                VStack(spacing: 8) {
                    Text(loaded ? "No encontré sesiones. Si esta cuenta no ha iniciado sesión en claude.ai dentro de Blender Play, ábrela una vez:" : "")
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                    if loaded {
                        Button("Iniciar sesión en claude.ai con esta cuenta") {
                            if let pane = SessionPane.cloud("https://claude.ai/code", title: "Claude Code", account: account) {
                                groups.add(pane, to: groupID)
                                done()
                            }
                        }
                        Text("Si usas Claude en Chrome, la pestaña «En Chrome» lee tus sesiones desde ahí.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(found, id: \.url) { item in
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary).frame(width: 18)
                        Text(item.title.isEmpty ? item.url : item.title).lineLimit(1)
                        Spacer()
                        if group?.panes.contains(where: { $0.url.map { ClaudeLink.samePage($0, item.url) } ?? false }) == true {
                            Text("En el grupo").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Ventana de Chrome") { add(item, .chrome) }
                            Button("Dentro de Blender Play") { add(item, .cloud) }
                        }
                    }
                    .disabled(group?.isFull ?? true)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack { Spacer(); Button("Cerrar") { done() }.keyboardShortcut(.cancelAction) }
        }
        .onAppear {
            if account == nil { account = engine.profiles.first?.id.uuidString }
            Task { await load() }
        }
        .onChange(of: account) { Task { await load() } }
    }

    private func add(_ item: (url: String, title: String), _ kind: SessionPane.Kind) {
        guard let pane = SessionPane.cloud(item.url, title: item.title, account: account, kind: kind) else { return }
        groups.add(pane, to: groupID)
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        let lister = CloudSessionLister()
        self.lister = lister
        found = await lister.sessions(account: account)
        self.lister = nil
        loaded = true
        loading = false
    }
}

/// A session found on this Mac and the account it belongs to.
struct FoundSession: Identifiable, Sendable {
    let session: LocalSession
    let account: String?
    var id: String { session.transcript }
}

struct AddPaneView: View {
    let groupID: UUID
    var done: () -> Void = {}
    @ObservedObject private var groups = SessionGroups.shared
    @ObservedObject private var engine = Engine.shared
    @AppStorage("loveploy.addTab") private var tab = 0
    @AppStorage("loveploy.addByFolder") private var byFolder = true
    @State private var sessions: [FoundSession] = []
    @State private var scanned: [String] = []
    @State private var loading = true
    @State private var query = ""
    @State private var accountFilter = "*"
    @State private var picked: [String] = []
    @State private var localAccount: String?
    @State private var cloudAccount: String?
    @State private var cloudURL = ""
    @State private var cloudTitle = ""
    @State private var cloudError: String?

    private var group: SessionGroup? { groups.group(groupID) }
    private var full: Bool { group?.isFull ?? true }
    private var room: Int { SessionGroup.maxPanes - (group?.panes.count ?? SessionGroup.maxPanes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agregar sesiones a «\(group?.name ?? "")»").font(.headline)
                Spacer()
                Text(full ? "El grupo ya tiene 8 sesiones" : "Quedan \(room) lugar\(room == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(full ? .orange : .secondary)
            }
            Picker("", selection: $tab) {
                Text("En esta Mac (\(sessions.count))").tag(0)
                Text("En Chrome").tag(2)
                Text("En la nube").tag(3)
                Text("Vista web").tag(4)
                Text("Pegar dirección").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case 2: ChromeTabsList(groupID: groupID, done: done)
            case 3: CloudSessionsList(groupID: groupID, done: done)
            case 4: PreviewPicker(groupID: groupID, done: done)
            case 1: cloud
            default: local
            }
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .task { await load() }
        .onAppear {
            let fallback = engine.profiles.first?.id.uuidString
            localAccount = localAccount ?? fallback
            cloudAccount = cloudAccount ?? fallback
        }
    }

    // MARK: local

    private var local: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar por título, carpeta o cuenta", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $accountFilter) {
                    Text("Todas las cuentas").tag("*")
                    ForEach(engine.profiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
                    }
                    Text("Sin cuenta asignada").tag("")
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Por carpeta", isOn: $byFolder).toggleStyle(.checkbox)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Volver a buscar")
            }
            if loading {
                ProgressView("Buscando sesiones…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 6) {
                    Text(sessions.isEmpty ? "No encontré sesiones de Claude Code en esta Mac." : "Ninguna sesión coincide con el filtro.")
                    if sessions.isEmpty {
                        Text("Busqué en:").font(.caption).foregroundStyle(.secondary)
                        ForEach(scanned, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if byFolder {
                        ForEach(folders, id: \.path) { folder in
                            Section {
                                ForEach(folder.items) { sessionRow($0) }
                            } header: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(folder.name).bold()
                                    Text(folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    } else {
                        ForEach(filtered) { sessionRow($0) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Button("Nueva sesión en una carpeta…") { newLocalSession() }.disabled(full)
                accountPicker($localAccount)
                Spacer()
                if !picked.isEmpty {
                    Button("Quitar selección") { picked = [] }
                }
                Button("Cerrar") { done() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Agregar" : "Agregar \(picked.count)") { addPicked() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
    }

    private var filtered: [FoundSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { item in
            if accountFilter != "*", (item.account ?? "") != accountFilter { return false }
            guard !q.isEmpty else { return true }
            return item.session.title.lowercased().contains(q) || item.session.cwd.lowercased().contains(q)
                || Accounts.name(item.account).lowercased().contains(q)
        }
    }

    /// Sessions by folder, the folder with the newest session first.
    private var folders: [(name: String, path: String, items: [FoundSession])] {
        var order: [String] = []
        var byPath: [String: [FoundSession]] = [:]
        for item in filtered {
            if byPath[item.session.cwd] == nil { order.append(item.session.cwd) }
            byPath[item.session.cwd, default: []].append(item)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return order.map { path in
            let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            return (URL(fileURLWithPath: path).lastPathComponent, shown, byPath[path] ?? [])
        }
    }

    private func inGroup(_ session: LocalSession) -> Bool {
        group?.panes.contains { $0.sessionID == session.id } ?? false
    }

    private func sessionRow(_ item: FoundSession) -> some View {
        let session = item.session
        let already = inGroup(session)
        let isPicked = picked.contains(item.id)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { already || isPicked },
                set: { on in
                    if on { if picked.count < room { picked.append(item.id) } } else { picked.removeAll { $0 == item.id } }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(already || (!isPicked && picked.count >= room))
            Circle().fill(Accounts.tint(item.account)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text("\(byFolder ? "" : session.project + " · ")\(Accounts.name(item.account)) · \(session.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if already {
                Text("En el grupo").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Agregar") {
                    if groups.add(.local(session, account: item.account), to: groupID) { picked.removeAll { $0 == item.id } }
                }
                .disabled(full)
            }
        }
        .contentShape(Rectangle())
    }

    private func addPicked() {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in picked {
            guard let item = byID[id] else { continue }
            groups.add(.local(item.session, account: item.account), to: groupID)
        }
        picked = []
        done()
    }

    private func newLocalSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Abrir aquí"
        panel.message = "Carpeta donde correrá la nueva sesión de Claude Code"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let profile = Accounts.profile(localAccount)
        // The session id is chosen here so its time and tokens can be billed from the first minute.
        let pane = SessionPane(kind: .local, title: folder.lastPathComponent, account: localAccount,
                               sessionID: UUID().uuidString.lowercased(), directory: folder.path,
                               configDir: profile?.codeConfigDir, startsNew: true)
        groups.add(pane, to: groupID)
    }

    private func load() async {
        loading = true
        let (sources, owners, titles) = Accounts.localSources()
        scanned = sources.map(\.root.path)
        let found = await Task.detached(priority: .userInitiated) { () -> [FoundSession] in
            var all: [FoundSession] = []
            var seen = Set<String>()
            for source in sources {
                for session in LocalSessionScanner.scan(projectsRoot: source.root, configDir: source.configDir, titles: titles, limit: 400)
                where seen.insert(session.id).inserted {
                    // ~/.claude holds every account's Code tab sessions; the desktop app says whose each one is.
                    let account = source.configDir == nil ? (owners[session.id] ?? source.account) : source.account
                    all.append(FoundSession(session: session, account: account))
                }
            }
            return all.sorted { $0.session.modified > $1.session.modified }
        }.value
        sessions = found
        loading = false
    }

    // MARK: cloud

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cuenta").frame(width: 70, alignment: .leading)
                accountPicker($cloudAccount)
            }
            HStack {
                Text("Dirección").frame(width: 70, alignment: .leading)
                TextField("https://claude.ai/code/session_…", text: $cloudURL).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Nombre").frame(width: 70, alignment: .leading)
                TextField("Opcional", text: $cloudTitle).textFieldStyle(.roundedBorder)
            }
            if let cloudError {
                Text(cloudError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Abrir claude.ai/code y elegir ahí") {
                    addCloud("https://claude.ai/code", title: cloudTitle.isEmpty ? "Claude Code (nube)" : cloudTitle)
                }
                .disabled(full)
                Spacer()
                Button("Agregar") { addCloud(cloudURL, title: cloudTitle) }
                    .buttonStyle(.borderedProminent)
                    .disabled(full || cloudURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Copia la dirección de la sesión desde claude.ai/code o desde la app de Claude. La primera vez, inicia sesión en claude.ai dentro del panel: cada cuenta guarda su propia sesión, así que puedes mezclar cuentas en el mismo grupo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Cerrar") { done() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func addCloud(_ address: String, title: String) {
        guard let pane = SessionPane.cloud(address, title: title, account: cloudAccount) else {
            cloudError = "Pon una dirección https de claude.ai."
            return
        }
        cloudError = nil
        if groups.add(pane, to: groupID) {
            cloudURL = ""
            cloudTitle = ""
        }
    }

    private func accountPicker(_ selection: Binding<String?>) -> some View {
        Picker("", selection: selection) {
            ForEach(engine.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id.uuidString))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Panel section

struct GroupsSection: View {
    @ObservedObject var groups: SessionGroups
    @Binding var open: Bool
    @State private var naming = false

    var body: some View {
        Divider().padding(.horizontal, 14)
        SectionHeader(title: "Grupos de sesiones (\(groups.groups.count))",
                      trailing: groups.openIDs.isEmpty ? nil : "\(groups.openIDs.count) abiertos",
                      open: $open)
        if open {
            VStack(spacing: 0) {
                ForEach(groups.groups) { GroupRow(group: $0, groups: groups) }
                if groups.groups.count > 1 {
                    PlainRow(title: "Abrir todos") { groups.openAll() }
                }
                if naming {
                    NameField(text: "", placeholder: "Nombre del grupo", onCommit: { name in
                        naming = false
                        groups.create(name: name)
                    }, onCancel: { naming = false })
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                } else {
                    PlainRow(title: "Nuevo grupo…") { naming = true }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
    }
}

struct GroupRow: View {
    let group: SessionGroup
    @ObservedObject var groups: SessionGroups

    var body: some View {
        HStack(spacing: 9) {
            Badge(on: groups.isOpen(group.id)) {
                Image(systemName: group.layout.symbol).font(.system(size: 11, weight: .medium))
            }
            Text(group.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            if group.openAtLaunch {
                Image(systemName: "power").font(.system(size: 10)).foregroundStyle(.tertiary).help("Se abre al iniciar")
            }
            if let shortcut = group.shortcut {
                Text(shortcut.display).font(.system(size: 11)).foregroundStyle(.tertiary).help("Tecla rápida")
            }
            Text("\(group.panes.count)/\(SessionGroup.maxPanes)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .modifier(HoverBackground(radius: 8))
        .onTapGesture { groups.open(group.id) }
        .contextMenu {
            Button("Abrir") { groups.open(group.id) }
            Button(group.openAtLaunch ? "No abrir al iniciar" : "Abrir al iniciar") {
                groups.change(group.id) { $0.openAtLaunch.toggle() }
            }
            if group.shortcut != nil {
                Button("Quitar tecla rápida \(group.shortcut!.display)") { groups.setShortcut(nil, for: group.id) }
            } else if let next = GroupShortcut.suggestion(taken: groups.groups.map(\.shortcut)) {
                Button("Tecla rápida \(next.display)") { groups.setShortcut(next, for: group.id) }
            }
            Divider()
            Button("Subir") { groups.move(group.id, by: -1) }.disabled(groups.groups.first?.id == group.id)
            Button("Bajar") { groups.move(group.id, by: 1) }.disabled(groups.groups.last?.id == group.id)
            Divider()
            Button("Eliminar grupo", role: .destructive) { groups.delete(group.id) }
        }
    }
}
