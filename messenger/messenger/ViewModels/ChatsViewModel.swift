import CryptoKit
import Foundation

@MainActor
// Chat list refresh is kept separate from per-conversation mailbox ingestion.
final class ChatsViewModel {
  enum ChatsViewModelError: LocalizedError {
    case missingCurrentUser
    case missingSeedPhrase
    case contactCodeMismatch
    case invalidUserHandle
    case unableToResolvePeer

    var errorDescription: String? {
      switch self {
      case .missingCurrentUser:
        return "Текущий пользователь не найден"
      case .missingSeedPhrase:
        return "Seed phrase отсутствует на этом устройстве"
      case .contactCodeMismatch:
        return "QR/код не совпадает с ключом на сервере"
      case .invalidUserHandle:
        return "Некорректный user_handle"
      case .unableToResolvePeer:
        return "Не удалось определить собеседника для этого диалога"
      }
    }
  }

  struct ContactShareData {
    let card: QRContactCard
    let qrPayload: String
    let textCode: String
  }

  private enum StorageKeys {
    static let legacyLocalConversations: String = "federated.local.conversations"
    static let localConversationsPrefix: String = "federated.local.conversations.v2"
    static let unscopedLocalConversations: String = "federated.local.conversations.v2"
  }

  private weak var container: AppContainer?
  private let e2eSecurityService: E2ESecurityServiceProtocol
  private let sessionStore: AppSessionStore
  private let messageService: MessageServiceProtocol?
  private let realtimeRouter: RealtimeEventRouter?
  private let defaults: UserDefaults
  private let secureStateStore: SecureStateStoreProtocol?
  private let keyMaterialStore: KeyMaterialStore?
  private let identityService: IdentityServiceProtocol?
  private var eventObserverId: UUID?
  private var remoteNotificationObserver: NSObjectProtocol?

  private(set) var conversations: [Conversation] = []
  private(set) var filteredConversations: [Conversation] = []
  private(set) var searchQuery: String = ""
  var onStateChanged: (() -> Void)?

  var currentUserId: String? {
    resolvedCurrentUserHandle()
  }

  init(
    container: AppContainer? = nil,
    e2eSecurityService: E2ESecurityServiceProtocol,
    sessionStore: AppSessionStore,
    messageService: MessageServiceProtocol? = nil,
    realtimeRouter: RealtimeEventRouter? = nil,
    defaults: UserDefaults = .standard,
    secureStateStore: SecureStateStoreProtocol? = nil,
    keyMaterialStore: KeyMaterialStore? = nil,
    identityService: IdentityServiceProtocol? = nil
  ) {
    self.container = container
    self.e2eSecurityService = e2eSecurityService
    self.sessionStore = sessionStore
    self.messageService = messageService
    self.realtimeRouter = realtimeRouter
    self.defaults = defaults
    self.secureStateStore = secureStateStore
    self.keyMaterialStore = keyMaterialStore
    self.identityService = identityService

    clearLegacyConversationStorage()
    self.conversations = loadLocalConversations()
    self.filteredConversations = conversations
    observeRealtimeEvents()
    observeProcessedRemoteNotifications()
  }

  deinit {
    guard let eventObserverId else {
      if let remoteNotificationObserver {
        NotificationCenter.default.removeObserver(remoteNotificationObserver)
      }
      return
    }

    let realtimeRouter: RealtimeEventRouter? = self.realtimeRouter
    Task { @MainActor in
      realtimeRouter?.removeObserver(eventObserverId)
    }

    if let remoteNotificationObserver {
      NotificationCenter.default.removeObserver(remoteNotificationObserver)
    }
  }

  func loadConversations() async throws {
    do {
      try await discoverIncomingConversations()
    } catch {
      // Preserve locally persisted conversations even when sync pull fails intermittently.
    }

    conversations = loadLocalConversations()
    applySearch(searchQuery)
    notifyStateChanged()
  }

  @discardableResult
  func createDirectConversation(with userId: String) async throws -> Conversation {
    let normalizedPeer: String = userId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard isValidHandle(normalizedPeer) else {
      throw ChatsViewModelError.invalidUserHandle
    }

    guard let currentUser: String = currentUserId else {
      throw ChatsViewModelError.missingCurrentUser
    }

    if let existing: Conversation = conversations.first(where: { conversation in
      conversation.type == .direct && peerUserHandle(for: conversation) == normalizedPeer
    }) {
      return existing
    }

    let conversationId: String = directConversationId(
      localUserHandle: currentUser,
      peerUserHandle: normalizedPeer
    )

    let participants: [ConversationParticipant] = [
      ConversationParticipant(
        id: UUID().uuidString,
        conversationId: conversationId,
        userId: currentUser,
        joinedAt: Date(),
        role: .member
      ),
      ConversationParticipant(
        id: UUID().uuidString,
        conversationId: conversationId,
        userId: normalizedPeer,
        joinedAt: Date(),
        role: .member
      ),
    ]

    let conversation: Conversation = Conversation(
      id: conversationId,
      type: .direct,
      name: normalizedPeer,
      createdAt: Date(),
      updatedAt: Date(),
      participants: participants
    )

    upsert(conversation)
    persistLocalConversations()

    return conversation
  }

  @discardableResult
  func createGroupConversation(name: String, participantIds: [String]) async throws -> Conversation {
    _ = name
    _ = participantIds
    throw APIError.server(statusCode: 400, message: "Groups are not available in release 1")
  }

  func verifyContactCard(_ card: QRContactCard) async throws {
    let expectedFingerprint: String = fingerprint(from: card.ikSignPub)
    let serverFingerprint: PublicKeyFingerprintResponse = try await e2eSecurityService.getPeerFingerprint(
      peerUserId: card.userHandle
    )

    if expectedFingerprint != serverFingerprint.fingerprint {
      _ = try await e2eSecurityService.markMismatch(
        peerUserId: card.userHandle,
        fingerprint: serverFingerprint.fingerprint
      )
      throw ChatsViewModelError.contactCodeMismatch
    }

    _ = try await e2eSecurityService.verifyTrust(
      peerUserId: card.userHandle,
      fingerprint: expectedFingerprint,
      method: .qr
    )
  }

  func myContactShareData() throws -> ContactShareData {
    guard let currentUser: String = currentUserId else {
      throw ChatsViewModelError.missingCurrentUser
    }

    guard let keyMaterialStore, let identityService else {
      throw ChatsViewModelError.missingSeedPhrase
    }

    let lookupIds: [String] = keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: currentUser,
      sessionUser: sessionStore.currentUser
    )
    guard let resolvedSeed = keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds) else {
      throw ChatsViewModelError.missingSeedPhrase
    }

    if resolvedSeed.userId != currentUser {
      keyMaterialStore.saveSeedPhrase(resolvedSeed.seedPhrase, for: currentUser)
      keyMaterialStore.setCurrentUserId(currentUser)
    }

    let identity: IdentityBundle = try identityService.restoreIdentity(
      userHandle: currentUser,
      seedPhrase: resolvedSeed.seedPhrase
    )

    let card = QRContactCard(
      userHandle: currentUser,
      ikSignPub: identity.ikSignPublic,
      ikDhPub: identity.ikDHPublic,
      deviceListDigest: nil,
      inviteToken: nil
    )

    let qrPayload: String = try ContactCodeCodec.encodeJSON(card)
    let textCode: String = try ContactCodeCodec.encodeTextCode(card)
    return ContactShareData(card: card, qrPayload: qrPayload, textCode: textCode)
  }

  func applySearch(_ query: String) {
    searchQuery = query

    let normalized: String = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
      filteredConversations = conversations
      return
    }

    let currentUserId: String? = sessionStore.currentUser?.id
    filteredConversations = conversations.filter { conversation in
      let title: String = title(for: conversation, currentUserId: currentUserId)
      return title.lowercased().contains(normalized) || conversation.id.lowercased().contains(normalized)
    }
  }

  func title(for conversation: Conversation, currentUserId: String? = nil) -> String {
    UserHandleDisplay.title(for: conversation, currentUserId: currentUserId)
  }

  func deleteConversation(id: String) throws {
    guard let index: Int = conversations.firstIndex(where: { $0.id == id }) else {
      throw APIError.server(statusCode: 404, message: "Conversation not found")
    }

    conversations.remove(at: index)
    persistLocalConversations()
    applySearch(searchQuery)
    notifyStateChanged()
  }

  @discardableResult
  func ensureConversations(for blobs: [FederatedMailboxBlob]) async -> [Conversation] {
    guard currentUserId != nil else {
      return conversations
    }

    guard let container else {
      return conversations
    }

    var changed: Bool = false

    for blob in blobs {
      guard let inspected = try? await ConversationViewModel.inspectMailboxBlob(container: container, blob: blob) else {
        continue
      }

      let conversationCountBefore: Int = conversations.count
      _ = ensureConversation(
        for: inspected,
        blobCreatedAt: blob.createdAt,
        persistImmediately: false
      )
      changed = conversations.count != conversationCountBefore || changed
    }

    if changed {
      persistLocalConversations()
      notifyStateChanged()
    }

    return conversations
  }

  @discardableResult
  func ensureConversation(
    for inspected: ConversationViewModel.InspectedMailboxBlob,
    blobCreatedAt: Date,
    persistImmediately: Bool = true
  ) -> Conversation? {
    guard let currentUser: String = currentUserId else {
      return nil
    }

    let sender: String = inspected.header.senderUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedCurrentUser: String = currentUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard isValidHandle(sender),
      sender != normalizedCurrentUser
    else {
      return nil
    }

    let conversationId: String = directConversationId(
      localUserHandle: normalizedCurrentUser,
      peerUserHandle: sender
    )

    if let existing: Conversation = conversation(id: conversationId) {
      return existing
    }

    let conversation = Conversation(
      id: conversationId,
      type: .direct,
      name: sender,
      createdAt: blobCreatedAt,
      updatedAt: blobCreatedAt,
      participants: [
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: conversationId,
          userId: normalizedCurrentUser,
          joinedAt: blobCreatedAt,
          role: .member
        ),
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: conversationId,
          userId: sender,
          joinedAt: blobCreatedAt,
          role: .member
        ),
      ]
    )

    upsert(conversation)
    if persistImmediately {
      persistLocalConversations()
      notifyStateChanged()
    }

    return conversation
  }

  func conversation(id: String) -> Conversation? {
    conversations.first(where: { $0.id == id })
  }

  func peerUserHandle(for conversation: Conversation) -> String? {
    peerUserHandle(for: conversation, currentUserId: currentUserId?.lowercased())
  }

  private func peerUserHandle(for conversation: Conversation, currentUserId: String?) -> String? {
    guard conversation.type == .direct,
      let participants: [ConversationParticipant] = conversation.participants
    else {
      return nil
    }

    return participants
      .map(\.userId)
      .first(where: { participant in
        guard let currentUserId else {
          return true
        }

        return participant.lowercased() != currentUserId
      })
  }

  func blockPeer(in conversation: Conversation) async throws {
    guard let peerUserHandle: String = peerUserHandle(for: conversation),
      isValidHandle(peerUserHandle.lowercased())
    else {
      throw ChatsViewModelError.unableToResolvePeer
    }

    let fingerprint: PublicKeyFingerprintResponse = try await e2eSecurityService.getPeerFingerprint(
      peerUserId: peerUserHandle
    )
    _ = try await e2eSecurityService.markMismatch(
      peerUserId: peerUserHandle,
      fingerprint: fingerprint.fingerprint
    )
  }

  private func upsert(_ conversation: Conversation) {
    if let index: Int = conversations.firstIndex(where: { $0.id == conversation.id }) {
      conversations[index] = conversation
    } else {
      conversations.insert(conversation, at: 0)
    }

    applySearch(searchQuery)
    notifyStateChanged()
  }

  private func persistLocalConversations(_ value: [Conversation]? = nil) {
    let conversationsToPersist: [Conversation] = value ?? conversations
    if let storageKey = resolvedStorageKey(),
      let secureStateStore
    {
      do {
        try secureStateStore.save(conversationsToPersist, for: scopedStorageKey(), storageKey: storageKey)
        defaults.removeObject(forKey: scopedStorageKey())
        return
      } catch {
        // Fallback to legacy storage to avoid dropping local chat index.
      }
    }

    guard let data: Data = try? JSONCoding.encoder.encode(conversationsToPersist) else {
      return
    }

    defaults.set(data, forKey: scopedStorageKey())
  }

  private func loadLocalConversations() -> [Conversation] {
    guard let currentUserId else {
      return []
    }

    let storageKeyName: String = scopedStorageKey(owner: currentUserId)

    let stored: [Conversation]
    if let storageKey = resolvedStorageKey(owner: currentUserId),
      let secureStateStore,
      let secureStored = try? secureStateStore.load([Conversation].self, for: storageKeyName, storageKey: storageKey)
    {
      stored = secureStored
    } else if let data: Data = defaults.data(forKey: storageKeyName),
      let legacyStored: [Conversation] = try? JSONCoding.decoder.decode([Conversation].self, from: data)
    {
      stored = legacyStored
      migrateLegacyConversationsIfNeeded(legacyStored, owner: currentUserId, key: storageKeyName)
    } else {
      return []
    }

    let normalizedCurrent: String = currentUserId.lowercased()
    let filtered: [Conversation] = stored.filter { conversation in
      guard conversation.type == .direct else {
        return true
      }

      guard let participants: [ConversationParticipant] = conversation.participants else {
        return false
      }

      return participants.contains(where: { $0.userId.lowercased() == normalizedCurrent })
    }

    let sanitized: [Conversation] = filtered.filter { conversation in
      !isAutomationPlaceholderConversation(conversation, currentUserId: normalizedCurrent)
    }
    let canonicalized: [Conversation] = canonicalizeDirectConversations(
      sanitized,
      currentUserId: normalizedCurrent
    )

    if canonicalized != stored {
      persistLocalConversations(canonicalized)
    }

    return canonicalized
  }

  private func clearLegacyConversationStorage() {
    defaults.removeObject(forKey: StorageKeys.legacyLocalConversations)
    defaults.removeObject(forKey: StorageKeys.unscopedLocalConversations)
    defaults.removeObject(forKey: scopedStorageKey(owner: "anonymous"))
    secureStateStore?.removeValue(for: scopedStorageKey(owner: "anonymous"))
  }

  private func scopedStorageKey() -> String {
    let owner: String = currentUserId?.lowercased() ?? "anonymous"
    return scopedStorageKey(owner: owner)
  }

  private func scopedStorageKey(owner: String) -> String {
    let digest = SHA256.hash(data: Data(owner.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.localConversationsPrefix).\(suffix)"
  }

  private func fingerprint(from publicKey: String) -> String {
    let digest = SHA256.hash(data: Data(publicKey.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
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

  private func canonicalizeDirectConversations(_ stored: [Conversation], currentUserId: String) -> [Conversation] {
    var mergedById: [String: Conversation] = [:]
    var order: [String] = []

    for conversation in stored {
      let canonical: Conversation = canonicalConversation(conversation, currentUserId: currentUserId)
      if let existing: Conversation = mergedById[canonical.id] {
        mergedById[canonical.id] = mergeConversation(existing, with: canonical)
      } else {
        mergedById[canonical.id] = canonical
        order.append(canonical.id)
      }
    }

    return order.compactMap { mergedById[$0] }
  }

  private func canonicalConversation(_ conversation: Conversation, currentUserId: String) -> Conversation {
    guard conversation.type == .direct,
      let peerHandle: String = peerUserHandle(for: conversation, currentUserId: currentUserId)
    else {
      return conversation
    }

    let canonicalId: String = directConversationId(
      localUserHandle: currentUserId,
      peerUserHandle: peerHandle
    )
    let updatedParticipants: [ConversationParticipant]? = conversation.participants?.map { participant in
      ConversationParticipant(
        id: participant.id,
        conversationId: canonicalId,
        userId: participant.userId,
        joinedAt: participant.joinedAt,
        role: participant.role
      )
    }

    return Conversation(
      id: canonicalId,
      type: .direct,
      name: peerHandle,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      participants: updatedParticipants
    )
  }

  private func mergeConversation(_ lhs: Conversation, with rhs: Conversation) -> Conversation {
    let createdAt: Date? = {
      switch (lhs.createdAt, rhs.createdAt) {
      case let (.some(left), .some(right)):
        return min(left, right)
      case let (.some(left), .none):
        return left
      case let (.none, .some(right)):
        return right
      case (.none, .none):
        return nil
      }
    }()
    let updatedAt: Date? = {
      switch (lhs.updatedAt, rhs.updatedAt) {
      case let (.some(left), .some(right)):
        return max(left, right)
      case let (.some(left), .none):
        return left
      case let (.none, .some(right)):
        return right
      case (.none, .none):
        return nil
      }
    }()

    return Conversation(
      id: lhs.id,
      type: lhs.type,
      name: rhs.name ?? lhs.name,
      createdAt: createdAt,
      updatedAt: updatedAt,
      participants: rhs.participants ?? lhs.participants
    )
  }

  private func isValidHandle(_ value: String) -> Bool {
    value.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil
  }

  private func resolvedCurrentUserHandle() -> String? {
    let sessionUser: SessionUser? = sessionStore.currentUser
    let candidates: [String?] = [
      sessionUser?.id,
      sessionUser?.username,
      sessionUser?.email,
      keyMaterialStore?.currentUserId,
    ]

    for candidate in candidates {
      guard let candidate else {
        continue
      }

      let normalized: String = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if isValidHandle(normalized) {
        return normalized
      }
    }

    return sessionUser?.id.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolvedStorageKey(owner: String? = nil) -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: owner ?? currentUserId,
      sessionUser: sessionStore.currentUser,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )
  }

  private func migrateLegacyConversationsIfNeeded(_ conversations: [Conversation], owner: String, key: String) {
    guard let storageKey = resolvedStorageKey(owner: owner),
      let secureStateStore
    else {
      return
    }

    do {
      try secureStateStore.save(conversations, for: key, storageKey: storageKey)
      defaults.removeObject(forKey: key)
    } catch {
      // Keep plaintext fallback if secure migration fails.
    }
  }

  private func isAutomationPlaceholderConversation(_ conversation: Conversation, currentUserId: String) -> Bool {
    guard conversation.type == .direct,
      let participants: [ConversationParticipant] = conversation.participants
    else {
      return false
    }

    let peerHandles: [String] = participants
      .map(\.userId)
      .map { $0.lowercased() }
      .filter { $0 != currentUserId }

    guard peerHandles.count == 1, let peerHandle: String = peerHandles.first else {
      return false
    }

    return isAutomationPeerHandle(peerHandle)
  }

  private func isAutomationPeerHandle(_ value: String) -> Bool {
    value.range(of: "^@(iosa|iosb)[a-z0-9._-]*:localhost$", options: .regularExpression) != nil
  }

  private func discoverIncomingConversations() async throws {
    guard let messageService,
      let currentUser: String = currentUserId
    else {
      return
    }

    let deviceId: String? = keyMaterialStore?.deviceId(for: currentUser)
    let sync: FederatedSyncResponse = try await messageService.pullSync(deviceId: deviceId, limit: 200)
    guard !sync.blobs.isEmpty else {
      return
    }
    try await ingestIncomingSyncBlobsForGlobalState(sync.blobs, currentUser: currentUser, deviceId: deviceId)
  }

  private func ingestIncomingSyncBlobsForGlobalState(
    _ blobs: [FederatedMailboxBlob],
    currentUser: String,
    deviceId: String?
  ) async throws {
    guard let container else {
      _ = await ensureConversations(for: blobs)
      return
    }

    let normalizedCurrentUser: String = currentUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var viewModelsByConversationId: [String: ConversationViewModel] = [:]

    for blob in blobs {
      guard let inspected = try? await ConversationViewModel.inspectMailboxBlob(container: container, blob: blob) else {
        continue
      }

      let sender: String = inspected.header.senderUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let conversationId: String = sender == normalizedCurrentUser
        ? inspected.header.conversationId
        : directConversationId(localUserHandle: normalizedCurrentUser, peerUserHandle: sender)
      if conversation(id: conversationId) == nil {
        _ = ensureConversation(for: inspected, blobCreatedAt: blob.createdAt)
      }
      guard let conversation: Conversation = conversation(id: conversationId) else {
        continue
      }

      do {
        let conversationViewModel: ConversationViewModel
        if let cachedViewModel: ConversationViewModel = viewModelsByConversationId[conversationId] {
          conversationViewModel = cachedViewModel
        } else {
          let newViewModel = ConversationViewModel(
            container: container,
            conversation: conversation,
            defaults: defaults
          )
          viewModelsByConversationId[conversationId] = newViewModel
          conversationViewModel = newViewModel
        }

        _ = try await conversationViewModel.ingestMailboxBlobs([blob], source: .realtime)
        let incomingMessages: [Message] = conversationViewModel.messages.filter {
          $0.senderId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != normalizedCurrentUser
        }
        container.pushNotificationService.reportIncomingCallOffersIfNeeded(
          from: incomingMessages,
          allMessages: conversationViewModel.messages,
          conversation: conversation,
          currentUserId: normalizedCurrentUser,
          localDeviceId: deviceId
        )
      } catch {
        continue
      }
    }
  }

  private func observeRealtimeEvents() {
    guard let realtimeRouter else {
      return
    }

    eventObserverId = realtimeRouter.observeEvents { [weak self] event in
      guard let self else {
        return
      }

      switch event {
      case .syncBlobAvailable, .syncBlobs:
        Task {
          try? await self.loadConversations()
        }
      default:
        break
      }
    }
  }

  private func observeProcessedRemoteNotifications() {
    remoteNotificationObserver = NotificationCenter.default.addObserver(
      forName: .didProcessRemoteNotificationSync,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        let previousConversations: [Conversation] = self.conversations
        let previousFiltered: [Conversation] = self.filteredConversations
        self.conversations = self.loadLocalConversations()
        self.applySearch(self.searchQuery)
        if self.conversations != previousConversations || self.filteredConversations != previousFiltered {
          self.notifyStateChanged()
        }
      }
    }
  }

  private func notifyStateChanged() {
    onStateChanged?()
  }
}
