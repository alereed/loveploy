import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class StateTests: XCTestCase {
    typealias Deployment = ProjectDetails.PublishedDeployment

    func details(published: Bool = true, latest: String?, live: String?, head: String? = nil, secrets: (String?, String?)? = nil) -> ProjectDetails {
        ProjectDetails(
            id: "p",
            isPublished: published,
            latestCommitSha: latest,
            publishedDeployment: live.map {
                Deployment(commitSha: $0, headCommitSha: head, previewSecretsHash: secrets?.0, secretsHash: secrets?.1, hasPreviewSecretsHash: secrets != nil)
            }
        )
    }

    func testSameRuleAsLovablePublishButton() {
        XCTAssertEqual(DeployState.evaluate(details(published: false, latest: "a", live: nil)), .unpublished)
        XCTAssertEqual(DeployState.evaluate(details(latest: "a", live: nil)), .unknown)
        XCTAssertEqual(DeployState.evaluate(details(latest: "a", live: "a")), .upToDate)
        XCTAssertEqual(DeployState.evaluate(details(latest: "b", live: "a")), .outdated)
        // The live build can be on a head commit after the deployment commit.
        XCTAssertEqual(DeployState.evaluate(details(latest: "b", live: "a", head: "b")), .upToDate)
        // Changed secrets need a republish even with the same code.
        XCTAssertEqual(DeployState.evaluate(details(latest: "a", live: "a", secrets: ("new", "old"))), .outdated)
        XCTAssertEqual(DeployState.evaluate(details(latest: "a", live: "a", secrets: ("same", "same"))), .upToDate)
        XCTAssertEqual(DeployState.evaluate(nil, listedAsPublished: false), .unpublished)
        XCTAssertEqual(DeployState.evaluate(nil, listedAsPublished: true), .unknown)
    }

    func testInclusionRules() {
        func row(_ id: String, _ details: ProjectDetails) -> ProjectRow {
            ProjectRow(summary: ProjectSummary(id: id), workspace: Workspace(id: "ws", name: "WS"), details: details)
        }
        let outdated = row("a", details(latest: "2", live: "1"))
        let upToDate = row("b", details(latest: "1", live: "1"))
        let unpublished = row("c", details(published: false, latest: "1", live: nil))

        XCTAssertTrue(isIncluded(outdated, excluded: [], overrides: [:]))
        XCTAssertFalse(isIncluded(outdated, excluded: ["a"], overrides: [:]))
        XCTAssertFalse(isIncluded(upToDate, excluded: [], overrides: [:]))
        XCTAssertFalse(isIncluded(unpublished, excluded: [], overrides: [:]))
        XCTAssertTrue(isIncluded(upToDate, excluded: [], overrides: ["b": true]))
        XCTAssertTrue(isIncluded(unpublished, excluded: [], overrides: ["c": true]))
    }

    func testGitStatusFlagsRemoteAhead() {
        XCTAssertTrue(GitStatus(repo: "a/b", syncState: "remote_ahead").remoteAhead)
        XCTAssertTrue(GitStatus(repo: "a/b", syncState: "diverged").remoteAhead)
        XCTAssertFalse(GitStatus(repo: "a/b", syncState: "in_sync").remoteAhead)
    }

    func testStateStoreRoundTripAndOldFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        let store = StateStore(fileURL: url)
        XCTAssertEqual(store.load(), LoveployState())
        try store.save(LoveployState(excluded: ["p9"]))
        XCTAssertEqual(store.load().excluded, ["p9"])

        // A file from the API-key version still loads its exclusions.
        try Data(#"{"records":{"x":{"commitSha":"a","publishedAt":"2026-01-01T00:00:00Z"}},"excluded":["x"],"repoLinks":{}}"#.utf8).write(to: url)
        XCTAssertEqual(store.load().excluded, ["x"])
    }
}
