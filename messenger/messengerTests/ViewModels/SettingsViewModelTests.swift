import XCTest
@testable import messenger

final class SettingsViewModelTests: XCTestCase {
  @MainActor
  func testHasPrivateKeyResolvesSeedByFallbackSessionIdentifiers() throws {
    let suiteName: String = "SettingsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let legacySessionUser = User(
      id: "legacy-user-id",
      username: "@alice:example.org",
      email: "@alice:example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: legacySessionUser))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.saveSeedPhrase("seed-for-alice", for: "@alice:example.org")

    let container: AppContainer = AppContainer(
      environment: .local,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )

    let viewModel: SettingsViewModel = SettingsViewModel(container: container)

    XCTAssertTrue(viewModel.hasPrivateKey)
    XCTAssertEqual(try viewModel.exportPrivateKey(), "seed-for-alice")
  }

  @MainActor
  func testManualReadReceiptsTogglePersistsInDefaults() throws {
    let suiteName: String = "SettingsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "@alice:example.org",
          username: "@alice:example.org",
          email: "@alice:example.org",
          publicKey: "",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let container: AppContainer = AppContainer(
      environment: .local,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: InMemoryKeyMaterialStore(),
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )

    let viewModel: SettingsViewModel = SettingsViewModel(container: container, defaults: defaults)
    XCTAssertFalse(viewModel.manualReadReceiptsEnabled)

    viewModel.setManualReadReceipts(enabled: true)
    XCTAssertTrue(viewModel.manualReadReceiptsEnabled)
    XCTAssertTrue(defaults.bool(forKey: "messaging.manual_read_receipts"))
  }

  @MainActor
  func testLogoutClearsSeedButPreservesDeviceIdentity() async throws {
    let suiteName: String = "SettingsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let user = User(
      id: "@alice:example.org",
      username: "@alice:example.org",
      email: "@alice:example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: user))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(user.id)
    keyMaterialStore.saveSeedPhrase("seed-for-alice", for: user.id)
    keyMaterialStore.saveDeviceIdentity(
      PersistedDeviceIdentity(
        deviceId: "device-keep-1",
        dkSignPrivate: "sign-priv",
        dkSignPublic: "sign-pub",
        dkDhPrivate: "dh-priv",
        dkDhPublic: "dh-pub",
        deviceCertificateChain: [],
        createdAt: Date()
      ),
      for: user.id
    )

    let tokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access", refreshToken: "refresh")

    let container: AppContainer = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )

    let viewModel: SettingsViewModel = SettingsViewModel(container: container, defaults: defaults)

    await viewModel.logout()

    XCTAssertNil(keyMaterialStore.seedPhrase(for: user.id))
    XCTAssertEqual(keyMaterialStore.deviceIdentity(for: user.id)?.deviceId, "device-keep-1")
    XCTAssertNil(container.sessionStore.currentUser)
    XCTAssertNil(tokenStore.accessToken)
  }

  @MainActor
  func testDiagnosticsSummaryReportsSuccessfulTurnCredentialProbe() async throws {
    let suiteName: String = "SettingsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let networkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: Self.turnCredentialsResponseJSON())
    let tokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-token", refreshToken: "refresh-token")
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let user = User(
      id: "@alice:example.org",
      username: "@alice:example.org",
      email: "@alice:example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: user))
    let keyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.saveSeedPhrase("seed-for-alice", for: user.id)

    let container: AppContainer = AppContainer(
      environment: .production,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )
    let viewModel: SettingsViewModel = SettingsViewModel(container: container, defaults: defaults)

    await viewModel.refreshNetworkDiagnostics(force: true)

    let summary: String = viewModel.diagnosticsSummary()
    XCTAssertTrue(summary.contains("turn=ok("))
    XCTAssertTrue(summary.contains("policy=relay"))
    XCTAssertTrue(summary.contains("servers=1"))
    XCTAssertTrue(summary.contains("ttl=300"))
    XCTAssertTrue(summary.contains("first=turn:turn.surraund.com:3478"))
    XCTAssertTrue(summary.contains("api=https://messenger.surraund.com/api"))
    XCTAssertTrue(summary.contains("ws=wss://messenger.surraund.com/socket.io"))
    XCTAssertFalse(summary.contains("turn-pass"))

    let request: URLRequest = try XCTUnwrap(networkClient.requests.first)
    XCTAssertEqual(request.url?.path, "/api/turn/credentials")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
  }

  @MainActor
  func testDiagnosticsSummaryReportsTurnCredentialProbeFailure() async throws {
    let suiteName: String = "SettingsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let networkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 400, json: "{\"error\":\"Invalid TURN credential request\"}")
    let tokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-token", refreshToken: "refresh-token")
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "@alice:example.org",
          username: "@alice:example.org",
          email: "@alice:example.org",
          publicKey: "",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let container: AppContainer = AppContainer(
      environment: .production,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: InMemoryKeyMaterialStore(),
      sessionStore: sessionStore,
      networkClient: networkClient
    )
    let viewModel: SettingsViewModel = SettingsViewModel(container: container, defaults: defaults)

    await viewModel.refreshNetworkDiagnostics(force: true)

    let summary: String = viewModel.diagnosticsSummary()
    XCTAssertTrue(summary.contains("turn=failed(Invalid TURN credential request)"))
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
