import Foundation

/// Decides which apps Turbo asks the hub to send to TestFlight when TestFlight is set to
/// automatic: apps with native changes no build has, once they've been waiting `settleDelay`.
/// Each pending commit is asked for once; if that build fails, it waits for a new commit.
public struct TestFlightAutopilot: Sendable {
    public var settleDelay: TimeInterval
    /// When each app's pending commit was first seen.
    private var firstSeen: [String: (commit: String, at: Date)] = [:]
    /// The pending commit already asked for, per app.
    private var requested: [String: String] = [:]

    public init(settleDelay: TimeInterval) {
        self.settleDelay = settleDelay
    }

    public mutating func ready(apps: [HubApp], now: Date) -> [HubApp] {
        var ready: [HubApp] = []
        var seen = Set<String>()
        for app in apps where app.hasIOS {
            guard let commit = app.iosPendienteCommit else { continue }
            seen.insert(app.slug)
            if firstSeen[app.slug]?.commit != commit {
                firstSeen[app.slug] = (commit, now)
            }
            guard app.testFlight != .building, requested[app.slug] != commit,
                  let since = firstSeen[app.slug]?.at, now.timeIntervalSince(since) >= settleDelay else { continue }
            ready.append(app)
        }
        // Built (nothing pending anymore): start over with the next change.
        firstSeen = firstSeen.filter { seen.contains($0.key) }
        requested = requested.filter { seen.contains($0.key) }
        return ready
    }

    public mutating func recordRequest(_ app: HubApp) {
        if let commit = app.iosPendienteCommit {
            requested[app.slug] = commit
        }
    }

    public func wasRequested(_ app: HubApp) -> Bool {
        app.iosPendienteCommit.map { requested[app.slug] == $0 } ?? false
    }
}
