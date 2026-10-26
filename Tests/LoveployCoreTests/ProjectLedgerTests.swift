import Foundation
import XCTest
@testable import LoveployCore

final class ProjectLedgerTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func reply(_ stamp: String, cwd: String, id: String, model: String = "claude-opus-5-5", input: Int = 1000, output: Int = 500) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","cwd":"\#(cwd)","requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":2000}}}"#
    }

    func user(_ stamp: String, cwd: String) -> String {
        #"{"type":"user","timestamp":"\#(stamp)","cwd":"\#(cwd)","message":{"role":"user","content":"hola"}}"#
    }

    func write(_ lines: [String], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func testPrices() {
        XCTAssertEqual(ModelPrice.for(model: "claude-opus-5-5").output, 20)
        XCTAssertEqual(ModelPrice.for(model: "claude-opus-5").output, 25)
        XCTAssertEqual(ModelPrice.for(model: "claude-sonnet-4-5-20250929").input, 3)
        XCTAssertEqual(ModelPrice.for(model: "claude-haiku-5-5").input, 0.10)
        XCTAssertEqual(ModelPrice.for(model: "claude-fable-5-1").cacheRead, 0.25)
        // 1M input at $4 + 1M output at $20 + 1M cache writes at $5 + 1M cache reads at $0.20
        let count = TokenCount(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        XCTAssertEqual(count.dollars(model: "claude-opus-5-5"), 29.2, accuracy: 0.0001)
    }

    func testReportsTimeAndTokensPerProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Two windows on the same project at the same time, one session elsewhere, one subagent.
        try write([
            user("2026-10-20T10:00:00Z", cwd: "/Users/ale/cliente"),
            reply("2026-10-20T10:02:00Z", cwd: "/Users/ale/cliente", id: "1"),
            reply("2026-10-20T10:06:00Z", cwd: "/Users/ale/cliente", id: "2"),
        ], to: root.appendingPathComponent("-Users-ale-cliente/a.jsonl"))
        try write([
            reply("2026-10-20T10:01:00Z", cwd: "/Users/ale/cliente/web", id: "3", model: "claude-sonnet-5-5"),
            reply("2026-10-20T10:01:00Z", cwd: "/Users/ale/cliente/web", id: "3", model: "claude-sonnet-5-5"),   // copied reply
        ], to: root.appendingPathComponent("-Users-ale-cliente-web/b.jsonl"))
        try write([reply("2026-10-20T10:20:00Z", cwd: "/x", id: "4")], to: root.appendingPathComponent("-Users-ale-cliente/a/subagents/agent-1.jsonl"))
        try write([reply("2026-10-21T09:00:00Z", cwd: "/Users/ale/otro", id: "5")], to: root.appendingPathComponent("-Users-ale-otro/c.jsonl"))

        var ledger = UsageLedger()
        ledger.scan(roots: [root], calendar: calendar)
        XCTAssertEqual(Set(ledger.sessions.keys), ["a", "b", "c"])
        XCTAssertEqual(ledger.sessions["a"]?.cwd, "/Users/ale/cliente")

        let cliente = BillingProject(name: "Cliente", folders: ["/Users/ale/cliente/"], hourlyRate: 600)
        let otro = BillingProject(name: "Otro")
        let report = ProjectReport.build(ledger: ledger, projects: [cliente, otro], assignments: ["c": otro.id])
        XCTAssertEqual(report.count, 2)
        let first = report[0]
        XCTAssertEqual(first.projectID, cliente.id)
        XCTAssertEqual(first.sessions, 2)
        XCTAssertEqual(first.minutes, 15, "10:00, 10:05 and 10:20 slots; b's 10:00 slot overlaps a's")
        XCTAssertEqual(first.sessionMinutes, 20)
        XCTAssertEqual(first.tokens["claude-opus-5-5"]?.messages, 3)
        XCTAssertEqual(first.tokens["claude-sonnet-5-5"]?.messages, 1, "the copied reply counts once")
        XCTAssertEqual(first.fee(rate: cliente.hourlyRate) ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(report[1].projectID, otro.id)
        XCTAssertEqual(report[1].minutes, 5)

        let october20 = ProjectReport.build(ledger: ledger, projects: [cliente], assignments: [:], from: "2026-10-20", to: "2026-10-20")
        XCTAssertEqual(october20.count, 1, "c falls on the 21st")
        let unassigned = ProjectReport.build(ledger: ledger, projects: [cliente], assignments: [:])
        XCTAssertNil(unassigned.last?.projectID)
        XCTAssertEqual(unassigned.last?.sessions, 1)

        let csv = ProjectReport.csv(report, projects: [cliente, otro], period: "octubre 2026")
        XCTAssertTrue(csv.hasPrefix("periodo,proyecto,horas"))
        XCTAssertTrue(csv.contains("octubre 2026,Cliente,0.25,0.33,2,claude-opus-5-5,3000,1500,0,6000,"))
        XCTAssertEqual(ledger.devHours.slots["2026-10-20"]?.count, 3)

        // Nothing new: nothing changes.
        let before = ledger
        ledger.scan(roots: [root], calendar: calendar)
        XCTAssertEqual(ledger, before)

        let file = JSONFile<UsageLedger>(fileURL: root.appendingPathComponent("ledger.json"))
        try file.save(ledger)
        XCTAssertEqual(file.load(), ledger)
    }

    func testSubagentFolderNeverNamesTheSession() {
        var ledger = UsageLedger()
        ledger.ingest(Data(reply("2026-10-20T10:00:00Z", cwd: "/x", id: "s").utf8), session: "a", subagent: true, calendar: calendar)
        XCTAssertEqual(ledger.sessions["a"]?.cwd, "/x", "better than nothing until the session's own file is read")
        ledger.ingest(Data(user("2026-10-20T10:01:00Z", cwd: "/Users/ale/cliente").utf8), session: "a", calendar: calendar)
        ledger.ingest(Data(reply("2026-10-20T10:02:00Z", cwd: "/y", id: "t").utf8), session: "a", subagent: true, calendar: calendar)
        XCTAssertEqual(ledger.sessions["a"]?.cwd, "/Users/ale/cliente")
    }

    func testFreshPanesStartWithTheirOwnSessionID() {
        var pane = SessionPane(kind: .local, title: "nueva", sessionID: "11111111-2222-3333-4444-555555555555", directory: "/tmp", startsNew: true)
        XCTAssertEqual(pane.shellCommand, "cd '/tmp' && exec claude --session-id '11111111-2222-3333-4444-555555555555'")
        pane.startsNew = false
        XCTAssertEqual(pane.shellCommand, "cd '/tmp' && exec claude --resume '11111111-2222-3333-4444-555555555555'")
        let project = UUID()
        let group = SessionGroup(name: "g", panes: [pane], project: project)
        XCTAssertEqual(group.project(of: pane), project)
    }
}
