import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class IOSTests: XCTestCase {
    typealias Release = StoreBuild.Release

    func run(_ id: String, _ status: String, commit: String?, at: String) -> BuildRun {
        BuildRun(id: id, status: status, commitSha: commit, createdAt: at)
    }

    func build(_ run: String, at: String, version: String, number: String, state: String?, status: String = "succeeded") -> StoreBuild {
        StoreBuild(runId: run, target: "ios", targetStatus: status, createdAt: at,
                   storeRelease: Release(appVersion: version, buildNumber: number, storeState: state))
    }

    func testNoIOSAppWhenNothingWasBuilt() {
        XCTAssertNil(IOSStatus.evaluate(runs: [], builds: [], latestCommitSha: "a"))
        let android = StoreBuild(runId: "r", target: "android", targetStatus: "succeeded", createdAt: "2026-01-01", storeRelease: nil)
        XCTAssertNil(IOSStatus.evaluate(runs: [], builds: [android], latestCommitSha: "a"))
    }

    func testTestFlightUpToDateWhenLastUploadIsLatestCommit() {
        let status = IOSStatus.evaluate(
            runs: [run("r2", "succeeded", commit: "c2", at: "2026-10-02"), run("r1", "succeeded", commit: "c1", at: "2026-10-01")],
            builds: [build("r2", at: "2026-10-02", version: "1.1", number: "12", state: "live")],
            latestCommitSha: "c2"
        )
        XCTAssertEqual(status?.testFlight, .upToDate)
        XCTAssertEqual(status?.latestUpload?.label, "1.1 (12)")
        XCTAssertEqual(status?.live?.label, "1.1 (12)")
        XCTAssertEqual(status?.appStoreBehind, false)
        XCTAssertEqual(status?.testFlightNeedsUpload, false)
    }

    func testTestFlightOutdatedWhenCodeMovedOn() {
        let status = IOSStatus.evaluate(
            runs: [run("r1", "succeeded", commit: "c1", at: "2026-10-01")],
            builds: [build("r1", at: "2026-10-01", version: "1.0", number: "3", state: "ready")],
            latestCommitSha: "c9"
        )
        XCTAssertEqual(status?.testFlight, .outdated)
        XCTAssertEqual(status?.testFlightNeedsUpload, true)
        XCTAssertNil(status?.live)
        XCTAssertEqual(status?.appStoreBehind, true, "nothing live yet")
    }

    func testUploadingAndFailed() {
        let uploading = IOSStatus.evaluate(
            runs: [run("r2", "running", commit: "c2", at: "2026-10-02"), run("r1", "succeeded", commit: "c1", at: "2026-10-01")],
            builds: [], latestCommitSha: "c2")
        XCTAssertEqual(uploading?.testFlight, .uploading)

        let failed = IOSStatus.evaluate(
            runs: [run("r2", "failed", commit: "c2", at: "2026-10-02"), run("r1", "succeeded", commit: "c1", at: "2026-10-01")],
            builds: [], latestCommitSha: "c2")
        XCTAssertEqual(failed?.testFlight, .failed)
    }

    func testAppStoreBehindNewestUpload() {
        let status = IOSStatus.evaluate(
            runs: [run("r3", "succeeded", commit: "c3", at: "2026-10-03")],
            builds: [
                build("r3", at: "2026-10-03", version: "1.2", number: "14", state: "in_review"),
                build("r2", at: "2026-10-02", version: "1.1", number: "12", state: "live"),
            ],
            latestCommitSha: "c3"
        )
        XCTAssertEqual(status?.testFlight, .upToDate)
        XCTAssertEqual(status?.latestUpload?.label, "1.2 (14)")
        XCTAssertEqual(status?.latestUpload?.stateLabel, "en revisión")
        XCTAssertEqual(status?.live?.label, "1.1 (12)")
        XCTAssertEqual(status?.appStoreBehind, true)
    }

    func testEndpointsDecode() async throws {
        let transport = MockTransport()
        transport.on("GET", "/projects/p1/build-runs", """
        {"runs":[{"id":"r1","status":"succeeded","commit_sha":"c1","created_at":"2026-10-01T10:00:00Z","requested_targets":["ios"],"flow":"manual"},
                 {"id":"r0","status":"succeeded","commit_sha":"c0","created_at":"2026-09-01T10:00:00Z","requested_targets":["android"]}],
         "has_more":false}
        """)
        transport.on("GET", "/projects/p1/mobile-publish/store-builds", """
        {"builds":[{"run_id":"r1","target":"ios","run_status":"succeeded","target_status":"succeeded","created_at":"2026-10-01T10:00:00Z",
                    "store_release":{"app_version":"1.0","build_number":7,"store_state":"processing","store_states":[]}}]}
        """)
        let client = makeClient(transport)
        let runs = try await client.iosBuildRuns(projectID: "p1")
        let builds = try await client.storeBuilds(projectID: "p1")
        XCTAssertEqual(runs.map(\.id), ["r1"], "android-only runs are left out")
        XCTAssertEqual(builds.first?.storeRelease?.label, "1.0 (7)")
        XCTAssertEqual(builds.first?.storeRelease?.stateLabel, "Apple la está procesando")
        let query = transport.requests[0].url!.query!
        XCTAssertTrue(query.contains("target=ios") && query.contains("flow=manual"))
    }
}
