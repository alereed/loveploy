import Foundation
import XCTest
@testable import LoveployCore

final class ClaudeOrgsTests: XCTestCase {
    func testParsesTeamAndPersonal() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        [
          {"uuid":"p-1","name":"ale@example.com's Organization","capabilities":["chat","claude_max"],"rate_limit_tier":"default_claude_max_20x"},
          {"uuid":"t-1","name":"Blender","capabilities":["chat","raven"],"rate_limit_tier":"default_raven","billing_type":"stripe_subscription"},
          {"uuid":"api","name":"Consola","capabilities":["api"]}
        ]
        """.utf8))
        let orgs = ClaudeOrg.parse(json)
        XCTAssertEqual(orgs.map(\.id), ["t-1", "p-1"], "teams first, API-only left out")
        XCTAssertEqual(orgs.map(\.name), ["Blender", "Personal"])
        XCTAssertEqual(orgs.map(\.team), [true, false])
        XCTAssertFalse(orgs.contains { $0.name.contains("@") })
        XCTAssertEqual(ClaudeOrg.parse(["nope"]), [])
    }

    func testClaudeAppLinksAreSessions() throws {
        let link = "https://claude.ai/code/cshk_01ABCDEFexampleLinkForTests"
        XCTAssertTrue(ClaudeLink.isCodeSession(link))
        XCTAssertTrue(ClaudeLink.isCodeSession("https://claude.ai/code/session_abc"))
        XCTAssertFalse(ClaudeLink.isCodeSession("https://claude.ai/code"))
        XCTAssertEqual(try XCTUnwrap(SessionPane.cloud(link, title: nil, account: nil)).title, "Sesión 01ABCD")
    }

    func testStoreIDIsStableAndSeparate() {
        let a = ClaudeOrg.storeID(account: "acct", org: "t-1")
        XCTAssertEqual(a, ClaudeOrg.storeID(account: "acct", org: "t-1"))
        XCTAssertNotEqual(a, ClaudeOrg.storeID(account: "acct", org: "p-1"))
        XCTAssertNotEqual(a, ClaudeOrg.storeID(account: "other", org: "t-1"))
    }

    func testPaneRemembersItsOrganization() throws {
        let org = ClaudeOrg(id: "t-1", name: "Blender", team: true)
        let pane = try XCTUnwrap(SessionPane.cloud("https://claude.ai/code/session_abc", title: "X", account: "acct", org: org))
        XCTAssertEqual(pane.org, "t-1")
        let back = try JSONDecoder().decode(SessionPane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(back.org, "t-1")
        XCTAssertEqual(back.orgName, "Blender")
        // Panes saved before organizations existed still load.
        let old = try JSONDecoder().decode(SessionPane.self, from: Data(#"{"kind":"cloud","title":"Y"}"#.utf8))
        XCTAssertNil(old.org)
    }
}
