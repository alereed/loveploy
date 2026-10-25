import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A repository the GitHub token can see, with the head of its default branch.
public struct GitHubRepo: Hashable, Sendable, Identifiable {
    public let fullName: String
    public let name: String
    public let url: String
    public let defaultBranch: String?
    public let head: GitHubCommit?
    public let isArchived: Bool

    public init(fullName: String, name: String, url: String, defaultBranch: String?, head: GitHubCommit?, isArchived: Bool = false) {
        self.fullName = fullName
        self.name = name
        self.url = url
        self.defaultBranch = defaultBranch
        self.head = head
        self.isArchived = isArchived
    }

    public var id: String { fullName }
}

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

/// Minimal read-only GitHub client: who am I, my repos, branch heads, and compares.
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

    /// Every repository the token can see, with the head of each default branch.
    /// Uses GraphQL so 100 repos and their heads come back in one request.
    public func repositories() async throws -> [GitHubRepo] {
        struct Response: Decodable {
            struct DataField: Decodable { let viewer: Viewer }
            struct Viewer: Decodable { let repositories: Connection }
            struct Connection: Decodable {
                let nodes: [Node]
                let pageInfo: PageInfo
            }
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }
            struct Node: Decodable {
                let nameWithOwner: String
                let name: String
                let url: String
                let isArchived: Bool
                let defaultBranchRef: Ref?
            }
            struct Ref: Decodable {
                let name: String
                let target: Target?
            }
            struct Target: Decodable {
                let oid: String?
                let message: String?
                let committedDate: Date?
            }
            struct GraphQLError: Decodable { let message: String }

            let data: DataField?
            let errors: [GraphQLError]?
        }

        let query = """
        query($cursor: String) {
          viewer {
            repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                         orderBy: {field: PUSHED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes {
                nameWithOwner name url isArchived
                defaultBranchRef { name target { ... on Commit { oid message committedDate } } }
              }
            }
          }
        }
        """

        var repos: [GitHubRepo] = []
        var cursor: String?
        repeat {
            var variables: [String: Any] = [:]
            variables["cursor"] = cursor ?? NSNull()
            let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            let response: Response = try await send("POST", path: "/graphql", body: body)
            if let error = response.errors?.first {
                throw GitHubError(status: 200, message: error.message)
            }
            guard let connection = response.data?.viewer.repositories else { break }
            for node in connection.nodes {
                let head = node.defaultBranchRef?.target.flatMap { target in
                    target.oid.map { GitHubCommit(sha: $0, message: target.message ?? "", date: target.committedDate) }
                }
                repos.append(GitHubRepo(
                    fullName: node.nameWithOwner,
                    name: node.name,
                    url: node.url,
                    defaultBranch: node.defaultBranchRef?.name,
                    head: head,
                    isArchived: node.isArchived
                ))
            }
            cursor = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : nil
        } while cursor != nil
        return repos
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
        return try LovableClient.decoder.decode(T.self, from: data)
    }
}
