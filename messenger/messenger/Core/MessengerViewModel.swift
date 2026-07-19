import Foundation
import UIKit

enum CallDiagnosticLog {
  static let outgoingOfferSent: String = "Call offer sent"
  static let outgoingAnswerSent: String = "Call answer sent"
  static let incomingCallOfferReceived: String = "Incoming call offer received"
  static let incomingCallReceived: String = "Incoming call received"
  static let callAnswerReceived: String = "Call answer received"
  static let iceCandidateReceived: String = "ICE candidate received"
  static let callEndReceived: String = "Call end event received"

  static let redactedMessagesForTesting: [String] = [
    outgoingOfferSent,
    outgoingAnswerSent,
    incomingCallOfferReceived,
    incomingCallReceived,
    callAnswerReceived,
    iceCandidateReceived,
    callEndReceived,
  ]
}

@MainActor
final class MessengerViewModel {
  struct ProcessedRemoteNotification: Equatable {
    let hint: PushNotificationHint
    let messageId: String
    let synthetic: Bool
    let receivedAt: Date
  }

  private let container: AppContainer
  private lazy var chatsViewModel: ChatsViewModel = {
    ChatsViewModel(
      container: container,
      e2eSecurityService: container.e2eSecurityService,
      sessionStore: container.sessionStore,
      messageService: container.messageService,
      realtimeRouter: container.realtimeRouter,
      defaults: container.defaults,
      secureStateStore: container.secureStateStore,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )
  }()
  private var activeConversationViewModel: ConversationViewModel?

  private(set) var currentUser: User?
  private(set) var activeConversationId: String?
  private(set) var activeCallId: String?
  private(set) var latestRTCConfig: RTCConfig?
  private(set) var socketState: SocketConnectionState = .disconnected
  private(set) var lastIncomingCallId: String?
  private(set) var lastIncomingCallerId: String?
  private(set) var lastErrorMessage: String?
  private(set) var activeConversationMessagesCount: Int = 0
  private(set) var lastGeneratedSeedPhrase: String?
  private(set) var latestAPNSTokenData: Data?
  private(set) var lastProcessedRemoteNotification: ProcessedRemoteNotification?

  private var pendingCallOffersById: [String: CallSessionDescriptionSignal] = [:]
  private var pendingCallAnswersById: [String: CallSessionDescriptionSignal] = [:]
  private var pendingCallICECandidatesById: [String: [CallICECandidateSignal]] = [:]
  private var processedCallSignalMessageIds: Set<String> = []
  private var activeCallPeerId: String?
  private var activeCallType: Call.CallType = .video
  private var processedRemoteNotifications: [ProcessedRemoteNotification] = []
  private var didReceiveAPNSTokenObserver: NSObjectProtocol?
  private var didProcessRemoteNotificationObserver: NSObjectProtocol?

  var onLogUpdate: ((String) -> Void)?
  var onStateUpdate: (() -> Void)?

  init(container: AppContainer) {
    self.container = container
    self.latestAPNSTokenData = container.pushNotificationService.currentAPNSToken()

    Task {
      await container.socketClient.setOnEvent { [weak self] event in
        Task { @MainActor in
          self?.handleSocketEvent(event)
        }
      }

      await container.socketClient.setOnStateChange { [weak self] state in
        Task { @MainActor in
          self?.handleSocketStateChange(state)
        }
      }
    }

    didReceiveAPNSTokenObserver = NotificationCenter.default.addObserver(
      forName: .didReceiveAPNSToken,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      let token = notification.userInfo?["token"] as? Data
      Task { @MainActor [weak self, token] in
        self?.handleDidReceiveAPNSToken(token)
      }
    }

    didProcessRemoteNotificationObserver = NotificationCenter.default.addObserver(
      forName: .didProcessRemoteNotificationSync,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      let rawHint = (notification.userInfo?["hint"] as? String ?? PushNotificationHint.message.rawValue)
      let messageId = notification.userInfo?["message_id"] as? String ?? ""
      let synthetic = notification.userInfo?["synthetic"] as? Bool ?? false
      Task { @MainActor [weak self, rawHint, messageId, synthetic] in
        self?.handleDidProcessRemoteNotification(rawHint: rawHint, messageId: messageId, synthetic: synthetic)
      }
    }
  }

  deinit {
    if let didReceiveAPNSTokenObserver {
      NotificationCenter.default.removeObserver(didReceiveAPNSTokenObserver)
    }
    if let didProcessRemoteNotificationObserver {
      NotificationCenter.default.removeObserver(didProcessRemoteNotificationObserver)
    }
  }

  func register(userHandle: String) async {
    do {
      let authViewModel = AuthViewModel(container: container)
      let handle: String = normalizedUserHandle(primary: userHandle, fallback: userHandle)
      let result = try await authViewModel.register(userHandle: handle)

      currentUser = result.user
      lastGeneratedSeedPhrase = result.generatedSeedPhrase
      lastErrorMessage = nil
      await container.pushNotificationService.syncDeviceTokenIfNeeded()
      log("Registered user: \(result.user.id)")
      onStateUpdate?()
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Register failed: \(message)")
    }
  }

  func login(userHandle: String, seedPhrase: String? = nil) async {
    do {
      let authViewModel = AuthViewModel(container: container)
      let handle: String = normalizedUserHandle(primary: userHandle, fallback: userHandle)
      let resolvedSeedPhrase: String? = {
        let provided: String = (seedPhrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !provided.isEmpty {
          return provided
        }

        let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
          explicitUserId: handle,
          sessionUser: container.sessionStore.currentUser
        )
        return container.keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds)?.seedPhrase
      }()

      let result = try await authViewModel.login(userHandle: handle, seedPhrase: resolvedSeedPhrase)

      currentUser = result.user
      lastGeneratedSeedPhrase = nil
      lastErrorMessage = nil
      await container.pushNotificationService.syncDeviceTokenIfNeeded()
      log("Logged in as: \(result.user.id)")
      onStateUpdate?()
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Login failed: \(message)")
    }
  }

  func refreshSession() async {
    do {
      _ = try await container.authService.refreshTokens()
      await container.pushNotificationService.syncDeviceTokenIfNeeded()
      lastErrorMessage = nil
      log("Session refreshed")
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Refresh failed: \(message)")
    }
  }

  func logout() async {
    await container.socketClient.disconnect()
    await container.pushNotificationService.unregisterCurrentDeviceTokenIfNeeded()

    do {
      try await container.authService.logout()
    } catch {
      log("Logout request failed: \(describe(error))")
    }

    currentUser = nil
    container.clearLocalSessionState(preserveDeviceIdentity: true)
    activeConversationId = nil
    activeConversationViewModel = nil
    activeConversationMessagesCount = 0
    activeCallId = nil
    lastIncomingCallId = nil
    lastIncomingCallerId = nil
    socketState = .disconnected
    lastErrorMessage = nil
    pendingCallOffersById.removeAll()
    pendingCallAnswersById.removeAll()
    pendingCallICECandidatesById.removeAll()
    processedCallSignalMessageIds.removeAll()
    activeCallPeerId = nil
    activeCallType = .video
    log("Logged out")
    onStateUpdate?()
  }

  func connectSocket() async {
    guard let accessToken: String = container.tokenStore.accessToken else {
      log("Socket connection requires login")
      return
    }

    await container.socketClient.connect(token: accessToken)
  }

  func disconnectSocket() async {
    await container.socketClient.disconnect()
  }

  func loadConversations() async {
    do {
      try await chatsViewModel.loadConversations()
      let nextConversation: Conversation? = chatsViewModel.filteredConversations.first ?? chatsViewModel.conversations.first
      if let nextConversation {
        await activateConversation(nextConversation)
      } else {
        activeConversationId = nil
        activeConversationViewModel = nil
        activeConversationMessagesCount = 0
      }

      log("Loaded conversations: \(chatsViewModel.conversations.count)")
      onStateUpdate?()
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Load conversations failed: \(message)")
    }
  }

  func createDirectConversation(with userId: String) async {
    do {
      let normalizedPeer: String = normalizedUserHandle(primary: userId, fallback: userId)
      let conversation: Conversation = try await chatsViewModel.createDirectConversation(with: normalizedPeer)
      await activateConversation(conversation)
      log("Direct conversation ready: \(conversation.id)")
      onStateUpdate?()
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Create conversation failed: \(message)")
    }
  }

  func joinActiveConversationSocket() async {
    guard let conversationId: String = activeConversationId, let activeConversationViewModel else {
      log("No active conversation to join via socket")
      return
    }

    await activeConversationViewModel.joinRealtime()
    log("Joined conversation via socket: \(conversationId)")
  }

  func loadMessages(limit: Int = 20, offset: Int = 0) async {
    _ = limit
    _ = offset

    guard activeConversationId != nil, let activeConversationViewModel else {
      log("No active conversation")
      return
    }

    do {
      try await activeConversationViewModel.loadInitialMessages()
      activeConversationMessagesCount = activeConversationViewModel.messages.count
      processCallSignals(from: activeConversationViewModel.messages)
      log("Messages loaded: \(activeConversationMessagesCount)")
      onStateUpdate?()
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Load messages failed: \(message)")
    }
  }

  func messageCount(
    type: Message.MessageType? = nil,
    contentContains: String? = nil,
    includeCurrentUser: Bool = true
  ) -> Int {
    guard let activeConversationViewModel else {
      return 0
    }

    let localUserId: String = resolvedCurrentUserId()?.lowercased() ?? ""
    let normalizedNeedle: String? = contentContains?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return activeConversationViewModel.messages.filter { message in
      if !includeCurrentUser && !localUserId.isEmpty && message.senderId.lowercased() == localUserId {
        return false
      }

      if let type, message.type != type {
        return false
      }

      if let normalizedNeedle, !normalizedNeedle.isEmpty {
        return message.content.lowercased().contains(normalizedNeedle)
      }

      return true
    }.count
  }

  func inboundMessageCount(
    type: Message.MessageType? = nil,
    contentContains: String? = nil
  ) -> Int {
    messageCount(
      type: type,
      contentContains: contentContains,
      includeCurrentUser: false
    )
  }

  @discardableResult
  func sendMessage(_ content: String) async -> Bool {
    guard activeConversationId != nil, let activeConversationViewModel else {
      log("No active conversation")
      return false
    }

    do {
      let sent: Message = try await activeConversationViewModel.sendText(plaintext: content)
      activeConversationMessagesCount = activeConversationViewModel.messages.count
      switch sent.transportState {
      case .partialFailure:
        lastErrorMessage = sent.transportErrorDetail ?? "Message delivery is incomplete"
        log("Message partially sent: \(sent.id)")
        onStateUpdate?()
        return false
      case .failed:
        lastErrorMessage = sent.transportErrorDetail ?? "Message delivery failed"
        log("Message failed locally: \(sent.id)")
        onStateUpdate?()
        return false
      default:
        lastErrorMessage = nil
        log("Message sent: \(sent.id)")
      }
      onStateUpdate?()
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Send message failed: \(message)")
      return false
    }
  }

  func sendAttachment(
    data: Data,
    fileName: String,
    mimeType: String,
    type: Message.MessageType
  ) async -> Bool {
    guard activeConversationId != nil, let activeConversationViewModel else {
      log("No active conversation")
      return false
    }

    do {
      let sent: Message = try await activeConversationViewModel.sendAttachment(
        data: data,
        fileName: fileName,
        mimeType: mimeType,
        type: type
      )
      activeConversationMessagesCount = activeConversationViewModel.messages.count
      switch sent.transportState {
      case .partialFailure:
        lastErrorMessage = sent.transportErrorDetail ?? "Attachment delivery is incomplete"
        log("Attachment partially sent: \(fileName)")
        onStateUpdate?()
        return false
      case .failed:
        lastErrorMessage = sent.transportErrorDetail ?? "Attachment delivery failed"
        log("Attachment failed locally: \(fileName)")
        onStateUpdate?()
        return false
      default:
        lastErrorMessage = nil
        log("Attachment sent: \(fileName)")
      }
      onStateUpdate?()
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Send attachment failed: \(message)")
      return false
    }
  }

  func deleteActiveConversation() async -> Bool {
    guard let conversationId: String = activeConversationId else {
      log("No active conversation to delete")
      return false
    }

    do {
      try chatsViewModel.deleteConversation(id: conversationId)
      activeConversationId = nil
      activeConversationViewModel = nil
      activeConversationMessagesCount = 0
      log("Conversation deleted: \(conversationId)")
      onStateUpdate?()
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Delete conversation failed: \(message)")
      return false
    }
  }

  func blockPeer(_ peerUserId: String) async -> Bool {
    do {
      let fingerprintResponse: PublicKeyFingerprintResponse = try await container.e2eSecurityService.getPeerFingerprint(
        peerUserId: peerUserId
      )

      _ = try await container.e2eSecurityService.markMismatch(
        peerUserId: peerUserId,
        fingerprint: fingerprintResponse.fingerprint
      )

      log("Peer blocked via trust mismatch: \(peerUserId)")
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Block peer failed: \(message)")
      return false
    }
  }

  func ensureProtectedTrust(with peerUserId: String, timeout: TimeInterval = 60) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))
    var lastFailure: String = "E2E trust setup not started"

    while Date() < deadline {
      do {
        _ = try await container.e2eSecurityService.setConsent(
          peerUserId: peerUserId,
          enabled: true,
          source: "p2p_prompt"
        )

        let fingerprintResponse: PublicKeyFingerprintResponse = try await container.e2eSecurityService.getPeerFingerprint(
          peerUserId: peerUserId
        )

        _ = try await container.e2eSecurityService.verifyTrust(
          peerUserId: peerUserId,
          fingerprint: fingerprintResponse.fingerprint,
          method: .p2p
        )

        let status: E2ETrustStatusResponse = try await container.e2eSecurityService.getTrustStatus(peerUserId: peerUserId)
        if status.mode == .protected {
          lastErrorMessage = nil
          log("E2E trust protected with peer: \(peerUserId)")
          return true
        }

        lastFailure = "E2E trust state is \(status.mode.rawValue), waiting for protected"
      } catch {
        lastFailure = describe(error)
      }

      try? await Task.sleep(nanoseconds: 500_000_000)
    }

    lastErrorMessage = lastFailure
    log("E2E trust setup failed: \(lastFailure)")
    return false
  }

  func startCall(receiverId: String, type: Call.CallType) async {
    guard activeConversationId != nil, activeConversationViewModel != nil else {
      lastErrorMessage = "Call start requires active direct conversation"
      log("Start call failed: \(lastErrorMessage ?? "missing active conversation")")
      return
    }

    activeCallId = UUID().uuidString
    activeCallPeerId = normalizedUserHandle(primary: receiverId, fallback: receiverId)
    activeCallType = type
    if let activeCallId {
      resetPendingCallSignals(callId: activeCallId)
      log("Call started (E2E signaling): \(activeCallId), type: \(type.rawValue)")
    }
    lastErrorMessage = nil
    onStateUpdate?()
  }

  func startVoiceCall(receiverId: String) async {
    await startCall(receiverId: receiverId, type: .voice)
  }

  func makeOutgoingCallSession(receiverId: String, type: Call.CallType) -> E2ECallSessionViewModel? {
    guard activeConversationId != nil, let activeConversationViewModel else {
      lastErrorMessage = "Call session requires active direct conversation"
      log("Start call session failed: \(lastErrorMessage ?? "missing active conversation")")
      return nil
    }

    let peerId: String = normalizedUserHandle(primary: receiverId, fallback: receiverId)
    let callId: String = UUID().uuidString.lowercased()
    activeCallId = callId
    activeCallPeerId = peerId
    activeCallType = type
    resetPendingCallSignals(callId: callId)
    lastErrorMessage = nil
    log("Call session started (E2E UI): \(callId), type: \(type.rawValue)")
    onStateUpdate?()

    return E2ECallSessionViewModel(
      conversationViewModel: activeConversationViewModel,
      role: .initiator,
      callId: callId,
      peerUserId: peerId,
      callType: type
    )
  }

  func answerIncomingCall(callId: String? = nil) async {
    guard let targetCallId: String = callId ?? lastIncomingCallId else {
      log("No incoming call to answer")
      return
    }

    activeCallId = targetCallId
    if let offer: CallSessionDescriptionSignal = pendingCallOffersById[targetCallId] {
      activeCallPeerId = offer.fromUserId ?? lastIncomingCallerId
    } else {
      activeCallPeerId = lastIncomingCallerId
    }
    lastErrorMessage = nil
    log("Call answered (E2E signaling): \(targetCallId)")
    onStateUpdate?()
  }

  func makeIncomingCallSession(callId: String, callType: Call.CallType) -> E2ECallSessionViewModel? {
    guard let activeConversationViewModel else {
      lastErrorMessage = "Incoming call session requires active direct conversation"
      log("Incoming call session failed: \(lastErrorMessage ?? "missing active conversation")")
      return nil
    }

    guard let offer: CallSessionDescriptionSignal = pendingCallOffersById[callId] else {
      lastErrorMessage = "Incoming call session requires pending SDP offer"
      log("Incoming call session failed for \(callId): \(lastErrorMessage ?? "missing offer")")
      return nil
    }

    let callerId: String = normalizedUserHandle(
      primary: offer.fromUserId ?? lastIncomingCallerId ?? "",
      fallback: lastIncomingCallerId ?? ""
    )
    guard !callerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      lastErrorMessage = "Incoming call session requires caller id"
      log("Incoming call session failed for \(callId): \(lastErrorMessage ?? "missing caller")")
      return nil
    }

    activeCallId = callId
    activeCallPeerId = callerId
    activeCallType = callType
    lastErrorMessage = nil
    log("Incoming call session accepted (E2E UI): \(callId), type: \(callType.rawValue)")
    onStateUpdate?()

    return E2ECallSessionViewModel(
      conversationViewModel: activeConversationViewModel,
      role: .receiver(offer: offer),
      callId: callId,
      peerUserId: callerId,
      callType: callType
    )
  }

  func pendingIncomingCallDescriptor(callId: String, callType: Call.CallType) -> E2EIncomingCallDescriptor? {
    guard let conversation: Conversation = activeConversationViewModel?.conversation,
      let offer: CallSessionDescriptionSignal = pendingCallOffersById[callId]
    else {
      return nil
    }

    let callerUserId: String = offer.fromUserId ?? lastIncomingCallerId ?? ""
    guard !callerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    return E2EIncomingCallDescriptor(
      systemUUID: UUID(),
      callId: callId,
      conversation: conversation,
      offer: offer,
      callType: callType,
      callerUserId: callerUserId
    )
  }

  func endCurrentCall() async {
    guard let callId: String = activeCallId else {
      log("No active call")
      return
    }

    if let activeConversationViewModel {
      do {
        _ = try await activeConversationViewModel.sendSignalingPayload(
          msgType: Message.MessageType.callEnd.rawValue,
          payloadObject: CallSignalEnvelope.payload(
            callId: callId,
            values: [
              "status": "ended",
            ]
          )
        )
      } catch {
        log("End call signaling failed: \(describe(error))")
      }
    }

    activeCallId = nil
    resetPendingCallSignals(callId: callId)
    lastErrorMessage = nil
    log("Call ended (E2E signaling): \(callId)")
    onStateUpdate?()
  }

  func pendingCallOffer(callId: String) -> CallSessionDescriptionSignal? {
    pendingCallOffersById[callId]
  }

  func takePendingCallOffer(callId: String) -> CallSessionDescriptionSignal? {
    let offer: CallSessionDescriptionSignal? = pendingCallOffersById[callId]
    pendingCallOffersById[callId] = nil
    return offer
  }

  func pendingCallAnswer(callId: String) -> CallSessionDescriptionSignal? {
    pendingCallAnswersById[callId]
  }

  func takePendingCallAnswer(callId: String) -> CallSessionDescriptionSignal? {
    let answer: CallSessionDescriptionSignal? = pendingCallAnswersById[callId]
    pendingCallAnswersById[callId] = nil
    return answer
  }

  func takePendingCallICECandidates(callId: String) -> [CallICECandidateSignal] {
    let candidates: [CallICECandidateSignal] = pendingCallICECandidatesById[callId] ?? []
    pendingCallICECandidatesById[callId] = nil
    return candidates
  }

  @discardableResult
  private func appendPendingCallICECandidate(_ candidate: CallICECandidateSignal, callId: String) -> Bool {
    var queue: [CallICECandidateSignal] = pendingCallICECandidatesById[callId] ?? []
    guard !queue.contains(where: { $0.dedupeKey == candidate.dedupeKey }) else {
      return false
    }

    queue.append(candidate)
    pendingCallICECandidatesById[callId] = queue
    return true
  }

#if DEBUG
  func appendPendingCallICECandidateForTesting(_ candidate: CallICECandidateSignal, callId: String) -> Bool {
    appendPendingCallICECandidate(candidate, callId: callId)
  }
#endif

  func resetPendingCallSignals(callId: String) {
    pendingCallOffersById[callId] = nil
    pendingCallAnswersById[callId] = nil
    pendingCallICECandidatesById[callId] = nil
  }

  func sendCallOffer(
    callId: String,
    targetUserId: String,
    description: CallSessionDescriptionSignal
  ) async -> Bool {
    _ = targetUserId
    guard let activeConversationViewModel else {
      lastErrorMessage = "No active conversation for call offer"
      log("Send call offer failed: \(lastErrorMessage ?? "missing active conversation")")
      return false
    }

    do {
      let dtlsFingerprint: String = try boundDTLSFingerprint(for: description)
      var payload: [String: Any] = CallSignalEnvelope.payload(
        callId: callId,
        dtlsFingerprint: dtlsFingerprint,
        values: [
          "call_type": activeCallType.rawValue,
          "offer": [
            "type": description.type,
            "sdp": description.sdp,
          ],
        ]
      )
      if let sender: String = resolvedCurrentUserId() {
        payload["from_user"] = sender
      }

      _ = try await activeConversationViewModel.sendSignalingPayload(
        msgType: Message.MessageType.callOffer.rawValue,
        payloadObject: payload
      )
      log(CallDiagnosticLog.outgoingOfferSent)
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Send call offer failed: \(message)")
      return false
    }
  }

  func sendCallAnswer(callId: String, description: CallSessionDescriptionSignal) async -> Bool {
    guard let activeConversationViewModel else {
      lastErrorMessage = "No active conversation for call answer"
      log("Send call answer failed: \(lastErrorMessage ?? "missing active conversation")")
      return false
    }

    do {
      let dtlsFingerprint: String = try boundDTLSFingerprint(for: description)
      var payload: [String: Any] = CallSignalEnvelope.payload(
        callId: callId,
        dtlsFingerprint: dtlsFingerprint,
        values: [
          "answer": [
            "type": description.type,
            "sdp": description.sdp,
          ],
        ]
      )
      if let sender: String = resolvedCurrentUserId() {
        payload["from_user"] = sender
      }

      _ = try await activeConversationViewModel.sendSignalingPayload(
        msgType: Message.MessageType.callAnswer.rawValue,
        payloadObject: payload
      )
      log(CallDiagnosticLog.outgoingAnswerSent)
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Send call answer failed: \(message)")
      return false
    }
  }

  func sendCallICECandidate(
    callId: String,
    targetUserId: String,
    candidate: CallICECandidateSignal
  ) async -> Bool {
    _ = targetUserId
    guard let activeConversationViewModel else {
      lastErrorMessage = "No active conversation for ICE candidate"
      log("Send ICE candidate failed: \(lastErrorMessage ?? "missing active conversation")")
      return false
    }

    do {
      var payload: [String: Any] = CallSignalEnvelope.payload(
        callId: callId,
        values: [
          "candidate": [
            "candidate": candidate.sdp,
            "sdpMLineIndex": Int(candidate.sdpMLineIndex),
          ],
        ]
      )
      if let sdpMid: String = candidate.sdpMid, !sdpMid.isEmpty {
        payload["candidate"] = [
          "candidate": candidate.sdp,
          "sdpMLineIndex": Int(candidate.sdpMLineIndex),
          "sdpMid": sdpMid,
        ]
      }

      _ = try await activeConversationViewModel.sendSignalingPayload(
        msgType: Message.MessageType.callIceCandidate.rawValue,
        payloadObject: payload
      )
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Send ICE candidate failed: \(message)")
      return false
    }
  }

  func flushCallCandidates(callId: String) async -> Bool {
    _ = callId
    return true
  }

  func registerDummyDeviceToken() async {
    _ = await registerCurrentDeviceToken()
  }

  func registerCurrentDeviceToken() async -> Bool {
    guard let tokenData: Data = container.pushNotificationService.currentAPNSToken() ?? latestAPNSTokenData else {
      let message: String = "APNS token is not available"
      lastErrorMessage = message
      log("Device token register failed: \(message)")
      return false
    }

    do {
      let _ = try await container.pushNotificationService.registerDeviceToken(tokenData)
      latestAPNSTokenData = tokenData
      lastErrorMessage = nil
      log("Device token registered")
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Device token register failed: \(message)")
      return false
    }
  }

  func validateSyntheticPushNotification(hint: PushNotificationHint, messageId: String) async -> Bool {
    let handled: Bool = await container.pushNotificationService.handleRemoteNotification([
      "uitest_remote_sync": true,
      "hint": hint.rawValue,
      "message_id": messageId,
    ])

    if handled {
      lastErrorMessage = nil
      log("Synthetic push processed: \(hint.rawValue) \(messageId)")
      return true
    }

    let message: String = "Synthetic push was not processed"
    lastErrorMessage = message
    log(message)
    return false
  }

  func waitForAPNSToken(timeout: TimeInterval) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))
    while Date() < deadline {
      if container.pushNotificationService.currentAPNSToken() != nil || latestAPNSTokenData != nil {
        latestAPNSTokenData = container.pushNotificationService.currentAPNSToken() ?? latestAPNSTokenData
        lastErrorMessage = nil
        return true
      }

      try? await Task.sleep(nanoseconds: 250_000_000)
    }

    latestAPNSTokenData = container.pushNotificationService.currentAPNSToken() ?? latestAPNSTokenData
    if latestAPNSTokenData == nil {
      lastErrorMessage = "APNS token was not received in time"
    }
    return latestAPNSTokenData != nil
  }

  func waitForRemoteNotification(
    hint: PushNotificationHint,
    timeout: TimeInterval,
    requireServerDelivery: Bool = true,
    after earliestDate: Date = Date()
  ) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))

    while Date() < deadline {
      if let event = processedRemoteNotifications.last(where: { candidate in
        candidate.receivedAt >= earliestDate
          && candidate.hint == hint
          && (!requireServerDelivery || !candidate.synthetic)
      }) {
        lastProcessedRemoteNotification = event
        lastErrorMessage = nil
        return true
      }

      try? await Task.sleep(nanoseconds: 250_000_000)
    }

    let matched: Bool = processedRemoteNotifications.contains(where: { candidate in
      candidate.receivedAt >= earliestDate
        && candidate.hint == hint
        && (!requireServerDelivery || !candidate.synthetic)
    })
    if !matched {
      lastErrorMessage = "Timed out waiting for \(hint.rawValue) remote notification"
    }
    return matched
  }

  func sendMissedCallMarker(tag: String? = nil) async -> Bool {
    guard activeConversationId != nil, let activeConversationViewModel else {
      log("No active conversation")
      return false
    }

    do {
      let sent: Message = try await activeConversationViewModel.sendSignalingPayload(
        msgType: Message.MessageType.callEnd.rawValue,
        payloadObject: CallSignalEnvelope.payload(
          callId: UUID().uuidString,
          values: [
            "status": "missed",
            "source": "automation",
            "automation_tag": tag ?? "",
          ]
        )
      )
      activeConversationMessagesCount = activeConversationViewModel.messages.count
      switch sent.transportState {
      case .partialFailure:
        lastErrorMessage = sent.transportErrorDetail ?? "Missed-call marker delivery is incomplete"
        log("Missed call marker partially sent: \(sent.id)")
        onStateUpdate?()
        return false
      case .failed:
        lastErrorMessage = sent.transportErrorDetail ?? "Missed-call marker delivery failed"
        log("Missed call marker failed locally: \(sent.id)")
        onStateUpdate?()
        return false
      default:
        lastErrorMessage = nil
        log("Missed call marker sent: \(sent.id)")
      }
      onStateUpdate?()
      return true
    } catch {
      let message: String = describe(error)
      lastErrorMessage = message
      log("Missed call marker send failed: \(message)")
      return false
    }
  }

  private func handleSocketEvent(_ event: SocketEvent) {
    if LegacyRawCallSocketPolicy.isLegacyRawCallEvent(event.name),
      !LegacyRawCallSocketPolicy.allowsRawCallEvents(configuration: container.launchConfiguration)
    {
      log("Ignored legacy raw call socket event outside stub mode: \(event.name)")
      return
    }

    if event.name == "rtc_config",
      let payload: Data = event.payload,
      let rtcConfig: RTCConfig = try? JSONCoding.decoder.decode(RTCConfig.self, from: payload)
    {
      latestRTCConfig = rtcConfig
      log("RTC config received. ICE servers: \(rtcConfig.iceServers.count)")
      onStateUpdate?()
      return
    }

    if event.name == "incoming_call",
      let incomingCall: IncomingCallEvent = try? event.decodePayload(as: IncomingCallEvent.self)
    {
      lastIncomingCallId = incomingCall.callId
      lastIncomingCallerId = incomingCall.callerId

      if let offerPayload: [String: String] = incomingCall.offer,
        let sdpType: String = offerPayload["type"],
        let sdp: String = offerPayload["sdp"],
        !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let offer: CallSessionDescriptionSignal = CallSessionDescriptionSignal(
          callId: incomingCall.callId,
          fromUserId: incomingCall.callerId,
          type: sdpType,
          sdp: sdp
        )
        pendingCallOffersById[incomingCall.callId] = offer
        log(CallDiagnosticLog.incomingCallOfferReceived)
      }

      log(CallDiagnosticLog.incomingCallReceived)
      onStateUpdate?()
      return
    }

    if event.name == "call_answered",
      let callAnswered: CallAnsweredEvent = try? event.decodePayload(as: CallAnsweredEvent.self)
    {
      activeCallId = callAnswered.callId

      if let answerPayload: [String: String] = callAnswered.answer,
        let sdpType: String = answerPayload["type"],
        let sdp: String = answerPayload["sdp"],
        !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let answer: CallSessionDescriptionSignal = CallSessionDescriptionSignal(
          callId: callAnswered.callId,
          fromUserId: nil,
          type: sdpType,
          sdp: sdp
        )
        pendingCallAnswersById[callAnswered.callId] = answer
        log(CallDiagnosticLog.callAnswerReceived)
      }

      log(CallDiagnosticLog.callAnswerReceived)
      onStateUpdate?()
      return
    }

    if event.name == "call_ice_candidate",
      let candidateEvent: CallICECandidateEvent = try? event.decodePayload(as: CallICECandidateEvent.self),
      let candidateSignal: CallICECandidateSignal = parseICECandidateSignal(from: candidateEvent)
    {
      if appendPendingCallICECandidate(candidateSignal, callId: candidateEvent.callId) {
        log(CallDiagnosticLog.iceCandidateReceived)
      }
      return
    }

    if event.name == "call_ended",
      let callEnded: CallEndedEvent = try? event.decodePayload(as: CallEndedEvent.self)
    {
      if activeCallId == callEnded.callId {
        activeCallId = nil
      }
      resetPendingCallSignals(callId: callEnded.callId)
      log(CallDiagnosticLog.callEndReceived)
      onStateUpdate?()
      return
    }

    log("Socket event: \(event.name)")
  }

  private func handleSocketStateChange(_ state: SocketConnectionState) {
    socketState = state
    log("Socket state changed: \(state)")
    onStateUpdate?()
  }

  private func handleDidReceiveAPNSToken(_ token: Data?) {
    latestAPNSTokenData = token
    if let latestAPNSTokenData {
      log("APNS token received: \(latestAPNSTokenData.count) bytes")
    } else {
      log("APNS token received")
    }
    onStateUpdate?()
  }

  private func handleDidProcessRemoteNotification(
    rawHint: String,
    messageId: String,
    synthetic: Bool
  ) {
    let normalizedHint: String = rawHint
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let hint: PushNotificationHint = PushNotificationHint(rawValue: normalizedHint) ?? .message
    let normalizedMessageId: String = messageId
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let event = ProcessedRemoteNotification(
      hint: hint,
      messageId: normalizedMessageId,
      synthetic: synthetic,
      receivedAt: Date()
    )

    processedRemoteNotifications.append(event)
    if processedRemoteNotifications.count > 32 {
      processedRemoteNotifications.removeFirst(processedRemoteNotifications.count - 32)
    }

    lastProcessedRemoteNotification = event
    log("Remote notification processed: hint=\(hint.rawValue) synthetic=\(synthetic) messageId=\(normalizedMessageId)")
    onStateUpdate?()
  }

  private func parseICECandidateSignal(from event: CallICECandidateEvent) -> CallICECandidateSignal? {
    var candidate: [String: Any] = [:]
    for (key, value) in event.candidate {
      candidate[key] = value.value
    }

    var payload: [String: Any] = ["candidate": candidate]
    if let transportProfile: String = event.transportProfile {
      payload["transport_profile"] = transportProfile
    }

    return CallSignalParser.iceCandidate(from: payload, callId: event.callId)
  }

  private func processCallSignals(from messages: [Message]) {
    guard !messages.isEmpty else {
      return
    }

    let sortedMessages: [Message] = messages.sorted { $0.createdAt < $1.createdAt }
    for message in sortedMessages where !processedCallSignalMessageIds.contains(message.id) {
      processedCallSignalMessageIds.insert(message.id)
      processCallSignal(from: message)
    }
  }

  private func processCallSignal(from message: Message) {
    guard let payload: [String: Any] = parseJSONObject(from: message.content) else {
      return
    }

    let localUserId: String? = resolvedCurrentUserId()
    let isOwnMessage: Bool = message.senderId == localUserId
    let callId: String = callId(from: payload, fallback: message.id)
    guard CallSignalParser.hasValidEnvelope(payload) else {
      return
    }

    switch message.type {
    case .callOffer:
      guard !isOwnMessage,
        let description: CallSessionDescriptionSignal = CallSignalParser.sessionDescription(
          from: payload,
          objectKey: "offer",
          senderId: message.senderId,
          callId: callId
        )
      else {
        return
      }

      lastIncomingCallId = callId
      lastIncomingCallerId = message.senderId
      activeCallPeerId = message.senderId
      if let parsedType: Call.CallType = callType(from: payload) {
        activeCallType = parsedType
      }

      pendingCallOffersById[callId] = CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: message.senderId,
        type: description.type,
        sdp: description.sdp,
        dtlsFingerprint: description.dtlsFingerprint
      )
      log(CallDiagnosticLog.incomingCallOfferReceived)
      onStateUpdate?()
    case .callAnswer:
      guard !isOwnMessage,
        let description: CallSessionDescriptionSignal = CallSignalParser.sessionDescription(
          from: payload,
          objectKey: "answer",
          senderId: message.senderId,
          callId: callId
        )
      else {
        return
      }

      pendingCallAnswersById[callId] = CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: message.senderId,
        type: description.type,
        sdp: description.sdp,
        dtlsFingerprint: description.dtlsFingerprint
      )
      log(CallDiagnosticLog.callAnswerReceived)
      onStateUpdate?()
    case .callIceCandidate:
      guard !isOwnMessage,
        let candidateSignal: CallICECandidateSignal = parseICECandidate(from: payload, callId: callId)
      else {
        return
      }

      if appendPendingCallICECandidate(candidateSignal, callId: callId) {
        log(CallDiagnosticLog.iceCandidateReceived)
      }
    case .callEnd:
      if activeCallId == callId {
        activeCallId = nil
      }
      resetPendingCallSignals(callId: callId)
      log(CallDiagnosticLog.callEndReceived)
      onStateUpdate?()
    default:
      return
    }
  }

  private func parseJSONObject(from raw: String) -> [String: Any]? {
    guard let data: Data = raw.data(using: .utf8),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: Any] = object as? [String: Any]
    else {
      return nil
    }

    return payload
  }

  private func callId(from payload: [String: Any], fallback: String) -> String {
    let keys: [String] = ["call_id", "callId", "id"]
    for key in keys {
      if let value: String = stringValue(payload[key]), !value.isEmpty {
        return value
      }
    }
    return fallback
  }

  private func callType(from payload: [String: Any]) -> Call.CallType? {
    let candidates: [String?] = [
      stringValue(payload["call_type"]),
      stringValue(payload["callType"]),
      stringValue(payload["media_type"]),
      stringValue(payload["type"]),
    ]

    for value in candidates {
      guard let normalized: String = value?.lowercased() else {
        continue
      }

      if let parsed: Call.CallType = Call.CallType(rawValue: normalized) {
        return parsed
      }
    }

    return nil
  }

  private func parseICECandidate(from payload: [String: Any], callId: String) -> CallICECandidateSignal? {
    CallSignalParser.iceCandidate(from: payload, callId: callId)
  }

  private func stringValue(_ raw: Any?) -> String? {
    switch raw {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }

  private func log(_ message: String) {
    let timestamp: String = DateFormatter.logTimestamp.string(from: Date())
    onLogUpdate?("[\(timestamp)] \(message)")
  }

  private func activateConversation(_ conversation: Conversation) async {
    activeConversationId = conversation.id
    processedCallSignalMessageIds.removeAll()
    let conversationViewModel = ConversationViewModel(
      container: container,
      conversation: conversation,
      defaults: container.defaults
    )
    conversationViewModel.onStateChanged = { [weak self, weak conversationViewModel] in
      guard let self, let conversationViewModel else {
        return
      }

      guard self.activeConversationId == conversationViewModel.conversation.id else {
        return
      }

      self.activeConversationMessagesCount = conversationViewModel.messages.count
      self.processCallSignals(from: conversationViewModel.messages)
      self.onStateUpdate?()
    }
    activeConversationViewModel = conversationViewModel
    activeConversationMessagesCount = conversationViewModel.messages.count
    processCallSignals(from: conversationViewModel.messages)
  }

  private func resolvedCurrentUserId() -> String? {
    let sessionUser: SessionUser? = container.sessionStore.currentUser
    let candidates: [String?] = [
      currentUser?.id,
      sessionUser?.id,
      sessionUser?.username,
      sessionUser?.email,
      container.keyMaterialStore.currentUserId,
    ]

    for candidate in candidates {
      guard let candidate else {
        continue
      }

      let normalized: String = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if normalized.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil {
        return normalized
      }
    }

    return currentUser?.id ?? sessionUser?.id ?? container.keyMaterialStore.currentUserId
  }

  private func normalizedUserHandle(primary: String, fallback: String) -> String {
    let candidate = primary.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil {
      return candidate.lowercased()
    }

    let fallbackCandidate = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if fallbackCandidate.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil {
      return fallbackCandidate
    }

    let localPart = fallbackCandidate
      .replacingOccurrences(of: "@", with: "")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined()

    let normalizedLocal = localPart.isEmpty ? "user" : String(localPart.prefix(24))
    return "@\(normalizedLocal):localhost"
  }

  private func boundDTLSFingerprint(for description: CallSessionDescriptionSignal) throws -> String {
    guard let expectedFingerprint: String = description.dtlsFingerprint,
      let actualFingerprint: String = CallSignalParser.dtlsFingerprint(fromSDP: description.sdp),
      expectedFingerprint == actualFingerprint
    else {
      throw WebRTCAutomationEngineError.operationFailed("SDP DTLS fingerprint is not transcript-bound")
    }

    return expectedFingerprint
  }

  private func describe(_ error: Error) -> String {
    guard let apiError: APIError = error as? APIError else {
      return error.localizedDescription
    }

    switch apiError {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid HTTP response"
    case .transport(let message):
      return "Transport error: \(message)"
    case .server(let statusCode, let message):
      if message.contains("\"username\" is required") {
        let currentAPI = container.environment.apiBaseURL.absoluteString
        return "Server error [\(statusCode)]: backend \(currentAPI) использует legacy /auth/register. Для federated регистрации нужен backend с полем user_handle."
      }
      return "Server error [\(statusCode)]: \(message)"
    case .decoding(let message):
      return "Decoding error: \(message)"
    case .encoding(let message):
      return "Encoding error: \(message)"
    case .unauthorized:
      return "Unauthorized (401)"
    }
  }
}

private extension DateFormatter {
  static let logTimestamp: DateFormatter = {
    let formatter: DateFormatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}
