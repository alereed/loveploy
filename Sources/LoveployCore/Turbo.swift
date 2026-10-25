import Foundation

/// Decides what Turbo mode publishes on its own.
///
/// A project is published automatically once it's outdated, not excluded, and its
/// latest version has stayed the same for `settleDelay` (so it doesn't publish while
/// someone, or Lovable's agent, is still making changes). A version that failed to
/// publish isn't retried automatically; a new change gets a fresh attempt.
public struct TurboPlanner: Sendable {
    public var settleDelay: TimeInterval
    /// When each project's current version was first seen.
    private var firstSeen: [String: (version: String, at: Date)] = [:]
    /// Versions that failed to publish automatically.
    private var failed: [String: String] = [:]
    /// Versions just published. Lovable can take a moment to report them as live,
    /// and they mustn't go out twice meanwhile.
    private var published: [String: String] = [:]

    public init(settleDelay: TimeInterval) {
        self.settleDelay = settleDelay
    }

    /// What identifies "the same changes": the latest commit plus the secrets.
    public static func version(of row: ProjectRow) -> String {
        let deployment = row.details?.publishedDeployment
        return [row.details?.latestCommitSha ?? "", deployment?.previewSecretsHash ?? ""].joined(separator: "|")
    }

    /// Updates what it knows from a fresh list and returns the projects ready to publish.
    public mutating func ready(rows: [ProjectRow], excluded: Set<String>, now: Date) -> [String] {
        var ready: [String] = []
        var seen = Set<String>()
        for row in rows where row.state.needsDeploy {
            seen.insert(row.id)
            let version = Self.version(of: row)
            if firstSeen[row.id]?.version != version {
                firstSeen[row.id] = (version, now)
            }
            guard !excluded.contains(row.id), failed[row.id] != version, published[row.id] != version,
                  let since = firstSeen[row.id]?.at, now.timeIntervalSince(since) >= settleDelay else { continue }
            ready.append(row.id)
        }
        // Forget projects that are no longer outdated.
        firstSeen = firstSeen.filter { seen.contains($0.key) }
        failed = failed.filter { seen.contains($0.key) }
        published = published.filter { seen.contains($0.key) }
        return ready
    }

    /// When Turbo will publish this project, if it's waiting for changes to settle.
    public func publishDate(for row: ProjectRow, excluded: Set<String>) -> Date? {
        guard row.state.needsDeploy, !excluded.contains(row.id),
              let entry = firstSeen[row.id], entry.version == Self.version(of: row),
              failed[row.id] != entry.version, published[row.id] != entry.version else { return nil }
        return entry.at.addingTimeInterval(settleDelay)
    }

    public func didFail(_ row: ProjectRow) -> Bool {
        failed[row.id] == Self.version(of: row)
    }

    public mutating func recordFailure(projectID: String, version: String) {
        failed[projectID] = version
    }

    /// Published: wait for the next change before publishing it again.
    public mutating func recordSuccess(projectID: String, version: String) {
        failed[projectID] = nil
        published[projectID] = version
    }
}
