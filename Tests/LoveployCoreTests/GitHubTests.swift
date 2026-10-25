import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class GitHubTests: XCTestCase {
    func repo(_ name: String, sha: String?, archived: Bool = false) -> GitHubRepo {
        GitHubRepo(
            fullName: "alereed/\(name)",
            name: name,
            url: "https://github.com/alereed/\(name)",
            defaultBranch: "main",
            head: sha.map { GitHubCommit(sha: $0, message: "msg", date: nil) },
            isArchived: archived
        )
    }

    func testRepositoriesPaginatesGraphQL() async throws {
        let transport = MockTransport()
        transport.on("POST", "/graphql", """
        {"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[
          {"nameWithOwner":"alereed/uno","name":"uno","url":"https://github.com/alereed/uno","isArchived":false,
           "defaultBranchRef":{"name":"main","target":{"oid":"aaa","message":"Fix header\\n\\nmore","committedDate":"2026-10-20T10:00:00Z"}}}]}}}}
        """)
        transport.on("POST", "/graphql", """
        {"data":{"viewer":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"nameWithOwner":"alereed/vacio","name":"vacio","url":"https://github.com/alereed/vacio","isArchived":true,
           "defaultBranchRef":null}]}}}}
        """)
        let repos = try await GitHubClient(token: "ghp_x", transport: transport).repositories()

        XCTAssertEqual(repos.map(\.fullName), ["alereed/uno", "alereed/vacio"])
        XCTAssertEqual(repos[0].head?.sha, "aaa")
        XCTAssertEqual(repos[0].head?.headline, "Fix header")
        XCTAssertNil(repos[1].head)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer ghp_x")
        let secondBody = String(decoding: transport.requests[1].httpBody!, as: UTF8.self)
        XCTAssertTrue(secondBody.contains("\"cursor\":\"c1\""))
    }

    func testCompareReturnsNewestFirst() async throws {
        let transport = MockTransport()
        transport.on("GET", "/repos/alereed/uno/compare/old...main", """
        {"status":"ahead","ahead_by":2,"behind_by":0,"commits":[
          {"sha":"c1","commit":{"message":"primero","committer":{"date":"2026-10-20T10:00:00Z"}}},
          {"sha":"c2","commit":{"message":"segundo","committer":{"date":"2026-10-21T10:00:00Z"}}}]}
        """)
        let comparison = try await GitHubClient(token: "t", transport: transport)
            .compare(repo: "alereed/uno", base: "old", head: "main")
        XCTAssertEqual(comparison.aheadBy, 2)
        XCTAssertEqual(comparison.commits.map(\.sha), ["c2", "c1"])
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

    func testSlugify() {
        XCTAssertEqual(slugify("Mi Proyecto Ñandú!"), "mi-proyecto-nandu")
        XCTAssertEqual(slugify("  landing--page_v2 "), "landing-page-v2")
    }

    func testMatchRepoPrefersCommitThenUniqueName() {
        let repos = [repo("otra-cosa", sha: "abc"), repo("mi-landing", sha: "zzz"), repo("viejo", sha: "x", archived: true)]
        XCTAssertEqual(matchRepo(projectName: "Lo que sea", latestCommitSha: "abc", repos: repos),
                       RepoLink(fullName: "alereed/otra-cosa", source: .commit))
        XCTAssertEqual(matchRepo(projectName: "Mi Landing", latestCommitSha: "nope", repos: repos),
                       RepoLink(fullName: "alereed/mi-landing", source: .name))
        XCTAssertNil(matchRepo(projectName: "Viejo", latestCommitSha: nil, repos: repos))
        XCTAssertNil(matchRepo(projectName: "Nada", latestCommitSha: nil, repos: repos))

        let duplicated = [repo("app", sha: "1"), GitHubRepo(fullName: "org/app", name: "app", url: "", defaultBranch: "main", head: nil)]
        XCTAssertNil(matchRepo(projectName: "App", latestCommitSha: nil, repos: duplicated))
    }

    func testRankReposPutsClosestNamesFirst() {
        let repos = [repo("zeta", sha: nil), repo("crm-ventas-api", sha: nil), repo("crm-ventas", sha: nil)]
        XCTAssertEqual(rankRepos(for: "CRM Ventas", repos: repos).map(\.name), ["crm-ventas", "crm-ventas-api", "zeta"])
    }

    func testGitHubChangesMakeProjectOutdated() {
        let record = PublishRecord(commitSha: "L1", publishedAt: Date(), githubSha: "G1")
        // Lovable unchanged, GitHub moved: outdated.
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "L1", lastEditedAt: nil, record: record,
                                            githubHeadSha: "G2"), .outdated)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "L1", lastEditedAt: nil, record: record,
                                            githubHeadSha: "G1"), .upToDate)

        // Published before linking: with shared SHAs, Lovable's recorded commit stands in for GitHub's.
        let old = PublishRecord(commitSha: "S1", publishedAt: Date())
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "S1", lastEditedAt: nil, record: old,
                                            githubHeadSha: "S2", sharesCommits: true), .outdated)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "S1", lastEditedAt: nil, record: old,
                                            githubHeadSha: "S2", sharesCommits: false), .upToDate)
    }

    func testLovableBehindGitHub() {
        let link = RepoLink(fullName: "alereed/uno", source: .commit)
        let status = GitHubStatus(link: link, repoURL: nil, head: GitHubCommit(sha: "new", message: "", date: nil))
        XCTAssertTrue(status.lovableIsBehind(latestCommitSha: "old"))
        XCTAssertFalse(status.lovableIsBehind(latestCommitSha: "new"))

        let byName = GitHubStatus(link: RepoLink(fullName: "alereed/uno", source: .name), repoURL: nil, head: status.head)
        XCTAssertFalse(byName.lovableIsBehind(latestCommitSha: "old"))
    }

    func testOldStateFilesStillLoad() throws {
        let json = #"{"records":{"prj_1":{"commitSha":"a","publishedAt":"2026-01-01T00:00:00Z"}},"excluded":["x"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LoveployState.self, from: Data(json.utf8))
        XCTAssertEqual(state.records["prj_1"]?.commitSha, "a")
        XCTAssertEqual(state.excluded, ["x"])
        XCTAssertTrue(state.repoLinks.isEmpty)
    }
}
