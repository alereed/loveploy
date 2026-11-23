import Foundation

// One claude.ai sign-in can belong to several organizations: a team (Claude Team or
// Enterprise) and the person's own plan (Pro or Max). claude.ai shows one at a time, chosen by
// the `lastActiveOrg` cookie; Blender Play opens each pane, lists sessions and reads limits in
// the organization you pick.

/// An organization of a claude.ai account.
public struct ClaudeOrg: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// A team plan (Team, Enterprise), not the person's own.
    public let team: Bool

    public init(id: String, name: String, team: Bool) {
        self.id = id
        self.name = name
        self.team = team
    }

    /// The organizations in claude.ai's `/api/organizations` answer that can chat or run
    /// Claude Code (API-only organizations are left out), teams first.
    public static func parse(_ json: Any) -> [ClaudeOrg] {
        guard let list = json as? [[String: Any]] else { return [] }
        let orgs = list.compactMap { entry -> ClaudeOrg? in
            guard let id = entry["uuid"] as? String, !id.isEmpty else { return nil }
            let capabilities = entry["capabilities"] as? [String] ?? []
            if !capabilities.isEmpty, !capabilities.contains("chat"), !capabilities.contains(where: { $0.hasPrefix("claude_") }) { return nil }
            let tier = (entry["rate_limit_tier"] as? String ?? "") + " " + (entry["billing_type"] as? String ?? "")
            let team = capabilities.contains { $0.contains("raven") || $0.contains("team") || $0.contains("enterprise") }
                || tier.contains("team") || tier.contains("enterprise") || tier.contains("raven")
            return ClaudeOrg(id: id, name: displayName(entry["name"] as? String ?? "", team: team), team: team)
        }
        return orgs.filter(\.team) + orgs.filter { !$0.team }
    }

    /// A personal organization is called "<email>'s Organization": show "Personal" instead
    /// (and keep the email out of the app).
    public static func displayName(_ name: String, team: Bool) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return team ? "Equipo" : "Personal" }
        for suffix in ["'s Organization", "’s Organization", "'s organization", "’s organization"] where trimmed.hasSuffix(suffix) {
            return "Personal"
        }
        if trimmed.contains("@") { return "Personal" }
        return trimmed
    }

    /// A web storage of its own for an account in this organization, so a pane in the team and
    /// one in the personal plan don't fight over the active organization. Always the same for
    /// the same account and organization.
    public static func storeID(account: String, org: String) -> UUID {
        func fnv(_ text: String, seed: UInt64) -> UInt64 {
            var h = seed
            for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return h
        }
        let key = "blenderplay-org|" + account + "|" + org
        let a = fnv(key, seed: 0xcbf2_9ce4_8422_2325), b = fnv(key, seed: 0x8422_2325_cbf2_9ce4)
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (8 * $0)) } + (0..<8).map { UInt8(truncatingIfNeeded: b >> (8 * $0)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
