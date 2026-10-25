import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubCommit: Hashable, Sendable {
    public let sha: String
    public let message: String
    public let date: Date?

    public init(sha: String, message: String, date: Date?) {
        self.sha = sha
        self.message = message
        self.date = date
    }

    /// First line of the commit message.
    public var headline: String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    }
}

/// How `head` relates to `base` (GitHub's compare API).
public struct GitHubComparison: Hashable, Sendable {
    public let status: String
    public let aheadBy: Int
    public let behindBy: Int
    /// Newest first.
    public let commits: [GitHubCommit]

    public init(status: String, aheadBy: Int, behindBy: Int, commits: [GitHubCommit]) {
        self.status = status
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.commits = commits
    }
}

public struct GitHubError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String

    public var errorDescription: String? {
        switch status {
        case 401: return "Token de GitHub inválido o vencido."
        case 403: return "GitHub rechazó la solicitud: \(message)"
        case 404: return "GitHub no encontró el repo o la rama (¿el token tiene acceso?)."
        default: return "GitHub \(status): \(message)"
        }
    }
}

/// Minimal read-only GitHub client: who am I, branch heads, and compares.
public struct GitHubClient: Sendable {
    let token: String
    let baseURL: URL
    let transport: HTTPTransport

    public init(token: String, baseURL: URL = URL(string: "https://api.github.com")!, transport: HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.baseURL = baseURL
        self.transport = transport
    }

    /// The login the token belongs to.
    public func viewerLogin() async throws -> String {
        struct User: Decodable { let login: String }
        let user: User = try await get("/user")
        return user.login
    }

    /// Latest commit on a branch.
    public func branchHead(repo: String, branch: String) async throws -> GitHubCommit {
        let commit: RESTCommit = try await get("/repos/\(repo)/commits/\(Self.escape(branch))")
        return commit.model
    }

    /// Commits in `head` that aren't in `base`.
    public func compare(repo: String, base: String, head: String) async throws -> GitHubComparison {
        struct Response: Decodable {
            let status: String
            let aheadBy: Int
            let behindBy: Int
            let commits: [RESTCommit]
        }
        let response: Response = try await get("/repos/\(repo)/compare/\(Self.escape(base))...\(Self.escape(head))")
        return GitHubComparison(
            status: response.status,
            aheadBy: response.aheadBy,
            behindBy: response.behindBy,
            commits: response.commits.reversed().map(\.model)
        )
    }

    // MARK: - Plumbing

    // MARK: - Actions (TestFlight builds on self-hosted Macs)

    /// Recent runs of a workflow, newest first. Throws a 404 when the workflow isn't in the repo.
    public func workflowRuns(repo: String, workflow: String, perPage: Int = 10) async throws -> [WorkflowRun] {
        struct Response: Decodable { let workflowRuns: [WorkflowRun]? }
        let response: Response = try await get("/repos/\(repo)/actions/workflows/\(Self.escape(workflow))/runs?per_page=\(perPage)")
        return response.workflowRuns ?? []
    }

    /// Starts a `workflow_dispatch` run on `ref` with the given inputs.
    public func dispatchWorkflow(repo: String, workflow: String, ref: String, inputs: [String: String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ref": ref, "inputs": inputs])
        let _: Empty = try await send("POST", path: "/repos/\(repo)/actions/workflows/\(Self.escape(workflow))/dispatches", body: body)
    }

    /// Blob SHA of a file on a branch, or nil when it doesn't exist.
    public func fileSHA(repo: String, path: String, branch: String?) async throws -> String? {
        struct Response: Decodable { let sha: String }
        let ref = branch.map { "?ref=\(Self.escape($0))" } ?? ""
        do {
            let response: Response = try await get("/repos/\(repo)/contents/\(Self.escape(path))\(ref)")
            return response.sha
        } catch let error as GitHubError where error.status == 404 {
            return nil
        }
    }

    /// Creates or updates a file with a commit on `branch`.
    public func putFile(repo: String, path: String, content: String, message: String, branch: String?) async throws {
        var body: [String: Any] = ["message": message, "content": Data(content.utf8).base64EncodedString()]
        if let branch { body["branch"] = branch }
        if let sha = try await fileSHA(repo: repo, path: path, branch: branch) { body["sha"] = sha }
        let _: Empty = try await send("PUT", path: "/repos/\(repo)/contents/\(Self.escape(path))", body: try JSONSerialization.data(withJSONObject: body))
    }

    private struct Empty: Decodable {}

    private struct ErrorMessage: Decodable { let message: String }

    private struct RESTCommit: Decodable {
        struct Inner: Decodable {
            struct Person: Decodable { let date: Date? }
            let message: String
            let committer: Person?
        }

        let sha: String
        let commit: Inner

        var model: GitHubCommit {
            GitHubCommit(sha: sha, message: commit.message, date: commit.committer?.date)
        }
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? component
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path: path, body: nil)
    }

    private func send<T: Decodable>(_ method: String, path: String, body: Data?) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Loveploy", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorMessage.self, from: data))?.message ?? ""
            throw GitHubError(status: response.statusCode, message: message)
        }
        return try LovableWebClient.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

/// A GitHub Actions run.
public struct WorkflowRun: Decodable, Hashable, Sendable {
    public let id: Int
    /// queued, in_progress, completed, waiting, requested, pending.
    public let status: String?
    /// success, failure, cancelled, timed_out… once completed.
    public let conclusion: String?
    public let headSha: String?
    public let displayTitle: String?
    public let htmlUrl: String?
    public let createdAt: String?

    public init(id: Int, status: String?, conclusion: String?, headSha: String?, displayTitle: String?, htmlUrl: String? = nil, createdAt: String?) {
        self.id = id
        self.status = status
        self.conclusion = conclusion
        self.headSha = headSha
        self.displayTitle = displayTitle
        self.htmlUrl = htmlUrl
        self.createdAt = createdAt
    }

    public var isFinished: Bool { status == "completed" }
    public var succeeded: Bool { isFinished && conclusion == "success" }
}
