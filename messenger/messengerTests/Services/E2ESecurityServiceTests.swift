import XCTest
@testable import messenger

final class E2ESecurityServiceTests: XCTestCase {
  func testGetPeerFingerprintUsesPeekQuery() async throws {
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

    let networkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: bundleJSON)
    let tokenStore = InMemoryTokenStore()
    let apiClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service = E2ESecurityService(
      apiClient: apiClient,
      sessionStore: MockSecuritySessionStore()
    )

    _ = try await service.getPeerFingerprint(peerUserId: "@peer:example.com")

    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("peek=true") == true)
  }

  func testTrustSnapshotRoundTripPreservesVerifiedPeersAndConsent() async throws {
    let sourceSuite: String = "E2ESecurityServiceTests.source.\(UUID().uuidString)"
    let targetSuite: String = "E2ESecurityServiceTests.target.\(UUID().uuidString)"
    guard let sourceDefaults: UserDefaults = UserDefaults(suiteName: sourceSuite),
      let targetDefaults: UserDefaults = UserDefaults(suiteName: targetSuite)
    else {
      XCTFail("Failed to create isolated defaults suites")
      return
    }

    defer {
      sourceDefaults.removePersistentDomain(forName: sourceSuite)
      targetDefaults.removePersistentDomain(forName: targetSuite)
    }

    let sessionStore = MockSecuritySessionStore()
    let user = User(
      id: "@alice:example.org",
      username: "@alice:example.org",
      email: "@alice:example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: user))

    let networkClient = MockNetworkClient()
    let tokenStore = InMemoryTokenStore()
    let sourceService = E2ESecurityService(
      apiClient: APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore),
      sessionStore: sessionStore,
      defaults: sourceDefaults
    )

    _ = try await sourceService.verifyTrust(
      peerUserId: "@bob:example.org",
      fingerprint: "fingerprint-bob",
      method: .qr
    )
    _ = try await sourceService.setConsent(
      peerUserId: "@bob:example.org",
      enabled: true,
      source: "linked-device"
    )

    let snapshot: DeviceLinkTrustStateSnapshot = sourceService.exportSnapshot(for: user.id)

    let targetService = E2ESecurityService(
      apiClient: APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore),
      sessionStore: sessionStore,
      defaults: targetDefaults
    )
    targetService.importSnapshot(snapshot, for: user.id)

    let status: E2ETrustStatusResponse = try await targetService.getTrustStatus(peerUserId: "@bob:example.org")
    let consent: E2EConsentResponse = try await targetService.getConsent(peerUserId: "@bob:example.org")

    XCTAssertEqual(status.effectiveState, .verified)
    XCTAssertEqual(status.trustRecord?.peerFingerprint, "fingerprint-bob")
    XCTAssertEqual(consent.consent?.consentGiven, true)
    XCTAssertEqual(consent.consent?.consentSource, "linked-device")
  }
}

private final class MockSecuritySessionStore: AppSessionStore {
  var currentUser: SessionUser?

  func save(user: SessionUser) {
    currentUser = user
  }

  func clear() {
    currentUser = nil
  }
}
