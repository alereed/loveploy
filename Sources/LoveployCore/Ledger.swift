import Foundation

/// Everything Loveploy persists between launches (the session lives in the Keychain).
public struct LoveployState: Codable, Equatable, Sendable {
    /// Projects the user chose to leave out of "Publicar" (and of Turbo).
    public var excluded: Set<String> = []
    /// Turbo mode: publish outdated projects automatically.
    public var turbo: Bool = false
    /// How long a project's changes must stay the same before Turbo publishes it.
    public var turboDelayMinutes: Int = 5

    public init(excluded: Set<String> = [], turbo: Bool = false, turboDelayMinutes: Int = 5) {
        self.excluded = excluded
        self.turbo = turbo
        self.turboDelayMinutes = turboDelayMinutes
    }

    // Tolerates files written by other versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excluded = (try? container.decodeIfPresent(Set<String>.self, forKey: .excluded)) ?? []
        turbo = (try? container.decodeIfPresent(Bool.self, forKey: .turbo)) ?? false
        turboDelayMinutes = (try? container.decodeIfPresent(Int.self, forKey: .turboDelayMinutes)) ?? 5
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
