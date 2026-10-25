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

/// Minimal client for the Lovable public API (https://docs.lovable.dev/api-reference).
public struct LovableClient: Sendable {
    public static let apiVersion = "2026-09-11"

    let apiKey: String
    let baseURL: URL
    let transport: HTTPTransport
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.lovable.dev")!,
        transport: HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: - Endpoints

    public func listWorkspaces() async throws -> [Workspace] {
        try await paginate(path: "/v1/workspaces", query: [])
    }

    public func listProjects(workspaceIDs: [String]) async throws -> [ProjectSummary] {
        try await paginate(path: "/v1/projects", query: workspaceIDs.map { URLQueryItem(name: "workspace_id", value: $0) })
    }

    public func getProject(id: String) async throws -> ProjectDetail {
        try await request("GET", path: "/v1/projects/\(id)")
    }

    /// Starts an asynchronous build and deploy. Keeps the current publish audience.
    public func publish(projectID: String) async throws -> Deployment {
        try await request("POST", path: "/v1/projects/\(projectID)/publish", body: Data("{}".utf8), retryRateLimit: false)
    }

    public func publishStatus(projectID: String, deploymentID: String) async throws -> Deployment {
        try await request("GET", path: "/v1/projects/\(projectID)/publish/\(deploymentID)")
    }

    /// Polls a deployment until it finishes, backing off from 2s toward 10s as the docs ask.
    public func waitForDeployment(
        projectID: String,
        deployment: Deployment,
        timeout: TimeInterval = 15 * 60
    ) async throws -> Deployment {
        var current = deployment
        var delay: TimeInterval = 2
        var waited: TimeInterval = 0
        while !current.isTerminal {
            if waited >= timeout {
                return current
            }
            try await sleep(delay)
            waited += delay
            delay = min(delay * 1.5, 10)
            current = try await publishStatus(projectID: projectID, deploymentID: current.id)
        }
        return current
    }

    // MARK: - Plumbing

    private func paginate<Item: Decodable>(path: String, query: [URLQueryItem]) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        repeat {
            var pageQuery = query + [URLQueryItem(name: "limit", value: "100")]
            if let cursor {
                pageQuery.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: Page<Item> = try await request("GET", path: path, query: pageQuery)
            items += page.data
            cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
        } while cursor != nil
        return items
    }

    private func request<T: Decodable>(
        _ method: String,
        path: String,
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
        request.setValue(apiKey, forHTTPHeaderField: "Lovable-API-Key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Lovable-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var attempts = 0
        while true {
            let (data, response) = try await transport.send(request)
            if (200..<300).contains(response.statusCode) {
                return try Self.decoder.decode(T.self, from: data)
            }
            // Reads are safe to retry on 429; a POST may already have taken effect.
            if response.statusCode == 429, retryRateLimit, attempts < 3 {
                attempts += 1
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
                try await sleep(min(retryAfter, 60))
                continue
            }
            if let apiError = try? Self.decoder.decode(LovableAPIError.self, from: data) {
                throw apiError
            }
            throw LovableAPIError(
                type: "http_\(response.statusCode)",
                title: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                status: response.statusCode
            )
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
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
