import Foundation
import LoveployCore
import SwiftUI
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
        // One active organization only (claude.ai may have left its own copy from a switch).
        for cookie in await target.allCookies() where isClaude(cookie) && cookie.name == "lastActiveOrg" {
            await target.deleteCookie(cookie)
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

// MARK: - Keeping each pane in its organization

/// Watches a claude.ai pane for two things: claude.ai asking to switch organization (the
/// session belongs to the other one), and you switching it yourself inside the page. Either way
/// the pane remembers the right organization and opens in it from then on.
final class OrgWatcher: NSObject, WKScriptMessageHandler {
    static let name = "bpOrg"
    let pane: UUID

    init(pane: UUID) { self.pane = pane }

    /// Only looks at dialogs, alerts and buttons (never the conversation, which can mention
    /// organizations), and only in the first half minute after a page opens.
    static let script = """
    (() => {
      if (!/(^|\\.)claude\\.ai$/.test(location.hostname)) return;
      const post = (kind, text) => { try { window.webkit.messageHandlers.bpOrg.postMessage({kind, text: text || ''}); } catch (e) {} };
      const asks = /(switch|cambia|cambiar)[^\\n]{0,60}(organi[sz]ation|organizaci[oó]n|workspace|team|equipo|cuenta|account|personal)|(belongs to|pertenece a|is in|est[aá] en)[^\\n]{0,60}(organi|cuenta|account|workspace)|(don.t have access|do not have access|no tienes acceso|not have permission|no tienes permiso)/i;
      let since = Date.now(), last = '';
      const check = () => {
        if (Date.now() - since > 30000) return;
        const parts = [];
        document.querySelectorAll('[role=dialog],[role=alertdialog],[role=alert],button,a[role=button]').forEach(el => {
          const t = (el.innerText || '').trim();
          if (t && t.length < 400) parts.push(t);
        });
        const text = parts.join('\\n');
        const match = text.match(asks);
        if (!match) return;
        const at = Math.max(0, match.index - 160);
        const snippet = text.slice(at, match.index + 240);
        if (snippet === last) return;
        last = snippet;
        post('mismatch', snippet);
      };
      let pending = null;
      new MutationObserver(() => {
        if (pending || Date.now() - since > 30000) return;
        pending = setTimeout(() => { pending = null; check(); }, 1200);
      }).observe(document.documentElement, {childList: true, subtree: true});
      setTimeout(check, 2500);
      // In-page navigation (claude.ai is a single-page app): look again, and report it so the
      // app can see whether you switched organization yourself.
      let href = location.href;
      setInterval(() => {
        if (location.href !== href) { href = location.href; since = Date.now(); last = ''; post('navigated'); setTimeout(check, 2500); }
      }, 1000);
      post('navigated');
    })();
    """

    static func install(in configuration: WKWebViewConfiguration, pane: UUID) {
        configuration.userContentController.add(OrgWatcher(pane: pane), name: name)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let text = body["text"] as? String ?? ""
        let pane = pane
        Task { @MainActor in
            switch kind {
            case "mismatch": await PaneOrgs.mismatch(pane: pane, text: text)
            case "navigated": await PaneOrgs.followPage(pane: pane)
            default: break
            }
        }
    }
}

@MainActor
enum PaneOrgs {
    /// Organizations already tried for a pane since it last opened fine, so a page that keeps
    /// asking doesn't bounce between them forever.
    private static var tried: [UUID: Set<String>] = [:]

    /// claude.ai says this session is in the other organization: move the pane there.
    static func mismatch(pane id: UUID, text: String) async {
        guard let pane = SessionGroups.shared.pane(id), pane.kind == .cloud else { return }
        let orgs = await ClaudeOrgs.orgs(account: pane.account)
        guard orgs.count > 1 else { return }
        var done = tried[id] ?? []
        if let current = pane.org { done.insert(current) }
        let lower = text.lowercased()
        // The organization claude.ai names, else the next one not tried yet.
        let named = orgs.first { !done.contains($0.id) && $0.name != "Personal" && lower.contains($0.name.lowercased()) }
            ?? orgs.first { !done.contains($0.id) && $0.name == "Personal" && lower.contains("personal") }
        guard let target = named ?? orgs.first(where: { !done.contains($0.id) }) else { return }
        done.insert(target.id)
        tried[id] = done
        Log.write("pane \(id.uuidString.prefix(8)): claude.ai asked to switch organization; opening it in \(target.name)")
        SessionGroups.shared.setOrg(id, to: target)
    }

    /// The page moved (or loaded): if you switched organization inside claude.ai, remember it,
    /// so next time the pane opens there directly.
    static func followPage(pane id: UUID) async {
        guard let pane = SessionGroups.shared.pane(id), pane.kind == .cloud else { return }
        let store = ClaudeOrgs.store(account: pane.account, org: pane.org)
        let cookies = await store.httpCookieStore.allCookies()
        guard let active = cookies.first(where: { $0.name == "lastActiveOrg" && $0.domain.hasSuffix("claude.ai") })?.value,
              active != pane.org else { return }
        let orgs = await ClaudeOrgs.orgs(account: pane.account)
        guard orgs.count > 1, let org = orgs.first(where: { $0.id == active }) else { return }
        // Same page, now known to be in this organization: no reload needed.
        SessionGroups.shared.setOrg(id, to: org, reload: false)
    }

    static func manual(pane id: UUID, to org: ClaudeOrg) {
        tried[id] = nil
        SessionGroups.shared.setOrg(id, to: org)
    }
}

// MARK: - The organization of a pane, in its header

/// "· Blender ▾": which organization the pane is in, and a menu to move it to the other one.
struct PaneOrgMenu: View {
    let pane: SessionPane
    @State private var orgs: [ClaudeOrg] = []

    var body: some View {
        Group {
            if orgs.count > 1 || pane.orgName != nil {
                Menu {
                    ForEach(orgs) { org in
                        Button {
                            PaneOrgs.manual(pane: pane.id, to: org)
                        } label: {
                            if org.id == pane.org { Label(org.name, systemImage: "checkmark") } else { Text(org.name + (org.team ? " (equipo)" : "")) }
                        }
                    }
                } label: {
                    Text(pane.orgName ?? "Organización")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((orgs.first { $0.id == pane.org }?.team ?? false ? Color.blue : Color.gray).opacity(0.18)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Organización de esta sesión (equipo o personal). Elige otra para abrirla ahí.")
            }
        }
        .task(id: pane.account) { orgs = await ClaudeOrgs.orgs(account: pane.account) }
    }
}
