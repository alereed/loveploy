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
        edit(&groups[index])
        save()
        windows[id]?.window?.title = groups[index].name
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
        groups.removeAll { $0.id == id }
        save()
    }

    func open(_ id: UUID) {
        PanelController.shared.close()
        if let controller = windows[id] {
            NSApp.activate()
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard group(id) != nil else { return }
        let controller = GroupWindowController(groupID: id)
        windows[id] = controller
        openIDs.insert(id)
        updateActivationPolicy()
        NSApp.activate()
        controller.showWindow(nil)
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

    static func tint(_ account: String?) -> Color {
        profile(account)?.tint ?? .secondary
    }

    /// Where each account keeps its Claude Code sessions, plus who owns the sessions of the
    /// shared ~/.claude folder (the desktop app's Code tab lists them per account).
    static func localSources() -> (sources: [(root: URL, configDir: String?, account: String?)], owners: [String: String], titles: [String: String]) {
        let profiles = Engine.shared.profiles
        let index = UsageScan.sessionIndex(profiles)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sources: [(root: URL, configDir: String?, account: String?)] = [
            (home.appendingPathComponent(".claude/projects"), nil, profiles.first(where: \.isDefault)?.id.uuidString),
        ]
        for profile in profiles {
            guard let config = profile.codeConfigDir else { continue }
            sources.append((URL(fileURLWithPath: config).appendingPathComponent("projects"), config, profile.id.uuidString))
        }
        return (sources, index.owners, index.titles)
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
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: GroupView(groupID: groupID, hosts: hosts))
        // Each group comes back where it was, at the size it had, on the same screen.
        let name = "LoveployGroup-\(groupID.uuidString)"
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
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

    func windowWillClose(_ notification: Notification) {
        hosts.terminateAll()
        SessionGroups.shared.windowClosed(groupID)
    }
}

// MARK: - Pane views (kept alive while the layout changes)

/// Owns each pane's terminal or web view, so rearranging the window never restarts a session.
@MainActor
final class PaneHosts: ObservableObject {
    @Published private(set) var ended: [UUID: String] = [:]
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
    }

    // A terminal running Claude Code through the user's login shell, signed in as the pane's account.
    private func makeTerminal(_ pane: SessionPane) -> NSView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let observer = TerminalObserver(paneID: pane.id) { [weak self] id, code in
            self?.ended[id] = code == 0 || code == nil ? "La sesión terminó." : "Claude Code salió con código \(code!)."
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
            args: ["-l", "-i", "-c", pane.shellCommand],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent
        )
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
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), configuration: configuration)
        web.customUserAgent = LovableWeb.userAgent
        web.allowsBackForwardNavigationGestures = true
        let popups = WebPopups()
        self.popups.append(popups)
        web.uiDelegate = popups
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

/// Sign-in with Google and similar open a popup that reports back to the page.
@MainActor
final class WebPopups: NSObject, WKUIDelegate {
    private var windows: [NSWindow] = []

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = LovableWeb.userAgent
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
        windows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let window = windows.first(where: { $0.contentView === webView }) {
            window.close()
            windows.removeAll { $0 === window }
        }
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
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                AddPaneView(groupID: groupID)
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
                PaneHostView(pane: pane, hosts: hosts)
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
            Image(systemName: pane.kind == .local ? "terminal" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(pane.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(Accounts.name(pane.account)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button { SessionGroups.shared.change(groupID) { $0.move(pane.id, by: -1) } } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .help("Mover antes")
            Button { SessionGroups.shared.change(groupID) { $0.move(pane.id, by: 1) } } label: { Image(systemName: "chevron.right") }
                .disabled(index >= count - 1)
                .help("Mover después")
            Button { hosts.reload(pane) } label: { Image(systemName: "arrow.clockwise") }
                .help(pane.kind == .local ? "Reiniciar la sesión" : "Recargar")
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
        case .cloud:
            if let url = pane.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
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

/// A session found on this Mac and the account it belongs to.
struct FoundSession: Identifiable, Sendable {
    let session: LocalSession
    let account: String?
    var id: String { session.transcript }
}

struct AddPaneView: View {
    let groupID: UUID
    @ObservedObject private var groups = SessionGroups.shared
    @ObservedObject private var engine = Engine.shared
    @State private var tab = 0
    @State private var sessions: [FoundSession] = []
    @State private var loading = true
    @State private var query = ""
    @State private var added: Set<String> = []
    @State private var localAccount: String?
    @State private var cloudAccount: String?
    @State private var cloudURL = ""
    @State private var cloudTitle = ""
    @State private var cloudError: String?

    private var group: SessionGroup? { groups.group(groupID) }
    private var full: Bool { group?.isFull ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("En esta Mac").tag(0)
                Text("En la nube (claude.ai/code)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if full {
                Text("El grupo ya tiene 8 sesiones.").font(.caption).foregroundStyle(.orange)
            }
            if tab == 0 { local } else { cloud }
        }
        .padding(14)
        .frame(width: 560, height: 500)
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
            TextField("Buscar por título, proyecto o cuenta", text: $query)
                .textFieldStyle(.roundedBorder)
            if loading {
                ProgressView("Buscando sesiones…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Text("No hay sesiones de Claude Code en esta Mac\(query.isEmpty ? "" : " con ese texto").")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { item in
                    sessionRow(item.session, account: item.account)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("Nueva sesión en una carpeta:").font(.system(size: 12))
                accountPicker($localAccount)
                Spacer()
                Button("Elegir carpeta…") { newLocalSession() }.disabled(full)
            }
        }
    }

    private var filtered: [FoundSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { item in
            item.session.title.lowercased().contains(q) || item.session.project.lowercased().contains(q)
                || Accounts.name(item.account).lowercased().contains(q)
        }
    }

    private func sessionRow(_ session: LocalSession, account: String?) -> some View {
        let isAdded = added.contains(session.transcript)
        return HStack(spacing: 8) {
            Circle().fill(Accounts.tint(account)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text("\(session.project) · \(Accounts.name(account)) · \(session.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(isAdded ? "Agregada" : "Agregar") {
                if groups.add(.local(session, account: account), to: groupID) { added.insert(session.transcript) }
            }
            .disabled(isAdded || full)
        }
    }

    private func newLocalSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Abrir aquí"
        panel.message = "Carpeta donde correrá la nueva sesión de Claude Code"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let profile = Accounts.profile(localAccount)
        let pane = SessionPane(kind: .local, title: folder.lastPathComponent, account: localAccount,
                               directory: folder.path, configDir: profile?.codeConfigDir)
        groups.add(pane, to: groupID)
    }

    private func load() async {
        let (sources, owners, titles) = Accounts.localSources()
        let found = await Task.detached(priority: .userInitiated) { () -> [FoundSession] in
            var all: [FoundSession] = []
            for source in sources {
                for session in LocalSessionScanner.scan(projectsRoot: source.root, configDir: source.configDir, titles: titles, limit: 200) {
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
                Button("Nueva sesión en la nube") {
                    addCloud("https://claude.ai/code", title: cloudTitle.isEmpty ? "Nueva sesión" : cloudTitle)
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
            Divider()
            Button("Eliminar grupo", role: .destructive) { groups.delete(group.id) }
        }
    }
}
