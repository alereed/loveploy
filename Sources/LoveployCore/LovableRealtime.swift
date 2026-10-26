import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One open WebSocket, reduced to what the realtime client needs (so tests can fake it).
public protocol RealtimeSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// Opens a WebSocket to `url` offering `protocols` as Sec-WebSocket-Protocol.
public typealias RealtimeConnector = @Sendable (_ url: URL, _ protocols: [String]) throws -> RealtimeSocket

/// A frame the realtime server sends.
public enum RealtimeFrame: Equatable, Sendable {
    /// A full snapshot for subscription `id`.
    case data(id: String, payload: Data)
    /// The subscription failed or was revoked.
    case error(id: String, message: String)
    /// Anything else (patches, resumes, keep-alives).
    case other

    public static func parse(_ text: String) -> RealtimeFrame {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String, let id = object["id"] as? String else { return .other }
        switch type {
        case "data":
            guard let payload = object["payload"],
                  let data = try? JSONSerialization.data(withJSONObject: payload) else { return .other }
            return .data(id: id, payload: data)
        case "error", "subscription_closed":
            return .error(id: id, message: describe(object["error"]) ?? type)
        default:
            return .other
        }
    }

    private static func describe(_ error: Any?) -> String? {
        if let text = error as? String { return text }
        if let object = error as? [String: Any] {
            return (object["message"] as? String) ?? (object["code"] as? String)
        }
        return nil
    }
}

/// Reads projects the way lovable.dev's editor does: a subscription on
/// `wss://api.lovable.dev/realtime` that answers with the whole project, including
/// `published_deployment` and `latest_commit_sha`, which `/details` leaves out.
public struct LovableRealtime: Sendable {
    let session: LovableSession
    let url: URL
    let connect: RealtimeConnector
    let timeout: TimeInterval
    let window: Int

    public init(
        session: LovableSession,
        url: URL = URL(string: "wss://api.lovable.dev/realtime")!,
        timeout: TimeInterval = 25,
        window: Int = 10,
        connect: @escaping RealtimeConnector = { try URLSessionRealtimeSocket.open(url: $0, protocols: $1) }
    ) {
        self.session = session
        self.url = url
        self.timeout = timeout
        self.window = max(1, window)
        self.connect = connect
    }

    static func subscribeMessage(id: String, projectID: String) -> String {
        let object: [String: Any] = ["type": "subscribe", "id": id, "name": "project", "params": ["projectId": projectID]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func unsubscribeMessage(id: String) -> String {
        #"{"id":"\#(id)","type":"unsubscribe"}"#
    }

    /// The full project for each ID that answered in time. Missing IDs are left out, so the
    /// caller can fall back to `/details` for them.
    public func projects(ids: [String]) async throws -> [String: ProjectDetails] {
        guard !ids.isEmpty else { return [:] }
        let token = try await session.idToken(forceRefresh: false)
        let socket = try connect(url, ["bearer", token])
        defer { socket.close() }

        var queue = ids[...]
        var pending: [String: String] = [:] // subscription → project
        var next = 0
        var found: [String: ProjectDetails] = [:]

        func subscribeMore() async throws {
            while pending.count < window, let projectID = queue.popFirst() {
                next += 1
                let id = "lp-\(next)"
                pending[id] = projectID
                try await socket.send(Self.subscribeMessage(id: id, projectID: projectID))
            }
        }

        // A socket read can't be cancelled, so the deadline closes the socket instead.
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            socket.close()
        }
        defer { timer.cancel() }
        try await subscribeMore()
        while !pending.isEmpty {
            let text: String
            do {
                text = try await socket.receive()
            } catch {
                // Timed out or dropped: keep what arrived, unless nothing did.
                if found.isEmpty { throw error }
                break
            }
            switch RealtimeFrame.parse(text) {
            case let .data(id, payload):
                guard let projectID = pending.removeValue(forKey: id) else { continue }
                if let project = Self.decodeProject(payload) {
                    found[projectID] = project
                }
                try? await socket.send(Self.unsubscribeMessage(id: id))
            case let .error(id, _):
                pending[id] = nil
            case .other:
                continue
            }
            try await subscribeMore()
        }
        return found
    }

    /// The payload is `{project: {...}}`; tolerate a bare project too.
    static func decodeProject(_ payload: Data) -> ProjectDetails? {
        struct Wrapper: Decodable { let project: ProjectDetails? }
        if let wrapped = try? LovableWebClient.decoder.decode(Wrapper.self, from: payload), let project = wrapped.project {
            return project
        }
        guard let project = try? LovableWebClient.decoder.decode(ProjectDetails.self, from: payload),
              project.id != nil || project.publishedDeployment != nil else { return nil }
        return project
    }
}

/// The real socket, on URLSessionWebSocketTask.
public final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public static func open(url: URL, protocols: [String]) throws -> RealtimeSocket {
        var request = URLRequest(url: url)
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("https://lovable.dev", forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionRealtimeSocket(task: task)
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
