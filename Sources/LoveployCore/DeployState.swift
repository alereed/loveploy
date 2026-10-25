import Foundation

/// Where a project stands relative to its published version.
public enum DeployState: String, Sendable, CaseIterable {
    /// The live version is the latest commit.
    case upToDate
    /// There are changes (commits or secrets) that aren't live yet.
    case outdated
    /// Published, but Lovable didn't say which commit is live.
    case unknown
    /// Never published.
    case unpublished

    /// Whether the project belongs in the default deploy list.
    public var needsDeploy: Bool { self == .outdated }

    public var label: String {
        switch self {
        case .upToDate: return "Al día"
        case .outdated: return "Desactualizado"
        case .unknown: return "Sin datos"
        case .unpublished: return "Sin publicar"
        }
    }

    /// The same rule lovable.dev's Publish button uses to offer "Update".
    public static func evaluate(_ details: ProjectDetails?, listedAsPublished: Bool? = nil) -> DeployState {
        guard let details else {
            return listedAsPublished == false ? .unpublished : .unknown
        }
        guard details.isPublished ?? listedAsPublished ?? false else { return .unpublished }
        guard let published = details.publishedDeployment, let publishedSha = published.commitSha else { return .unknown }
        if published.secretsChanged {
            return .outdated
        }
        guard let latest = details.latestCommitSha else { return .upToDate }
        return latest == publishedSha || latest == published.headCommitSha ? .upToDate : .outdated
    }
}

/// The project's GitHub repo, as Lovable's git sync reports it.
public struct GitStatus: Hashable, Sendable {
    public let repo: String
    public let branch: String?
    public let url: String?
    /// Lovable vs. the repo: in_sync, lovable_ahead, remote_ahead, diverged, unavailable.
    public let syncState: String?
    public let ahead: Int?
    public let behind: Int?
    /// Commits on the repo since the published version, newest first. Needs a GitHub token.
    public let newCommits: [GitHubCommit]?

    public init(repo: String, branch: String? = nil, url: String? = nil, syncState: String? = nil, ahead: Int? = nil, behind: Int? = nil, newCommits: [GitHubCommit]? = nil) {
        self.repo = repo
        self.branch = branch
        self.url = url
        self.syncState = syncState
        self.ahead = ahead
        self.behind = behind
        self.newCommits = newCommits
    }

    /// GitHub has commits Lovable hasn't pulled, so publishing won't include them yet.
    public var remoteAhead: Bool { syncState == "remote_ahead" || syncState == "diverged" }

    public func with(newCommits: [GitHubCommit]?) -> GitStatus {
        GitStatus(repo: repo, branch: branch, url: url, syncState: syncState, ahead: ahead, behind: behind, newCommits: newCommits)
    }
}

/// A project plus everything the menu needs to show it.
public struct ProjectRow: Identifiable, Hashable, Sendable {
    public let summary: ProjectSummary
    public let workspace: Workspace
    public let details: ProjectDetails?
    public let git: GitStatus?
    /// The iOS app, when the project has one.
    public let ios: IOSStatus?
    /// Why the details couldn't be read, if they couldn't.
    public let error: String?

    public init(summary: ProjectSummary, workspace: Workspace, details: ProjectDetails?, git: GitStatus? = nil, ios: IOSStatus? = nil, error: String? = nil) {
        self.summary = summary
        self.workspace = workspace
        self.details = details
        self.git = git
        self.ios = ios
        self.error = error
    }

    public var id: String { summary.id }
    public var state: DeployState { DeployState.evaluate(details, listedAsPublished: summary.isPublished) }
    public var publishedSha: String? { details?.publishedDeployment?.commitSha }
    public var liveURL: String? { details?.url }

    public func with(details: ProjectDetails?) -> ProjectRow {
        ProjectRow(summary: summary, workspace: workspace, details: details, git: git, ios: ios, error: nil)
    }

    public func with(git: GitStatus?) -> ProjectRow {
        ProjectRow(summary: summary, workspace: workspace, details: details, git: git, ios: ios, error: error)
    }

    public func with(ios: IOSStatus?) -> ProjectRow {
        ProjectRow(summary: summary, workspace: workspace, details: details, git: git, ios: ios, error: error)
    }
}

/// Decides which projects "Publicar" will deploy.
///
/// By default a project is included when it's outdated and the user hasn't excluded
/// it. `overrides` holds one-off choices for this session (forcing an up-to-date or
/// unpublished project in).
public func isIncluded(_ row: ProjectRow, excluded: Set<String>, overrides: [String: Bool]) -> Bool {
    if let override = overrides[row.id] {
        return override
    }
    return row.state.needsDeploy && !excluded.contains(row.id)
}
