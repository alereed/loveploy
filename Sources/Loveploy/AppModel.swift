import AppKit
import Foundation
import LoveployCore
import ServiceManagement
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
    /// What Turbo is waiting on; published so the menu can show when each project goes out.
    @Published private(set) var turboPlanner: TurboPlanner
    @Published var filter: Filter = .pending
    @Published var showingSettings = false

    private let session: LovableSession
    private let client: LovableWebClient
    private let store = StateStore.default()
    private var githubToken: String?
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
        let state = store.load()
        self.state = state
        turboPlanner = TurboPlanner(settleDelay: TimeInterval(state.turboDelayMinutes * 60))

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
        case .ios: return rows.filter { $0.ios != nil }
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
                    guard row.details?.isPublished == true else { return row }
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

    /// TestFlight and App Store status for projects that build for iOS.
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

    var iosNeedingUpload: Int {
        rows.filter { $0.ios?.testFlightNeedsUpload == true }.count
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
        guard state.turbo, isSignedIn, !isDeploying else { return }
        let ready = turboPlanner.ready(rows: rows, excluded: state.excluded, now: Date())
        deploy(ready, automatic: true)
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

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errors.append("Inicio de sesión: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
