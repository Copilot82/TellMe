import Foundation
import XCTest
@testable import messenger

final class CallServiceTests: XCTestCase {
  func testFetchTurnCredentialsUsesRustRelayOnlyContract() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: Self.turnCredentialsResponseJSON())

    let service: CallService = makeCallService(networkClient: networkClient)

    let config: RTCConfig = try await service.fetchTurnCredentials()

    XCTAssertEqual(config.iceTransportPolicy, "relay")
    XCTAssertEqual(config.iceServers.first?.urls, "turn:turn.surraund.com:3478?transport=udp")
    XCTAssertEqual(config.iceServers.first?.username, "turn-user")
    XCTAssertEqual(config.iceServers.first?.credential, "turn-pass")
    XCTAssertEqual(config.turnCredentials.username, "turn-user")
    XCTAssertEqual(config.turnCredentials.password, "turn-pass")
    XCTAssertEqual(config.turnCredentials.credential, "turn-pass")
    XCTAssertEqual(config.turnCredentials.expiresAt, 1_800_000_000)
    XCTAssertEqual(config.turnCredentials.ttl, 300)

    let request: URLRequest = try XCTUnwrap(networkClient.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/api/turn/credentials")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")

    let body: [String: Any] = try Self.decodeRequestBody(request)
    XCTAssertEqual(body["purpose"] as? String, "call_media")
    XCTAssertEqual(body["transport_profile"] as? String, "webrtc_turn_relay")
    XCTAssertNil(body["transportProfile"])
    XCTAssertNil(body["call_id"])
    XCTAssertNil(body["conversation_id"])
    XCTAssertNil(body["peer_id"])
    XCTAssertNil(body["device_id"])

    let capabilities: [String: Any] = try XCTUnwrap(body["capabilities"] as? [String: Any])
    XCTAssertEqual(capabilities["audio"] as? Bool, true)
    XCTAssertEqual(capabilities["video"] as? Bool, true)
  }

  func testFetchTurnCredentialsRetriesTransientServerFailure() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 503, json: "{\"error\":\"temporary unavailable\"}")
    networkClient.enqueue(statusCode: 200, json: Self.turnCredentialsResponseJSON())

    let service: CallService = makeCallService(networkClient: networkClient, sleep: { _ in })

    let config: RTCConfig = try await service.fetchTurnCredentials()

    XCTAssertEqual(config.iceTransportPolicy, "relay")
    XCTAssertEqual(networkClient.requests.count, 2)
  }

  func testFetchTurnCredentialsRetriesTransientTransportFailure() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueueError(APIError.transport("A TLS error caused the secure connection to fail."))
    networkClient.enqueue(statusCode: 200, json: Self.turnCredentialsResponseJSON())

    let service: CallService = makeCallService(networkClient: networkClient, sleep: { _ in })

    let config: RTCConfig = try await service.fetchTurnCredentials()

    XCTAssertEqual(config.iceTransportPolicy, "relay")
    XCTAssertEqual(networkClient.requests.count, 2)
  }

  func testFetchTurnCredentialsDoesNotRetryUnauthorized() async {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 401, json: "{\"error\":\"Unauthorized\"}")
    networkClient.enqueue(statusCode: 200, json: Self.turnCredentialsResponseJSON())

    let service: CallService = makeCallService(networkClient: networkClient)

    do {
      let _: RTCConfig = try await service.fetchTurnCredentials()
      XCTFail("Expected unauthorized error")
    } catch let error as APIError {
      XCTAssertEqual(error, .unauthorized)
      XCTAssertEqual(networkClient.requests.count, 1)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testDeviceTokensListEndpointUsesDevicesNamespace() async throws {
    let timestamp: String = makeISODateString()
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 200,
      json:
        """
        {
          "tokens": [
            {
              "id": "dt1",
              "user_id": "u1",
              "device_type": "ios",
              "token": "abc",
              "device_name": "iPhone",
              "os_version": "18",
              "app_version": "1",
              "push_enabled": true,
              "last_used_at": "\(timestamp)",
              "created_at": "\(timestamp)"
            }
          ]
        }
        """
    )

    let service: CallService = makeCallService(networkClient: networkClient)

    let response: DeviceTokensResponse = try await service.listDeviceTokens()

    XCTAssertEqual(response.tokens.first?.deviceType, .ios)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/devices/push/tokens") == true)
  }

  func testUpdateDeviceTokenPushEnabledEndpointUsesDevicesNamespace() async throws {
    let timestamp: String = makeISODateString()
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 200,
      json:
        """
        {
          "token": {
            "id": "dt1",
            "user_id": "u1",
            "device_type": "ios",
            "token": "abc",
            "device_name": "iPhone",
            "os_version": "18",
            "app_version": "1",
            "push_enabled": false,
            "last_used_at": "\(timestamp)",
            "created_at": "\(timestamp)"
          }
        }
        """
    )

    let service: CallService = makeCallService(networkClient: networkClient)

    let response: DeviceTokenResponse = try await service.updateDeviceTokenPushEnabled(token: "abc", pushEnabled: false)

    XCTAssertEqual(response.token.pushEnabled, false)
    XCTAssertEqual(networkClient.requests.first?.httpMethod, "PUT")
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/devices/push/tokens/abc") == true)

    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let payload: [String: Any] = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    XCTAssertEqual(payload["push_enabled"] as? Bool, false)
  }

  func testRegisterDeviceTokenIncludesPushEnvironment() async throws {
    let timestamp: String = makeISODateString()
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 200,
      json:
        """
        {
          "token": {
            "id": "dt1",
            "user_id": "u1",
            "device_type": "ios",
            "token": "abc",
            "device_name": "iPhone",
            "os_version": "18",
            "app_version": "1",
            "push_enabled": true,
            "push_environment": "sandbox",
            "last_used_at": "\(timestamp)",
            "created_at": "\(timestamp)"
          }
        }
        """
    )

    let service: CallService = makeCallService(networkClient: networkClient)

    let payload = DeviceTokenRegistrationPayload(
      deviceType: .ios,
      token: "abc",
      deviceName: "iPhone",
      osVersion: "18",
      appVersion: "1",
      pushEnabled: true,
      pushEnvironment: .sandbox,
      pushMode: .privacyFirst,
      tokenKind: .alert
    )

    let response: DeviceTokenResponse = try await service.registerDeviceToken(payload)

    XCTAssertEqual(response.token.pushEnvironment, .sandbox)
    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let encodedPayload: [String: Any] = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    XCTAssertEqual(encodedPayload["push_environment"] as? String, "sandbox")
  }

  private func makeCallService(
    networkClient: MockNetworkClient,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in }
  ) -> CallService {
    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-token", refreshToken: "refresh-token")
    let apiClient: APIClient = APIClient(
      environment: .local,
      networkClient: networkClient,
      tokenStore: tokenStore
    )
    return CallService(apiClient: apiClient, sleep: sleep)
  }

  private static func decodeRequestBody(_ request: URLRequest) throws -> [String: Any] {
    let bodyData: Data = try XCTUnwrap(request.httpBody)
    let object: Any = try JSONSerialization.jsonObject(with: bodyData)
    return try XCTUnwrap(object as? [String: Any])
  }

  private static func turnCredentialsResponseJSON() -> String {
    """
    {
      "ice_servers": [
        {
          "urls": [
            "turn:turn.surraund.com:3478?transport=udp",
            "turn:turn.surraund.com:3478?transport=tcp"
          ],
          "username": "turn-user",
          "credential": "turn-pass"
        }
      ],
      "turn_credentials": {
        "username": "turn-user",
        "credential": "turn-pass",
        "expires_at": 1800000000,
        "ttl": 300
      },
      "ice_transport_policy": "relay",
      "transport_profile": "webrtc_turn_relay"
    }
    """
  }
}
