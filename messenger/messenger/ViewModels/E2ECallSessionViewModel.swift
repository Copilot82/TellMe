import AVFoundation
import Foundation
import UIKit
import WebRTC

protocol CallMediaRecoveryControlling: AnyObject {
  func updateRelayIceServers(_ iceServers: [WebRTC.RTCIceServer]) throws
  func restartIceAndCreateOffer(callId: String) async throws -> CallSessionDescriptionSignal
}

extension WebRTCAutomationEngine: CallMediaRecoveryControlling {}

protocol CallOfferRecoveryControlling: CallMediaRecoveryControlling {
  func rollbackLocalDescription() async throws
}

extension WebRTCAutomationEngine: CallOfferRecoveryControlling {}

protocol CallRemoteICECandidateQueuing: AnyObject {
  func queueRemoteCandidate(_ candidate: CallICECandidateSignal) async throws
}

extension WebRTCAutomationEngine: CallRemoteICECandidateQueuing {}

protocol CallVideoRendererManaging: AnyObject {
  func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer)
  func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer)
  func detachLocalVideoRenderer(_ renderer: RTCVideoRenderer)
  func detachRemoteVideoRenderer(_ renderer: RTCVideoRenderer)
}

extension WebRTCAutomationEngine: CallVideoRendererManaging {}

private struct PendingLocalICECandidateRetry {
  let candidate: CallICECandidateSignal
  let attemptCount: Int
  let nextAttemptAt: Date
}

private struct PendingRemoteICECandidateRetry {
  let attemptCount: Int
  let nextAttemptAt: Date
}

private struct PendingCallAnswerRetry {
  let answer: CallSessionDescriptionSignal
  let attemptCount: Int
  let nextAttemptAt: Date
  let retryState: E2ECallSessionViewModel.SessionState
  let retryStatusText: String
  let successStatusText: String
}

private struct PendingReconnectOfferRetry {
  let offer: CallSessionDescriptionSignal
  let attemptCount: Int
  let nextAttemptAt: Date
}

@MainActor
final class E2ECallSessionViewModel {
  enum Role {
    case initiator
    case receiver(offer: CallSessionDescriptionSignal)
  }

  enum SessionState: Equatable {
    case idle
    case connecting
    case waitingForPeer
    case connected
    case reconnecting
    case ended
    case failed(String)
  }

  private let conversationViewModel: ConversationViewModel
  private let role: Role
  private let callId: String
  private let peerUserId: String
  private let callType: Call.CallType

  private var engine: WebRTCAutomationEngine?
  private var sessionTask: Task<Void, Never>?
  private var processedMessageIds: Set<String> = []
  private var remoteDescriptionApplied: Bool = false
  private var isFinished: Bool = false
  private var localVideoRenderer: RTCVideoRenderer?
  private var remoteVideoRenderer: RTCVideoRenderer?
  private var additionalRemoteVideoRenderers: [RTCVideoRenderer] = []
  private var hasReportedConnected: Bool = false
  private var recoveryMonitor: CallMediaRecoveryMonitor = CallMediaRecoveryMonitor()
  private var renegotiationState: CallRenegotiationState = CallRenegotiationState()
  private var remoteMicrophoneEnabled: Bool = true
  private var remoteCameraEnabled: Bool
  private var finishObservers: [UUID: () -> Void] = [:]
  private let toneController: CallToneController = CallToneController()
  private var pictureInPictureController: E2ECallPictureInPictureController?
  private var pictureInPictureEventHistory: [String] = ["none"]
  private var systemEndObserver: NSObjectProtocol?
  private var mediaStateTask: Task<Void, Never>?
  private var pendingMediaStateSendId: UUID?
  private var mediaStateSendAttemptCount: Int = 0
  private var pendingLocalICECandidates: [PendingLocalICECandidateRetry] = []
  private var pendingRemoteICECandidateRetries: [String: PendingRemoteICECandidateRetry] = [:]
  private var pendingCallAnswerRetry: PendingCallAnswerRetry?
  private var pendingReconnectOfferRetry: PendingReconnectOfferRetry?
  private var waitingForPeerStartedAt: Date?
  private var lastUnansweredOfferRecoveryAttemptAt: Date?
  private var unansweredOfferRecoveryAttemptCount: Int = 0
  private static let mediaStateSendDebounceNanoseconds: UInt64 = 150_000_000
  private static let mediaStatePeerDeliveryRetryDelaysSeconds: [TimeInterval] = [1, 2, 4, 8]
  private static let fastCallSignalPollIntervalNanoseconds: UInt64 = 250_000_000
  private static let steadyCallSignalPollIntervalNanoseconds: UInt64 = 1_000_000_000
  private static let maxPendingLocalICECandidates: Int = 64
  private static let localICECandidateRetryDelaysSeconds: [TimeInterval] = [1, 2, 4, 8]
  private static let remoteICECandidateRetryDelaysSeconds: [TimeInterval] = [0, 1, 2, 4, 8]
  private static let callAnswerPeerDeliveryRetryDelaysSeconds: [TimeInterval] = [0, 1, 2, 4, 8]
  private static let reconnectOfferPeerDeliveryRetryDelaysSeconds: [TimeInterval] = [0, 1, 2, 4, 8]
  private static let callEndPeerDeliveryRetryDelaysSeconds: [TimeInterval] = [0, 0.5, 1.5]
  private static let unansweredInitialOfferRecoveryDelaysSeconds: [TimeInterval] = [8, 18, 32]
  private static let unansweredInitialOfferFailureTimeoutSeconds: TimeInterval = 75

  private(set) var state: SessionState = .idle
  private(set) var statusText: String = "Подготовка звонка"
  private(set) var isMuted: Bool = false
  private(set) var isCameraEnabled: Bool

  var onStateChanged: (() -> Void)?
  var onFinished: (() -> Void)?
  var onPictureInPictureStartRequested: (() -> Void)?
  var onPictureInPictureDidStart: (() -> Void)?
  var onPictureInPictureStartFailed: (() -> Void)?
  var onPictureInPictureDidStop: (() -> Void)?

#if DEBUG
  var pictureInPictureStartOverrideForTesting: (() -> Bool)?
  var pictureInPictureAvailabilityOverrideForTesting: Bool?
  var callEndPeerDeliveryRetryDelaysOverrideForTesting: [TimeInterval]?
  var mediaStatePeerDeliveryRetryDelaysOverrideForTesting: [TimeInterval]?
  var callAnswerPeerDeliveryRetryDelaysOverrideForTesting: [TimeInterval]?
  var reconnectOfferPeerDeliveryRetryDelaysOverrideForTesting: [TimeInterval]?
  var unansweredInitialOfferRecoveryDelaysOverrideForTesting: [TimeInterval]?
  var unansweredInitialOfferFailureTimeoutOverrideForTesting: TimeInterval?

  var hasSessionTaskForTesting: Bool {
    sessionTask != nil
  }

  var hasPendingMediaStateTaskForTesting: Bool {
    mediaStateTask != nil
  }

  var pendingLocalICECandidateCountForTesting: Int {
    pendingLocalICECandidates.count
  }

  var pendingCallAnswerRetryCountForTesting: Int {
    pendingCallAnswerRetry?.attemptCount ?? 0
  }

  var pendingReconnectOfferRetryCountForTesting: Int {
    pendingReconnectOfferRetry?.attemptCount ?? 0
  }

  var unansweredOfferRecoveryAttemptCountForTesting: Int {
    unansweredOfferRecoveryAttemptCount
  }

  var hasPendingLocalOfferAnswerForTesting: Bool {
    renegotiationState.hasPendingLocalOfferAnswer
  }

  var remoteMediaStateForTesting: (microphone: Bool, camera: Bool) {
    (remoteMicrophoneEnabled, remoteCameraEnabled)
  }

  func boundDTLSFingerprintForTesting(_ description: CallSessionDescriptionSignal) throws -> String {
    try boundDTLSFingerprint(for: description)
  }

  func applyRemoteMediaStateForTesting(_ mediaState: CallMediaStateSignal) {
    applyRemoteMediaState(mediaState)
  }

  func handleRecoverableDisconnectForTesting(
    decision: CallMediaRecoveryDecision,
    mediaEngine: CallMediaRecoveryControlling
  ) async {
    await handleRecoverableDisconnect(decision: decision, mediaEngine: mediaEngine)
  }

  func sendICECandidateForTesting(_ candidate: CallICECandidateSignal) async {
    await sendICECandidate(candidate)
  }

  func flushPendingLocalICECandidatesForTesting() async {
    await flushPendingLocalICECandidates(force: true)
  }

  @discardableResult
  func sendCallAnswerForTesting(_ answer: CallSessionDescriptionSignal) async throws -> Bool {
    try await sendCallAnswerOrQueueRetry(
      answer,
      retryState: .reconnecting,
      retryStatusText: "Call answer ожидает повторной доставки",
      successStatusText: "Call answer отправлен"
    )
  }

  func flushPendingCallAnswerForTesting() async {
    await flushPendingCallAnswer(force: true)
  }

  func flushPendingReconnectOfferForTesting() async {
    await flushPendingReconnectOffer(force: true)
  }

  func markWaitingForPeerForTesting(startedAt: Date = Date()) {
    update(state: .waitingForPeer, status: "Вызов отправлен")
    waitingForPeerStartedAt = startedAt
  }

  func recoverUnansweredInitialOfferForTesting(
    mediaEngine: CallOfferRecoveryControlling,
    now: Date = Date()
  ) async {
    await recoverUnansweredInitialOfferIfNeeded(mediaEngine, now: now)
  }

  func handleRemoteICECandidateForTesting(
    message: Message,
    mediaEngine: CallRemoteICECandidateQueuing
  ) async {
    processedMessageIds.insert(message.id)
    guard let payload: [String: Any] = parseJSONObject(from: message.content) else {
      return
    }

    await handleRemoteICECandidate(message: message, payload: payload, mediaEngine: mediaEngine)
  }

  func hasProcessedMessageForTesting(_ messageId: String) -> Bool {
    processedMessageIds.contains(messageId)
  }

  func remoteICECandidateRetryCountForTesting(messageId: String) -> Int {
    pendingRemoteICECandidateRetries[messageId]?.attemptCount ?? 0
  }

  var additionalRemoteVideoRendererCountForTesting: Int {
    additionalRemoteVideoRenderers.count
  }

  func attachStoredVideoRenderersForTesting(to rendererManager: CallVideoRendererManaging) {
    attachStoredVideoRenderers(to: rendererManager)
  }
#endif

  deinit {
    let pictureInPictureController = pictureInPictureController
    Task { @MainActor in
      pictureInPictureController?.stopAndRelease()
    }
    if let systemEndObserver {
      NotificationCenter.default.removeObserver(systemEndObserver)
    }
    engine?.stop()
    sessionTask?.cancel()
    mediaStateTask?.cancel()
  }

  init(
    conversationViewModel: ConversationViewModel,
    role: Role,
    callId: String,
    peerUserId: String,
    callType: Call.CallType
  ) {
    self.conversationViewModel = conversationViewModel
    self.role = role
    self.callId = callId
    self.peerUserId = peerUserId
    self.callType = callType
    self.isCameraEnabled = callType == .video
    self.remoteCameraEnabled = callType == .video
    installSystemCallObserver()
  }

  var title: String {
    UserHandleDisplay.usernameOnly(from: peerUserId)
  }

  var activeCallId: String {
    callId
  }

  var showsCameraControl: Bool {
    callType == .video
  }

  var isPictureInPictureAvailable: Bool {
#if DEBUG
    if let pictureInPictureAvailabilityOverrideForTesting {
      return callType == .video && pictureInPictureAvailabilityOverrideForTesting
    }
#endif
    return callType == .video && pictureInPictureController?.isAvailable == true
  }

  var isPictureInPictureActive: Bool {
    callType == .video && pictureInPictureController?.isActive == true
  }

  var pictureInPictureDiagnosticsSummary: String {
    guard callType == .video else {
      return "audio_call"
    }

    let controllerSummary: String = pictureInPictureController?.diagnosticsSummary ?? "not_configured"
    return "events=\(pictureInPictureEventHistory.joined(separator: ","))/\(controllerSummary)"
  }

#if DEBUG
  var pictureInPictureSourceViewForTesting: UIView? {
    pictureInPictureController?.sourceViewForTesting
  }
#endif

  @discardableResult
  func addFinishObserver(_ handler: @escaping () -> Void) -> UUID {
    let id = UUID()
    finishObservers[id] = handler
    return id
  }

  func removeFinishObserver(_ id: UUID) {
    finishObservers[id] = nil
  }

  func start() {
    guard !isFinished, sessionTask == nil else {
      return
    }

    sessionTask = Task { [weak self] in
      await self?.runSession()
    }
  }

  func endFromUser() async {
    guard !isFinished else {
      return
    }

    await sendCallEnd(status: "ended")
    _ = await SystemCallCoordinator.shared.requestEndCall(callId: callId)
    finish(status: "Звонок завершен", state: .ended, reportSystemCall: false)
  }

  private func endFromSystemCall() async {
    guard !isFinished else {
      return
    }

    await sendCallEnd(status: "ended")
    finish(status: "Звонок завершен", state: .ended, reportSystemCall: false)
  }

  func finishForLocalSessionClear() {
    finish(status: "Звонок завершен", state: .ended)
  }

  func setMuted(_ muted: Bool) {
    isMuted = muted
    engine?.setMicrophoneEnabled(!muted)
    notifyStateChanged()
    scheduleMediaStateSend()
  }

  func setCameraEnabled(_ enabled: Bool) {
    guard callType == .video else {
      return
    }

    isCameraEnabled = enabled
    engine?.setCameraEnabled(enabled)
    notifyStateChanged()
    scheduleMediaStateSend()
  }

  func attachVideoRenderers(local: RTCVideoRenderer?, remote: RTCVideoRenderer?) {
    if let localVideoRenderer, !isSameRenderer(localVideoRenderer, local) {
      engine?.detachLocalVideoRenderer(localVideoRenderer)
    }
    if let remoteVideoRenderer, !isSameRenderer(remoteVideoRenderer, remote) {
      engine?.detachRemoteVideoRenderer(remoteVideoRenderer)
    }

    localVideoRenderer = local
    remoteVideoRenderer = remote

    if let local {
      engine?.attachLocalVideoRenderer(local)
    }
    if let remote {
      engine?.attachRemoteVideoRenderer(remote)
    }
  }

  func detachVideoRenderers(local: RTCVideoRenderer?, remote: RTCVideoRenderer?) {
    if let local,
      let localVideoRenderer,
      ObjectIdentifier(local as AnyObject) == ObjectIdentifier(localVideoRenderer as AnyObject)
    {
      engine?.detachLocalVideoRenderer(local)
      self.localVideoRenderer = nil
    }

    if let remote,
      let remoteVideoRenderer,
      ObjectIdentifier(remote as AnyObject) == ObjectIdentifier(remoteVideoRenderer as AnyObject)
    {
      engine?.detachRemoteVideoRenderer(remote)
      self.remoteVideoRenderer = nil
    }
  }

  func attachAdditionalRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    guard !containsRenderer(renderer, in: additionalRemoteVideoRenderers) else {
      return
    }

    additionalRemoteVideoRenderers.append(renderer)
    engine?.attachRemoteVideoRenderer(renderer)
  }

  func detachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    if let index: Int = rendererIndex(renderer, in: additionalRemoteVideoRenderers) {
      additionalRemoteVideoRenderers.remove(at: index)
    }

    engine?.detachRemoteVideoRenderer(renderer)
  }

  private func isSameRenderer(_ lhs: RTCVideoRenderer, _ rhs: RTCVideoRenderer?) -> Bool {
    guard let rhs else {
      return false
    }

    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
  }

  private func containsRenderer(_ renderer: RTCVideoRenderer, in renderers: [RTCVideoRenderer]) -> Bool {
    rendererIndex(renderer, in: renderers) != nil
  }

  private func rendererIndex(_ renderer: RTCVideoRenderer, in renderers: [RTCVideoRenderer]) -> Int? {
    let rendererId = ObjectIdentifier(renderer as AnyObject)
    return renderers.firstIndex { ObjectIdentifier($0 as AnyObject) == rendererId }
  }

  func configurePictureInPicture(sourceView: UIView) {
    guard callType == .video else {
      return
    }

    if pictureInPictureController == nil {
      pictureInPictureController = E2ECallPictureInPictureController(session: self)
    }
    pictureInPictureController?.configure(sourceView: sourceView)
  }

  func preparePictureInPictureForAutomaticStart(sourceView: UIView, reason: String = "unknown") {
    guard callType == .video, !isFinished else {
      return
    }

    configurePictureInPicture(sourceView: sourceView)
    pictureInPictureController?.prepareForAutomaticStart(reason: reason)
  }

  @discardableResult
  func startPictureInPictureIfPossible(reason: String = "manual") -> Bool {
    guard callType == .video, !isFinished else {
      return false
    }

    recordPictureInPictureEvent("call_pip_request", detail: "reason=\(reason)")
    onPictureInPictureStartRequested?()
#if DEBUG
    if let pictureInPictureStartOverrideForTesting {
      return pictureInPictureStartOverrideForTesting()
    }
#endif
    return pictureInPictureController?.startIfPossible(source: reason) == true
  }

  func recordPictureInPictureEvent(_ event: String, detail: String? = nil) {
    guard callType == .video else {
      return
    }

    let normalizedEvent: String = event.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEvent.isEmpty else {
      return
    }

    let sanitizedDetail: String = (detail ?? "")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let value: String
    if sanitizedDetail.isEmpty {
      value = normalizedEvent
    } else {
      value = "\(normalizedEvent)(\(String(sanitizedDetail.prefix(360))))"
    }

    if pictureInPictureEventHistory.last != value {
      pictureInPictureEventHistory.append(value)
    }
    if pictureInPictureEventHistory.count > 32 {
      pictureInPictureEventHistory.removeFirst(pictureInPictureEventHistory.count - 32)
    }
    PiPDiagnosticRecorder.shared.record(
      category: "call_startup",
      name: normalizedEvent,
      callId: callId,
      detail: sanitizedDetail.isEmpty ? nil : sanitizedDetail
    )
    notifyStateChanged()
  }

  func notifyPictureInPictureDidStart() {
    onPictureInPictureDidStart?()
  }

  func notifyPictureInPictureStartFailed() {
    onPictureInPictureStartFailed?()
  }

  func notifyPictureInPictureDidStop() {
    onPictureInPictureDidStop?()
  }

  private func installSystemCallObserver() {
    removeSystemCallObserver()
    systemEndObserver = NotificationCenter.default.addObserver(
      forName: .didEndSystemCall,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let endedCallId: String? = notification.userInfo?["call_id"] as? String

      Task { @MainActor [weak self] in
        guard let self,
          endedCallId == self.callId
        else {
          return
        }

        await self.endFromSystemCall()
      }
    }
  }

  private func removeSystemCallObserver() {
    guard let systemEndObserver else {
      return
    }

    NotificationCenter.default.removeObserver(systemEndObserver)
    self.systemEndObserver = nil
  }

  private func runSession() async {
    CallStartupTracer.event("call_session_start", callId: callId)
    update(state: .connecting, status: "Проверка доступа к медиа")

    CallStartupTracer.event("call_permission_request_begin", callId: callId)
    guard await requestMediaPermissions() else {
      let requiredMedia: String = callType == .video ? "камере или микрофону" : "микрофону"
      fail("Нет доступа к \(requiredMedia)")
      return
    }
    CallStartupTracer.event("call_permission_request_end", callId: callId)

    guard await prepareSystemCallAudioIfNeeded() else {
      fail("Не удалось активировать системную аудиосессию звонка")
      return
    }

    let rtcConfig: RTCConfig
    do {
      CallStartupTracer.event("call_turn_fetch_begin", callId: callId)
      rtcConfig = try await conversationViewModel.fetchRelayRTCConfig()
      CallStartupTracer.event("call_turn_fetch_end", callId: callId)
    } catch {
      fail(turnCredentialFailureMessage(error))
      return
    }

    let iceServers: [WebRTC.RTCIceServer] = CallRelayIceServerMapper.map(rtcConfig)
    guard !iceServers.isEmpty else {
      fail("TURN relay config пустой")
      return
    }

    let mediaEngine: WebRTCAutomationEngine
    do {
      CallStartupTracer.event("call_webrtc_init_begin", callId: callId)
      mediaEngine = try WebRTCAutomationEngine(
        iceServers: iceServers,
        includeVideo: callType == .video
      ) { _ in
        // Keep SDP, ICE candidates, IPs, and media stats out of UI logs.
      }
      mediaEngine.bindDiagnosticCallId(callId)
      engine = mediaEngine
      attachStoredVideoRenderers(to: mediaEngine)
      mediaEngine.setMicrophoneEnabled(!isMuted)
      mediaEngine.setCameraEnabled(isCameraEnabled)
      CallStartupTracer.event("call_webrtc_init_end", callId: callId)
    } catch {
      fail("Не удалось создать WebRTC relay-only session")
      return
    }

    mediaEngine.onLocalCandidate = { [weak self] candidate in
      guard let self else {
        return
      }

      Task { @MainActor in
        await self.sendICECandidate(candidate)
      }
    }

    do {
      toneController.stop()
      switch role {
      case .initiator:
        CallStartupTracer.event("call_capture_start_begin", callId: callId)
        try await mediaEngine.startLocalMedia()
        CallStartupTracer.event("call_capture_start_end", callId: callId)
        try await startOutgoingCall(mediaEngine)
      case let .receiver(offer):
        try await answerIncomingCall(mediaEngine, offer: offer)
      }
    } catch {
      fail(startupFailureMessage(error))
      return
    }

    await pollCallSignals(mediaEngine)
  }

  private func startupFailureMessage(_ error: Error) -> String {
    let message: String = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback: String = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
    let safeMessage: String = sanitizeStartupError(message.isEmpty ? fallback : message)
    guard !safeMessage.isEmpty else {
      return "Не удалось запустить звонок"
    }

    return "Не удалось запустить звонок: \(safeMessage)"
  }

  private func turnCredentialFailureMessage(_ error: Error) -> String {
    let message: String = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback: String = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
    let safeMessage: String = sanitizeStartupError(message.isEmpty ? fallback : message)
    guard !safeMessage.isEmpty else {
      return "Не удалось получить TURN relay credentials"
    }

    return "Не удалось получить TURN relay credentials: \(safeMessage)"
  }

  private func prepareSystemCallAudioIfNeeded() async -> Bool {
    switch role {
    case .initiator:
      CallStartupTracer.event(
        "callkit_outgoing_start_begin",
        callId: callId,
        detail: "type=\(callType.rawValue) peer=\(peerUserId)"
      )
      let audioReady: Bool = await SystemCallCoordinator.shared.startOutgoingCallThroughCallKit(
        callId: callId,
        peerUserId: peerUserId,
        callType: callType
      )
      CallStartupTracer.event(
        "callkit_outgoing_start_end",
        callId: callId,
        detail: "audioReady=\(audioReady) \(SystemCallCoordinator.shared.diagnosticsSummary())"
      )
      return audioReady

    case .receiver:
      CallStartupTracer.event("callkit_incoming_audio_wait_begin", callId: callId)
      let audioReady: Bool = await SystemCallCoordinator.shared.waitForCallKitAudioIfManaged(callId: callId)
      CallStartupTracer.event(
        "callkit_incoming_audio_wait_end",
        callId: callId,
        detail: "audioReady=\(audioReady) \(SystemCallCoordinator.shared.diagnosticsSummary())"
      )
      return audioReady
    }
  }

  private func sanitizeStartupError(_ message: String) -> String {
    let flattened: String = message
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return String(flattened.prefix(180))
  }

  private func startOutgoingCall(_ mediaEngine: WebRTCAutomationEngine) async throws {
    update(state: .connecting, status: "Создание защищенного offer")
    CallStartupTracer.event("call_offer_create_begin", callId: callId)
    let generatedOffer: CallSessionDescriptionSignal = try await mediaEngine.createOffer(callId: callId)
    let offer: CallSessionDescriptionSignal = newLocalOffer(from: generatedOffer)
    CallStartupTracer.event("call_offer_create_end", callId: callId)
    try await sendCallOffer(offer, offerKind: "initial")
    update(state: .waitingForPeer, status: "Вызов отправлен")
    toneController.startOutgoingRingback()
  }

  private func answerIncomingCall(
    _ mediaEngine: WebRTCAutomationEngine,
    offer: CallSessionDescriptionSignal
  ) async throws {
    update(state: .connecting, status: "Принятие защищенного offer")
    try await mediaEngine.applyRemoteDescription(offer)
    renegotiationState.markRemoteOfferApplied(sdp: offer.sdp)
    remoteDescriptionApplied = true
    resetUnansweredOfferRecoveryState()

    CallStartupTracer.event("call_capture_start_begin", callId: callId)
    try await mediaEngine.startLocalMedia()
    CallStartupTracer.event("call_capture_start_end", callId: callId)
    CallStartupTracer.event("call_answer_create_begin", callId: callId)
    let generatedAnswer: CallSessionDescriptionSignal = try await mediaEngine.createAnswer(callId: callId)
    let answer: CallSessionDescriptionSignal = localAnswer(generatedAnswer, respondingTo: offer)
    CallStartupTracer.event("call_answer_create_end", callId: callId)
    let delivered: Bool = try await sendCallAnswerOrQueueRetry(
      answer,
      retryState: .waitingForPeer,
      retryStatusText: "Ответ ожидает повторной доставки",
      successStatusText: "Ответ отправлен"
    )
    update(
      state: .waitingForPeer,
      status: delivered
        ? "Ответ отправлен"
        : "Ответ ожидает повторной доставки"
    )
  }

  private func pollCallSignals(_ mediaEngine: WebRTCAutomationEngine) async {
    while !Task.isCancelled && !isFinished {
      try? await conversationViewModel.loadInitialMessages()
      await flushPendingReconnectOffer()
      await flushPendingCallAnswer()
      await processRemoteSignals(mediaEngine)
      await flushPendingLocalICECandidates()
      await recoverUnansweredInitialOfferIfNeeded(mediaEngine)
      await updateMediaStatus(mediaEngine)

      try? await Task.sleep(nanoseconds: Self.callSignalPollIntervalNanoseconds(for: state))
    }
  }

  static func callSignalPollIntervalNanoseconds(for state: SessionState) -> UInt64 {
    switch state {
    case .connected, .ended, .failed:
      return steadyCallSignalPollIntervalNanoseconds
    case .idle, .connecting, .waitingForPeer, .reconnecting:
      return fastCallSignalPollIntervalNanoseconds
    }
  }

  private func processRemoteSignals(_ mediaEngine: WebRTCAutomationEngine) async {
    let currentUserId: String? = conversationViewModel.activeUserId?.lowercased()
    let messages: [Message] = CallSignalProcessingOrder.sorted(conversationViewModel.messages, callId: callId)

    for message in messages where !processedMessageIds.contains(message.id) {
      processedMessageIds.insert(message.id)

      if let currentUserId, message.senderId.lowercased() == currentUserId {
        continue
      }

      guard let payload: [String: Any] = parseJSONObject(from: message.content),
        let messageCallId: String = stringValue(payload["call_id"] ?? payload["callId"]),
        messageCallId == callId,
        CallSignalParser.hasValidEnvelope(payload)
      else {
        continue
      }

      switch message.type {
      case .callOffer:
        guard let offer: CallSessionDescriptionSignal = CallSignalParser.sessionDescription(
          from: payload,
          objectKey: "offer",
          senderId: message.senderId,
          callId: callId
        ) else {
          continue
        }

        let disposition: CallRenegotiationState.RemoteReconnectOfferDisposition =
          renegotiationState.remoteReconnectOfferDisposition(
            payload: payload,
            sdp: offer.sdp,
            localUserId: conversationViewModel.activeUserId,
            remoteUserId: offer.fromUserId
          )
        guard disposition != .ignore else {
          continue
        }

        do {
          update(state: .reconnecting, status: "Восстановление медиа через TURN")
          if disposition == .rollbackLocalOfferAndApply {
            try await mediaEngine.rollbackLocalDescription()
            renegotiationState.markLocalOfferRolledBack()
            pendingReconnectOfferRetry = nil
          }
          try await mediaEngine.applyRemoteDescription(offer)
          renegotiationState.markRemoteOfferApplied(sdp: offer.sdp)
          pendingReconnectOfferRetry = nil
          remoteDescriptionApplied = true
          resetUnansweredOfferRecoveryState()
        } catch {
          fail("Не удалось применить reconnect offer")
          continue
        }

        do {
          try await refreshRelayConfiguration(mediaEngine)
        } catch {
          update(state: .reconnecting, status: "Ожидание новых TURN credentials")
        }

        do {
          let generatedAnswer: CallSessionDescriptionSignal = try await mediaEngine.createAnswer(callId: callId)
          let answer: CallSessionDescriptionSignal = localAnswer(generatedAnswer, respondingTo: offer)
          let delivered: Bool = try await sendCallAnswerOrQueueRetry(
            answer,
            retryState: .reconnecting,
            retryStatusText: "Reconnect answer ожидает повторной доставки",
            successStatusText: "Reconnect answer отправлен"
          )
          update(
            state: .reconnecting,
            status: delivered
              ? "Reconnect answer отправлен"
              : "Reconnect answer ожидает повторной доставки"
          )
        } catch {
          update(state: .reconnecting, status: "Повторная попытка восстановления")
        }
      case .callAnswer:
        guard let answer: CallSessionDescriptionSignal = CallSignalParser.sessionDescription(
          from: payload,
          objectKey: "answer",
          senderId: message.senderId,
          callId: callId
        ),
          renegotiationState.shouldApplyRemoteAnswer(
            sdp: answer.sdp,
            answerToOfferId: answer.answerToOfferId
          )
        else {
          continue
        }

        do {
          try await mediaEngine.applyRemoteDescription(answer)
          renegotiationState.markRemoteAnswerApplied(
            sdp: answer.sdp,
            answerToOfferId: answer.answerToOfferId
          )
          pendingReconnectOfferRetry = nil
          remoteDescriptionApplied = true
          resetUnansweredOfferRecoveryState()
          update(state: .connecting, status: "Ответ получен, подключение через TURN")
        } catch {
          fail("Не удалось применить ответ")
        }
      case .callIceCandidate:
        await handleRemoteICECandidate(message: message, payload: payload, mediaEngine: mediaEngine)
      case .callMediaState:
        guard let mediaState: CallMediaStateSignal = CallSignalParser.mediaState(from: payload, callId: callId) else {
          continue
        }

        applyRemoteMediaState(mediaState)
      case .callEnd:
        finish(status: "Звонок завершен собеседником", state: .ended)
      default:
        continue
      }
    }
  }

  private func handleRemoteICECandidate(
    message: Message,
    payload: [String: Any],
    mediaEngine: CallRemoteICECandidateQueuing
  ) async {
    guard let candidate: CallICECandidateSignal = parseICECandidate(from: payload) else {
      pendingRemoteICECandidateRetries[message.id] = nil
      return
    }

    guard CallSignalParser.isRelayCandidate(candidate.sdp) else {
      pendingRemoteICECandidateRetries[message.id] = nil
      return
    }

    if let retry: PendingRemoteICECandidateRetry = pendingRemoteICECandidateRetries[message.id],
      retry.nextAttemptAt > Date()
    {
      processedMessageIds.remove(message.id)
      return
    }

    do {
      try await mediaEngine.queueRemoteCandidate(candidate)
      pendingRemoteICECandidateRetries[message.id] = nil
    } catch {
      scheduleRemoteICECandidateRetry(messageId: message.id)
    }
  }

  private func scheduleRemoteICECandidateRetry(messageId: String) {
    let failedAttemptCount: Int = (pendingRemoteICECandidateRetries[messageId]?.attemptCount ?? 0) + 1
    guard failedAttemptCount <= Self.remoteICECandidateRetryDelaysSeconds.count else {
      pendingRemoteICECandidateRetries[messageId] = nil
      return
    }

    pendingRemoteICECandidateRetries[messageId] = PendingRemoteICECandidateRetry(
      attemptCount: failedAttemptCount,
      nextAttemptAt: nextRemoteICECandidateRetryDate(failedAttemptCount: failedAttemptCount)
    )
    processedMessageIds.remove(messageId)
  }

  private func nextRemoteICECandidateRetryDate(failedAttemptCount: Int) -> Date {
    Date().addingTimeInterval(remoteICECandidateRetryDelay(failedAttemptCount: failedAttemptCount))
  }

  private func remoteICECandidateRetryDelay(failedAttemptCount: Int) -> TimeInterval {
    let index: Int = min(
      max(0, failedAttemptCount - 1),
      Self.remoteICECandidateRetryDelaysSeconds.count - 1
    )
    return Self.remoteICECandidateRetryDelaysSeconds[index]
  }

  private func updateMediaStatus(_ mediaEngine: WebRTCAutomationEngine) async {
    guard !isFinished else {
      return
    }

    let snapshot: WebRTCMediaFlowSnapshot = await mediaEngine.currentMediaSnapshot()
    let decision: CallMediaRecoveryDecision = recoveryMonitor.evaluate(
      snapshot: snapshot,
      now: Date(),
      hasRemoteDescription: remoteDescriptionApplied,
      hasReportedConnected: hasReportedConnected,
      expectsInboundAudio: remoteMicrophoneEnabled,
      expectsInboundVideo: callType == .video && remoteCameraEnabled,
      expectsOutboundAudio: !isMuted,
      canSendRestartOffer: remoteDescriptionApplied
    )

    switch decision.status {
    case .connected:
      update(state: .connected, status: "Соединено через TURN relay")
      if !hasReportedConnected {
        hasReportedConnected = true
        CallStartupTracer.event("call_media_connected", callId: callId)
        toneController.playConnectedCheckTone()
        SystemCallCoordinator.shared.reportOutgoingConnected(callId: callId)
      }
    case .reconnecting:
      await handleRecoverableDisconnect(decision: decision, mediaEngine: mediaEngine)
    case .failed:
      finish(status: "Связь потеряна", state: .failed("Связь потеряна"))
    case .connecting:
      if remoteDescriptionApplied {
        update(state: .connecting, status: "Подключение медиа через TURN")
      }
    }
  }

  private func handleRecoverableDisconnect(
    decision: CallMediaRecoveryDecision,
    mediaEngine: CallMediaRecoveryControlling
  ) async {
    update(state: .reconnecting, status: "Восстановление соединения через TURN")

    if decision.shouldRefreshRelay {
      do {
        try await refreshRelayConfiguration(mediaEngine)
      } catch {
        update(state: .reconnecting, status: "Ожидание новых TURN credentials")
      }
    }

    if pendingReconnectOfferRetry != nil {
      await flushPendingReconnectOffer(force: true)
      return
    }

    guard decision.shouldSendRestartOffer else {
      return
    }

    do {
      let generatedOffer: CallSessionDescriptionSignal = try await mediaEngine.restartIceAndCreateOffer(callId: callId)
      let offer: CallSessionDescriptionSignal = newLocalOffer(from: generatedOffer)
      let delivered: Bool = try await sendReconnectOfferOrQueueRetry(offer)
      update(
        state: .reconnecting,
        status: delivered
          ? "Reconnect offer отправлен"
          : "Reconnect offer ожидает повторной доставки"
      )
    } catch {
      update(state: .reconnecting, status: "Повторная попытка восстановления")
    }
  }

  private func recoverUnansweredInitialOfferIfNeeded(
    _ mediaEngine: CallOfferRecoveryControlling,
    now: Date = Date()
  ) async {
    guard case .initiator = role,
      !isFinished,
      !remoteDescriptionApplied,
      pendingReconnectOfferRetry == nil,
      state == .waitingForPeer,
      let waitingForPeerStartedAt
    else {
      return
    }

    let elapsed: TimeInterval = now.timeIntervalSince(waitingForPeerStartedAt)
    if elapsed >= unansweredInitialOfferFailureTimeoutSeconds() {
      fail("Не удалось установить соединение: собеседник не ответил на защищенный offer")
      return
    }

    let retryDelays: [TimeInterval] = unansweredInitialOfferRecoveryDelays()
    guard unansweredOfferRecoveryAttemptCount < retryDelays.count else {
      return
    }

    let requiredDelay: TimeInterval = max(0, retryDelays[unansweredOfferRecoveryAttemptCount])
    guard elapsed >= requiredDelay else {
      return
    }

    if let lastUnansweredOfferRecoveryAttemptAt,
      now.timeIntervalSince(lastUnansweredOfferRecoveryAttemptAt) < 1
    {
      return
    }

    unansweredOfferRecoveryAttemptCount += 1
    lastUnansweredOfferRecoveryAttemptAt = now
    update(state: .reconnecting, status: "Повторная отправка offer через TURN")

    do {
      try await refreshRelayConfiguration(mediaEngine)
    } catch {
      update(state: .waitingForPeer, status: "Ожидание новых TURN credentials")
      return
    }

    do {
      try await mediaEngine.rollbackLocalDescription()
      renegotiationState.markLocalOfferRolledBack()
      let generatedOffer: CallSessionDescriptionSignal = try await mediaEngine.restartIceAndCreateOffer(callId: callId)
      let offer: CallSessionDescriptionSignal = newLocalOffer(from: generatedOffer)
      let delivered: Bool = try await sendReconnectOfferOrQueueRetry(offer)
      update(
        state: .waitingForPeer,
        status: delivered
          ? "Вызов отправлен повторно"
          : "Повторный offer ожидает доставки"
      )
    } catch {
      update(state: .waitingForPeer, status: "Ожидание ответа собеседника")
    }
  }

  private func unansweredInitialOfferRecoveryDelays() -> [TimeInterval] {
#if DEBUG
    if let unansweredInitialOfferRecoveryDelaysOverrideForTesting {
      return unansweredInitialOfferRecoveryDelaysOverrideForTesting
    }
#endif
    return Self.unansweredInitialOfferRecoveryDelaysSeconds
  }

  private func unansweredInitialOfferFailureTimeoutSeconds() -> TimeInterval {
#if DEBUG
    if let unansweredInitialOfferFailureTimeoutOverrideForTesting {
      return unansweredInitialOfferFailureTimeoutOverrideForTesting
    }
#endif
    return Self.unansweredInitialOfferFailureTimeoutSeconds
  }

  private func refreshRelayConfiguration(_ mediaEngine: CallMediaRecoveryControlling) async throws {
    let rtcConfig: RTCConfig = try await conversationViewModel.fetchRelayRTCConfig()
    let iceServers: [WebRTC.RTCIceServer] = CallRelayIceServerMapper.map(rtcConfig)
    guard !iceServers.isEmpty else {
      throw WebRTCAutomationEngineError.operationFailed("TURN relay config пустой")
    }

    try mediaEngine.updateRelayIceServers(iceServers)
  }

  private func attachStoredVideoRenderers(to mediaEngine: CallVideoRendererManaging) {
    if let localVideoRenderer {
      mediaEngine.attachLocalVideoRenderer(localVideoRenderer)
    }
    if let remoteVideoRenderer {
      mediaEngine.attachRemoteVideoRenderer(remoteVideoRenderer)
    }
    for additionalRemoteVideoRenderer in additionalRemoteVideoRenderers
      where !isSameRenderer(additionalRemoteVideoRenderer, remoteVideoRenderer)
    {
      mediaEngine.attachRemoteVideoRenderer(additionalRemoteVideoRenderer)
    }
  }

  private func requestMediaPermissions() async -> Bool {
    let microphoneAllowed: Bool = await requestMicrophonePermission()
    guard microphoneAllowed else {
      return false
    }

    guard callType == .video else {
      return true
    }

    return await requestCameraPermission()
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func requestCameraPermission() async -> Bool {
    let status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }

  private func newLocalOffer(
    from description: CallSessionDescriptionSignal
  ) -> CallSessionDescriptionSignal {
    CallSessionDescriptionSignal(
      callId: description.callId,
      fromUserId: description.fromUserId,
      type: description.type,
      sdp: description.sdp,
      dtlsFingerprint: description.dtlsFingerprint,
      offerId: UUID().uuidString.lowercased()
    )
  }

  private func localAnswer(
    _ description: CallSessionDescriptionSignal,
    respondingTo offer: CallSessionDescriptionSignal
  ) -> CallSessionDescriptionSignal {
    CallSessionDescriptionSignal(
      callId: description.callId,
      fromUserId: description.fromUserId,
      type: description.type,
      sdp: description.sdp,
      dtlsFingerprint: description.dtlsFingerprint,
      answerToOfferId: normalizedOfferIdentifier(offer.offerId)
    )
  }

  private func normalizedOfferIdentifier(_ offerId: String?) -> String? {
    guard let normalized: String = offerId?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else {
      return nil
    }

    return normalized
  }

  private func sendCallOffer(_ offer: CallSessionDescriptionSignal, offerKind: String) async throws {
    let dtlsFingerprint: String = try boundDTLSFingerprint(for: offer)
    guard let offerId: String = normalizedOfferIdentifier(offer.offerId) else {
      throw WebRTCAutomationEngineError.operationFailed("Local offer is missing its correlation ID")
    }

    renegotiationState.markLocalOfferSent(offerId: offerId)
    var payload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      dtlsFingerprint: dtlsFingerprint,
      values: [
        "call_type": callType.rawValue,
        "offer_kind": offerKind,
        "offer": [
          "type": offer.type,
          "sdp": offer.sdp,
          "offer_id": offerId,
        ],
      ]
    )
    if let sender: String = conversationViewModel.activeUserId {
      payload["from_user"] = sender
    }

    if offerKind == "initial" {
      _ = try await conversationViewModel.sendSignalingPayload(
        msgType: Message.MessageType.callOffer.rawValue,
        payloadObject: payload
      )
    } else {
      _ = try await conversationViewModel.sendSignalingPayloadRequiringPeerDelivery(
        msgType: Message.MessageType.callOffer.rawValue,
        payloadObject: payload,
        errorMessage: "Reconnect offer delivery incomplete for peer devices"
      )
    }
  }

  @discardableResult
  private func sendReconnectOfferOrQueueRetry(_ offer: CallSessionDescriptionSignal) async throws -> Bool {
    do {
      try await sendCallOffer(offer, offerKind: "ice_restart")
      pendingReconnectOfferRetry = nil
      return true
    } catch {
      guard isRetryableReconnectOfferSendError(error), !isFinished else {
        throw error
      }

      enqueuePendingReconnectOffer(offer, failedAttemptCount: 1)
      return false
    }
  }

  private func flushPendingReconnectOffer(force: Bool = false) async {
    guard let retry: PendingReconnectOfferRetry = pendingReconnectOfferRetry,
      !isFinished,
      !Task.isCancelled
    else {
      return
    }

    guard force || retry.nextAttemptAt <= Date() else {
      return
    }

    do {
      try await sendCallOffer(retry.offer, offerKind: "ice_restart")
      pendingReconnectOfferRetry = nil
      update(state: .reconnecting, status: "Reconnect offer отправлен")
    } catch {
      guard isRetryableReconnectOfferSendError(error), !isFinished, !Task.isCancelled else {
        pendingReconnectOfferRetry = nil
        return
      }

      enqueuePendingReconnectOffer(retry.offer, failedAttemptCount: retry.attemptCount + 1)
      if pendingReconnectOfferRetry != nil {
        update(state: .reconnecting, status: "Reconnect offer ожидает повторной доставки")
      }
    }
  }

  private func enqueuePendingReconnectOffer(
    _ offer: CallSessionDescriptionSignal,
    failedAttemptCount: Int
  ) {
    guard failedAttemptCount <= reconnectOfferPeerDeliveryRetryDelays().count else {
      pendingReconnectOfferRetry = nil
      return
    }

    let attemptCount: Int = max(1, failedAttemptCount)
    pendingReconnectOfferRetry = PendingReconnectOfferRetry(
      offer: offer,
      attemptCount: attemptCount,
      nextAttemptAt: nextReconnectOfferRetryDate(failedAttemptCount: attemptCount)
    )
  }

  private func nextReconnectOfferRetryDate(failedAttemptCount: Int) -> Date {
    Date().addingTimeInterval(reconnectOfferRetryDelay(failedAttemptCount: failedAttemptCount))
  }

  private func reconnectOfferRetryDelay(failedAttemptCount: Int) -> TimeInterval {
    let delays: [TimeInterval] = reconnectOfferPeerDeliveryRetryDelays()
    guard !delays.isEmpty else {
      return 0
    }

    let index: Int = min(
      max(0, failedAttemptCount - 1),
      delays.count - 1
    )
    return max(0, delays[index])
  }

  private func reconnectOfferPeerDeliveryRetryDelays() -> [TimeInterval] {
#if DEBUG
    if let reconnectOfferPeerDeliveryRetryDelaysOverrideForTesting {
      return reconnectOfferPeerDeliveryRetryDelaysOverrideForTesting
    }
#endif
    return Self.reconnectOfferPeerDeliveryRetryDelaysSeconds
  }

  private func sendCallAnswer(_ answer: CallSessionDescriptionSignal) async throws {
    let dtlsFingerprint: String = try boundDTLSFingerprint(for: answer)
    var answerPayload: [String: Any] = [
      "type": answer.type,
      "sdp": answer.sdp,
    ]
    if let answerToOfferId: String = normalizedOfferIdentifier(answer.answerToOfferId) {
      answerPayload["answer_to_offer_id"] = answerToOfferId
    }

    var payload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      dtlsFingerprint: dtlsFingerprint,
      values: [
        "answer": answerPayload,
      ]
    )
    if let sender: String = conversationViewModel.activeUserId {
      payload["from_user"] = sender
    }

    _ = try await conversationViewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callAnswer.rawValue,
      payloadObject: payload,
      errorMessage: "Call answer delivery incomplete for peer devices"
    )
  }

  @discardableResult
  private func sendCallAnswerOrQueueRetry(
    _ answer: CallSessionDescriptionSignal,
    retryState: SessionState,
    retryStatusText: String,
    successStatusText: String
  ) async throws -> Bool {
    do {
      try await sendCallAnswer(answer)
      pendingCallAnswerRetry = nil
      return true
    } catch {
      guard isRetryableCallAnswerSendError(error), !isFinished else {
        throw error
      }

      enqueuePendingCallAnswer(
        answer,
        failedAttemptCount: 1,
        retryState: retryState,
        retryStatusText: retryStatusText,
        successStatusText: successStatusText
      )
      return false
    }
  }

  private func flushPendingCallAnswer(force: Bool = false) async {
    guard let retry: PendingCallAnswerRetry = pendingCallAnswerRetry,
      !isFinished,
      !Task.isCancelled
    else {
      return
    }

    guard force || retry.nextAttemptAt <= Date() else {
      return
    }

    do {
      try await sendCallAnswer(retry.answer)
      pendingCallAnswerRetry = nil
      update(state: retry.retryState, status: retry.successStatusText)
    } catch {
      guard isRetryableCallAnswerSendError(error), !isFinished, !Task.isCancelled else {
        pendingCallAnswerRetry = nil
        return
      }

      enqueuePendingCallAnswer(
        retry.answer,
        failedAttemptCount: retry.attemptCount + 1,
        retryState: retry.retryState,
        retryStatusText: retry.retryStatusText,
        successStatusText: retry.successStatusText
      )
      if pendingCallAnswerRetry != nil {
        update(state: retry.retryState, status: retry.retryStatusText)
      }
    }
  }

  private func enqueuePendingCallAnswer(
    _ answer: CallSessionDescriptionSignal,
    failedAttemptCount: Int,
    retryState: SessionState,
    retryStatusText: String,
    successStatusText: String
  ) {
    guard failedAttemptCount <= callAnswerPeerDeliveryRetryDelays().count else {
      pendingCallAnswerRetry = nil
      return
    }

    pendingCallAnswerRetry = PendingCallAnswerRetry(
      answer: answer,
      attemptCount: max(1, failedAttemptCount),
      nextAttemptAt: nextCallAnswerRetryDate(failedAttemptCount: failedAttemptCount),
      retryState: retryState,
      retryStatusText: retryStatusText,
      successStatusText: successStatusText
    )
  }

  private func nextCallAnswerRetryDate(failedAttemptCount: Int) -> Date {
    Date().addingTimeInterval(callAnswerRetryDelay(failedAttemptCount: failedAttemptCount))
  }

  private func callAnswerRetryDelay(failedAttemptCount: Int) -> TimeInterval {
    let delays: [TimeInterval] = callAnswerPeerDeliveryRetryDelays()
    guard !delays.isEmpty else {
      return 0
    }

    let index: Int = min(
      max(0, failedAttemptCount - 1),
      delays.count - 1
    )
    return max(0, delays[index])
  }

  private func callAnswerPeerDeliveryRetryDelays() -> [TimeInterval] {
#if DEBUG
    if let callAnswerPeerDeliveryRetryDelaysOverrideForTesting {
      return callAnswerPeerDeliveryRetryDelaysOverrideForTesting
    }
#endif
    return Self.callAnswerPeerDeliveryRetryDelaysSeconds
  }

  private func isRetryableCallAnswerSendError(_ error: Error) -> Bool {
    isRetryablePeerDeliverySendError(error)
  }

  private func isRetryableReconnectOfferSendError(_ error: Error) -> Bool {
    isRetryablePeerDeliverySendError(error)
  }

  private func isRetryablePeerDeliverySendError(_ error: Error) -> Bool {
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

  private func boundDTLSFingerprint(for description: CallSessionDescriptionSignal) throws -> String {
    guard let expectedFingerprint: String = description.dtlsFingerprint,
      let actualFingerprint: String = CallSignalParser.dtlsFingerprint(fromSDP: description.sdp),
      expectedFingerprint == actualFingerprint
    else {
      throw WebRTCAutomationEngineError.operationFailed("Local SDP DTLS fingerprint is not transcript-bound")
    }

    return expectedFingerprint
  }

  private func sendICECandidate(_ candidate: CallICECandidateSignal) async {
    do {
      try await sendICECandidatePayload(candidate)
    } catch {
      guard !isFinished, !(error is CancellationError) else {
        return
      }

      enqueuePendingLocalICECandidate(candidate, failedAttemptCount: 1)
    }
  }

  private func sendICECandidatePayload(_ candidate: CallICECandidateSignal) async throws {
    var candidatePayload: [String: Any] = [
      "candidate": candidate.sdp,
      "sdpMLineIndex": Int(candidate.sdpMLineIndex),
    ]
    if let sdpMid: String = candidate.sdpMid, !sdpMid.isEmpty {
      candidatePayload["sdpMid"] = sdpMid
    }

    _ = try await conversationViewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callIceCandidate.rawValue,
      payloadObject: CallSignalEnvelope.payload(
        callId: callId,
        values: [
          "candidate": candidatePayload,
        ]
      ),
      errorMessage: "ICE candidate delivery incomplete for peer devices"
    )
  }

  private func enqueuePendingLocalICECandidate(
    _ candidate: CallICECandidateSignal,
    failedAttemptCount: Int
  ) {
    let retry = PendingLocalICECandidateRetry(
      candidate: candidate,
      attemptCount: max(1, failedAttemptCount),
      nextAttemptAt: nextLocalICECandidateRetryDate(failedAttemptCount: failedAttemptCount)
    )
    if let index = pendingLocalICECandidates.firstIndex(where: { $0.candidate.dedupeKey == candidate.dedupeKey }) {
      pendingLocalICECandidates[index] = retry
      return
    }

    if pendingLocalICECandidates.count >= Self.maxPendingLocalICECandidates {
      pendingLocalICECandidates.removeFirst()
    }
    pendingLocalICECandidates.append(retry)
  }

  private func flushPendingLocalICECandidates(force: Bool = false) async {
    guard !isFinished, !pendingLocalICECandidates.isEmpty else {
      return
    }

    var index = 0
    while index < pendingLocalICECandidates.count && !isFinished && !Task.isCancelled {
      let retry: PendingLocalICECandidateRetry = pendingLocalICECandidates[index]
      if !force, retry.nextAttemptAt > Date() {
        index += 1
        continue
      }

      do {
        try await sendICECandidatePayload(retry.candidate)
        removePendingLocalICECandidate(dedupeKey: retry.candidate.dedupeKey, currentIndex: index)
      } catch {
        guard !isFinished, !(error is CancellationError) else {
          return
        }

        enqueuePendingLocalICECandidate(retry.candidate, failedAttemptCount: retry.attemptCount + 1)
        return
      }
    }
  }

  private func removePendingLocalICECandidate(dedupeKey: String, currentIndex: Int) {
    if currentIndex < pendingLocalICECandidates.count,
      pendingLocalICECandidates[currentIndex].candidate.dedupeKey == dedupeKey
    {
      pendingLocalICECandidates.remove(at: currentIndex)
      return
    }

    pendingLocalICECandidates.removeAll { $0.candidate.dedupeKey == dedupeKey }
  }

  private func nextLocalICECandidateRetryDate(failedAttemptCount: Int) -> Date {
    Date().addingTimeInterval(localICECandidateRetryDelay(failedAttemptCount: failedAttemptCount))
  }

  private func localICECandidateRetryDelay(failedAttemptCount: Int) -> TimeInterval {
    let index: Int = min(
      max(0, failedAttemptCount - 1),
      Self.localICECandidateRetryDelaysSeconds.count - 1
    )
    return Self.localICECandidateRetryDelaysSeconds[index]
  }

  private func sendCallEnd(status: String) async {
    let retryDelays: [TimeInterval] = callEndPeerDeliveryRetryDelays()
    do {
      try await Self.sendCallEndPayload(
        conversationViewModel: conversationViewModel,
        callId: callId,
        status: status
      )
    } catch {
      guard !(error is CancellationError) else {
        return
      }

      Self.scheduleCallEndRetries(
        conversationViewModel: conversationViewModel,
        callId: callId,
        status: status,
        retryDelays: retryDelays
      )
    }
  }

  private static func scheduleCallEndRetries(
    conversationViewModel: ConversationViewModel,
    callId: String,
    status: String,
    retryDelays: [TimeInterval]
  ) {
    guard !retryDelays.isEmpty else {
      return
    }

    Task { @MainActor in
      for delaySeconds in retryDelays {
        let normalizedDelaySeconds: TimeInterval = max(0, delaySeconds)
        if normalizedDelaySeconds > 0 {
          try? await Task.sleep(nanoseconds: UInt64(normalizedDelaySeconds * 1_000_000_000))
        }

        do {
          try await sendCallEndPayload(
            conversationViewModel: conversationViewModel,
            callId: callId,
            status: status
          )
          return
        } catch {
          guard !(error is CancellationError) else {
            return
          }
        }
      }
    }
  }

  private static func sendCallEndPayload(
    conversationViewModel: ConversationViewModel,
    callId: String,
    status: String
  ) async throws {
    _ = try await conversationViewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callEnd.rawValue,
      payloadObject: CallSignalEnvelope.payload(
        callId: callId,
        values: [
          "status": status,
        ]
      ),
      errorMessage: "Call end delivery incomplete for peer devices"
    )
  }

  private func callEndPeerDeliveryRetryDelays() -> [TimeInterval] {
#if DEBUG
    if let callEndPeerDeliveryRetryDelaysOverrideForTesting {
      return callEndPeerDeliveryRetryDelaysOverrideForTesting
    }
#endif
    return Self.callEndPeerDeliveryRetryDelaysSeconds
  }

  private func scheduleMediaStateSend() {
    scheduleMediaStateSend(afterNanoseconds: Self.mediaStateSendDebounceNanoseconds, resetRetry: true)
  }

  private func scheduleMediaStateSend(afterNanoseconds delayNanoseconds: UInt64, resetRetry: Bool) {
    guard !isFinished else {
      return
    }

    if resetRetry {
      mediaStateSendAttemptCount = 0
    }

    let sendId = UUID()
    pendingMediaStateSendId = sendId
    mediaStateTask?.cancel()
    mediaStateTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        return
      }

      await self?.sendScheduledMediaState(sendId: sendId)
    }
  }

  private func sendScheduledMediaState(sendId: UUID) async {
    guard pendingMediaStateSendId == sendId, !isFinished, !Task.isCancelled else {
      return
    }

    pendingMediaStateSendId = nil
    do {
      try await sendMediaStatePayload()
      mediaStateSendAttemptCount = 0
      if pendingMediaStateSendId == nil {
        mediaStateTask = nil
      }
    } catch {
      guard !isFinished, !(error is CancellationError), !Task.isCancelled else {
        if pendingMediaStateSendId == nil {
          mediaStateTask = nil
        }
        return
      }

      scheduleMediaStateRetry()
    }
  }

  private func scheduleMediaStateRetry() {
    let retryDelays: [TimeInterval] = mediaStatePeerDeliveryRetryDelays()
    guard mediaStateSendAttemptCount < retryDelays.count else {
      mediaStateTask = nil
      pendingMediaStateSendId = nil
      return
    }

    let delaySeconds: TimeInterval = max(0, retryDelays[mediaStateSendAttemptCount])
    mediaStateSendAttemptCount += 1
    scheduleMediaStateSend(
      afterNanoseconds: UInt64(delaySeconds * 1_000_000_000),
      resetRetry: false
    )
  }

  private func mediaStatePeerDeliveryRetryDelays() -> [TimeInterval] {
#if DEBUG
    if let mediaStatePeerDeliveryRetryDelaysOverrideForTesting {
      return mediaStatePeerDeliveryRetryDelaysOverrideForTesting
    }
#endif
    return Self.mediaStatePeerDeliveryRetryDelaysSeconds
  }

  private func sendMediaStatePayload() async throws {
    guard !isFinished, !Task.isCancelled else {
      throw CancellationError()
    }

    var values: [String: Any] = [
      "microphone_enabled": !isMuted,
    ]
    if callType == .video {
      values["camera_enabled"] = isCameraEnabled
    }

    _ = try await conversationViewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callMediaState.rawValue,
      payloadObject: CallSignalEnvelope.payload(
        callId: callId,
        values: values
      ),
      errorMessage: "Call media state delivery incomplete for peer devices"
    )
  }

  private func applyRemoteMediaState(_ mediaState: CallMediaStateSignal) {
    remoteMicrophoneEnabled = mediaState.isMicrophoneEnabled
    if let isCameraEnabled: Bool = mediaState.isCameraEnabled {
      remoteCameraEnabled = isCameraEnabled
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

  private func parseICECandidate(from payload: [String: Any]) -> CallICECandidateSignal? {
    CallSignalParser.iceCandidate(from: payload, callId: callId)
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

  private func fail(_ message: String) {
    finish(status: message, state: .failed(message))
  }

  private func finish(
    status: String,
    state: SessionState,
    reportSystemCall: Bool = true
  ) {
    guard !isFinished else {
      return
    }

    isFinished = true
    removeSystemCallObserver()
    toneController.stop()
    pictureInPictureController?.stopAndRelease()
    engine?.stop()
    engine = nil
    sessionTask?.cancel()
    sessionTask = nil
    mediaStateTask?.cancel()
    mediaStateTask = nil
    pendingMediaStateSendId = nil
    mediaStateSendAttemptCount = 0
    pendingLocalICECandidates.removeAll()
    pendingRemoteICECandidateRetries.removeAll()
    pendingCallAnswerRetry = nil
    pendingReconnectOfferRetry = nil
    resetUnansweredOfferRecoveryState()
    additionalRemoteVideoRenderers.removeAll()
    update(state: state, status: status)
    if reportSystemCall {
      SystemCallCoordinator.shared.endCall(callId: callId)
    }
    onFinished?()
    let observers: [() -> Void] = Array(finishObservers.values)
    for observer in observers {
      observer()
    }
    finishObservers.removeAll()
  }

  private func update(state: SessionState, status: String) {
    if state == .waitingForPeer, waitingForPeerStartedAt == nil {
      waitingForPeerStartedAt = Date()
    }

    switch state {
    case .connected, .ended, .failed:
      resetUnansweredOfferRecoveryState()
    case .idle, .connecting, .waitingForPeer, .reconnecting:
      break
    }

    guard self.state != state || statusText != status else {
      return
    }

    self.state = state
    self.statusText = status
    notifyStateChanged()
  }

  private func notifyStateChanged() {
    onStateChanged?()
  }

  private func resetUnansweredOfferRecoveryState() {
    waitingForPeerStartedAt = nil
    lastUnansweredOfferRecoveryAttemptAt = nil
    unansweredOfferRecoveryAttemptCount = 0
  }
}
