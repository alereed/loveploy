import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class GitHubTests: XCTestCase {
    func testCompareReturnsNewestFirst() async throws {
        let transport = MockTransport()
        transport.on("GET", "/repos/alereed/uno/compare/old...main", """
        {"status":"ahead","ahead_by":2,"behind_by":0,"commits":[
          {"sha":"c1","commit":{"message":"primero","committer":{"date":"2026-10-20T10:00:00Z"}}},
          {"sha":"c2","commit":{"message":"segundo\\n\\ndetalle","committer":{"date":"2026-10-21T10:00:00Z"}}}]}
        """)
        let comparison = try await GitHubClient(token: "t", transport: transport)
            .compare(repo: "alereed/uno", base: "old", head: "main")
        XCTAssertEqual(comparison.aheadBy, 2)
        XCTAssertEqual(comparison.commits.map(\.sha), ["c2", "c1"])
        XCTAssertEqual(comparison.commits[0].headline, "segundo")
        XCTAssertEqual(header(transport.requests[0], "Authorization"), "Bearer t")
    }

    func testGitHubErrors() async {
        let transport = MockTransport()
        transport.on("GET", "/user", status: 401, #"{"message":"Bad credentials"}"#)
        do {
            _ = try await GitHubClient(token: "t", transport: transport).viewerLogin()
            XCTFail("expected an error")
        } catch let error as GitHubError {
            XCTAssertEqual(error.status, 401)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
