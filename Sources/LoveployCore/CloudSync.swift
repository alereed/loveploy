import Foundation

// Blender Play: the parts of the cloud sync that don't need a Mac — the code that joins two
// Macs, what of the ledger travels, how the ledgers of several Macs add up, and merging lists
// when a Mac joins. Encryption and the network live in the app.

/// The secret two Macs share. Shown as "BP1-" + base64url of 32 random bytes.
public struct SyncCode: Equatable, Sendable {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public static func random() -> SyncCode {
        var generator = SystemRandomNumberGenerator()
        return SyncCode(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })!
    }

    public var text: String {
        "BP1-" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts the code as shown, with spaces or line breaks pasted in.
    public init?(text: String) {
        var body = text.filter { !$0.isWhitespace }
        guard body.uppercased().hasPrefix("BP1-") else { return nil }
        body = String(body.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body) else { return nil }
        self.init(bytes: [UInt8](data))
    }
}

/// What each kind of synced data is called in the cloud.
public enum SyncKind {
    public static let groups = "groups"
    public static let projects = "projects"
    public static let chrome = "chrome"
    public static let prefs = "prefs"
    public static let ledgerPrefix = "ledger:"
    public static let activityPrefix = "activity:"

    /// Kinds that are one Mac's own data (several Macs each keep theirs).
    public static func device(of kind: String) -> String? {
        for prefix in [ledgerPrefix, activityPrefix] where kind.hasPrefix(prefix) {
            return String(kind.dropFirst(prefix.count))
        }
        return nil
    }

    /// The device id as a valid kind suffix (letters, digits and dashes, up to 64).
    public static func safeDevice(_ id: String) -> String {
        String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
    }
}

extension UsageLedger {
    /// Only what another Mac needs: time and tokens per session, not this Mac's file offsets.
    public var forSync: UsageLedger {
        var copy = UsageLedger()
        copy.sessions = sessions
        return copy
    }

    /// This ledger plus another Mac's. Sessions are per Mac, so they rarely share an id; when
    /// they do (a claude.ai pane open on both Macs), time is the union of both and tokens the
    /// larger count, so nothing is counted twice.
    public func merging(_ other: UsageLedger) -> UsageLedger {
        var result = self
        for (id, theirs) in other.sessions {
            guard var mine = result.sessions[id] else {
                result.sessions[id] = theirs
                continue
            }
            if mine.cwd == nil { mine.cwd = theirs.cwd }
            for (day, activity) in theirs.days {
                var today = mine.days[day] ?? DayActivity()
                today.slots.formUnion(activity.slots)
                for (model, count) in activity.tokens where count.total > (today.tokens[model]?.total ?? -1) {
                    today.tokens[model] = count
                }
                mine.days[day] = today
            }
            result.sessions[id] = mine
        }
        return result
    }
}

public enum SyncMerge {
    /// Two JSON lists of objects with an "id": everything in either, the remote copy winning
    /// for the same id (used once, when a Mac joins, so neither side loses what it had).
    /// Nil when either isn't such a list.
    public static func unionByID(local: Data, remote: Data) -> Data? {
        guard let mine = try? JSONSerialization.jsonObject(with: local) as? [[String: Any]],
              let theirs = try? JSONSerialization.jsonObject(with: remote) as? [[String: Any]] else { return nil }
        let remoteIDs = Set(theirs.compactMap { $0["id"] as? String })
        let kept = mine.filter { ($0["id"] as? String).map { !remoteIDs.contains($0) } ?? true }
        return try? JSONSerialization.data(withJSONObject: theirs + kept)
    }
}
