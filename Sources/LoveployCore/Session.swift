import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something that can perform an HTTP request. Lets tests swap out the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }
}

/// The Firebase credentials lovable.dev keeps in the browser after you sign in.
public struct LovableCredentials: Codable, Hashable, Sendable {
    public var refreshToken: String
    public var idToken: String?
    /// When `idToken` stops being valid.
    public var expiresAt: Date?
    public var email: String?
    public var uid: String?

    public init(refreshToken: String, idToken: String? = nil, expiresAt: Date? = nil, email: String? = nil, uid: String? = nil) {
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.email = email
        self.uid = uid
    }
}

public enum SessionError: Error, LocalizedError, Sendable {
    case signedOut
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Inicia sesión en Lovable."
        case .refreshFailed(let reason): return "No se pudo renovar la sesión de Lovable (\(reason)). Vuelve a iniciar sesión."
        }
    }
}

/// Keeps a valid ID token for api.lovable.dev, renewing it the same way the
/// Firebase SDK in lovable.dev does (Secure Token API with the refresh token).
public actor LovableSession {
    /// lovable.dev's public Firebase web config.
    public static let firebaseAPIKey = "AIzaSyBQNjlw9Vp4tP4VVeANzyPJnqbG2wLbYPw"

    private var credentials: LovableCredentials?
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let onChange: @Sendable (LovableCredentials?) -> Void
    /// Last resort when the refresh endpoint refuses us: read a fresh token from a
    /// signed-in lovable.dev page.
    private let fallback: (@Sendable () async throws -> LovableCredentials)?
    private var refreshing: Task<String, Error>?

    public init(
        credentials: LovableCredentials?,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        fallback: (@Sendable () async throws -> LovableCredentials)? = nil,
        onChange: @escaping @Sendable (LovableCredentials?) -> Void = { _ in }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.fallback = fallback
        self.onChange = onChange
    }

    public var current: LovableCredentials? { credentials }

    public func signIn(_ credentials: LovableCredentials) {
        self.credentials = credentials
        onChange(credentials)
    }

    public func signOut() {
        credentials = nil
        refreshing?.cancel()
        refreshing = nil
        onChange(nil)
    }

    /// A token valid for at least another minute. `forceRefresh` after a 401.
    public func idToken(forceRefresh: Bool = false) async throws -> String {
        guard let credentials else { throw SessionError.signedOut }
        if !forceRefresh, let token = credentials.idToken, let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSince(now()) > 60 {
            return token
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let refreshToken = credentials?.refreshToken else { throw SessionError.signedOut }
        do {
            let renewed = try await Self.exchange(refreshToken: refreshToken, transport: transport, now: now())
            return store(renewed)
        } catch let error as SessionError {
            guard let fallback else { throw error }
            let renewed = try await fallback()
            return store(renewed)
        }
    }

    private func store(_ renewed: LovableCredentials) -> String {
        var merged = renewed
        merged.email = merged.email ?? credentials?.email
        merged.uid = merged.uid ?? credentials?.uid
        credentials = merged
        onChange(merged)
        return merged.idToken ?? ""
    }

    static func exchange(refreshToken: String, transport: HTTPTransport, now: Date) async throws -> LovableCredentials {
        struct Response: Decodable {
            let idToken: String
            let refreshToken: String?
            let expiresIn: String?
            let userId: String?
        }
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(firebaseAPIKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // The key is restricted to lovable.dev, like any browser key.
        request.setValue("https://lovable.dev/", forHTTPHeaderField: "Referer")
        request.setValue("https://lovable.dev", forHTTPHeaderField: "Origin")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable {
                struct Inner: Decodable { let message: String? }
                let error: Inner?
            }
            let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message ?? "HTTP \(response.statusCode)"
            throw SessionError.refreshFailed(reason)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(Response.self, from: data)
        let lifetime = body.expiresIn.flatMap(TimeInterval.init) ?? 3600
        return LovableCredentials(
            refreshToken: body.refreshToken ?? refreshToken,
            idToken: body.idToken,
            expiresAt: now.addingTimeInterval(lifetime),
            uid: body.userId
        )
    }
}
