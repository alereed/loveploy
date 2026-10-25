import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An app in the Blender Dev Apps catalog, as `panel_salud` reports it.
public struct HubApp: Decodable, Hashable, Sendable, Identifiable {
    public struct Store: Decodable, Hashable, Sendable {
        public let version: String?
        public let build: String?
        /// en_preparacion, esperando_revision, ready_for_review, en_revision, en_tienda, rechazado…
        public let estado: String?
        public let liveAt: String?

        public init(version: String?, build: String?, estado: String?, liveAt: String? = nil) {
            self.version = version
            self.build = build
            self.estado = estado
            self.liveAt = liveAt
        }

        /// "1.0.2 (322)"
        public var label: String {
            [version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        }

        public var estadoLabel: String {
            switch estado {
            case "en_tienda": return "en la App Store"
            case "en_preparacion": return "en preparación"
            case "esperando_revision", "ready_for_review": return "esperando revisión"
            case "en_revision": return "en revisión"
            case "rechazado": return "rechazada"
            case let other?: return other.replacingOccurrences(of: "_", with: " ")
            case nil: return "sin estado"
            }
        }
    }

    public struct Deploy: Decodable, Hashable, Sendable {
        /// exitoso, fallido, sin_resultado, disparado…
        public let estado: String?
        public let plataforma: String?
        public let entorno: String?
        public let commitMessage: String?
        public let startedAt: String?
        public let finishedAt: String?

        public init(estado: String?, plataforma: String? = "ios", entorno: String? = "beta", commitMessage: String? = nil, startedAt: String? = nil, finishedAt: String? = nil) {
            self.estado = estado
            self.plataforma = plataforma
            self.entorno = entorno
            self.commitMessage = commitMessage
            self.startedAt = startedAt
            self.finishedAt = finishedAt
        }

        public var isRunning: Bool {
            finishedAt == nil && !["exitoso", "fallido", "sin_resultado", "cancelado"].contains(estado ?? "")
        }
    }

    public struct Missing: Decodable, Hashable, Sendable {
        public let que: String
        public let peso: String?
        public let porque: String?
    }

    public let slug: String
    public let nombre: String?
    public let ios: Bool?
    public let repoOwner: String?
    public let repoName: String?
    public let repoBranch: String?
    public let iosBundleId: String?
    public let appStore: Store?
    public let deploy: Deploy?
    public let iosCompiladoCommit: String?
    public let iosPendienteCommit: String?
    public let iosPendienteDesde: String?
    public let iosPendienteMensaje: String?
    public let faltantes: [Missing]?
    public let android: Bool?
    public let androidPackage: String?
    public let playStore: Store?

    public init(
        slug: String, nombre: String?, ios: Bool? = true, repoOwner: String?, repoName: String?, repoBranch: String? = "main",
        iosBundleId: String? = nil, appStore: Store? = nil, deploy: Deploy? = nil,
        iosCompiladoCommit: String? = nil, iosPendienteCommit: String? = nil, iosPendienteDesde: String? = nil,
        iosPendienteMensaje: String? = nil, faltantes: [Missing]? = nil,
        android: Bool? = nil, androidPackage: String? = nil, playStore: Store? = nil
    ) {
        self.slug = slug
        self.nombre = nombre
        self.ios = ios
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.repoBranch = repoBranch
        self.iosBundleId = iosBundleId
        self.appStore = appStore
        self.deploy = deploy
        self.iosCompiladoCommit = iosCompiladoCommit
        self.iosPendienteCommit = iosPendienteCommit
        self.iosPendienteDesde = iosPendienteDesde
        self.iosPendienteMensaje = iosPendienteMensaje
        self.faltantes = faltantes
        self.android = android
        self.androidPackage = androidPackage
        self.playStore = playStore
    }

    public var id: String { slug }
    public var label: String { nombre ?? slug }
    public var hasIOS: Bool { (ios ?? false) && iosBundleId != nil }

    /// What TestFlight needs, by the hub's own rule: native commits no successful build includes.
    public enum TestFlight: Hashable, Sendable {
        case upToDate
        /// There are native changes waiting since that date.
        case pending
        case building
        case failed
        /// Never built from the console.
        case none
    }

    public var testFlight: TestFlight {
        if deploy?.plataforma == "ios", deploy?.isRunning == true { return .building }
        if iosPendienteCommit != nil { return .pending }
        if deploy?.plataforma == "ios", deploy?.estado == "fallido" { return .failed }
        return iosCompiladoCommit == nil ? .none : .upToDate
    }

    public var needsTestFlight: Bool { testFlight == .pending || testFlight == .failed }

    public var hasAndroid: Bool { (android ?? false) && androidPackage != nil }

    /// The App Store version can take a build and go to review (it isn't already in review).
    public var canSubmitForReview: Bool {
        ["en_preparacion", "rechazado"].contains(appStore?.estado ?? "")
    }

    /// Same repo as a Lovable project's git sync. Repos move between owners (a user to an
    /// organization), so the repo name decides and the owner only breaks ties.
    public func matches(repo fullName: String) -> Bool {
        guard let repoName else { return false }
        let parts = fullName.lowercased().split(separator: "/").map(String.init)
        return parts.last == repoName.lowercased()
    }
}

/// A row of `builds_recientes`.
public struct HubDeployment: Decodable, Hashable, Sendable {
    public struct AppRef: Decodable, Hashable, Sendable {
        public let slug: String?
    }

    public let plataforma: String?
    public let proveedor: String?
    public let entorno: String?
    public let estado: String?
    public let commitSha: String?
    public let startedAt: String?
    public let devApps: AppRef?

    public init(plataforma: String?, proveedor: String?, entorno: String?, estado: String?, commitSha: String? = nil, startedAt: String?, slug: String? = nil) {
        self.plataforma = plataforma
        self.proveedor = proveedor
        self.entorno = entorno
        self.estado = estado
        self.commitSha = commitSha
        self.startedAt = startedAt
        self.devApps = AppRef(slug: slug)
    }
}

/// Picks the catalog apps for a Lovable project. When several apps share the repo name,
/// the owner breaks the tie; apps that only share the repo (like two apps in one monorepo) all match.
public func hubApps(forRepo repo: String?, in apps: [HubApp]) -> [HubApp] {
    guard let repo else { return [] }
    let candidates = apps.filter { $0.hasIOS && $0.matches(repo: repo) }
    let owner = repo.lowercased().split(separator: "/").first.map(String.init)
    let sameOwner = candidates.filter { $0.repoOwner?.lowercased() == owner }
    let owners = Set(candidates.compactMap { $0.repoOwner?.lowercased() })
    return owners.count > 1 && !sameOwner.isEmpty ? sameOwner : candidates
}

/// Xcode Cloud TestFlight builds started today (the ecosystem's limit is 7 a day).
public func xcodeCloudBuildsToday(_ deployments: [HubDeployment], now: Date = Date(), calendar: Calendar = .current) -> Int {
    deployments.filter { deployment in
        guard deployment.proveedor == "xcode_cloud", deployment.plataforma == "ios",
              let started = deployment.startedAt.flatMap(parseISO8601) else { return false }
        return calendar.isDate(started, inSameDayAs: now)
    }.count
}

public struct HubError: Error, LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// Talks to the Blender Dev Apps hub (its MCP server, over HTTP). The user enters the
/// server URL and a key scoped to "devops"; neither is part of this code.
public struct DevOpsHub: Sendable {
    public static let dailyTestFlightLimit = 7

    let endpoint: URL
    let key: String
    let transport: HTTPTransport

    public init(endpoint: URL, key: String, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.key = key
        self.transport = transport
    }

    /// Every app with its stores, last build and what it's missing (`panel_salud`).
    public func panel() async throws -> [HubApp] {
        struct Response: Decodable { let apps: [HubApp]? }
        let data = try await callTool("panel_salud", arguments: [:])
        return try LovableWebClient.decoder.decode(Response.self, from: data).apps ?? []
    }

    public func recentBuilds(limit: Int = 30) async throws -> [HubDeployment] {
        struct Response: Decodable { let filas: [HubDeployment]? }
        let data = try await callTool("builds_recientes", arguments: ["limite": limit])
        return try LovableWebClient.decoder.decode(Response.self, from: data).filas ?? []
    }

    /// Same path as the portal's button: iOS beta goes through Xcode Cloud to TestFlight.
    /// It costs Mac hours, so callers must ask the user first.
    public func requestTestFlight(app slug: String) async throws -> String {
        try await build(app: slug, platform: "ios", channel: "beta")
    }

    /// Android build through the hub (GitHub Actions on Linux). `channel`: beta or production.
    public func requestAndroid(app slug: String, channel: String = "beta") async throws -> String {
        try await build(app: slug, platform: "android", channel: channel)
    }

    /// Attaches the newest VALID build to the App Store version in preparation, then sends it
    /// to Apple's review. Public and irreversible: callers must get explicit confirmation.
    public func submitForReview(app slug: String) async throws -> String {
        let attached = try await callTool("version_adjuntar_build", arguments: ["app": slug])
        let submitted = try await callTool("enviar_a_revision", arguments: ["app": slug, "confirmar": true])
        return [attached, submitted].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    private func build(app slug: String, platform: String, channel: String) async throws -> String {
        let data = try await callTool("build_disparar", arguments: ["app": slug, "plataforma": platform, "canal": channel])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - MCP over HTTP

    /// Initializes a session and calls one tool. Returns the tool's text content.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> Data {
        let (_, sessionHeader) = try await rpc(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Loveploy", "version": "1.0"],
        ], session: nil)
        _ = try? await rpc(method: "notifications/initialized", params: nil, session: sessionHeader, notification: true)
        let (result, _) = try await rpc(method: "tools/call", params: ["name": name, "arguments": arguments], session: sessionHeader)

        let content = result?["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        if result?["isError"] as? Bool == true {
            throw HubError(message: text.isEmpty ? "El hub respondió con un error." : text)
        }
        return Data(text.utf8)
    }

    private func rpc(method: String, params: [String: Any]?, session: String?, notification: Bool = false) async throws -> ([String: Any]?, String?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !notification { message["id"] = Int.random(in: 1...999_999) }
        if let params { message["params"] = params }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await transport.send(request)
        let sessionHeader = response.value(forHTTPHeaderField: "Mcp-Session-Id") ?? session
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if response.statusCode == 401 {
                throw HubError(message: "El hub de Blender Dev Apps rechazó la llave (necesita alcance devops).")
            }
            throw HubError(message: body ?? "El hub respondió \(response.statusCode).")
        }
        if notification || data.isEmpty { return (nil, sessionHeader) }
        guard let object = Self.jsonRPCMessage(from: data) else {
            throw HubError(message: "No se entendió la respuesta del hub.")
        }
        if let error = object["error"] as? [String: Any] {
            throw HubError(message: error["message"] as? String ?? "Error del hub.")
        }
        return (object["result"] as? [String: Any], sessionHeader)
    }

    /// The JSON-RPC message, whether it came as plain JSON or as server-sent events.
    static func jsonRPCMessage(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], object["id"] != nil {
                return object
            }
        }
        return nil
    }
}
