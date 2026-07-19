import CallKit
import Foundation
import PushKit
import UIKit
import WebRTC

@MainActor
// CallKit state is centralized because incoming pushes can arrive before chat UI is mounted.
final class SystemCallCoordinator: NSObject {
  static let shared = SystemCallCoordinator()

  private enum Constants {
    static let opaqueCallTimeoutSeconds: TimeInterval = 20
    static let missingVoIPTokenPushKitRefreshInterval: TimeInterval = 30
  }

  private let provider: CXProvider
  private let callController: CXCallController = CXCallController()
  private let audioSessionCoordinator: CallAudioSessionCoordinator = .shared
  private var pushRegistry: PKPushRegistry?
  private weak var container: AppContainer?

  private var callIdByUUID: [UUID: String] = [:]
  private var uuidByCallId: [String: UUID] = [:]
  private var incomingByUUID: [UUID: E2EIncomingCallDescriptor] = [:]
  private var opaqueIncomingUUIDs: [UUID: Date] = [:]
  private var answeredBeforeDecryptUUIDs: Set<UUID> = []
  private var acceptedIncomingDescriptors: [E2EIncomingCallDescriptor] = []
  private var acceptedIncomingCallIds: Set<String> = []
  private var callHasVideoByUUID: [UUID: Bool] = [:]
  private var locallyRequestedEndUUIDs: Set<UUID> = []
  private var providerAudioSessionActive: Bool = false
  private var lastMissingVoIPTokenPushKitRefreshAt: Date?
#if DEBUG
  private var autoAcceptedIncomingUUIDs: Set<UUID> = []
  private var incomingDeliveryDiagnosticsByCallId: [String: String] = [:]
#endif

  private struct StoredIncomingCall {
    let uuid: UUID
    let wasReported: Bool
    let descriptor: E2EIncomingCallDescriptor
  }

  private override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = true
    configuration.maximumCallsPerCallGroup = 1
    configuration.maximumCallGroups = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = false
    configuration.ringtoneSound = nil
    self.provider = CXProvider(configuration: configuration)

    super.init()

    provider.setDelegate(self, queue: .main)
    audioSessionCoordinator.installManualAudioModel()
  }

  func attach(container: AppContainer) {
    self.container = container
  }

  func startPushKitIfAvailable() {
    configurePushKitIfAvailable(forceRecreate: false)
  }

  func refreshPushKitRegistrationIfVoIPTokenMissing() {
    guard container?.pushNotificationService.currentVoIPToken() == nil else {
      return
    }

    let now = Date()
    if let lastMissingVoIPTokenPushKitRefreshAt,
      now.timeIntervalSince(lastMissingVoIPTokenPushKitRefreshAt) < Constants.missingVoIPTokenPushKitRefreshInterval
    {
      return
    }

    lastMissingVoIPTokenPushKitRefreshAt = now
    configurePushKitIfAvailable(forceRecreate: true)
  }

  func forceRefreshPushKitRegistrationIfVoIPTokenMissing() {
    guard container?.pushNotificationService.currentVoIPToken() == nil else {
      return
    }

    lastMissingVoIPTokenPushKitRefreshAt = Date()
    configurePushKitIfAvailable(forceRecreate: true)
  }

  private func configurePushKitIfAvailable(forceRecreate: Bool) {
  #if targetEnvironment(simulator)
    _ = forceRecreate
    return
  #else
    guard !AppLaunchConfiguration.current.shouldUseStubNetwork else {
      return
    }

    guard forceRecreate || pushRegistry == nil else {
      return
    }

    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry
  #endif
  }

  func reportOpaqueIncomingWake() {
    let uuid = UUID()
    opaqueIncomingUUIDs[uuid] = Date()
    // The encrypted wake does not reveal the call type. Default to the private
    // receiver route until the descriptor is decrypted; a confirmed video call
    // can safely switch to the speaker profile afterwards.
    callHasVideoByUUID[uuid] = false
    reportNewIncomingCall(
      uuid: uuid,
      displayName: "Защищенный звонок",
      hasVideo: false
    )
    scheduleOpaqueIncomingWakeExpiry(uuid: uuid)
  }

  func clearUnresolvedOpaqueIncomingWakes(reason: CXCallEndedReason = .failed) {
    let uuids: [UUID] = Array(opaqueIncomingUUIDs.keys)
    for uuid in uuids {
      provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
      clearCall(uuid: uuid)
    }
  }

  func reportIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    let stored: StoredIncomingCall = storeIncomingCall(descriptor)
#if DEBUG
    recordIncomingDeliveryForTesting(descriptor)
#endif

    if !stored.wasReported {
      reportNewIncomingCall(
        uuid: stored.uuid,
        displayName: UserHandleDisplay.usernameOnly(from: descriptor.callerUserId),
        hasVideo: descriptor.callType == .video
      )
    } else {
      provider.reportCall(
        with: stored.uuid,
        updated: callUpdate(
          displayName: UserHandleDisplay.usernameOnly(from: descriptor.callerUserId),
          hasVideo: descriptor.callType == .video
        )
      )
    }

    if answeredBeforeDecryptUUIDs.remove(stored.uuid) != nil {
      acceptIncomingCall(stored.descriptor)
    }

#if DEBUG
    autoAcceptIncomingCallForUITestsIfNeeded(uuid: stored.uuid)
#endif
  }

  func answerIncomingCallThroughCallKit(
    _ descriptor: E2EIncomingCallDescriptor,
    audioActivationTimeout: TimeInterval = 8
  ) async -> Bool {
    let stored: StoredIncomingCall = storeIncomingCall(descriptor)
    let displayName: String = UserHandleDisplay.usernameOnly(from: descriptor.callerUserId)

    if !stored.wasReported {
      let reported: Bool = await reportNewIncomingCallAndWait(
        uuid: stored.uuid,
        displayName: displayName,
        hasVideo: descriptor.callType == .video
      )
      guard reported else {
        return false
      }
    } else {
      provider.reportCall(
        with: stored.uuid,
        updated: callUpdate(displayName: displayName, hasVideo: descriptor.callType == .video)
      )
    }

    let hasVideo: Bool = descriptor.callType == .video
    guard audioSessionCoordinator.beginCallKitRequest(callUUID: stored.uuid, hasVideo: hasVideo) else {
      return false
    }
    let action = CXAnswerCallAction(call: stored.uuid)
    let requested: Bool = await requestAndWait(CXTransaction(action: action))
    guard requested else {
      audioSessionCoordinator.markCallKitRequestFailed(callUUID: stored.uuid, hasVideo: hasVideo)
      clearCall(uuid: stored.uuid)
      return false
    }

    return await waitForAudioActivation(callUUID: stored.uuid, timeout: audioActivationTimeout)
  }

  func startOutgoingCallThroughCallKit(
    callId: String,
    peerUserId: String,
    callType: Call.CallType,
    audioActivationTimeout: TimeInterval = 8
  ) async -> Bool {
    let hadExistingCall: Bool = uuidByCallId[callId] != nil
    if hadExistingCall, let existingUUID: UUID = uuidByCallId[callId] {
      return await waitForAudioActivation(callUUID: existingUUID, timeout: audioActivationTimeout)
    }

    guard await waitForPreviousAudioSessionDeactivation(timeout: min(3, audioActivationTimeout)) else {
      return false
    }

    let uuid: UUID = storeOutgoingCall(callId: callId)
    let hasVideo: Bool = callType == .video
    callHasVideoByUUID[uuid] = hasVideo
    guard audioSessionCoordinator.beginCallKitRequest(callUUID: uuid, hasVideo: hasVideo) else {
      clearCall(uuid: uuid)
      return false
    }
    let handle = CXHandle(type: .generic, value: UserHandleDisplay.usernameOnly(from: peerUserId))
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = callType == .video

    let requested: Bool = await requestAndWait(CXTransaction(action: action))
    guard requested else {
      audioSessionCoordinator.markCallKitRequestFailed(callUUID: uuid, hasVideo: hasVideo)
      if !hadExistingCall {
        clearCall(uuid: uuid)
        return false
      }

      return await waitForAudioActivation(callUUID: uuid, timeout: audioActivationTimeout)
    }

    return await waitForAudioActivation(callUUID: uuid, timeout: audioActivationTimeout)
  }

  func waitForCallKitAudioIfManaged(
    callId: String,
    audioActivationTimeout: TimeInterval = 8
  ) async -> Bool {
    guard let uuid: UUID = uuidByCallId[callId],
      audioSessionCoordinator.isManagingCallKitAudio(callUUID: uuid)
    else {
      // A receiver created outside CallKit uses the coordinator's standalone
      // lease. Only an accepted CallKit call must wait for provider activation.
      return true
    }

    return await waitForAudioActivation(callUUID: uuid, timeout: audioActivationTimeout)
  }

  private func storeOutgoingCall(callId: String) -> UUID {
    if let existing: UUID = uuidByCallId[callId] {
      return existing
    }

    let uuid: UUID = UUID(uuidString: callId) ?? UUID()
    callIdByUUID[uuid] = callId
    uuidByCallId[callId] = uuid
    return uuid
  }

  func reportOutgoingConnected(callId: String) {
    guard let uuid: UUID = uuidByCallId[callId] else {
      return
    }

    provider.reportOutgoingCall(with: uuid, connectedAt: Date())
  }

  func diagnosticsSummary() -> String {
    let audio = audioSessionCoordinator.snapshot()
    return [
      "providerAudio=\(providerAudioSessionActive)",
      "audioIO=\(audio.audioIOEnabled)",
      "audioUnit=\(audio.audioUnitRunning)",
      "input=\(audio.inputRouteAvailable)",
      "output=\(audio.outputRouteAvailable)",
      "mapped=\(callIdByUUID.count)",
      "incoming=\(incomingByUUID.count)",
      "opaque=\(opaqueIncomingUUIDs.count)",
      "accepted=\(acceptedIncomingDescriptors.count)",
      "answeredOpaque=\(answeredBeforeDecryptUUIDs.count)",
    ].joined(separator: ",")
  }

  func endCall(callId: String, reason: CXCallEndedReason = .remoteEnded) {
    guard let uuid: UUID = uuidByCallId[callId] else {
      return
    }

    audioSessionCoordinator.beginEnding(callUUID: uuid)
    provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    clearCall(uuid: uuid)
  }

  @discardableResult
  func requestEndCall(callId: String) async -> Bool {
    guard let uuid: UUID = uuidByCallId[callId] else {
      return true
    }

    if locallyRequestedEndUUIDs.contains(uuid) {
      return true
    }

    locallyRequestedEndUUIDs.insert(uuid)
    audioSessionCoordinator.beginEnding(callUUID: uuid)
    let requested: Bool = await requestAndWait(CXTransaction(action: CXEndCallAction(call: uuid)))
    guard requested else {
      locallyRequestedEndUUIDs.remove(uuid)
      provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
      clearCall(uuid: uuid)
      return false
    }
    return true
  }

  func takeAcceptedIncomingCalls() -> [E2EIncomingCallDescriptor] {
    let descriptors: [E2EIncomingCallDescriptor] = acceptedIncomingDescriptors
    acceptedIncomingDescriptors.removeAll()
    return descriptors
  }

  private func request(_ transaction: CXTransaction, onFailure: (@MainActor () -> Void)? = nil) {
    callController.request(transaction) { error in
      guard error != nil else {
        return
      }

      Task { @MainActor in
        onFailure?()
      }
    }
  }

  private func requestAndWait(_ transaction: CXTransaction) async -> Bool {
    await withCheckedContinuation { continuation in
      callController.request(transaction) { error in
        continuation.resume(returning: error == nil)
      }
    }
  }

  private func reportNewIncomingCall(uuid: UUID, displayName: String, hasVideo: Bool) {
    provider.reportNewIncomingCall(
      with: uuid,
      update: callUpdate(displayName: displayName, hasVideo: hasVideo)
    ) { [weak self] error in
      guard error != nil else {
        return
      }

      Task { @MainActor [weak self] in
        self?.clearCall(uuid: uuid)
      }
    }
  }

  private func reportNewIncomingCallAndWait(uuid: UUID, displayName: String, hasVideo: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      provider.reportNewIncomingCall(
        with: uuid,
        update: callUpdate(displayName: displayName, hasVideo: hasVideo)
      ) { [weak self] error in
        if error != nil {
          Task { @MainActor [weak self] in
            self?.clearCall(uuid: uuid)
          }
          continuation.resume(returning: false)
          return
        }

        continuation.resume(returning: true)
      }
    }
  }

  private func scheduleOpaqueIncomingWakeExpiry(uuid: UUID) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Constants.opaqueCallTimeoutSeconds * 1_000_000_000))
      guard let self,
        self.opaqueIncomingUUIDs[uuid] != nil
      else {
        return
      }

      self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
      self.clearCall(uuid: uuid)
    }
  }

  private func waitForAudioActivation(callUUID: UUID, timeout: TimeInterval) async -> Bool {
    if audioSessionCoordinator.isAudioIOEnabled(callUUID: callUUID) {
      return true
    }

    let deadline: Date = Date().addingTimeInterval(max(0, timeout))
    while !audioSessionCoordinator.isAudioIOEnabled(callUUID: callUUID) && Date() < deadline {
      guard !Task.isCancelled else {
        return false
      }
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
      } catch is CancellationError {
        return false
      } catch {
        return false
      }
    }

    return !Task.isCancelled && audioSessionCoordinator.isAudioIOEnabled(callUUID: callUUID)
  }

  private func waitForPreviousAudioSessionDeactivation(timeout: TimeInterval) async -> Bool {
    if audioSessionCoordinator.isAvailableForNewCallKitCall() {
      return true
    }

    let deadline: Date = Date().addingTimeInterval(max(0, timeout))
    while !audioSessionCoordinator.isAvailableForNewCallKitCall() && Date() < deadline {
      guard !Task.isCancelled else {
        return false
      }
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
      } catch is CancellationError {
        return false
      } catch {
        return false
      }
    }

    guard !Task.isCancelled else {
      return false
    }
    if audioSessionCoordinator.isAvailableForNewCallKitCall() {
      return true
    }

    guard callController.callObserver.calls.isEmpty else {
      return false
    }

    let reconciled: Bool = audioSessionCoordinator.reconcileStaleProviderActivation()
    if reconciled {
      providerAudioSessionActive = false
    }
    return audioSessionCoordinator.isAvailableForNewCallKitCall()
  }

  private func storeIncomingCall(_ descriptor: E2EIncomingCallDescriptor) -> StoredIncomingCall {
    let uuid: UUID = resolvedUUID(for: descriptor)
    let wasReported: Bool = callIdByUUID[uuid] != nil || opaqueIncomingUUIDs[uuid] != nil
    let shouldTrackUnansweredIncomingCall: Bool = incomingByUUID[uuid] != nil
      || opaqueIncomingUUIDs[uuid] != nil
      || callIdByUUID[uuid] == nil
    let resolvedDescriptor = E2EIncomingCallDescriptor(
      systemUUID: uuid,
      callId: descriptor.callId,
      conversation: descriptor.conversation,
      offer: descriptor.offer,
      callType: descriptor.callType,
      callerUserId: descriptor.callerUserId
    )

    if shouldTrackUnansweredIncomingCall {
      incomingByUUID[uuid] = resolvedDescriptor
    }
    callIdByUUID[uuid] = descriptor.callId
    uuidByCallId[descriptor.callId] = uuid
    let hasVideo: Bool = descriptor.callType == .video
    callHasVideoByUUID[uuid] = hasVideo
    _ = audioSessionCoordinator.updateCallKitMediaType(callUUID: uuid, hasVideo: hasVideo)
    opaqueIncomingUUIDs[uuid] = nil

    return StoredIncomingCall(uuid: uuid, wasReported: wasReported, descriptor: resolvedDescriptor)
  }

  private func callUpdate(displayName: String, hasVideo: Bool) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: displayName)
    update.localizedCallerName = displayName
    update.hasVideo = hasVideo
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  private func resolvedUUID(for descriptor: E2EIncomingCallDescriptor) -> UUID {
    if let existing: UUID = uuidByCallId[descriptor.callId] {
      return existing
    }

    let cutoff = Date().addingTimeInterval(-Constants.opaqueCallTimeoutSeconds)
    opaqueIncomingUUIDs = opaqueIncomingUUIDs.filter { _, createdAt in
      createdAt >= cutoff
    }

    if let opaque: UUID = opaqueIncomingUUIDs.min(by: { $0.value < $1.value })?.key {
      return opaque
    }

    return descriptor.systemUUID
  }

  private func acceptIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    let uuid: UUID? = uuidByCallId[descriptor.callId]
      ?? callIdByUUID.first(where: { $0.value == descriptor.callId })?.key
    if let uuid {
      incomingByUUID[uuid] = nil
    }
    guard acceptedIncomingCallIds.insert(descriptor.callId).inserted else {
      return
    }
    startAcceptedIncomingCallSession(descriptor)
    acceptedIncomingDescriptors.append(descriptor)
    NotificationCenter.default.post(
      name: .didAcceptSystemIncomingCall,
      object: nil,
      userInfo: ["descriptor": descriptor]
    )
  }

  private func startAcceptedIncomingCallSession(_ descriptor: E2EIncomingCallDescriptor) {
    guard let container else {
      return
    }

    if let existing: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: descriptor.callId) {
      existing.start()
      return
    }

    let conversationViewModel = ConversationViewModel(
      container: container,
      conversation: descriptor.conversation,
      defaults: container.defaults
    )
    let session = E2ECallSessionViewModel(
      conversationViewModel: conversationViewModel,
      role: .receiver(offer: descriptor.offer),
      callId: descriptor.callId,
      peerUserId: descriptor.callerUserId,
      callType: descriptor.callType
    )
    container.e2eCallSessionStore.retain(session).start()
  }

  private func handleAnswerAction(uuid: UUID) {
    if let descriptor: E2EIncomingCallDescriptor = incomingByUUID[uuid] {
      acceptIncomingCall(descriptor)
    } else {
      answeredBeforeDecryptUUIDs.insert(uuid)
    }
  }

  private func handleEndAction(uuid: UUID) {
    audioSessionCoordinator.beginEnding(callUUID: uuid)
    let shouldRejectUnansweredIncomingCall: Bool = incomingByUUID[uuid] != nil
    let wasLocallyRequested: Bool = locallyRequestedEndUUIDs.remove(uuid) != nil
    if !wasLocallyRequested, let callId: String = callIdByUUID[uuid] {
      NotificationCenter.default.post(
        name: .didEndSystemCall,
        object: nil,
        userInfo: [
          "call_id": callId,
          "uuid": uuid,
        ]
      )
    }
    if shouldRejectUnansweredIncomingCall {
      rejectIncomingCall(uuid: uuid)
    } else {
      clearCall(uuid: uuid)
    }
  }

  private func rejectIncomingCall(uuid: UUID) {
    guard let descriptor: E2EIncomingCallDescriptor = incomingByUUID[uuid] else {
      clearCall(uuid: uuid)
      return
    }

    guard let container else {
      clearCall(uuid: uuid)
      return
    }

    Task { @MainActor in
      let viewModel = ConversationViewModel(
        container: container,
        conversation: descriptor.conversation,
        defaults: container.defaults
      )
      _ = try? await viewModel.sendSignalingPayloadRequiringPeerDelivery(
        msgType: Message.MessageType.callEnd.rawValue,
        payloadObject: CallSignalEnvelope.payload(
          callId: descriptor.callId,
          values: [
            "status": "rejected",
          ]
        ),
        errorMessage: "Rejected call delivery incomplete for peer devices"
      )
    }
    clearCall(uuid: uuid)
  }

  private func clearCall(uuid: UUID) {
    if let callId: String = callIdByUUID[uuid] {
      uuidByCallId[callId] = nil
      acceptedIncomingDescriptors.removeAll { $0.callId == callId }
      acceptedIncomingCallIds.remove(callId)
    }
    audioSessionCoordinator.clearCall(callUUID: uuid)
    callIdByUUID[uuid] = nil
    incomingByUUID[uuid] = nil
    opaqueIncomingUUIDs[uuid] = nil
    answeredBeforeDecryptUUIDs.remove(uuid)
    callHasVideoByUUID[uuid] = nil
    locallyRequestedEndUUIDs.remove(uuid)
#if DEBUG
    autoAcceptedIncomingUUIDs.remove(uuid)
#endif
  }

  private func handleProviderReset() {
    let resetCalls: [(uuid: UUID, callId: String)] = callIdByUUID.map { key, value in
      (uuid: key, callId: value)
    }
    audioSessionCoordinator.providerDidReset()
    callIdByUUID.removeAll()
    uuidByCallId.removeAll()
    incomingByUUID.removeAll()
    opaqueIncomingUUIDs.removeAll()
    answeredBeforeDecryptUUIDs.removeAll()
    acceptedIncomingDescriptors.removeAll()
    acceptedIncomingCallIds.removeAll()
    callHasVideoByUUID.removeAll()
    locallyRequestedEndUUIDs.removeAll()
    providerAudioSessionActive = false
#if DEBUG
    autoAcceptedIncomingUUIDs.removeAll()
#endif

    for resetCall in resetCalls {
      NotificationCenter.default.post(
        name: .didEndSystemCall,
        object: nil,
        userInfo: [
          "call_id": resetCall.callId,
          "uuid": resetCall.uuid,
        ]
      )
    }
  }

#if DEBUG
  struct TestingSnapshot: Equatable {
    let callIdByUUID: [UUID: String]
    let uuidByCallId: [String: UUID]
    let incomingCallIdsByUUID: [UUID: String]
    let opaqueIncomingUUIDs: Set<UUID>
    let answeredBeforeDecryptUUIDs: Set<UUID>
    let acceptedCallIds: [String]
    let providerAudioSessionActive: Bool
  }

  func resetForTesting() {
    container = nil
    callIdByUUID.removeAll()
    uuidByCallId.removeAll()
    incomingByUUID.removeAll()
    opaqueIncomingUUIDs.removeAll()
    answeredBeforeDecryptUUIDs.removeAll()
    acceptedIncomingDescriptors.removeAll()
    acceptedIncomingCallIds.removeAll()
    callHasVideoByUUID.removeAll()
    locallyRequestedEndUUIDs.removeAll()
    providerAudioSessionActive = false
    audioSessionCoordinator.resetForTesting()
    autoAcceptedIncomingUUIDs.removeAll()
    incomingDeliveryDiagnosticsByCallId.removeAll()
  }

  func testingSnapshot() -> TestingSnapshot {
    TestingSnapshot(
      callIdByUUID: callIdByUUID,
      uuidByCallId: uuidByCallId,
      incomingCallIdsByUUID: incomingByUUID.mapValues(\.callId),
      opaqueIncomingUUIDs: Set(opaqueIncomingUUIDs.keys),
      answeredBeforeDecryptUUIDs: answeredBeforeDecryptUUIDs,
      acceptedCallIds: acceptedIncomingDescriptors.map(\.callId),
      providerAudioSessionActive: providerAudioSessionActive
    )
  }

  func recordOutgoingCallForTesting(callId: String, uuid: UUID) {
    callIdByUUID[uuid] = callId
    uuidByCallId[callId] = uuid
  }

  @discardableResult
  func storeOutgoingCallForTesting(callId: String) -> UUID {
    storeOutgoingCall(callId: callId)
  }

  func recordOpaqueIncomingWakeForTesting(uuid: UUID, createdAt: Date = Date()) {
    opaqueIncomingUUIDs[uuid] = createdAt
  }

  @discardableResult
  func storeIncomingCallForTesting(_ descriptor: E2EIncomingCallDescriptor) -> UUID {
    storeIncomingCall(descriptor).uuid
  }

  @discardableResult
  func completeIncomingCallDecryptionForTesting(_ descriptor: E2EIncomingCallDescriptor) -> UUID {
    let stored: StoredIncomingCall = storeIncomingCall(descriptor)
    if answeredBeforeDecryptUUIDs.remove(stored.uuid) != nil {
      acceptIncomingCall(stored.descriptor)
    }
    return stored.uuid
  }

  func handleAnswerActionForTesting(uuid: UUID) {
    handleAnswerAction(uuid: uuid)
  }

  func handleEndActionForTesting(uuid: UUID) {
    handleEndAction(uuid: uuid)
  }

  func handleCallControllerRequestFailureForTesting(uuid: UUID) {
    clearCall(uuid: uuid)
  }

  func setProviderAudioSessionActiveForTesting(_ isActive: Bool) {
    providerAudioSessionActive = isActive
  }

  func handleProviderResetForTesting() {
    handleProviderReset()
  }

  func incomingDeliveryDiagnosticsForTesting(callId: String) -> String {
    incomingDeliveryDiagnosticsByCallId[callId] ?? "none"
  }

  private func recordIncomingDeliveryForTesting(_ descriptor: E2EIncomingCallDescriptor) {
    incomingDeliveryDiagnosticsByCallId[descriptor.callId] = [
      "appState=\(applicationStateDescriptionForTesting(UIApplication.shared.applicationState))",
      "type=\(descriptor.callType.rawValue)",
      "caller=\(descriptor.callerUserId)",
    ].joined(separator: ";")
  }

  private func autoAcceptIncomingCallForUITestsIfNeeded(uuid: UUID) {
    guard shouldAutoAcceptIncomingCallsForUITests else {
      return
    }

    guard autoAcceptedIncomingUUIDs.insert(uuid).inserted else {
      return
    }

    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, self.callIdByUUID[uuid] != nil else {
        return
      }

      let action = CXAnswerCallAction(call: uuid)
      self.request(CXTransaction(action: action)) { [weak self] in
        self?.autoAcceptedIncomingUUIDs.remove(uuid)
      }
    }
  }

  private var shouldAutoAcceptIncomingCallsForUITests: Bool {
    let rawValue: String = ProcessInfo.processInfo.environment["E2E_AUTO_ACCEPT_INCOMING_CALL"] ?? ""
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    default:
      return false
    }
  }

  private func applicationStateDescriptionForTesting(_ state: UIApplication.State) -> String {
    switch state {
    case .active:
      return "active"
    case .inactive:
      return "inactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown"
    }
  }
#endif
}

extension SystemCallCoordinator: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    _ = provider
    handleProviderReset()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    _ = provider
    providerAudioSessionActive = true
    audioSessionCoordinator.providerDidActivate(audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    _ = provider
    audioSessionCoordinator.providerDidDeactivate(audioSession)
    providerAudioSessionActive = false
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    _ = provider
    let hasVideo: Bool = callHasVideoByUUID[action.callUUID] ?? action.isVideo
    callHasVideoByUUID[action.callUUID] = hasVideo
    do {
      try audioSessionCoordinator.configureCallKitAudio(callUUID: action.callUUID, hasVideo: hasVideo)
      provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
      action.fulfill()
    } catch {
      audioSessionCoordinator.markCallKitRequestFailed(callUUID: action.callUUID, hasVideo: hasVideo)
      action.fail()
      provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
      clearCall(uuid: action.callUUID)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    _ = provider
    let hasVideo: Bool = callHasVideoByUUID[action.callUUID] ?? false
    do {
      try audioSessionCoordinator.configureCallKitAudio(callUUID: action.callUUID, hasVideo: hasVideo)
      handleAnswerAction(uuid: action.callUUID)
      action.fulfill()
    } catch {
      audioSessionCoordinator.markCallKitRequestFailed(callUUID: action.callUUID, hasVideo: hasVideo)
      action.fail()
      provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
      clearCall(uuid: action.callUUID)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    _ = provider
    handleEndAction(uuid: action.callUUID)
    action.fulfill()
  }
}

extension SystemCallCoordinator: PKPushRegistryDelegate {
  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    _ = registry
    guard type == .voIP else {
      return
    }

    Task { @MainActor in
      await self.container?.pushNotificationService.handleVoIPToken(pushCredentials.token)
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    _ = registry
    guard type == .voIP else {
      return
    }

    Task { @MainActor in
      await self.container?.pushNotificationService.handleVoIPTokenInvalidation()
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    _ = registry
    guard type == .voIP else {
      completion()
      return
    }

    Task { @MainActor in
      self.reportOpaqueIncomingWake()
      let processed: Bool = await self.container?.pushNotificationService.handleRemoteNotification(
        payload.dictionaryPayload
      ) ?? false
      if processed {
        self.clearUnresolvedOpaqueIncomingWakes()
      }
      completion()
    }
  }
}

extension Notification.Name {
  static let didReceiveEncryptedCallOffer: Notification.Name = Notification.Name("didReceiveEncryptedCallOffer")
  static let didAcceptSystemIncomingCall: Notification.Name = Notification.Name("didAcceptSystemIncomingCall")
  static let didEndSystemCall: Notification.Name = Notification.Name("didEndSystemCall")
  static let didRequestActiveCallInterfaceRestore: Notification.Name = Notification.Name(
    "didRequestActiveCallInterfaceRestore"
  )
}
