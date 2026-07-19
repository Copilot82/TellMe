import CryptoKit
import Foundation

private final class AsyncSerialGate {
  private let lock: NSLock = NSLock()
  private var isOccupied: Bool = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    await withCheckedContinuation { continuation in
      var shouldResumeImmediately: Bool = false
      lock.lock()
      if isOccupied {
        waiters.append(continuation)
      } else {
        isOccupied = true
        shouldResumeImmediately = true
      }
      lock.unlock()

      if shouldResumeImmediately {
        continuation.resume()
      }
    }
  }

  func leave() {
    let next: CheckedContinuation<Void, Never>?
    lock.lock()
    if waiters.isEmpty {
      isOccupied = false
      next = nil
    } else {
      next = waiters.removeFirst()
    }
    lock.unlock()

    next?.resume()
  }
}

@MainActor
final class ConversationViewModel {
  enum MailboxIngestionSource {
    case userInitiated
    case realtime
    case backgroundPush
  }

  enum ConversationViewModelError: LocalizedError {
    case missingCurrentUser
    case missingSeedPhrase
    case unableToResolveRecipient
    case invalidAttachmentData

    var errorDescription: String? {
      switch self {
      case .missingCurrentUser:
        return "Current user is missing"
      case .missingSeedPhrase:
        return "Seed phrase is missing on this device."
      case .unableToResolveRecipient:
        return "Unable to resolve recipient"
      case .invalidAttachmentData:
        return "Unable to read selected attachment"
      }
    }
  }

  private enum StorageKeys {
    static let messageHistoryPrefix: String = "federated.local.messages.v2"
    static let editHistoryPrefix: String = "federated.local.message.edits.v2"
    static let replyPreviewPrefix: String = "federated.local.message.reply-previews.v2"
    static let pinnedMessagesPrefix: String = "federated.local.pins.v2"
    static let hiddenPinnedMessagesPrefix: String = "federated.local.hidden-pins.v2"
    static let hiddenMessagesPrefix: String = "federated.local.hidden-messages.v2"
    static let sentReadReceiptsPrefix: String = "federated.local.sent-read-receipts.v2"
    static let pendingReadReceiptsPrefix: String = "federated.local.pending-read-receipts.v2"
    static let deferredControlsPrefix: String = "federated.local.deferred-controls.v2"
    static let manualReadReceiptsKey: String = "messaging.manual_read_receipts"
    static let maxStoredMessagesPerConversation: Int = 500
  }

  private enum ControlMessageType {
    static let edit = "msg_edit"
    static let deleteForAll = "msg_delete_for_all"
    static let read = "msg_read"
    static let reaction = "msg_reaction"
    static let pin = "msg_pin"
    static let unpin = "msg_unpin"
  }

  private struct UserTextPayload: Codable {
    let text: String
    let replyToMessageId: String?
    let replyPreviewText: String?
    let forwardFromMessageId: String?
  }

  private struct ControlPayload: Codable {
    let action: String
    let targetMessageId: String?
    let messageIds: [String]?
    let content: String?
    let messageCreatedAt: Date?
    let emoji: String?
    let reactionAction: String?
    let actorUserId: String?
    let at: Date?
  }

  private enum HydrationOutcome {
    case applied(Message)
    case retryableFailure
    case terminalDrop(messageId: String)
  }

  private struct HydrationBatch {
    let appliedMessages: [Message]
    let ackIds: [String]
  }

  private struct MailboxIngestionSummary {
    let appliedMessages: [Message]
    let ackIds: [String]
  }

  struct InspectedMailboxBlob {
    let envelope: EncryptedMessageEnvelope
    let header: EncryptedMessageHeader
    let payload: E2EMessagePayload
    let nextState: RatchetSessionState
    let consumedOneTimePrekeyId: String?
  }

  private struct OutboundSendExecutionResult {
    let messageId: String
    let transportState: Message.OutboundTransportState
    let errorDetail: String?
    let attemptedPeerDeliveryCount: Int
    let successfulPeerDeliveryCount: Int
  }

  private struct DeliveryTarget {
    let userHandle: String
    let bundle: FederatedPrekeyBundle
  }

  nonisolated static let defaultInitialCallOfferPeerDeliveryRetryDelaysSeconds: [TimeInterval] = [0, 0.4, 1.2, 2.4]

  private let container: AppContainer
  private let defaults: UserDefaults
  private let initialCallOfferPeerDeliveryRetryDelaysSeconds: [TimeInterval]
  private let outboundSendGate: AsyncSerialGate = AsyncSerialGate()
  private var eventObserverId: UUID?
  private var stateObserverId: UUID?
  private var remoteNotificationObserver: NSObjectProtocol?
  private var realtimePollingTask: Task<Void, Never>?
  private var hasJoinedRealtime: Bool = false
  private var isVisibleConversation: Bool = false
  private let realtimePollIntervalNanoseconds: UInt64 = 2_000_000_000
  private let pageSize: Int = 50

  private(set) var conversation: Conversation
  private(set) var messages: [Message] = []
  private(set) var totalCount: Int = 0
  private(set) var typingUserIds: Set<String> = []
  private(set) var trustStatus: E2ETrustStatusResponse?
  private(set) var pinnedMessages: [PinnedMessage] = []

  private var editsByMessageId: [String: [MessageEdit]] = [:]
  private var replyPreviewByReplyMessageId: [String: String] = [:]
  private var hiddenPinnedMessageIds: Set<String> = []
  private var hiddenMessageIds: Set<String> = []
  private var volatileDeletedMessageIds: Set<String> = []
  private var sentReadReceipts: Set<String> = []
  private var pendingReadReceipts: Set<String> = []
  private var deferredControlMessages: [Message] = []
  private var callTranscriptStatesByCallId: [String: CallSignalEnvelope.TranscriptState] = [:]
  private var callDeliveryTranscriptStatesByTarget: [String: CallSignalEnvelope.TranscriptState] = [:]
  private var callDeliveryPayloadBodiesByMessageAndTarget: [String: String] = [:]

  var onStateChanged: (() -> Void)?

  var peerUserId: String? {
    guard conversation.type == .direct else {
      return nil
    }

    if let currentUserId: String = currentUserId(),
      let participants: [ConversationParticipant] = conversation.participants,
      let peer: String = participants.first(where: { $0.userId.lowercased() != currentUserId.lowercased() })?.userId
    {
      return peer.lowercased()
    }

    if let candidate: String = conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      candidate.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil
    {
      return candidate
    }

    if let currentUserId: String = currentUserId() {
      let discoveredPeer: String? = messages
        .map(\.senderId)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .first(where: {
          $0 != currentUserId.lowercased()
            && $0.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil
        })
      if let discoveredPeer {
        return discoveredPeer
      }
    }

    return nil
  }

  var isConversationProtected: Bool {
    trustStatus?.mode == .protected
  }

  var securityWarningText: String? {
    if isConversationProtected {
      return nil
    }
    return "Сообщения не подтверждены. Проверьте ключ контакта через QR."
  }

  var activeUserId: String? {
    currentUserId()
  }

  var activeDeviceId: String? {
    currentDeviceId()
  }

  var isCurrentUserAdmin: Bool {
    false
  }

  var manualReadReceiptsEnabled: Bool {
    defaults.bool(forKey: StorageKeys.manualReadReceiptsKey)
  }

  init(
    container: AppContainer,
    conversation: Conversation,
    defaults: UserDefaults = .standard,
    initialCallOfferPeerDeliveryRetryDelaysSeconds: [TimeInterval] =
      ConversationViewModel.defaultInitialCallOfferPeerDeliveryRetryDelaysSeconds
  ) {
    self.container = container
    self.defaults = defaults
    self.initialCallOfferPeerDeliveryRetryDelaysSeconds = initialCallOfferPeerDeliveryRetryDelaysSeconds
    self.conversation = conversation
    self.messages = loadPersistedMessages()
    self.editsByMessageId = loadPersistedEdits()
    self.replyPreviewByReplyMessageId = loadPersistedReplyPreviews()
    self.pinnedMessages = loadPersistedPinnedMessages()
    self.hiddenPinnedMessageIds = loadHiddenPinnedMessageIds()
    self.hiddenMessageIds = loadHiddenMessageIds()
    self.sentReadReceipts = loadSentReadReceipts()
    self.pendingReadReceipts = loadPendingReadReceipts()
    self.deferredControlMessages = loadPersistedDeferredControlMessages()
    self.messages = messages.filter { !hiddenMessageIds.contains($0.id) }
    reapplyPersistedDeferredControlsIfNeeded()
    observeRealtimeEvents()
    observeProcessedRemoteNotifications()
  }

  deinit {
    if let remoteNotificationObserver {
      NotificationCenter.default.removeObserver(remoteNotificationObserver)
    }
  }

  func joinRealtime() async {
    hasJoinedRealtime = true
    if eventObserverId == nil || stateObserverId == nil {
      observeRealtimeEvents()
    }
    try? await container.socketClient.subscribeSync()
    startRealtimePolling()
  }

  func leaveRealtime() async {
    hasJoinedRealtime = false
    stopRealtimePolling()
    if let eventObserverId {
      container.realtimeRouter.removeObserver(eventObserverId)
      self.eventObserverId = nil
    }
    if let stateObserverId {
      container.realtimeRouter.removeObserver(stateObserverId)
      self.stateObserverId = nil
    }
  }

  func beginVisibleConversationTracking() async {
    isVisibleConversation = true
    await syncVisibleConversationTracking()
    _ = await flushPendingReadReceiptsIfNeeded()
    _ = await autoMarkVisibleConversationAsReadIfNeeded()
  }

  func endVisibleConversationTracking() async {
    isVisibleConversation = false
    await syncVisibleConversationTracking()
  }

  func sendTypingStart() async {
    // typing signals are intentionally not sent in release-1 hard-cutover
  }

  func sendTypingStop() async {
    // typing signals are intentionally not sent in release-1 hard-cutover
  }

  func loadConversationDetails() async throws {
    try? await refreshTrustStatus()
    notifyStateChanged()
  }

  func loadInitialMessages() async throws {
    try await syncAndHydrate(limit: pageSize, replaceExisting: true, source: .userInitiated)
    try? await refreshTrustStatus()
    notifyStateChanged()
  }

  func fetchRelayRTCConfig() async throws -> RTCConfig {
    await reconnectRealtimeForCallStartupIfNeeded()
    return try await container.callService.fetchTurnCredentials()
  }

  private func reconnectRealtimeForCallStartupIfNeeded() async {
    guard !container.launchConfiguration.shouldDisableRealtime,
      let token: String = container.tokenStore.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      return
    }

    switch container.realtimeRouter.connectionState {
    case .connected, .connecting:
      return
    case .disconnected, .failed:
      await container.realtimeRouter.connect(token: token)
    }
  }

  func loadMoreMessages() async throws {
    let nextLimit = max(pageSize, messages.count + pageSize)
    try await syncAndHydrate(limit: nextLimit, replaceExisting: true, source: .userInitiated)
    notifyStateChanged()
  }

  @discardableResult
  // Mailbox ingestion is idempotent because realtime, push, and manual sync can deliver the same blob.
  func ingestMailboxBlobs(
    _ blobs: [FederatedMailboxBlob],
    source: MailboxIngestionSource = .backgroundPush
  ) async throws -> [String] {
    let summary = try await processMailboxBlobs(
      blobs,
      replaceExisting: false,
      source: source
    )
    return summary.ackIds
  }

  @discardableResult
  func sendText(
    plaintext: String,
    replyToMessageId: String? = nil,
    forwardFromMessageId: String? = nil
  ) async throws -> Message {
    let normalizedText: String = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedReplyToMessageId: String? = normalizedOptionalMessageId(replyToMessageId)
    let normalizedForwardFromMessageId: String? = normalizedOptionalMessageId(forwardFromMessageId)
    guard !normalizedText.isEmpty else {
      throw APIError.server(statusCode: 400, message: "Message is empty")
    }
    if let normalizedReplyToMessageId,
      !isUserVisibleMessage(normalizedReplyToMessageId)
    {
      throw APIError.server(statusCode: 400, message: "Reply target is unavailable")
    }
    if let normalizedForwardFromMessageId,
      !isUserVisibleMessage(normalizedForwardFromMessageId)
    {
      throw APIError.server(statusCode: 400, message: "Forward target is unavailable")
    }

    let replyPreview: String? = normalizedReplyToMessageId
      .flatMap { replyPreviewText(messageId: $0) }
      .map { String($0.prefix(140)) }
    let bodyPayload = UserTextPayload(
      text: normalizedText,
      replyToMessageId: normalizedReplyToMessageId,
      replyPreviewText: replyPreview,
      forwardFromMessageId: normalizedForwardFromMessageId
    )
    let encodedBody: Data = try JSONCoding.encoder.encode(bodyPayload)
    let encodedBodyString: String = String(data: encodedBody, encoding: .utf8) ?? normalizedText

    let payload = E2EMessagePayload(
      conversationId: conversation.id,
      msgType: "text",
      body: encodedBodyString,
      attachments: [],
      padding: randomPadding()
    )

    let localMessageId: String = normalizedMessageId(UUID().uuidString)
    let localMessage = Message(
      id: localMessageId,
      conversationId: conversation.id,
      senderId: currentUserId() ?? "local",
      content: normalizedText,
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: normalizedReplyToMessageId,
      forwardedFromMessageId: normalizedForwardFromMessageId,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: .pending,
      transportErrorDetail: nil
    )

    upsertMessage(localMessage)
    if let replyPreview {
      replyPreviewByReplyMessageId[localMessage.id] = replyPreview
      persistReplyPreviews()
    }
    notifyStateChanged()

    do {
      let sendResult = try await sendE2EPayload(payload, messageId: localMessage.id)
      let finalized = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: sendResult.transportState,
        errorDetail: sendResult.errorDetail
      ) ?? localMessage
      notifyStateChanged()
      return finalized
    } catch {
      _ = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: .failed,
        errorDetail: error.localizedDescription
      )
      notifyStateChanged()
      throw error
    }
  }

  @discardableResult
  func sendAttachment(
    data: Data,
    fileName: String,
    mimeType: String,
    type: Message.MessageType,
    allowRiskyUpload: Bool = false
  ) async throws -> Message {
    guard !data.isEmpty else {
      throw ConversationViewModelError.invalidAttachmentData
    }

    guard let senderHandle: String = currentUserId() else {
      throw ConversationViewModelError.missingCurrentUser
    }

    let seedPhrase: String = try resolvedSeedPhrase(for: senderHandle)
    let prepared = try container.attachmentInspectionService.prepareForUpload(
      data: data,
      fileName: fileName,
      mimeType: mimeType
    )
    if prepared.scanResult.verdict == .warn, !allowRiskyUpload {
      throw AttachmentInspectionError.warningRequiresAcknowledgement(prepared.scanResult)
    }

    let fileKeyData = container.cryptoService.generateSeed(bytes: 32)
    let fileKey = SymmetricKey(data: fileKeyData)
    let encryptedFile = try container.cryptoService.encryptAEAD(plaintext: prepared.data, key: fileKey)

    let encodedCiphertext = try JSONCoding.encoder.encode(encryptedFile)
    let mediaInit = try await container.messageService.initMediaUpload(
      mimeHint: prepared.mimeType,
      sizeHint: prepared.data.count,
      ttlSec: nil
    )
    let localDeviceId: String = currentDeviceId() ?? fallbackDeviceId(for: senderHandle)
    let ciphertextSha256: String = AttachmentSecurity.sha256Hex(encodedCiphertext)
    let attestationPayload: String = AttachmentSecurity.buildUploadAttestationPayload(
      mediaId: mediaInit.mediaId,
      userHandle: senderHandle,
      deviceId: localDeviceId,
      capabilityToken: mediaInit.downloadCapability,
      ciphertextSha256: ciphertextSha256,
      ciphertextSize: encodedCiphertext.count,
      scanResult: prepared.scanResult
    )
    let attestationSignature: String = try container.identityService.signMessage(
      seedPhrase: seedPhrase,
      message: attestationPayload
    )
    _ = try await container.messageService.uploadCiphertext(
      mediaId: mediaInit.mediaId,
      ciphertext: encodedCiphertext,
      attestation: MediaUploadAttestationPayload(
        capabilityToken: mediaInit.downloadCapability,
        ciphertextSha256: ciphertextSha256,
        scanVerdict: prepared.scanResult.verdict,
        riskFlags: prepared.scanResult.riskFlags,
        scannerVersion: prepared.scanResult.scannerVersion,
        rulesVersion: prepared.scanResult.rulesVersion,
        attestationSignature: attestationSignature
      )
    )

    let attachment = E2EAttachmentReference(
      originServer: mediaInit.originServer,
      mediaId: mediaInit.mediaId,
      downloadCapability: mediaInit.downloadCapability,
      fileKey: fileKeyData.base64EncodedString(),
      hashCipherFile: ciphertextSha256,
      mime: prepared.mimeType,
      size: prepared.data.count,
      scanVerdict: prepared.scanResult.verdict,
      riskFlags: prepared.scanResult.riskFlags,
      scannerVersion: prepared.scanResult.scannerVersion,
      rulesVersion: prepared.scanResult.rulesVersion
    )

    let bodyPayload = UserTextPayload(
      text: fileName,
      replyToMessageId: nil,
      replyPreviewText: nil,
      forwardFromMessageId: nil
    )
    let encodedBody: Data = try JSONCoding.encoder.encode(bodyPayload)
    let encodedBodyString: String = String(data: encodedBody, encoding: .utf8) ?? prepared.fileName

    let payload = E2EMessagePayload(
      conversationId: conversation.id,
      msgType: type.rawValue,
      body: encodedBodyString,
      attachments: [attachment],
      padding: randomPadding()
    )
    let localMessageId: String = normalizedMessageId(UUID().uuidString)

    let localMessage = Message(
      id: localMessageId,
      conversationId: conversation.id,
      senderId: currentUserId() ?? "local",
      content: prepared.fileName,
      type: type,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: FileAttachment(
        id: attachment.mediaId,
        messageId: localMessageId,
        storageUrl: mediaInit.downloadPath,
        mimeType: prepared.mimeType,
        fileSize: prepared.data.count,
        fileName: prepared.fileName,
        originServer: mediaInit.originServer,
        downloadCapability: mediaInit.downloadCapability,
        fileKey: attachment.fileKey,
        hashCipherFile: attachment.hashCipherFile,
        scanVerdict: attachment.scanVerdict,
        riskFlags: attachment.riskFlags,
        scannerVersion: attachment.scannerVersion,
        rulesVersion: attachment.rulesVersion,
        createdAt: Date()
      ),
      reactions: nil,
      transportState: .pending,
      transportErrorDetail: nil
    )

    upsertMessage(localMessage)
    notifyStateChanged()

    do {
      let sendResult = try await sendE2EPayload(payload, messageId: localMessage.id)
      let finalized = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: sendResult.transportState,
        errorDetail: sendResult.errorDetail
      ) ?? localMessage
      notifyStateChanged()
      return finalized
    } catch {
      _ = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: .failed,
        errorDetail: error.localizedDescription
      )
      notifyStateChanged()
      throw error
    }
  }

  func prepareAttachmentPreview(
    messageId: String,
    allowRiskyPreview: Bool = false
  ) async throws -> PreparedAttachmentPreview {
    let preview: PreparedAttachmentPreview = try await resolveAttachmentPreview(messageId: messageId)
    if preview.scanResult.verdict == .warn, !allowRiskyPreview {
      throw AttachmentInspectionError.previewWarningRequiresAcknowledgement(preview.scanResult)
    }

    return preview
  }

  func prepareAttachmentExport(
    messageId: String,
    allowRiskyPreview: Bool = false,
    allowRiskyExport: Bool = false
  ) async throws -> PreparedAttachmentPreview {
    let preview = try await prepareAttachmentPreview(
      messageId: messageId,
      allowRiskyPreview: allowRiskyPreview
    )
    if preview.scanResult.verdict == .warn, !allowRiskyExport {
      throw AttachmentInspectionError.exportWarningRequiresAcknowledgement(preview.scanResult)
    }

    return preview
  }

  @discardableResult
  func sendSignalingPayload(
    msgType: String,
    payloadObject: [String: Any]
  ) async throws -> Message {
    try await sendSignalingPayload(
      msgType: msgType,
      payloadObject: payloadObject,
      requiresPeerDelivery: false,
      peerDeliveryErrorMessage: nil
    )
  }

  @discardableResult
  func sendSignalingPayloadRequiringPeerDelivery(
    msgType: String,
    payloadObject: [String: Any],
    errorMessage: String
  ) async throws -> Message {
    try await sendSignalingPayload(
      msgType: msgType,
      payloadObject: payloadObject,
      requiresPeerDelivery: true,
      peerDeliveryErrorMessage: errorMessage
    )
  }

  @discardableResult
  private func sendSignalingPayload(
    msgType: String,
    payloadObject: [String: Any],
    requiresPeerDelivery: Bool,
    peerDeliveryErrorMessage: String?
  ) async throws -> Message {
    let preparedPayloadObject: [String: Any] = prepareSignalingPayload(
      msgType: msgType,
      payloadObject: payloadObject
    )
    guard JSONSerialization.isValidJSONObject(preparedPayloadObject) else {
      throw ConversationViewModelError.invalidAttachmentData
    }

    let bodyData: Data = try JSONSerialization.data(withJSONObject: preparedPayloadObject, options: [])
    guard let body: String = String(data: bodyData, encoding: .utf8) else {
      throw ConversationViewModelError.invalidAttachmentData
    }

    let payload = E2EMessagePayload(
      conversationId: conversation.id,
      msgType: msgType,
      body: body,
      attachments: [],
      padding: randomPadding()
    )

    let localMessage = Message(
      id: normalizedMessageId(UUID().uuidString),
      conversationId: conversation.id,
      senderId: currentUserId() ?? "local",
      content: body,
      type: Message.MessageType(rawValue: msgType) ?? .system,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: .pending,
      transportErrorDetail: nil
    )

    upsertMessage(localMessage)
    notifyStateChanged()

    do {
      let sendResult = try await sendE2EPayloadWithInitialCallOfferPeerDeliveryRetry(
        payload,
        messageId: localMessage.id
      )
      if requiresPeerDelivery,
        sendResult.attemptedPeerDeliveryCount == 0 || sendResult.successfulPeerDeliveryCount == 0
      {
        let errorDetail: String = sendResult.errorDetail ?? peerDeliveryErrorMessage ?? "Peer delivery incomplete"
        _ = updateLocalOutboundMessageTransport(
          messageId: localMessage.id,
          transportState: .failed,
          errorDetail: errorDetail
        )
        notifyStateChanged()
        throw APIError.server(statusCode: 503, message: errorDetail)
      }

      let finalized = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: sendResult.transportState,
        errorDetail: sendResult.errorDetail
      ) ?? localMessage
      notifyStateChanged()
      return finalized
    } catch {
      _ = updateLocalOutboundMessageTransport(
        messageId: localMessage.id,
        transportState: .failed,
        errorDetail: error.localizedDescription
      )
      notifyStateChanged()
      throw error
    }
  }

  private func sendE2EPayloadWithInitialCallOfferPeerDeliveryRetry(
    _ payload: E2EMessagePayload,
    messageId: String
  ) async throws -> OutboundSendExecutionResult {
    guard isInitialCallOfferPayload(payload) else {
      return try await sendE2EPayload(payload, messageId: messageId)
    }

    defer {
      clearCallDeliveryPayloadBodyCache(messageId: messageId)
    }

    var lastResult: OutboundSendExecutionResult?
    var lastRetryableError: Error?
    let delays: [TimeInterval] = initialCallOfferPeerDeliveryRetryDelaysSeconds
    for attemptIndex in 0...delays.count {
      do {
        let sendResult = try await sendE2EPayload(payload, messageId: messageId)
        guard sendResult.attemptedPeerDeliveryCount == 0 || sendResult.successfulPeerDeliveryCount == 0 else {
          return sendResult
        }

        lastResult = sendResult
        lastRetryableError = nil
      } catch {
        try Task.checkCancellation()
        guard isRetryableInitialCallOfferSendError(error) else {
          throw error
        }

        lastRetryableError = error
      }

      guard attemptIndex < delays.count else {
        break
      }

      let delaySeconds: TimeInterval = max(0, delays[attemptIndex])
      if delaySeconds > 0 {
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
      }
      try Task.checkCancellation()
    }

    if let lastRetryableError, lastResult == nil {
      throw lastRetryableError
    }

    throw APIError.server(
      statusCode: 503,
      message: lastResult?.errorDetail ?? "Initial call offer delivery incomplete for peer devices"
    )
  }

  private func isRetryableInitialCallOfferSendError(_ error: Error) -> Bool {
    if error is CancellationError {
      return false
    }

    guard let apiError = error as? APIError else {
      return false
    }

    switch apiError {
    case .transport, .invalidResponse:
      return true
    case .server(let statusCode, _):
      return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    case .invalidURL, .decoding, .encoding, .unauthorized:
      return false
    }
  }

  private func prepareSignalingPayload(msgType: String, payloadObject: [String: Any]) -> [String: Any] {
    guard isCallSignalingMessageType(msgType),
      let callId: String = CallSignalParser.callId(from: payloadObject)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !callId.isEmpty
    else {
      return payloadObject
    }

    let senderDeviceId: String? = currentSenderDeviceId()
    var state: CallSignalEnvelope.TranscriptState =
      callTranscriptStatesByCallId[callId] ?? CallSignalEnvelope.TranscriptState()
    let preparedPayload: [String: Any] = CallSignalEnvelope.prepareOutgoingPayload(
      payloadObject,
      callId: callId,
      senderDeviceId: senderDeviceId,
      state: &state
    )
    if msgType == Message.MessageType.callEnd.rawValue {
      callTranscriptStatesByCallId[callId] = nil
    } else {
      callTranscriptStatesByCallId[callId] = state
    }
    return preparedPayload
  }

  private func isCallSignalingMessageType(_ msgType: String) -> Bool {
    Message.MessageType(rawValue: msgType)?.isCallSignaling == true
  }

  @discardableResult
  private func updateLocalOutboundMessageTransport(
    messageId: String,
    transportState: Message.OutboundTransportState,
    errorDetail: String?
  ) -> Message? {
    guard let index: Int = messageIndex(for: messageId) else {
      return nil
    }

    let current = messages[index]
    let updated = Message(
      id: current.id,
      conversationId: current.conversationId,
      senderId: current.senderId,
      content: current.content,
      type: current.type,
      encryptionMode: current.encryptionMode,
      encryptionKeyNonce: current.encryptionKeyNonce,
      readAt: current.readAt,
      deliveredAt: current.deliveredAt,
      replyToMessageId: current.replyToMessageId,
      forwardedFromMessageId: current.forwardedFromMessageId,
      deletedBy: current.deletedBy,
      deletedAt: current.deletedAt,
      createdAt: current.createdAt,
      attachment: current.attachment,
      reactions: current.reactions,
      transportState: transportState,
      transportErrorDetail: transportState == .accepted || transportState == .pending ? nil : errorDetail
    )

    messages[index] = updated
    totalCount = messages.count
    persistMessages()
    return updated
  }

  func markAsRead(messageId: String) async throws {
    guard let message: Message = message(matching: messageId) else {
      return
    }

    guard !isOutgoing(message), message.deletedAt == nil else {
      return
    }

    try await sendReadReceipts(messageIds: [message.id], markLocally: true)
    persistMessages()
    persistSentReadReceipts()
    notifyStateChanged()
  }

  func markAsDelivered(messageId: String) async throws {
    _ = messageId
  }

  func editMessage(messageId: String, content: String) async throws {
    let normalizedContent: String = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTargetMessageId: String = normalizedMessageId(messageId)
    guard !normalizedContent.isEmpty else {
      return
    }

    guard let index: Int = messageIndex(for: normalizedTargetMessageId) else {
      return
    }

    let current = messages[index]
    guard current.content != normalizedContent else {
      return
    }

    try await sendControlMessage(
      type: ControlMessageType.edit,
      payload: ControlPayload(
        action: "edit",
        targetMessageId: normalizedTargetMessageId,
        messageIds: nil,
        content: normalizedContent,
        messageCreatedAt: nil,
        emoji: nil,
        reactionAction: nil,
        actorUserId: currentUserId(),
        at: Date()
      )
    )

    appendEditHistory(messageId: normalizedTargetMessageId, oldContent: current.content)
    messages[index] = Message(
      id: current.id,
      conversationId: current.conversationId,
      senderId: current.senderId,
      content: normalizedContent,
      type: current.type,
      encryptionMode: current.encryptionMode,
      encryptionKeyNonce: current.encryptionKeyNonce,
      readAt: current.readAt,
      deliveredAt: current.deliveredAt,
      replyToMessageId: current.replyToMessageId,
      forwardedFromMessageId: current.forwardedFromMessageId,
      deletedBy: current.deletedBy,
      deletedAt: current.deletedAt,
      createdAt: current.createdAt,
      attachment: current.attachment,
      reactions: current.reactions,
      transportState: current.transportState,
      transportErrorDetail: current.transportErrorDetail
    )
    persistEdits()
    persistMessages()
    notifyStateChanged()
  }

  func deleteMessage(messageId: String) async throws {
    let normalizedTargetMessageId: String = normalizedMessageId(messageId)
    let deleteTime: Date = Date()
    applyDeleteForAll(messageId: normalizedTargetMessageId, deletedBy: currentUserId(), deletedAt: deleteTime)
    persistHiddenMessageIds()
    persistReplyPreviews()
    persistMessages()
    notifyStateChanged()

    try await sendControlMessage(
      type: ControlMessageType.deleteForAll,
      payload: ControlPayload(
        action: "delete_for_all",
        targetMessageId: normalizedTargetMessageId,
        messageIds: nil,
        content: nil,
        messageCreatedAt: nil,
        emoji: nil,
        reactionAction: nil,
        actorUserId: currentUserId(),
        at: deleteTime
      )
    )
  }

  func deleteMessageForMe(messageId: String) async throws {
    let normalizedTargetMessageId: String = normalizedMessageId(messageId)
    messages.removeAll(where: { normalizedMessageId($0.id) == normalizedTargetMessageId })
    hiddenMessageIds.insert(normalizedTargetMessageId)
    volatileDeletedMessageIds.remove(normalizedTargetMessageId)
    replyPreviewByReplyMessageId.removeValue(forKey: normalizedTargetMessageId)
    totalCount = messages.count
    persistHiddenMessageIds()
    persistReplyPreviews()
    persistMessages()
    notifyStateChanged()
  }

  func addReaction(messageId: String, emoji: String) async throws {
    try await toggleReaction(messageId: messageId, emoji: emoji)
  }

  func removeReaction(messageId: String) async throws {
    _ = messageId
  }

  func listReactions(messageId: String) async throws -> [MessageReaction] {
    message(matching: messageId)?.reactions ?? []
  }

  func listEdits(messageId: String) async throws -> [MessageEdit] {
    editsByMessageId[normalizedMessageId(messageId)] ?? []
  }

  func pinMessage(messageId: String) async throws {
    let targetMessageId: String = normalizedMessageId(messageId)
    if pinnedMessages.contains(where: { normalizedMessageId($0.messageId) == targetMessageId }) {
      hiddenPinnedMessageIds.remove(targetMessageId)
      persistHiddenPinnedMessageIds()
      notifyStateChanged()
      return
    }

    guard isUserVisibleMessage(targetMessageId) else {
      return
    }

    let now: Date = Date()
    let previewText: String = pinnedMessagePreviewText(targetMessageId)
    let messageCreatedAt: Date? = message(matching: targetMessageId)?.createdAt
    let pin = PinnedMessage(
      id: UUID().uuidString,
      conversationId: conversation.id,
      messageId: targetMessageId,
      pinnedBy: currentUserId() ?? "local",
      pinnedAt: now,
      previewText: previewText,
      messageCreatedAt: messageCreatedAt
    )

    try await sendControlMessage(
      type: ControlMessageType.pin,
      payload: ControlPayload(
        action: "pin",
        targetMessageId: targetMessageId,
        messageIds: nil,
        content: previewText,
        messageCreatedAt: messageCreatedAt,
        emoji: nil,
        reactionAction: nil,
        actorUserId: currentUserId(),
        at: now
      )
    )

    hiddenPinnedMessageIds.remove(targetMessageId)
    pinnedMessages.insert(pin, at: 0)
    persistPinnedMessages()
    persistHiddenPinnedMessageIds()
    notifyStateChanged()
  }

  func unpinMessage(messageId: String) async throws {
    let targetMessageId: String = normalizedMessageId(messageId)
    try await sendControlMessage(
      type: ControlMessageType.unpin,
      payload: ControlPayload(
        action: "unpin",
        targetMessageId: targetMessageId,
        messageIds: nil,
        content: nil,
        messageCreatedAt: nil,
        emoji: nil,
        reactionAction: nil,
        actorUserId: currentUserId(),
        at: Date()
      )
    )
    hiddenPinnedMessageIds.remove(targetMessageId)
    pinnedMessages.removeAll(where: { normalizedMessageId($0.messageId) == targetMessageId })
    persistPinnedMessages()
    persistHiddenPinnedMessageIds()
    notifyStateChanged()
  }

  func listPinnedMessages() async throws -> [PinnedMessage] {
    visiblePinnedMessages()
  }

  func isMessagePinned(_ messageId: String) -> Bool {
    let targetMessageId: String = normalizedMessageId(messageId)
    return pinnedMessages.contains(where: { normalizedMessageId($0.messageId) == targetMessageId })
  }

  func visiblePinnedMessages() -> [PinnedMessage] {
    pinnedMessages
      .filter { !hiddenPinnedMessageIds.contains(normalizedMessageId($0.messageId)) }
      .filter { isUserVisibleMessage($0.messageId) }
      .sorted { lhs, rhs in
        let lhsDate: Date = pinnedMessageSentAt(lhs)
        let rhsDate: Date = pinnedMessageSentAt(rhs)
        if lhsDate != rhsDate {
          return lhsDate > rhsDate
        }

        return lhs.pinnedAt > rhs.pinnedAt
      }
  }

  func currentPinnedBannerMessage() -> PinnedMessage? {
    visiblePinnedMessages().first
  }

  func pinnedMessageSentAt(_ pinnedMessage: PinnedMessage) -> Date {
    if let createdAt: Date = pinnedMessage.messageCreatedAt {
      return createdAt
    }

    if let message: Message = message(matching: pinnedMessage.messageId) {
      return message.createdAt
    }

    return pinnedMessage.pinnedAt
  }

  func pinnedMessageRecord(messageId: String) -> PinnedMessage? {
    let targetMessageId: String = normalizedMessageId(messageId)
    return pinnedMessages.first(where: { normalizedMessageId($0.messageId) == targetMessageId })
  }

  func canUnpinMessageForEveryone(_ pinnedMessage: PinnedMessage) -> Bool {
    let currentUser = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let actor = pinnedMessage.pinnedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return currentUser == actor
  }

  func unpinMessageForCurrentUser(messageId: String) {
    let targetMessageId: String = normalizedMessageId(messageId)
    guard pinnedMessages.contains(where: { normalizedMessageId($0.messageId) == targetMessageId }) else {
      return
    }

    hiddenPinnedMessageIds.insert(targetMessageId)
    persistHiddenPinnedMessageIds()
    notifyStateChanged()
  }

  func pinnedMessagePreviewText(_ messageId: String) -> String {
    if let pinnedMessage = pinnedMessageRecord(messageId: messageId),
      let storedPreview: String = normalizedPreviewText(pinnedMessage.previewText)
    {
      return storedPreview
    }

    if let message: Message = message(matching: messageId) {
      return pinnedMessagePreviewText(for: message)
    }

    return "Сообщение"
  }

  func canManuallyMarkRead(_ message: Message) -> Bool {
    manualReadReceiptsEnabled
      && message.isUserVisibleInConversation
      && !isOutgoing(message)
      && message.readAt == nil
      && message.deletedAt == nil
  }

  func makeChatsViewModel() -> ChatsViewModel {
    ChatsViewModel(
      container: container,
      e2eSecurityService: container.e2eSecurityService,
      sessionStore: container.sessionStore,
      messageService: container.messageService,
      realtimeRouter: container.realtimeRouter,
      defaults: defaults,
      secureStateStore: container.secureStateStore,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )
  }

  func forwardMessages(messageIds: [String], to targetConversation: Conversation) async throws {
    guard !messageIds.isEmpty else {
      return
    }

    let idSet: Set<String> = Set(messageIds.map(normalizedMessageId))
    let selectedMessages: [Message] = messages
      .filter {
        idSet.contains(normalizedMessageId($0.id))
          && $0.deletedAt == nil
          && $0.isUserVisibleInConversation
      }
      .sorted(by: { $0.createdAt < $1.createdAt })

    guard !selectedMessages.isEmpty else {
      return
    }

    let targetViewModel = ConversationViewModel(container: container, conversation: targetConversation, defaults: defaults)
    for message in selectedMessages {
      if message.type == .text {
        _ = try await targetViewModel.sendText(
          plaintext: message.content,
          replyToMessageId: nil,
          forwardFromMessageId: message.id
        )
      } else {
        // Forwarding encrypted media/file payloads is represented as textual forward marker in release-1.
        let forwardedLabel: String = "Forwarded: \(message.content)"
        _ = try await targetViewModel.sendText(
          plaintext: forwardedLabel,
          replyToMessageId: nil,
          forwardFromMessageId: message.id
        )
      }
    }
  }

  func toggleReaction(messageId: String, emoji: String) async throws {
    let targetMessageId: String = normalizedMessageId(messageId)
    guard let index: Int = messageIndex(for: targetMessageId),
      messages[index].isUserVisibleInConversation
    else {
      return
    }

    let actorUserId: String = currentUserId() ?? "local"
    var reactions: [MessageReaction] = messages[index].reactions ?? []
    let existingIndex: Int? = reactions.firstIndex(where: { $0.userId == actorUserId && $0.emoji == emoji })
    let reactionAction: String

    if let existingIndex {
      reactions.remove(at: existingIndex)
      reactionAction = "remove"
    } else {
      reactions.append(
        MessageReaction(
          id: nil,
          messageId: targetMessageId,
          userId: actorUserId,
          emoji: emoji,
          createdAt: Date()
        )
      )
      reactionAction = "add"
    }

    messages[index].reactions = reactions
    persistMessages()
    notifyStateChanged()

    try await sendControlMessage(
      type: ControlMessageType.reaction,
      payload: ControlPayload(
        action: "reaction",
        targetMessageId: targetMessageId,
        messageIds: nil,
        content: nil,
        messageCreatedAt: nil,
        emoji: emoji,
        reactionAction: reactionAction,
        actorUserId: actorUserId,
        at: Date()
      )
    )
  }

  func hasEdits(messageId: String) -> Bool {
    !(editsByMessageId[normalizedMessageId(messageId)] ?? []).isEmpty
  }

  func replyPreviewText(messageId: String) -> String? {
    let targetMessageId: String = normalizedMessageId(messageId)
    if let message: Message = message(matching: targetMessageId) {
      guard message.isUserVisibleInConversation else {
        return nil
      }
      return message.content
    }

    for edits in editsByMessageId.values {
      if let edit = edits.first(where: { normalizedMessageId($0.messageId) == targetMessageId }) {
        return edit.oldContent
      }
    }

    return nil
  }

  func visibleMessages() -> [Message] {
    messages
      .filter(\.isUserVisibleInConversation)
      .sorted(by: { $0.createdAt < $1.createdAt })
  }

  func replyPreviewFallback(forReplyMessageId messageId: String) -> String? {
    replyPreviewByReplyMessageId[normalizedMessageId(messageId)]
  }

  func isOutgoing(_ message: Message) -> Bool {
    guard let currentUserId: String = currentUserId() else {
      return false
    }

    return message.senderId.lowercased() == currentUserId.lowercased()
  }

  func statusSymbol(for message: Message) -> String {
    guard isOutgoing(message) else {
      return ""
    }

    if message.readAt != nil {
      return "✓✓"
    }

    switch message.transportState {
    case .pending:
      return "⏳"
    case .accepted:
      return "✓"
    case .partialFailure, .failed:
      return "!"
    case .none:
      break
    }

    if message.deliveredAt != nil {
      return "✓"
    }

    return "⏳"
  }

  func refreshTrustStatus() async throws {
    guard let peerUserId else {
      trustStatus = nil
      notifyStateChanged()
      return
    }

    trustStatus = try await container.e2eSecurityService.getTrustStatus(peerUserId: peerUserId)
    notifyStateChanged()
  }

  func fetchPeerFingerprint() async throws -> String {
    guard let peerUserId else {
      throw ConversationViewModelError.unableToResolveRecipient
    }

    let response = try await container.e2eSecurityService.getPeerFingerprint(peerUserId: peerUserId)
    return response.fingerprint
  }

  func verifyPeerFingerprint(_ fingerprint: String, method: TrustVerificationMethod) async throws {
    guard let peerUserId else {
      throw ConversationViewModelError.unableToResolveRecipient
    }

    _ = try await container.e2eSecurityService.verifyTrust(
      peerUserId: peerUserId,
      fingerprint: fingerprint,
      method: method
    )
    try await refreshTrustStatus()
  }

  func setAutoKeyExchangeConsent(enabled: Bool) async throws {
    guard let peerUserId else {
      throw ConversationViewModelError.unableToResolveRecipient
    }

    _ = try await container.e2eSecurityService.setConsent(
      peerUserId: peerUserId,
      enabled: enabled,
      source: "local"
    )
    try await refreshTrustStatus()
  }

  func canEditMessage(_ message: Message) -> Bool {
    guard let currentUserId: String = currentUserId(), message.senderId == currentUserId else {
      return false
    }
    return Date().timeIntervalSince(message.createdAt) <= 24 * 60 * 60
  }

  func decryptTextIfNeeded(_ message: Message) async -> String {
    message.content
  }

  private func syncAndHydrate(
    limit: Int,
    replaceExisting: Bool,
    source: MailboxIngestionSource
  ) async throws {
    let deviceId = currentDeviceId()
    let sync = try await container.messageService.pullSync(deviceId: deviceId, limit: limit)
    _ = try await processMailboxBlobs(
      sync.blobs,
      replaceExisting: replaceExisting,
      source: source
    )
  }

  private func processMailboxBlobs(
    _ blobs: [FederatedMailboxBlob],
    replaceExisting: Bool,
    source: MailboxIngestionSource
  ) async throws -> MailboxIngestionSummary {
    let hydrated = try await hydrateMessages(blobs)
    if !hydrated.appliedMessages.isEmpty {
      try await applyHydratedMessages(
        hydrated.appliedMessages,
        replaceExisting: replaceExisting,
        source: source
      )
    }

    if !hydrated.ackIds.isEmpty {
      _ = try? await container.messageService.ackMessages(hydrated.ackIds)
    }

    return MailboxIngestionSummary(
      appliedMessages: hydrated.appliedMessages,
      ackIds: hydrated.ackIds
    )
  }

  private func hydrateMessages(_ blobs: [FederatedMailboxBlob]) async throws -> HydrationBatch {
    var hydrated: [Message] = []
    var ackIds: [String] = []

    for blob in blobs {
      switch try await hydrateMessage(blob) {
      case .applied(let message):
        hydrated.append(message)
      case .retryableFailure:
        continue
      case .terminalDrop(let messageId):
        ackIds.append(messageId)
      }
    }

    let appliedMessages: [Message] = hydrated.sorted { $0.createdAt > $1.createdAt }
    let appliedIds: [String] = appliedMessages.map(\.id)

    return HydrationBatch(
      appliedMessages: appliedMessages,
      ackIds: Array(Set(appliedIds + ackIds))
    )
  }

  private func hydrateMessage(_ blob: FederatedMailboxBlob) async throws -> HydrationOutcome {
    let localUserId: String? = currentUserId()
    let normalizedBlobMessageId: String = normalizedMessageId(blob.messageId)
    let inspected: InspectedMailboxBlob
    do {
      guard let candidate = try await ConversationViewModel.inspectMailboxBlob(container: container, blob: blob) else {
        return .retryableFailure
      }
      inspected = candidate
    } catch {
      if Self.isTerminalEnvelopeError(error) {
        return .terminalDrop(messageId: normalizedBlobMessageId)
      }
      return .retryableFailure
    }

    if inspected.header.conversationId != conversation.id {
      updateConversationIdIfNeeded(inspected.header.conversationId, senderUserHandle: inspected.header.senderUserHandle)
    }
    let resolvedConversationId: String = conversation.id

    try container.ratchetSessionStore.upsert(inspected.nextState)
    if let oneTimePrekeyId: String = inspected.consumedOneTimePrekeyId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !oneTimePrekeyId.isEmpty,
      let localDeviceId: String = inspected.nextState.localDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !localDeviceId.isEmpty
    {
      container.prekeyPrivateStore.consumeOneTimePrekey(deviceId: localDeviceId, prekeyId: oneTimePrekeyId)
    }

    if shouldDropInvalidCallPayload(inspected, ownerDeviceId: blob.ownerDeviceId) {
      return .terminalDrop(messageId: normalizedBlobMessageId)
    }

    let parsed = decodeUserPayload(inspected.payload.body)
    let resolvedType: Message.MessageType = {
      if isControlMessageType(inspected.payload.msgType) {
        return .system
      }

      return Message.MessageType(rawValue: inspected.payload.msgType) ?? .text
    }()
    let normalizedSenderId: String = inspected.header.senderUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let senderId: String = normalizedSenderId.isEmpty ? (peerUserId ?? blob.senderServer) : normalizedSenderId
    let isOutgoingMessage: Bool = localUserId?.lowercased() == senderId.lowercased()
    let resolvedDeliveredAt: Date? = isOutgoingMessage ? blob.createdAt : nil

    if let replyPreviewText: String = parsed.replyPreviewText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !replyPreviewText.isEmpty
    {
      replyPreviewByReplyMessageId[normalizedBlobMessageId] = replyPreviewText
    }

    let resolvedAttachment: FileAttachment? = inspected.payload.attachments.first.map { attachment in
      FileAttachment(
        id: attachment.mediaId,
        messageId: normalizedBlobMessageId,
        storageUrl: "/api/media/ciphertext/\(attachment.mediaId)",
        mimeType: attachment.mime ?? "application/octet-stream",
        fileSize: attachment.size ?? 0,
        fileName: parsed.text,
        originServer: attachment.originServer,
        downloadCapability: attachment.downloadCapability,
        fileKey: attachment.fileKey,
        hashCipherFile: attachment.hashCipherFile,
        scanVerdict: attachment.scanVerdict,
        riskFlags: attachment.riskFlags,
        scannerVersion: attachment.scannerVersion,
        rulesVersion: attachment.rulesVersion,
        createdAt: blob.createdAt
      )
    }

    return .applied(
      Message(
        id: normalizedBlobMessageId,
        conversationId: resolvedConversationId,
        senderId: senderId,
        content: parsed.text,
        type: resolvedType,
        encryptionMode: .e2e,
        encryptionKeyNonce: nil,
        readAt: nil,
        deliveredAt: resolvedDeliveredAt,
        replyToMessageId: normalizedOptionalMessageId(parsed.replyToMessageId),
        forwardedFromMessageId: normalizedOptionalMessageId(parsed.forwardFromMessageId),
        deletedBy: nil,
        deletedAt: nil,
        createdAt: blob.createdAt,
        attachment: resolvedAttachment,
        reactions: nil,
        transportState: isOutgoingMessage ? .accepted : nil,
        transportErrorDetail: nil
      )
    )
  }

  static func isTerminalEnvelopeError(_ error: Error) -> Bool {
    guard let envelopeError = error as? EnvelopeServiceError else {
      return false
    }

    switch envelopeError {
    case .invalidBlob, .decodingFailed:
      return true
    case .encodingFailed:
      return false
    }
  }

  private func sendE2EPayload(
    _ payload: E2EMessagePayload,
    messageId: String = UUID().uuidString
  ) async throws -> OutboundSendExecutionResult {
    await outboundSendGate.enter()
    defer {
      outboundSendGate.leave()
    }

    return try await performSendE2EPayload(payload, messageId: messageId)
  }

  private func performSendE2EPayload(
    _ payload: E2EMessagePayload,
    messageId: String
  ) async throws -> OutboundSendExecutionResult {
    let normalizedOutboundMessageId: String = normalizedMessageId(messageId)
    guard let peerHandle: String = peerUserId else {
      throw ConversationViewModelError.unableToResolveRecipient
    }

    guard let senderHandle: String = currentUserId() else {
      throw ConversationViewModelError.missingCurrentUser
    }

    guard let deviceIdentity: PersistedDeviceIdentity = container.keyMaterialStore.deviceIdentity(for: senderHandle) else {
      throw ConversationViewModelError.missingCurrentUser
    }

    let timestamp = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
    let localDeviceId: String = deviceIdentity.deviceId
    let isCallSignalingPayload: Bool = isCallSignalingMessageType(payload.msgType)
    let isInitialCallOffer: Bool = isInitialCallOfferPayload(payload)
    let peerInventoryResponse = try await container.authService.fetchPrekeys(
      userHandle: peerHandle,
      deviceId: nil,
      peek: true
    )
    let peerTargets: [DeliveryTarget] = try await container.e2eSecurityService.validateBundles(
      peerInventoryResponse.bundles,
      expectedPeerUserId: peerHandle
    ).map {
      DeliveryTarget(
        userHandle: peerHandle,
        bundle: $0
      )
    }

    var selfTargets: [DeliveryTarget] = []
    do {
      let selfInventoryResponse = try await container.authService.fetchSelfPrekeys(deviceId: nil, peek: true)
      selfTargets = try await container.e2eSecurityService.validateBundles(
        selfInventoryResponse.bundles,
        expectedPeerUserId: senderHandle
      )
        .filter { $0.deviceId != localDeviceId }
        .map {
          DeliveryTarget(
            userHandle: senderHandle,
            bundle: $0
          )
        }
    } catch {
      guard isCallSignalingPayload else {
        throw error
      }
      selfTargets = []
    }

    let targets: [DeliveryTarget] = peerTargets + selfTargets
    let availableTargetsByDevice: [String: DeliveryTarget] = Dictionary(
      uniqueKeysWithValues: targets.map {
        (sessionTargetKey(userHandle: $0.userHandle, deviceId: $0.bundle.deviceId), $0)
      }
    )
    guard !peerTargets.isEmpty else {
      throw APIError.server(statusCode: 404, message: "Recipient has no active device bundles")
    }

    let existingSessionsRaw: [RatchetSessionState] = (try? container.ratchetSessionStore.sessions(
      conversationId: conversation.id
    ))?
      .filter { state in
        let key: String = sessionTargetKey(userHandle: state.peerUserHandle, deviceId: state.peerDeviceId)
        return availableTargetsByDevice[key] != nil
      } ?? []

    let existingSessionsByTarget: [String: RatchetSessionState] = {
      let sessionsMatchingCurrentDevice: [RatchetSessionState] = existingSessionsRaw.filter { state in
        guard let stateLocalDeviceId: String = state.localDeviceId?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !stateLocalDeviceId.isEmpty
        else {
          return true
        }

        return stateLocalDeviceId == localDeviceId
      }
      let candidateSessions: [RatchetSessionState] = sessionsMatchingCurrentDevice.isEmpty
        ? existingSessionsRaw
        : sessionsMatchingCurrentDevice
      var uniqueByTarget: [String: RatchetSessionState] = [:]
      for state in candidateSessions {
        let key: String = sessionTargetKey(userHandle: state.peerUserHandle, deviceId: state.peerDeviceId)
        if let current: RatchetSessionState = uniqueByTarget[key] {
          if state.updatedAt > current.updatedAt {
            uniqueByTarget[key] = state
          }
        } else {
          uniqueByTarget[key] = state
        }
      }

      return uniqueByTarget
    }()
    for (targetKey, state) in existingSessionsByTarget where availableTargetsByDevice[targetKey] == nil {
      try? container.ratchetSessionStore.remove(sessionId: state.sessionId)
    }

    var targetStates: [RatchetSessionState] = []
    for target in targets {
      let targetKey: String = sessionTargetKey(userHandle: target.userHandle, deviceId: target.bundle.deviceId)
      if let existing = existingSessionsByTarget[targetKey] {
        targetStates.append(existing)
        continue
      }

      do {
        let bootstrapResponse: FederatedPrekeysGetResponse
        if target.userHandle == senderHandle {
          bootstrapResponse = try await container.authService.fetchSelfPrekeys(
            deviceId: target.bundle.deviceId,
            peek: false
          )
        } else {
          bootstrapResponse = try await container.authService.fetchPrekeys(
            userHandle: target.userHandle,
            deviceId: target.bundle.deviceId,
            peek: false
          )
        }

        guard let bootstrapBundle: FederatedPrekeyBundle = bootstrapResponse.bundles.first(where: {
          $0.deviceId == target.bundle.deviceId
        }) else {
          throw APIError.server(statusCode: 409, message: "Recipient device bundle unavailable")
        }
        let validatedBootstrapBundle: FederatedPrekeyBundle = try await container.e2eSecurityService.validateBundle(
          bootstrapBundle,
          expectedPeerUserId: target.userHandle
        )

        let state = try loadOrCreateRatchetState(
          localUserHandle: senderHandle,
          localDeviceId: localDeviceId,
          peerUserHandle: target.userHandle,
          peerDeviceId: validatedBootstrapBundle.deviceId,
          deviceIdentity: deviceIdentity,
          peerBundle: validatedBootstrapBundle
        )
        targetStates.append(state)
      } catch {
        let isSelfDeliveryTarget: Bool = target.userHandle.lowercased() == senderHandle.lowercased()
        guard isCallSignalingPayload && isSelfDeliveryTarget else {
          throw error
        }
      }
    }

    guard !targetStates.isEmpty else {
      throw APIError.server(statusCode: 404, message: "Recipient has no active device bundles")
    }

    var deliveries: [FederatedDelivery] = []

    for state in targetStates {
      let deliveryPayload: E2EMessagePayload = try targetBoundDeliveryPayload(
        from: payload,
        messageId: normalizedOutboundMessageId,
        targetState: state,
        senderDeviceId: localDeviceId
      )
      let sealed = try container.envelopeService.seal(payload: deliveryPayload, state: state)
      try container.ratchetSessionStore.upsert(sealed.nextState)

      let isPeerDelivery: Bool = state.peerUserHandle.lowercased() != senderHandle.lowercased()
      let pushKind: PushKind? = isInitialCallOffer && isPeerDelivery ? nil : .message
      let wakeupClass: WakeupClass? = isInitialCallOffer && isPeerDelivery ? .voipOpaque : nil

      deliveries.append(
        FederatedDelivery(
          wireVersion: 2,
          deliveryId: UUID().uuidString.lowercased(),
          toServer: domain(from: state.peerUserHandle),
          toUser: state.peerUserHandle,
          toDeviceId: state.peerDeviceId,
          messageId: normalizedOutboundMessageId,
          timestamp: timestamp,
          ttlSec: 7 * 24 * 60 * 60,
          ciphertextBlob: sealed.ciphertextBlob,
          pushKind: pushKind,
          wakeupClass: wakeupClass
        )
      )
    }

    let response = try await container.messageService.sendDeliveries(deliveries)
    let senderHandleNormalized: String = senderHandle.lowercased()
    let successfulStatuses: Set<String> = [
      "accepted",
      "acked",
      "queued_federation",
      "queued_local",
    ]
    var resultsByDeliveryId: [String: String] = [:]
    for result in response.results {
      resultsByDeliveryId[result.deliveryId] = result.status.lowercased()
    }
    let peerDeliveries: [FederatedDelivery] = deliveries.filter {
      $0.toUser.lowercased() != senderHandleNormalized
    }
    let successfulPeerDeliveryCount: Int = peerDeliveries.filter { delivery in
      guard let status: String = resultsByDeliveryId[delivery.deliveryId] else {
        return false
      }

      return successfulStatuses.contains(status)
    }.count
    let failures: [String] = deliveries.compactMap { delivery in
      guard let status: String = resultsByDeliveryId[delivery.deliveryId] else {
        return "\(delivery.toDeviceId):missing"
      }
      guard successfulStatuses.contains(status) else {
        return "\(delivery.toDeviceId):\(status)"
      }
      return nil
    }

    if failures.isEmpty {
      return OutboundSendExecutionResult(
        messageId: normalizedOutboundMessageId,
        transportState: .accepted,
        errorDetail: nil,
        attemptedPeerDeliveryCount: peerDeliveries.count,
        successfulPeerDeliveryCount: successfulPeerDeliveryCount
      )
    }

    return OutboundSendExecutionResult(
      messageId: normalizedOutboundMessageId,
      transportState: .partialFailure,
      errorDetail: "Delivery incomplete for \(failures.joined(separator: ", "))",
      attemptedPeerDeliveryCount: peerDeliveries.count,
      successfulPeerDeliveryCount: successfulPeerDeliveryCount
    )
  }

  private func targetBoundDeliveryPayload(
    from payload: E2EMessagePayload,
    messageId: String,
    targetState: RatchetSessionState,
    senderDeviceId: String
  ) throws -> E2EMessagePayload {
    guard isCallSignalingMessageType(payload.msgType) else {
      return payload
    }

    guard let bodyPayload: [String: Any] = jsonObject(from: payload.body),
      let callId: String = CallSignalParser.callId(from: bodyPayload)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !callId.isEmpty
    else {
      throw ConversationViewModelError.invalidAttachmentData
    }

    let transcriptKey: String = callTranscriptTargetKey(
      callId: callId,
      userHandle: targetState.peerUserHandle,
      deviceId: targetState.peerDeviceId
    )
    let payloadCacheKey: String = callDeliveryPayloadBodyCacheKey(
      messageId: messageId,
      transcriptKey: transcriptKey
    )
    if let cachedBody: String = callDeliveryPayloadBodiesByMessageAndTarget[payloadCacheKey] {
      return E2EMessagePayload(
        conversationId: payload.conversationId,
        msgType: payload.msgType,
        body: cachedBody,
        attachments: payload.attachments,
        padding: payload.padding
      )
    }

    var transcriptState: CallSignalEnvelope.TranscriptState =
      callDeliveryTranscriptStatesByTarget[transcriptKey] ?? CallSignalEnvelope.TranscriptState()
    let preparedPayload: [String: Any] = CallSignalEnvelope.prepareOutgoingPayload(
      bodyPayload,
      callId: callId,
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetState.peerDeviceId,
      state: &transcriptState
    )
    guard JSONSerialization.isValidJSONObject(preparedPayload),
      let bodyData: Data = try? JSONSerialization.data(withJSONObject: preparedPayload, options: []),
      let body: String = String(data: bodyData, encoding: .utf8)
    else {
      throw ConversationViewModelError.invalidAttachmentData
    }

    if payload.msgType == Message.MessageType.callEnd.rawValue {
      callDeliveryTranscriptStatesByTarget.removeValue(forKey: transcriptKey)
    } else {
      callDeliveryTranscriptStatesByTarget[transcriptKey] = transcriptState
    }
    callDeliveryPayloadBodiesByMessageAndTarget[payloadCacheKey] = body

    return E2EMessagePayload(
      conversationId: payload.conversationId,
      msgType: payload.msgType,
      body: body,
      attachments: payload.attachments,
      padding: payload.padding
    )
  }

  private func callDeliveryPayloadBodyCacheKey(messageId: String, transcriptKey: String) -> String {
    "\(normalizedMessageId(messageId))|\(transcriptKey)"
  }

  private func clearCallDeliveryPayloadBodyCache(messageId: String) {
    let prefix: String = "\(normalizedMessageId(messageId))|"
    for key in Array(callDeliveryPayloadBodiesByMessageAndTarget.keys) where key.hasPrefix(prefix) {
      callDeliveryPayloadBodiesByMessageAndTarget.removeValue(forKey: key)
    }
  }

  private func isInitialCallOfferPayload(_ payload: E2EMessagePayload) -> Bool {
    guard payload.msgType == Message.MessageType.callOffer.rawValue else {
      return false
    }

    guard let bodyData: Data = payload.body.data(using: .utf8),
      let object: Any = try? JSONSerialization.jsonObject(with: bodyData, options: []),
      let body: [String: Any] = object as? [String: Any]
    else {
      return true
    }

    let rawOfferKind: String?
    switch body["offer_kind"] ?? body["offerKind"] {
    case let string as String:
      rawOfferKind = string
    case let number as NSNumber:
      rawOfferKind = number.stringValue
    default:
      rawOfferKind = nil
    }

    let offerKind: String = rawOfferKind?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "initial"
    return offerKind == "initial"
  }

  private func shouldDropInvalidCallPayload(
    _ inspected: InspectedMailboxBlob,
    ownerDeviceId: String
  ) -> Bool {
    guard isCallSignalingMessageType(inspected.payload.msgType) else {
      return false
    }

    let localDeviceId: String? = inspected.nextState.localDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ownerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    let senderDeviceId: String = inspected.header.senderDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bodyPayload: [String: Any] = jsonObject(from: inspected.payload.body),
      CallSignalParser.hasValidEnvelope(bodyPayload),
      CallSignalParser.isTargeted(to: localDeviceId, payload: bodyPayload),
      CallSignalParser.senderDeviceId(from: bodyPayload) == senderDeviceId
    else {
      return true
    }

    return false
  }

  private func jsonObject(from raw: String) -> [String: Any]? {
    guard let bodyData: Data = raw.data(using: .utf8),
      let object: Any = try? JSONSerialization.jsonObject(with: bodyData, options: []),
      let payload: [String: Any] = object as? [String: Any]
    else {
      return nil
    }

    return payload
  }

  private func loadOrCreateRatchetState(
    localUserHandle: String,
    localDeviceId: String,
    peerUserHandle: String,
    peerDeviceId: String,
    deviceIdentity: PersistedDeviceIdentity,
    peerBundle: FederatedPrekeyBundle
  ) throws -> RatchetSessionState {
    let initialState = try container.x3dhService.initiateSession(
      deviceIdentity: deviceIdentity,
      localUserHandle: localUserHandle,
      peerBundle: peerBundle,
      conversationId: conversation.id
    )

    let state = RatchetSessionState(
      sessionStateVersion: initialState.sessionStateVersion,
      sessionId: initialState.sessionId,
      conversationId: initialState.conversationId,
      localUserHandle: initialState.localUserHandle,
      localDeviceId: localDeviceId,
      localIkDhPublic: initialState.localIkDhPublic,
      peerUserHandle: peerUserHandle,
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: peerBundle.deviceDhPub,
      rootKey: initialState.rootKey,
      sendChainKey: initialState.sendChainKey,
      receiveChainKey: initialState.receiveChainKey,
      sendCounter: initialState.sendCounter,
      receiveCounter: initialState.receiveCounter,
      previousChainLength: initialState.previousChainLength,
      bootstrapDhPub: initialState.bootstrapDhPub,
      localRatchetPriv: initialState.localRatchetPriv,
      localRatchetPub: initialState.localRatchetPub,
      remoteRatchetPub: initialState.remoteRatchetPub,
      signedPrekeyId: peerBundle.signedPrekey.prekeyId,
      oneTimePrekeyId: peerBundle.oneTimePrekey?.prekeyId,
      skippedMessageKeys: initialState.skippedMessageKeys,
      createdAt: initialState.createdAt,
      updatedAt: initialState.updatedAt
    )

    try container.ratchetSessionStore.upsert(state)
    return state
  }

  static func inspectMailboxBlob(
    container: AppContainer,
    blob: FederatedMailboxBlob
  ) async throws -> InspectedMailboxBlob? {
    let envelope = try container.envelopeService.decodeEnvelope(ciphertextBlob: blob.ciphertextBlob)

    if let existing = try container.ratchetSessionStore.session(sessionId: envelope.sessionId) {
      let opened = try container.envelopeService.open(ciphertextBlob: blob.ciphertextBlob, state: existing)
      return InspectedMailboxBlob(
        envelope: envelope,
        header: opened.header,
        payload: opened.payload,
        nextState: opened.nextState,
        consumedOneTimePrekeyId: nil
      )
    }

    guard envelope.kind == .prekeyInit,
      let ephemeralPub: String = envelope.ephemeralPub?.trimmingCharacters(in: .whitespacesAndNewlines),
      !ephemeralPub.isEmpty,
      let senderDeviceDhPub: String = envelope.senderDeviceDhPub?.trimmingCharacters(in: .whitespacesAndNewlines),
      !senderDeviceDhPub.isEmpty,
      let signedPrekeyId: String = envelope.signedPrekeyId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !signedPrekeyId.isEmpty,
      let localUserHandle: String = resolvedCurrentUserHandle(container: container),
      let deviceIdentity: PersistedDeviceIdentity = container.keyMaterialStore.deviceIdentity(for: localUserHandle)
    else {
      return nil
    }

    let provisionalState: RatchetSessionState
    do {
      provisionalState = try container.x3dhService.receiveSession(
        deviceIdentity: deviceIdentity,
        localUserHandle: localUserHandle,
        prekeyPrivateStore: container.prekeyPrivateStore,
        ephemeralPub: ephemeralPub,
        senderDeviceDhPub: senderDeviceDhPub,
        signedPrekeyId: signedPrekeyId,
        oneTimePrekeyId: envelope.oneTimePrekeyId,
        sessionId: envelope.sessionId,
        conversationId: "__pending__",
        peerUserHandle: "__pending__",
        peerDeviceId: "__pending__"
      )
    } catch {
      throw error
    }

    let opened = try container.envelopeService.openInitial(ciphertextBlob: blob.ciphertextBlob, state: provisionalState)
    let senderUserHandle: String = opened.header.senderUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let senderDeviceId: String = opened.header.senderDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !senderUserHandle.isEmpty, !senderDeviceId.isEmpty else {
      return nil
    }

    let bundleResponse: FederatedPrekeysGetResponse
    if senderUserHandle == localUserHandle {
      bundleResponse = try await container.authService.fetchSelfPrekeys(deviceId: senderDeviceId, peek: true)
    } else {
      bundleResponse = try await container.authService.fetchPrekeys(
        userHandle: senderUserHandle,
        deviceId: senderDeviceId,
        peek: true
      )
    }

    guard let fetchedBundle: FederatedPrekeyBundle = bundleResponse.bundles.first(where: {
      $0.deviceId == senderDeviceId
    }) else {
      return nil
    }

    let validatedBundle: FederatedPrekeyBundle = try await container.e2eSecurityService.validateBundle(
      fetchedBundle,
      expectedPeerUserId: senderUserHandle
    )
    guard validatedBundle.deviceDhPub == senderDeviceDhPub else {
      return nil
    }

    let finalizedState = RatchetSessionState(
      sessionStateVersion: opened.nextState.sessionStateVersion,
      sessionId: opened.nextState.sessionId,
      conversationId: opened.header.conversationId,
      localUserHandle: localUserHandle,
      localDeviceId: deviceIdentity.deviceId,
      localIkDhPublic: deviceIdentity.dkDhPublic,
      peerUserHandle: senderUserHandle,
      peerDeviceId: senderDeviceId,
      peerIkDhPublic: senderDeviceDhPub,
      rootKey: opened.nextState.rootKey,
      sendChainKey: opened.nextState.sendChainKey,
      receiveChainKey: opened.nextState.receiveChainKey,
      sendCounter: opened.nextState.sendCounter,
      receiveCounter: opened.nextState.receiveCounter,
      previousChainLength: opened.nextState.previousChainLength,
      bootstrapDhPub: nil,
      localRatchetPriv: opened.nextState.localRatchetPriv,
      localRatchetPub: opened.nextState.localRatchetPub,
      remoteRatchetPub: opened.nextState.remoteRatchetPub,
      signedPrekeyId: nil,
      oneTimePrekeyId: nil,
      skippedMessageKeys: opened.nextState.skippedMessageKeys,
      createdAt: opened.nextState.createdAt,
      updatedAt: opened.nextState.updatedAt
    )

    return InspectedMailboxBlob(
      envelope: envelope,
      header: opened.header,
      payload: opened.payload,
      nextState: finalizedState,
      consumedOneTimePrekeyId: envelope.oneTimePrekeyId?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private func randomPadding() -> String {
    let count = Int.random(in: 8...32)
    return String(repeating: "0", count: count)
  }

  private func sessionTargetKey(userHandle: String, deviceId: String) -> String {
    "\(userHandle.lowercased())|\(deviceId)"
  }

  private func callTranscriptTargetKey(callId: String, userHandle: String, deviceId: String) -> String {
    "\(callId.lowercased())|\(sessionTargetKey(userHandle: userHandle, deviceId: deviceId))"
  }

  private func domain(from handle: String) -> String {
    guard let index = handle.firstIndex(of: ":") else {
      return "localhost"
    }
    return String(handle[handle.index(after: index)...])
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

  private func updateConversationIdIfNeeded(_ envelopeConversationId: String, senderUserHandle: String) {
    guard conversation.type == .direct
    else {
      return
    }

    let targetConversationId: String
    if let localUserHandle: String = currentUserId() {
      targetConversationId = directConversationId(
        localUserHandle: localUserHandle,
        peerUserHandle: senderUserHandle
      )
    } else {
      targetConversationId = envelopeConversationId
    }

    guard conversation.id != targetConversationId else {
      return
    }

    let updatedParticipants = conversation.participants?.map { participant in
      ConversationParticipant(
        id: participant.id,
        conversationId: targetConversationId,
        userId: participant.userId,
        joinedAt: participant.joinedAt,
        role: participant.role
      )
    }

    conversation = Conversation(
      id: targetConversationId,
      type: conversation.type,
      name: conversation.name ?? senderUserHandle,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      participants: updatedParticipants
    )
  }

  private func currentUserId() -> String? {
    Self.resolvedCurrentUserHandle(container: container)
  }

  private func currentDeviceId() -> String? {
    guard let userId = currentUserId() else {
      return nil
    }
    return container.keyMaterialStore.deviceId(for: userId)
  }

  private func currentSenderDeviceId() -> String? {
    guard let userHandle: String = currentUserId() else {
      return nil
    }

    return currentDeviceId() ?? fallbackDeviceId(for: userHandle)
  }

  private func resolvedSeedPhrase(for userHandle: String) throws -> String {
    let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: userHandle,
      sessionUser: container.sessionStore.currentUser
    )
    guard let resolvedSeed = container.keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds) else {
      throw ConversationViewModelError.missingSeedPhrase
    }

    if resolvedSeed.userId != userHandle {
      container.keyMaterialStore.saveSeedPhrase(resolvedSeed.seedPhrase, for: userHandle)
      container.keyMaterialStore.setCurrentUserId(userHandle)
    }

    return resolvedSeed.seedPhrase
  }

  private static func resolvedCurrentUserHandle(container: AppContainer) -> String? {
    let sessionUser: SessionUser? = container.sessionStore.currentUser
    let candidates: [String?] = [
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

    return sessionUser?.id
  }

  private func resolveAttachmentPreview(messageId: String) async throws -> PreparedAttachmentPreview {
    guard let message: Message = message(matching: messageId),
      let attachment: FileAttachment = message.attachment,
      let originServer: String = attachment.originServer,
      let downloadCapability: String = attachment.downloadCapability,
      let fileKey: String = attachment.fileKey,
      let hashCipherFile: String = attachment.hashCipherFile
    else {
      throw AttachmentInspectionError.invalidAttachmentMetadata
    }

    let request = AttachmentPreviewRequest(
      mediaId: attachment.id,
      originServer: originServer,
      downloadCapability: downloadCapability,
      fileKey: fileKey,
      expectedCiphertextHash: hashCipherFile,
      fileName: attachment.fileName ?? message.content,
      mimeType: attachment.mimeType
    )
    return try await container.attachmentPreviewService.resolvePreview(for: request)
  }

  private func fallbackDeviceId(for userHandle: String) -> String {
    let raw: String = userHandle.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    let suffix: String = String(raw.prefix(12))
    return suffix.isEmpty ? "device" : "dev-\(suffix)"
  }

  private func decodeUserPayload(
    _ body: String
  ) -> (text: String, replyToMessageId: String?, replyPreviewText: String?, forwardFromMessageId: String?) {
    guard let data: Data = body.data(using: .utf8),
      let decoded: UserTextPayload = try? JSONCoding.decoder.decode(UserTextPayload.self, from: data)
    else {
      return (body, nil, nil, nil)
    }

    return (decoded.text, decoded.replyToMessageId, decoded.replyPreviewText, decoded.forwardFromMessageId)
  }

  private func decodeControlPayload(_ message: Message) -> ControlPayload? {
    guard let data: Data = message.content.data(using: .utf8),
      let decoded: ControlPayload = try? JSONCoding.decoder.decode(ControlPayload.self, from: data)
    else {
      return nil
    }

    return decoded
  }

  private func isControlMessageType(_ rawType: String) -> Bool {
    rawType.hasPrefix("msg_")
  }

  private func isControlMessage(_ message: Message) -> Bool {
    message.type == .system && decodeControlPayload(message) != nil
  }

  private func sendControlMessage(type: String, payload: ControlPayload) async throws {
    let encoded: Data = try JSONCoding.encoder.encode(payload)
    let body: String = String(data: encoded, encoding: .utf8) ?? "{}"

    let e2ePayload = E2EMessagePayload(
      conversationId: conversation.id,
      msgType: type,
      body: body,
      attachments: [],
      padding: randomPadding()
    )

    let result = try await sendE2EPayload(e2ePayload)
    guard result.transportState == .accepted else {
      throw APIError.server(
        statusCode: 502,
        message: result.errorDetail ?? "Control message delivery incomplete"
      )
    }
  }

  private func sendReadReceipts(messageIds: [String], markLocally: Bool) async throws {
    let requestedMessageIds: [String] = deduplicatedMessageIds(messageIds)
    guard !requestedMessageIds.isEmpty else {
      return
    }

    let now: Date = Date()
    let unsentMessageIds: [String] = requestedMessageIds.filter { !sentReadReceipts.contains($0) }

    if markLocally {
      _ = applyReadLocally(messageIds: requestedMessageIds, at: now)
    }

    for messageId in unsentMessageIds {
      pendingReadReceipts.insert(messageId)
    }

    persistMessages()
    persistSentReadReceipts()
    persistPendingReadReceipts()

    guard !unsentMessageIds.isEmpty else {
      return
    }

    logReadReceipt("queued msg_read ids=\(unsentMessageIds.count)")
    _ = await flushPendingReadReceiptsIfNeeded()
  }

  private func applyControlMessages(_ controls: [Message]) -> [Message] {
    var unresolved: [Message] = []

    for controlMessage in controls.sorted(by: { $0.createdAt < $1.createdAt }) {
      guard let control: ControlPayload = decodeControlPayload(controlMessage) else {
        continue
      }

      switch control.action {
      case "edit":
        guard let targetId: String = control.targetMessageId.map(normalizedMessageId),
          let newContent: String = control.content,
          let index: Int = messageIndex(for: targetId)
        else {
          unresolved.append(controlMessage)
          continue
        }

        let current = messages[index]
        if current.content != newContent {
          appendEditHistory(
            messageId: targetId,
            oldContent: current.content,
            editedBy: control.actorUserId ?? current.senderId,
            editedAt: control.at ?? controlMessage.createdAt
          )
        }

        messages[index] = Message(
          id: current.id,
          conversationId: current.conversationId,
          senderId: current.senderId,
          content: newContent,
          type: current.type,
          encryptionMode: current.encryptionMode,
          encryptionKeyNonce: current.encryptionKeyNonce,
          readAt: current.readAt,
          deliveredAt: current.deliveredAt,
          replyToMessageId: current.replyToMessageId,
          forwardedFromMessageId: current.forwardedFromMessageId,
          deletedBy: current.deletedBy,
          deletedAt: current.deletedAt,
          createdAt: current.createdAt,
          attachment: current.attachment,
          reactions: current.reactions,
          transportState: current.transportState,
          transportErrorDetail: current.transportErrorDetail
        )

      case "delete_for_all":
        guard let targetId: String = control.targetMessageId.map(normalizedMessageId) else {
          continue
        }
        applyDeleteForAll(messageId: targetId, deletedBy: control.actorUserId, deletedAt: control.at ?? Date())

      case "read":
        let ids: [String] = deduplicatedMessageIds(control.messageIds ?? [])
        guard !ids.isEmpty else {
          continue
        }
        let readAt: Date = control.at ?? Date()
        let outcome = applyReadLocally(messageIds: ids, at: readAt)
        logReadReceipt(
          "applied incoming msg_read ids=\(ids.count) changed=\(outcome.didChange) missing=\(outcome.missingMessageIds.count)"
        )
        if !outcome.missingMessageIds.isEmpty {
          unresolved.append(controlMessage)
        }

      case "reaction":
        guard let targetId: String = control.targetMessageId.map(normalizedMessageId),
          let emoji: String = control.emoji,
          let reactionAction: String = control.reactionAction,
          let index: Int = messageIndex(for: targetId)
        else {
          unresolved.append(controlMessage)
          continue
        }

        let actor: String = control.actorUserId ?? peerUserId ?? "peer"
        var reactions: [MessageReaction] = messages[index].reactions ?? []
        if reactionAction == "remove" {
          reactions.removeAll(where: { $0.userId == actor && $0.emoji == emoji })
        } else {
          reactions.removeAll(where: { $0.userId == actor && $0.emoji == emoji })
          reactions.append(
            MessageReaction(
              id: nil,
              messageId: targetId,
              userId: actor,
              emoji: emoji,
              createdAt: control.at
            )
          )
        }
        messages[index].reactions = reactions

      case "pin":
        guard let targetId: String = control.targetMessageId.map(normalizedMessageId) else {
          continue
        }

        if !pinnedMessages.contains(where: { normalizedMessageId($0.messageId) == targetId }) {
          pinnedMessages.insert(
            PinnedMessage(
              id: UUID().uuidString,
              conversationId: conversation.id,
              messageId: targetId,
              pinnedBy: control.actorUserId ?? peerUserId ?? "peer",
              pinnedAt: control.at ?? Date(),
              previewText: normalizedPreviewText(control.content) ?? pinnedMessagePreviewText(targetId),
              messageCreatedAt: control.messageCreatedAt ?? message(matching: targetId)?.createdAt
            ),
            at: 0
          )
        }

      case "unpin":
        guard let targetId: String = control.targetMessageId.map(normalizedMessageId) else {
          continue
        }
        hiddenPinnedMessageIds.remove(targetId)
        pinnedMessages.removeAll(where: { normalizedMessageId($0.messageId) == targetId })

      default:
        break
      }
    }

    return unresolved
  }

  private func appendEditHistory(messageId: String, oldContent: String) {
    appendEditHistory(
      messageId: messageId,
      oldContent: oldContent,
      editedBy: currentUserId() ?? "local",
      editedAt: Date()
    )
  }

  private func appendEditHistory(messageId: String, oldContent: String, editedBy: String, editedAt: Date) {
    let normalizedTargetMessageId: String = normalizedMessageId(messageId)
    let edit = MessageEdit(
      id: UUID().uuidString,
      messageId: normalizedTargetMessageId,
      oldContent: oldContent,
      editedBy: editedBy,
      editedAt: editedAt
    )

    var edits: [MessageEdit] = editsByMessageId[normalizedTargetMessageId] ?? []
    edits.append(edit)
    editsByMessageId[normalizedTargetMessageId] = edits.sorted(by: { $0.editedAt > $1.editedAt })
  }

  private func applyDeleteForAll(messageId: String, deletedBy: String?, deletedAt: Date) {
    let normalizedTargetMessageId: String = normalizedMessageId(messageId)
    guard let index: Int = messageIndex(for: normalizedTargetMessageId) else {
      hiddenMessageIds.insert(normalizedTargetMessageId)
      volatileDeletedMessageIds.remove(normalizedTargetMessageId)
      replyPreviewByReplyMessageId.removeValue(forKey: normalizedTargetMessageId)
      return
    }

    let current = messages[index]
    let normalizedCurrentUserId: String? = currentUserId()?.lowercased()
    let normalizedDeletedBy: String? = deletedBy?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let deletedByCurrentUser: Bool = {
      guard let normalizedDeletedBy,
        let normalizedCurrentUserId
      else {
        return isOutgoing(current)
      }

      return normalizedDeletedBy == normalizedCurrentUserId
    }()
    if deletedByCurrentUser {
      messages.remove(at: index)
      hiddenMessageIds.insert(normalizedTargetMessageId)
      volatileDeletedMessageIds.remove(normalizedTargetMessageId)
      replyPreviewByReplyMessageId.removeValue(forKey: normalizedTargetMessageId)
      totalCount = messages.count
      return
    }

    volatileDeletedMessageIds.insert(normalizedTargetMessageId)
    messages[index] = Message(
      id: current.id,
      conversationId: current.conversationId,
      senderId: current.senderId,
      content: "Сообщение удалено",
      type: current.type,
      encryptionMode: current.encryptionMode,
      encryptionKeyNonce: current.encryptionKeyNonce,
      readAt: current.readAt,
      deliveredAt: current.deliveredAt,
      replyToMessageId: current.replyToMessageId,
      forwardedFromMessageId: current.forwardedFromMessageId,
      deletedBy: deletedBy,
      deletedAt: deletedAt,
      createdAt: current.createdAt,
      attachment: nil,
      reactions: [],
      transportState: current.transportState,
      transportErrorDetail: current.transportErrorDetail
    )
  }

  private func mergeMessages(_ existing: [Message], _ incoming: [Message]) -> [Message] {
    var byId: [String: Message] = [:]

    for message in existing {
      let normalizedExistingMessage: Message = normalizedMessage(message)
      byId[normalizedExistingMessage.id] = normalizedExistingMessage
    }

    for message in incoming {
      let normalizedIncomingMessage: Message = normalizedMessage(message)
      if hiddenMessageIds.contains(normalizedIncomingMessage.id) {
        continue
      }

      guard let current: Message = byId[normalizedIncomingMessage.id] else {
        byId[normalizedIncomingMessage.id] = normalizedIncomingMessage
        continue
      }

      if current.content != "[Encrypted message]",
        normalizedIncomingMessage.content == "[Encrypted message]"
      {
        continue
      }

      let outgoingDeliveredAt: Date? = {
        guard let localUserId: String = currentUserId(),
          normalizedIncomingMessage.senderId.lowercased() == localUserId.lowercased()
        else {
          return nil
        }

        return normalizedIncomingMessage.deliveredAt ?? current.deliveredAt ?? normalizedIncomingMessage.createdAt
      }()
      let mergedTransportState: Message.OutboundTransportState? = {
        if normalizedIncomingMessage.readAt != nil || outgoingDeliveredAt != nil {
          return .accepted
        }

        return normalizedIncomingMessage.transportState ?? current.transportState
      }()
      let mergedTransportErrorDetail: String? = {
        switch mergedTransportState {
        case .accepted, .pending, .none:
          return nil
        case .partialFailure, .failed:
          return normalizedIncomingMessage.transportErrorDetail ?? current.transportErrorDetail
        }
      }()

      byId[normalizedIncomingMessage.id] = Message(
        id: normalizedIncomingMessage.id,
        conversationId: normalizedIncomingMessage.conversationId,
        senderId: normalizedIncomingMessage.senderId,
        content: normalizedIncomingMessage.content,
        type: normalizedIncomingMessage.type,
        encryptionMode: normalizedIncomingMessage.encryptionMode ?? current.encryptionMode,
        encryptionKeyNonce: normalizedIncomingMessage.encryptionKeyNonce ?? current.encryptionKeyNonce,
        readAt: normalizedIncomingMessage.readAt ?? current.readAt,
        deliveredAt: outgoingDeliveredAt ?? normalizedIncomingMessage.deliveredAt ?? current.deliveredAt,
        replyToMessageId: normalizedIncomingMessage.replyToMessageId ?? current.replyToMessageId,
        forwardedFromMessageId: normalizedIncomingMessage.forwardedFromMessageId ?? current.forwardedFromMessageId,
        deletedBy: normalizedIncomingMessage.deletedBy ?? current.deletedBy,
        deletedAt: normalizedIncomingMessage.deletedAt ?? current.deletedAt,
        createdAt: normalizedIncomingMessage.createdAt,
        attachment: normalizedIncomingMessage.attachment ?? current.attachment,
        reactions: normalizedIncomingMessage.reactions ?? current.reactions,
        transportState: mergedTransportState,
        transportErrorDetail: mergedTransportErrorDetail
      )
    }

    return byId.values.sorted { lhs, rhs in
      lhs.createdAt > rhs.createdAt
    }
  }

  private func applyHydratedMessages(
    _ hydrated: [Message],
    replaceExisting: Bool,
    source: MailboxIngestionSource
  ) async throws {
    var visibleHydrated: [Message] = []
    var controlMessages: [Message] = []

    for message in hydrated {
      if isControlMessage(message) {
        controlMessages.append(message)
      } else {
        visibleHydrated.append(message)
      }
    }

    let base: [Message] = replaceExisting ? loadPersistedMessages() : messages
    messages = mergeMessages(base, visibleHydrated)
    let combinedControls: [Message] = deferredControlMessages + controlMessages
    deferredControlMessages = applyControlMessages(combinedControls)
    messages = messages.filter { !hiddenMessageIds.contains($0.id) }
    totalCount = messages.count

    if isVisibleConversation {
      _ = await autoMarkVisibleConversationAsReadIfNeeded(notifyAfterChange: false)
    }

    persistMessages()
    persistEdits()
    persistReplyPreviews()
    persistPinnedMessages()
    persistHiddenPinnedMessageIds()
    persistHiddenMessageIds()
    persistSentReadReceipts()
    persistDeferredControlMessages()
  }

  private func persistedMessagesStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.messageHistoryPrefix).\(suffix)"
  }

  private func persistedEditsStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.editHistoryPrefix).\(suffix)"
  }

  private func persistedReplyPreviewStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.replyPreviewPrefix).\(suffix)"
  }

  private func persistedPinnedStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.pinnedMessagesPrefix).\(suffix)"
  }

  private func persistedHiddenPinnedStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.hiddenPinnedMessagesPrefix).\(suffix)"
  }

  private func persistedHiddenMessagesStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.hiddenMessagesPrefix).\(suffix)"
  }

  private func persistedReadReceiptsStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.sentReadReceiptsPrefix).\(suffix)"
  }

  private func persistedPendingReadReceiptsStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.pendingReadReceiptsPrefix).\(suffix)"
  }

  private func persistedDeferredControlsStorageKey() -> String {
    let owner: String = currentUserId()?.lowercased() ?? "anonymous"
    let rawKey: String = "\(owner)|\(conversation.id.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.deferredControlsPrefix).\(suffix)"
  }

  private func loadPersistedMessages() -> [Message] {
    guard let stored: [Message] = loadPersistedValue([Message].self, key: persistedMessagesStorageKey()) else {
      return []
    }

    return stored
      .map(normalizedMessage)
      .filter { $0.conversationId == conversation.id }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private func persistMessages() {
    let persistedMessages: [Message] = messages
      .map(normalizedMessage)
      .filter { !volatileDeletedMessageIds.contains($0.id) }
    let capped: [Message] = Array(persistedMessages.prefix(StorageKeys.maxStoredMessagesPerConversation))
    persistPersistedValue(capped, key: persistedMessagesStorageKey())
  }

  private func loadPersistedEdits() -> [String: [MessageEdit]] {
    guard let edits: [String: [MessageEdit]] = loadPersistedValue(
      [String: [MessageEdit]].self,
      key: persistedEditsStorageKey()
    ) else {
      return [:]
    }

    return normalizeEditsByMessageId(edits)
  }

  private func loadPersistedReplyPreviews() -> [String: String] {
    guard let previews: [String: String] = loadPersistedValue(
      [String: String].self,
      key: persistedReplyPreviewStorageKey()
    ) else {
      return [:]
    }

    return normalizeReplyPreviews(previews)
  }

  private func persistEdits() {
    let normalizedEditsByMessageId: [String: [MessageEdit]] = normalizeEditsByMessageId(editsByMessageId)
    editsByMessageId = normalizedEditsByMessageId
    persistPersistedValue(normalizedEditsByMessageId, key: persistedEditsStorageKey())
  }

  private func persistReplyPreviews() {
    let visibleMessageIds: Set<String> = Set(messages.map(\.id))
    replyPreviewByReplyMessageId = normalizeReplyPreviews(replyPreviewByReplyMessageId).filter { key, _ in
      visibleMessageIds.contains(key) && !hiddenMessageIds.contains(key) && !volatileDeletedMessageIds.contains(key)
    }

    persistPersistedValue(replyPreviewByReplyMessageId, key: persistedReplyPreviewStorageKey())
  }

  private func loadPersistedPinnedMessages() -> [PinnedMessage] {
    guard let pinned: [PinnedMessage] = loadPersistedValue([PinnedMessage].self, key: persistedPinnedStorageKey()) else {
      return []
    }

    return pinned.map(normalizedPinnedMessage)
  }

  private func persistPinnedMessages() {
    pinnedMessages = pinnedMessages.map(normalizedPinnedMessage)
    persistPersistedValue(pinnedMessages, key: persistedPinnedStorageKey())
  }

  private func loadHiddenPinnedMessageIds() -> Set<String> {
    guard let ids: [String] = loadPersistedValue([String].self, key: persistedHiddenPinnedStorageKey()) else {
      return []
    }

    return Set(ids.map(normalizedMessageId))
  }

  private func persistHiddenPinnedMessageIds() {
    hiddenPinnedMessageIds = Set(hiddenPinnedMessageIds.map(normalizedMessageId))
    let ids: [String] = Array(hiddenPinnedMessageIds)
    persistPersistedValue(ids, key: persistedHiddenPinnedStorageKey())
  }

  private func loadHiddenMessageIds() -> Set<String> {
    guard let ids: [String] = loadPersistedValue([String].self, key: persistedHiddenMessagesStorageKey()) else {
      return []
    }

    return Set(ids.map(normalizedMessageId))
  }

  private func persistHiddenMessageIds() {
    hiddenMessageIds = Set(hiddenMessageIds.map(normalizedMessageId))
    let ids: [String] = Array(hiddenMessageIds)
    persistPersistedValue(ids, key: persistedHiddenMessagesStorageKey())
  }

  private func loadSentReadReceipts() -> Set<String> {
    guard let ids: [String] = loadPersistedValue([String].self, key: persistedReadReceiptsStorageKey()) else {
      return []
    }

    return Set(ids.map(normalizedMessageId))
  }

  private func persistSentReadReceipts() {
    sentReadReceipts = Set(sentReadReceipts.map(normalizedMessageId))
    let ids: [String] = Array(sentReadReceipts)
    persistPersistedValue(ids, key: persistedReadReceiptsStorageKey())
  }

  private func loadPendingReadReceipts() -> Set<String> {
    guard let ids: [String] = loadPersistedValue([String].self, key: persistedPendingReadReceiptsStorageKey()) else {
      return []
    }

    return Set(ids.map(normalizedMessageId))
  }

  private func persistPendingReadReceipts() {
    pendingReadReceipts = Set(pendingReadReceipts.map(normalizedMessageId))
    let ids: [String] = Array(pendingReadReceipts)
    persistPersistedValue(ids, key: persistedPendingReadReceiptsStorageKey())
  }

  private func loadPersistedDeferredControlMessages() -> [Message] {
    guard let stored: [Message] = loadPersistedValue([Message].self, key: persistedDeferredControlsStorageKey()) else {
      return []
    }

    return stored
      .map(normalizedMessage)
      .filter { $0.conversationId == conversation.id }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private func persistDeferredControlMessages() {
    deferredControlMessages = deferredControlMessages.map(normalizedMessage)
    persistPersistedValue(deferredControlMessages, key: persistedDeferredControlsStorageKey())
  }

  private func loadPersistedValue<T: Codable>(_ type: T.Type, key: String) -> T? {
    if let storageKey = resolvedStorageKey(),
      let value = try? container.secureStateStore.load(type, for: key, storageKey: storageKey)
    {
      return value
    }

    guard let data: Data = defaults.data(forKey: key),
      let legacyValue: T = try? JSONCoding.decoder.decode(type, from: data)
    else {
      return nil
    }

    migrateLegacyPersistedValueIfNeeded(legacyValue, key: key)
    return legacyValue
  }

  private func persistPersistedValue<T: Codable>(_ value: T, key: String) {
    if let storageKey = resolvedStorageKey() {
      do {
        try container.secureStateStore.save(value, for: key, storageKey: storageKey)
        defaults.removeObject(forKey: key)
        return
      } catch {
        // Fallback to legacy storage if secure persistence fails.
      }
    }

    guard let encoded: Data = try? JSONCoding.encoder.encode(value) else {
      return
    }

    defaults.set(encoded, forKey: key)
  }

  private func migrateLegacyPersistedValueIfNeeded<T: Codable>(_ value: T, key: String) {
    guard let storageKey = resolvedStorageKey() else {
      return
    }

    do {
      try container.secureStateStore.save(value, for: key, storageKey: storageKey)
      defaults.removeObject(forKey: key)
    } catch {
      // Keep plaintext fallback if secure migration fails.
    }
  }

  private func resolvedStorageKey() -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: currentUserId(),
      sessionUser: container.sessionStore.currentUser,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )
  }

  private func upsertMessage(_ updatedMessage: Message) {
    let normalizedUpdatedMessage: Message = normalizedMessage(updatedMessage)
    if let index: Int = messageIndex(for: normalizedUpdatedMessage.id) {
      messages[index] = normalizedUpdatedMessage
      totalCount = messages.count
      persistMessages()
      return
    }

    messages.insert(normalizedUpdatedMessage, at: 0)
    totalCount = messages.count
    persistMessages()
  }

  private func startRealtimePolling() {
    guard realtimePollingTask == nil else {
      return
    }

    realtimePollingTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: self.realtimePollIntervalNanoseconds)
        guard self.hasJoinedRealtime else {
          continue
        }
        try? await self.pullAndNotifyIfChanged(limit: self.pageSize)
      }
    }
  }

  private func stopRealtimePolling() {
    realtimePollingTask?.cancel()
    realtimePollingTask = nil
  }

  private func stateSignature() -> String {
    let newestId: String = messages.first?.id ?? "-"
    let oldestId: String = messages.last?.id ?? "-"
    let deletedCount: Int = messages.reduce(into: 0) { partial, message in
      if message.deletedAt != nil {
        partial += 1
      }
    }
    let reactionCount: Int = messages.reduce(into: 0) { partial, message in
      partial += message.reactions?.count ?? 0
    }
    let editsCount: Int = editsByMessageId.values.reduce(into: 0) { partial, edits in
      partial += edits.count
    }
    let statusFingerprint: String = messages
      .map { message in
        [
          message.id,
          message.readAt == nil ? "0" : "1",
          message.deliveredAt == nil ? "0" : "1",
          message.transportState?.rawValue ?? "-",
          message.deletedAt == nil ? "0" : "1",
          String(message.reactions?.count ?? 0),
        ].joined(separator: ":")
      }
      .joined(separator: ",")

    return [
      String(messages.count),
      newestId,
      oldestId,
      String(deletedCount),
      String(reactionCount),
      String(editsCount),
      String(pinnedMessages.count),
      String(hiddenPinnedMessageIds.count),
      String(pendingReadReceipts.count),
      String(deferredControlMessages.count),
      statusFingerprint,
    ].joined(separator: "|")
  }

  private func pullAndNotifyIfChanged(limit: Int) async throws {
    let before: String = stateSignature()
    try await syncAndHydrate(limit: limit, replaceExisting: false, source: .realtime)
    let after: String = stateSignature()
    if before != after {
      notifyStateChanged()
    }
  }

  private func observeRealtimeEvents() {
    eventObserverId = container.realtimeRouter.observeEvents { [weak self] event in
      guard let self else {
        return
      }

      switch event {
      case .syncBlobAvailable:
        Task {
          try? await self.pullAndNotifyIfChanged(limit: self.pageSize)
        }
      case .syncBlobs(let payload):
        Task {
          let before: String = self.stateSignature()
          if let summary = try? await self.processMailboxBlobs(
            payload.blobs,
            replaceExisting: false,
            source: .realtime
          ),
            !summary.appliedMessages.isEmpty || !summary.ackIds.isEmpty
          {
            let after: String = self.stateSignature()
            if before != after {
              self.notifyStateChanged()
            }
          }
        }
      default:
        break
      }
    }

    stateObserverId = container.realtimeRouter.observeConnectionState { [weak self] state in
      guard let self, self.hasJoinedRealtime else {
        return
      }

      if state == .connected {
        Task {
          if self.isVisibleConversation {
            await self.syncVisibleConversationTracking()
          }
          try? await self.container.socketClient.subscribeSync()
          try? await self.pullAndNotifyIfChanged(limit: self.pageSize)
          _ = await self.flushPendingReadReceiptsIfNeeded()
          if self.isVisibleConversation {
            _ = await self.autoMarkVisibleConversationAsReadIfNeeded()
          }
        }
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
        self?.reloadPersistedConversationStateIfNeeded()
      }
    }
  }

  private func syncVisibleConversationTracking() async {
    let peerUserHandle: String? = peerUserId?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if isVisibleConversation, let peerUserHandle, !peerUserHandle.isEmpty {
      container.pushNotificationService.setVisibleConversationPeerUserId(peerUserHandle)
      return
    }

    container.pushNotificationService.setVisibleConversationPeerUserId(nil)
  }

  private func notifyStateChanged() {
    onStateChanged?()
  }

  private func reloadPersistedConversationStateIfNeeded() {
    let before: String = stateSignature()
    let persistedHiddenMessageIds: Set<String> = loadHiddenMessageIds()

    hiddenPinnedMessageIds = loadHiddenPinnedMessageIds()
    hiddenMessageIds = persistedHiddenMessageIds
    messages = loadPersistedMessages().filter { !persistedHiddenMessageIds.contains($0.id) }
    editsByMessageId = loadPersistedEdits()
    replyPreviewByReplyMessageId = loadPersistedReplyPreviews()
    pinnedMessages = loadPersistedPinnedMessages()
    sentReadReceipts = loadSentReadReceipts()
    pendingReadReceipts = loadPendingReadReceipts()
    deferredControlMessages = loadPersistedDeferredControlMessages()
    reapplyPersistedDeferredControlsIfNeeded()

    let after: String = stateSignature()
    if before != after {
      notifyStateChanged()
    }
  }

  private func deduplicatedMessageIds(_ messageIds: [String]) -> [String] {
    var seen: Set<String> = []
    return messageIds
      .map(normalizedMessageId)
      .filter { seen.insert($0).inserted }
  }

  private func pendingReadReceiptMessageIds() -> [String] {
    let pendingIds: [String] = Array(pendingReadReceipts.subtracting(sentReadReceipts))
    return deduplicatedMessageIds(pendingIds).filter { messageId in
      messages.contains(where: { normalizedMessageId($0.id) == messageId && $0.deletedAt == nil })
    }
  }

  private func unreadIncomingMessageIds() -> [String] {
    messages
      .filter { !isOutgoing($0) && $0.readAt == nil && $0.deletedAt == nil }
      .map(\.id)
  }

  private func applyReadLocally(messageIds: [String], at readAt: Date) -> (didChange: Bool, missingMessageIds: [String]) {
    var didChange = false
    var missingMessageIds: [String] = []

    for messageId in deduplicatedMessageIds(messageIds) {
      guard let index: Int = messageIndex(for: messageId) else {
        missingMessageIds.append(messageId)
        continue
      }

      let current = messages[index]
      guard current.readAt == nil else {
        continue
      }

      didChange = true
      messages[index] = Message(
        id: current.id,
        conversationId: current.conversationId,
        senderId: current.senderId,
        content: current.content,
        type: current.type,
        encryptionMode: current.encryptionMode,
        encryptionKeyNonce: current.encryptionKeyNonce,
        readAt: readAt,
        deliveredAt: current.deliveredAt,
        replyToMessageId: current.replyToMessageId,
        forwardedFromMessageId: current.forwardedFromMessageId,
        deletedBy: current.deletedBy,
        deletedAt: current.deletedAt,
        createdAt: current.createdAt,
        attachment: current.attachment,
        reactions: current.reactions,
        transportState: current.transportState,
        transportErrorDetail: current.transportErrorDetail
      )
    }

    return (didChange, missingMessageIds)
  }

  @discardableResult
  private func flushPendingReadReceiptsIfNeeded() async -> Bool {
    let pendingIds: [String] = pendingReadReceiptMessageIds()
    guard !pendingIds.isEmpty else {
      return false
    }

    let now: Date = Date()
    logReadReceipt("flushing pending msg_read ids=\(pendingIds.count)")

    do {
      try await sendControlMessage(
        type: ControlMessageType.read,
        payload: ControlPayload(
          action: "read",
          targetMessageId: nil,
          messageIds: pendingIds,
          content: nil,
          messageCreatedAt: nil,
          emoji: nil,
          reactionAction: nil,
          actorUserId: currentUserId(),
          at: now
        )
      )

      for messageId in pendingIds {
        sentReadReceipts.insert(messageId)
        pendingReadReceipts.remove(messageId)
      }

      persistSentReadReceipts()
      persistPendingReadReceipts()
      logReadReceipt("flushed pending msg_read ids=\(pendingIds.count)")
      return true
    } catch {
      logReadReceipt("flush pending msg_read failed: \(error.localizedDescription)")
      persistPendingReadReceipts()
      return false
    }
  }

  @discardableResult
  private func autoMarkVisibleConversationAsReadIfNeeded(notifyAfterChange: Bool = true) async -> Bool {
    guard isVisibleConversation, !manualReadReceiptsEnabled else {
      return false
    }

    let incomingUnreadIds: [String] = unreadIncomingMessageIds()
    guard !incomingUnreadIds.isEmpty else {
      return false
    }

    do {
      try await sendReadReceipts(messageIds: incomingUnreadIds, markLocally: true)
      persistMessages()
      persistSentReadReceipts()
      persistPendingReadReceipts()
      if notifyAfterChange {
        notifyStateChanged()
      }
      return true
    } catch {
      return false
    }
  }

  private func logReadReceipt(_: String) {
  }

  private func reapplyPersistedDeferredControlsIfNeeded() {
    guard !deferredControlMessages.isEmpty else {
      totalCount = messages.count
      return
    }

    deferredControlMessages = applyControlMessages(deferredControlMessages.map(normalizedMessage))
    messages = messages.filter { !hiddenMessageIds.contains($0.id) }
    totalCount = messages.count
    persistMessages()
    persistEdits()
    persistReplyPreviews()
    persistPinnedMessages()
    persistHiddenPinnedMessageIds()
    persistHiddenMessageIds()
    persistDeferredControlMessages()
  }

  private func normalizedMessageId(_ messageId: String) -> String {
    messageId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func normalizedOptionalMessageId(_ messageId: String?) -> String? {
    guard let messageId else {
      return nil
    }

    let normalized: String = normalizedMessageId(messageId)
    return normalized.isEmpty ? nil : normalized
  }

  private func normalizedPreviewText(_ value: String?) -> String? {
    guard let value else {
      return nil
    }

    let collapsed = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else {
      return nil
    }

    return String(collapsed.prefix(140))
  }

  private func messageIndex(for messageId: String) -> Int? {
    let targetMessageId: String = normalizedMessageId(messageId)
    return messages.firstIndex(where: { normalizedMessageId($0.id) == targetMessageId })
  }

  private func message(matching messageId: String) -> Message? {
    guard let index: Int = messageIndex(for: messageId) else {
      return nil
    }

    return messages[index]
  }

  private func isUserVisibleMessage(_ messageId: String) -> Bool {
    message(matching: messageId)?.isUserVisibleInConversation == true
  }

  private func pinnedMessagePreviewText(for message: Message) -> String {
    if message.deletedAt != nil {
      return "Удалённое сообщение"
    }

    if let normalizedContent: String = normalizedPreviewText(message.content) {
      return normalizedContent
    }

    if let fileName: String = normalizedPreviewText(message.attachment?.fileName) {
      return fileName
    }

    switch message.type {
    case .file:
      return "Вложение"
    case .media:
      return "Медиа"
    default:
      return "Сообщение"
    }
  }

  private func normalizedMessage(_ message: Message) -> Message {
    let normalizedId: String = normalizedMessageId(message.id)
    let normalizedAttachment: FileAttachment? = message.attachment.map { attachment in
      FileAttachment(
        id: attachment.id,
        messageId: normalizedMessageId(attachment.messageId),
        storageUrl: attachment.storageUrl,
        mimeType: attachment.mimeType,
        fileSize: attachment.fileSize,
        fileName: attachment.fileName,
        originServer: attachment.originServer,
        downloadCapability: attachment.downloadCapability,
        fileKey: attachment.fileKey,
        hashCipherFile: attachment.hashCipherFile,
        scanVerdict: attachment.scanVerdict,
        riskFlags: attachment.riskFlags,
        scannerVersion: attachment.scannerVersion,
        rulesVersion: attachment.rulesVersion,
        createdAt: attachment.createdAt
      )
    }
    let normalizedReactions: [MessageReaction]? = message.reactions?.map { reaction in
      MessageReaction(
        id: reaction.id,
        messageId: reaction.messageId.flatMap(normalizedOptionalMessageId),
        userId: reaction.userId,
        emoji: reaction.emoji,
        createdAt: reaction.createdAt
      )
    }

    return Message(
      id: normalizedId,
      conversationId: message.conversationId,
      senderId: message.senderId,
      content: message.content,
      type: message.type,
      encryptionMode: message.encryptionMode,
      encryptionKeyNonce: message.encryptionKeyNonce,
      readAt: message.readAt,
      deliveredAt: message.deliveredAt,
      replyToMessageId: normalizedOptionalMessageId(message.replyToMessageId),
      forwardedFromMessageId: normalizedOptionalMessageId(message.forwardedFromMessageId),
      deletedBy: message.deletedBy,
      deletedAt: message.deletedAt,
      createdAt: message.createdAt,
      attachment: normalizedAttachment,
      reactions: normalizedReactions,
      transportState: message.transportState,
      transportErrorDetail: message.transportErrorDetail
    )
  }

  private func normalizeEditsByMessageId(_ edits: [String: [MessageEdit]]) -> [String: [MessageEdit]] {
    var normalized: [String: [MessageEdit]] = [:]

    for (messageId, values) in edits {
      let normalizedTargetMessageId: String = normalizedMessageId(messageId)
      let normalizedValues: [MessageEdit] = values.map { edit in
        MessageEdit(
          id: edit.id,
          messageId: normalizedMessageId(edit.messageId),
          oldContent: edit.oldContent,
          editedBy: edit.editedBy,
          editedAt: edit.editedAt
        )
      }
      normalized[normalizedTargetMessageId, default: []].append(contentsOf: normalizedValues)
      normalized[normalizedTargetMessageId] = normalized[normalizedTargetMessageId]?
        .sorted(by: { $0.editedAt > $1.editedAt })
    }

    return normalized
  }

  private func normalizeReplyPreviews(_ previews: [String: String]) -> [String: String] {
    previews.reduce(into: [:]) { partial, entry in
      partial[normalizedMessageId(entry.key)] = entry.value
    }
  }

  private func normalizedPinnedMessage(_ pinnedMessage: PinnedMessage) -> PinnedMessage {
    PinnedMessage(
      id: pinnedMessage.id,
      conversationId: pinnedMessage.conversationId,
      messageId: normalizedMessageId(pinnedMessage.messageId),
      pinnedBy: pinnedMessage.pinnedBy,
      pinnedAt: pinnedMessage.pinnedAt,
      previewText: normalizedPreviewText(pinnedMessage.previewText),
      messageCreatedAt: pinnedMessage.messageCreatedAt
    )
  }
}

private enum SHA256Hex {
  static func hash(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
