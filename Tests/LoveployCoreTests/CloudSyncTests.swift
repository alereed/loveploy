import Foundation
import XCTest
@testable import LoveployCore

final class CloudSyncTests: XCTestCase {
    func testCodeRoundTrips() throws {
        let code = SyncCode.random()
        XCTAssertTrue(code.text.hasPrefix("BP1-"))
        XCTAssertFalse(code.text.contains("="))
        XCTAssertEqual(SyncCode(text: code.text), code)
        // Pasted with spaces and a line break, or in lowercase prefix.
        let messy = " " + code.text.prefix(10) + "\n" + code.text.dropFirst(10) + " "
        XCTAssertEqual(SyncCode(text: String(messy)), code)
        XCTAssertEqual(SyncCode(text: "bp1-" + code.text.dropFirst(4)), code)
        XCTAssertNil(SyncCode(text: "BP1-abc"))
        XCTAssertNil(SyncCode(text: "hola"))
        XCTAssertNotEqual(SyncCode.random(), code)
    }

    func testKinds() {
        XCTAssertEqual(SyncKind.device(of: "ledger:abc-1"), "abc-1")
        XCTAssertEqual(SyncKind.device(of: "activity:X"), "X")
        XCTAssertNil(SyncKind.device(of: "groups"))
        XCTAssertEqual(SyncKind.safeDevice("A1B2-c3/d4 é"), "A1B2-c3d4")
    }

    func testLedgerForSyncDropsOffsets() {
        var ledger = UsageLedger()
        ledger.offsets["/x.jsonl"] = 10
        ledger.seen.insert(4)
        ledger.sessions["s"] = SessionActivity(cwd: "/a", days: ["2026-11-20": DayActivity(slots: [1])])
        let synced = ledger.forSync
        XCTAssertTrue(synced.offsets.isEmpty)
        XCTAssertTrue(synced.seen.isEmpty)
        XCTAssertEqual(synced.sessions, ledger.sessions)
    }

    func testLedgersOfTwoMacsAddUpWithoutDoubleCounting() {
        let model = "claude-opus-5-5"
        var mine = UsageLedger()
        mine.sessions["local"] = SessionActivity(cwd: "/a", days: ["d": DayActivity(slots: [1, 2], tokens: [model: TokenCount(input: 10)])])
        mine.sessions["pane:1"] = SessionActivity(days: ["d": DayActivity(slots: [5])])
        var theirs = UsageLedger()
        theirs.sessions["remote"] = SessionActivity(cwd: "/b", days: ["d": DayActivity(slots: [3], tokens: [model: TokenCount(output: 7)])])
        theirs.sessions["pane:1"] = SessionActivity(cwd: "/c", days: ["d": DayActivity(slots: [5, 6]), "e": DayActivity(slots: [0])])

        let total = mine.merging(theirs)
        XCTAssertEqual(Set(total.sessions.keys), ["local", "remote", "pane:1"])
        XCTAssertEqual(total.sessions["pane:1"]?.days["d"]?.slots, [5, 6])
        XCTAssertEqual(total.sessions["pane:1"]?.days["e"]?.slots, [0])
        XCTAssertEqual(total.sessions["pane:1"]?.cwd, "/c")
        XCTAssertEqual(total.sessions["remote"]?.days["d"]?.tokens[model]?.output, 7)
        // Time: slots 1,2,3,5,6 on day d and 0 on e = 6 slots.
        XCTAssertEqual(total.devHours.slots.values.reduce(0) { $0 + $1.count }, 6)
        // The same session from both sides keeps the larger token count, not the sum.
        let again = total.merging(total)
        XCTAssertEqual(again, total)
    }

    func testUnionByIDKeepsBothSides() throws {
        let local = Data(#"[{"id":"a","name":"mío"},{"id":"b","name":"solo aquí"}]"#.utf8)
        let remote = Data(#"[{"id":"a","name":"de la otra Mac"},{"id":"c","name":"solo allá"}]"#.utf8)
        let merged = try XCTUnwrap(SyncMerge.unionByID(local: local, remote: remote))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [[String: String]])
        XCTAssertEqual(list.map { $0["id"]! }, ["a", "c", "b"])
        XCTAssertEqual(list.first?["name"], "de la otra Mac")
        XCTAssertNil(SyncMerge.unionByID(local: Data("{}".utf8), remote: remote))
    }
}
