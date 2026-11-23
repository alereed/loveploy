import Foundation
import LoveployCore
import WebKit

// Blender Play: the organizations (team and personal) of each account signed in to claude.ai
// inside the app, and a web storage per organization so each pane stays in the one you chose.

@MainActor
enum ClaudeOrgs {
    private static var cache: [String: (orgs: [ClaudeOrg], at: Date)] = [:]

    /// The account's own web storage (where you signed in to claude.ai inside Blender Play).
    static func baseStore(_ account: String?) -> WKWebsiteDataStore {
        account.flatMap(UUID.init(uuidString:)).map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }

    /// The storage a claude.ai page opens in: the account's, or a copy of it set to `org`.
    static func store(account: String?, org: String?) -> WKWebsiteDataStore {
        guard let org else { return baseStore(account) }
        return WKWebsiteDataStore(forIdentifier: ClaudeOrg.storeID(account: account ?? "default", org: org))
    }

    private static func isClaude(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain == "claude.ai" || domain.hasSuffix(".claude.ai")
    }

    /// The account's claude.ai sign-in (the `sessionKey` cookie), if it has one.
    static func sessionKey(account: String?) async -> String? {
        let cookies = await baseStore(account).httpCookieStore.allCookies()
        return cookies.first { isClaude($0) && $0.name == "sessionKey" }?.value
    }

    /// The account's organizations, teams first (cached ten minutes). Empty when it isn't
    /// signed in to claude.ai inside Blender Play.
    static func orgs(account: String?, refresh: Bool = false) async -> [ClaudeOrg] {
        let key = account ?? "default"
        if !refresh, let hit = cache[key], Date().timeIntervalSince(hit.at) < 600 { return hit.orgs }
        guard let cookie = await sessionKey(account: account),
              let json = try? await ChatLimits.get("/api/organizations", cookie) else { return cache[key]?.orgs ?? [] }
        let orgs = ClaudeOrg.parse(json)
        cache[key] = (orgs, Date())
        return orgs
    }

    /// Before a page opens in an organization: brings the account's sign-in into that
    /// organization's storage (so you don't sign in twice) and makes it the active one there.
    static func prepare(account: String?, org: String?) async {
        guard let org else { return }
        let source = baseStore(account).httpCookieStore
        let target = store(account: account, org: org).httpCookieStore
        for cookie in await source.allCookies() where isClaude(cookie) && cookie.name != "lastActiveOrg" {
            await target.setCookie(cookie)
        }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".claude.ai", .path: "/", .name: "lastActiveOrg", .value: org,
            .secure: "TRUE", .expires: Date().addingTimeInterval(365 * 86_400),
        ]
        if let active = HTTPCookie(properties: properties) { await target.setCookie(active) }
    }
}

/// For code in files that don't import LoveployCore (the MultiClaude part of main.swift).
enum OrgParser {
    static func parse(_ json: Any) -> [ClaudeOrg] { ClaudeOrg.parse(json) }
}
