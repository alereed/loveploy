import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

/// Serves canned responses keyed by "METHOD path" and records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, String, [String: String])
    private let lock = NSLock()
    private var handlers: [String: [Handler]] = [:]
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

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
            _requests.append(request)
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

/// A session whose token is valid for an hour.
func signedInSession(transport: HTTPTransport = MockTransport()) -> LovableSession {
    LovableSession(
        credentials: LovableCredentials(refreshToken: "refresh-1", idToken: "id-1", expiresAt: Date().addingTimeInterval(3600)),
        transport: transport
    )
}

func makeClient(_ transport: MockTransport, session: LovableSession? = nil) -> LovableWebClient {
    LovableWebClient(session: session ?? signedInSession(transport: transport), transport: transport, sleep: { _ in })
}

func header(_ request: URLRequest, _ name: String) -> String? {
    request.value(forHTTPHeaderField: name)
}
