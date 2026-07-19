import AVFoundation
import Foundation
import WebRTC

struct CallAudioSessionProfile: Equatable {
  let category: AVAudioSession.Category
  let mode: AVAudioSession.Mode
  let options: AVAudioSession.CategoryOptions

  static func callProfile(hasVideo: Bool) -> CallAudioSessionProfile {
    var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
    if hasVideo {
      options.insert(.defaultToSpeaker)
    }

    return CallAudioSessionProfile(
      category: .playAndRecord,
      mode: hasVideo ? .videoChat : .voiceChat,
      options: options
    )
  }

  func makeWebRTCConfiguration() -> RTCAudioSessionConfiguration {
    let configuration = RTCAudioSessionConfiguration()
    configuration.category = category.rawValue
    configuration.categoryOptions = options
    configuration.mode = mode.rawValue
    configuration.sampleRate = WebRTCMediaQualityProfile.preferredAudioSampleRate
    configuration.ioBufferDuration = WebRTCMediaQualityProfile.preferredAudioIOBufferDuration
    return configuration
  }
}

enum CallAudioSessionLifecycleError: LocalizedError {
  case callKitAudioNotReady
  case audioSessionUnavailable
  case callKitStateChanged
  case mediaProfileMismatch

  var errorDescription: String? {
    switch self {
    case .callKitAudioNotReady:
      return "CallKit has not activated audio for this call"
    case .audioSessionUnavailable:
      return "Another audio session is still active"
    case .callKitStateChanged:
      return "CallKit audio state changed during configuration"
    case .mediaProfileMismatch:
      return "The active audio session uses a different call media profile"
    }
  }
}

struct CallAudioSessionLifecycleStateMachine: Equatable {
  enum CallKitPhase: Equatable {
    case idle
    case requested(callUUID: UUID, hasVideo: Bool)
    case configured(callUUID: UUID, hasVideo: Bool)
    case active(callUUID: UUID, hasVideo: Bool)
    case ending(callUUID: UUID, hasVideo: Bool)
    case failed(callUUID: UUID, hasVideo: Bool)
  }

  private(set) var callKitPhase: CallKitPhase = .idle
  private(set) var providerAudioSessionActive: Bool = false
  private(set) var audioIOEnabled: Bool = false
  private(set) var audioUnitRunning: Bool = false
  private(set) var canPlayOrRecord: Bool = false
  private(set) var standaloneLeaseCount: Int = 0
  private(set) var standaloneHasVideo: Bool?
  private(set) var blocksStandaloneAudioAfterCallKitFailure: Bool = false
  private(set) var manualAudioIORestartAttempts: Int = 0

  var currentCallUUID: UUID? {
    switch callKitPhase {
    case .idle:
      return nil
    case .requested(let callUUID, _),
      .configured(let callUUID, _),
      .active(let callUUID, _),
      .ending(let callUUID, _),
      .failed(let callUUID, _):
      return callUUID
    }
  }

  var currentCallHasVideo: Bool? {
    switch callKitPhase {
    case .idle:
      return nil
    case .requested(_, let hasVideo),
      .configured(_, let hasVideo),
      .active(_, let hasVideo),
      .ending(_, let hasVideo),
      .failed(_, let hasVideo):
      return hasVideo
    }
  }

  var isAvailableForNewCallKitCall: Bool {
    currentCallUUID == nil && !providerAudioSessionActive && standaloneLeaseCount == 0
  }

  var requiresCallKitManagedAudio: Bool {
    currentCallUUID != nil || providerAudioSessionActive || blocksStandaloneAudioAfterCallKitFailure
  }

  mutating func beginCallKitRequest(callUUID: UUID, hasVideo: Bool) -> Bool {
    if currentCallUUID == callUUID {
      switch callKitPhase {
      case .requested(_, let existingHasVideo), .configured(_, let existingHasVideo):
        return existingHasVideo == hasVideo
      case .idle, .active, .ending, .failed:
        return false
      }
    }

    guard isAvailableForNewCallKitCall else {
      return false
    }

    blocksStandaloneAudioAfterCallKitFailure = false
    callKitPhase = .requested(callUUID: callUUID, hasVideo: hasVideo)
    audioIOEnabled = false
    manualAudioIORestartAttempts = 0
    return true
  }

  mutating func markCallKitConfigured(callUUID: UUID, hasVideo: Bool) -> Bool {
    switch callKitPhase {
    case .requested(let currentUUID, let existingHasVideo),
      .configured(let currentUUID, let existingHasVideo):
      guard currentUUID == callUUID, existingHasVideo == hasVideo else {
        return false
      }
      callKitPhase = .configured(callUUID: callUUID, hasVideo: hasVideo)
      audioIOEnabled = false
      return true
    case .idle, .active, .ending, .failed:
      return false
    }
  }

  mutating func updateCallKitMediaType(callUUID: UUID, hasVideo: Bool) -> Bool {
    guard currentCallUUID == callUUID else {
      return false
    }

    switch callKitPhase {
    case .requested:
      callKitPhase = .requested(callUUID: callUUID, hasVideo: hasVideo)
    case .configured:
      callKitPhase = .configured(callUUID: callUUID, hasVideo: hasVideo)
    case .active:
      callKitPhase = .active(callUUID: callUUID, hasVideo: hasVideo)
    case .ending:
      callKitPhase = .ending(callUUID: callUUID, hasVideo: hasVideo)
    case .failed:
      callKitPhase = .failed(callUUID: callUUID, hasVideo: hasVideo)
    case .idle:
      return false
    }
    return true
  }

  func hasActiveCallKitAudio(callUUID: UUID, hasVideo: Bool) -> Bool {
    guard case .active(let activeUUID, let activeHasVideo) = callKitPhase else {
      return false
    }
    return activeUUID == callUUID && activeHasVideo == hasVideo && audioIOEnabled
  }

  mutating func markCallKitRequestFailed(callUUID: UUID, hasVideo: Bool) {
    guard currentCallUUID == callUUID else {
      return
    }

    callKitPhase = .failed(callUUID: callUUID, hasVideo: hasVideo)
    audioIOEnabled = false
    canPlayOrRecord = false
    blocksStandaloneAudioAfterCallKitFailure = true
  }

  mutating func providerDidActivate() -> Bool {
    guard !providerAudioSessionActive else {
      return false
    }

    providerAudioSessionActive = true
    switch callKitPhase {
    case .configured(let callUUID, let hasVideo):
      callKitPhase = .active(callUUID: callUUID, hasVideo: hasVideo)
      audioIOEnabled = true
      canPlayOrRecord = true
      manualAudioIORestartAttempts = 0
    case .active:
      audioIOEnabled = true
      canPlayOrRecord = true
    case .idle, .requested, .ending, .failed:
      audioIOEnabled = false
      canPlayOrRecord = false
    }
    return true
  }

  @discardableResult
  mutating func beginEnding(callUUID: UUID) -> Bool {
    guard currentCallUUID == callUUID else {
      return false
    }

    let hasVideo: Bool
    switch callKitPhase {
    case .requested(_, let value),
      .configured(_, let value),
      .active(_, let value),
      .ending(_, let value),
      .failed(_, let value):
      hasVideo = value
    case .idle:
      return false
    }

    callKitPhase = .ending(callUUID: callUUID, hasVideo: hasVideo)
    audioIOEnabled = false
    canPlayOrRecord = false
    manualAudioIORestartAttempts = 0
    return true
  }

  mutating func clearCall(callUUID: UUID) {
    guard currentCallUUID == callUUID else {
      return
    }

    if providerAudioSessionActive {
      _ = beginEnding(callUUID: callUUID)
    } else {
      callKitPhase = .idle
      audioIOEnabled = false
      canPlayOrRecord = false
    }
  }

  mutating func providerDidDeactivate() -> Bool {
    guard providerAudioSessionActive else {
      return false
    }

    providerAudioSessionActive = false
    audioIOEnabled = false
    canPlayOrRecord = false
    audioUnitRunning = false
    manualAudioIORestartAttempts = 0
    switch callKitPhase {
    case .active(let callUUID, let hasVideo):
      callKitPhase = .configured(callUUID: callUUID, hasVideo: hasVideo)
    case .ending, .failed:
      callKitPhase = .idle
    case .idle, .requested, .configured:
      break
    }
    return true
  }

  mutating func reconcileStaleProviderActivation() -> Bool {
    guard providerAudioSessionActive else {
      return false
    }

    providerAudioSessionActive = false
    audioIOEnabled = false
    canPlayOrRecord = false
    audioUnitRunning = false
    manualAudioIORestartAttempts = 0
    callKitPhase = .idle
    return true
  }

  mutating func resetCallKitAfterProviderReset() -> Bool {
    let shouldForwardDeactivation: Bool = providerAudioSessionActive
    providerAudioSessionActive = false
    callKitPhase = .idle
    blocksStandaloneAudioAfterCallKitFailure = false
    manualAudioIORestartAttempts = 0
    if standaloneLeaseCount == 0 {
      audioIOEnabled = false
      canPlayOrRecord = false
      audioUnitRunning = false
    }
    return shouldForwardDeactivation
  }

  mutating func beginStandaloneLease(hasVideo: Bool) -> Bool {
    guard !requiresCallKitManagedAudio else {
      return false
    }
    if let standaloneHasVideo, standaloneHasVideo != hasVideo {
      return false
    }

    standaloneLeaseCount += 1
    standaloneHasVideo = hasVideo
    audioIOEnabled = true
    canPlayOrRecord = true
    if standaloneLeaseCount == 1 {
      manualAudioIORestartAttempts = 0
    }
    return true
  }

  mutating func endStandaloneLease() -> Bool {
    guard standaloneLeaseCount > 0 else {
      return false
    }

    standaloneLeaseCount -= 1
    if standaloneLeaseCount == 0 {
      standaloneHasVideo = nil
      audioIOEnabled = false
      canPlayOrRecord = false
      audioUnitRunning = false
      manualAudioIORestartAttempts = 0
      return true
    }
    return false
  }

  mutating func clearCallKitFailureBlock() {
    blocksStandaloneAudioAfterCallKitFailure = false
    if case .failed = callKitPhase, !providerAudioSessionActive {
      callKitPhase = .idle
    }
  }

  mutating func updateCanPlayOrRecord(_ value: Bool) {
    canPlayOrRecord = value && audioIOEnabled
  }

  mutating func updateAudioUnitRunning(_ value: Bool) {
    audioUnitRunning = value && audioIOEnabled
    if audioUnitRunning {
      manualAudioIORestartAttempts = 0
    }
  }

  mutating func reserveManualAudioIORestart(maxAttempts: Int) -> Bool {
    guard audioIOEnabled, manualAudioIORestartAttempts < maxAttempts else {
      return false
    }

    manualAudioIORestartAttempts += 1
    audioUnitRunning = false
    return true
  }

  mutating func reset() {
    self = CallAudioSessionLifecycleStateMachine()
  }
}

struct CallAudioSessionRuntimeSnapshot: Equatable {
  let stateKnown: Bool
  let providerAudioSessionActive: Bool
  let audioIOEnabled: Bool
  let canPlayOrRecord: Bool
  let audioUnitRunning: Bool
  let routeStateKnown: Bool
  let inputRouteAvailable: Bool
  let outputRouteAvailable: Bool
  let currentCallUUID: UUID?
  let blocksStandaloneAudio: Bool
}

enum CallAudioSessionLease: Equatable {
  case callKitManaged(callUUID: UUID)
  case standalone(id: UUID)
}

final class CallAudioSessionCoordinator: NSObject, @unchecked Sendable {
  static let shared = CallAudioSessionCoordinator()

  private enum MediaLeaseDecision {
    case callKitManaged(callUUID: UUID)
    case standalone(id: UUID, isFirst: Bool)
    case callKitNotReady
    case mediaProfileMismatch
    case unavailable
  }

  private enum Constants {
    static let maximumManualAudioIORestartAttempts: Int = 2
    static let manualAudioIORestartDelay: TimeInterval = 0.2
  }

  private let stateLock = NSLock()
  private let mediaLeaseOperationLock = NSLock()
  private let audioRecoveryQueue = DispatchQueue(label: "org.tellme.call-audio-recovery")
  private let rtcAudioSession: RTCAudioSession
  private var state: CallAudioSessionLifecycleStateMachine = CallAudioSessionLifecycleStateMachine()
  private var standaloneLeaseIds: Set<UUID> = []
  private var pendingManualAudioIORestartId: UUID?

  private init(rtcAudioSession: RTCAudioSession = RTCAudioSession.sharedInstance()) {
    self.rtcAudioSession = rtcAudioSession
    super.init()
    rtcAudioSession.add(self)
    installManualAudioModel()
  }

  func installManualAudioModel() {
    rtcAudioSession.useManualAudio = true
    rtcAudioSession.isAudioEnabled = false
  }

  func beginCallKitRequest(callUUID: UUID, hasVideo: Bool) -> Bool {
    withState { state in
      state.beginCallKitRequest(callUUID: callUUID, hasVideo: hasVideo)
    }
  }

  func configureCallKitAudio(callUUID: UUID, hasVideo: Bool) throws {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let isAlreadyActive: Bool = withState { state in
      state.hasActiveCallKitAudio(callUUID: callUUID, hasVideo: hasVideo)
    }
    if isAlreadyActive {
      return
    }

    guard beginCallKitRequest(callUUID: callUUID, hasVideo: hasVideo) else {
      throw CallAudioSessionLifecycleError.audioSessionUnavailable
    }

    rtcAudioSession.useManualAudio = true
    rtcAudioSession.isAudioEnabled = false
    try applyProfile(CallAudioSessionProfile.callProfile(hasVideo: hasVideo))
    guard withState({ state in
      state.markCallKitConfigured(callUUID: callUUID, hasVideo: hasVideo)
    }) else {
      throw CallAudioSessionLifecycleError.callKitStateChanged
    }
  }

  func markCallKitRequestFailed(callUUID: UUID, hasVideo: Bool) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    withState { state in
      state.markCallKitRequestFailed(callUUID: callUUID, hasVideo: hasVideo)
    }
    rtcAudioSession.isAudioEnabled = false
  }

  @discardableResult
  func updateCallKitMediaType(callUUID: UUID, hasVideo: Bool) -> Bool {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let currentMediaType: Bool? = withState { state in
      guard state.currentCallUUID == callUUID else {
        return nil
      }
      return state.currentCallHasVideo
    }
    guard let currentMediaType else {
      return false
    }
    guard currentMediaType != hasVideo else {
      return true
    }

    do {
      try applyProfile(CallAudioSessionProfile.callProfile(hasVideo: hasVideo))
    } catch {
      return false
    }

    return withState { state in
      state.updateCallKitMediaType(callUUID: callUUID, hasVideo: hasVideo)
    }
  }

  func providerDidActivate(_ session: AVAudioSession) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let shouldForward: Bool = withState { state in
      pendingManualAudioIORestartId = nil
      return state.providerDidActivate()
    }
    guard shouldForward else {
      return
    }

    rtcAudioSession.audioSessionDidActivate(session)
    let shouldEnableIO: Bool = withState { state in
      state.audioIOEnabled
    }
    rtcAudioSession.isAudioEnabled = shouldEnableIO
  }

  func beginEnding(callUUID: UUID) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let shouldDisableIO: Bool = withState { state in
      pendingManualAudioIORestartId = nil
      return state.beginEnding(callUUID: callUUID)
    }
    if shouldDisableIO {
      rtcAudioSession.isAudioEnabled = false
    }
  }

  func clearCall(callUUID: UUID) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let shouldDisableIO: Bool = withState { state in
      if state.currentCallUUID == callUUID {
        pendingManualAudioIORestartId = nil
      }
      let wasAudioIOEnabled: Bool = state.audioIOEnabled
      state.clearCall(callUUID: callUUID)
      return wasAudioIOEnabled && !state.audioIOEnabled
    }
    if shouldDisableIO {
      rtcAudioSession.isAudioEnabled = false
    }
  }

  func providerDidDeactivate(_ session: AVAudioSession) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let shouldForward: Bool = withState { state in
      pendingManualAudioIORestartId = nil
      return state.providerDidDeactivate()
    }
    rtcAudioSession.isAudioEnabled = false
    guard shouldForward else {
      return
    }

    rtcAudioSession.audioSessionDidDeactivate(session)
  }

  @discardableResult
  func reconcileStaleProviderActivation() -> Bool {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    rtcAudioSession.isAudioEnabled = false
    let shouldForward: Bool = withState { state in
      pendingManualAudioIORestartId = nil
      return state.reconcileStaleProviderActivation()
    }
    guard shouldForward else {
      return false
    }

    rtcAudioSession.audioSessionDidDeactivate(rtcAudioSession.session)
    return true
  }

  func providerDidReset() {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let resetOutcome: (shouldForwardDeactivation: Bool, preserveStandaloneAudio: Bool) = withState { state in
      pendingManualAudioIORestartId = nil
      let preserveStandaloneAudio: Bool = state.standaloneLeaseCount > 0
      return (state.resetCallKitAfterProviderReset(), preserveStandaloneAudio)
    }
    if !resetOutcome.preserveStandaloneAudio {
      rtcAudioSession.isAudioEnabled = false
    }
    if resetOutcome.shouldForwardDeactivation {
      rtcAudioSession.audioSessionDidDeactivate(rtcAudioSession.session)
    }
    if resetOutcome.preserveStandaloneAudio {
      rtcAudioSession.isAudioEnabled = true
    }
  }

  func acquireMediaLease(hasVideo: Bool) throws -> CallAudioSessionLease {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    let leaseId = UUID()
    let decision: MediaLeaseDecision = withState { state in
      if state.requiresCallKitManagedAudio {
        guard let callUUID: UUID = state.currentCallUUID, state.audioIOEnabled else {
          return .callKitNotReady
        }
        guard state.currentCallHasVideo == hasVideo else {
          return .mediaProfileMismatch
        }
        return .callKitManaged(callUUID: callUUID)
      }

      guard state.beginStandaloneLease(hasVideo: hasVideo) else {
        return state.standaloneLeaseCount > 0 ? .mediaProfileMismatch : .unavailable
      }
      standaloneLeaseIds.insert(leaseId)
      return .standalone(id: leaseId, isFirst: state.standaloneLeaseCount == 1)
    }

    switch decision {
    case .callKitManaged(let callUUID):
      return .callKitManaged(callUUID: callUUID)
    case .callKitNotReady:
      throw CallAudioSessionLifecycleError.callKitAudioNotReady
    case .mediaProfileMismatch:
      throw CallAudioSessionLifecycleError.mediaProfileMismatch
    case .unavailable:
      throw CallAudioSessionLifecycleError.audioSessionUnavailable
    case .standalone(let leaseId, let isFirstStandaloneLease):
      if isFirstStandaloneLease {
        do {
          try applyProfile(CallAudioSessionProfile.callProfile(hasVideo: hasVideo))
          rtcAudioSession.lockForConfiguration()
          defer {
            rtcAudioSession.unlockForConfiguration()
          }
          try rtcAudioSession.setActive(true)
          rtcAudioSession.isAudioEnabled = true
        } catch {
          releaseStandaloneLeaseAfterFailedActivation(leaseId)
          throw error
        }
      }
      return .standalone(id: leaseId)
    }
  }

  func releaseMediaLease(_ lease: CallAudioSessionLease) {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    switch lease {
    case .callKitManaged:
      break
    case .standalone(let leaseId):
      let shouldDeactivate: Bool = withState { state in
        guard standaloneLeaseIds.remove(leaseId) != nil else {
          return false
        }
        let isLastLease: Bool = state.endStandaloneLease()
        if isLastLease {
          pendingManualAudioIORestartId = nil
        }
        return isLastLease
      }
      guard shouldDeactivate else {
        return
      }

      rtcAudioSession.isAudioEnabled = false
      rtcAudioSession.lockForConfiguration()
      try? rtcAudioSession.setActive(false)
      rtcAudioSession.unlockForConfiguration()
    }
  }

  func updateCanPlayOrRecord(_ canPlayOrRecord: Bool) {
    withState { state in
      state.updateCanPlayOrRecord(canPlayOrRecord)
    }
    if !canPlayOrRecord {
      requestManualAudioIORestartIfNeeded()
    }
  }

  func updateAudioUnitRunning(_ isRunning: Bool) {
    withState { state in
      state.updateAudioUnitRunning(isRunning)
    }
  }

  func reportAudioUnitStartFailure() {
    withState { state in
      state.updateAudioUnitRunning(false)
    }
    requestManualAudioIORestartIfNeeded()
  }

  func reportAudioUnitStopped() {
    withState { state in
      state.updateAudioUnitRunning(false)
    }
    requestManualAudioIORestartIfNeeded()
  }

  func snapshot() -> CallAudioSessionRuntimeSnapshot {
    let lifecycleState: CallAudioSessionLifecycleStateMachine = withState { $0 }
    let route: AVAudioSessionRouteDescription = rtcAudioSession.session.currentRoute
    return CallAudioSessionRuntimeSnapshot(
      stateKnown: true,
      providerAudioSessionActive: lifecycleState.providerAudioSessionActive,
      audioIOEnabled: lifecycleState.audioIOEnabled,
      canPlayOrRecord: lifecycleState.canPlayOrRecord,
      audioUnitRunning: lifecycleState.audioUnitRunning,
      routeStateKnown: true,
      inputRouteAvailable: !route.inputs.isEmpty,
      outputRouteAvailable: !route.outputs.isEmpty,
      currentCallUUID: lifecycleState.currentCallUUID,
      blocksStandaloneAudio: lifecycleState.requiresCallKitManagedAudio
    )
  }

  func isAudioIOEnabled(callUUID: UUID) -> Bool {
    let lifecycleState: CallAudioSessionLifecycleStateMachine = withState { $0 }
    return lifecycleState.currentCallUUID == callUUID && lifecycleState.audioIOEnabled
  }

  func isManagingCallKitAudio(callUUID: UUID) -> Bool {
    withState { state in
      state.currentCallUUID == callUUID
    }
  }

  func isAvailableForNewCallKitCall() -> Bool {
    withState { state in
      state.isAvailableForNewCallKitCall
    }
  }

#if DEBUG
  func resetForTesting() {
    mediaLeaseOperationLock.lock()
    defer {
      mediaLeaseOperationLock.unlock()
    }

    rtcAudioSession.isAudioEnabled = false
    stateLock.lock()
    state.reset()
    standaloneLeaseIds.removeAll()
    pendingManualAudioIORestartId = nil
    stateLock.unlock()
    installManualAudioModel()
  }
#endif

  private func applyProfile(_ profile: CallAudioSessionProfile) throws {
    let webRTCConfiguration: RTCAudioSessionConfiguration = profile.makeWebRTCConfiguration()

    rtcAudioSession.lockForConfiguration()
    defer {
      rtcAudioSession.unlockForConfiguration()
    }

    // WebRTC applies its process-wide default again when the audio unit starts.
    // Keep that startup configuration aligned with the CallKit profile or a
    // video call falls back from VideoChat/Speaker to VoiceChat/Receiver.
    // Install it while holding WebRTC's configuration lock so the global
    // startup profile and the live AVAudioSession cannot diverge.
    RTCAudioSessionConfiguration.setWebRTC(webRTCConfiguration)

    try rtcAudioSession.setCategory(profile.category, with: profile.options)
    try rtcAudioSession.setMode(profile.mode)
    rtcAudioSession.ignoresPreferredAttributeConfigurationErrors = true
    try? rtcAudioSession.setPreferredSampleRate(WebRTCMediaQualityProfile.preferredAudioSampleRate)
    try? rtcAudioSession.setPreferredIOBufferDuration(WebRTCMediaQualityProfile.preferredAudioIOBufferDuration)
  }

  private func releaseStandaloneLeaseAfterFailedActivation(_ leaseId: UUID) {
    withState { state in
      if standaloneLeaseIds.remove(leaseId) != nil {
        _ = state.endStandaloneLease()
      }
    }
    rtcAudioSession.isAudioEnabled = false
  }

  private func requestManualAudioIORestartIfNeeded() {
    let restartId = UUID()
    let shouldRestart: Bool = withState { state in
      guard pendingManualAudioIORestartId == nil,
        state.reserveManualAudioIORestart(maxAttempts: Constants.maximumManualAudioIORestartAttempts)
      else {
        return false
      }
      pendingManualAudioIORestartId = restartId
      return true
    }
    guard shouldRestart else {
      return
    }

    // Restart only WebRTC's manual audio I/O. The local audio track's mute state
    // is user-owned and must remain untouched during recovery. Dispatching both
    // phases avoids mutating RTCAudioSession reentrantly from its delegate callback.
    audioRecoveryQueue.async { [weak self] in
      guard let self else {
        return
      }

      self.mediaLeaseOperationLock.lock()
      let shouldDisableIO: Bool = self.withState { state in
        self.pendingManualAudioIORestartId == restartId && state.audioIOEnabled
      }
      guard shouldDisableIO else {
        self.mediaLeaseOperationLock.unlock()
        return
      }
      self.rtcAudioSession.isAudioEnabled = false
      self.mediaLeaseOperationLock.unlock()

      self.audioRecoveryQueue.asyncAfter(deadline: .now() + Constants.manualAudioIORestartDelay) { [weak self] in
        guard let self else {
          return
        }

        self.mediaLeaseOperationLock.lock()
        defer {
          self.mediaLeaseOperationLock.unlock()
        }
        let shouldEnableIO: Bool = self.withState { state in
          guard self.pendingManualAudioIORestartId == restartId else {
            return false
          }
          self.pendingManualAudioIORestartId = nil
          return state.audioIOEnabled
        }
        if shouldEnableIO {
          self.rtcAudioSession.isAudioEnabled = true
        }
      }
    }
  }

  private func withState<T>(_ body: (inout CallAudioSessionLifecycleStateMachine) -> T) -> T {
    stateLock.lock()
    defer {
      stateLock.unlock()
    }
    return body(&state)
  }
}

extension CallAudioSessionCoordinator: RTCAudioSessionDelegate {
  func audioSession(
    _ audioSession: RTCAudioSession,
    didChangeCanPlayOrRecord canPlayOrRecord: Bool
  ) {
    _ = audioSession
    updateCanPlayOrRecord(canPlayOrRecord)
  }

  func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
    _ = session
    updateAudioUnitRunning(true)
  }

  func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
    _ = session
    reportAudioUnitStopped()
  }

  func audioSession(
    _ audioSession: RTCAudioSession,
    audioUnitStartFailedWithError error: Error
  ) {
    _ = audioSession
    _ = error
    reportAudioUnitStartFailure()
  }
}
