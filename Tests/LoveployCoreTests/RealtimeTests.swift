import Foundation
import XCTest
@testable import LoveployCore

/// Answers each subscribe with whatever `reply` returns, in order.
final class FakeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var sent: [String] = []
    let reply: (_ id: String, _ projectID: String) -> String?

    init(reply: @escaping (_ id: String, _ projectID: String) -> String?) {
        self.reply = reply
    }

    func send(_ text: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        lock.withLock { sent.append(text) }
        guard object["type"] as? String == "subscribe",
              let id = object["id"] as? String,
              let projectID = (object["params"] as? [String: String])?["projectId"],
              let answer = reply(id, projectID) else { return }
        deliver(answer)
    }

    private func deliver(_ text: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            inbox.append(text)
            lock.unlock()
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let text = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: URLError(.cancelled))
    }
}

final class RealtimeTests: XCTestCase {
    func testParsesFrames() {
        XCTAssertEqual(RealtimeFrame.parse(#"{"type":"error","id":"a","error":{"message":"forbidden"}}"#), .error(id: "a", message: "forbidden"))
        XCTAssertEqual(RealtimeFrame.parse(#"{"type":"subscription_closed","id":"a"}"#), .error(id: "a", message: "subscription_closed"))
        XCTAssertEqual(RealtimeFrame.parse(#"{"type":"patch","id":"a","ops":[]}"#), .other)
        XCTAssertEqual(RealtimeFrame.parse("no json"), .other)
        guard case let .data(id, payload) = RealtimeFrame.parse(#"{"type":"data","id":"x","v":3,"payload":{"project":{"id":"p"}}}"#) else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(id, "x")
        XCTAssertEqual(RealtimeFrame.parse(String(decoding: payload, as: UTF8.self)), .other)
    }

    func testSubscribeMessage() throws {
        let text = LovableRealtime.subscribeMessage(id: "lp-1", projectID: "abc")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "subscribe")
        XCTAssertEqual(object["name"] as? String, "project")
        XCTAssertEqual(object["params"] as? [String: String], ["projectId": "abc"])
    }

    func testReadsWholeProjectsAndSkipsFailures() async throws {
        final class Opened: @unchecked Sendable { var url: URL?; var protocols: [String]? }
        let opened = Opened()
        let socket = FakeSocket { id, projectID in
            switch projectID {
            case "p1":
                return #"{"type":"data","id":"\#(id)","v":1,"payload":{"project":{"id":"p1","is_published":true,"latest_commit_sha":"bbb","published_deployment":{"id":"d","commit_sha":"aaa"}}}}"#
            case "p2":
                return #"{"type":"data","id":"\#(id)","v":1,"payload":{"project":{"id":"p2","is_published":true,"latest_commit_sha":"ccc","published_deployment":{"commit_sha":"ccc"}}}}"#
            default:
                return #"{"type":"error","id":"\#(id)","error":"not_found"}"#
            }
        }
        let realtime = LovableRealtime(session: signedInSession(), timeout: 5, window: 2) { url, protocols in
            opened.url = url
            opened.protocols = protocols
            return socket
        }
        let projects = try await realtime.projects(ids: ["p1", "p2", "p3"])
        XCTAssertEqual(opened.url?.absoluteString, "wss://api.lovable.dev/realtime")
        XCTAssertEqual(opened.protocols, ["bearer", "id-1"])
        XCTAssertEqual(Set(projects.keys), ["p1", "p2"])
        XCTAssertEqual(DeployState.evaluate(projects["p1"]), .outdated)
        XCTAssertEqual(DeployState.evaluate(projects["p2"]), .upToDate)
        XCTAssertTrue(socket.sent.contains { $0.contains("unsubscribe") })
    }

    func testTimesOutWithWhatArrived() async throws {
        let socket = FakeSocket { id, projectID in
            projectID == "fast"
                ? #"{"type":"data","id":"\#(id)","payload":{"project":{"id":"fast","is_published":false}}}"#
                : nil
        }
        let realtime = LovableRealtime(session: signedInSession(), timeout: 0.3) { _, _ in socket }
        let projects = try await realtime.projects(ids: ["fast", "slow"])
        XCTAssertEqual(Array(projects.keys), ["fast"])
        XCTAssertEqual(DeployState.evaluate(projects["fast"]), .unpublished)
    }
}
