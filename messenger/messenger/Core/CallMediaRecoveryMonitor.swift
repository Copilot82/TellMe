import Foundation
import WebRTC

struct CallMediaRecoveryPolicy {
  let disconnectGraceSeconds: TimeInterval
  let connectionEstablishmentGraceSeconds: TimeInterval
  let mediaStallGraceSeconds: TimeInterval
  let relayRefreshIntervalSeconds: TimeInterval
  let restartRetryDelaysSeconds: [TimeInterval]

  init(
    disconnectGraceSeconds: TimeInterval,
    connectionEstablishmentGraceSeconds: TimeInterval = 18,
    mediaStallGraceSeconds: TimeInterval,
    relayRefreshIntervalSeconds: TimeInterval,
    restartRetryDelaysSeconds: [TimeInterval]
  ) {
    self.disconnectGraceSeconds = disconnectGraceSeconds
    self.connectionEstablishmentGraceSeconds = connectionEstablishmentGraceSeconds
    self.mediaStallGraceSeconds = mediaStallGraceSeconds
    self.relayRefreshIntervalSeconds = relayRefreshIntervalSeconds
    self.restartRetryDelaysSeconds = restartRetryDelaysSeconds
  }

  static let production = CallMediaRecoveryPolicy(
    disconnectGraceSeconds: 75,
    connectionEstablishmentGraceSeconds: 18,
    mediaStallGraceSeconds: 12,
    relayRefreshIntervalSeconds: 10,
    restartRetryDelaysSeconds: [0, 2, 5, 10, 15, 20, 30]
  )
}

struct CallMediaRecoveryDecision: Equatable {
  enum Status: Equatable {
    case connected
    case connecting
    case reconnecting
    case failed
  }

  let status: Status
  let shouldRefreshRelay: Bool
  let shouldSendRestartOffer: Bool
}

struct CallMediaRecoveryMonitor {
  private let policy: CallMediaRecoveryPolicy
  private var disconnectedSince: Date?
  private var connectionEstablishingSince: Date?
  private var inboundAudioProgress = ExpectedMediaProgress()
  private var inboundVideoProgress = ExpectedMediaProgress()
  private var outboundAudioProgress = ExpectedMediaProgress()
  private var lastExpectedMediaExpectation: ExpectedMediaExpectation?
  private var lastReconnectAttemptAt: Date?
  private var reconnectAttemptCount: Int = 0
  private var lastRelayRefreshAt: Date?

  init(policy: CallMediaRecoveryPolicy = .production) {
    self.policy = policy
  }

  mutating func evaluate(
    snapshot: WebRTCMediaFlowSnapshot,
    now: Date,
    hasRemoteDescription: Bool,
    hasReportedConnected: Bool,
    expectsInboundAudio: Bool = true,
    expectsInboundVideo: Bool = true,
    expectsOutboundAudio: Bool = false,
    canSendRestartOffer: Bool
  ) -> CallMediaRecoveryDecision {
    let remoteSessionStarted: Bool = hasRemoteDescription || hasReportedConnected
    guard remoteSessionStarted else {
      resetTransientFailureState()
      return connectingDecision()
    }

    if snapshot.isConnectionReady {
      disconnectedSince = nil
      connectionEstablishingSince = nil
      let mediaHealth = consumeExpectedMediaProgress(
        snapshot: snapshot,
        now: now,
        expectsInboundAudio: expectsInboundAudio,
        expectsInboundVideo: expectsInboundVideo,
        expectsOutboundAudio: expectsOutboundAudio
      )
      if mediaHealth.hasStalledRequiredMedia {
        return reconnectingDecision(now: now, canSendRestartOffer: canSendRestartOffer)
      }

      if mediaHealth.allRequiredMediaPresent {
        if mediaHealth.allExpectedMediaProgressed {
          lastReconnectAttemptAt = nil
          reconnectAttemptCount = 0
          lastRelayRefreshAt = nil
        }
        return connectedDecision()
      }

      // Preserve an established call through short route changes and RTP/DTX
      // gaps, but do not announce a new call as connected without evidence from
      // every expected media pipeline.
      return hasReportedConnected ? connectedDecision() : connectingDecision()
    }

    guard snapshot.isRecoverableDisconnect else {
      if connectionEstablishingSince == nil {
        connectionEstablishingSince = now
      }

      if now.timeIntervalSince(connectionEstablishingSince ?? now) >= policy.connectionEstablishmentGraceSeconds {
        return reconnectingDecision(now: now, canSendRestartOffer: canSendRestartOffer)
      }

      return connectingDecision()
    }

    connectionEstablishingSince = nil
    if disconnectedSince == nil {
      disconnectedSince = now
    }

    let disconnectedElapsed: TimeInterval = now.timeIntervalSince(disconnectedSince ?? now)
    guard disconnectedElapsed <= policy.disconnectGraceSeconds else {
      return CallMediaRecoveryDecision(
        status: .failed,
        shouldRefreshRelay: false,
        shouldSendRestartOffer: false
      )
    }

    return reconnectingDecision(now: now, canSendRestartOffer: canSendRestartOffer)
  }

  private mutating func consumeExpectedMediaProgress(
    snapshot: WebRTCMediaFlowSnapshot,
    now: Date,
    expectsInboundAudio: Bool,
    expectsInboundVideo: Bool,
    expectsOutboundAudio: Bool
  ) -> ExpectedMediaHealth {
    let expectation = ExpectedMediaExpectation(
      inboundAudio: expectsInboundAudio,
      inboundVideo: expectsInboundVideo,
      outboundAudio: expectsOutboundAudio
    )
    if let lastExpectedMediaExpectation, lastExpectedMediaExpectation != expectation {
      inboundAudioProgress.reset()
      inboundVideoProgress.reset()
      outboundAudioProgress.reset()
    }
    lastExpectedMediaExpectation = expectation

    let audioIOReady = !snapshot.audioSessionStateKnown
      || (snapshot.audioSessionCanPlayOrRecord && snapshot.audioUnitRunning)
    let audioPlayoutReady = audioIOReady
      && (!snapshot.audioRouteStateKnown || snapshot.audioOutputRouteAvailable)
    let audioCaptureReady = audioIOReady
      && (!snapshot.audioRouteStateKnown || snapshot.audioInputRouteAvailable)
    let inboundAudio = inboundAudioProgress.observe(
      score: snapshot.inboundAudioProgressScore,
      expected: expectsInboundAudio,
      prerequisitesSatisfied: snapshot.remoteAudioTrackSeen && audioPlayoutReady,
      now: now,
      graceSeconds: policy.mediaStallGraceSeconds
    )
    let inboundVideo = inboundVideoProgress.observe(
      score: snapshot.inboundVideoProgressScore,
      expected: expectsInboundVideo,
      prerequisitesSatisfied: snapshot.remoteVideoTrackSeen,
      now: now,
      graceSeconds: policy.mediaStallGraceSeconds
    )
    let outboundAudio = outboundAudioProgress.observe(
      score: snapshot.outboundAudioProgressScore,
      expected: expectsOutboundAudio,
      prerequisitesSatisfied: snapshot.localAudioSenderSeen && audioCaptureReady,
      now: now,
      graceSeconds: policy.mediaStallGraceSeconds
    )
    let observations = [inboundAudio, inboundVideo, outboundAudio]
    return ExpectedMediaHealth(
      allRequiredMediaPresent: observations.allSatisfy(\.hasRequiredEvidence),
      allExpectedMediaProgressed: observations.allSatisfy(\.progressed),
      hasStalledRequiredMedia: observations.contains(where: \.isStalled)
    )
  }

  private mutating func reconnectingDecision(
    now: Date,
    canSendRestartOffer: Bool
  ) -> CallMediaRecoveryDecision {
    let shouldSendRestartOffer: Bool = shouldAttemptRestartOffer(now: now, canSendRestartOffer: canSendRestartOffer)
    let shouldRefreshRelay: Bool = shouldSendRestartOffer || shouldRefreshRelayConfig(now: now)

    if shouldRefreshRelay {
      lastRelayRefreshAt = now
    }

    return CallMediaRecoveryDecision(
      status: .reconnecting,
      shouldRefreshRelay: shouldRefreshRelay,
      shouldSendRestartOffer: shouldSendRestartOffer
    )
  }

  private mutating func shouldAttemptRestartOffer(now: Date, canSendRestartOffer: Bool) -> Bool {
    guard canSendRestartOffer,
      reconnectAttemptCount < policy.restartRetryDelaysSeconds.count
    else {
      return false
    }

    let delayIndex: Int = min(reconnectAttemptCount, policy.restartRetryDelaysSeconds.count - 1)
    let requiredDelay: TimeInterval = policy.restartRetryDelaysSeconds[delayIndex]
    if let lastReconnectAttemptAt,
      now.timeIntervalSince(lastReconnectAttemptAt) < requiredDelay
    {
      return false
    }

    lastReconnectAttemptAt = now
    reconnectAttemptCount += 1
    return true
  }

  private func shouldRefreshRelayConfig(now: Date) -> Bool {
    guard let lastRelayRefreshAt else {
      return true
    }

    return now.timeIntervalSince(lastRelayRefreshAt) >= policy.relayRefreshIntervalSeconds
  }

  private mutating func resetTransientFailureState() {
    disconnectedSince = nil
    connectionEstablishingSince = nil
    inboundAudioProgress.reset()
    inboundVideoProgress.reset()
    outboundAudioProgress.reset()
    lastExpectedMediaExpectation = nil
    lastReconnectAttemptAt = nil
    reconnectAttemptCount = 0
    lastRelayRefreshAt = nil
  }

  private func connectedDecision() -> CallMediaRecoveryDecision {
    CallMediaRecoveryDecision(
      status: .connected,
      shouldRefreshRelay: false,
      shouldSendRestartOffer: false
    )
  }

  private func connectingDecision() -> CallMediaRecoveryDecision {
    CallMediaRecoveryDecision(
      status: .connecting,
      shouldRefreshRelay: false,
      shouldSendRestartOffer: false
    )
  }
}

private struct ExpectedMediaExpectation: Equatable {
  let inboundAudio: Bool
  let inboundVideo: Bool
  let outboundAudio: Bool
}

private struct ExpectedMediaHealth {
  let allRequiredMediaPresent: Bool
  let allExpectedMediaProgressed: Bool
  let hasStalledRequiredMedia: Bool
}

private struct ExpectedMediaObservation {
  let hasRequiredEvidence: Bool
  let progressed: Bool
  let isStalled: Bool
}

private struct ExpectedMediaProgress {
  private var lastScore: Int64?
  private var lastProgressAt: Date?

  mutating func observe(
    score: Int64,
    expected: Bool,
    prerequisitesSatisfied: Bool,
    now: Date,
    graceSeconds: TimeInterval
  ) -> ExpectedMediaObservation {
    guard expected else {
      reset()
      return ExpectedMediaObservation(
        hasRequiredEvidence: true,
        progressed: true,
        isStalled: false
      )
    }

    if lastProgressAt == nil {
      lastProgressAt = now
    }
    let counterAdvancedOrReset: Bool = lastScore == nil
      || score > (lastScore ?? 0)
      || (score > 0 && score < (lastScore ?? 0))
    let progressed = prerequisitesSatisfied
      && score > 0
      && counterAdvancedOrReset
    if progressed {
      lastProgressAt = now
    }
    lastScore = score

    return ExpectedMediaObservation(
      hasRequiredEvidence: prerequisitesSatisfied && score > 0,
      progressed: progressed,
      isStalled: now.timeIntervalSince(lastProgressAt ?? now) >= graceSeconds
    )
  }

  mutating func reset() {
    lastScore = nil
    lastProgressAt = nil
  }
}

extension WebRTCMediaFlowSnapshot {
  var isConnectionReady: Bool {
    connectionState == .connected
      || iceConnectionState == .connected
      || iceConnectionState == .completed
  }

  var isRecoverableDisconnect: Bool {
    connectionState == .disconnected
      || connectionState == .failed
      || iceConnectionState == .disconnected
      || iceConnectionState == .failed
  }

  var mediaProgressScore: Int64 {
    outboundAudioBytes
      + outboundVideoBytes
      + inboundAudioBytes
      + inboundVideoBytes
      + outboundAudioPackets
      + outboundVideoPackets
      + inboundAudioPackets
      + inboundVideoPackets
  }

  var inboundAudioProgressScore: Int64 {
    if inboundAudioSamplesStatsSeen {
      return inboundAudioSamplesDurationMilliseconds
    }
    return inboundAudioBytes + inboundAudioPackets
  }

  var inboundVideoProgressScore: Int64 {
    inboundVideoBytes + inboundVideoPackets
  }

  var outboundAudioProgressScore: Int64 {
    if audioSourceStatsSeen {
      return outboundAudioSamplesDurationMilliseconds
    }
    return outboundAudioBytes + outboundAudioPackets
  }
}
