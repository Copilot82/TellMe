import XCTest
@testable import messenger

final class AuthServiceTests: XCTestCase {
  func testRegisterFederatedStoresTokens() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 200,
      json:
        """
        {
          "user_handle": "@test:example.com",
          "device_id": "dev_1",
          "session_token": "token-1",
          "refresh_token": "refresh-1",
          "expires_in": 900
        }
        """
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    let response: FederatedRegisterResponse = try await service.registerFederated(
      FederatedRegisterRequest(
        userHandle: "@test:example.com",
        ikSignPub: "ik_sign_pub",
        ikDhPub: "ik_dh_pub",
        signature: "signature",
        timestamp: makeISODateString(),
        initialDevice: FederatedInitialDevice(
          deviceId: "dev_1",
          dkSignPub: "dk_sign_pub",
          dkDhPub: "dk_dh_pub",
          deviceCertificateChain: []
        )
      )
    )

    XCTAssertEqual(response.userHandle, "@test:example.com")
    XCTAssertEqual(response.deviceId, "dev_1")
    XCTAssertEqual(tokenStore.accessToken, "token-1")
    XCTAssertEqual(tokenStore.refreshToken, "refresh-1")
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/auth/register") == true)
  }

  func testRefreshUsesRefreshToken() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 200,
      json: "{\"session_token\":\"new-a\",\"refresh_token\":\"new-r\",\"expires_in\":900}"
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "old-a", refreshToken: "old-r")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    let refreshed: FederatedSessionTokens = try await service.refreshTokens()

    XCTAssertEqual(refreshed.sessionToken, "new-a")
    XCTAssertEqual(refreshed.refreshToken, "new-r")
    XCTAssertEqual(tokenStore.accessToken, "new-a")
    XCTAssertEqual(tokenStore.refreshToken, "new-r")

    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let payload: [String: String] = try JSONSerialization.jsonObject(with: body) as? [String: String] ?? [:]
    XCTAssertEqual(payload["refresh_token"], "old-r")
  }

  func testRefreshTokensCoalescesConcurrentRequests() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueueResponder { _ in
      Thread.sleep(forTimeInterval: 0.05)
      let body: Data = Data(
        """
        {"session_token":"new-a","refresh_token":"new-r","expires_in":900}
        """.utf8
      )
      return MockNetworkClient.QueuedResponse(statusCode: 200, body: body)
    }

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "old-a", refreshToken: "old-r")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    async let first: FederatedSessionTokens = service.refreshTokens()
    async let second: FederatedSessionTokens = service.refreshTokens()
    let refreshed: [FederatedSessionTokens] = try await [first, second]

    XCTAssertEqual(refreshed.map(\.sessionToken), ["new-a", "new-a"])
    XCTAssertEqual(refreshed.map(\.refreshToken), ["new-r", "new-r"])
    XCTAssertEqual(networkClient.requests.count, 1)
    XCTAssertEqual(tokenStore.accessToken, "new-a")
    XCTAssertEqual(tokenStore.refreshToken, "new-r")
  }

  func testFetchPrekeysIncludesPeekQueryWhenRequested() async throws {
    let bundleJSON =
      """
      {
        "bundles": [
          {
            "protocol_version": 2,
            "user_handle": "@peer:example.com",
            "device_id": "peer-device-1",
            "account_sign_pub": "ik-sign",
            "device_sign_pub": "dk-sign",
            "device_dh_pub": "dk-dh",
            "device_certificate_chain": [],
            "signed_prekey": {
              "prekey_id": "signed-1",
              "signed_prekey_pub": "signed-prekey",
              "signature": "signed-prekey-signature",
              "expires_at": null
            },
            "one_time_prekey": null,
            "push_mode": "privacy_first"
          }
        ]
      }
      """

    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: bundleJSON)

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    let response = try await service.fetchPrekeys(
      userHandle: "@peer:example.com",
      deviceId: nil,
      peek: true
    )

    XCTAssertEqual(response.bundles.count, 1)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("peek=true") == true)
  }

  func testFetchPrekeysUsesSessionTokenWhenAvailable() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: "{\"bundles\":[]}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-token", refreshToken: "refresh-token")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    let response = try await service.fetchPrekeys(
      userHandle: "@peer:example.com",
      deviceId: "peer-device-1",
      peek: true
    )

    XCTAssertTrue(response.bundles.isEmpty)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/prekeys/get") == true)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("device_id=peer-device-1") == true)
    XCTAssertEqual(networkClient.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
  }

  func testFetchSelfPrekeysUsesAuthenticatedSelfEndpoint() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: "{\"bundles\":[]}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-token", refreshToken: "refresh-token")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: AuthService = AuthService(apiClient: apiClient, tokenStore: tokenStore)

    let response = try await service.fetchSelfPrekeys(deviceId: "self-device-2", peek: true)

    XCTAssertTrue(response.bundles.isEmpty)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/prekeys/self") == true)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("device_id=self-device-2") == true)
    XCTAssertEqual(networkClient.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
  }
}
