import Foundation
import UIKit
import UserNotifications
import CryptoKit

@MainActor
protocol PushNotificationServiceProtocol {
  func registerDeviceToken(_ token: Data) async throws -> DeviceTokenResponse
  nonisolated func tokenHexString(from tokenData: Data) -> String
  func currentAPNSToken() -> Data?
  func currentVoIPToken() -> Data?
  func diagnosticsSummary() -> String
  func visibleConversationPeerUserId() -> String?
  func setVisibleConversationPeerUserId(_ peerUserId: String?)
  func resetRegistrationState()
  func unregisterCurrentDeviceTokenIfNeeded() async
  func shouldPresentForegroundNotification(_ userInfo: [AnyHashable: Any]) -> Bool
  func handleAPNSToken(_ token: Data) async
  func handleVoIPToken(_ token: Data) async
  func handleVoIPTokenInvalidation() async
  func syncDeviceTokenIfNeeded() async
  func warmAuthenticatedPushRegistration(timeout: TimeInterval) async
  func synchronizeIncomingMailbox(reason: String) async -> Bool
  func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool
}

@MainActor
// Push wakeups trigger encrypted mailbox sync instead of carrying plaintext message content.
final class PushNotificationService: PushNotificationServiceProtocol {
  private enum StorageKeys {
    static let latestAPNSToken: String = "push.latest_apns_token"
    static let latestVoIPToken: String = "push.latest_voip_token"
    static let lastRegisteredSignature: String = "push.last_registered_signature"
    static let lastRegisteredVoIPSignature: String = "push.last_registered_voip_signature"

    static func latestToken(for kind: PushTokenKind) -> String {
      kind == .voip ? latestVoIPToken : latestAPNSToken
    }

    static func lastRegisteredSignature(for kind: PushTokenKind) -> String {
      kind == .voip ? lastRegisteredVoIPSignature : lastRegisteredSignature
    }
  }

  static var shared: PushNotificationService?

  private let callService: CallServiceProtocol
  private let messageService: MessageServiceProtocol
  private let sessionStore: AppSessionStore
  private let keyMaterialStore: KeyMaterialStore
  private let defaults: UserDefaults
  private let identityService: IdentityServiceProtocol?
  private let secureStateStore: SecureStateStoreProtocol?
  private let notificationCenter: NotificationCenter
  private let pushEnvironmentProvider: () -> PushEnvironment
  private weak var container: AppContainer?
  private var visibleConversationPeerUserIdValue: String?
  private var reportedIncomingCallIds: Set<String> = []
  private var lastRegistrationErrorsByKind: [String: String] = [:]
  private var lastTokenListError: String?
  private var isSyncingDeviceTokens: Bool = false
  private var shouldResyncDeviceTokensAfterCurrentSync: Bool = false

  init(
    callService: CallServiceProtocol,
    messageService: MessageServiceProtocol,
    sessionStore: AppSessionStore,
    keyMaterialStore: KeyMaterialStore,
    defaults: UserDefaults = .standard,
    identityService: IdentityServiceProtocol? = nil,
    secureStateStore: SecureStateStoreProtocol? = nil,
    notificationCenter: NotificationCenter = .default,
    pushEnvironmentProvider: @escaping () -> PushEnvironment = PushNotificationService.defaultPushEnvironment
  ) {
    self.callService = callService
    self.messageService = messageService
    self.sessionStore = sessionStore
    self.keyMaterialStore = keyMaterialStore
    self.defaults = defaults
    self.identityService = identityService
    self.secureStateStore = secureStateStore
    self.notificationCenter = notificationCenter
    self.pushEnvironmentProvider = pushEnvironmentProvider
    PushNotificationService.shared = self
  }

  nonisolated func tokenHexString(from tokenData: Data) -> String {
    tokenData.map { String(format: "%02.2hhx", $0) }.joined()
  }

  func currentAPNSToken() -> Data? {
    latestStoredToken(kind: .alert)
  }

  func currentVoIPToken() -> Data? {
    latestStoredToken(kind: .voip)
  }

  func diagnosticsSummary() -> String {
    let alertState: String = diagnosticsState(kind: .alert)
    let voipState: String = diagnosticsState(kind: .voip)
    var parts: [String] = [
      "alert=\(alertState)",
      "voip=\(voipState)",
    ]

    let errors: [String] = [
      lastRegistrationErrorsByKind[PushTokenKind.alert.rawValue].map { "alert:\($0)" },
      lastRegistrationErrorsByKind[PushTokenKind.voip.rawValue].map { "voip:\($0)" },
      lastTokenListError.map { "list:\($0)" },
    ].compactMap { $0 }
    if !errors.isEmpty {
      parts.append("error=\(errors.joined(separator: ";"))")
    }

    return parts.joined(separator: ",")
  }

  func visibleConversationPeerUserId() -> String? {
    visibleConversationPeerUserIdValue
  }

  func setVisibleConversationPeerUserId(_ peerUserId: String?) {
    visibleConversationPeerUserIdValue = normalizedUserHandle(from: peerUserId)
  }

  func resetRegistrationState() {
    for kind in [PushTokenKind.alert, .voip] {
      clearRegistrationSignature(kind: kind)
    }
    lastRegistrationErrorsByKind.removeAll()
    lastTokenListError = nil
    visibleConversationPeerUserIdValue = nil
    reportedIncomingCallIds.removeAll()
  }

  func unregisterCurrentDeviceTokenIfNeeded() async {
    guard let currentUserId: String = sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines),
      !currentUserId.isEmpty
    else {
      resetRegistrationState()
      return
    }
    _ = currentUserId

    for kind in [PushTokenKind.alert, .voip] {
      guard let token: Data = latestStoredToken(kind: kind) else {
        continue
      }

      do {
        try await callService.deleteDeviceToken(token: tokenHexString(from: token))
      } catch {
        // Best-effort only. A subsequent authenticated registration will reassign the token.
      }
    }

    resetRegistrationState()
  }

  func shouldPresentForegroundNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    _ = userInfo
    return false
  }

  func registerDeviceToken(_ token: Data) async throws -> DeviceTokenResponse {
    try await registerDeviceToken(token, kind: .alert)
  }

  func registerDeviceToken(_ token: Data, kind: PushTokenKind) async throws -> DeviceTokenResponse {
    let pushEnvironment: PushEnvironment = currentPushEnvironment()
    let payload = DeviceTokenRegistrationPayload(
      deviceType: .ios,
      token: tokenHexString(from: token),
      deviceName: UIDevice.current.name,
      osVersion: UIDevice.current.systemVersion,
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      pushEnabled: true,
      pushEnvironment: pushEnvironment,
      pushMode: .privacyFirst,
      tokenKind: kind
    )

    return try await callService.registerDeviceToken(payload)
  }

  func attach(container: AppContainer) {
    self.container = container
  }

  func handleAPNSToken(_ token: Data) async {
    persistLatestToken(token, kind: .alert)
    await syncDeviceTokenIfNeeded()
  }

  func handleVoIPToken(_ token: Data) async {
    persistLatestToken(token, kind: .voip)
    await syncDeviceTokenIfNeeded()
  }

  func handleVoIPTokenInvalidation() async {
    await unregisterStoredToken(kind: .voip, removeLatestToken: true)
  }

  func syncDeviceTokenIfNeeded() async {
    if isSyncingDeviceTokens {
      shouldResyncDeviceTokensAfterCurrentSync = true
      return
    }

    isSyncingDeviceTokens = true
    defer {
      isSyncingDeviceTokens = false
    }

    repeat {
      shouldResyncDeviceTokensAfterCurrentSync = false
      await syncDeviceTokensOnceIfPossible()
    } while shouldResyncDeviceTokensAfterCurrentSync
  }

  func warmAuthenticatedPushRegistration(timeout: TimeInterval = 8) async {
    let deadline: Date = Date().addingTimeInterval(max(0, timeout))
    var nextForcedPushKitRefresh: Date = .distantPast

    while !Task.isCancelled {
      if currentVoIPToken() == nil, Date() >= nextForcedPushKitRefresh {
        container?.systemCallCoordinator.forceRefreshPushKitRegistrationIfVoIPTokenMissing()
        nextForcedPushKitRefresh = Date().addingTimeInterval(2)
      }

      await syncDeviceTokenIfNeeded()

      if currentVoIPToken() != nil {
        return
      }

      guard Date() < deadline else {
        return
      }

      try? await Task.sleep(nanoseconds: 500_000_000)
    }
  }

  private func syncDeviceTokensOnceIfPossible() async {
    guard let currentUserId: String = sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines),
      !currentUserId.isEmpty
    else {
      return
    }

    let tokenRegistrations: [(kind: PushTokenKind, token: Data)] = [PushTokenKind.alert, .voip].compactMap { kind in
      guard let token: Data = latestStoredToken(kind: kind) else {
        return nil
      }
      return (kind, token)
    }

    guard !tokenRegistrations.isEmpty else {
      return
    }

    let serverTokens: [DeviceToken]? = await fetchRegisteredDeviceTokensForReconciliation()

    for tokenRegistration in tokenRegistrations {
      let kind: PushTokenKind = tokenRegistration.kind
      let token: Data = tokenRegistration.token
      let tokenHex: String = tokenHexString(from: token)
      let signature: String = registrationSignature(userId: currentUserId, token: token, kind: kind)
      let signatureMatches: Bool = storedRegistrationSignature(kind: kind) == signature

      if let serverTokens,
        serverTokens.contains(where: {
          serverDeviceTokenMatches($0, tokenHex: tokenHex, kind: kind, environment: currentPushEnvironment())
        })
      {
        persistRegistrationSignature(signature, kind: kind)
        clearRegistrationError(kind: kind)
        continue
      }

      if serverTokens == nil, signatureMatches {
        continue
      }

      do {
        _ = try await registerDeviceToken(token, kind: kind)
        persistRegistrationSignature(signature, kind: kind)
        clearRegistrationError(kind: kind)
      } catch {
        clearRegistrationSignature(kind: kind)
        lastRegistrationErrorsByKind[kind.rawValue] = diagnosticDescription(for: error)
      }
    }
  }

  func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
    if handleSyntheticRemoteNotificationIfNeeded(userInfo) {
      return true
    }

    return await synchronizeIncomingMailbox(reason: "remote_notification", userInfo: userInfo)
  }

  func synchronizeIncomingMailbox(reason: String) async -> Bool {
    await synchronizeIncomingMailbox(reason: reason, userInfo: ["sync_reason": reason])
  }

  private func synchronizeIncomingMailbox(reason: String, userInfo: [AnyHashable: Any]) async -> Bool {
    guard let container,
      let currentUserId: String = sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !currentUserId.isEmpty,
      let deviceId: String = keyMaterialStore.deviceId(for: currentUserId)
    else {
      return false
    }

    do {
      let pageLimit: Int = 200
      let chatsViewModel = ChatsViewModel(
        container: container,
        e2eSecurityService: container.e2eSecurityService,
        sessionStore: sessionStore,
        messageService: messageService,
        realtimeRouter: nil,
        defaults: defaults,
        secureStateStore: container.secureStateStore,
        keyMaterialStore: keyMaterialStore,
        identityService: container.identityService
      )

      var processedAny: Bool = false
      var notificationCandidates: [(message: Message, conversation: Conversation)] = []
      while true {
        let sync: FederatedSyncResponse = try await messageService.pullSync(deviceId: deviceId, limit: pageLimit)
        guard !sync.blobs.isEmpty else {
          break
        }

        var iterationProcessed: Bool = false
        var terminalAckIds: [String] = []
        var viewModelsByConversationId: [String: ConversationViewModel] = [:]

        for blob in sync.blobs {
          do {
            guard let inspected = try await ConversationViewModel.inspectMailboxBlob(container: container, blob: blob) else {
              continue
            }

            let conversationId: String
            if inspected.header.senderUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == currentUserId {
              conversationId = inspected.header.conversationId
            } else {
              conversationId = directConversationId(
                localUserHandle: currentUserId,
                peerUserHandle: inspected.header.senderUserHandle
              )
            }

            let conversation: Conversation?
            if let existingConversation: Conversation = chatsViewModel.conversation(id: conversationId) {
              conversation = existingConversation
            } else {
              conversation = chatsViewModel.ensureConversation(
                for: inspected,
                blobCreatedAt: blob.createdAt
              )
            }
            guard let conversation else {
              continue
            }

            let viewModel: ConversationViewModel
            if let cachedViewModel: ConversationViewModel = viewModelsByConversationId[conversationId] {
              viewModel = cachedViewModel
            } else {
              let newViewModel = ConversationViewModel(
                container: container,
                conversation: conversation,
                defaults: defaults
              )
              viewModelsByConversationId[conversationId] = newViewModel
              viewModel = newViewModel
            }

            let existingMessageIds: Set<String> = Set(viewModel.messages.map(\.id))
            let processedIds: [String] = try await viewModel.ingestMailboxBlobs(
              [blob],
              source: .backgroundPush
            )
            let newMessages: [Message] = viewModel.messages.filter { message in
              !existingMessageIds.contains(message.id)
                && message.senderId.lowercased() != currentUserId
            }
            reportIncomingCallOffersIfNeeded(
              from: newMessages,
              allMessages: viewModel.messages,
              conversation: conversation,
              currentUserId: currentUserId,
              localDeviceId: deviceId,
              reportedCallIds: &reportedIncomingCallIds
            )

            if let latestMessage: Message = newMessages
              .filter({ !$0.type.isCallSignaling })
              .sorted(by: { $0.createdAt > $1.createdAt })
              .first
            {
              notificationCandidates.append((latestMessage, conversation))
            }
            processedAny = processedAny || !processedIds.isEmpty
            iterationProcessed = iterationProcessed || !processedIds.isEmpty || !newMessages.isEmpty
          } catch {
            if ConversationViewModel.isTerminalEnvelopeError(error) {
              terminalAckIds.append(blob.messageId)
              iterationProcessed = true
            }
            continue
          }
        }

        if !terminalAckIds.isEmpty {
          _ = try? await messageService.ackMessages(Array(Set(terminalAckIds)))
          processedAny = true
        }

        if sync.blobs.count < pageLimit || !iterationProcessed {
          break
        }
      }

      await scheduleLocalNotificationsIfNeeded(notificationCandidates)

      if processedAny {
        var notificationUserInfo: [AnyHashable: Any] = userInfo
        notificationUserInfo["sync_reason"] = reason
        notificationCenter.post(name: .didProcessRemoteNotificationSync, object: nil, userInfo: notificationUserInfo)
      }

      return processedAny
    } catch {
      return false
    }
  }

  private func reportIncomingCallsIfNeeded(_ descriptors: [E2EIncomingCallDescriptor]) {
    reportIncomingCallsIfNeeded(descriptors, reportedCallIds: &reportedIncomingCallIds)
  }

  func reportIncomingCallOffersIfNeeded(
    from candidateMessages: [Message],
    allMessages: [Message],
    conversation: Conversation,
    currentUserId: String,
    localDeviceId: String? = nil
  ) {
    reportIncomingCallOffersIfNeeded(
      from: candidateMessages,
      allMessages: allMessages,
      conversation: conversation,
      currentUserId: currentUserId,
      localDeviceId: localDeviceId,
      reportedCallIds: &reportedIncomingCallIds
    )
  }

  private func reportIncomingCallOffersIfNeeded(
    from candidateMessages: [Message],
    allMessages: [Message],
    conversation: Conversation,
    currentUserId: String,
    localDeviceId: String? = nil,
    reportedCallIds: inout Set<String>
  ) {
    let descriptors: [E2EIncomingCallDescriptor] = incomingCallDescriptors(
      from: candidateMessages,
      allMessages: allMessages,
      conversation: conversation,
      currentUserId: currentUserId,
      localDeviceId: localDeviceId
    )
    reportIncomingCallsIfNeeded(descriptors, reportedCallIds: &reportedCallIds)
  }

  private func reportIncomingCallsIfNeeded(
    _ descriptors: [E2EIncomingCallDescriptor],
    reportedCallIds: inout Set<String>
  ) {
    for descriptor in descriptors {
      let callId: String = descriptor.callId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !callId.isEmpty,
        reportedCallIds.insert(callId).inserted
      else {
        continue
      }

      SystemCallCoordinator.shared.reportIncomingCall(descriptor)
      notificationCenter.post(
        name: .didReceiveEncryptedCallOffer,
        object: nil,
        userInfo: ["descriptor": descriptor]
      )
    }
  }

  private func incomingCallDescriptors(
    from candidateMessages: [Message],
    allMessages: [Message],
    conversation: Conversation,
    currentUserId: String,
    localDeviceId: String? = nil
  ) -> [E2EIncomingCallDescriptor] {
    let latestCallEndAtByCallId: [String: Date] = latestCallEndTimestampsByCallId(from: allMessages)

    return candidateMessages.compactMap { message in
      guard message.type == .callOffer,
        let callId: String = normalizedCallId(from: message)
      else {
        return nil
      }

      if let endedAt: Date = latestCallEndAtByCallId[callId],
        endedAt >= message.createdAt
      {
        return nil
      }

      return CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: conversation,
        currentUserId: currentUserId,
        localDeviceId: localDeviceId
      )
    }
  }

  private func latestCallEndTimestampsByCallId(from messages: [Message]) -> [String: Date] {
    var latestByCallId: [String: Date] = [:]
    for message in messages where message.type == .callEnd {
      guard let callId: String = normalizedCallId(from: message) else {
        continue
      }

      if let current: Date = latestByCallId[callId],
        current >= message.createdAt
      {
        continue
      }

      latestByCallId[callId] = message.createdAt
    }
    return latestByCallId
  }

  private func normalizedCallId(from message: Message) -> String? {
    guard let callId: String = CallSignalParser.callId(from: message)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !callId.isEmpty
    else {
      return nil
    }

    return callId
  }

  private func latestStoredToken(kind: PushTokenKind) -> Data? {
    let key: String = StorageKeys.latestToken(for: kind)
    if let storageKey = resolvedStorageKey(),
      let secureStateStore,
      let encoded = try? secureStateStore.load(String.self, for: key, storageKey: storageKey)
    {
      return Data(base64Encoded: encoded)
    }

    guard let encoded: String = defaults.string(forKey: key) else {
      return nil
    }

    let token: Data? = Data(base64Encoded: encoded)
    if token != nil {
      migrateLegacyValueIfNeeded(encoded, for: key)
    }
    return token
  }

  private func persistLatestToken(_ token: Data, kind: PushTokenKind) {
    let encoded: String = token.base64EncodedString()
    let key: String = StorageKeys.latestToken(for: kind)
    if persistSecureValue(encoded, for: key) {
      defaults.removeObject(forKey: key)
      return
    }

    defaults.set(encoded, forKey: key)
  }

  private func clearLatestToken(kind: PushTokenKind) {
    let key: String = StorageKeys.latestToken(for: kind)
    secureStateStore?.removeValue(for: key)
    defaults.removeObject(forKey: key)
  }

  private func storedRegistrationSignature(kind: PushTokenKind) -> String? {
    let key: String = StorageKeys.lastRegisteredSignature(for: kind)
    if let storageKey = resolvedStorageKey(),
      let secureStateStore,
      let signature = try? secureStateStore.load(String.self, for: key, storageKey: storageKey)
    {
      return signature
    }

    let signature: String? = defaults.string(forKey: key)
    if let signature {
      migrateLegacyValueIfNeeded(signature, for: key)
    }
    return signature
  }

  private func persistRegistrationSignature(_ signature: String, kind: PushTokenKind) {
    let key: String = StorageKeys.lastRegisteredSignature(for: kind)
    if persistSecureValue(signature, for: key) {
      defaults.removeObject(forKey: key)
      return
    }

    defaults.set(signature, forKey: key)
  }

  private func clearRegistrationSignature(kind: PushTokenKind) {
    let key: String = StorageKeys.lastRegisteredSignature(for: kind)
    secureStateStore?.removeValue(for: key)
    defaults.removeObject(forKey: key)
  }

  private func unregisterStoredToken(kind: PushTokenKind, removeLatestToken: Bool) async {
    let token: Data? = latestStoredToken(kind: kind)
    if let token,
      sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    {
      do {
        try await callService.deleteDeviceToken(token: tokenHexString(from: token))
      } catch {
        // Best-effort only. The local invalidation still prevents re-registering a stale VoIP token.
      }
    }

    if removeLatestToken {
      clearLatestToken(kind: kind)
    }
    clearRegistrationSignature(kind: kind)
  }

  private func persistSecureValue<T: Codable>(_ value: T, for key: String) -> Bool {
    guard let storageKey = resolvedStorageKey(),
      let secureStateStore
    else {
      return false
    }

    do {
      try secureStateStore.save(value, for: key, storageKey: storageKey)
      return true
    } catch {
      return false
    }
  }

  private func migrateLegacyValueIfNeeded<T: Codable>(_ value: T, for key: String) {
    guard persistSecureValue(value, for: key) else {
      return
    }

    defaults.removeObject(forKey: key)
  }

  private func resolvedStorageKey() -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: sessionStore.currentUser?.id,
      sessionUser: sessionStore.currentUser,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )
  }

  private func registrationSignature(userId: String, token: Data, kind: PushTokenKind) -> String {
    "\(userId.lowercased())|\(tokenHexString(from: token))|\(currentPushEnvironment().rawValue)|\(kind.rawValue)"
  }

  private func currentPushEnvironment() -> PushEnvironment {
    pushEnvironmentProvider()
  }

  private func fetchRegisteredDeviceTokensForReconciliation() async -> [DeviceToken]? {
    do {
      let response: DeviceTokensResponse = try await callService.listDeviceTokens()
      lastTokenListError = nil
      return response.tokens
    } catch {
      lastTokenListError = diagnosticDescription(for: error)
      return nil
    }
  }

  private func serverDeviceTokenMatches(
    _ token: DeviceToken,
    tokenHex: String,
    kind: PushTokenKind,
    environment: PushEnvironment
  ) -> Bool {
    let serverTokenKind: PushTokenKind = token.tokenKind ?? .alert
    let serverEnvironment: PushEnvironment = token.pushEnvironment ?? environment
    return token.token.lowercased() == tokenHex.lowercased()
      && token.pushEnabled
      && serverTokenKind == kind
      && serverEnvironment == environment
  }

  private func diagnosticsState(kind: PushTokenKind) -> String {
    guard let token: Data = latestStoredToken(kind: kind) else {
      return "missing"
    }

    if lastRegistrationErrorsByKind[kind.rawValue] != nil {
      return "failed"
    }

    guard let currentUserId: String = sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines),
      !currentUserId.isEmpty
    else {
      return "local"
    }

    let signature: String = registrationSignature(userId: currentUserId, token: token, kind: kind)
    return storedRegistrationSignature(kind: kind) == signature ? "registered" : "pending"
  }

  private func clearRegistrationError(kind: PushTokenKind) {
    lastRegistrationErrorsByKind[kind.rawValue] = nil
  }

  private func diagnosticDescription(for error: Error) -> String {
    let rawValue: String
    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      rawValue = description
    } else {
      rawValue = String(describing: error)
    }

    let sanitized = rawValue
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "|", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(sanitized.prefix(120))
  }

  nonisolated private static func defaultPushEnvironment() -> PushEnvironment {
#if DEBUG
    return .sandbox
#else
    return .production
#endif
  }

  private func handleSyntheticRemoteNotificationIfNeeded(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard boolValue(userInfoValue("uitest_remote_sync", in: userInfo)) else {
      return false
    }

    let hint: String = stringValue(userInfoValue("hint", in: userInfo))
      ?? stringValue(userInfoValue("push_kind", in: userInfo))
      ?? PushNotificationHint.message.rawValue
    let messageId: String = stringValue(userInfoValue("message_id", in: userInfo)) ?? "ui-test-push"

    notificationCenter.post(
      name: .didProcessRemoteNotificationSync,
      object: nil,
      userInfo: [
        "hint": hint,
        "message_id": messageId,
        "synthetic": true,
      ]
    )

    return true
  }

  private func userInfoValue(_ key: String, in userInfo: [AnyHashable: Any]) -> Any? {
    userInfo[AnyHashable(key)]
  }

  private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let bool as Bool:
      return bool
    case let number as NSNumber:
      return number.boolValue
    case let string as String:
      switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "y", "on":
        return true
      default:
        return false
      }
    default:
      return false
    }
  }

  private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }

  private func normalizedUserHandle(from rawValue: String?) -> String? {
    guard let rawValue else {
      return nil
    }

    let normalized: String = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
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

  private func scheduleLocalNotificationsIfNeeded(_ candidates: [(message: Message, conversation: Conversation)]) async {
    guard !candidates.isEmpty else {
      return
    }

    let uniqueByConversation: [String: (message: Message, conversation: Conversation)] = Dictionary(
      candidates.map { ($0.conversation.id, $0) },
      uniquingKeysWith: { current, replacement in
        replacement.message.createdAt > current.message.createdAt ? replacement : current
      }
    )

    for candidate in uniqueByConversation.values {
      let peerHandle: String? = peerHandle(for: candidate.conversation)
      if let peerHandle, peerHandle == visibleConversationPeerUserIdValue {
        continue
      }

      let content = UNMutableNotificationContent()
      content.title = candidate.conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? (candidate.conversation.name ?? "TellMe")
        : (peerHandle ?? "TellMe")
      content.body = notificationBody(for: candidate.message)
      content.sound = .default
      content.userInfo = ["hint": PushNotificationHint.message.rawValue]

      let request = UNNotificationRequest(
        identifier: "sync.\(candidate.message.id)",
        content: content,
        trigger: nil
      )

      try? await UNUserNotificationCenter.current().add(request)
    }
  }

  private func peerHandle(for conversation: Conversation) -> String? {
    let normalizedCurrentUserId: String? = sessionStore.currentUser?.id
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return conversation.participants?
      .map(\.userId)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .first(where: { participant in
        guard let normalizedCurrentUserId else {
          return true
        }

        return participant != normalizedCurrentUserId
      })
  }

  private func notificationBody(for message: Message) -> String {
    switch message.type {
    case .text:
      let trimmed: String = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Новое защищённое сообщение" : String(trimmed.prefix(140))
    case .file, .media:
      return "Новое защищённое вложение"
    case .callEnd:
      return "Обновление защищённого звонка"
    case .callMediaState:
      return "Обновление защищённого звонка"
    default:
      return "Новая защищённая активность"
    }
  }

#if DEBUG
  func reportIncomingCallsForTesting(_ descriptors: [E2EIncomingCallDescriptor]) {
    reportIncomingCallsIfNeeded(descriptors)
  }

  func reportIncomingCallsForTesting(
    _ descriptors: [E2EIncomingCallDescriptor],
    reportedCallIds: inout Set<String>
  ) {
    reportIncomingCallsIfNeeded(descriptors, reportedCallIds: &reportedCallIds)
  }

  func incomingCallDescriptorsForTesting(
    from candidateMessages: [Message],
    allMessages: [Message],
    conversation: Conversation,
    currentUserId: String,
    localDeviceId: String? = nil
  ) -> [E2EIncomingCallDescriptor] {
    incomingCallDescriptors(
      from: candidateMessages,
      allMessages: allMessages,
      conversation: conversation,
      currentUserId: currentUserId,
      localDeviceId: localDeviceId
    )
  }

  func reportIncomingCallOffersForTesting(
    from candidateMessages: [Message],
    allMessages: [Message],
    conversation: Conversation,
    currentUserId: String,
    localDeviceId: String? = nil
  ) {
    reportIncomingCallOffersIfNeeded(
      from: candidateMessages,
      allMessages: allMessages,
      conversation: conversation,
      currentUserId: currentUserId,
      localDeviceId: localDeviceId
    )
  }
#endif
}
