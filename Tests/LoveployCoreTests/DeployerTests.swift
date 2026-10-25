import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class DeployerTests: XCTestCase {
    func testPublishesFollowsProgressAndReportsFailures() async {
        let transport = MockTransport()
        transport.on("POST", "/projects/p1/deployments", #"{"deployment_id":"d1"}"#)
        transport.on("GET", "/projects/p1/deployments/d1/progress", #"{"status":"running","step":"Building"}"#)
        transport.on("GET", "/projects/p1/deployments/d1/progress", #"{"status":"completed","url":"https://uno.lovable.app","head_commit_sha":"abc"}"#)

        transport.on("POST", "/projects/p2/deployments", #"{"deployment_id":"d2"}"#)
        transport.on("GET", "/projects/p2/deployments/d2/progress",
                     #"{"status":"error","error_message":"Build failed","error_class":"code"}"#)

        // A progress record that vanished counts as done, like on lovable.dev.
        transport.on("POST", "/projects/p3/deployments", #"{"deployment_id":"d3"}"#)
        transport.on("GET", "/projects/p3/deployments/d3/progress", status: 404, #"{"type":"not_found"}"#)

        let collected = Collected()
        await Deployer(maxConcurrent: 2).run(projectIDs: ["p1", "p2", "p3"], client: makeClient(transport)) { id, progress in
            await collected.update(id, progress)
        }

        let final = await collected.latest
        XCTAssertEqual(final["p1"], .completed(url: "https://uno.lovable.app"))
        XCTAssertEqual(final["p3"], .completed(url: nil))
        guard case .failed(let message) = final["p2"] else {
            return XCTFail("p2 should fail")
        }
        XCTAssertTrue(message.contains("Build failed"))
        XCTAssertTrue(message.contains("código"))
        let steps = await collected.history["p1"] ?? []
        XCTAssertTrue(steps.contains(.publishing(step: "Building")))
        let body = transport.requests.first { $0.httpMethod == "POST" }?.httpBody
        XCTAssertEqual(body.map { String(decoding: $0, as: UTF8.self) }, "{}")
    }
}

actor Collected {
    var latest: [String: DeployProgress] = [:]
    var history: [String: [DeployProgress]] = [:]

    func update(_ id: String, _ value: DeployProgress) {
        latest[id] = value
        history[id, default: []].append(value)
    }
}
