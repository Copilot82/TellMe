import XCTest
@testable import messenger

final class AuthViewModelTests: XCTestCase {
  @MainActor
  func testLoginWithoutLocalDeviceIdentityRequiresLinkFlow() async throws {
    let suiteName: String = "AuthViewModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keyMaterialStore = InMemoryKeyMaterialStore()
    let tokenStore = InMemoryTokenStore()
    let sessionStore = UserDefaultsSessionStore(defaults: defaults)
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )

    let userHandle = "@alice:example.org"
    let identity = try container.identityService.createIdentity(userHandle: userHandle)
    let viewModel = AuthViewModel(container: container)

    do {
      _ = try await viewModel.login(userHandle: userHandle, seedPhrase: identity.seedPhrase)
      XCTFail("Expected device-link-required error")
    } catch let error as AuthViewModel.AuthViewModelError {
      XCTAssertEqual(error, .deviceLinkRequired)
    }
  }

  @MainActor
  func testLoginReusesStoredDeviceIdentityAndMigratesLegacyDeviceId() async throws {
    let suiteName: String = "AuthViewModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keyMaterialStore = InMemoryKeyMaterialStore()
    let tokenStore = InMemoryTokenStore()
    let sessionStore = UserDefaultsSessionStore(defaults: defaults)
    let networkClient = MockNetworkClient()
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )

    let userHandle = "@alice:example.org"
    let identity = try container.identityService.createIdentity(userHandle: userHandle)
    keyMaterialStore.saveDeviceId("legacy-device-1", for: userHandle)

    networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "challenge_id": "11111111-1111-4111-8111-111111111111",
        "nonce": "nonce-1",
        "expires_at": "2026-03-27T12:00:00.000Z"
      }
      """
    )
    networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "session_token": "session-1",
        "refresh_token": "refresh-1",
        "expires_in": 900
      }
      """
    )
    networkClient.enqueue(statusCode: 201, json: "{}")
    networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "signed_prekey_id": "signed-1",
        "one_time_prekeys_added": 100
      }
      """
    )

    let viewModel = AuthViewModel(container: container)
    _ = try await viewModel.login(userHandle: userHandle, seedPhrase: identity.seedPhrase)

    XCTAssertEqual(keyMaterialStore.deviceIdentity(for: userHandle)?.deviceId, "legacy-device-1")
    XCTAssertEqual(keyMaterialStore.deviceId(for: userHandle), "legacy-device-1")
    XCTAssertEqual(tokenStore.accessToken, "session-1")
    XCTAssertEqual(tokenStore.refreshToken, "refresh-1")
    XCTAssertTrue(networkClient.requests[0].url?.absoluteString.contains("/api/auth/start") == true)
    XCTAssertTrue(networkClient.requests[1].url?.absoluteString.contains("/api/auth/finish") == true)
    XCTAssertTrue(networkClient.requests[2].url?.absoluteString.contains("/api/devices/register") == true)
    XCTAssertTrue(networkClient.requests[3].url?.absoluteString.contains("/api/prekeys/publish") == true)
  }

  @MainActor
  func testRegisterCallsSyncDeviceTokenIfNeeded() async throws {
    let suiteName: String = "AuthViewModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keyMaterialStore = InMemoryKeyMaterialStore()
    let tokenStore = InMemoryTokenStore()
    let sessionStore = UserDefaultsSessionStore(defaults: defaults)
    let networkClient = MockNetworkClient()
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )

    let userHandle = "@alice:example.org"
    let identity = try container.identityService.createIdentity(userHandle: userHandle)
    let deviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: userHandle,
      seedPhrase: identity.seedPhrase,
      deviceId: nil
    )
    keyMaterialStore.saveDeviceIdentity(deviceIdentity, for: userHandle)
    keyMaterialStore.saveSeedPhrase(identity.seedPhrase, for: userHandle)

    networkClient.enqueue(
      statusCode: 201,
      json: """
      {
        "user_handle": "\(userHandle)",
        "device_id": "\(deviceIdentity.deviceId)",
        "session_token": "session-1",
        "refresh_token": "refresh-1",
        "expires_in": 900
      }
      """
    )
    networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "signed_prekey_id": "signed-1",
        "one_time_prekeys_added": 100
      }
      """
    )

    let viewModel = AuthViewModel(container: container)
    _ = try await viewModel.register(userHandle: userHandle)

    XCTAssertEqual(tokenStore.accessToken, "session-1")
    XCTAssertEqual(keyMaterialStore.currentUserId, userHandle)

    let requestPaths = networkClient.requests.map { $0.url?.path ?? "" }
    XCTAssertTrue(requestPaths.contains { $0.hasSuffix("/api/auth/register") }, "Should call /auth/register")
    XCTAssertTrue(requestPaths.contains { $0.hasSuffix("/api/prekeys/publish") }, "Should publish prekeys")
  }

  @MainActor
  func testRegisterIgnoresForeignPersistedDeviceIdentityFromKeychain() async throws {
    let suiteName: String = "AuthViewModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let keyMaterialStore = InMemoryKeyMaterialStore()
    let tokenStore = InMemoryTokenStore()
    let sessionStore = UserDefaultsSessionStore(defaults: defaults)
    let networkClient = MockNetworkClient()
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )

    let staleHandle = "@old:example.org"
    let staleIdentity = try container.identityService.createIdentity(userHandle: staleHandle)
    let staleDeviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: staleHandle,
      seedPhrase: staleIdentity.seedPhrase,
      deviceId: "stale-device-1"
    )
    keyMaterialStore.saveDeviceIdentity(staleDeviceIdentity, for: staleHandle)
    keyMaterialStore.setCurrentUserId(staleHandle)

    let userHandle = "@alice:example.org"
    networkClient.registerFallbackResponder { [self] request in
      guard let path = request.url?.path else {
        throw NSError(domain: "AuthViewModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing request path"])
      }

      if path.hasSuffix("/api/auth/register") {
        let payload = try self.requestJSONBody(request)
        guard self.registerPayloadHasValidInitialChain(payload, expectedUserHandle: userHandle) else {
          return MockNetworkClient.QueuedResponse(
            statusCode: 401,
            body: Data("{\"error\":\"Invalid initial device certificate chain\"}".utf8)
          )
        }

        let initialDevice = payload["initial_device"] as? [String: Any] ?? [:]
        let response = try JSONSerialization.data(withJSONObject: [
          "user_handle": userHandle,
          "device_id": initialDevice["device_id"] as? String ?? "",
          "session_token": "session-1",
          "refresh_token": "refresh-1",
          "expires_in": 900,
        ])
        return MockNetworkClient.QueuedResponse(statusCode: 201, body: response)
      }

      if path.hasSuffix("/api/prekeys/publish") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: Data("{\"signed_prekey_id\":\"signed-1\",\"one_time_prekeys_added\":100}".utf8)
        )
      }

      return nil
    }

    let viewModel = AuthViewModel(container: container)
    _ = try await viewModel.register(userHandle: userHandle)

    let registerPayload = try requestJSONBody(networkClient.requests[0])
    let initialDevice = try XCTUnwrap(registerPayload["initial_device"] as? [String: Any])
    let chain = try XCTUnwrap(initialDevice["device_certificate_chain"] as? [[String: Any]])
    XCTAssertEqual(chain.first?["account_handle"] as? String, userHandle)
    XCTAssertNotEqual(initialDevice["device_id"] as? String, staleDeviceIdentity.deviceId)
    XCTAssertEqual(keyMaterialStore.currentUserId, userHandle)
    XCTAssertEqual(tokenStore.accessToken, "session-1")
  }
}

private extension AuthViewModelTests {
  func requestJSONBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  func registerPayloadHasValidInitialChain(
    _ payload: [String: Any],
    expectedUserHandle: String
  ) -> Bool {
    guard
      let initialDevice = payload["initial_device"] as? [String: Any],
      let deviceId = initialDevice["device_id"] as? String,
      let dkSignPub = initialDevice["dk_sign_pub"] as? String,
      let dkDhPub = initialDevice["dk_dh_pub"] as? String,
      let chain = initialDevice["device_certificate_chain"] as? [[String: Any]],
      let leaf = chain.last
    else {
      return false
    }

    return chain.first?["account_handle"] as? String == expectedUserHandle
      && leaf["device_id"] as? String == deviceId
      && leaf["device_sign_pub"] as? String == dkSignPub
      && leaf["device_dh_pub"] as? String == dkDhPub
  }
}
