import Foundation

/// Lovable's API does not say which commit is live, so Loveploy keeps its own record
/// of what it published. Comparing that against `latest_commit_sha` tells us which
/// projects are behind.
public struct PublishRecord: Codable, Hashable, Sendable {
    public var commitSha: String?
    public var publishedAt: Date
    public var url: String?

    public init(commitSha: String?, publishedAt: Date, url: String? = nil) {
        self.commitSha = commitSha
        self.publishedAt = publishedAt
        self.url = url
    }
}

/// Everything Loveploy persists between launches (except API keys, which live in the Keychain).
public struct LoveployState: Codable, Equatable, Sendable {
    /// Last successful publish per project ID.
    public var records: [String: PublishRecord] = [:]
    /// Projects the user chose to leave out of "Publicar todo".
    public var excluded: Set<String> = []

    public init(records: [String: PublishRecord] = [:], excluded: Set<String> = []) {
        self.records = records
        self.excluded = excluded
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
