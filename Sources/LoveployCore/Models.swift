import Foundation

/// A Lovable workspace (`GET /v1/workspaces`).
public struct Workspace: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let plan: String?
    public let numProjects: Int?

    public init(id: String, name: String, plan: String? = nil, numProjects: Int? = nil) {
        self.id = id
        self.name = name
        self.plan = plan
        self.numProjects = numProjects
    }
}

/// A project as returned by `GET /v1/projects`.
public struct ProjectSummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let workspaceId: String
    public let name: String?
    public let isPublished: Bool
    public let publishAudience: String?
    public let lastEditedAt: Date?
    public let latestScreenshotUrl: String?

    public init(
        id: String,
        workspaceId: String,
        name: String?,
        isPublished: Bool,
        publishAudience: String? = nil,
        lastEditedAt: Date? = nil,
        latestScreenshotUrl: String? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.isPublished = isPublished
        self.publishAudience = publishAudience
        self.lastEditedAt = lastEditedAt
        self.latestScreenshotUrl = latestScreenshotUrl
    }

    public var displayName: String { name?.isEmpty == false ? name! : id }
}

/// A project as returned by `GET /v1/projects/{id}`. Only the fields Loveploy needs.
public struct ProjectDetail: Decodable, Hashable, Sendable {
    public let id: String
    public let latestCommitSha: String?
    public let previewUrl: String?
    public let isPublished: Bool?

    public init(id: String, latestCommitSha: String?, previewUrl: String? = nil, isPublished: Bool? = nil) {
        self.id = id
        self.latestCommitSha = latestCommitSha
        self.previewUrl = previewUrl
        self.isPublished = isPublished
    }
}

/// A publish job (`POST /v1/projects/{id}/publish` and its status endpoint).
public struct Deployment: Decodable, Hashable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case running, completed, error, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public let id: String
    public let status: Status
    public let url: String?
    public let errorMessage: String?
    public let errorClass: String?

    public init(id: String, status: Status, url: String? = nil, errorMessage: String? = nil, errorClass: String? = nil) {
        self.id = id
        self.status = status
        self.url = url
        self.errorMessage = errorMessage
        self.errorClass = errorClass
    }

    public var isTerminal: Bool { status == .completed || status == .error }
}

struct Page<Item: Decodable>: Decodable {
    struct Pagination: Decodable {
        let hasMore: Bool
        let nextCursor: String?
    }

    let data: [Item]
    let pagination: Pagination
}

/// The error envelope every Lovable API error uses.
public struct LovableAPIError: Error, Decodable, Sendable, LocalizedError {
    public let type: String
    public let title: String
    public let status: Int
    public let requestId: String?
    public let detail: String?

    public init(type: String, title: String, status: Int, requestId: String? = nil, detail: String? = nil) {
        self.type = type
        self.title = title
        self.status = status
        self.requestId = requestId
        self.detail = detail
    }

    public var errorDescription: String? {
        switch type {
        case "unauthorized":
            return "API key inválida o revocada."
        case "insufficient_scope":
            return "La API key no tiene el permiso necesario (usa projects:write y workspaces:read)."
        case "payment_required":
            return "El plan del workspace no incluye la API (requiere Business o Enterprise)."
        case "security_critical_findings":
            return "Publicación bloqueada por hallazgos de seguridad críticos. Revísalos en Lovable."
        case "rate_limited":
            return "Demasiadas solicitudes; intenta de nuevo en un momento."
        default:
            return [title, detail].compactMap { $0 }.joined(separator: ": ")
        }
    }
}

/// What to do when a deployment fails, keyed by `error_class`.
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
