import Foundation
import LoveployCore
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case pending = "Pendientes"
        case all = "Todos"
        var id: String { rawValue }
    }

    @Published private(set) var keys: [APIKeyEntry]
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
    /// Repos the GitHub token can see, most recently pushed first.
    @Published private(set) var githubRepos: [GitHubRepo] = []
    @Published var filter: Filter = .pending
    @Published var showingSettings = false

    private let store = StateStore.default()
    private var githubToken: String?
    private var timer: Timer?
    private static let refreshInterval: TimeInterval = 15 * 60

    init() {
        keys = Keychain.loadKeys()
        githubToken = Keychain.loadGitHubToken()
        state = store.load()
        if keys.isEmpty {
            showingSettings = true
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: - Derived state

    /// Projects that need a deploy and aren't excluded: what the menu bar badge counts.
    var pendingCount: Int {
        rows.filter { $0.state.needsDeploy && !state.excluded.contains($0.id) }.count
    }

    var selectedRows: [ProjectRow] {
        rows.filter(isSelected)
    }

    var visibleRows: [ProjectRow] {
        switch filter {
        case .all: return rows
        case .pending: return rows.filter { $0.state.needsDeploy || isSelected($0) || progress[$0.id] != nil }
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
            // Remember exclusions of pending projects across launches.
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

    func markUpToDate(_ row: ProjectRow) {
        let record = PublishRecord(
            commitSha: row.latestCommitSha,
            publishedAt: Date(),
            url: row.record?.url,
            githubSha: row.githubShaForPublish
        )
        state.records[row.id] = record
        replace(row.with(record: record))
        save()
    }

    func markAllUnknownUpToDate() {
        for row in rows where row.state == .unknown {
            markUpToDate(row)
        }
    }

    func resetExclusions() {
        state.excluded = []
        save()
    }

    // MARK: - API keys

    /// Validates a key against the API before storing it.
    func addKey(label: String, key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaces = try await LovableClient(apiKey: trimmed).listWorkspaces()
        let name = label.isEmpty ? (workspaces.first?.name ?? "Workspace") : label
        keys.append(APIKeyEntry(label: name, key: trimmed))
        Keychain.saveKeys(keys)
        showingSettings = false
        await refresh()
    }

    func removeKey(_ entry: APIKeyEntry) {
        keys.removeAll { $0.id == entry.id }
        Keychain.saveKeys(keys)
        Task { await refresh() }
    }

    // MARK: - GitHub

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
        githubRepos = []
        Keychain.saveGitHubToken(nil)
        Task { await refresh() }
    }

    /// Repos for the "link" menu, closest names first.
    func repoChoices(for row: ProjectRow) -> [GitHubRepo] {
        Array(rankRepos(for: row.summary.name, repos: githubRepos.filter { !$0.isArchived }).prefix(25))
    }

    func link(_ row: ProjectRow, to repo: GitHubRepo) {
        let shares = repo.head?.sha != nil && repo.head?.sha == row.latestCommitSha
        state.repoLinks[row.id] = RepoLink(fullName: repo.fullName, source: shares ? .commit : .manual)
        state.unlinked.remove(row.id)
        save()
        Task { await refresh() }
    }

    func unlink(_ row: ProjectRow) {
        state.repoLinks[row.id] = nil
        state.unlinked.insert(row.id)
        save()
        Task { await refresh() }
    }

    // MARK: - Refresh

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 120 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing, !isDeploying else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var newRows: [ProjectRow] = []
        var newErrors: [String] = []
        var seen = Set<String>()

        for (index, entry) in keys.enumerated() {
            let client = LovableClient(apiKey: entry.key)
            do {
                let workspaces = try await client.listWorkspaces()
                for workspace in workspaces {
                    let projects: [ProjectSummary]
                    do {
                        projects = try await client.listProjects(workspaceIDs: [workspace.id])
                    } catch {
                        // Workspace-scoped keys can see other workspaces but not list their projects.
                        if (error as? LovableAPIError)?.status != 404 && (error as? LovableAPIError)?.status != 403 {
                            newErrors.append("\(workspace.name): \(error.localizedDescription)")
                        }
                        continue
                    }
                    let fresh = projects.filter { seen.insert($0.id).inserted }
                    let details = await fetchDetails(for: fresh.filter(\.isPublished), client: client)
                    for project in fresh {
                        newRows.append(ProjectRow(
                            summary: project,
                            workspaceName: workspace.name,
                            latestCommitSha: details[project.id]?.latestCommitSha,
                            previewUrl: details[project.id]?.previewUrl,
                            record: state.records[project.id],
                            keyIndex: index
                        ))
                    }
                }
            } catch {
                newErrors.append("\(entry.label): \(error.localizedDescription)")
            }
        }

        if let githubToken {
            do {
                newRows = try await attachGitHub(to: newRows, client: GitHubClient(token: githubToken))
            } catch {
                newErrors.append("GitHub: \(error.localizedDescription)")
            }
        }

        rows = newRows.sorted(by: Self.order)
        errors = newErrors
        lastRefresh = Date()
    }

    /// Links each project to its repo (remembering auto-matches), reads the branch head,
    /// and lists the commits made since the last publish.
    private func attachGitHub(to rows: [ProjectRow], client: GitHubClient) async throws -> [ProjectRow] {
        if githubLogin == nil {
            githubLogin = try? await client.viewerLogin()
        }
        let repos = try await client.repositories()
        githubRepos = repos
        let reposByName = Dictionary(repos.map { ($0.fullName.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var linked: [(row: ProjectRow, link: RepoLink, repo: GitHubRepo?)] = []
        var result: [ProjectRow] = []
        for row in rows {
            var link = state.repoLinks[row.id]
            if link == nil, !state.unlinked.contains(row.id) {
                link = matchRepo(projectName: row.summary.name, latestCommitSha: row.latestCommitSha, repos: repos)
            }
            guard var link else {
                result.append(row)
                continue
            }
            let repo = reposByName[link.fullName.lowercased()]
            // Seeing Lovable's commit at the repo head proves the two share SHAs.
            if link.source != .commit, link.branch == nil, let sha = row.latestCommitSha, repo?.head?.sha == sha {
                link.source = .commit
            }
            if state.repoLinks[row.id] != link {
                state.repoLinks[row.id] = link
            }
            linked.append((row, link, repo))
        }
        save()

        let statuses = await withTaskGroup(of: (String, GitHubStatus).self) { group in
            var queue = linked[...]
            var statuses: [String: GitHubStatus] = [:]
            func startNext() {
                guard let item = queue.popFirst() else { return }
                group.addTask { (item.row.id, await Self.githubStatus(row: item.row, link: item.link, repo: item.repo, client: client)) }
            }
            for _ in 0..<4 { startNext() }
            while let item = await group.next() {
                statuses[item.0] = item.1
                startNext()
            }
            return statuses
        }

        for item in linked {
            result.append(ProjectRow(
                summary: item.row.summary,
                workspaceName: item.row.workspaceName,
                latestCommitSha: item.row.latestCommitSha,
                previewUrl: item.row.previewUrl,
                record: item.row.record,
                keyIndex: item.row.keyIndex,
                github: statuses[item.row.id]
            ))
        }
        return result
    }

    private nonisolated static func githubStatus(row: ProjectRow, link: RepoLink, repo: GitHubRepo?, client: GitHubClient) async -> GitHubStatus {
        let url = repo?.url ?? "https://github.com/\(link.fullName)"
        var head = repo?.head
        if let branch = link.branch, branch != repo?.defaultBranch {
            head = try? await client.branchHead(repo: link.fullName, branch: branch)
        }
        guard let head else {
            let error = repo == nil ? "sin acceso al repo con este token" : "no se pudo leer la rama"
            return GitHubStatus(link: link, repoURL: url, head: nil, error: error)
        }

        // Which commit went live last time, in GitHub terms.
        let published = row.record?.githubSha ?? (link.source == .commit ? row.record?.commitSha : nil)
        var newCommits: [GitHubCommit]?
        if let published {
            if published == head.sha {
                newCommits = []
            } else if let comparison = try? await client.compare(repo: link.fullName, base: published, head: head.sha) {
                newCommits = comparison.commits
            }
        }
        return GitHubStatus(link: link, repoURL: url, head: head, newCommits: newCommits)
    }

    /// Fetches `latest_commit_sha` for each project, six requests at a time.
    private func fetchDetails(for projects: [ProjectSummary], client: LovableClient) async -> [String: ProjectDetail] {
        await withTaskGroup(of: ProjectDetail?.self) { group in
            var results: [String: ProjectDetail] = [:]
            var queue = projects[...]
            func startNext() {
                guard let project = queue.popFirst() else { return }
                group.addTask { try? await client.getProject(id: project.id) }
            }
            for _ in 0..<6 { startNext() }
            while let detail = await group.next() {
                if let detail { results[detail.id] = detail }
                startNext()
            }
            return results
        }
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
        return a.summary.displayName.localizedCaseInsensitiveCompare(b.summary.displayName) == .orderedAscending
    }

    // MARK: - Deploy

    func deploySelected() {
        let targets = selectedRows
        guard !targets.isEmpty, !isDeploying else { return }
        let token = githubToken
        let jobs = targets.compactMap { row -> DeployJob? in
            guard keys.indices.contains(row.keyIndex) else { return nil }
            return DeployJob(
                projectID: row.id,
                client: LovableClient(apiKey: keys[row.keyIndex].key),
                githubSha: Self.githubShaResolver(for: row, token: token)
            )
        }
        isDeploying = true
        progress = [:]

        Task {
            await Deployer().run(
                jobs: jobs,
                onUpdate: { [weak self] id, value in await self?.setProgress(value, for: id) },
                onRecord: { [weak self] id, record in await self?.storeRecord(record, for: id) }
            )
            finishDeploy()
        }
    }

    /// What GitHub SHA to record when a project is published. With shared SHAs it's
    /// Lovable's own commit; otherwise the branch head right before publishing.
    private static func githubShaResolver(for row: ProjectRow, token: String?) -> (@Sendable (String?) async -> String?)? {
        guard let github = row.github, let token else { return nil }
        let repo = github.link.fullName
        let branch = github.link.branch
        let shares = github.sharesCommits
        let fallback = github.head?.sha
        return { lovableSha in
            if shares, let lovableSha { return lovableSha }
            // "HEAD" resolves to the default branch.
            let head = try? await GitHubClient(token: token).branchHead(repo: repo, branch: branch ?? "HEAD")
            return head?.sha ?? fallback
        }
    }

    private func setProgress(_ value: DeployProgress, for id: String) {
        progress[id] = value
    }

    private func storeRecord(_ record: PublishRecord, for id: String) {
        state.records[id] = record
        if let row = rows.first(where: { $0.id == id }) {
            replace(row.with(record: record))
        }
        save()
    }

    private func finishDeploy() {
        isDeploying = false
        overrides = [:]
        let succeeded = progress.values.filter { if case .completed = $0 { return true } else { return false } }.count
        let failed = progress.count - succeeded
        notify(
            title: failed == 0 ? "Despliegue terminado" : "Despliegue con errores",
            body: failed == 0
                ? "\(succeeded) proyecto(s) publicados."
                : "\(succeeded) publicados, \(failed) con error."
        )
        Task { await refresh() }
    }

    // MARK: - Helpers

    private func replace(_ row: ProjectRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        }
    }

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
