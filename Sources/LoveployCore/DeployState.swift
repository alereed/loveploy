import Foundation

/// Where a project stands relative to its published version.
public enum DeployState: String, Sendable, CaseIterable {
    /// The live version matches the latest commit Loveploy published.
    case upToDate
    /// There are commits after the version Loveploy last published.
    case outdated
    /// Published, but not by Loveploy, so we can't tell which commit is live.
    case unknown
    /// Never published.
    case unpublished

    /// Whether the project belongs in the default deploy list.
    public var needsDeploy: Bool { self == .outdated || self == .unknown }

    public var label: String {
        switch self {
        case .upToDate: return "Al día"
        case .outdated: return "Desactualizado"
        case .unknown: return "Sin registro"
        case .unpublished: return "Sin publicar"
        }
    }

    public static func evaluate(
        isPublished: Bool,
        latestCommitSha: String?,
        lastEditedAt: Date?,
        record: PublishRecord?
    ) -> DeployState {
        guard isPublished else { return .unpublished }
        guard let record else { return .unknown }
        if let latest = latestCommitSha, let published = record.commitSha {
            return latest == published ? .upToDate : .outdated
        }
        // No commit to compare against: fall back to edit time.
        if let lastEditedAt, lastEditedAt > record.publishedAt {
            return .outdated
        }
        return .upToDate
    }
}

/// A project plus everything the menu needs to show it.
public struct ProjectRow: Identifiable, Hashable, Sendable {
    public let summary: ProjectSummary
    public let workspaceName: String
    public let latestCommitSha: String?
    public let previewUrl: String?
    public let record: PublishRecord?
    /// Index of the API key that can reach this project.
    public let keyIndex: Int

    public init(
        summary: ProjectSummary,
        workspaceName: String,
        latestCommitSha: String?,
        previewUrl: String? = nil,
        record: PublishRecord?,
        keyIndex: Int = 0
    ) {
        self.summary = summary
        self.workspaceName = workspaceName
        self.latestCommitSha = latestCommitSha
        self.previewUrl = previewUrl
        self.record = record
        self.keyIndex = keyIndex
    }

    public var id: String { summary.id }

    public var state: DeployState {
        DeployState.evaluate(
            isPublished: summary.isPublished,
            latestCommitSha: latestCommitSha,
            lastEditedAt: summary.lastEditedAt,
            record: record
        )
    }
}

/// Decides which projects "Publicar" will deploy.
///
/// By default a project is included when it needs a deploy and the user hasn't
/// excluded it. `overrides` holds one-off choices for this session (for example,
/// forcing an up-to-date project or skipping one just this time).
public func isIncluded(_ row: ProjectRow, excluded: Set<String>, overrides: [String: Bool]) -> Bool {
    if let override = overrides[row.id] {
        return override
    }
    return row.state.needsDeploy && !excluded.contains(row.id)
}

extension ProjectRow {
    /// The same row with a new publish record (after a deploy or "mark as up to date").
    public func with(record: PublishRecord?) -> ProjectRow {
        ProjectRow(
            summary: summary,
            workspaceName: workspaceName,
            latestCommitSha: latestCommitSha,
            previewUrl: previewUrl,
            record: record,
            keyIndex: keyIndex
        )
    }
}
