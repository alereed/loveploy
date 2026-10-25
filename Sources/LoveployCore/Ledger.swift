import Foundation

/// Lovable's API does not say which commit is live, so Loveploy keeps its own record
/// of what it published. Comparing that against `latest_commit_sha` tells us which
/// projects are behind.
public struct PublishRecord: Codable, Hashable, Sendable {
    /// Lovable's `latest_commit_sha` when it was published.
    public var commitSha: String?
    public var publishedAt: Date
    public var url: String?
    /// Head of the linked GitHub branch when it was published.
    public var githubSha: String?

    public init(commitSha: String?, publishedAt: Date, url: String? = nil, githubSha: String? = nil) {
        self.commitSha = commitSha
        self.publishedAt = publishedAt
        self.url = url
        self.githubSha = githubSha
    }
}

/// Which GitHub repo (and branch) a Lovable project syncs with.
public struct RepoLink: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Lovable's latest commit was found as the head of this repo, so the SHAs are shared.
        case commit
        /// The repo name matches the project name.
        case name
        /// Chosen by the user.
        case manual
    }

    public var fullName: String
    /// nil means the repo's default branch.
    public var branch: String?
    public var source: Source

    public init(fullName: String, branch: String? = nil, source: Source) {
        self.fullName = fullName
        self.branch = branch
        self.source = source
    }
}

/// Everything Loveploy persists between launches (except API keys, which live in the Keychain).
public struct LoveployState: Codable, Equatable, Sendable {
    /// Last successful publish per project ID.
    public var records: [String: PublishRecord] = [:]
    /// Projects the user chose to leave out of "Publicar todo".
    public var excluded: Set<String> = []
    /// GitHub repo per project ID.
    public var repoLinks: [String: RepoLink] = [:]
    /// Projects the user explicitly unlinked, so auto-matching leaves them alone.
    public var unlinked: Set<String> = []

    public init(
        records: [String: PublishRecord] = [:],
        excluded: Set<String> = [],
        repoLinks: [String: RepoLink] = [:],
        unlinked: Set<String> = []
    ) {
        self.records = records
        self.excluded = excluded
        self.repoLinks = repoLinks
        self.unlinked = unlinked
    }

    // Tolerates files written by older versions that lack newer keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([String: PublishRecord].self, forKey: .records) ?? [:]
        excluded = try container.decodeIfPresent(Set<String>.self, forKey: .excluded) ?? []
        repoLinks = try container.decodeIfPresent([String: RepoLink].self, forKey: .repoLinks) ?? [:]
        unlinked = try container.decodeIfPresent(Set<String>.self, forKey: .unlinked) ?? []
    }
}

/// Reads and writes `LoveployState` as JSON on disk.
public struct StateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Loveploy/state.json`
    public static func `default`() -> StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return StateStore(fileURL: base.appendingPathComponent("Loveploy/state.json"))
    }

    public func load() -> LoveployState {
        guard let data = try? Data(contentsOf: fileURL) else { return LoveployState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LoveployState.self, from: data)) ?? LoveployState()
    }

    public func save(_ state: LoveployState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
