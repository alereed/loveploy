import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class ClientTests: XCTestCase {
    func testWorkspacesAndPaginatedProjects() async throws {
        let transport = MockTransport()
        transport.on("GET", "/user/workspaces", #"{"workspaces":[{"id":"ws1","name":"Blender","plan":"pro"}]}"#)
        transport.on("GET", "/v2/workspaces/ws1/projects", """
        {"projects":[{"id":"p1","name":"uno","display_name":"Uno","is_published":true,"last_edited_at":"2026-10-01T10:00:00.123Z"},
                     {"id":"p2","name":"dos","last_edited_at":{"weird":true}}],
         "has_more":true,"next_cursor":"c1"}
        """)
        transport.on("GET", "/v2/workspaces/ws1/projects", #"{"projects":[{"id":"p3"}],"has_more":false,"next_cursor":null}"#)

        let client = makeClient(transport)
        let workspaces = try await client.workspaces()
        let projects = try await client.projects(workspaceID: "ws1")

        XCTAssertEqual(workspaces.map(\.displayName), ["Blender"])
        XCTAssertEqual(projects.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(projects.map(\.label), ["Uno", "dos", "p3"])
        XCTAssertEqual(projects[0].isPublished, true)
        XCTAssertNotNil(projects[0].editedAt)
        XCTAssertNil(projects[1].editedAt, "an odd field doesn't break the list")
        let first = transport.requests[0]
        XCTAssertEqual(header(first, "Authorization"), "Bearer id-1")
        XCTAssertEqual(first.url?.host, "api.lovable.dev")
        XCTAssertTrue(transport.requests[2].url!.query!.contains("cursor=c1"))
    }

    func testDetailsDecodePublishedDeployment() async throws {
        let transport = MockTransport()
        transport.on("GET", "/projects/p1/details", """
        {"id":"p1","workspace_id":"ws1","is_published":true,"latest_commit_sha":"bbb","url":"https://uno.lovable.app",
         "published_deployment":{"id":"d1","commit_sha":"aaa","head_commit_sha":"aaa",
           "target_metadata":{"preview_secrets_hash":"x","secrets_hash":"x","other":{"nested":1}}},
         "something_else":[1,2,3]}
        """)
        let details = try await makeClient(transport).details(projectID: "p1")
        XCTAssertEqual(details.latestCommitSha, "bbb")
        XCTAssertEqual(details.publishedDeployment?.commitSha, "aaa")
        XCTAssertEqual(details.publishedDeployment?.secretsChanged, false)
        XCTAssertEqual(details.url, "https://uno.lovable.app")
        XCTAssertEqual(DeployState.evaluate(details), .outdated)
    }

    func testExpiredTokenIsRenewedAndRequestRetried() async throws {
        let transport = MockTransport()
        transport.on("GET", "/user/workspaces", status: 401, #"{"type":"authentication_failed","message":"expired"}"#)
        transport.on("GET", "/user/workspaces", #"{"workspaces":[]}"#)
        transport.on("POST", "/v1/token", #"{"id_token":"id-2","refresh_token":"refresh-2","expires_in":"3600"}"#)

        _ = try await makeClient(transport).workspaces()

        let api = transport.requests.filter { $0.url?.host == "api.lovable.dev" }
        XCTAssertEqual(api.count, 2)
        XCTAssertEqual(header(api[1], "Authorization"), "Bearer id-2")
    }

    func testErrorsCarryStatusAndMessage() async {
        let transport = MockTransport()
        transport.on("POST", "/projects/p1/deployments", status: 403, #"{"type":"forbidden","message":"nope"}"#)
        do {
            _ = try await makeClient(transport).startDeployment(projectID: "p1")
            XCTFail("expected an error")
        } catch let error as LovableError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.type, "forbidden")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testGitSyncEndpoints() async throws {
        let transport = MockTransport()
        transport.on("GET", "/workspaces/ws1/projects/p1/gitsync", """
        {"config":{"owner_name":"alereed","repo_name":"uno","main_branch":"main","repo_url":"https://github.com/alereed/uno","provider_type":"github"}}
        """)
        transport.on("GET", "/workspaces/ws1/projects/p1/gitsync/sync-status", #"{"state":"remote_ahead","ahead":0,"behind":2,"capped":false}"#)
        let client = makeClient(transport)
        let info = try await client.gitSync(workspaceID: "ws1", projectID: "p1")
        let status = try await client.gitSyncStatus(workspaceID: "ws1", projectID: "p1")
        XCTAssertEqual(info.fullName, "alereed/uno")
        XCTAssertEqual(info.config?.mainBranch, "main")
        XCTAssertEqual(status.state, "remote_ahead")
        XCTAssertEqual(status.behind, 2)
        XCTAssertNil(GitSyncInfo(config: nil).fullName)
    }
}
