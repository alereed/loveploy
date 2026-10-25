import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LoveployCore

final class SessionTests: XCTestCase {
    func testUsesCachedTokenWhileValid() async throws {
        let transport = MockTransport()
        let session = signedInSession(transport: transport)
        let token = try await session.idToken()
        XCTAssertEqual(token, "id-1")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefreshesExpiredTokenWithSecureTokenAPI() async throws {
        let transport = MockTransport()
        transport.on("POST", "/v1/token", #"{"id_token":"id-2","refresh_token":"refresh-2","expires_in":"3600","user_id":"u1"}"#)
        let session = LovableSession(
            credentials: LovableCredentials(refreshToken: "refresh-1", idToken: "old", expiresAt: Date().addingTimeInterval(-10), email: "a@b.mx"),
            transport: transport
        )

        let token = try await session.idToken()

        XCTAssertEqual(token, "id-2")
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.host, "securetoken.googleapis.com")
        XCTAssertTrue(request.url!.query!.contains("key=\(LovableSession.firebaseAPIKey)"))
        XCTAssertEqual(header(request, "Referer"), "https://lovable.dev/")
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=refresh-1"))
        let current = await session.current
        XCTAssertEqual(current?.refreshToken, "refresh-2")
        XCTAssertEqual(current?.email, "a@b.mx", "keeps the email it already knew")
    }

    func testFallsBackWhenRefreshIsRefused() async throws {
        let transport = MockTransport()
        transport.on("POST", "/v1/token", status: 403, #"{"error":{"message":"API_KEY_HTTP_REFERRER_BLOCKED"}}"#)
        let session = LovableSession(
            credentials: LovableCredentials(refreshToken: "r", idToken: nil),
            transport: transport,
            fallback: { LovableCredentials(refreshToken: "r2", idToken: "from-web", expiresAt: Date().addingTimeInterval(3600)) }
        )
        let token = try await session.idToken()
        XCTAssertEqual(token, "from-web")
    }

    func testRefreshFailureWithoutFallbackExplainsIt() async {
        let transport = MockTransport()
        transport.on("POST", "/v1/token", status: 400, #"{"error":{"message":"TOKEN_EXPIRED"}}"#)
        let session = LovableSession(credentials: LovableCredentials(refreshToken: "r"), transport: transport)
        do {
            _ = try await session.idToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("TOKEN_EXPIRED"))
        }
    }

    func testSignedOutThrows() async {
        let session = LovableSession(credentials: nil, transport: MockTransport())
        do {
            _ = try await session.idToken()
            XCTFail("expected an error")
        } catch SessionError.signedOut {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
