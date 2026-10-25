import Foundation

// Shapes of the endpoints lovable.dev's own web app calls on api.lovable.dev.
// They aren't a documented API, so every field Loveploy doesn't strictly need is optional.

/// A workspace the signed-in user belongs to (`GET /user/workspaces`).
public struct Workspace: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }

    public var displayName: String { name?.isEmpty == false ? name! : id }
}

struct WorkspacesResponse: Decodable {
    let workspaces: [Workspace]?
}

/// A project as listed on the dashboard (`GET /v2/workspaces/{id}/projects`).
public struct ProjectSummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let displayName: String?
    public let title: String?
    public let isPublished: Bool?
    public let lastEditedAt: Date?
    public let updatedAt: Date?

    public init(id: String, name: String? = nil, displayName: String? = nil, isPublished: Bool? = nil, lastEditedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.title = nil
        self.isPublished = isPublished
        self.lastEditedAt = lastEditedAt
        self.updatedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, displayName, title, isPublished, lastEditedAt, updatedAt
    }

    // Lenient: a field in an unexpected shape shouldn't hide the whole project list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        isPublished = try? container.decodeIfPresent(Bool.self, forKey: .isPublished)
        lastEditedAt = try? container.decodeIfPresent(Date.self, forKey: .lastEditedAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public var label: String {
        for candidate in [displayName, title, name] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return id
    }

    public var editedAt: Date? { lastEditedAt ?? updatedAt }
}

struct ProjectPage: Decodable {
    let projects: [ProjectSummary]?
    let hasMore: Bool?
    let nextCursor: String?
}

/// `GET /projects/{id}/details`: what the editor knows about a project, including
/// which commit is live.
public struct ProjectDetails: Decodable, Hashable, Sendable {
    public struct PublishedDeployment: Decodable, Hashable, Sendable {
        public let id: String?
        public let commitSha: String?
        public let headCommitSha: String?
        /// Hash of the secrets in the preview vs. the ones that went live.
        public let previewSecretsHash: String?
        public let secretsHash: String?
        public let hasPreviewSecretsHash: Bool

        public init(id: String? = nil, commitSha: String?, headCommitSha: String? = nil, previewSecretsHash: String? = nil, secretsHash: String? = nil, hasPreviewSecretsHash: Bool = false) {
            self.id = id
            self.commitSha = commitSha
            self.headCommitSha = headCommitSha
            self.previewSecretsHash = previewSecretsHash
            self.secretsHash = secretsHash
            self.hasPreviewSecretsHash = hasPreviewSecretsHash
        }

        enum CodingKeys: String, CodingKey {
            case id, commitSha, headCommitSha, targetMetadata
        }

        struct TargetMetadata: Decodable {
            let previewSecretsHash: String?
            let secretsHash: String?
            let hasPreviewSecretsHash: Bool

            enum CodingKeys: String, CodingKey {
                case previewSecretsHash, secretsHash
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                hasPreviewSecretsHash = container.contains(.previewSecretsHash)
                previewSecretsHash = try? container.decodeIfPresent(String.self, forKey: .previewSecretsHash)
                secretsHash = try? container.decodeIfPresent(String.self, forKey: .secretsHash)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            commitSha = try? container.decodeIfPresent(String.self, forKey: .commitSha)
            headCommitSha = try? container.decodeIfPresent(String.self, forKey: .headCommitSha)
            let metadata = try? container.decodeIfPresent(TargetMetadata.self, forKey: .targetMetadata)
            previewSecretsHash = metadata?.previewSecretsHash
            secretsHash = metadata?.secretsHash
            hasPreviewSecretsHash = metadata?.hasPreviewSecretsHash ?? false
        }

        /// Secrets changed since the publish (same check the Publish button makes).
        public var secretsChanged: Bool {
            hasPreviewSecretsHash && (previewSecretsHash ?? "") != (secretsHash ?? "")
        }
    }

    public let id: String?
    public let workspaceId: String?
    public let isPublished: Bool?
    public let latestCommitSha: String?
    public let url: String?
    public let publishedDeployment: PublishedDeployment?

    enum CodingKeys: String, CodingKey {
        case id, workspaceId, isPublished, latestCommitSha, url, publishedDeployment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        workspaceId = try? container.decodeIfPresent(String.self, forKey: .workspaceId)
        isPublished = try? container.decodeIfPresent(Bool.self, forKey: .isPublished)
        latestCommitSha = try? container.decodeIfPresent(String.self, forKey: .latestCommitSha)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        publishedDeployment = try? container.decodeIfPresent(PublishedDeployment.self, forKey: .publishedDeployment)
    }

    public init(id: String?, workspaceId: String? = nil, isPublished: Bool?, latestCommitSha: String?, url: String? = nil, publishedDeployment: PublishedDeployment?) {
        self.id = id
        self.workspaceId = workspaceId
        self.isPublished = isPublished
        self.latestCommitSha = latestCommitSha
        self.url = url
        self.publishedDeployment = publishedDeployment
    }
}

/// `POST /projects/{id}/deployments`
struct DeploymentStarted: Decodable {
    let deploymentId: String
}

/// `GET /projects/{id}/deployments/{deployment_id}/progress`
public struct DeploymentProgress: Decodable, Hashable, Sendable {
    public let status: String?
    public let step: String?
    public let url: String?
    public let headCommitSha: String?
    public let targetCommitSha: String?
    public let errorMessage: String?
    public let errorClass: String?

    public init(status: String?, step: String? = nil, url: String? = nil, errorMessage: String? = nil, errorClass: String? = nil) {
        self.status = status
        self.step = step
        self.url = url
        self.headCommitSha = nil
        self.targetCommitSha = nil
        self.errorMessage = errorMessage
        self.errorClass = errorClass
    }

    public var isCompleted: Bool { status == "completed" }
    public var isError: Bool { status == "error" }
}

/// `GET /workspaces/{ws}/projects/{id}/gitsync`: which repo the project syncs with.
public struct GitSyncInfo: Decodable, Hashable, Sendable {
    public struct Config: Decodable, Hashable, Sendable {
        public let ownerName: String?
        public let repoName: String?
        public let mainBranch: String?
        public let repoUrl: String?
        public let providerType: String?

        public init(ownerName: String?, repoName: String?, mainBranch: String? = nil, repoUrl: String? = nil, providerType: String? = "github") {
            self.ownerName = ownerName
            self.repoName = repoName
            self.mainBranch = mainBranch
            self.repoUrl = repoUrl
            self.providerType = providerType
        }
    }

    public let config: Config?

    public init(config: Config?) {
        self.config = config
    }

    /// "owner/repo", when connected.
    public var fullName: String? {
        guard let owner = config?.ownerName, let repo = config?.repoName, !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    public var isGitHub: Bool { config?.providerType?.lowercased().hasPrefix("github") ?? true }
}

/// `GET /workspaces/{ws}/projects/{id}/gitsync/sync-status`: Lovable vs. the repo.
public struct GitSyncStatus: Decodable, Hashable, Sendable {
    /// not_connected, in_sync, lovable_ahead, remote_ahead, diverged, unavailable.
    public let state: String?
    public let ahead: Int?
    public let behind: Int?

    public init(state: String?, ahead: Int? = nil, behind: Int? = nil) {
        self.state = state
        self.ahead = ahead
        self.behind = behind
    }
}

/// An error from api.lovable.dev, or an HTTP failure without a readable body.
public struct LovableError: Error, Decodable, LocalizedError, Sendable {
    public let type: String?
    public let message: String?
    public let detail: String?
    public var status: Int = 0

    enum CodingKeys: String, CodingKey { case type, message, detail, error }

    public init(status: Int, type: String? = nil, message: String? = nil) {
        self.status = status
        self.type = type
        self.message = message
        self.detail = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        let error = try? container.decodeIfPresent(String.self, forKey: .error)
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? error
        detail = try? container.decodeIfPresent(String.self, forKey: .detail)
    }

    public var isAuthFailure: Bool {
        status == 401 || type == "authentication_failed" || type == "oauth_unauthorized"
    }

    public var errorDescription: String? {
        if isAuthFailure { return "La sesión de Lovable expiró. Vuelve a iniciar sesión." }
        if type == "project_slug_taken" { return "Ese subdominio ya está ocupado." }
        if status == 403 { return "No tienes permiso para publicar este proyecto." }
        if status == 429 { return "Lovable está limitando las solicitudes; intenta en un momento." }
        let text = [message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        if !text.isEmpty { return text }
        return "Lovable respondió \(status)\(type.map { " (\($0))" } ?? "")."
    }
}

/// What to do when a publish fails, keyed by `error_class`.
public func publishFailureHint(errorClass: String?) -> String? {
    switch errorClass {
    case "transient": return "Falla temporal: vuelve a intentar."
    case "code": return "Error en el código o SQL del proyecto."
    case "configuration": return "Error de configuración del proyecto."
    case "data": return "La migración choca con datos de producción; requiere revisión."
    case "integration": return "Revisa credenciales o cuota de la integración conectada."
    case "policy": return "Una política del workspace bloquea la publicación."
    case "internal": return "Error interno de Lovable; contacta a soporte."
    default: return nil
    }
}
