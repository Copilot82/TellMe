import CryptoKit
import XCTest
@testable import messenger

final class ChatsViewModelTests: XCTestCase {
  @MainActor
  func testDirectConversationTitleShortensFederatedHandle() {
    let currentUser: String = "@local:messenger.surraund.com"
    let peer: String = "@alice:messenger.surraund.com"
    let conversation: Conversation = makeDirectConversation(id: "dm-title", currentUser: currentUser, peer: peer)
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: UserDefaults.standard)
    let viewModel: ChatsViewModel = ChatsViewModel(
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore
    )

    XCTAssertEqual(UserHandleDisplay.usernameOnly(from: peer), "alice")
    XCTAssertEqual(viewModel.title(for: conversation, currentUserId: currentUser), "alice")
  }

  @MainActor
  func testMyContactShareDataUsesHandleAndFallbackSeedLookup() throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
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

    let viewModel: ChatsViewModel = ChatsViewModel(
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      defaults: defaults,
      keyMaterialStore: keyMaterialStore,
      identityService: MockIdentityService()
    )

    let share: ChatsViewModel.ContactShareData = try viewModel.myContactShareData()

    XCTAssertEqual(share.card.userHandle, "@alice:example.org")
    XCTAssertTrue(share.textCode.hasPrefix(ContactCodeCodec.textPrefix))
    XCTAssertEqual(ContactCodeCodec.decode(share.textCode)?.userHandle, "@alice:example.org")
  }

  @MainActor
  func testInitFiltersOutAutomationPlaceholderConversations() async throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let currentUser: String = "@newuser:example.org"
    let storageKey: String = scopedStorageKey(owner: currentUser)

    let staleAutomationConversation: Conversation = makeDirectConversation(
      id: "c1",
      currentUser: currentUser,
      peer: "@iosa123456:localhost"
    )
    let validConversation: Conversation = makeDirectConversation(
      id: "c2",
      currentUser: currentUser,
      peer: "@bob:example.org"
    )

    let initialConversations: [Conversation] = [staleAutomationConversation, validConversation]
    defaults.set(try JSONCoding.encoder.encode(initialConversations), forKey: storageKey)

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let user = User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: user))

    let viewModel: ChatsViewModel = ChatsViewModel(
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      defaults: defaults
    )
    try await viewModel.loadConversations()

    XCTAssertEqual(viewModel.conversations.count, 1)
    XCTAssertEqual(viewModel.conversations.first?.name, "@bob:example.org")

    let persistedData: Data = try XCTUnwrap(defaults.data(forKey: storageKey))
    let persisted: [Conversation] = try XCTUnwrap(try? JSONCoding.decoder.decode([Conversation].self, from: persistedData))
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(persisted.first?.name, "@bob:example.org")
  }

  @MainActor
  func testLoadConversationsDiscoversIncomingConversationFromSyncEnvelope() async throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let currentUser: String = "@bob:messenger.example.com"
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let sessionUser = User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: sessionUser))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(currentUser)
    keyMaterialStore.saveDeviceId("dev-b", for: currentUser)
    let tokenStore = InMemoryTokenStore()
    let networkClient = MockNetworkClient()
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: networkClient
    )

    let aliceIdentity = try container.identityService.createIdentity(userHandle: "@alice:messenger.example.com")
    let bobIdentity = try container.identityService.createIdentity(userHandle: currentUser)
    keyMaterialStore.saveSeedPhrase(bobIdentity.seedPhrase, for: currentUser)
    let storageKey = try container.identityService.deriveStorageKey(seedPhrase: bobIdentity.seedPhrase)
    container.ratchetSessionStore.configure(storageKey: storageKey)

    let senderState = try container.x3dhService.bootstrapSession(
      seedPhrase: aliceIdentity.seedPhrase,
      localUserHandle: "@alice:messenger.example.com",
      localDeviceId: "dev-a",
      peerUserHandle: currentUser,
      peerDeviceId: "dev-b",
      peerIkDhPublic: bobIdentity.ikDHPublic,
      sessionId: "session-ab",
      conversationId: "conv-ab"
    )
    let receiverState = try container.x3dhService.bootstrapSession(
      seedPhrase: bobIdentity.seedPhrase,
      localUserHandle: currentUser,
      localDeviceId: "dev-b",
      peerUserHandle: "@alice:messenger.example.com",
      peerDeviceId: "dev-a",
      peerIkDhPublic: aliceIdentity.ikDHPublic,
      sessionId: "session-ab",
      conversationId: "conv-ab"
    )
    try container.ratchetSessionStore.upsert(receiverState)

    let payload = E2EMessagePayload(
      conversationId: "conv-ab",
      msgType: "text",
      body: "hello",
      attachments: [],
      padding: "00000000"
    )
    let sealed = try container.envelopeService.seal(payload: payload, state: senderState)

    let blob = FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-b",
      ownerDeviceId: "dev-b",
      senderServer: "messenger.example.com",
      messageId: "55555555-5555-4555-8555-555555555555",
      deliveryId: "66666666-6666-4666-8666-666666666666",
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
    let messageService = MessageServiceStub(
      syncResponse: FederatedSyncResponse(deviceId: "dev-b", blobs: [blob])
    )

    let viewModel: ChatsViewModel = ChatsViewModel(
      container: container,
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      messageService: messageService,
      defaults: defaults,
      keyMaterialStore: keyMaterialStore
    )

    try await viewModel.loadConversations()

    XCTAssertEqual(viewModel.conversations.count, 1)
    XCTAssertEqual(
      viewModel.conversations.first?.id,
      directConversationId(localUserHandle: currentUser, peerUserHandle: "@alice:messenger.example.com")
    )
    XCTAssertEqual(viewModel.conversations.first?.name, "@alice:messenger.example.com")
  }

  @MainActor
  func testLoadConversationsReportsIncomingCallOfferFromGlobalSyncWithoutOpeningConversation() async throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let currentUser: String = "@bob:messenger.example.com"
    let peerUser: String = "@alice:messenger.example.com"
    let localDeviceId: String = "dev-b"
    let peerDeviceId: String = "dev-a"
    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let sessionUser = User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: sessionUser))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(currentUser)
    keyMaterialStore.saveDeviceId(localDeviceId, for: currentUser)
    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: InMemoryTokenStore(),
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: MockNetworkClient()
    )

    let aliceIdentity = try container.identityService.createIdentity(userHandle: peerUser)
    let bobIdentity = try container.identityService.createIdentity(userHandle: currentUser)
    keyMaterialStore.saveSeedPhrase(bobIdentity.seedPhrase, for: currentUser)
    let storageKey = try container.identityService.deriveStorageKey(seedPhrase: bobIdentity.seedPhrase)
    container.ratchetSessionStore.configure(storageKey: storageKey)

    let senderState = try container.x3dhService.bootstrapSession(
      seedPhrase: aliceIdentity.seedPhrase,
      localUserHandle: peerUser,
      localDeviceId: peerDeviceId,
      peerUserHandle: currentUser,
      peerDeviceId: localDeviceId,
      peerIkDhPublic: bobIdentity.ikDHPublic,
      sessionId: "session-call-ab",
      conversationId: "conv-call-ab"
    )
    let receiverState = try container.x3dhService.bootstrapSession(
      seedPhrase: bobIdentity.seedPhrase,
      localUserHandle: currentUser,
      localDeviceId: localDeviceId,
      peerUserHandle: peerUser,
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: aliceIdentity.ikDHPublic,
      sessionId: "session-call-ab",
      conversationId: "conv-call-ab"
    )
    try container.ratchetSessionStore.upsert(receiverState)

    let textPayload = E2EMessagePayload(
      conversationId: "conv-call-ab",
      msgType: Message.MessageType.text.rawValue,
      body: "hello before call",
      attachments: [],
      padding: "00000000"
    )
    let sealedText = try container.envelopeService.seal(payload: textPayload, state: senderState)
    let textBlob = FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-b",
      ownerDeviceId: localDeviceId,
      senderServer: "messenger.example.com",
      messageId: "77777777-7777-4777-8777-777777777777",
      deliveryId: "88888888-8888-4888-8888-888888888888",
      ciphertextBlob: sealedText.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )

    let callId: String = "call-global-sync-offer-1"
    let callPayload: [String: Any] = makeCallOfferPayload(
      callId: callId,
      senderDeviceId: peerDeviceId,
      targetDeviceId: localDeviceId,
      fromUser: peerUser
    )
    let callPayloadData: Data = try JSONSerialization.data(withJSONObject: callPayload, options: [])
    let callBody: String = try XCTUnwrap(String(data: callPayloadData, encoding: .utf8))
    let payload = E2EMessagePayload(
      conversationId: "conv-call-ab",
      msgType: Message.MessageType.callOffer.rawValue,
      body: callBody,
      attachments: [],
      padding: "00000000"
    )
    let sealed = try container.envelopeService.seal(payload: payload, state: sealedText.nextState)
    let blob = FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-b",
      ownerDeviceId: localDeviceId,
      senderServer: "messenger.example.com",
      messageId: "99999999-9999-4999-8999-999999999999",
      deliveryId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
    let messageService = MessageServiceStub(
      syncResponse: FederatedSyncResponse(deviceId: localDeviceId, blobs: [textBlob, blob])
    )
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }

    let viewModel: ChatsViewModel = ChatsViewModel(
      container: container,
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      messageService: messageService,
      defaults: defaults,
      keyMaterialStore: keyMaterialStore
    )

    try await viewModel.loadConversations()

    let conversation = try XCTUnwrap(viewModel.conversations.first)
    let conversationViewModel = ConversationViewModel(
      container: container,
      conversation: conversation,
      defaults: defaults
    )
    let snapshot = coordinator.testingSnapshot()
    let reportedUUID = try XCTUnwrap(snapshot.uuidByCallId[callId])

    XCTAssertEqual(conversation.name, peerUser)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID[reportedUUID], callId)
    XCTAssertTrue(conversationViewModel.messages.contains { $0.type == .callOffer && $0.id == blob.messageId })
  }

  @MainActor
  func testLoadConversationsKeepsLocalDataWhenSyncFails() async throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let currentUser: String = "@bob:messenger.example.com"
    let storageKey: String = scopedStorageKey(owner: currentUser)

    let cachedConversation: Conversation = makeDirectConversation(
      id: "cached-conversation",
      currentUser: currentUser,
      peer: "@alice:messenger.example.com"
    )
    defaults.set(try JSONCoding.encoder.encode([cachedConversation]), forKey: storageKey)

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let sessionUser = User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: sessionUser))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.saveDeviceId("dev-b", for: currentUser)

    let messageService = MessageServiceStub(
      syncResponse: FederatedSyncResponse(deviceId: "dev-b", blobs: []),
      pullSyncError: APIError.transport("timeout")
    )

    let viewModel: ChatsViewModel = ChatsViewModel(
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      messageService: messageService,
      defaults: defaults,
      keyMaterialStore: keyMaterialStore
    )

    try await viewModel.loadConversations()

    XCTAssertEqual(viewModel.conversations.count, 1)
    XCTAssertEqual(
      viewModel.conversations.first?.id,
      directConversationId(localUserHandle: currentUser, peerUserHandle: "@alice:messenger.example.com")
    )
    XCTAssertEqual(viewModel.conversations.first?.name, "@alice:messenger.example.com")
  }

  @MainActor
  func testLoadConversationsCanonicalizesAndDeduplicatesStoredDirectChats() async throws {
    let suiteName: String = "ChatsViewModelTests.\(UUID().uuidString)"
    guard let defaults: UserDefaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Failed to create isolated UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let currentUser: String = "@alice:example.org"
    let peerUser: String = "@bob:example.org"
    let storageKey: String = scopedStorageKey(owner: currentUser)
    let staleConversation = makeDirectConversation(
      id: "legacy-direct-1",
      currentUser: currentUser,
      peer: peerUser
    )
    let duplicateConversation = makeDirectConversation(
      id: "legacy-direct-2",
      currentUser: currentUser,
      peer: peerUser
    )
    defaults.set(try JSONCoding.encoder.encode([staleConversation, duplicateConversation]), forKey: storageKey)

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let sessionUser = User(
      id: currentUser,
      username: currentUser,
      email: currentUser,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: sessionUser))

    let viewModel: ChatsViewModel = ChatsViewModel(
      e2eSecurityService: MockE2ESecurityService(),
      sessionStore: sessionStore,
      defaults: defaults
    )

    try await viewModel.loadConversations()

    XCTAssertEqual(viewModel.conversations.count, 1)
    XCTAssertEqual(
      viewModel.conversations.first?.id,
      directConversationId(localUserHandle: currentUser, peerUserHandle: peerUser)
    )
    XCTAssertEqual(viewModel.conversations.first?.name, peerUser)
  }

  private func makeDirectConversation(id: String, currentUser: String, peer: String) -> Conversation {
    Conversation(
      id: id,
      type: .direct,
      name: peer,
      createdAt: Date(),
      updatedAt: Date(),
      participants: [
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: id,
          userId: currentUser,
          joinedAt: Date(),
          role: .member
        ),
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: id,
          userId: peer,
          joinedAt: Date(),
          role: .member
        ),
      ]
    )
  }

  private func scopedStorageKey(owner: String) -> String {
    let digest = SHA256.hash(data: Data(owner.lowercased().utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "federated.local.conversations.v2.\(suffix)"
  }

  private func directConversationId(localUserHandle: String, peerUserHandle: String) -> String {
    let participants: [String] = [
      localUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      peerUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].sorted()
    let digest = SHA256.hash(data: Data("direct|\(participants.joined(separator: "|"))".utf8))
    let hex: String = digest.map { String(format: "%02x", $0) }.joined()
    return "dm-\(String(hex.prefix(32)))"
  }

  private func makeCallOfferPayload(
    callId: String,
    senderDeviceId: String,
    targetDeviceId: String,
    fromUser: String
  ) -> [String: Any] {
    CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": "initial",
        "from_user": fromUser,
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
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
}

private final class MockIdentityService: IdentityServiceProtocol {
  func createIdentity(userHandle: String) throws -> IdentityBundle {
    IdentityBundle(
      userHandle: userHandle,
      ikSignPublic: "ik_sign_public",
      ikDHPublic: "ik_dh_public",
      seedPhrase: "seed"
    )
  }

  func restoreIdentity(userHandle: String, seedPhrase: String) throws -> IdentityBundle {
    IdentityBundle(
      userHandle: userHandle,
      ikSignPublic: "ik_sign_public",
      ikDHPublic: "ik_dh_public",
      seedPhrase: seedPhrase
    )
  }

  func signRegistrationProof(
    seedPhrase: String,
    userHandle: String,
    ikSignPublic: String,
    ikDHPublic: String,
    timestampISO8601: String
  ) throws -> String {
    "signature"
  }

  func signChallenge(seedPhrase: String, nonce: String) throws -> String {
    "signature"
  }

  func signMessage(seedPhrase: String, message: String) throws -> String {
    _ = seedPhrase
    _ = message
    return "signature"
  }

  func deriveStorageKey(seedPhrase: String) throws -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }
}

private final class MockE2ESecurityService: E2ESecurityServiceProtocol {
  func listTrustRecords() async throws -> E2ETrustRecordsResponse {
    E2ETrustRecordsResponse(trustRecords: [])
  }

  func getTrustStatus(peerUserId: String) async throws -> E2ETrustStatusResponse {
    E2ETrustStatusResponse(
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: "fp",
      consent: nil,
      mutualConsent: false,
      trustRecord: nil,
      effectiveState: .unverified,
      mode: .unprotected
    )
  }

  func verifyTrust(
    peerUserId: String,
    fingerprint: String,
    method: TrustVerificationMethod
  ) async throws -> E2EVerifyTrustResponse {
    let record = TrustedPeerKeyRecord(
      id: "id",
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: fingerprint,
      verifiedMethod: method,
      state: .verified,
      peerPublicKeyHash: fingerprint,
      verifiedAt: Date(),
      createdAt: Date(),
      updatedAt: Date()
    )
    return E2EVerifyTrustResponse(trustRecord: record, fingerprintMatchesServer: true, mode: .protected)
  }

  func markMismatch(peerUserId: String, fingerprint: String) async throws -> E2EVerifyTrustResponse {
    let record = TrustedPeerKeyRecord(
      id: "id",
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: fingerprint,
      verifiedMethod: .manual,
      state: .mismatch,
      peerPublicKeyHash: fingerprint,
      verifiedAt: Date(),
      createdAt: Date(),
      updatedAt: Date()
    )
    return E2EVerifyTrustResponse(trustRecord: record, fingerprintMatchesServer: false, mode: .blocked)
  }

  func setConsent(peerUserId: String, enabled: Bool, source: String?) async throws -> E2EConsentResponse {
    let consent = KeyExchangeConsent(
      id: "id",
      ownerUserId: "local",
      peerUserId: peerUserId,
      consentGiven: enabled,
      consentSource: source ?? "local",
      createdAt: Date(),
      updatedAt: Date()
    )
    return E2EConsentResponse(consent: consent, mutualConsent: enabled)
  }

  func getConsent(peerUserId: String) async throws -> E2EConsentResponse {
    E2EConsentResponse(consent: nil, mutualConsent: false)
  }

  func getPeerFingerprint(peerUserId: String) async throws -> PublicKeyFingerprintResponse {
    PublicKeyFingerprintResponse(userId: peerUserId, fingerprint: "fp")
  }
}
