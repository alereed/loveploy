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
    @Published var filter: Filter = .pending
    @Published var showingSettings = false

    private let store = StateStore.default()
    private var timer: Timer?
    private static let refreshInterval: TimeInterval = 15 * 60

    init() {
        keys = Keychain.loadKeys()
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
        let record = PublishRecord(commitSha: row.latestCommitSha, publishedAt: Date(), url: row.record?.url)
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

        rows = newRows.sorted(by: Self.order)
        errors = newErrors
        lastRefresh = Date()
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
        let jobs = targets.compactMap { row -> (projectID: String, client: LovableClient)? in
            guard keys.indices.contains(row.keyIndex) else { return nil }
            return (row.id, LovableClient(apiKey: keys[row.keyIndex].key))
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
