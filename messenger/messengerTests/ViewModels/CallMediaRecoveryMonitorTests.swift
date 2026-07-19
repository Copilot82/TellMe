import Foundation
import WebRTC
import XCTest
@testable import messenger

final class CallMediaRecoveryMonitorTests: XCTestCase {
  func testDisconnectedInitiatorRequestsImmediateRestartOfferAndBacksOff() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 1_000)
    let snapshot = makeSnapshot(connectionState: .disconnected, iceConnectionState: .disconnected)

    let first = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(first.status, .reconnecting)
    XCTAssertTrue(first.shouldRefreshRelay)
    XCTAssertTrue(first.shouldSendRestartOffer)

    let tooSoon = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(1),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(tooSoon.status, .reconnecting)
    XCTAssertFalse(tooSoon.shouldRefreshRelay)
    XCTAssertFalse(tooSoon.shouldSendRestartOffer)

    let afterBackoff = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(2),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(afterBackoff.status, .reconnecting)
    XCTAssertTrue(afterBackoff.shouldRefreshRelay)
    XCTAssertTrue(afterBackoff.shouldSendRestartOffer)
  }

  func testPeerWithRemoteDescriptionCanSendRestartOffer() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 2_000)
    let snapshot = makeSnapshot(connectionState: .failed, iceConnectionState: .failed)

    let decision = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .reconnecting)
    XCTAssertTrue(decision.shouldRefreshRelay)
    XCTAssertTrue(decision.shouldSendRestartOffer)
  }

  func testPeerWithoutRemoteDescriptionDoesNotSendRestartOffer() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 2_500)
    let snapshot = makeSnapshot(connectionState: .failed, iceConnectionState: .failed)

    let decision = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: false,
      hasReportedConnected: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .connecting)
    XCTAssertFalse(decision.shouldRefreshRelay)
    XCTAssertFalse(decision.shouldSendRestartOffer)
  }

  func testRemoteDescriptionStuckInCheckingTriggersReconnectAfterEstablishmentGrace() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      connectionEstablishmentGraceSeconds: 3,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 2_750)
    let snapshot = makeSnapshot(connectionState: .new, iceConnectionState: .checking)

    let initial = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(initial.status, .connecting)
    XCTAssertFalse(initial.shouldRefreshRelay)
    XCTAssertFalse(initial.shouldSendRestartOffer)

    let expired = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(4),
      hasRemoteDescription: true,
      hasReportedConnected: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(expired.status, .reconnecting)
    XCTAssertTrue(expired.shouldRefreshRelay)
    XCTAssertTrue(expired.shouldSendRestartOffer)
  }

  func testMediaFlowSnapshotSummaryRedactsRawMediaStats() {
    let snapshot = WebRTCMediaFlowSnapshot(
      outboundAudioBytes: 123_456,
      outboundVideoBytes: 234_567,
      inboundAudioBytes: 345_678,
      inboundVideoBytes: 456_789,
      outboundAudioPackets: 101,
      outboundVideoPackets: 202,
      inboundAudioPackets: 303,
      inboundVideoPackets: 404,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: true,
      connectionState: .connected,
      iceConnectionState: .connected
    )

    let summary = snapshot.summary()

    XCTAssertTrue(summary.contains("audio=present"))
    XCTAssertTrue(summary.contains("video=present"))
    XCTAssertFalse(summary.contains("123456"))
    XCTAssertFalse(summary.contains("456789"))
    XCTAssertFalse(summary.contains("101p"))
    XCTAssertFalse(summary.contains("404p"))
  }

  func testDisconnectFailsAfterGraceWindow() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 3,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 3_000)
    let snapshot = makeSnapshot(connectionState: .disconnected, iceConnectionState: .disconnected)

    _ = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    let expired = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(4),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(expired.status, .failed)
    XCTAssertFalse(expired.shouldRefreshRelay)
    XCTAssertFalse(expired.shouldSendRestartOffer)
  }

  func testConnectedMediaStallTriggersReconnectOffer() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_000)
    let snapshot = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )

    let connected = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(connected.status, .connected)
    XCTAssertFalse(connected.shouldSendRestartOffer)

    let stalled = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(stalled.status, .reconnecting)
    XCTAssertTrue(stalled.shouldRefreshRelay)
    XCTAssertTrue(stalled.shouldSendRestartOffer)
  }

  func testOutboundOnlyProgressDoesNotMaskMissingInboundMedia() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_500)
    let outboundOnly = WebRTCMediaFlowSnapshot(
      outboundAudioBytes: 1_000,
      outboundVideoBytes: 2_000,
      inboundAudioBytes: 0,
      inboundVideoBytes: 0,
      outboundAudioPackets: 20,
      outboundVideoPackets: 30,
      inboundAudioPackets: 0,
      inboundVideoPackets: 0,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: true,
      connectionState: .connected,
      iceConnectionState: .connected
    )

    let connected = monitor.evaluate(
      snapshot: outboundOnly,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(connected.status, .connected)

    let stalled = monitor.evaluate(
      snapshot: WebRTCMediaFlowSnapshot(
        outboundAudioBytes: 3_000,
        outboundVideoBytes: 6_000,
        inboundAudioBytes: 0,
        inboundVideoBytes: 0,
        outboundAudioPackets: 50,
        outboundVideoPackets: 70,
        inboundAudioPackets: 0,
        inboundVideoPackets: 0,
        remoteAudioTrackSeen: true,
        remoteVideoTrackSeen: true,
        connectionState: .connected,
        iceConnectionState: .connected
      ),
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(stalled.status, .reconnecting)
    XCTAssertTrue(stalled.shouldRefreshRelay)
    XCTAssertTrue(stalled.shouldSendRestartOffer)
  }

  func testRemoteMutedMediaStateSuppressesInboundStallReconnect() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_750)
    let snapshot = makeSnapshot(connectionState: .connected, iceConnectionState: .connected, packets: 0)

    let connected = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: false,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    let stillConnected = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(20),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: false,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(connected.status, .connected)
    XCTAssertEqual(stillConnected.status, .connected)
    XCTAssertFalse(stillConnected.shouldRefreshRelay)
    XCTAssertFalse(stillConnected.shouldSendRestartOffer)
  }

  func testInboundMediaExpectationChangeResetsStallBaselineForNewGraceWindow() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_850)
    let snapshot = makeSnapshot(connectionState: .connected, iceConnectionState: .connected, packets: 10)

    let connectedWithAudioAndVideo = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(connectedWithAudioAndVideo.status, .connected)

    let cameraDisabledByPeer = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(cameraDisabledByPeer.status, .connected)
    XCTAssertFalse(cameraDisabledByPeer.shouldRefreshRelay)
    XCTAssertFalse(cameraDisabledByPeer.shouldSendRestartOffer)

    let audioStillStalledAfterNewGraceWindow = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(12),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(audioStillStalledAfterNewGraceWindow.status, .reconnecting)
    XCTAssertTrue(audioStillStalledAfterNewGraceWindow.shouldRefreshRelay)
    XCTAssertTrue(audioStillStalledAfterNewGraceWindow.shouldSendRestartOffer)
  }

  func testNewCallIsNotReportedConnectedBeforeExpectedMediaEvidence() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_900)
    let noMedia = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 0
    )

    let initial = monitor.evaluate(
      snapshot: noMedia,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: false,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(initial.status, .connecting)

    let expired = monitor.evaluate(
      snapshot: noMedia,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: false,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )
    XCTAssertEqual(expired.status, .reconnecting)
    XCTAssertTrue(expired.shouldSendRestartOffer)
  }

  func testVideoProgressDoesNotMaskStalledInboundAudio() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_925)
    let baseline = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )

    XCTAssertEqual(
      monitor.evaluate(
        snapshot: baseline,
        now: start,
        hasRemoteDescription: true,
        hasReportedConnected: true,
        expectsInboundAudio: true,
        expectsInboundVideo: true,
        canSendRestartOffer: true
      ).status,
      .connected
    )

    var videoOnlyProgress = baseline
    videoOnlyProgress.inboundVideoBytes += 10_000
    videoOnlyProgress.inboundVideoPackets += 100
    let decision = monitor.evaluate(
      snapshot: videoOnlyProgress,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .reconnecting)
    XCTAssertTrue(decision.shouldSendRestartOffer)
  }

  func testInboundProgressDoesNotMaskStalledLocalMicrophoneSource() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_950)
    var baseline = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )
    baseline.localAudioSenderSeen = true
    baseline.audioSourceStatsSeen = true
    baseline.outboundAudioSamplesDurationMilliseconds = 1_000
    baseline.audioSessionStateKnown = true
    baseline.audioSessionCanPlayOrRecord = true
    baseline.audioUnitRunning = true

    XCTAssertEqual(
      monitor.evaluate(
        snapshot: baseline,
        now: start,
        hasRemoteDescription: true,
        hasReportedConnected: true,
        expectsInboundAudio: true,
        expectsInboundVideo: false,
        expectsOutboundAudio: true,
        canSendRestartOffer: true
      ).status,
      .connected
    )

    var inboundOnlyProgress = baseline
    inboundOnlyProgress.inboundAudioBytes += 10_000
    inboundOnlyProgress.inboundAudioPackets += 100
    inboundOnlyProgress.outboundAudioBytes += 10_000
    inboundOnlyProgress.outboundAudioPackets += 100
    let decision = monitor.evaluate(
      snapshot: inboundOnlyProgress,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      expectsOutboundAudio: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .reconnecting)
    XCTAssertTrue(decision.shouldRefreshRelay)
    XCTAssertTrue(decision.shouldSendRestartOffer)
  }

  func testStoppedAudioUnitInvalidatesOtherwiseProgressingAudio() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_975)
    var baseline = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )
    baseline.audioSessionStateKnown = true
    baseline.audioSessionCanPlayOrRecord = true
    baseline.audioUnitRunning = true

    _ = monitor.evaluate(
      snapshot: baseline,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    var stopped = baseline
    stopped.inboundAudioBytes += 10_000
    stopped.inboundAudioPackets += 100
    stopped.audioSessionCanPlayOrRecord = false
    stopped.audioUnitRunning = false
    let decision = monitor.evaluate(
      snapshot: stopped,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .reconnecting)
  }

  func testInboundRTPWithoutDecodedSampleProgressTriggersRecovery() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_980)
    var baseline = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )
    baseline.inboundAudioSamplesStatsSeen = true
    baseline.inboundAudioSamplesDurationMilliseconds = 1_000

    _ = monitor.evaluate(
      snapshot: baseline,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    var packetsWithoutDecodedPCM = baseline
    packetsWithoutDecodedPCM.inboundAudioBytes += 100_000
    packetsWithoutDecodedPCM.inboundAudioPackets += 1_000
    let decision = monitor.evaluate(
      snapshot: packetsWithoutDecodedPCM,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(decision.status, .reconnecting)
    XCTAssertTrue(decision.shouldSendRestartOffer)
  }

  func testMissingInputRouteIsSeparatedFromHealthyRemotePlayout() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 4_990)
    var snapshot = makeSnapshot(
      connectionState: .connected,
      iceConnectionState: .connected,
      packets: 10
    )
    snapshot.localAudioSenderSeen = true
    snapshot.audioSourceStatsSeen = true
    snapshot.outboundAudioSamplesDurationMilliseconds = 1_000
    snapshot.audioSessionStateKnown = true
    snapshot.audioSessionCanPlayOrRecord = true
    snapshot.audioUnitRunning = true
    snapshot.audioRouteStateKnown = true
    snapshot.audioInputRouteAvailable = false
    snapshot.audioOutputRouteAvailable = true

    let initial = monitor.evaluate(
      snapshot: snapshot,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: false,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      expectsOutboundAudio: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(initial.status, .connecting)

    snapshot.inboundAudioBytes += 10_000
    snapshot.inboundAudioPackets += 100
    snapshot.outboundAudioSamplesDurationMilliseconds += 1_000
    let expired = monitor.evaluate(
      snapshot: snapshot,
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: false,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      expectsOutboundAudio: true,
      canSendRestartOffer: true
    )

    XCTAssertEqual(expired.status, .reconnecting)
  }

  func testMediaProgressResetsReconnectBackoff() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 10]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 5_000)
    let disconnected = makeSnapshot(connectionState: .disconnected, iceConnectionState: .disconnected)

    let firstReconnect = monitor.evaluate(
      snapshot: disconnected,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertTrue(firstReconnect.shouldSendRestartOffer)

    let progressed = monitor.evaluate(
      snapshot: makeSnapshot(connectionState: .connected, iceConnectionState: .connected, packets: 50),
      now: start.addingTimeInterval(1),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertEqual(progressed.status, .connected)

    let restartedAgainAfterNewFailure = monitor.evaluate(
      snapshot: disconnected,
      now: start.addingTimeInterval(2),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertTrue(restartedAgainAfterNewFailure.shouldSendRestartOffer)
  }

  func testPositiveCounterResetAfterIceRestartCountsAsFreshProgress() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 4,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 5_250)

    _ = monitor.evaluate(
      snapshot: makeSnapshot(
        connectionState: .connected,
        iceConnectionState: .connected,
        packets: 100
      ),
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    let resetCounters = monitor.evaluate(
      snapshot: makeSnapshot(
        connectionState: .connected,
        iceConnectionState: .connected,
        packets: 1
      ),
      now: start.addingTimeInterval(6),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      expectsInboundAudio: true,
      expectsInboundVideo: false,
      canSendRestartOffer: true
    )

    XCTAssertEqual(resetCounters.status, .connected)
    XCTAssertFalse(resetCounters.shouldRefreshRelay)
    XCTAssertFalse(resetCounters.shouldSendRestartOffer)
  }

  func testRelayRefreshContinuesAfterRestartOfferAttemptsAreExhausted() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 3,
      restartRetryDelaysSeconds: [0]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 5_500)
    let disconnected = makeSnapshot(connectionState: .disconnected, iceConnectionState: .disconnected)

    let first = monitor.evaluate(
      snapshot: disconnected,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertTrue(first.shouldRefreshRelay)
    XCTAssertTrue(first.shouldSendRestartOffer)

    let beforeRefreshInterval = monitor.evaluate(
      snapshot: disconnected,
      now: start.addingTimeInterval(1),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertFalse(beforeRefreshInterval.shouldRefreshRelay)
    XCTAssertFalse(beforeRefreshInterval.shouldSendRestartOffer)

    let afterRefreshInterval = monitor.evaluate(
      snapshot: disconnected,
      now: start.addingTimeInterval(3),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: true
    )
    XCTAssertTrue(afterRefreshInterval.shouldRefreshRelay)
    XCTAssertFalse(afterRefreshInterval.shouldSendRestartOffer)
  }

  func testRelayRefreshContinuesWhenRestartOfferCannotBeSentYet() {
    let policy = CallMediaRecoveryPolicy(
      disconnectGraceSeconds: 30,
      mediaStallGraceSeconds: 5,
      relayRefreshIntervalSeconds: 3,
      restartRetryDelaysSeconds: [0, 2, 5]
    )
    var monitor = CallMediaRecoveryMonitor(policy: policy)
    let start = Date(timeIntervalSince1970: 5_750)
    let disconnected = makeSnapshot(connectionState: .disconnected, iceConnectionState: .disconnected)

    let first = monitor.evaluate(
      snapshot: disconnected,
      now: start,
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: false
    )
    XCTAssertTrue(first.shouldRefreshRelay)
    XCTAssertFalse(first.shouldSendRestartOffer)

    let beforeRefreshInterval = monitor.evaluate(
      snapshot: disconnected,
      now: start.addingTimeInterval(1),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: false
    )
    XCTAssertFalse(beforeRefreshInterval.shouldRefreshRelay)
    XCTAssertFalse(beforeRefreshInterval.shouldSendRestartOffer)

    let afterRefreshInterval = monitor.evaluate(
      snapshot: disconnected,
      now: start.addingTimeInterval(3),
      hasRemoteDescription: true,
      hasReportedConnected: true,
      canSendRestartOffer: false
    )
    XCTAssertTrue(afterRefreshInterval.shouldRefreshRelay)
    XCTAssertFalse(afterRefreshInterval.shouldSendRestartOffer)
  }

  private func makeSnapshot(
    connectionState: RTCPeerConnectionState,
    iceConnectionState: RTCIceConnectionState,
    packets: Int64 = 0
  ) -> WebRTCMediaFlowSnapshot {
    WebRTCMediaFlowSnapshot(
      outboundAudioBytes: packets * 80,
      outboundVideoBytes: packets * 120,
      inboundAudioBytes: packets * 70,
      inboundVideoBytes: packets * 110,
      outboundAudioPackets: packets,
      outboundVideoPackets: packets,
      inboundAudioPackets: packets,
      inboundVideoPackets: packets,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: true,
      connectionState: connectionState,
      iceConnectionState: iceConnectionState
    )
  }
}
