import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class DevOpsHubTests: XCTestCase {
    static let endpoint = URL(string: "https://hub.example.com/mcp")!

    /// A trimmed `panel_salud` answer, in the hub's real shape.
    let panel = """
    {"generado_at":"2026-10-25T17:22:35Z","total":3,"apps":[
      {"ios":true,"slug":"uno","nombre":"Uno","repo_owner":"acme","repo_name":"uno","repo_branch":"main",
       "ios_bundle_id":"com.example.uno",
       "app_store":{"build":"15","track":"production","estado":"en_preparacion","version":"1.0","live_at":null},
       "deploy":{"estado":"exitoso","entorno":"beta","plataforma":"ios","commit_message":"iOS: primera versión",
                 "started_at":"2026-10-13T04:09:32Z","finished_at":"2026-10-13T04:14:56Z"},
       "faltantes":[{"que":"Cambios nativos de iOS sin compilar","peso":"pendiente","porque":"Desde el 22-Oct"}],
       "ios_compilado_commit":"cc7cae2","ios_pendiente_commit":"c48768f","ios_pendiente_desde":"2026-10-23T03:51:10+00:00",
       "ios_pendiente_mensaje":"Pantalla de inicio nueva"},
      {"ios":true,"slug":"dos","nombre":"Dos","repo_owner":"acme","repo_name":"dos",
       "ios_bundle_id":"com.example.dos",
       "app_store":{"build":"322","estado":"en_tienda","version":"1.0.2","live_at":"2026-10-13T17:07:07Z"},
       "deploy":{"estado":"exitoso","plataforma":"ios","started_at":"2026-10-13T04:11:14Z","finished_at":"2026-10-13T04:15:30Z"},
       "faltantes":[],"ios_compilado_commit":"41137f8","ios_pendiente_commit":null},
      {"ios":false,"slug":"web","nombre":"Solo web","repo_owner":"acme","repo_name":"solo-web",
       "ios_bundle_id":null,"app_store":null,"deploy":null,"faltantes":[]}
    ]}
    """

    func toolResult(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":\#(escaped)}]}}"#
    }

    func makeHub(_ transport: MockTransport, toolAnswer: String) -> DevOpsHub {
        let path = Self.endpoint.path
        transport.on("POST", path) { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            switch body?["method"] as? String {
            case "initialize":
                return (200, #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}"#, ["Mcp-Session-Id": "s-1"])
            case "notifications/initialized":
                return (202, "", [:])
            default:
                // Answer as server-sent events, like streamable HTTP can.
                return (200, "event: message\ndata: \(self.toolResult(toolAnswer))\n\n", ["Content-Type": "text/event-stream"])
            }
        }
        return DevOpsHub(endpoint: Self.endpoint, key: "devops-key", transport: transport)
    }

    func testPanelDecodesAppsAndTestFlightState() async throws {
        let transport = MockTransport()
        let apps = try await makeHub(transport, toolAnswer: panel).panel()

        XCTAssertEqual(apps.map(\.slug), ["uno", "dos", "web"])
        let uno = apps[0]
        XCTAssertEqual(uno.testFlight, .pending)
        XCTAssertTrue(uno.needsTestFlight)
        XCTAssertEqual(uno.appStore?.label, "1.0 (15)")
        XCTAssertEqual(uno.appStore?.estadoLabel, "en preparación")
        XCTAssertEqual(apps[1].testFlight, .upToDate)
        XCTAssertEqual(apps[1].appStore?.estadoLabel, "en la App Store")
        XCTAssertFalse(apps[2].hasIOS)

        // Key header, session reuse, and the tool that was called.
        let calls = transport.requests
        XCTAssertEqual(calls.first.flatMap { header($0, "Authorization") }, "Bearer devops-key")
        let toolCall = calls.last!
        XCTAssertEqual(header(toolCall, "Mcp-Session-Id"), "s-1")
        let body = try JSONSerialization.jsonObject(with: toolCall.httpBody!) as! [String: Any]
        XCTAssertEqual((body["params"] as? [String: Any])?["name"] as? String, "panel_salud")
    }

    func testToolErrorsAndBadKey() async {
        let transport = MockTransport()
        transport.on("POST", Self.endpoint.path, status: 401, #"{"error":"No autorizado"}"#)
        do {
            _ = try await DevOpsHub(endpoint: Self.endpoint, key: "x", transport: transport).panel()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("llave"))
        }
    }

    func testMatchesLovableRepoByNameAcrossOwnerRenames() {
        let uno = HubApp(slug: "uno", nombre: "Uno", repoOwner: "acme", repoName: "Uno", iosBundleId: "a")
        let clientes = HubApp(slug: "clientes", nombre: "Clientes", repoOwner: "acme", repoName: "monorepo", iosBundleId: "b")
        let tiendas = HubApp(slug: "tiendas", nombre: "Tiendas", repoOwner: "acme", repoName: "monorepo", iosBundleId: "c")
        let web = HubApp(slug: "web", nombre: "Web", ios: false, repoOwner: "acme", repoName: "uno", iosBundleId: nil)
        let apps = [uno, clientes, tiendas, web]

        // Lovable may still report the repo's previous owner.
        XCTAssertEqual(hubApps(forRepo: "persona/uno", in: apps).map(\.slug), ["uno"])
        XCTAssertEqual(hubApps(forRepo: "acme/monorepo", in: apps).map(\.slug), ["clientes", "tiendas"])
        XCTAssertTrue(hubApps(forRepo: "persona/otro", in: apps).isEmpty)
        XCTAssertTrue(hubApps(forRepo: nil, in: apps).isEmpty)
    }

    func testCountsTodaysXcodeCloudBuilds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-25T18:00:00Z")!
        let rows = [
            HubDeployment(plataforma: "ios", proveedor: "xcode_cloud", entorno: "beta", estado: "exitoso", startedAt: "2026-10-25T16:27:48.397575+00:00"),
            HubDeployment(plataforma: "ios", proveedor: "xcode_cloud", entorno: "beta", estado: "fallido", startedAt: "2026-10-25T16:01:44Z"),
            HubDeployment(plataforma: "ios", proveedor: "xcode_cloud", entorno: "beta", estado: "exitoso", startedAt: "2026-10-24T23:59:00Z"),
            HubDeployment(plataforma: "android", proveedor: "github_actions", entorno: "beta", estado: "exitoso", startedAt: "2026-10-25T10:00:00Z"),
        ]
        XCTAssertEqual(xcodeCloudBuildsToday(rows, now: now, calendar: calendar), 2)
    }

    func testBuildingAndFailedStates() {
        let building = HubApp(slug: "a", nombre: "A", repoOwner: nil, repoName: "a", iosBundleId: "x",
                              deploy: .init(estado: "disparado", startedAt: "2026-10-25T10:00:00Z"), iosCompiladoCommit: "c1")
        XCTAssertEqual(building.testFlight, .building)
        let failed = HubApp(slug: "a", nombre: "A", repoOwner: nil, repoName: "a", iosBundleId: "x",
                            deploy: .init(estado: "fallido", startedAt: "x", finishedAt: "y"), iosCompiladoCommit: "c1")
        XCTAssertEqual(failed.testFlight, .failed)
        XCTAssertEqual(HubApp(slug: "a", nombre: nil, repoOwner: nil, repoName: "a", iosBundleId: "x").testFlight, .none)
    }

    func testJSONRPCFromPlainJSONOrEvents() {
        XCTAssertNotNil(DevOpsHub.jsonRPCMessage(from: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)))
        XCTAssertNotNil(DevOpsHub.jsonRPCMessage(from: Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)))
        XCTAssertNil(DevOpsHub.jsonRPCMessage(from: Data("hola".utf8)))
    }
}
