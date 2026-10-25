import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to api.lovable.dev the way lovable.dev's own web app does: with the
/// signed-in user's Firebase ID token. No API key, no MCP.
public struct LovableWebClient: Sendable {
    let session: LovableSession
    let baseURL: URL
    let transport: HTTPTransport
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        session: LovableSession,
        baseURL: URL = URL(string: "https://api.lovable.dev")!,
        transport: HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: - Endpoints

    public func workspaces() async throws -> [Workspace] {
        let response: WorkspacesResponse = try await request("GET", "/user/workspaces")
        return response.workspaces ?? []
    }

    public func projects(workspaceID: String) async throws -> [ProjectSummary] {
        var projects: [ProjectSummary] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "limit", value: "50")]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: ProjectPage = try await request("GET", "/v2/workspaces/\(workspaceID)/projects", query: query)
            projects += page.projects ?? []
            cursor = (page.hasMore ?? false) ? page.nextCursor : nil
        } while cursor != nil && !(cursor?.isEmpty ?? true)
        return projects
    }

    public func details(projectID: String) async throws -> ProjectDetails {
        try await request("GET", "/projects/\(projectID)/details")
    }

    /// What the Publish / Update button does. Returns the deployment ID to follow.
    public func startDeployment(projectID: String) async throws -> String {
        let started: DeploymentStarted = try await request("POST", "/projects/\(projectID)/deployments", body: Data("{}".utf8), retryRateLimit: false)
        return started.deploymentId
    }

    public func deploymentProgress(projectID: String, deploymentID: String) async throws -> DeploymentProgress {
        do {
            return try await request("GET", "/projects/\(projectID)/deployments/\(deploymentID)/progress")
        } catch let error as LovableError where error.status == 404 {
            // lovable.dev treats a vanished progress record as finished.
            return DeploymentProgress(status: "completed")
        }
    }

    public func gitSync(workspaceID: String, projectID: String) async throws -> GitSyncInfo {
        try await request("GET", "/workspaces/\(workspaceID)/projects/\(projectID)/gitsync")
    }

    public func gitSyncStatus(workspaceID: String, projectID: String) async throws -> GitSyncStatus {
        try await request("GET", "/workspaces/\(workspaceID)/projects/\(projectID)/gitsync/sync-status")
    }

    // MARK: - Plumbing

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        retryRateLimit: Bool = true
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://lovable.dev", forHTTPHeaderField: "Origin")
        request.setValue("https://lovable.dev/", forHTTPHeaderField: "Referer")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var forceRefresh = false
        var rateLimitRetries = 0
        while true {
            request.setValue("Bearer \(try await session.idToken(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            if (200..<300).contains(response.statusCode) {
                return try Self.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
            }
            var error = (try? Self.decoder.decode(LovableError.self, from: data)) ?? LovableError(status: response.statusCode)
            error.status = response.statusCode
            // An expired token: renew once and retry.
            if error.isAuthFailure, !forceRefresh {
                forceRefresh = true
                continue
            }
            if response.statusCode == 429, retryRateLimit, rateLimitRetries < 3 {
                rateLimitRetries += 1
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
                try await sleep(min(retryAfter, 60))
                continue
            }
            throw error
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
            }
            let string = try container.decode(String.self)
            if let date = parseISO8601(string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(string)"))
        }
        return decoder
    }()
}

func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
