import XCTest
@testable import LoveployCore

final class TurboTests: XCTestCase {
    let workspace = Workspace(id: "ws", name: "WS")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func row(_ id: String, latest: String, live: String = "live", secrets: String? = nil) -> ProjectRow {
        ProjectRow(
            summary: ProjectSummary(id: id),
            workspace: workspace,
            details: ProjectDetails(
                id: id,
                isPublished: true,
                latestCommitSha: latest,
                publishedDeployment: .init(commitSha: live, previewSecretsHash: secrets, secretsHash: secrets, hasPreviewSecretsHash: secrets != nil)
            )
        )
    }

    func testWaitsForChangesToSettle() {
        var planner = TurboPlanner(settleDelay: 300)
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c1")], excluded: [], now: t0), [])
        XCTAssertEqual(planner.publishDate(for: row("a", latest: "c1"), excluded: []), t0.addingTimeInterval(300))
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c1")], excluded: [], now: t0 + 200), [])
        // A new commit restarts the wait.
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c2")], excluded: [], now: t0 + 299), [])
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c2")], excluded: [], now: t0 + 500), [])
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c2")], excluded: [], now: t0 + 599), ["a"])
    }

    func testZeroDelayPublishesRightAway() {
        var planner = TurboPlanner(settleDelay: 0)
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c1")], excluded: [], now: t0), ["a"])
    }

    func testSkipsExcludedAndUpToDate() {
        var planner = TurboPlanner(settleDelay: 0)
        let rows = [row("a", latest: "c1"), row("b", latest: "live"), row("c", latest: "c9")]
        XCTAssertEqual(planner.ready(rows: rows, excluded: ["c"], now: t0), ["a"])
        XCTAssertNil(planner.publishDate(for: rows[2], excluded: ["c"]))
    }

    func testFailedVersionIsNotRetriedUntilItChanges() {
        var planner = TurboPlanner(settleDelay: 0)
        let failing = row("a", latest: "c1")
        XCTAssertEqual(planner.ready(rows: [failing], excluded: [], now: t0), ["a"])
        planner.recordFailure(projectID: "a", version: TurboPlanner.version(of: failing))
        XCTAssertTrue(planner.didFail(failing))
        XCTAssertEqual(planner.ready(rows: [failing], excluded: [], now: t0 + 600), [])
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c2")], excluded: [], now: t0 + 700), ["a"])
    }

    func testJustPublishedVersionIsNotPublishedTwice() {
        var planner = TurboPlanner(settleDelay: 0)
        let outdated = row("a", latest: "c1")
        XCTAssertEqual(planner.ready(rows: [outdated], excluded: [], now: t0), ["a"])
        planner.recordSuccess(projectID: "a", version: TurboPlanner.version(of: outdated))
        // Lovable still reports the old live commit for a moment.
        XCTAssertEqual(planner.ready(rows: [outdated], excluded: [], now: t0 + 60), [])
        XCTAssertNil(planner.publishDate(for: outdated, excluded: []))
        // The next change goes out.
        XCTAssertEqual(planner.ready(rows: [row("a", latest: "c2")], excluded: [], now: t0 + 120), ["a"])
    }

    func testSecretChangesCountAsNewVersion() {
        XCTAssertNotEqual(TurboPlanner.version(of: row("a", latest: "c1", secrets: "s1")),
                          TurboPlanner.version(of: row("a", latest: "c1", secrets: "s2")))
    }

    func testSettingsPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json")
        let store = StateStore(fileURL: url)
        try store.save(LoveployState(excluded: ["x"], turbo: true, turboDelayMinutes: 10))
        let loaded = store.load()
        XCTAssertTrue(loaded.turbo)
        XCTAssertEqual(loaded.turboDelayMinutes, 10)
        try Data(#"{"excluded":["x"]}"#.utf8).write(to: url)
        XCTAssertFalse(store.load().turbo)
        XCTAssertEqual(store.load().turboDelayMinutes, 5)
    }
}
