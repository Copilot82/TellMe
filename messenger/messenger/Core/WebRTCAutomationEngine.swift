import AVFoundation
import Foundation
import WebRTC

enum WebRTCAutomationEngineError: Error {
  case peerConnectionCreationFailed
  case cameraUnavailable
  case cameraFormatUnavailable
  case signalingStateInvalid(String)
  case operationFailed(String)
}

extension WebRTCAutomationEngineError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .peerConnectionCreationFailed:
      return "WebRTC peer connection could not be created"
    case .cameraUnavailable:
      return "Camera unavailable"
    case .cameraFormatUnavailable:
      return "Camera format unavailable"
    case .signalingStateInvalid(let state):
      return "Invalid WebRTC signaling state: \(state)"
    case .operationFailed(let message):
      return message
    }
  }
}

private extension WebRTCAutomationEngine {
  static func candidateType(_ sdp: String) -> String {
    let parts: [Substring] = sdp.split(separator: " ")
    guard let typeKeyIndex: Array<Substring>.Index = parts.firstIndex(of: "typ") else {
      return "unknown"
    }

    let typeIndex: Array<Substring>.Index = parts.index(after: typeKeyIndex)
    guard parts.indices.contains(typeIndex) else {
      return "unknown"
    }

    return String(parts[typeIndex])
  }
}

struct WebRTCMediaFlowSnapshot {
  var outboundAudioBytes: Int64 = 0
  var outboundVideoBytes: Int64 = 0
  var inboundAudioBytes: Int64 = 0
  var inboundVideoBytes: Int64 = 0
  var outboundAudioPackets: Int64 = 0
  var outboundVideoPackets: Int64 = 0
  var inboundAudioPackets: Int64 = 0
  var inboundVideoPackets: Int64 = 0
  var localAudioSenderSeen: Bool = false
  var audioSourceStatsSeen: Bool = false
  var inboundAudioSamplesStatsSeen: Bool = false
  var outboundAudioSamplesDurationMilliseconds: Int64 = 0
  var inboundAudioSamplesDurationMilliseconds: Int64 = 0
  var outboundAudioEnergyStatsSeen: Bool = false
  var inboundAudioEnergyStatsSeen: Bool = false
  var outboundAudioEnergy: Double = 0
  var inboundAudioEnergy: Double = 0
  var audioSessionStateKnown: Bool = false
  var audioSessionCanPlayOrRecord: Bool = false
  var audioUnitRunning: Bool = false
  var audioRouteStateKnown: Bool = false
  var audioInputRouteAvailable: Bool = false
  var audioOutputRouteAvailable: Bool = false
  var audioProfileStateKnown: Bool = false
  var audioProfileMatchesExpected: Bool = false
  var audioOutputRouteMatchesExpected: Bool = false
  var remoteAudioTrackSeen: Bool
  var remoteVideoTrackSeen: Bool
  var connectionState: RTCPeerConnectionState
  var iceConnectionState: RTCIceConnectionState

  func hasBidirectionalAudio(minBytes: Int64) -> Bool {
    let outboundAudioReady: Bool = outboundAudioBytes >= minBytes || outboundAudioPackets > 0
    let inboundAudioReady: Bool = inboundAudioBytes >= minBytes || inboundAudioPackets > 0
    return outboundAudioReady
      && inboundAudioReady
      && audioCaptureDiagnosticsReady
      && remoteAudioTrackSeen
  }

  func hasBidirectionalAudioVideo(minBytes: Int64) -> Bool {
    let outboundAudioReady: Bool = outboundAudioBytes >= minBytes || outboundAudioPackets > 0
    let outboundVideoReady: Bool = outboundVideoBytes >= minBytes || outboundVideoPackets > 0
    let inboundAudioReady: Bool = inboundAudioBytes >= minBytes || inboundAudioPackets > 0
    let inboundVideoReady: Bool = inboundVideoBytes >= minBytes || inboundVideoPackets > 0

    return outboundAudioReady
      && outboundVideoReady
      && inboundAudioReady
      && inboundVideoReady
      && audioCaptureDiagnosticsReady
      && remoteAudioTrackSeen
      && remoteVideoTrackSeen
  }

  private var audioCaptureDiagnosticsReady: Bool {
    let isLegacySnapshot: Bool = !audioSourceStatsSeen
      && !audioSessionStateKnown
      && !audioRouteStateKnown
    let senderReady: Bool = isLegacySnapshot || localAudioSenderSeen
    let sourceReady: Bool = !audioSourceStatsSeen || outboundAudioSamplesDurationMilliseconds > 0
    let decodeReady: Bool = !inboundAudioSamplesStatsSeen || inboundAudioSamplesDurationMilliseconds > 0
    let energyReady: Bool = (!outboundAudioEnergyStatsSeen || outboundAudioEnergy > 0)
      && (!inboundAudioEnergyStatsSeen || inboundAudioEnergy > 0)
    let audioSessionReady: Bool = !audioSessionStateKnown
      || (audioSessionCanPlayOrRecord && audioUnitRunning)
    let routeReady: Bool = !audioRouteStateKnown
      || (audioInputRouteAvailable && audioOutputRouteAvailable)
    let profileReady: Bool = !audioProfileStateKnown
      || (audioProfileMatchesExpected && audioOutputRouteMatchesExpected)
    return senderReady
      && sourceReady
      && decodeReady
      && energyReady
      && audioSessionReady
      && routeReady
      && profileReady
  }

  func summary() -> String {
    let remoteTracksSummary: String =
      "remoteTracks(audio=\(remoteAudioTrackSeen), video=\(remoteVideoTrackSeen))"
    let connectionSummary: String =
      "pc=\(connectionState.rawValue), ice=\(iceConnectionState.rawValue), \(remoteTracksSummary)"
    let outboundSummary: String =
      "out(audio=\(mediaFlowLabel(bytes: outboundAudioBytes, packets: outboundAudioPackets)), "
      + "video=\(mediaFlowLabel(bytes: outboundVideoBytes, packets: outboundVideoPackets)))"
    let inboundSummary: String =
      "in(audio=\(mediaFlowLabel(bytes: inboundAudioBytes, packets: inboundAudioPackets)), "
      + "video=\(mediaFlowLabel(bytes: inboundVideoBytes, packets: inboundVideoPackets)))"
    let mediaSummary: String = "\(outboundSummary), \(inboundSummary)"
    let localAudioSummary: String = [
      "sender=\(localAudioSenderSeen ? "present" : "absent")",
      "source=\(audioSourceStatsSeen ? "present" : "absent")",
      "samplesOut=\(outboundAudioSamplesDurationMilliseconds > 0 ? "present" : "idle")",
      "samplesIn=\(inboundAudioSamplesDurationMilliseconds > 0 ? "present" : "idle")",
      "energyOut=\(audioEnergyLabel(statsSeen: outboundAudioEnergyStatsSeen, energy: outboundAudioEnergy))",
      "energyIn=\(audioEnergyLabel(statsSeen: inboundAudioEnergyStatsSeen, energy: inboundAudioEnergy))",
    ].joined(separator: ",")
    let audioSessionSummary: String = [
      "state=\(audioSessionStateKnown ? "known" : "unknown")",
      "canPlay=\(audioSessionCanPlayOrRecord)",
      "unit=\(audioUnitRunning ? "running" : "stopped")",
      "route=\(audioRouteStateKnown ? "known" : "unknown")",
      "input=\(audioInputRouteAvailable ? "available" : "unavailable")",
      "output=\(audioOutputRouteAvailable ? "available" : "unavailable")",
      "profile=\(audioProfileStateKnown ? (audioProfileMatchesExpected ? "expected" : "unexpected") : "unknown")",
      "outputRoute=\(audioProfileStateKnown ? (audioOutputRouteMatchesExpected ? "expected" : "unexpected") : "unknown")",
    ].joined(separator: ",")
    return "\(connectionSummary), \(mediaSummary), localAudio(\(localAudioSummary)), audioSession(\(audioSessionSummary))"
  }

  private func mediaFlowLabel(bytes: Int64, packets: Int64) -> String {
    bytes > 0 || packets > 0 ? "present" : "idle"
  }

  private func audioEnergyLabel(statsSeen: Bool, energy: Double) -> String {
    guard statsSeen else {
      return "unknown"
    }
    return energy > 0 ? "present" : "silent"
  }
}

enum WebRTCMediaQualityProfile {
  static let targetVideoWidth: Int32 = 1280
  static let targetVideoHeight: Int32 = 720
  static let targetVideoMaxFramerate: Int = 24
  static let targetVideoMinFramerate: Int = 10
  static let preferredAudioSampleRate: Double = 48_000
  static let preferredAudioIOBufferDuration: TimeInterval = 0.01
  static let videoMinBitrateBps: Int = 120_000
  static let videoStartBitrateBps: Int = 650_000
  static let videoMaxBitrateBps: Int = 1_400_000
  static let audioMinBitrateBps: Int = 24_000
  static let audioStartBitrateBps: Int = 48_000
  static let audioMaxBitrateBps: Int = 96_000
  static let audioJitterBufferMaxPackets: Int32 = 50
  static let relayBackupCandidatePairPingIntervalMs: Int32 = 1_000
}

final class WebRTCAutomationEngine: NSObject {
  private let log: (String) -> Void
  private let peerConnectionFactory: RTCPeerConnectionFactory
  private let peerConnection: RTCPeerConnection
  private let includeVideo: Bool
  private let audioTrack: RTCAudioTrack
  private let videoSource: RTCVideoSource?
  private let videoTrack: RTCVideoTrack?
  private let cameraCapturer: RTCCameraVideoCapturer?
  private var audioSender: RTCRtpSender?
  private var videoSender: RTCRtpSender?
  private var localVideoRenderers: [RTCVideoRenderer] = []
  private var remoteVideoRenderers: [RTCVideoRenderer] = []
  private var remoteVideoTrack: RTCVideoTrack?
  private var pendingRemoteCandidates: [CallICECandidateSignal] = []
  private var remoteCandidateDedupeKeys: Set<String> = []
  private var isRemoteDescriptionApplied: Bool = false
  private var isCaptureRunning: Bool = false
  private var isCameraCaptureRunning: Bool = false
  private var wantsCameraCapture: Bool
  private var didRegisterAudioSessionDelegate: Bool = false
  private var audioSessionLease: CallAudioSessionLease?
  private var activeCallId: String?

  private(set) var connectionState: RTCPeerConnectionState = .new
  private(set) var iceConnectionState: RTCIceConnectionState = .new
  private(set) var remoteAudioTrackSeen: Bool = false
  private(set) var remoteVideoTrackSeen: Bool = false

  var onLocalCandidate: ((CallICECandidateSignal) -> Void)?

  init(iceServers: [WebRTC.RTCIceServer], includeVideo: Bool = true, log: @escaping (String) -> Void) throws {
    self.log = log
    self.includeVideo = includeVideo
    self.wantsCameraCapture = includeVideo

    let encoderFactory: RTCDefaultVideoEncoderFactory = RTCDefaultVideoEncoderFactory()
    let decoderFactory: RTCDefaultVideoDecoderFactory = RTCDefaultVideoDecoderFactory()
    self.peerConnectionFactory = RTCPeerConnectionFactory(
      encoderFactory: encoderFactory,
      decoderFactory: decoderFactory
    )

    let configuration: RTCConfiguration = Self.makeRelayConfiguration(iceServers: iceServers)

    let constraints: RTCMediaConstraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: nil
    )

    guard
      let peerConnection: RTCPeerConnection = peerConnectionFactory.peerConnection(
        with: configuration,
        constraints: constraints,
        delegate: nil
      )
    else {
      throw WebRTCAutomationEngineError.peerConnectionCreationFailed
    }

    self.peerConnection = peerConnection
    self.audioTrack = peerConnectionFactory.audioTrack(withTrackId: "e2e-audio")
    if includeVideo {
      let videoSource: RTCVideoSource = peerConnectionFactory.videoSource()
      self.videoSource = videoSource
      self.videoTrack = peerConnectionFactory.videoTrack(with: videoSource, trackId: "e2e-video")
      self.cameraCapturer = RTCCameraVideoCapturer(delegate: videoSource)
    } else {
      self.videoSource = nil
      self.videoTrack = nil
      self.cameraCapturer = nil
    }

    super.init()

    self.peerConnection.delegate = self
    let iceServerSummary = Self.iceServerSummary(iceServers)
    log("[E2E][Media] Relay ICE servers configured: \(iceServerSummary)")
    recordDiagnostic(category: "ice", name: "relay_configured", detail: iceServerSummary)
    let rtcAudioSession = RTCAudioSession.sharedInstance()
    rtcAudioSession.add(self)
    didRegisterAudioSessionDelegate = true

    audioSender = self.peerConnection.add(audioTrack, streamIds: ["e2e-stream"])
    guard audioSender != nil else {
      rtcAudioSession.remove(self)
      didRegisterAudioSessionDelegate = false
      self.peerConnection.delegate = nil
      self.peerConnection.close()
      throw WebRTCAutomationEngineError.operationFailed("WebRTC audio sender could not be created")
    }
    if let videoTrack {
      videoSender = self.peerConnection.add(videoTrack, streamIds: ["e2e-stream"])
      guard videoSender != nil else {
        rtcAudioSession.remove(self)
        didRegisterAudioSessionDelegate = false
        self.peerConnection.delegate = nil
        self.peerConnection.close()
        throw WebRTCAutomationEngineError.operationFailed("WebRTC video sender could not be created")
      }
    }
    configureMediaSenderParameters()
  }

  func startLocalMedia() async throws {
    if isCaptureRunning {
      return
    }

    let lease: CallAudioSessionLease = try CallAudioSessionCoordinator.shared.acquireMediaLease(hasVideo: includeVideo)
    audioSessionLease = lease
    do {
      try await startCameraCaptureIfNeeded()
    } catch {
      CallAudioSessionCoordinator.shared.releaseMediaLease(lease)
      audioSessionLease = nil
      throw error
    }
    isCaptureRunning = true
    log("[E2E][Media] Local media capture started")
  }

  func bindDiagnosticCallId(_ callId: String) {
    activeCallId = callId
  }

  func stop() {
    if didRegisterAudioSessionDelegate {
      RTCAudioSession.sharedInstance().remove(self)
      didRegisterAudioSessionDelegate = false
    }

    stopCameraCaptureIfNeeded()
    isCaptureRunning = false
    pendingRemoteCandidates.removeAll()
    remoteCandidateDedupeKeys.removeAll()

    detachVideoRenderers()
    peerConnection.close()
    if let audioSessionLease {
      CallAudioSessionCoordinator.shared.releaseMediaLease(audioSessionLease)
      self.audioSessionLease = nil
    }
  }

  deinit {
    if didRegisterAudioSessionDelegate {
      RTCAudioSession.sharedInstance().remove(self)
    }
    if let audioSessionLease {
      CallAudioSessionCoordinator.shared.releaseMediaLease(audioSessionLease)
    }
  }

  func setMicrophoneEnabled(_ enabled: Bool) {
    audioTrack.isEnabled = enabled
  }

  func setCameraEnabled(_ enabled: Bool) {
    guard includeVideo else {
      return
    }

    wantsCameraCapture = enabled
    videoTrack?.isEnabled = enabled
    if enabled {
      guard isCaptureRunning else {
        return
      }

      Task { [weak self] in
        do {
          try await self?.startCameraCaptureIfNeeded()
        } catch {
          self?.log("[E2E][Media] Camera restart failed after enable")
        }
      }
    } else {
      stopCameraCaptureIfNeeded()
    }
  }

  func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
    guard let videoTrack else {
      return
    }

    guard !containsRenderer(renderer, in: localVideoRenderers) else {
      return
    }

    videoTrack.add(renderer)
    localVideoRenderers.append(renderer)
  }

  func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    guard !containsRenderer(renderer, in: remoteVideoRenderers) else {
      return
    }

    remoteVideoRenderers.append(renderer)
    remoteVideoTrack?.add(renderer)
  }

  func detachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
    guard let index: Int = rendererIndex(renderer, in: localVideoRenderers) else {
      return
    }

    videoTrack?.remove(renderer)
    localVideoRenderers.remove(at: index)
  }

  func detachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    guard let index: Int = rendererIndex(renderer, in: remoteVideoRenderers) else {
      return
    }

    remoteVideoTrack?.remove(renderer)
    remoteVideoRenderers.remove(at: index)
  }

  func detachVideoRenderers() {
    if let videoTrack {
      for renderer in localVideoRenderers {
        videoTrack.remove(renderer)
      }
    }

    if let remoteVideoTrack {
      for renderer in remoteVideoRenderers {
        remoteVideoTrack.remove(renderer)
      }
    }

    localVideoRenderers.removeAll()
    remoteVideoRenderers.removeAll()
  }

  func createOffer(callId: String) async throws -> CallSessionDescriptionSignal {
    activeCallId = callId
    let constraints: RTCMediaConstraints = offerAnswerConstraints()
    let offer: RTCSessionDescription = try await makeOffer(constraints: constraints)
    try await setLocalDescription(offer)

    return CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: nil,
      type: sdpTypeString(for: offer.type),
      sdp: offer.sdp,
      dtlsFingerprint: CallSignalParser.dtlsFingerprint(fromSDP: offer.sdp)
    )
  }

  func restartIceAndCreateOffer(callId: String) async throws -> CallSessionDescriptionSignal {
    activeCallId = callId
    peerConnection.restartIce()
    let constraints: RTCMediaConstraints = offerAnswerConstraints()
    let offer: RTCSessionDescription = try await makeOffer(constraints: constraints)
    try await setLocalDescription(offer)

    return CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: nil,
      type: sdpTypeString(for: offer.type),
      sdp: offer.sdp,
      dtlsFingerprint: CallSignalParser.dtlsFingerprint(fromSDP: offer.sdp)
    )
  }

  func updateRelayIceServers(_ iceServers: [WebRTC.RTCIceServer]) throws {
    guard !iceServers.isEmpty else {
      throw WebRTCAutomationEngineError.operationFailed("Relay ICE server list is empty")
    }

    let configuration: RTCConfiguration = Self.makeRelayConfiguration(iceServers: iceServers)
    guard peerConnection.setConfiguration(configuration) else {
      throw WebRTCAutomationEngineError.operationFailed("WebRTC relay ICE configuration update failed")
    }

    let iceServerSummary = Self.iceServerSummary(iceServers)
    log("[E2E][Media] Relay ICE servers updated: \(iceServerSummary)")
    recordDiagnostic(category: "ice", name: "relay_updated", detail: iceServerSummary)
  }

  func createAnswer(callId: String) async throws -> CallSessionDescriptionSignal {
    activeCallId = callId
    let constraints: RTCMediaConstraints = offerAnswerConstraints()
    let answer: RTCSessionDescription = try await makeAnswer(constraints: constraints)
    try await setLocalDescription(answer)

    return CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: nil,
      type: sdpTypeString(for: answer.type),
      sdp: answer.sdp,
      dtlsFingerprint: CallSignalParser.dtlsFingerprint(fromSDP: answer.sdp)
    )
  }

  func applyRemoteDescription(_ description: CallSessionDescriptionSignal) async throws {
    activeCallId = description.callId
    guard let expectedFingerprint: String = description.dtlsFingerprint,
      let actualFingerprint: String = CallSignalParser.dtlsFingerprint(fromSDP: description.sdp),
      expectedFingerprint == actualFingerprint
    else {
      throw WebRTCAutomationEngineError.operationFailed("Remote SDP DTLS fingerprint is not transcript-bound")
    }

    let sdpType: RTCSdpType = try Self.parseSdpType(description.type)
    let remoteDescription: RTCSessionDescription = RTCSessionDescription(type: sdpType, sdp: description.sdp)
    try await setRemoteDescription(remoteDescription)

    isRemoteDescriptionApplied = true
    let pending: [CallICECandidateSignal] = pendingRemoteCandidates
    pendingRemoteCandidates.removeAll()

    for candidate in pending {
      do {
        try await applyRemoteCandidate(candidate)
        log("[E2E][Media] Pending remote relay ICE candidate applied mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)")
        recordRemoteCandidateDiagnostic(
          name: "pending_remote_candidate_applied",
          candidate: candidate
        )
      } catch {
        remoteCandidateDedupeKeys.remove(candidate.dedupeKey)
        log("[E2E][Media] Pending remote ICE candidate was rejected")
        recordRemoteCandidateDiagnostic(
          name: "pending_remote_candidate_rejected",
          candidate: candidate,
          detail: error.localizedDescription
        )
      }
    }
  }

  func rollbackLocalDescription() async throws {
    let rollbackDescription: RTCSessionDescription = RTCSessionDescription(type: .rollback, sdp: "")
    try await setLocalDescription(rollbackDescription)
  }

  func queueRemoteCandidate(_ candidate: CallICECandidateSignal) async throws {
    guard CallSignalParser.isRelayCandidate(candidate.sdp) else {
      throw WebRTCAutomationEngineError.operationFailed("Non-relay remote ICE candidate rejected")
    }
    guard remoteCandidateDedupeKeys.insert(candidate.dedupeKey).inserted else {
      return
    }

    if isRemoteDescriptionApplied {
      do {
        log("[E2E][Media] Applying remote relay ICE candidate mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)")
        recordRemoteCandidateDiagnostic(name: "remote_candidate_applying", candidate: candidate)
        try await applyRemoteCandidate(candidate)
        recordRemoteCandidateDiagnostic(name: "remote_candidate_applied", candidate: candidate)
      } catch {
        remoteCandidateDedupeKeys.remove(candidate.dedupeKey)
        recordRemoteCandidateDiagnostic(
          name: "remote_candidate_rejected",
          candidate: candidate,
          detail: error.localizedDescription
        )
        throw error
      }
      return
    }

    pendingRemoteCandidates.append(candidate)
    log("[E2E][Media] Queued remote relay ICE candidate mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)")
    recordRemoteCandidateDiagnostic(name: "remote_candidate_queued", candidate: candidate)
  }

  func waitForBidirectionalMedia(
    timeout: TimeInterval,
    minBytes: Int64,
    pollInterval: TimeInterval = 1
  ) async -> WebRTCMediaFlowSnapshot {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))
    var latestSnapshot: WebRTCMediaFlowSnapshot = await collectMediaSnapshot()

    while Date() < deadline {
      latestSnapshot = await collectMediaSnapshot()

      let connectionReady: Bool =
        connectionState == .connected
        || iceConnectionState == .connected
        || iceConnectionState == .completed

      let mediaReady: Bool = includeVideo
        ? latestSnapshot.hasBidirectionalAudioVideo(minBytes: minBytes)
        : latestSnapshot.hasBidirectionalAudio(minBytes: minBytes)
      if connectionReady && mediaReady {
        return latestSnapshot
      }

      try? await Task.sleep(nanoseconds: UInt64(max(0.1, pollInterval) * 1_000_000_000))
    }

    return latestSnapshot
  }

  func currentMediaSnapshot() async -> WebRTCMediaFlowSnapshot {
    await collectMediaSnapshot()
  }

#if DEBUG
  static func relayConfigurationForTesting(iceServers: [WebRTC.RTCIceServer]) -> RTCConfiguration {
    makeRelayConfiguration(iceServers: iceServers)
  }

  static func sdpTypeForTesting(_ rawType: String) throws -> RTCSdpType {
    try parseSdpType(rawType)
  }
#endif

  private static func makeRelayConfiguration(iceServers: [WebRTC.RTCIceServer]) -> RTCConfiguration {
    let configuration: RTCConfiguration = RTCConfiguration()
    configuration.enableDscp = true
    configuration.sdpSemantics = .unifiedPlan
    configuration.bundlePolicy = .maxBundle
    configuration.rtcpMuxPolicy = .require
    configuration.tcpCandidatePolicy = .enabled
    configuration.candidateNetworkPolicy = .all
    configuration.continualGatheringPolicy = .gatherContinually
    configuration.iceTransportPolicy = .relay
    configuration.iceCandidatePoolSize = 0
    configuration.shouldPruneTurnPorts = true
    configuration.shouldPresumeWritableWhenFullyRelayed = true
    configuration.audioJitterBufferMaxPackets = WebRTCMediaQualityProfile.audioJitterBufferMaxPackets
    configuration.audioJitterBufferFastAccelerate = true
    configuration.iceBackupCandidatePairPingInterval =
      WebRTCMediaQualityProfile.relayBackupCandidatePairPingIntervalMs
    configuration.iceServers = iceServers
    return configuration
  }

  private static func iceServerSummary(_ iceServers: [WebRTC.RTCIceServer]) -> String {
    let urlSummaries: [String] = iceServers.flatMap { server in
      server.urlStrings.map { url in
        iceServerURLLabel(url)
      }
    }

    return "count=\(iceServers.count), urls=\(urlSummaries.joined(separator: ","))"
  }

  private static func iceServerURLLabel(_ url: String) -> String {
    let normalizedURL: String = url.lowercased()
    if normalizedURL.hasPrefix("turns:") {
      return "turns"
    }
    if normalizedURL.hasPrefix("turn:") {
      return normalizedURL.contains("transport=tcp") ? "turn-tcp" : "turn-udp"
    }
    return "other"
  }

  private func recordDiagnostic(category: String, name: String, callId: String? = nil, detail: String? = nil) {
    PiPDiagnosticRecorder.shared.record(
      category: category,
      name: name,
      callId: callId ?? activeCallId ?? "none",
      detail: detail
    )
  }

  private func recordRemoteCandidateDiagnostic(
    name: String,
    candidate: CallICECandidateSignal,
    detail: String? = nil
  ) {
    let candidateDetail = [
      "type=\(Self.candidateType(candidate.sdp))",
      "mid=\(candidate.sdpMid ?? "nil")",
      "mline=\(candidate.sdpMLineIndex)",
      detail.map { "detail=\($0)" },
    ].compactMap { $0 }.joined(separator: " ")

    recordDiagnostic(category: "ice_candidate", name: name, detail: candidateDetail)
  }

  private func startCameraCaptureIfNeeded() async throws {
    guard includeVideo, wantsCameraCapture, !isCameraCaptureRunning else {
      return
    }

    try await startCameraCapture()
    isCameraCaptureRunning = true
  }

  private func stopCameraCaptureIfNeeded() {
    guard isCameraCaptureRunning else {
      return
    }

    cameraCapturer?.stopCapture()
    isCameraCaptureRunning = false
    log("[E2E][Media] Camera capture stopped")
  }

  private func startCameraCapture() async throws {
    guard let cameraCapturer else {
      return
    }

    configureMultitaskingCameraAccessIfSupported(cameraCapturer)

    let devices: [AVCaptureDevice] = RTCCameraVideoCapturer.captureDevices()
    guard let device: AVCaptureDevice = devices.first(where: { $0.position == .front }) ?? devices.first else {
      throw WebRTCAutomationEngineError.cameraUnavailable
    }

    let formats: [AVCaptureDevice.Format] = RTCCameraVideoCapturer.supportedFormats(for: device)
    guard let format: AVCaptureDevice.Format = bestFormat(from: formats) else {
      throw WebRTCAutomationEngineError.cameraFormatUnavailable
    }

    let fps: Int = bestFps(for: format)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      cameraCapturer.startCapture(with: device, format: format, fps: fps) { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  private func configureMultitaskingCameraAccessIfSupported(_ cameraCapturer: RTCCameraVideoCapturer) {
    guard #available(iOS 16.0, *) else {
      return
    }

    let captureSession = cameraCapturer.captureSession
    guard captureSession.isMultitaskingCameraAccessSupported else {
      return
    }

    captureSession.isMultitaskingCameraAccessEnabled = true
  }

  private func bestFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
    let targetPixels: Int32 =
      WebRTCMediaQualityProfile.targetVideoWidth * WebRTCMediaQualityProfile.targetVideoHeight

    return formats.min { left, right in
      formatScore(left, targetPixels: targetPixels) < formatScore(right, targetPixels: targetPixels)
    }
  }

  private func formatScore(_ format: AVCaptureDevice.Format, targetPixels: Int32) -> Int64 {
    let dimensions: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let maxDimension: Int32 = max(dimensions.width, dimensions.height)
    let minDimension: Int32 = min(dimensions.width, dimensions.height)
    let pixels: Int32 = dimensions.width * dimensions.height
    let isWithinTarget: Bool =
      maxDimension <= WebRTCMediaQualityProfile.targetVideoWidth
      && minDimension <= WebRTCMediaQualityProfile.targetVideoHeight
    let distance: Int64 = Int64(abs(targetPixels - pixels))

    return isWithinTarget ? distance : Int64(targetPixels) + distance
  }

  private func bestFps(for format: AVCaptureDevice.Format) -> Int {
    let maxFrameRate: Double = format.videoSupportedFrameRateRanges
      .map(\.maxFrameRate)
      .max() ?? 15
    return max(
      WebRTCMediaQualityProfile.targetVideoMinFramerate,
      min(WebRTCMediaQualityProfile.targetVideoMaxFramerate, Int(maxFrameRate.rounded(.down)))
    )
  }

  private func offerAnswerConstraints() -> RTCMediaConstraints {
    let receiveVideo: String = includeVideo
      ? kRTCMediaConstraintsValueTrue
      : kRTCMediaConstraintsValueFalse
    return RTCMediaConstraints(
      mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
        kRTCMediaConstraintsOfferToReceiveVideo: receiveVideo,
      ],
      optionalConstraints: nil
    )
  }

  private func configureMediaSenderParameters() {
    if includeVideo {
      _ = peerConnection.setBweMinBitrateBps(
        NSNumber(value: WebRTCMediaQualityProfile.videoMinBitrateBps),
        currentBitrateBps: NSNumber(value: WebRTCMediaQualityProfile.videoStartBitrateBps),
        maxBitrateBps: NSNumber(value: WebRTCMediaQualityProfile.videoMaxBitrateBps)
      )
    } else {
      _ = peerConnection.setBweMinBitrateBps(
        NSNumber(value: WebRTCMediaQualityProfile.audioMinBitrateBps),
        currentBitrateBps: NSNumber(value: WebRTCMediaQualityProfile.audioStartBitrateBps),
        maxBitrateBps: NSNumber(value: WebRTCMediaQualityProfile.audioMaxBitrateBps)
      )
    }

    if let videoSender {
      let parameters: RTCRtpParameters = videoSender.parameters
      for encoding in parameters.encodings {
        encoding.maxBitrateBps = NSNumber(value: WebRTCMediaQualityProfile.videoMaxBitrateBps)
        encoding.maxFramerate = NSNumber(value: WebRTCMediaQualityProfile.targetVideoMaxFramerate)
        encoding.networkPriority = .high
      }
      videoSender.parameters = parameters
    }

    if let audioSender {
      let parameters: RTCRtpParameters = audioSender.parameters
      for encoding in parameters.encodings {
        encoding.maxBitrateBps = NSNumber(value: WebRTCMediaQualityProfile.audioMaxBitrateBps)
        encoding.networkPriority = .high
        encoding.adaptiveAudioPacketTime = true
      }
      audioSender.parameters = parameters
    }
  }

  private func makeOffer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
      peerConnection.offer(for: constraints) { offer, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        guard let offer else {
          continuation.resume(
            throwing: WebRTCAutomationEngineError.operationFailed("Offer is nil")
          )
          return
        }
        continuation.resume(returning: offer)
      }
    }
  }

  private func makeAnswer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
      peerConnection.answer(for: constraints) { answer, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        guard let answer else {
          continuation.resume(
            throwing: WebRTCAutomationEngineError.operationFailed("Answer is nil")
          )
          return
        }
        continuation.resume(returning: answer)
      }
    }
  }

  private func setLocalDescription(_ description: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.setLocalDescription(description) { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.setRemoteDescription(description) { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  private func applyRemoteCandidate(_ candidate: CallICECandidateSignal) async throws {
    guard CallSignalParser.isRelayCandidate(candidate.sdp) else {
      throw WebRTCAutomationEngineError.operationFailed("Non-relay remote ICE candidate rejected")
    }
    let rtcCandidate: RTCIceCandidate = RTCIceCandidate(
      sdp: candidate.sdp,
      sdpMLineIndex: Int32(candidate.sdpMLineIndex),
      sdpMid: candidate.sdpMid
    )

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.add(rtcCandidate) { error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  private func containsRenderer(_ renderer: RTCVideoRenderer, in renderers: [RTCVideoRenderer]) -> Bool {
    rendererIndex(renderer, in: renderers) != nil
  }

  private func rendererIndex(_ renderer: RTCVideoRenderer, in renderers: [RTCVideoRenderer]) -> Int? {
    let rendererId = ObjectIdentifier(renderer as AnyObject)
    return renderers.firstIndex(where: { ObjectIdentifier($0 as AnyObject) == rendererId })
  }

  private func collectMediaSnapshot() async -> WebRTCMediaFlowSnapshot {
    let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
      peerConnection.statistics { statsReport in
        continuation.resume(returning: statsReport)
      }
    }

    var snapshot: WebRTCMediaFlowSnapshot = WebRTCMediaFlowSnapshot(
      localAudioSenderSeen: audioSender != nil,
      remoteAudioTrackSeen: remoteAudioTrackSeen,
      remoteVideoTrackSeen: remoteVideoTrackSeen,
      connectionState: connectionState,
      iceConnectionState: iceConnectionState
    )

    for statistic in report.statistics.values {
      let type: String = statistic.type.lowercased()
      if type == "media-source" {
        let mediaTypeValue: String = stringValue(statistic.values["kind"])
          ?? stringValue(statistic.values["mediaType"])
          ?? ""
        if mediaTypeValue.lowercased() == "audio",
          let totalSamplesDuration = statistic.values["totalSamplesDuration"]
        {
          snapshot.audioSourceStatsSeen = true
          snapshot.outboundAudioSamplesDurationMilliseconds = max(
            snapshot.outboundAudioSamplesDurationMilliseconds,
            millisecondsValue(totalSamplesDuration)
          )
          if let totalAudioEnergy = statistic.values["totalAudioEnergy"] {
            snapshot.outboundAudioEnergyStatsSeen = true
            snapshot.outboundAudioEnergy = max(
              snapshot.outboundAudioEnergy,
              positiveDoubleValue(totalAudioEnergy)
            )
          }
        }
        continue
      }

      guard type == "outbound-rtp" || type == "inbound-rtp" else {
        continue
      }

      let mediaTypeValue: String = stringValue(statistic.values["kind"])
        ?? stringValue(statistic.values["mediaType"])
        ?? ""
      let mediaType: String = mediaTypeValue.lowercased()
      guard mediaType == "audio" || mediaType == "video" else {
        continue
      }

      if type == "outbound-rtp" {
        let bytesSent: Int64 = int64Value(statistic.values["bytesSent"])
        let packetsSent: Int64 = int64Value(statistic.values["packetsSent"])

        if mediaType == "audio" {
          snapshot.localAudioSenderSeen = true
          snapshot.outboundAudioBytes = max(snapshot.outboundAudioBytes, bytesSent)
          snapshot.outboundAudioPackets = max(snapshot.outboundAudioPackets, packetsSent)
        } else {
          snapshot.outboundVideoBytes = max(snapshot.outboundVideoBytes, bytesSent)
          snapshot.outboundVideoPackets = max(snapshot.outboundVideoPackets, packetsSent)
        }
      } else {
        let bytesReceived: Int64 = int64Value(statistic.values["bytesReceived"])
        let packetsReceived: Int64 = int64Value(statistic.values["packetsReceived"])

        if mediaType == "audio" {
          snapshot.inboundAudioBytes = max(snapshot.inboundAudioBytes, bytesReceived)
          snapshot.inboundAudioPackets = max(snapshot.inboundAudioPackets, packetsReceived)
          if let totalSamplesDuration = statistic.values["totalSamplesDuration"] {
            snapshot.inboundAudioSamplesStatsSeen = true
            snapshot.inboundAudioSamplesDurationMilliseconds = max(
              snapshot.inboundAudioSamplesDurationMilliseconds,
              millisecondsValue(totalSamplesDuration)
            )
          }
          if let totalAudioEnergy = statistic.values["totalAudioEnergy"] {
            snapshot.inboundAudioEnergyStatsSeen = true
            snapshot.inboundAudioEnergy = max(
              snapshot.inboundAudioEnergy,
              positiveDoubleValue(totalAudioEnergy)
            )
          }
        } else {
          snapshot.inboundVideoBytes = max(snapshot.inboundVideoBytes, bytesReceived)
          snapshot.inboundVideoPackets = max(snapshot.inboundVideoPackets, packetsReceived)
        }
      }
    }

    let audioSnapshot: CallAudioSessionRuntimeSnapshot = CallAudioSessionCoordinator.shared.snapshot()
    snapshot.audioSessionStateKnown = audioSnapshot.stateKnown
    snapshot.audioSessionCanPlayOrRecord = audioSnapshot.canPlayOrRecord
    snapshot.audioUnitRunning = audioSnapshot.audioUnitRunning
    snapshot.audioRouteStateKnown = audioSnapshot.routeStateKnown
    snapshot.audioInputRouteAvailable = audioSnapshot.inputRouteAvailable
    snapshot.audioOutputRouteAvailable = audioSnapshot.outputRouteAvailable
    let audioSession = RTCAudioSession.sharedInstance().session
    let outputPortTypes: [AVAudioSession.Port] = audioSession.currentRoute.outputs.map(\.portType)
    snapshot.audioProfileStateKnown = true
    snapshot.audioProfileMatchesExpected = Self.audioSessionProfileMatchesExpected(
      category: audioSession.category,
      mode: audioSession.mode,
      options: audioSession.categoryOptions,
      hasVideo: includeVideo
    )
    snapshot.audioOutputRouteMatchesExpected = Self.audioOutputRouteMatchesExpected(
      outputPortTypes: outputPortTypes,
      hasVideo: includeVideo
    )

    return snapshot
  }

  static func audioSessionProfileMatchesExpected(
    category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions,
    hasVideo: Bool
  ) -> Bool {
    guard category == .playAndRecord,
      options.contains(.allowBluetoothHFP),
      mode == (hasVideo ? .videoChat : .voiceChat)
    else {
      return false
    }

    return options.contains(.defaultToSpeaker) == hasVideo
  }

  static func audioOutputRouteMatchesExpected(
    outputPortTypes: [AVAudioSession.Port],
    hasVideo: Bool
  ) -> Bool {
    guard !outputPortTypes.isEmpty else {
      return false
    }

    let builtInOutputTypes: Set<AVAudioSession.Port> = [.builtInReceiver, .builtInSpeaker]
    if outputPortTypes.contains(where: { !builtInOutputTypes.contains($0) }) {
      return true
    }

    return outputPortTypes.contains(hasVideo ? .builtInSpeaker : .builtInReceiver)
  }

  private func sdpTypeString(for type: RTCSdpType) -> String {
    RTCSessionDescription.string(for: type)
  }

  private static func parseSdpType(_ rawType: String) throws -> RTCSdpType {
    let normalizedType: String = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalizedType {
    case "offer":
      return .offer
    case "answer":
      return .answer
    case "pranswer":
      return .prAnswer
    case "rollback":
      return .rollback
    default:
      throw WebRTCAutomationEngineError.signalingStateInvalid("Unsupported SDP type: \(rawType)")
    }
  }

  private func stringValue(_ object: NSObject?) -> String? {
    switch object {
    case let value as NSString:
      return String(value)
    case let value as NSNumber:
      return value.stringValue
    default:
      return nil
    }
  }

  private func int64Value(_ object: NSObject?) -> Int64 {
    switch object {
    case let value as NSNumber:
      return value.int64Value
    case let value as NSString:
      return Int64(String(value)) ?? 0
    default:
      return 0
    }
  }

  private func millisecondsValue(_ object: NSObject?) -> Int64 {
    let seconds: Double = positiveDoubleValue(object)
    return Int64(min(Double(Int64.max), seconds * 1_000))
  }

  private func positiveDoubleValue(_ object: NSObject?) -> Double {
    let value: Double
    switch object {
    case let number as NSNumber:
      value = number.doubleValue
    case let string as NSString:
      value = Double(String(string)) ?? 0
    default:
      value = 0
    }

    guard value.isFinite, value > 0 else {
      return 0
    }
    return value
  }
}

extension WebRTCAutomationEngine: RTCAudioSessionDelegate {
  func audioSession(
    _ audioSession: RTCAudioSession,
    didChangeCanPlayOrRecord canPlayOrRecord: Bool
  ) {
    _ = audioSession
    CallAudioSessionCoordinator.shared.updateCanPlayOrRecord(canPlayOrRecord)
    recordDiagnostic(
      category: "audio_session",
      name: "can_play_or_record_changed",
      detail: audioSessionDiagnosticDetail(additional: ["reportedCanPlay=\(canPlayOrRecord)"])
    )
    log("[E2E][Media][AudioSession] canPlayOrRecord=\(canPlayOrRecord)")
  }

  func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
    _ = session
    CallAudioSessionCoordinator.shared.updateAudioUnitRunning(true)
    recordDiagnostic(
      category: "audio_session",
      name: "play_or_record_started",
      detail: audioSessionDiagnosticDetail()
    )
    log("[E2E][Media][AudioSession] started play-or-record")
  }

  func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
    _ = session
    CallAudioSessionCoordinator.shared.reportAudioUnitStopped()
    recordDiagnostic(
      category: "audio_session",
      name: "play_or_record_stopped",
      detail: audioSessionDiagnosticDetail()
    )
    log("[E2E][Media][AudioSession] stopped play-or-record")
  }

  func audioSession(
    _ audioSession: RTCAudioSession,
    failedToSetActive active: Bool,
    error: Error
  ) {
    _ = audioSession
    recordDiagnostic(
      category: "audio_session",
      name: "set_active_failed",
      detail: audioSessionDiagnosticDetail(additional: ["requestedActive=\(active)"])
    )
    log("[E2E][Media][AudioSession] failedToSetActive active=\(active): \(error.localizedDescription)")
  }

  func audioSession(
    _ audioSession: RTCAudioSession,
    audioUnitStartFailedWithError error: Error
  ) {
    _ = audioSession
    CallAudioSessionCoordinator.shared.reportAudioUnitStartFailure()
    recordDiagnostic(
      category: "audio_session",
      name: "audio_unit_start_failed",
      detail: audioSessionDiagnosticDetail()
    )
    log("[E2E][Media][AudioSession] audioUnitStartFailed: \(error.localizedDescription)")
  }

  private func audioSessionDiagnosticDetail(additional: [String] = []) -> String {
    let snapshot: CallAudioSessionRuntimeSnapshot = CallAudioSessionCoordinator.shared.snapshot()
    let audioSession = RTCAudioSession.sharedInstance().session
    let outputPortTypes: [AVAudioSession.Port] = audioSession.currentRoute.outputs.map(\.portType)
    return (additional + [
      "providerActive=\(snapshot.providerAudioSessionActive)",
      "ioEnabled=\(snapshot.audioIOEnabled)",
      "canPlay=\(snapshot.canPlayOrRecord)",
      "unitRunning=\(snapshot.audioUnitRunning)",
      "routeKnown=\(snapshot.routeStateKnown)",
      "inputAvailable=\(snapshot.inputRouteAvailable)",
      "outputAvailable=\(snapshot.outputRouteAvailable)",
      "category=\(audioSession.category.rawValue)",
      "mode=\(audioSession.mode.rawValue)",
      "options=\(audioSession.categoryOptions.rawValue)",
      "outputs=\(outputPortTypes.map(\.rawValue).joined(separator: "+"))",
      "profileExpected=\(Self.audioSessionProfileMatchesExpected(category: audioSession.category, mode: audioSession.mode, options: audioSession.categoryOptions, hasVideo: includeVideo))",
      "outputRouteExpected=\(Self.audioOutputRouteMatchesExpected(outputPortTypes: outputPortTypes, hasVideo: includeVideo))",
    ]).joined(separator: " ")
  }
}

extension WebRTCAutomationEngine: RTCPeerConnectionDelegate {
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
    log("[E2E][Media] Signaling state changed: \(stateChanged.rawValue)")
    recordDiagnostic(
      category: "signaling",
      name: "state_changed",
      detail: "state=\(stateChanged.rawValue)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    if !stream.audioTracks.isEmpty {
      remoteAudioTrackSeen = true
    }
    if !stream.videoTracks.isEmpty {
      remoteVideoTrackSeen = true
    }
    recordDiagnostic(
      category: "media_track",
      name: "remote_stream_added",
      detail: "audio=\(!stream.audioTracks.isEmpty) video=\(!stream.videoTracks.isEmpty)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    log("[E2E][Media] Remote stream removed")
    recordDiagnostic(category: "media_track", name: "remote_stream_removed")
  }

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
    log("[E2E][Media] Renegotiation requested")
    recordDiagnostic(category: "signaling", name: "renegotiation_requested")
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
    iceConnectionState = newState
    log("[E2E][Media] ICE connection state changed: \(newState.rawValue)")
    recordDiagnostic(
      category: "ice",
      name: "connection_state_changed",
      detail: "state=\(newState.rawValue)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    log("[E2E][Media] ICE gathering state changed: \(newState.rawValue)")
    recordDiagnostic(
      category: "ice",
      name: "gathering_state_changed",
      detail: "state=\(newState.rawValue)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
    guard let callId: String = activeCallId else {
      recordDiagnostic(
        category: "ice_candidate",
        name: "local_candidate_without_call",
        detail: "type=\(Self.candidateType(candidate.sdp)) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
      )
      return
    }
    guard CallSignalParser.isRelayCandidate(candidate.sdp) else {
      let candidateType = Self.candidateType(candidate.sdp)
      log("[E2E][Media] Non-relay local ICE candidate rejected type=\(candidateType)")
      recordDiagnostic(
        category: "ice_candidate",
        name: "local_candidate_rejected",
        detail: "type=\(candidateType) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
      )
      return
    }

    log("[E2E][Media] Local relay ICE candidate generated mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)")
    recordDiagnostic(
      category: "ice_candidate",
      name: "local_relay_candidate_generated",
      callId: callId,
      detail: "type=\(Self.candidateType(candidate.sdp)) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)"
    )
    let signal: CallICECandidateSignal = CallICECandidateSignal(
      callId: callId,
      sdp: candidate.sdp,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: Int32(candidate.sdpMLineIndex)
    )
    onLocalCandidate?(signal)
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
    log("[E2E][Media] ICE candidates removed: \(candidates.count)")
    recordDiagnostic(
      category: "ice_candidate",
      name: "candidates_removed",
      detail: "count=\(candidates.count)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {
    let detail: String = [
      "server=\(Self.iceServerURLLabel(event.url))",
      "port=\(event.port)",
      "code=\(event.errorCode)",
      "text=\(event.errorText)",
    ].joined(separator: " ")

    log("[E2E][Media] ICE candidate gathering failed \(detail)")
    recordDiagnostic(category: "ice_candidate", name: "gathering_failed", detail: detail)
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    log("[E2E][Media] Data channel opened: \(dataChannel.label)")
    recordDiagnostic(
      category: "data_channel",
      name: "opened",
      detail: "label=\(dataChannel.label)"
    )
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
    connectionState = newState
    log("[E2E][Media] Peer connection state changed: \(newState.rawValue)")
    recordDiagnostic(
      category: "peer_connection",
      name: "state_changed",
      detail: "state=\(newState.rawValue)"
    )
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didAdd rtpReceiver: RTCRtpReceiver,
    streams mediaStreams: [RTCMediaStream]
  ) {
    guard let track: RTCMediaStreamTrack = rtpReceiver.track else {
      log("[E2E][Media] Receiver added without track")
      return
    }

    let kind: String = track.kind.lowercased()
    if kind == "audio" {
      remoteAudioTrackSeen = true
    }
    if kind == "video" {
      remoteVideoTrackSeen = true
      if let remoteTrack = track as? RTCVideoTrack {
        remoteVideoTrack = remoteTrack
        for renderer in remoteVideoRenderers {
          remoteTrack.add(renderer)
        }
      }
    }
    recordDiagnostic(
      category: "media_track",
      name: "receiver_added",
      detail: "kind=\(kind) streams=\(mediaStreams.count)"
    )
  }
}
