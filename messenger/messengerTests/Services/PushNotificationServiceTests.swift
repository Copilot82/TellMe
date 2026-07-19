import XCTest
@testable import messenger

@MainActor
final class PushNotificationServiceTests: XCTestCase {
  func testTokenHexFormatting() {
    let callService: MockCallService = MockCallService()
    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )

    let value: String = service.tokenHexString(from: Data([0x0A, 0xBC, 0x00]))

    XCTAssertEqual(value, "0abc00")
  }

  func testRegisterDeviceTokenCallsCallService() async throws {
    let callService: MockCallService = MockCallService()
    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )

    let _ = try await service.registerDeviceToken(Data(repeating: 0x11, count: 4))

    XCTAssertEqual(callService.registerCallsCount, 1)
    XCTAssertEqual(callService.lastPayload?.token, "11111111")
    XCTAssertEqual(callService.lastPayload?.pushEnvironment, .sandbox)
    XCTAssertEqual(callService.lastPayload?.tokenKind, .alert)
  }

  func testRegisterVoIPDeviceTokenUsesVoIPKind() async throws {
    let callService: MockCallService = MockCallService()
    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )

    let _ = try await service.registerDeviceToken(Data(repeating: 0x33, count: 4), kind: .voip)

    XCTAssertEqual(callService.registerCallsCount, 1)
    XCTAssertEqual(callService.lastPayload?.token, "33333333")
    XCTAssertEqual(callService.lastPayload?.tokenKind, .voip)
  }

  func testRegisterDeviceTokenUsesInjectedProductionEnvironment() async throws {
    let callService: MockCallService = MockCallService()
    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      pushEnvironmentProvider: { .production }
    )

    let _ = try await service.registerDeviceToken(Data(repeating: 0x22, count: 4))

    XCTAssertEqual(callService.registerCallsCount, 1)
    XCTAssertEqual(callService.lastPayload?.pushEnvironment, .production)
  }

  func testHandleAPNSTokenPersistsCurrentToken() async {
    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let service: PushNotificationService = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults
    )

    let token: Data = Data([0xAA, 0xBB, 0xCC, 0xDD])
    await service.handleAPNSToken(token)

    XCTAssertEqual(service.currentAPNSToken(), token)
  }

  func testHandleVoIPTokenPersistsCurrentToken() async {
    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let service: PushNotificationService = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults
    )

    let token: Data = Data([0x10, 0x20, 0x30, 0x40])
    await service.handleVoIPToken(token)

    XCTAssertEqual(service.currentVoIPToken(), token)
    XCTAssertNil(service.currentAPNSToken())
  }

  func testHandleVoIPTokenInvalidationDeletesOnlyVoIPTokenState() async {
    let callService: MockCallService = MockCallService()
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "@alice:example.org",
          username: "@alice:example.org",
          email: "alice@example.org",
          publicKey: "",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let apnsToken: Data = Data([0x10, 0x20, 0x30, 0x40])
    let voipToken: Data = Data([0xAA, 0xBB, 0xCC, 0xDD])
    defaults.set(apnsToken.base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set(voipToken.base64EncodedString(), forKey: "push.latest_voip_token")
    defaults.set("alert-signature", forKey: "push.last_registered_signature")
    defaults.set("voip-signature", forKey: "push.last_registered_voip_signature")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults
    )

    await service.handleVoIPTokenInvalidation()

    XCTAssertEqual(callService.deletedTokens, ["aabbccdd"])
    XCTAssertEqual(service.currentAPNSToken(), apnsToken)
    XCTAssertNil(service.currentVoIPToken())
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_signature"), "alert-signature")
    XCTAssertNil(defaults.string(forKey: "push.last_registered_voip_signature"))
  }

  func testSyncDeviceTokenIfNeededReregistersWhenStoredSignatureUsesLegacyFormat() async {
    let callService: MockCallService = MockCallService()
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let token: Data = Data(repeating: 0x11, count: 4)
    defaults.set(token.base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set("user-1|11111111", forKey: "push.last_registered_signature")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    await service.syncDeviceTokenIfNeeded()

    XCTAssertEqual(callService.registerCallsCount, 1)
    XCTAssertEqual(callService.lastPayload?.pushEnvironment, .production)
    XCTAssertEqual(
      defaults.string(forKey: "push.last_registered_signature"),
      "user-1|11111111|production|alert"
    )
  }

  func testSyncDeviceTokenIfNeededRegistersAlertAndVoIPTokensSeparately() async {
    let callService: MockCallService = MockCallService()
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(Data(repeating: 0x11, count: 4).base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set(Data(repeating: 0x22, count: 4).base64EncodedString(), forKey: "push.latest_voip_token")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    await service.syncDeviceTokenIfNeeded()

    XCTAssertEqual(callService.registeredPayloads.map(\.token), ["11111111", "22222222"])
    XCTAssertEqual(callService.registeredPayloads.map(\.tokenKind), [.alert, .voip])
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_signature"), "user-1|11111111|production|alert")
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_voip_signature"), "user-1|22222222|production|voip")
  }

  func testSyncDeviceTokenIfNeededRerunsWhenVoIPTokenArrivesDuringAlertSync() async {
    let callService: MockCallService = MockCallService()
    callService.listDeviceTokensError = NSError(domain: "PushNotificationServiceTests", code: 1)
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let service = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    let alertRegisterStarted = expectation(description: "alert token registration started")
    var releaseAlertRegister: CheckedContinuation<Void, Never>?
    callService.onRegisterDeviceToken = { payload in
      guard payload.tokenKind == .alert else {
        return
      }

      alertRegisterStarted.fulfill()
      await withCheckedContinuation { continuation in
        releaseAlertRegister = continuation
      }
    }

    let alertSyncTask = Task { @MainActor in
      await service.handleAPNSToken(Data(repeating: 0x11, count: 4))
    }
    await fulfillment(of: [alertRegisterStarted], timeout: 1)

    await service.handleVoIPToken(Data(repeating: 0x22, count: 4))
    releaseAlertRegister?.resume()
    await alertSyncTask.value

    XCTAssertEqual(callService.registeredPayloads.map(\.tokenKind), [.alert, .voip])
    XCTAssertEqual(callService.registeredPayloads.map(\.token), ["11111111", "22222222"])
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_signature"), "user-1|11111111|production|alert")
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_voip_signature"), "user-1|22222222|production|voip")
  }

  func testSyncDeviceTokenIfNeededReregistersWhenServerLostTokensDespiteStoredSignatures() async {
    let callService: MockCallService = MockCallService()
    callService.listDeviceTokensResponse = DeviceTokensResponse(tokens: [])
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(Data(repeating: 0x11, count: 4).base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set(Data(repeating: 0x22, count: 4).base64EncodedString(), forKey: "push.latest_voip_token")
    defaults.set("user-1|11111111|production|alert", forKey: "push.last_registered_signature")
    defaults.set("user-1|22222222|production|voip", forKey: "push.last_registered_voip_signature")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    await service.syncDeviceTokenIfNeeded()

    XCTAssertEqual(callService.listDeviceTokensCallsCount, 1)
    XCTAssertEqual(callService.registeredPayloads.map(\.token), ["11111111", "22222222"])
    XCTAssertEqual(callService.registeredPayloads.map(\.tokenKind), [.alert, .voip])
    XCTAssertEqual(service.diagnosticsSummary(), "alert=registered,voip=registered")
  }

  func testSyncDeviceTokenIfNeededRestoresLocalSignaturesFromServerTokensWithoutReregistering() async {
    let callService: MockCallService = MockCallService()
    callService.listDeviceTokensResponse = DeviceTokensResponse(tokens: [
      makeDeviceToken(token: "11111111", kind: .alert, environment: .production),
      makeDeviceToken(token: "22222222", kind: .voip, environment: .production),
    ])
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(Data(repeating: 0x11, count: 4).base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set(Data(repeating: 0x22, count: 4).base64EncodedString(), forKey: "push.latest_voip_token")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    await service.syncDeviceTokenIfNeeded()

    XCTAssertEqual(callService.registerCallsCount, 0)
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_signature"), "user-1|11111111|production|alert")
    XCTAssertEqual(defaults.string(forKey: "push.last_registered_voip_signature"), "user-1|22222222|production|voip")
    XCTAssertEqual(service.diagnosticsSummary(), "alert=registered,voip=registered")
  }

  func testDiagnosticsSummaryReportsPushRegistrationFailure() async {
    let callService: MockCallService = MockCallService()
    callService.listDeviceTokensResponse = DeviceTokensResponse(tokens: [])
    callService.registerError = APIError.transport("A TLS error caused the secure connection to fail.")
    let sessionStore: MockSessionStore = MockSessionStore()
    sessionStore.save(
      user: SessionUser(
        user: User(
          id: "User-1",
          username: "user",
          email: "user@example.com",
          publicKey: "pk",
          createdAt: nil,
          updatedAt: nil
        )
      )
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(Data(repeating: 0x11, count: 4).base64EncodedString(), forKey: "push.latest_apns_token")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults,
      pushEnvironmentProvider: { .production }
    )

    await service.syncDeviceTokenIfNeeded()

    let diagnostics = service.diagnosticsSummary()
    XCTAssertTrue(diagnostics.contains("alert=failed"))
    XCTAssertTrue(diagnostics.contains("voip=missing"))
    XCTAssertTrue(diagnostics.contains("TLS error"))
    XCTAssertNil(defaults.string(forKey: "push.last_registered_signature"))
  }

  func testUnregisterCurrentDeviceTokenIfNeededDeletesServerTokenAndClearsRegistrationSignature() async {
    let callService: MockCallService = MockCallService()
    let sessionStore: MockSessionStore = MockSessionStore()
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

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set(Data([0xAB, 0xCD, 0xEF, 0x01]).base64EncodedString(), forKey: "push.latest_apns_token")
    defaults.set(Data([0xAB, 0xCD, 0xEF, 0x02]).base64EncodedString(), forKey: "push.latest_voip_token")
    defaults.set("stale-signature", forKey: "push.last_registered_signature")
    defaults.set("stale-voip-signature", forKey: "push.last_registered_voip_signature")

    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: sessionStore,
      keyMaterialStore: MockKeyMaterialStore(),
      defaults: defaults
    )

    await service.unregisterCurrentDeviceTokenIfNeeded()

    XCTAssertEqual(callService.deletedTokens, ["abcdef01", "abcdef02"])
    XCTAssertNil(defaults.string(forKey: "push.last_registered_signature"))
    XCTAssertNil(defaults.string(forKey: "push.last_registered_voip_signature"))
  }

  func testSyntheticRemoteNotificationPostsSyncEvent() async {
    let callService: MockCallService = MockCallService()
    let notificationCenter = NotificationCenter()
    let service: PushNotificationService = PushNotificationService(
      callService: callService,
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      notificationCenter: notificationCenter
    )

    let expectation = expectation(description: "synthetic push notification handled")
    var observedHint: String?
    var observedMessageId: String?
    let token = notificationCenter.addObserver(
      forName: .didProcessRemoteNotificationSync,
      object: nil,
      queue: nil
    ) { notification in
      observedHint = notification.userInfo?["hint"] as? String
      observedMessageId = notification.userInfo?["message_id"] as? String
      expectation.fulfill()
    }
    defer {
      notificationCenter.removeObserver(token)
    }

    let processed: Bool = await service.handleRemoteNotification([
      "uitest_remote_sync": true,
      "hint": "message",
      "message_id": "synthetic-msg-001",
    ])

    XCTAssertTrue(processed)
    await fulfillment(of: [expectation], timeout: 1)
    XCTAssertEqual(observedHint, "message")
    XCTAssertEqual(observedMessageId, "synthetic-msg-001")
  }

  func testForegroundNotificationIsSuppressedForVisibleConversationPeer() {
    let service: PushNotificationService = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )

    service.setVisibleConversationPeerUserId("@Bob:example.org")

    XCTAssertFalse(
      service.shouldPresentForegroundNotification([
        "hint": PushNotificationHint.message.rawValue,
      ])
    )
  }

  func testHandleRemoteNotificationDrainsBacklogAcrossMultiplePages() async {
    let sessionStore = MockSessionStore()
    let currentUser = User(
      id: "@alice:example.org",
      username: "@alice:example.org",
      email: "alice@example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: currentUser))

    let keyMaterialStore = MockKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(currentUser.id)
    keyMaterialStore.saveDeviceId("device-1", for: currentUser.id)

    let firstPage: [FederatedMailboxBlob] = (0..<200).map { index in
      makeMalformedBlob(messageId: "msg-\(index)", deliveryId: "delivery-\(index)")
    }
    let secondPage: [FederatedMailboxBlob] = [
      makeMalformedBlob(messageId: "msg-200", deliveryId: "delivery-200"),
    ]
    let messageService = SequencedMessageService(
      syncResponses: [
        FederatedSyncResponse(deviceId: "device-1", blobs: firstPage),
        FederatedSyncResponse(deviceId: "device-1", blobs: secondPage),
        FederatedSyncResponse(deviceId: "device-1", blobs: []),
      ]
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: messageService,
      sessionStore: sessionStore,
      keyMaterialStore: keyMaterialStore,
      defaults: defaults,
      notificationCenter: NotificationCenter()
    )
    service.attach(container: container)

    let processed = await service.handleRemoteNotification([
      "aps": ["content-available": 1],
    ])

    XCTAssertTrue(processed)
    XCTAssertEqual(messageService.pullSyncCalls.map(\.limit), [200, 200])
    XCTAssertEqual(messageService.pullSyncCalls.map(\.deviceId), ["device-1", "device-1"])
    XCTAssertEqual(messageService.ackCalls.count, 2)
    XCTAssertEqual(messageService.ackCalls[0].count, 200)
    XCTAssertEqual(messageService.ackCalls[1], ["msg-200"])
  }

  func testSynchronizeIncomingMailboxPostsProcessedNotificationWithReason() async {
    let sessionStore = MockSessionStore()
    let currentUser = User(
      id: "@alice:example.org",
      username: "@alice:example.org",
      email: "alice@example.org",
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: currentUser))

    let keyMaterialStore = MockKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(currentUser.id)
    keyMaterialStore.saveDeviceId("device-1", for: currentUser.id)

    let messageService = SequencedMessageService(
      syncResponses: [
        FederatedSyncResponse(
          deviceId: "device-1",
          blobs: [
            makeMalformedBlob(messageId: "msg-realtime-1", deliveryId: "delivery-realtime-1"),
          ]
        ),
        FederatedSyncResponse(deviceId: "device-1", blobs: []),
      ]
    )

    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )
    let notificationCenter = NotificationCenter()
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: messageService,
      sessionStore: sessionStore,
      keyMaterialStore: keyMaterialStore,
      defaults: defaults,
      notificationCenter: notificationCenter
    )
    service.attach(container: container)

    let notificationExpectation = expectation(description: "mailbox sync processed notification")
    var observedReason: String?
    let token = notificationCenter.addObserver(
      forName: .didProcessRemoteNotificationSync,
      object: nil,
      queue: nil
    ) { notification in
      observedReason = notification.userInfo?["sync_reason"] as? String
      notificationExpectation.fulfill()
    }
    defer {
      notificationCenter.removeObserver(token)
    }

    let processed = await service.synchronizeIncomingMailbox(reason: "sync_blob_available")

    XCTAssertTrue(processed)
    XCTAssertEqual(messageService.pullSyncCalls.map(\.deviceId), ["device-1"])
    XCTAssertEqual(messageService.ackCalls, [["msg-realtime-1"]])
    await fulfillment(of: [notificationExpectation], timeout: 1)
    XCTAssertEqual(observedReason, "sync_blob_available")
  }

  func testSynchronizeIncomingMailboxReportsEncryptedCallOfferWithoutOpenConversation() async throws {
    let suiteName: String = "PushNotificationServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let currentUser: String = "@bob:messenger.example.com"
    let peerUser: String = "@alice:messenger.example.com"
    let localDeviceId: String = "dev-b"
    let peerDeviceId: String = "dev-a"
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    sessionStore.save(user: SessionUser(user: User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )))

    let keyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(currentUser)
    keyMaterialStore.saveDeviceId(localDeviceId, for: currentUser)
    let networkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: #"{"acked":1}"#)
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )

    let peerIdentity = try container.identityService.createIdentity(userHandle: peerUser)
    let localIdentity = try container.identityService.createIdentity(userHandle: currentUser)
    keyMaterialStore.saveSeedPhrase(localIdentity.seedPhrase, for: currentUser)
    let storageKey = try container.identityService.deriveStorageKey(seedPhrase: localIdentity.seedPhrase)
    container.ratchetSessionStore.configure(storageKey: storageKey)

    let senderState = try container.x3dhService.bootstrapSession(
      seedPhrase: peerIdentity.seedPhrase,
      localUserHandle: peerUser,
      localDeviceId: peerDeviceId,
      peerUserHandle: currentUser,
      peerDeviceId: localDeviceId,
      peerIkDhPublic: localIdentity.ikDHPublic,
      sessionId: "session-push-call-ab",
      conversationId: "conv-push-call-ab"
    )
    let receiverState = try container.x3dhService.bootstrapSession(
      seedPhrase: localIdentity.seedPhrase,
      localUserHandle: currentUser,
      localDeviceId: localDeviceId,
      peerUserHandle: peerUser,
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: peerIdentity.ikDHPublic,
      sessionId: "session-push-call-ab",
      conversationId: "conv-push-call-ab"
    )
    try container.ratchetSessionStore.upsert(receiverState)

    let callId: String = "call-push-sync-offer-1"
    let callPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: peerDeviceId,
      targetDeviceId: localDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": "initial",
        "from_user": peerUser,
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
    let callPayloadData: Data = try JSONSerialization.data(withJSONObject: callPayload, options: [])
    let callBody: String = try XCTUnwrap(String(data: callPayloadData, encoding: .utf8))
    let payload = E2EMessagePayload(
      conversationId: "conv-push-call-ab",
      msgType: Message.MessageType.callOffer.rawValue,
      body: callBody,
      attachments: [],
      padding: "00000000"
    )
    let sealed = try container.envelopeService.seal(payload: payload, state: senderState)
    let blob = FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-b",
      ownerDeviceId: localDeviceId,
      senderServer: "messenger.example.com",
      messageId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      deliveryId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
    let messageService = SequencedMessageService(syncResponses: [
      FederatedSyncResponse(deviceId: localDeviceId, blobs: [blob]),
      FederatedSyncResponse(deviceId: localDeviceId, blobs: []),
    ])
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: messageService,
      sessionStore: sessionStore,
      keyMaterialStore: keyMaterialStore,
      defaults: defaults,
      notificationCenter: NotificationCenter()
    )
    service.attach(container: container)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }

    let processed = await service.synchronizeIncomingMailbox(reason: "voip_opaque")

    let snapshot = coordinator.testingSnapshot()
    let reportedUUID = try XCTUnwrap(snapshot.uuidByCallId[callId])
    XCTAssertTrue(processed)
    XCTAssertEqual(messageService.pullSyncCalls.map(\.deviceId), [localDeviceId])
    XCTAssertEqual(snapshot.incomingCallIdsByUUID[reportedUUID], callId)
  }

  func testReportIncomingCallsDeduplicatesRepeatedEncryptedOfferDescriptors() {
    let notificationCenter = NotificationCenter()
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      notificationCenter: notificationCenter
    )
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let callId = "call-deduplicated-offer-1"
    let firstUUID = UUID()
    let duplicateUUID = UUID()
    let encryptedOfferExpectation = expectation(description: "deduplicated encrypted offer notification")
    encryptedOfferExpectation.expectedFulfillmentCount = 1
    encryptedOfferExpectation.assertForOverFulfill = true
    var observedCallIds: [String] = []
    let token = notificationCenter.addObserver(
      forName: .didReceiveEncryptedCallOffer,
      object: nil,
      queue: nil
    ) { notification in
      if let descriptor = notification.userInfo?["descriptor"] as? E2EIncomingCallDescriptor {
        observedCallIds.append(descriptor.callId)
      }
      encryptedOfferExpectation.fulfill()
    }
    defer {
      notificationCenter.removeObserver(token)
    }

    service.reportIncomingCallsForTesting([
      makeIncomingCallDescriptor(callId: callId, systemUUID: firstUUID),
      makeIncomingCallDescriptor(callId: callId, systemUUID: duplicateUUID),
    ])

    wait(for: [encryptedOfferExpectation], timeout: 1)
    let snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(observedCallIds, [callId])
    XCTAssertEqual(snapshot.uuidByCallId[callId], firstUUID)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID, [firstUUID: callId])
    XCTAssertNil(snapshot.callIdByUUID[duplicateUUID])
  }

  func testReportIncomingCallsDeduplicatesAcrossIncrementalBatches() {
    let notificationCenter = NotificationCenter()
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore(),
      notificationCenter: notificationCenter
    )
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let callId = "call-deduplicated-incremental-offer-1"
    let firstUUID = UUID()
    let duplicateUUID = UUID()
    let encryptedOfferExpectation = expectation(description: "incremental encrypted offer notification")
    encryptedOfferExpectation.expectedFulfillmentCount = 1
    encryptedOfferExpectation.assertForOverFulfill = true
    var observedCallIds: [String] = []
    let token = notificationCenter.addObserver(
      forName: .didReceiveEncryptedCallOffer,
      object: nil,
      queue: nil
    ) { notification in
      if let descriptor = notification.userInfo?["descriptor"] as? E2EIncomingCallDescriptor {
        observedCallIds.append(descriptor.callId)
      }
      encryptedOfferExpectation.fulfill()
    }
    defer {
      notificationCenter.removeObserver(token)
    }

    var reportedCallIds: Set<String> = []
    service.reportIncomingCallsForTesting(
      [makeIncomingCallDescriptor(callId: callId, systemUUID: firstUUID)],
      reportedCallIds: &reportedCallIds
    )
    service.reportIncomingCallsForTesting(
      [makeIncomingCallDescriptor(callId: callId, systemUUID: duplicateUUID)],
      reportedCallIds: &reportedCallIds
    )

    wait(for: [encryptedOfferExpectation], timeout: 1)
    let snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(observedCallIds, [callId])
    XCTAssertEqual(reportedCallIds, [callId])
    XCTAssertEqual(snapshot.uuidByCallId[callId], firstUUID)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID, [firstUUID: callId])
    XCTAssertNil(snapshot.callIdByUUID[duplicateUUID])
  }

  func testIncomingCallDescriptorSelectionReportsOpenInitialOffer() {
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )
    let callId = "call-push-open-offer-1"
    let conversation = makeConversation(id: "conversation-\(callId)")
    let offer = makeCallOfferMessage(callId: callId, createdAt: Date())

    let descriptors = service.incomingCallDescriptorsForTesting(
      from: [offer],
      allMessages: [offer],
      conversation: conversation,
      currentUserId: "@alice:example.org",
      localDeviceId: "device-1"
    )

    XCTAssertEqual(descriptors.map(\.callId), [callId])
    XCTAssertEqual(descriptors.first?.callerUserId, "@bob:example.org")
  }

  func testIncomingCallDescriptorSelectionSkipsOfferForDifferentLocalDevice() {
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )
    let callId = "call-push-other-device-offer-1"
    let conversation = makeConversation(id: "conversation-\(callId)")
    let offer = makeCallOfferMessage(
      callId: callId,
      createdAt: Date(),
      targetDeviceId: "other-local-device-1"
    )

    let descriptors = service.incomingCallDescriptorsForTesting(
      from: [offer],
      allMessages: [offer],
      conversation: conversation,
      currentUserId: "@alice:example.org",
      localDeviceId: "device-1"
    )

    XCTAssertTrue(descriptors.isEmpty)
  }

  func testIncomingCallDescriptorSelectionSkipsOfferClosedByNewerCallEnd() {
    let service = PushNotificationService(
      callService: MockCallService(),
      messageService: MockMessageService(),
      sessionStore: MockSessionStore(),
      keyMaterialStore: MockKeyMaterialStore()
    )
    let callId = "call-push-closed-offer-1"
    let conversation = makeConversation(id: "conversation-\(callId)")
    let offerCreatedAt = Date()
    let offer = makeCallOfferMessage(callId: callId, createdAt: offerCreatedAt)
    let callEnd = makeCallEndMessage(
      callId: callId,
      createdAt: offerCreatedAt.addingTimeInterval(1)
    )

    let descriptors = service.incomingCallDescriptorsForTesting(
      from: [offer],
      allMessages: [offer, callEnd],
      conversation: conversation,
      currentUserId: "@alice:example.org"
    )

    XCTAssertTrue(descriptors.isEmpty)
  }

  private func makeMalformedBlob(messageId: String, deliveryId: String) -> FederatedMailboxBlob {
    FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-local",
      ownerDeviceId: "device-1",
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: deliveryId,
      ciphertextBlob: "!!!not-base64!!!",
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
  }

  private func makeCallOfferMessage(
    callId: String,
    createdAt: Date,
    targetDeviceId: String = "device-1"
  ) -> Message {
    makeCallSignalMessage(
      callId: callId,
      type: .callOffer,
      payload: CallSignalEnvelope.payload(
        callId: callId,
        senderDeviceId: "peer-device-1",
        targetDeviceId: targetDeviceId,
        dtlsFingerprint: testDTLSFingerprint(),
        values: [
          "call_type": Call.CallType.video.rawValue,
          "offer_kind": "initial",
          "from_user": "@bob:example.org",
          "offer": [
            "type": "offer",
            "sdp": sdpWithDTLSFingerprint(),
          ],
        ]
      ),
      createdAt: createdAt
    )
  }

  private func makeCallEndMessage(callId: String, createdAt: Date) -> Message {
    makeCallSignalMessage(
      callId: callId,
      type: .callEnd,
      payload: CallSignalEnvelope.payload(
        callId: callId,
        senderDeviceId: "peer-device-1",
        targetDeviceId: "device-1",
        values: [
          "status": "ended",
        ]
      ),
      createdAt: createdAt
    )
  }

  private func makeCallSignalMessage(
    callId: String,
    type: Message.MessageType,
    payload: [String: Any],
    createdAt: Date
  ) -> Message {
    let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: [])
    let body = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return Message(
      id: "\(type.rawValue)-\(callId)",
      conversationId: "conversation-\(callId)",
      senderId: "@bob:example.org",
      content: body,
      type: type,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: createdAt,
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
  }

  private func sdpWithDTLSFingerprint() -> String {
    [
      "v=0",
      "a=fingerprint:\(testDTLSFingerprint())",
      "a=candidate:5 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
      "",
    ].joined(separator: "\r\n")
  }

  private func testDTLSFingerprint() -> String {
    "sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:10:20:30:40:50:60:70:80:90:A0:B0:C0:D0:E0:F0:01"
  }

  private func makeConversation(id: String) -> Conversation {
    Conversation(
      id: id,
      type: .direct,
      name: "@bob:example.org",
      createdAt: Date(),
      updatedAt: Date(),
      participants: [
        ConversationParticipant(
          id: "participant-local-\(id)",
          conversationId: id,
          userId: "@alice:example.org",
          joinedAt: Date(),
          role: .member
        ),
        ConversationParticipant(
          id: "participant-peer-\(id)",
          conversationId: id,
          userId: "@bob:example.org",
          joinedAt: Date(),
          role: .member
        ),
      ]
    )
  }

  private func makeIncomingCallDescriptor(callId: String, systemUUID: UUID) -> E2EIncomingCallDescriptor {
    E2EIncomingCallDescriptor(
      systemUUID: systemUUID,
      callId: callId,
      conversation: Conversation(
        id: "conversation-\(callId)",
        type: .direct,
        name: "@bob:example.org",
        createdAt: Date(),
        updatedAt: Date(),
        participants: [
          ConversationParticipant(
            id: "participant-local-\(callId)",
            conversationId: "conversation-\(callId)",
            userId: "@alice:example.org",
            joinedAt: Date(),
            role: .member
          ),
          ConversationParticipant(
            id: "participant-peer-\(callId)",
            conversationId: "conversation-\(callId)",
            userId: "@bob:example.org",
            joinedAt: Date(),
            role: .member
          ),
        ]
      ),
      offer: CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: "@bob:example.org",
        type: "offer",
        sdp: "v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\n",
        dtlsFingerprint: "AA:BB:CC"
      ),
      callType: .video,
      callerUserId: "@bob:example.org"
    )
  }

  private func makeDeviceToken(
    token: String,
    kind: PushTokenKind,
    environment: PushEnvironment,
    pushEnabled: Bool = true
  ) -> DeviceToken {
    DeviceToken(
      id: "token-\(kind.rawValue)-\(token)",
      userId: "User-1",
      deviceType: .ios,
      token: token,
      deviceName: "iPhone",
      osVersion: "18.0",
      appVersion: "1.0",
      pushEnabled: pushEnabled,
      pushEnvironment: environment,
      pushMode: .privacyFirst,
      tokenKind: kind,
      lastUsedAt: Date(),
      createdAt: Date()
    )
  }
}

private final class MockCallService: CallServiceProtocol {
  var registerCallsCount: Int = 0
  var lastPayload: DeviceTokenRegistrationPayload?
  var registeredPayloads: [DeviceTokenRegistrationPayload] = []
  var deletedTokens: [String] = []
  var listDeviceTokensResponse: DeviceTokensResponse = DeviceTokensResponse(tokens: [])
  var listDeviceTokensError: Error?
  var listDeviceTokensCallsCount: Int = 0
  var registerError: Error?
  var onRegisterDeviceToken: (@MainActor (DeviceTokenRegistrationPayload) async -> Void)?

  func fetchTurnCredentials() async throws -> RTCConfig { fatalError() }

  func registerDeviceToken(_ payload: DeviceTokenRegistrationPayload) async throws -> DeviceTokenResponse {
    registerCallsCount += 1
    lastPayload = payload
    if let onRegisterDeviceToken {
      await onRegisterDeviceToken(payload)
    }
    if let registerError {
      throw registerError
    }
    registeredPayloads.append(payload)

    return DeviceTokenResponse(
      token: DeviceToken(
        id: "1",
        userId: "u1",
        deviceType: .ios,
        token: payload.token,
        deviceName: payload.deviceName,
        osVersion: payload.osVersion,
        appVersion: payload.appVersion,
        pushEnabled: payload.pushEnabled,
        pushEnvironment: payload.pushEnvironment,
        pushMode: payload.pushMode,
        tokenKind: payload.tokenKind,
        lastUsedAt: Date(),
        createdAt: Date()
      )
    )
  }

  func updateDeviceTokenPushEnabled(token: String, pushEnabled: Bool) async throws -> DeviceTokenResponse {
    DeviceTokenResponse(
      token: DeviceToken(
        id: "1",
        userId: "u1",
        deviceType: .ios,
        token: token,
        deviceName: nil,
        osVersion: nil,
        appVersion: nil,
        pushEnabled: pushEnabled,
        pushEnvironment: lastPayload?.pushEnvironment ?? .sandbox,
        pushMode: lastPayload?.pushMode ?? .privacyFirst,
        tokenKind: lastPayload?.tokenKind ?? .alert,
        lastUsedAt: Date(),
        createdAt: Date()
      )
    )
  }

  func listDeviceTokens() async throws -> DeviceTokensResponse {
    listDeviceTokensCallsCount += 1
    if let listDeviceTokensError {
      throw listDeviceTokensError
    }
    return listDeviceTokensResponse
  }

  func deleteDeviceToken(token: String) async throws {
    deletedTokens.append(token)
  }
}

private final class MockMessageService: MessageServiceProtocol {
  func sendDeliveries(_ deliveries: [FederatedDelivery]) async throws -> FederatedSendResponse { fatalError() }
  func ackMessages(_ messageIds: [String]) async throws -> FederatedAckResponse { fatalError() }
  func pullSync(deviceId: String?, limit: Int) async throws -> FederatedSyncResponse { fatalError() }
  func initMediaUpload(mimeHint: String?, sizeHint: Int?, ttlSec: Int?) async throws -> FederatedMediaUploadInitResponse {
    fatalError()
  }
  func uploadCiphertext(
    mediaId: String,
    ciphertext: Data,
    attestation: MediaUploadAttestationPayload
  ) async throws -> FederatedMediaUploadResponse {
    fatalError()
  }
  func downloadCiphertext(mediaId: String, originServer: String, downloadCapability: String) async throws -> Data {
    fatalError()
  }
  func listMessages(conversationId: String, limit: Int, offset: Int) async throws -> MessageListResponse { fatalError() }
  func sendMessage(conversationId: String, payload: MessageSendPayload) async throws -> MessageResponse { fatalError() }
  func sendFileMessage(
    conversationId: String,
    payload: MessageSendPayload,
    file: MultiPartFile
  ) async throws -> MessageResponse {
    fatalError()
  }
  func markAsRead(messageId: String) async throws -> MessageResponse { fatalError() }
  func markAsDelivered(messageId: String) async throws -> MessageResponse { fatalError() }
  func editMessage(messageId: String, content: String) async throws -> MessageResponse { fatalError() }
  func deleteMessage(messageId: String) async throws -> MessageResponse { fatalError() }
  func deleteMessageForMe(messageId: String) async throws { fatalError() }
  func addReaction(messageId: String, emoji: String) async throws -> ReactionResponse { fatalError() }
  func removeReaction(messageId: String) async throws -> ReactionsResponse { fatalError() }
  func listReactions(messageId: String) async throws -> ReactionsResponse { fatalError() }
  func listEdits(messageId: String) async throws -> MessageEditsResponse { fatalError() }
}

private final class MockSessionStore: AppSessionStore {
  var currentUser: SessionUser?

  func save(user: SessionUser) {
    currentUser = user
  }

  func clear() {
    currentUser = nil
  }
}

private final class SequencedMessageService: MessageServiceProtocol {
  private(set) var pullSyncCalls: [(deviceId: String?, limit: Int)] = []
  private(set) var ackCalls: [[String]] = []
  private var syncResponses: [FederatedSyncResponse]

  init(syncResponses: [FederatedSyncResponse]) {
    self.syncResponses = syncResponses
  }

  func sendDeliveries(_ deliveries: [FederatedDelivery]) async throws -> FederatedSendResponse {
    _ = deliveries
    fatalError()
  }

  func ackMessages(_ messageIds: [String]) async throws -> FederatedAckResponse {
    ackCalls.append(messageIds)
    return FederatedAckResponse(acked: messageIds.count)
  }

  func pullSync(deviceId: String?, limit: Int) async throws -> FederatedSyncResponse {
    pullSyncCalls.append((deviceId: deviceId, limit: limit))
    guard !syncResponses.isEmpty else {
      return FederatedSyncResponse(deviceId: deviceId ?? "device-1", blobs: [])
    }

    return syncResponses.removeFirst()
  }

  func initMediaUpload(mimeHint: String?, sizeHint: Int?, ttlSec: Int?) async throws -> FederatedMediaUploadInitResponse {
    _ = mimeHint
    _ = sizeHint
    _ = ttlSec
    fatalError()
  }

  func uploadCiphertext(
    mediaId: String,
    ciphertext: Data,
    attestation: MediaUploadAttestationPayload
  ) async throws -> FederatedMediaUploadResponse {
    _ = mediaId
    _ = ciphertext
    _ = attestation
    fatalError()
  }

  func downloadCiphertext(mediaId: String, originServer: String, downloadCapability: String) async throws -> Data {
    _ = mediaId
    _ = originServer
    _ = downloadCapability
    fatalError()
  }

  func listMessages(conversationId: String, limit: Int, offset: Int) async throws -> MessageListResponse { fatalError() }
  func sendMessage(conversationId: String, payload: MessageSendPayload) async throws -> MessageResponse { fatalError() }
  func sendFileMessage(
    conversationId: String,
    payload: MessageSendPayload,
    file: MultiPartFile
  ) async throws -> MessageResponse {
    fatalError()
  }
  func markAsRead(messageId: String) async throws -> MessageResponse { fatalError() }
  func markAsDelivered(messageId: String) async throws -> MessageResponse { fatalError() }
  func editMessage(messageId: String, content: String) async throws -> MessageResponse { fatalError() }
  func deleteMessage(messageId: String) async throws -> MessageResponse { fatalError() }
  func deleteMessageForMe(messageId: String) async throws { fatalError() }
  func addReaction(messageId: String, emoji: String) async throws -> ReactionResponse { fatalError() }
  func removeReaction(messageId: String) async throws -> ReactionsResponse { fatalError() }
  func listReactions(messageId: String) async throws -> ReactionsResponse { fatalError() }
  func listEdits(messageId: String) async throws -> MessageEditsResponse { fatalError() }
}

private final class MockKeyMaterialStore: KeyMaterialStore {
  var currentUserId: String?
  private var deviceIds: [String: String] = [:]
  private var deviceIdentities: [String: PersistedDeviceIdentity] = [:]
  private var accountStorageKeys: [String: Data] = [:]

  func setCurrentUserId(_ userId: String?) {
    currentUserId = userId
  }

  func hasPrivateKey(for userId: String) -> Bool {
    _ = userId
    return false
  }

  func savePrivateKeyPEM(_ pem: String, for userId: String) {
    _ = pem
    _ = userId
  }

  func privateKeyPEM(for userId: String) -> String? {
    _ = userId
    return nil
  }

  func saveSeedPhrase(_ seedPhrase: String, for userId: String) {
    _ = seedPhrase
    _ = userId
  }

  func seedPhrase(for userId: String) -> String? {
    _ = userId
    return nil
  }

  func saveDeviceId(_ deviceId: String, for userId: String) {
    deviceIds[userId] = deviceId
  }

  func deviceId(for userId: String) -> String? {
    deviceIds[userId] ?? deviceIdentities[userId]?.deviceId
  }

  func saveDeviceIdentity(_ identity: PersistedDeviceIdentity, for userId: String) {
    deviceIdentities[userId] = identity
    deviceIds[userId] = identity.deviceId
  }

  func deviceIdentity(for userId: String) -> PersistedDeviceIdentity? {
    deviceIdentities[userId]
  }

  func saveAccountStorageKeyData(_ data: Data, for userId: String) {
    accountStorageKeys[userId] = data
  }

  func accountStorageKeyData(for userId: String) -> Data? {
    accountStorageKeys[userId]
  }

  func removePrivateKey(for userId: String) {
    _ = userId
  }

  func removeSeedPhrase(for userId: String) {
    _ = userId
  }

  func removeDeviceId(for userId: String) {
    deviceIds.removeValue(forKey: userId)
  }

  func removeDeviceIdentity(for userId: String) {
    deviceIdentities.removeValue(forKey: userId)
    deviceIds.removeValue(forKey: userId)
  }

  func removeAccountStorageKey(for userId: String) {
    accountStorageKeys.removeValue(forKey: userId)
  }

  func clearAll() {
    currentUserId = nil
    deviceIds.removeAll()
    deviceIdentities.removeAll()
    accountStorageKeys.removeAll()
  }
}
