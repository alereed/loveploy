import Foundation

/// Everything Loveploy persists between launches (the session lives in the Keychain).
public struct LoveployState: Codable, Equatable, Sendable {
    /// Projects the user chose to leave out of "Publicar".
    public var excluded: Set<String> = []

    public init(excluded: Set<String> = []) {
        self.excluded = excluded
    }

    // Tolerates files written by other versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excluded = (try? container.decodeIfPresent(Set<String>.self, forKey: .excluded)) ?? []
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
        return (try? JSONDecoder().decode(LoveployState.self, from: data)) ?? LoveployState()
    }

    public func save(_ state: LoveployState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
