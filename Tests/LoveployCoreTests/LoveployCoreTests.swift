import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

/// Serves canned responses keyed by "METHOD path" and records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, String, [String: String])
    private let lock = NSLock()
    private var handlers: [String: [Handler]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ method: String, _ path: String, status: Int = 200, headers: [String: String] = [:], _ body: String) {
        on(method, path) { _ in (status, body, headers) }
    }

    func on(_ method: String, _ path: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers["\(method) \(path)", default: []].append(handler)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let handler: Handler? = {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            guard var queue = handlers[key], !queue.isEmpty else { return nil }
            // The last handler for a route keeps answering once the others are used up.
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            handlers[key] = queue
            return next
        }()
        guard let handler else { throw URLError(.unsupportedURL) }
        let (status, body, headers) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

final class LoveployCoreTests: XCTestCase {
    func makeClient(_ transport: MockTransport) -> LovableClient {
        LovableClient(apiKey: "lov_test", transport: transport, sleep: { _ in })
    }

    func testListProjectsFollowsPaginationAndSendsHeaders() async throws {
        let transport = MockTransport()
        transport.on("GET", "/v1/projects", """
        {"data":[{"id":"prj_1","workspace_id":"ws","owner_id":null,"name":"Uno","description":null,"visibility":null,
          "latest_screenshot_url":null,"is_published":true,"publish_audience":"public","created_at":null,
          "last_edited_at":"2026-10-01T10:00:00.123Z"}],
         "pagination":{"has_more":true,"next_cursor":"abc"}}
        """)
        transport.on("GET", "/v1/projects", """
        {"data":[{"id":"prj_2","workspace_id":"ws","owner_id":null,"name":null,"description":null,"visibility":null,
          "latest_screenshot_url":null,"is_published":false,"publish_audience":null,"created_at":null,
          "last_edited_at":"2026-10-02T10:00:00Z"}],
         "pagination":{"has_more":false,"next_cursor":null}}
        """)

        let projects = try await makeClient(transport).listProjects(workspaceIDs: ["ws"])

        XCTAssertEqual(projects.map(\.id), ["prj_1", "prj_2"])
        XCTAssertEqual(projects[0].displayName, "Uno")
        XCTAssertEqual(projects[1].displayName, "prj_2")
        XCTAssertNotNil(projects[0].lastEditedAt)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Lovable-API-Key"), "lov_test")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Lovable-Version"), LovableClient.apiVersion)
        XCTAssertTrue(transport.requests[0].url!.query!.contains("workspace_id=ws"))
        XCTAssertTrue(transport.requests[1].url!.query!.contains("cursor=abc"))
    }

    func testAPIErrorsAreDecoded() async {
        let transport = MockTransport()
        transport.on("GET", "/v1/workspaces", status: 403, """
        {"type":"insufficient_scope","title":"Forbidden","status":403,"request_id":"r1","detail":null,"errors":null,"props":null}
        """)
        do {
            _ = try await makeClient(transport).listWorkspaces()
            XCTFail("expected an error")
        } catch let error as LovableAPIError {
            XCTAssertEqual(error.type, "insufficient_scope")
            XCTAssertEqual(error.requestId, "r1")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGetRetriesOnRateLimit() async throws {
        let transport = MockTransport()
        transport.on("GET", "/v1/workspaces", status: 429, headers: ["Retry-After": "1"], "{}")
        transport.on("GET", "/v1/workspaces", """
        {"data":[{"id":"ws","name":"Mi workspace","description":null,"image_url":null,"plan":"business",
          "num_projects":3,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],
         "pagination":{"has_more":false,"next_cursor":null}}
        """)
        let workspaces = try await makeClient(transport).listWorkspaces()
        XCTAssertEqual(workspaces.first?.name, "Mi workspace")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testDeployStateEvaluation() {
        let edited = Date(timeIntervalSince1970: 2_000)
        let record = PublishRecord(commitSha: "aaa", publishedAt: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(DeployState.evaluate(isPublished: false, latestCommitSha: "aaa", lastEditedAt: edited, record: record), .unpublished)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "aaa", lastEditedAt: edited, record: nil), .unknown)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "aaa", lastEditedAt: edited, record: record), .upToDate)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: "bbb", lastEditedAt: edited, record: record), .outdated)

        let noSha = PublishRecord(commitSha: nil, publishedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: nil, lastEditedAt: edited, record: noSha), .outdated)
        XCTAssertEqual(DeployState.evaluate(isPublished: true, latestCommitSha: nil, lastEditedAt: nil, record: noSha), .upToDate)
    }

    func testInclusionRules() {
        func row(_ id: String, published: Bool, sha: String?, recordSha: String?) -> ProjectRow {
            ProjectRow(
                summary: ProjectSummary(id: id, workspaceId: "ws", name: id, isPublished: published),
                workspaceName: "ws",
                latestCommitSha: sha,
                record: recordSha.map { PublishRecord(commitSha: $0, publishedAt: Date()) }
            )
        }
        let outdated = row("a", published: true, sha: "2", recordSha: "1")
        let upToDate = row("b", published: true, sha: "1", recordSha: "1")
        let unpublished = row("c", published: false, sha: "1", recordSha: nil)

        XCTAssertTrue(isIncluded(outdated, excluded: [], overrides: [:]))
        XCTAssertFalse(isIncluded(outdated, excluded: ["a"], overrides: [:]))
        XCTAssertFalse(isIncluded(upToDate, excluded: [], overrides: [:]))
        XCTAssertFalse(isIncluded(unpublished, excluded: [], overrides: [:]))
        XCTAssertTrue(isIncluded(upToDate, excluded: [], overrides: ["b": true]))
    }

    func testDeployerPublishesPollsAndRecordsCommit() async {
        let transport = MockTransport()
        transport.on("GET", "/v1/projects/prj_1", #"{"id":"prj_1","latest_commit_sha":"c0ffee","preview_url":null,"is_published":true}"#)
        transport.on("POST", "/v1/projects/prj_1/publish", status: 202,
                     #"{"id":"dep1","status":"running","url":null,"error_message":null,"error_class":null}"#)
        transport.on("GET", "/v1/projects/prj_1/publish/dep1",
                     #"{"id":"dep1","status":"running","url":null,"error_message":null,"error_class":null}"#)
        transport.on("GET", "/v1/projects/prj_1/publish/dep1",
                     #"{"id":"dep1","status":"completed","url":"https://uno.lovable.app","error_message":null,"error_class":null}"#)

        transport.on("GET", "/v1/projects/prj_2", #"{"id":"prj_2","latest_commit_sha":"bad","preview_url":null,"is_published":true}"#)
        transport.on("POST", "/v1/projects/prj_2/publish", status: 202,
                     #"{"id":"dep2","status":"error","url":null,"error_message":"Build failed","error_class":"code"}"#)

        let client = makeClient(transport)
        let collected = Collected()
        await Deployer(maxConcurrent: 2).run(
            jobs: [("prj_1", client), ("prj_2", client)],
            onUpdate: { id, progress in await collected.update(id, progress) },
            onRecord: { id, record in await collected.record(id, record) }
        )

        let progress = await collected.progress
        let records = await collected.records
        XCTAssertEqual(progress["prj_1"], .completed(url: "https://uno.lovable.app"))
        guard case .failed(let message) = progress["prj_2"] else {
            return XCTFail("prj_2 should fail")
        }
        XCTAssertTrue(message.contains("Build failed"))
        XCTAssertEqual(records["prj_1"]?.commitSha, "c0ffee")
        XCTAssertEqual(records["prj_1"]?.url, "https://uno.lovable.app")
        XCTAssertNil(records["prj_2"])
        let body = transport.requests.first { $0.httpMethod == "POST" }?.httpBody
        XCTAssertEqual(body.map { String(decoding: $0, as: UTF8.self) }, "{}")
    }

    func testStateStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.json")
        let store = StateStore(fileURL: url)
        XCTAssertEqual(store.load(), LoveployState())

        let state = LoveployState(
            records: ["prj_1": PublishRecord(commitSha: "abc", publishedAt: Date(timeIntervalSince1970: 1_700_000_000), url: "https://x")],
            excluded: ["prj_9"]
        )
        try store.save(state)
        XCTAssertEqual(store.load(), state)
    }
}

actor Collected {
    var progress: [String: DeployProgress] = [:]
    var records: [String: PublishRecord] = [:]

    func update(_ id: String, _ value: DeployProgress) { progress[id] = value }
    func record(_ id: String, _ value: PublishRecord) { records[id] = value }
}
