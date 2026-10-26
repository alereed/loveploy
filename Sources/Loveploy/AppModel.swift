import AppKit
import Foundation
import LoveployCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case pending = "Pendientes"
        case ios = "iOS"
        case all = "Todos"
        var id: String { rawValue }
    }

    @Published private(set) var account: String?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var rows: [ProjectRow] = []
    @Published private(set) var state: LoveployState
    /// One-off include/skip choices for projects that aren't pending (cleared after a deploy).
    @Published private(set) var overrides: [String: Bool] = [:]
    @Published private(set) var progress: [String: DeployProgress] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDeploying = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var githubLogin: String?
    /// TestFlight builds asked to the hub from this session, by app slug.
    @Published private(set) var testFlightRequests: [String: TestFlightRequest] = [:]
    /// iOS apps in the Blender Dev Apps catalog, once connected.
    @Published private(set) var hubAppCount: Int?
    /// Result of the last App Store / Android action per app slug.
    @Published private(set) var hubNotices: [String: String] = [:]
    /// What Turbo asks TestFlight for when TestFlight is automatic.
    @Published private(set) var testFlightAutopilot: TestFlightAutopilot
    /// What Turbo is waiting on; published so the menu can show when each project goes out.
    @Published private(set) var turboPlanner: TurboPlanner
    @Published var filter: Filter = .pending
    @Published var showingSettings = false

    private let session: LovableSession
    private let client: LovableWebClient
    private let store = StateStore.default()
    private var githubToken: String?
    private var hubCredentials: Keychain.HubCredentials?
    private var loginWindow: LoginWindowController?
    private var timer: Timer?
    private static let refreshInterval: TimeInterval = 15 * 60
    /// Turbo checks more often so changes go out soon after they settle.
    private static let turboRefreshInterval: TimeInterval = 2 * 60

    init() {
        let credentials = Keychain.loadCredentials()
        session = LovableSession(
            credentials: credentials,
            fallback: { try await LovableWeb.refreshInBackground() },
            onChange: { Keychain.saveCredentials($0) }
        )
        client = LovableWebClient(session: session)
        account = credentials?.email
        isSignedIn = credentials != nil
        githubToken = Keychain.loadGitHubToken()
        hubCredentials = Keychain.loadHub()
        let state = store.load()
        self.state = state
        turboPlanner = TurboPlanner(settleDelay: TimeInterval(state.turboDelayMinutes * 60))
        testFlightAutopilot = TestFlightAutopilot(settleDelay: TimeInterval(state.turboDelayMinutes * 60))

        scheduleRefreshTimer()
        Task { await refresh() }
    }

    // MARK: - Derived state

    /// Outdated projects that aren't excluded: what the menu bar badge counts.
    var pendingCount: Int {
        rows.filter { $0.state.needsDeploy && !state.excluded.contains($0.id) }.count
    }

    var selectedRows: [ProjectRow] {
        rows.filter(isSelected)
    }

    var visibleRows: [ProjectRow] {
        switch filter {
        case .all: return rows
        case .ios: return rows.filter(\.hasIOS)
        case .pending: return rows.filter { $0.state.needsDeploy || isSelected($0) || progress[$0.id] != nil || $0.git?.remoteAhead == true }
        }
    }

    func count(_ deployState: DeployState) -> Int {
        rows.filter { $0.state == deployState }.count
    }

    func isSelected(_ row: ProjectRow) -> Bool {
        isIncluded(row, excluded: state.excluded, overrides: overrides)
    }

    // MARK: - Selection

    func setSelected(_ selected: Bool, for row: ProjectRow) {
        if row.state.needsDeploy {
            // Remember exclusions of outdated projects across launches.
            if selected {
                state.excluded.remove(row.id)
            } else {
                state.excluded.insert(row.id)
            }
            overrides[row.id] = nil
            save()
        } else {
            overrides[row.id] = selected ? true : nil
        }
    }

    func selectAllVisible(_ selected: Bool) {
        for row in visibleRows {
            setSelected(selected, for: row)
        }
    }

    func resetExclusions() {
        state.excluded = []
        save()
    }

    // MARK: - Lovable session

    func signIn() {
        if let loginWindow {
            loginWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = LoginWindowController { [weak self] credentials in
            guard let self else { return }
            self.loginWindow = nil
            Task {
                await self.session.signIn(credentials)
                self.account = credentials.email
                self.isSignedIn = true
                self.showingSettings = false
                await self.refresh()
            }
        }
        loginWindow = controller
        controller.start()
    }

    func signOut() {
        Task {
            await session.signOut()
            await LovableWeb.clearWebsiteData()
            account = nil
            isSignedIn = false
            rows = []
            errors = []
        }
    }

    // MARK: - GitHub (optional)

    var hasGitHub: Bool { githubToken != nil }

    func connectGitHub(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        githubLogin = try await GitHubClient(token: trimmed).viewerLogin()
        githubToken = trimmed
        Keychain.saveGitHubToken(trimmed)
        await refresh()
    }

    func disconnectGitHub() {
        githubToken = nil
        githubLogin = nil
        Keychain.saveGitHubToken(nil)
        Task { await refresh() }
    }

    // MARK: - Refresh

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 120 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard isSignedIn, !isRefreshing, !isDeploying else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var newErrors: [String] = []
        var listed: [(ProjectSummary, Workspace)] = []
        do {
            var seen = Set<String>()
            for workspace in try await client.workspaces() {
                do {
                    for project in try await client.projects(workspaceID: workspace.id) where seen.insert(project.id).inserted {
                        listed.append((project, workspace))
                    }
                } catch {
                    newErrors.append("\(workspace.displayName): \(error.localizedDescription)")
                }
            }
        } catch {
            handle(error, into: &newErrors)
            errors = newErrors
            return
        }

        var newRows = await loadDetails(for: listed)
        newRows = await attachGit(to: newRows)
        newRows = await attachIOS(to: newRows)
        if let hub {
            do {
                let apps = try await hub.panel()
                hubAppCount = apps.filter(\.hasIOS).count
                newRows = newRows.map { $0.with(hub: hubApps(forRepo: $0.git?.repo, in: apps)) }
            } catch {
                newErrors.append("Blender Dev Apps: \(error.localizedDescription)")
            }
        }
        if githubToken != nil, githubLogin == nil {
            githubLogin = try? await GitHubClient(token: githubToken!).viewerLogin()
        }

        rows = newRows.sorted(by: Self.order)
        errors = newErrors
        lastRefresh = Date()
        runTurbo()
    }

    /// `GET /projects/{id}/details` for every project, eight at a time.
    private func loadDetails(for listed: [(ProjectSummary, Workspace)]) async -> [ProjectRow] {
        let client = client
        return await withTaskGroup(of: ProjectRow.self) { group in
            var queue = listed[...]
            var rows: [ProjectRow] = []
            func startNext() {
                guard let item = queue.popFirst() else { return }
                let (summary, workspace) = item
                group.addTask {
                    do {
                        let details = try await client.details(projectID: summary.id)
                        return ProjectRow(summary: summary, workspace: workspace, details: details)
                    } catch {
                        return ProjectRow(summary: summary, workspace: workspace, details: nil, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<8 { startNext() }
            while let row = await group.next() {
                rows.append(row)
                startNext()
            }
            return rows
        }
    }

    /// The repo each published project syncs with, how it compares to Lovable, and
    /// (with a GitHub token) the commits that aren't live yet.
    private func attachGit(to rows: [ProjectRow]) async -> [ProjectRow] {
        let client = client
        let github = githubToken.map { GitHubClient(token: $0) }
        return await withTaskGroup(of: ProjectRow.self) { group in
            var queue = rows[...]
            var result: [ProjectRow] = []
            func startNext() {
                guard let row = queue.popFirst() else { return }
                group.addTask {
                    guard let info = try? await client.gitSync(workspaceID: row.workspace.id, projectID: row.id),
                          let repo = info.fullName, info.isGitHub else { return row }
                    let sync = try? await client.gitSyncStatus(workspaceID: row.workspace.id, projectID: row.id)
                    var git = GitStatus(
                        repo: repo,
                        branch: info.config?.mainBranch,
                        url: info.config?.repoUrl ?? "https://github.com/\(repo)",
                        syncState: sync?.state,
                        ahead: sync?.ahead,
                        behind: sync?.behind
                    )
                    if let github, let published = row.publishedSha, row.state == .outdated || git.remoteAhead {
                        let head = git.branch ?? row.details?.latestCommitSha ?? "HEAD"
                        if let comparison = try? await github.compare(repo: repo, base: published, head: head) {
                            git = git.with(newCommits: comparison.commits)
                        }
                    }
                    return row.with(git: git)
                }
            }
            for _ in 0..<6 { startNext() }
            while let row = await group.next() {
                result.append(row)
                startNext()
            }
            return result
        }
    }

    /// TestFlight and App Store status for projects whose iOS app Lovable builds.
    private func attachIOS(to rows: [ProjectRow]) async -> [ProjectRow] {
        let client = client
        return await withTaskGroup(of: ProjectRow.self) { group in
            var queue = rows[...]
            var result: [ProjectRow] = []
            func startNext() {
                guard let row = queue.popFirst() else { return }
                group.addTask {
                    guard let runs = try? await client.iosBuildRuns(projectID: row.id), !runs.isEmpty else { return row }
                    let builds = (try? await client.storeBuilds(projectID: row.id)) ?? []
                    let ios = IOSStatus.evaluate(runs: runs, builds: builds, latestCommitSha: row.details?.latestCommitSha)
                    return row.with(ios: ios)
                }
            }
            for _ in 0..<8 { startNext() }
            while let row = await group.next() {
                result.append(row)
                startNext()
            }
            return result
        }
    }

    // MARK: - Blender Dev Apps (TestFlight through the hub)

    enum TestFlightRequest: Equatable {
        case sending
        case sent
        case failed(String)
    }

    var hasHub: Bool { hubCredentials != nil }

    private var hub: DevOpsHub? {
        hubCredentials.map { DevOpsHub(endpoint: $0.endpoint, key: $0.key) }
    }

    func connectHub(url: String, key: String) async throws {
        guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              endpoint.scheme == "https" else {
            throw HubError(message: "Escribe la URL https del MCP de DevOps.")
        }
        let credentials = Keychain.HubCredentials(endpoint: endpoint, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        let apps = try await DevOpsHub(endpoint: credentials.endpoint, key: credentials.key).panel()
        hubCredentials = credentials
        hubAppCount = apps.filter(\.hasIOS).count
        Keychain.saveHub(credentials)
        await refresh()
    }

    func disconnectHub() {
        hubCredentials = nil
        hubAppCount = nil
        Keychain.saveHub(nil)
        Task { await refresh() }
    }

    /// Catalog apps with native changes no TestFlight build has.
    var testFlightCandidates: [HubApp] {
        rows.flatMap(\.hub).filter { $0.needsTestFlight && testFlightRequests[$0.slug] != .sending }
    }

    /// Asks the hub for TestFlight builds (Xcode Cloud). It costs Mac hours and has a daily
    /// limit, so it always asks first and says how many went out today.
    /// TestFlight runs without asking and without the daily limit.
    var testFlightAutomatic: Bool {
        get { state.testFlightAutomatic }
        set {
            state.testFlightAutomatic = newValue
            save()
            if newValue { runTurbo() }
        }
    }

    func requestTestFlight(_ apps: [HubApp], automatic: Bool = false) {
        guard let hub, !apps.isEmpty else { return }
        // Mark them now, so the next Turbo pass doesn't ask for the same commit again.
        for app in apps { testFlightAutopilot.recordRequest(app) }
        let ask = !state.testFlightAutomatic && !automatic
        let github = githubToken.map { GitHubClient(token: $0) }
        let repos = Dictionary(rows.flatMap { row in row.hub.map { ($0.slug, row.git?.repo) } }, uniquingKeysWith: { first, _ in first })

        Task {
            let today = (try? await hub.recentBuilds()).map { xcodeCloudBuildsToday($0) }
            var checks: [String] = []
            if let github {
                for app in apps {
                    guard let commit = app.iosPendienteCommit, let repo = repos[app.slug] ?? nil else { continue }
                    if let runs = try? await github.runs(repo: repo, commit: commit) {
                        checks.append("\(app.label): \(Self.checksSummary(runs))")
                    }
                }
            }
            if ask {
                guard confirmTestFlight(apps, today: today, checks: checks) else { return }
            }

            for app in apps {
                testFlightRequests[app.slug] = .sending
                do {
                    _ = try await hub.requestTestFlight(app: app.slug)
                    testFlightRequests[app.slug] = .sent
                } catch {
                    testFlightRequests[app.slug] = .failed(error.localizedDescription)
                }
            }
            let sent = apps.filter { testFlightRequests[$0.slug] == .sent }.map(\.label)
            notify(
                title: automatic ? "⚡ Turbo pidió TestFlight" : "TestFlight pedido",
                body: sent.isEmpty ? "No se pudo pedir ningún build." : sent.joined(separator: ", ")
            )
            await refresh()
        }
    }

    /// Attaches the newest valid build and sends the App Store version to Apple's review.
    /// Public and irreversible, so it always asks, whatever the TestFlight setting.
    func submitForReview(_ app: HubApp) {
        guard let hub else { return }
        let alert = NSAlert()
        alert.messageText = "¿Enviar \(app.label) a revisión de App Store?"
        alert.informativeText = """
        Se adjunta el build válido más reciente a la versión \(app.appStore?.version ?? "") y se envía a Apple.
        Es público y no se puede deshacer desde aquí.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Enviar a revisión")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        hubNotices[app.slug] = "Enviando a revisión…"
        Task {
            do {
                _ = try await hub.submitForReview(app: app.slug)
                hubNotices[app.slug] = "Enviada a revisión de Apple"
                notify(title: "App Store: \(app.label)", body: "Enviada a revisión.")
            } catch {
                hubNotices[app.slug] = "No se pudo enviar a revisión: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    /// Android build through the hub (beta track of Google Play).
    func requestAndroid(_ app: HubApp) {
        guard let hub else { return }
        hubNotices[app.slug] = "Pidiendo build de Android…"
        Task {
            do {
                _ = try await hub.requestAndroid(app: app.slug)
                hubNotices[app.slug] = "Build de Android pedido"
                notify(title: "Android: \(app.label)", body: "Build pedido a Blender Dev Apps.")
            } catch {
                hubNotices[app.slug] = "No se pudo pedir Android: \(error.localizedDescription)"
            }
        }
    }

    private func confirmTestFlight(_ apps: [HubApp], today: Int?, checks: [String]) -> Bool {
        let limit = DevOpsHub.dailyTestFlightLimit
        let overLimit = today.map { $0 + apps.count > limit } ?? false
        let alert = NSAlert()
        alert.messageText = apps.count == 1
            ? "¿Pedir TestFlight de \(apps[0].label)?"
            : "¿Pedir TestFlight de \(apps.count) apps?"
        var lines = [
            apps.map { app in "• \(app.label)" + (app.iosPendienteMensaje.map { ": «\($0)»" } ?? "") }.joined(separator: "\n"),
            "",
            "Va por Xcode Cloud (gasta horas de la membresía).",
            today.map { "Van \($0) de \(limit) hoy." } ?? "No se pudo leer cuántos van hoy.",
        ]
        if !checks.isEmpty {
            lines.append("")
            lines.append("Checks de GitHub en el commit pendiente:")
            lines.append(contentsOf: checks)
        }
        if overLimit {
            lines.append("")
            lines.append("⚠️ Con estos se pasa del tope de \(limit) al día.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = overLimit ? .critical : .informational
        alert.addButton(withTitle: overLimit ? "Pedir de todos modos" : "Pedir TestFlight")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func checksSummary(_ runs: [WorkflowRun]) -> String {
        guard !runs.isEmpty else { return "sin checks" }
        if runs.contains(where: { !$0.isFinished }) { return "corriendo" }
        let failed = runs.filter { $0.conclusion == "failure" }.compactMap(\.name)
        return failed.isEmpty ? "verde ✓" : "rojo ✗ (\(failed.joined(separator: ", ")))"
    }

    var iosNeedingUpload: Int {
        rows.filter(\.iosNeedsBuild).count
    }

    private static func order(_ a: ProjectRow, _ b: ProjectRow) -> Bool {
        func rank(_ state: DeployState) -> Int {
            switch state {
            case .outdated: return 0
            case .unknown: return 1
            case .upToDate: return 2
            case .unpublished: return 3
            }
        }
        if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
        return a.summary.label.localizedCaseInsensitiveCompare(b.summary.label) == .orderedAscending
    }

    private func handle(_ error: Error, into errors: inout [String]) {
        if error is SessionError || (error as? LovableError)?.isAuthFailure == true {
            isSignedIn = false
            rows = []
        }
        errors.append(error.localizedDescription)
    }

    // MARK: - Deploy

    func deploySelected() {
        deploy(selectedRows.map(\.id), automatic: false)
    }

    private func deploy(_ ids: [String], automatic: Bool) {
        guard !ids.isEmpty, !isDeploying else { return }
        isDeploying = true
        progress = [:]
        let client = client
        // The version each project had when it went out, so Turbo doesn't retry a failed one.
        let versions = Dictionary(uniqueKeysWithValues: rows.filter { ids.contains($0.id) }.map { ($0.id, TurboPlanner.version(of: $0)) })

        Task {
            await Deployer().run(projectIDs: ids, client: client) { [weak self] id, value in
                await self?.setProgress(value, for: id)
            }
            finishDeploy(automatic: automatic, versions: versions)
        }
    }

    private func setProgress(_ value: DeployProgress, for id: String) {
        progress[id] = value
    }

    private func finishDeploy(automatic: Bool, versions: [String: String]) {
        isDeploying = false
        overrides = [:]
        var names: [String] = []
        var failed = 0
        for (id, result) in progress {
            if case .completed = result {
                if let version = versions[id] {
                    turboPlanner.recordSuccess(projectID: id, version: version)
                }
                names.append(rows.first { $0.id == id }?.summary.label ?? id)
            } else if let version = versions[id] {
                turboPlanner.recordFailure(projectID: id, version: version)
                failed += 1
            }
        }
        let succeeded = names.count
        let title: String
        if automatic {
            title = failed == 0 ? "⚡ Turbo publicó \(succeeded) proyecto(s)" : "⚡ Turbo: \(failed) con error"
        } else {
            title = failed == 0 ? "Despliegue terminado" : "Despliegue con errores"
        }
        let body = failed == 0
            ? names.sorted().joined(separator: ", ")
            : "\(succeeded) publicados, \(failed) con error. Turbo no reintentará esa versión."
        notify(title: title, body: body)
        Task { await refresh() }
    }

    // MARK: - Turbo

    var turbo: Bool {
        get { state.turbo }
        set {
            state.turbo = newValue
            save()
            scheduleRefreshTimer()
            if newValue {
                Task { await refresh() }
            }
        }
    }

    var turboDelayMinutes: Int {
        get { state.turboDelayMinutes }
        set {
            state.turboDelayMinutes = newValue
            turboPlanner.settleDelay = TimeInterval(newValue * 60)
            testFlightAutopilot.settleDelay = TimeInterval(newValue * 60)
            save()
            runTurbo()
        }
    }

    /// When Turbo will publish this project, if it's waiting.
    func turboPublishDate(for row: ProjectRow) -> Date? {
        guard state.turbo else { return nil }
        return turboPlanner.publishDate(for: row, excluded: state.excluded)
    }

    func turboGaveUp(on row: ProjectRow) -> Bool {
        state.turbo && turboPlanner.didFail(row)
    }

    private func runTurbo() {
        guard state.turbo, isSignedIn else { return }
        if !isDeploying {
            let ready = turboPlanner.ready(rows: rows, excluded: state.excluded, now: Date())
            deploy(ready, automatic: true)
        }
        if state.testFlightAutomatic, hasHub {
            let apps = rows.filter { !state.excluded.contains($0.id) }.flatMap(\.hub)
            let unique = Dictionary(apps.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first }).values
            let ready = testFlightAutopilot.ready(apps: Array(unique), now: Date())
            requestTestFlight(ready, automatic: true)
        }
    }

    private func scheduleRefreshTimer() {
        timer?.invalidate()
        let interval = state.turbo ? Self.turboRefreshInterval : Self.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    // MARK: - Helpers

    private func save() {
        do {
            try store.save(state)
        } catch {
            errors.append("No se pudo guardar el estado: \(error.localizedDescription)")
        }
    }

    private func notify(title: String, body: String) {
        // Notifications need a real app bundle; skip them under `swift run`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
