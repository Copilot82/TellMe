import AVFoundation
import WebRTC
import XCTest
@testable import messenger

final class CallAudioSessionLifecycleStateMachineTests: XCTestCase {
  func testVoiceProfileKeepsReceiverAsDefaultAndAllowsBluetoothHandsFree() {
    let profile = CallAudioSessionProfile.callProfile(hasVideo: false)

    XCTAssertEqual(profile.category, .playAndRecord)
    XCTAssertEqual(profile.mode, .voiceChat)
    XCTAssertTrue(profile.options.contains(.allowBluetoothHFP))
    XCTAssertFalse(profile.options.contains(.defaultToSpeaker))
  }

  func testVideoProfileDefaultsToSpeakerAndAllowsBluetoothHandsFree() {
    let profile = CallAudioSessionProfile.callProfile(hasVideo: true)

    XCTAssertEqual(profile.category, .playAndRecord)
    XCTAssertEqual(profile.mode, .videoChat)
    XCTAssertTrue(profile.options.contains(.allowBluetoothHFP))
    XCTAssertTrue(profile.options.contains(.defaultToSpeaker))
  }

  func testVideoProfileBuildsMatchingWebRTCStartupConfiguration() {
    let configuration = CallAudioSessionProfile.callProfile(hasVideo: true)
      .makeWebRTCConfiguration()

    XCTAssertEqual(configuration.category, AVAudioSession.Category.playAndRecord.rawValue)
    XCTAssertEqual(configuration.mode, AVAudioSession.Mode.videoChat.rawValue)
    XCTAssertTrue(configuration.categoryOptions.contains(.allowBluetoothHFP))
    XCTAssertTrue(configuration.categoryOptions.contains(.defaultToSpeaker))
    XCTAssertEqual(configuration.sampleRate, WebRTCMediaQualityProfile.preferredAudioSampleRate)
    XCTAssertEqual(
      configuration.ioBufferDuration,
      WebRTCMediaQualityProfile.preferredAudioIOBufferDuration
    )
  }

  func testVoiceProfileBuildsWebRTCStartupConfigurationWithoutSpeaker() {
    let configuration = CallAudioSessionProfile.callProfile(hasVideo: false)
      .makeWebRTCConfiguration()

    XCTAssertEqual(configuration.mode, AVAudioSession.Mode.voiceChat.rawValue)
    XCTAssertTrue(configuration.categoryOptions.contains(.allowBluetoothHFP))
    XCTAssertFalse(configuration.categoryOptions.contains(.defaultToSpeaker))
  }

  func testCallKitAudioIOEnablesOnlyAfterConfigurationAndProviderActivation() {
    let callUUID = UUID()
    var state = CallAudioSessionLifecycleStateMachine()

    XCTAssertTrue(state.beginCallKitRequest(callUUID: callUUID, hasVideo: false))
    XCTAssertEqual(state.callKitPhase, .requested(callUUID: callUUID, hasVideo: false))
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertFalse(state.canPlayOrRecord)

    XCTAssertTrue(state.markCallKitConfigured(callUUID: callUUID, hasVideo: false))
    XCTAssertEqual(state.callKitPhase, .configured(callUUID: callUUID, hasVideo: false))
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertFalse(state.canPlayOrRecord)

    XCTAssertTrue(state.providerDidActivate())
    XCTAssertEqual(state.callKitPhase, .active(callUUID: callUUID, hasVideo: false))
    XCTAssertTrue(state.providerAudioSessionActive)
    XCTAssertTrue(state.audioIOEnabled)
    XCTAssertTrue(state.canPlayOrRecord)
  }

  func testProviderActivationBeforeConfigurationDoesNotEnableAudioIO() {
    let callUUID = UUID()
    var state = CallAudioSessionLifecycleStateMachine()

    XCTAssertTrue(state.beginCallKitRequest(callUUID: callUUID, hasVideo: true))
    XCTAssertTrue(state.providerDidActivate())

    XCTAssertEqual(state.callKitPhase, .requested(callUUID: callUUID, hasVideo: true))
    XCTAssertTrue(state.providerAudioSessionActive)
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertFalse(state.canPlayOrRecord)
  }

  func testDuplicateProviderCallbacksAreIgnored() {
    let callUUID = UUID()
    var state = configuredState(callUUID: callUUID)

    XCTAssertTrue(state.providerDidActivate())
    XCTAssertFalse(state.providerDidActivate())
    XCTAssertTrue(state.providerAudioSessionActive)
    XCTAssertTrue(state.audioIOEnabled)

    XCTAssertTrue(state.providerDidDeactivate())
    XCTAssertFalse(state.providerDidDeactivate())
    XCTAssertFalse(state.providerAudioSessionActive)
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertEqual(state.callKitPhase, .configured(callUUID: callUUID, hasVideo: false))
  }

  func testActiveCallKitAudioRejectsReconfigurationThatWouldDisableIO() {
    let callUUID = UUID()
    var state = configuredState(callUUID: callUUID)
    XCTAssertTrue(state.providerDidActivate())

    XCTAssertTrue(state.hasActiveCallKitAudio(callUUID: callUUID, hasVideo: false))
    XCTAssertFalse(state.hasActiveCallKitAudio(callUUID: callUUID, hasVideo: true))
    XCTAssertFalse(state.beginCallKitRequest(callUUID: callUUID, hasVideo: false))
    XCTAssertFalse(state.markCallKitConfigured(callUUID: callUUID, hasVideo: false))
    XCTAssertTrue(state.audioIOEnabled)
  }

  func testActiveOpaqueCallCanAdoptDecryptedVideoProfileWithoutDisablingIO() {
    let callUUID = UUID()
    var state = configuredState(callUUID: callUUID)
    XCTAssertTrue(state.providerDidActivate())

    XCTAssertTrue(state.updateCallKitMediaType(callUUID: callUUID, hasVideo: true))

    XCTAssertEqual(state.callKitPhase, .active(callUUID: callUUID, hasVideo: true))
    XCTAssertEqual(state.currentCallHasVideo, true)
    XCTAssertTrue(state.audioIOEnabled)
    XCTAssertTrue(state.canPlayOrRecord)
  }

  func testEndingDisablesAudioIOBeforeProviderDeactivation() {
    let callUUID = UUID()
    var state = configuredState(callUUID: callUUID)
    XCTAssertTrue(state.providerDidActivate())
    state.updateAudioUnitRunning(true)

    XCTAssertTrue(state.beginEnding(callUUID: callUUID))

    XCTAssertEqual(state.callKitPhase, .ending(callUUID: callUUID, hasVideo: false))
    XCTAssertTrue(state.providerAudioSessionActive)
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertFalse(state.canPlayOrRecord)

    XCTAssertTrue(state.providerDidDeactivate())
    XCTAssertEqual(state.callKitPhase, .idle)
    XCTAssertFalse(state.providerAudioSessionActive)
    XCTAssertFalse(state.audioUnitRunning)
  }

  func testQuickRedialWaitsForPreviousProviderDeactivation() {
    let firstCallUUID = UUID()
    let secondCallUUID = UUID()
    var state = configuredState(callUUID: firstCallUUID)
    XCTAssertTrue(state.providerDidActivate())
    XCTAssertTrue(state.beginEnding(callUUID: firstCallUUID))
    state.clearCall(callUUID: firstCallUUID)

    XCTAssertFalse(state.isAvailableForNewCallKitCall)
    XCTAssertFalse(state.beginCallKitRequest(callUUID: secondCallUUID, hasVideo: true))

    XCTAssertTrue(state.providerDidDeactivate())
    XCTAssertTrue(state.isAvailableForNewCallKitCall)
    XCTAssertTrue(state.beginCallKitRequest(callUUID: secondCallUUID, hasVideo: true))
    XCTAssertEqual(state.callKitPhase, .requested(callUUID: secondCallUUID, hasVideo: true))
  }

  func testFailedCallKitRequestBlocksStandaloneAudioUntilNextCallKitRequest() {
    let failedCallUUID = UUID()
    let nextCallUUID = UUID()
    var state = CallAudioSessionLifecycleStateMachine()
    XCTAssertTrue(state.beginCallKitRequest(callUUID: failedCallUUID, hasVideo: false))

    state.markCallKitRequestFailed(callUUID: failedCallUUID, hasVideo: false)
    state.clearCall(callUUID: failedCallUUID)

    XCTAssertEqual(state.callKitPhase, .idle)
    XCTAssertTrue(state.blocksStandaloneAudioAfterCallKitFailure)
    XCTAssertTrue(state.requiresCallKitManagedAudio)
    XCTAssertFalse(state.beginStandaloneLease(hasVideo: false))

    XCTAssertTrue(state.beginCallKitRequest(callUUID: nextCallUUID, hasVideo: false))
    XCTAssertFalse(state.blocksStandaloneAudioAfterCallKitFailure)
    XCTAssertEqual(state.callKitPhase, .requested(callUUID: nextCallUUID, hasVideo: false))
  }

  func testStandaloneAudioLeasesUseReferenceCounting() {
    var state = CallAudioSessionLifecycleStateMachine()

    XCTAssertTrue(state.beginStandaloneLease(hasVideo: false))
    XCTAssertTrue(state.beginStandaloneLease(hasVideo: false))
    XCTAssertEqual(state.standaloneLeaseCount, 2)
    XCTAssertEqual(state.standaloneHasVideo, false)
    XCTAssertTrue(state.audioIOEnabled)

    XCTAssertFalse(state.endStandaloneLease())
    XCTAssertEqual(state.standaloneLeaseCount, 1)
    XCTAssertTrue(state.audioIOEnabled)

    XCTAssertTrue(state.endStandaloneLease())
    XCTAssertEqual(state.standaloneLeaseCount, 0)
    XCTAssertNil(state.standaloneHasVideo)
    XCTAssertFalse(state.audioIOEnabled)
    XCTAssertFalse(state.canPlayOrRecord)
  }

  func testStandaloneAudioLeasesRejectMixedMediaProfiles() {
    var state = CallAudioSessionLifecycleStateMachine()

    XCTAssertTrue(state.beginStandaloneLease(hasVideo: true))
    XCTAssertFalse(state.beginStandaloneLease(hasVideo: false))
    XCTAssertEqual(state.standaloneLeaseCount, 1)
    XCTAssertEqual(state.standaloneHasVideo, true)

    XCTAssertTrue(state.endStandaloneLease())
    XCTAssertTrue(state.beginStandaloneLease(hasVideo: false))
    XCTAssertEqual(state.standaloneHasVideo, false)
  }

  func testProviderResetPreservesStandaloneAudioState() {
    var state = CallAudioSessionLifecycleStateMachine()
    XCTAssertTrue(state.beginStandaloneLease(hasVideo: false))
    state.updateAudioUnitRunning(true)

    XCTAssertFalse(state.resetCallKitAfterProviderReset())

    XCTAssertEqual(state.standaloneLeaseCount, 1)
    XCTAssertEqual(state.standaloneHasVideo, false)
    XCTAssertTrue(state.audioIOEnabled)
    XCTAssertTrue(state.canPlayOrRecord)
    XCTAssertTrue(state.audioUnitRunning)
  }

  func testProviderResetKeepsStandaloneWebRTCAudioEnabled() throws {
    let coordinator = CallAudioSessionCoordinator.shared
    coordinator.resetForTesting()
    let lease = try coordinator.acquireMediaLease(hasVideo: false)
    defer {
      coordinator.releaseMediaLease(lease)
      coordinator.resetForTesting()
    }

    XCTAssertTrue(RTCAudioSession.sharedInstance().isAudioEnabled)

    coordinator.providerDidReset()

    XCTAssertTrue(RTCAudioSession.sharedInstance().isAudioEnabled)
  }

  func testManualAudioIORestartBudgetResetsOnlyAfterAudioUnitStarts() {
    let callUUID = UUID()
    var state = configuredState(callUUID: callUUID)
    XCTAssertTrue(state.providerDidActivate())

    XCTAssertTrue(state.reserveManualAudioIORestart(maxAttempts: 2))
    state.updateCanPlayOrRecord(true)
    XCTAssertEqual(state.manualAudioIORestartAttempts, 1)
    XCTAssertTrue(state.reserveManualAudioIORestart(maxAttempts: 2))
    XCTAssertFalse(state.reserveManualAudioIORestart(maxAttempts: 2))

    state.updateAudioUnitRunning(true)
    XCTAssertEqual(state.manualAudioIORestartAttempts, 0)
    XCTAssertTrue(state.reserveManualAudioIORestart(maxAttempts: 2))
  }

  func testLegacyMediaFlowSnapshotKeepsPacketBasedAudioFallback() {
    let snapshot = WebRTCMediaFlowSnapshot(
      outboundAudioPackets: 1,
      inboundAudioPackets: 1,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: false,
      connectionState: .connected,
      iceConnectionState: .connected
    )

    XCTAssertTrue(snapshot.hasBidirectionalAudio(minBytes: 1_024))
  }

  func testPhysicalMediaFlowRequiresSenderSamplesSessionAndRoute() {
    let healthy = WebRTCMediaFlowSnapshot(
      outboundAudioPackets: 1,
      inboundAudioPackets: 1,
      localAudioSenderSeen: true,
      audioSourceStatsSeen: true,
      inboundAudioSamplesStatsSeen: true,
      outboundAudioSamplesDurationMilliseconds: 1,
      inboundAudioSamplesDurationMilliseconds: 1,
      outboundAudioEnergyStatsSeen: true,
      inboundAudioEnergyStatsSeen: true,
      outboundAudioEnergy: 0.1,
      inboundAudioEnergy: 0.1,
      audioSessionStateKnown: true,
      audioSessionCanPlayOrRecord: true,
      audioUnitRunning: true,
      audioRouteStateKnown: true,
      audioInputRouteAvailable: true,
      audioOutputRouteAvailable: true,
      audioProfileStateKnown: true,
      audioProfileMatchesExpected: true,
      audioOutputRouteMatchesExpected: true,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: false,
      connectionState: .connected,
      iceConnectionState: .connected
    )
    XCTAssertTrue(healthy.hasBidirectionalAudio(minBytes: 1_024))

    var missingSender = healthy
    missingSender.localAudioSenderSeen = false
    XCTAssertFalse(missingSender.hasBidirectionalAudio(minBytes: 1_024))

    var noCapturedSamples = healthy
    noCapturedSamples.outboundAudioSamplesDurationMilliseconds = 0
    XCTAssertFalse(noCapturedSamples.hasBidirectionalAudio(minBytes: 1_024))

    var noDecodedSamples = healthy
    noDecodedSamples.inboundAudioSamplesDurationMilliseconds = 0
    XCTAssertFalse(noDecodedSamples.hasBidirectionalAudio(minBytes: 1_024))

    var silentMicrophone = healthy
    silentMicrophone.outboundAudioEnergy = 0
    XCTAssertFalse(silentMicrophone.hasBidirectionalAudio(minBytes: 1_024))

    var silentPlayout = healthy
    silentPlayout.inboundAudioEnergy = 0
    XCTAssertFalse(silentPlayout.hasBidirectionalAudio(minBytes: 1_024))

    var stoppedAudioUnit = healthy
    stoppedAudioUnit.audioUnitRunning = false
    XCTAssertFalse(stoppedAudioUnit.hasBidirectionalAudio(minBytes: 1_024))

    var missingInputRoute = healthy
    missingInputRoute.audioInputRouteAvailable = false
    XCTAssertFalse(missingInputRoute.hasBidirectionalAudio(minBytes: 1_024))

    var wrongAudioProfile = healthy
    wrongAudioProfile.audioProfileMatchesExpected = false
    XCTAssertFalse(wrongAudioProfile.hasBidirectionalAudio(minBytes: 1_024))

    var wrongOutputRoute = healthy
    wrongOutputRoute.audioOutputRouteMatchesExpected = false
    XCTAssertFalse(wrongOutputRoute.hasBidirectionalAudio(minBytes: 1_024))
  }

  func testPhysicalAudioProfileAndDefaultRouteMatchCallType() {
    let hfpAndSpeaker: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    XCTAssertTrue(
      WebRTCAutomationEngine.audioSessionProfileMatchesExpected(
        category: .playAndRecord,
        mode: .videoChat,
        options: hfpAndSpeaker,
        hasVideo: true
      )
    )
    XCTAssertTrue(
      WebRTCAutomationEngine.audioOutputRouteMatchesExpected(
        outputPortTypes: [.builtInSpeaker],
        hasVideo: true
      )
    )

    XCTAssertFalse(
      WebRTCAutomationEngine.audioSessionProfileMatchesExpected(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP],
        hasVideo: true
      )
    )
    XCTAssertFalse(
      WebRTCAutomationEngine.audioOutputRouteMatchesExpected(
        outputPortTypes: [.builtInReceiver],
        hasVideo: true
      )
    )

    XCTAssertTrue(
      WebRTCAutomationEngine.audioSessionProfileMatchesExpected(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP],
        hasVideo: false
      )
    )
    XCTAssertTrue(
      WebRTCAutomationEngine.audioOutputRouteMatchesExpected(
        outputPortTypes: [.builtInReceiver],
        hasVideo: false
      )
    )
    XCTAssertTrue(
      WebRTCAutomationEngine.audioOutputRouteMatchesExpected(
        outputPortTypes: [.bluetoothHFP],
        hasVideo: true
      )
    )
  }

  func testMediaFlowSnapshotAudioDiagnosticsDefaultToUnknownOrIdle() {
    let snapshot = WebRTCMediaFlowSnapshot(
      remoteAudioTrackSeen: false,
      remoteVideoTrackSeen: false,
      connectionState: .new,
      iceConnectionState: .new
    )

    XCTAssertFalse(snapshot.localAudioSenderSeen)
    XCTAssertFalse(snapshot.audioSourceStatsSeen)
    XCTAssertFalse(snapshot.inboundAudioSamplesStatsSeen)
    XCTAssertEqual(snapshot.outboundAudioSamplesDurationMilliseconds, 0)
    XCTAssertEqual(snapshot.inboundAudioSamplesDurationMilliseconds, 0)
    XCTAssertFalse(snapshot.audioSessionStateKnown)
    XCTAssertFalse(snapshot.audioSessionCanPlayOrRecord)
    XCTAssertFalse(snapshot.audioUnitRunning)
    XCTAssertFalse(snapshot.audioRouteStateKnown)
    XCTAssertFalse(snapshot.audioInputRouteAvailable)
    XCTAssertFalse(snapshot.audioOutputRouteAvailable)
  }

  func testMediaFlowSnapshotSummaryReportsStateWithoutRawDurations() {
    let snapshot = WebRTCMediaFlowSnapshot(
      localAudioSenderSeen: true,
      audioSourceStatsSeen: true,
      inboundAudioSamplesStatsSeen: true,
      outboundAudioSamplesDurationMilliseconds: 987_654,
      inboundAudioSamplesDurationMilliseconds: 765_432,
      audioSessionStateKnown: true,
      audioSessionCanPlayOrRecord: true,
      audioUnitRunning: true,
      audioRouteStateKnown: true,
      audioInputRouteAvailable: true,
      audioOutputRouteAvailable: true,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: false,
      connectionState: .connected,
      iceConnectionState: .connected
    )

    let summary = snapshot.summary()

    XCTAssertTrue(summary.contains("localAudio(sender=present,source=present"))
    XCTAssertTrue(summary.contains("samplesOut=present,samplesIn=present"))
    XCTAssertTrue(summary.contains("audioSession(state=known,canPlay=true,unit=running"))
    XCTAssertTrue(summary.contains("input=available,output=available"))
    XCTAssertFalse(summary.contains("987654"))
    XCTAssertFalse(summary.contains("765432"))
  }

  private func configuredState(callUUID: UUID) -> CallAudioSessionLifecycleStateMachine {
    var state = CallAudioSessionLifecycleStateMachine()
    XCTAssertTrue(state.beginCallKitRequest(callUUID: callUUID, hasVideo: false))
    XCTAssertTrue(state.markCallKitConfigured(callUUID: callUUID, hasVideo: false))
    return state
  }
}
