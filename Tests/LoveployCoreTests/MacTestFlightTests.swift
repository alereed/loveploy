import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class MacTestFlightTests: XCTestCase {
    func macRun(_ id: Int, status: String, conclusion: String?, build: String, commit: String, at: String) -> WorkflowRun {
        WorkflowRun(id: id, status: status, conclusion: conclusion, headSha: "branch-head",
                    displayTitle: "TestFlight \(build) · \(commit) · lp-\(id)", createdAt: at)
    }

    func testEmbeddedWorkflowMatchesTemplateFile() throws {
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("templates/loveploy-testflight.yml")
        XCTAssertEqual(try String(contentsOf: template, encoding: .utf8), MacTestFlight.workflowYAML)
        XCTAssertTrue(MacTestFlight.workflowYAML.contains("runs-on: [self-hosted, macOS]"))
    }

    func testNextBuildNumber() {
        XCTAssertEqual(MacTestFlight.nextBuildNumber(known: ["12", nil, "9"]), "13")
        XCTAssertNil(MacTestFlight.nextBuildNumber(known: [nil, "1.2.3"]))
    }

    func testRunTitleParsing() {
        let run = macRun(7, status: "completed", conclusion: "success", build: "15", commit: "abcdef1234", at: "2026-10-25T10:00:00Z")
        XCTAssertEqual(run.buildNumber, "15")
        XCTAssertEqual(run.builtCommit, "abcdef1234")
        XCTAssertEqual(run.loveployID, "lp-7")
        XCTAssertEqual(run.asBuildRun.status, "succeeded")
        XCTAssertEqual(macRun(8, status: "in_progress", conclusion: nil, build: "1", commit: "abcdef1", at: "x").asBuildRun.status, "running")
        XCTAssertEqual(macRun(9, status: "completed", conclusion: "failure", build: "1", commit: "abcdef1", at: "x").asBuildRun.status, "failed")
        let manual = WorkflowRun(id: 1, status: "completed", conclusion: "success", headSha: "head", displayTitle: "TestFlight 3 ·  · manual", createdAt: nil)
        XCTAssertEqual(manual.builtCommit, "head", "falls back to the branch head")
    }

    func testMacRunsCountTowardTestFlight() {
        let lovable = BuildRun(id: "r1", status: "succeeded", commitSha: "c1", createdAt: "2026-10-01T10:00:00Z")
        let upToDate = IOSStatus.evaluate(
            runs: [lovable], builds: [], latestCommitSha: "c2",
            macRuns: [macRun(5, status: "completed", conclusion: "success", build: "15", commit: "c2", at: "2026-10-25T10:00:00Z")],
            macWorkflowInstalled: true
        )
        XCTAssertEqual(upToDate?.testFlight, .upToDate)
        XCTAssertEqual(upToDate?.macRun?.buildNumber, "15")
        XCTAssertEqual(upToDate?.knownBuildNumbers.compactMap { $0 }, ["15"])

        let building = IOSStatus.evaluate(
            runs: [lovable], builds: [], latestCommitSha: "c2",
            macRuns: [macRun(6, status: "queued", conclusion: nil, build: "16", commit: "c2", at: "2026-10-25T11:00:00Z")]
        )
        XCTAssertEqual(building?.testFlight, .uploading)

        // Only Mac builds, no Lovable ones: still an iOS app.
        XCTAssertNotNil(IOSStatus.evaluate(runs: [], builds: [], latestCommitSha: "c2",
                                           macRuns: [macRun(1, status: "completed", conclusion: "failure", build: "1", commit: "c2", at: "2026-10-25")]))
    }

    func testActionsEndpoints() async throws {
        let transport = MockTransport()
        transport.on("GET", "/repos/alereed/uno/actions/workflows/loveploy-testflight.yml/runs", """
        {"total_count":1,"workflow_runs":[{"id":42,"status":"completed","conclusion":"success","head_sha":"h",
          "display_title":"TestFlight 15 · abcdef1 · lp","html_url":"https://github.com/alereed/uno/actions/runs/42","created_at":"2026-10-25T10:00:00Z"}]}
        """)
        transport.on("POST", "/repos/alereed/uno/actions/workflows/loveploy-testflight.yml/dispatches", status: 204, "")
        transport.on("GET", "/repos/alereed/uno/contents/.github/workflows/loveploy-testflight.yml", status: 404, #"{"message":"Not Found"}"#)
        transport.on("PUT", "/repos/alereed/uno/contents/.github/workflows/loveploy-testflight.yml", status: 201, #"{"content":{}}"#)

        let github = GitHubClient(token: "t", transport: transport)
        let runs = try await github.workflowRuns(repo: "alereed/uno", workflow: MacTestFlight.workflowFile)
        XCTAssertEqual(runs.first?.buildNumber, "15")
        XCTAssertEqual(runs.first?.htmlUrl, "https://github.com/alereed/uno/actions/runs/42")

        try await github.dispatchWorkflow(repo: "alereed/uno", workflow: MacTestFlight.workflowFile, ref: "main",
                                          inputs: ["commit_sha": "c2", "build_number": "16"])
        let dispatch = transport.requests.first { $0.httpMethod == "POST" }!
        let body = try JSONSerialization.jsonObject(with: dispatch.httpBody!) as! [String: Any]
        XCTAssertEqual(body["ref"] as? String, "main")
        XCTAssertEqual((body["inputs"] as? [String: String])?["build_number"], "16")

        try await github.putFile(repo: "alereed/uno", path: MacTestFlight.workflowPath, content: "hola",
                                 message: "Agregar workflow", branch: "main")
        let put = transport.requests.first { $0.httpMethod == "PUT" }!
        let putBody = try JSONSerialization.jsonObject(with: put.httpBody!) as! [String: Any]
        XCTAssertEqual(putBody["content"] as? String, Data("hola".utf8).base64EncodedString())
        XCTAssertNil(putBody["sha"], "new file")
        XCTAssertEqual(putBody["branch"] as? String, "main")
    }
}
