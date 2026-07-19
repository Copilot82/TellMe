import CryptoKit
import Foundation

struct CallSessionDescriptionSignal: Equatable {
  let callId: String
  let fromUserId: String?
  let type: String
  let sdp: String
  let dtlsFingerprint: String?
  let offerId: String?
  let answerToOfferId: String?

  init(
    callId: String,
    fromUserId: String?,
    type: String,
    sdp: String,
    dtlsFingerprint: String? = nil,
    offerId: String? = nil,
    answerToOfferId: String? = nil
  ) {
    self.callId = callId
    self.fromUserId = fromUserId
    self.type = type
    self.sdp = sdp
    self.dtlsFingerprint = dtlsFingerprint
    self.offerId = offerId
    self.answerToOfferId = answerToOfferId
  }
}

struct CallICECandidateSignal: Equatable {
  let callId: String
  let sdp: String
  let sdpMid: String?
  let sdpMLineIndex: Int32

  var dedupeKey: String {
    [
      normalizedKeyComponent(callId),
      normalizedKeyComponent(sdpMid ?? ""),
      String(sdpMLineIndex),
      normalizedCandidateSDP(sdp),
    ].joined(separator: "|")
  }

  private func normalizedCandidateSDP(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map(String.init)
      .joined(separator: " ")
  }

  private func normalizedKeyComponent(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct CallMediaStateSignal: Equatable {
  let callId: String
  let isMicrophoneEnabled: Bool
  let isCameraEnabled: Bool?
}

struct CallRenegotiationState {
  enum RemoteReconnectOfferDisposition: Equatable {
    case ignore
    case apply
    case rollbackLocalOfferAndApply
  }

  private(set) var pendingLocalOfferId: String?
  private(set) var localOfferGeneration: Int = 0
  private(set) var lastAppliedRemoteOfferSDP: String?
  private(set) var lastAppliedRemoteAnswerSDP: String?
  private(set) var lastAppliedRemoteAnswerToOfferId: String?
  private var lastLocalOfferId: String?

  var hasPendingLocalOfferAnswer: Bool {
    pendingLocalOfferId != nil
  }

  mutating func markLocalOfferSent(offerId: String) {
    guard let normalizedOfferId: String = normalizedOfferIdentifier(offerId) else {
      return
    }

    if lastLocalOfferId != normalizedOfferId {
      localOfferGeneration += 1
      lastLocalOfferId = normalizedOfferId
    }
    pendingLocalOfferId = normalizedOfferId
  }

  mutating func markLocalOfferRolledBack() {
    pendingLocalOfferId = nil
  }

  func shouldApplyRemoteReconnectOffer(payload: [String: Any], sdp: String) -> Bool {
    remoteReconnectOfferDisposition(
      payload: payload,
      sdp: sdp,
      localUserId: nil,
      remoteUserId: nil
    ) == .apply
  }

  func remoteReconnectOfferDisposition(
    payload: [String: Any],
    sdp: String,
    localUserId: String?,
    remoteUserId: String?
  ) -> RemoteReconnectOfferDisposition {
    guard CallSignalParser.isReconnectOffer(payload), sdp != lastAppliedRemoteOfferSDP else {
      return .ignore
    }

    guard hasPendingLocalOfferAnswer else {
      return .apply
    }

    guard isPolitePeer(localUserId: localUserId, remoteUserId: remoteUserId) else {
      return .ignore
    }

    return .rollbackLocalOfferAndApply
  }

  mutating func markRemoteOfferApplied(sdp: String) {
    lastAppliedRemoteOfferSDP = sdp
    pendingLocalOfferId = nil
  }

  func shouldApplyRemoteAnswer(sdp: String, answerToOfferId: String?) -> Bool {
    guard let pendingLocalOfferId,
      !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }

    if let answerToOfferId: String = normalizedOfferIdentifier(answerToOfferId) {
      return answerToOfferId == pendingLocalOfferId
    }

    // Correlation IDs are an additive call_version=1 extension. A pre-extension
    // peer may omit the ID for the initial offer, but an uncorrelated answer is
    // unsafe after any replacement offer (for example, an ICE restart).
    return localOfferGeneration == 1
  }

  mutating func markRemoteAnswerApplied(sdp: String, answerToOfferId: String?) {
    guard shouldApplyRemoteAnswer(sdp: sdp, answerToOfferId: answerToOfferId) else {
      return
    }

    lastAppliedRemoteAnswerSDP = sdp
    lastAppliedRemoteAnswerToOfferId = normalizedOfferIdentifier(answerToOfferId)
    pendingLocalOfferId = nil
  }

  private func isPolitePeer(localUserId: String?, remoteUserId: String?) -> Bool {
    guard let localUserId: String = normalizedUserId(localUserId),
      let remoteUserId: String = normalizedUserId(remoteUserId),
      localUserId != remoteUserId
    else {
      return false
    }

    return localUserId > remoteUserId
  }

  private func normalizedUserId(_ userId: String?) -> String? {
    guard let normalized: String = userId?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !normalized.isEmpty
    else {
      return nil
    }

    return normalized
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
}

struct E2EIncomingCallDescriptor: Equatable {
  let systemUUID: UUID
  let callId: String
  let conversation: Conversation
  let offer: CallSessionDescriptionSignal
  let callType: Call.CallType
  let callerUserId: String
}

enum CallSignalProcessingOrder {
  static func sorted(_ messages: [Message], callId: String) -> [Message] {
    messages.sorted { left, right in
      sortKey(for: left, callId: callId) < sortKey(for: right, callId: callId)
    }
  }

  private static func sortKey(for message: Message, callId: String) -> SortKey {
    guard message.type.isCallSignaling,
      let payload: [String: Any] = CallSignalParser.payload(from: message),
      CallSignalParser.callId(from: payload)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == callId,
      let sequence: Int = CallSignalParser.sequence(from: payload)
    else {
      return SortKey(
        priority: 1,
        sequence: Int.max,
        sentAt: nil,
        createdAt: message.createdAt,
        id: message.id
      )
    }

    return SortKey(
      priority: 0,
      sequence: sequence,
      sentAt: CallSignalParser.sentAtDate(from: payload),
      createdAt: message.createdAt,
      id: message.id
    )
  }

  private struct SortKey: Comparable {
    let priority: Int
    let sequence: Int
    let sentAt: Date?
    let createdAt: Date
    let id: String

    static func < (left: SortKey, right: SortKey) -> Bool {
      if left.priority != right.priority {
        return left.priority < right.priority
      }
      if left.sequence != right.sequence {
        return left.sequence < right.sequence
      }
      switch (left.sentAt, right.sentAt) {
      case let (leftSentAt?, rightSentAt?) where leftSentAt != rightSentAt:
        return leftSentAt < rightSentAt
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        break
      }
      if left.createdAt != right.createdAt {
        return left.createdAt < right.createdAt
      }
      return left.id < right.id
    }
  }
}

enum CallSignalEnvelope {
  // Offer correlation is additive within version 1 so existing peers can still
  // establish an initial call. CallRenegotiationState fails closed on missing
  // correlation after the first local offer generation.
  static let currentVersion: Int = 1
  static let transportProfile: String = "webrtc_turn_relay"
  static let initialTranscriptHash: String = String(repeating: "0", count: 64)

  struct TranscriptState {
    var nextSequence: Int = 1
    var previousTranscriptHash: String = CallSignalEnvelope.initialTranscriptHash
  }

  static func payload(
    callId: String,
    sentAt: Date = Date(),
    sequence: Int = 1,
    previousTranscriptHash: String = initialTranscriptHash,
    senderDeviceId: String? = nil,
    targetDeviceId: String? = nil,
    dtlsFingerprint: String? = nil,
    values: [String: Any] = [:]
  ) -> [String: Any] {
    var payload: [String: Any] = [
      "call_id": callId,
      "call_version": currentVersion,
      "sent_at": ISO8601DateFormatter.withFractionalSeconds.string(from: sentAt),
      "transport_profile": transportProfile,
      "seq": sequence,
      "prev_event_hash": previousTranscriptHash,
    ]
    payload.merge(values) { _, new in new }
    payload["call_id"] = callId
    payload["call_version"] = currentVersion
    payload["sent_at"] = ISO8601DateFormatter.withFractionalSeconds.string(from: sentAt)
    payload["transport_profile"] = transportProfile
    payload["seq"] = sequence
    payload["prev_event_hash"] = previousTranscriptHash
    payload["transcript_hash"] = nil
    if let senderDeviceId: String = normalizedNonEmptyString(senderDeviceId) {
      payload["sender_device_id"] = senderDeviceId
    }
    if let targetDeviceId: String = normalizedNonEmptyString(targetDeviceId) {
      payload["target_device_id"] = targetDeviceId
    }
    if let dtlsFingerprint: String = normalizedNonEmptyString(dtlsFingerprint) {
      payload["dtls_fingerprint"] = dtlsFingerprint
    }
    payload["transcript_hash"] = transcriptHash(for: payload)
    return payload
  }

  static func prepareOutgoingPayload(
    _ values: [String: Any],
    callId: String,
    senderDeviceId: String?,
    targetDeviceId: String? = nil,
    state: inout TranscriptState
  ) -> [String: Any] {
    let payload: [String: Any] = self.payload(
      callId: callId,
      sequence: state.nextSequence,
      previousTranscriptHash: state.previousTranscriptHash,
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetDeviceId,
      values: values
    )
    state.nextSequence += 1
    state.previousTranscriptHash = transcriptHash(for: payload)
    return payload
  }

  static func transcriptHash(for payload: [String: Any]) -> String {
    var canonicalPayload: [String: Any] = payload
    canonicalPayload.removeValue(forKey: "transcript_hash")
    canonicalPayload.removeValue(forKey: "transcriptHash")

    guard JSONSerialization.isValidJSONObject(canonicalPayload),
      let data: Data = try? JSONSerialization.data(withJSONObject: canonicalPayload, options: [.sortedKeys])
    else {
      return sha256Hex(Data())
    }

    return sha256Hex(data)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }

  private static func normalizedNonEmptyString(_ value: String?) -> String? {
    guard let normalized: String = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else {
      return nil
    }

    return normalized
  }
}

enum CallSignalParser {
  private static let maximumAcceptedSignalAge: TimeInterval = 10 * 60
  private static let maximumAcceptedFutureSkew: TimeInterval = 2 * 60

  static func payload(from message: Message) -> [String: Any]? {
    parseJSONObject(from: message.content)
  }

  static func incomingCallDescriptor(
    from message: Message,
    conversation: Conversation,
    currentUserId: String?,
    localDeviceId: String? = nil,
    systemUUID: UUID = UUID()
  ) -> E2EIncomingCallDescriptor? {
    guard message.type == .callOffer,
      message.senderId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        != currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      let payload: [String: Any] = parseJSONObject(from: message.content),
      isInitialOffer(payload),
      let callId: String = stringValue(payload["call_id"] ?? payload["callId"]),
      !callId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      hasValidEnvelope(payload),
      localDeviceId == nil || isTargeted(to: localDeviceId, payload: payload)
    else {
      return nil
    }

    let rawCallType: String = stringValue(payload["call_type"] ?? payload["callType"]) ?? Call.CallType.video.rawValue
    let callType: Call.CallType = Call.CallType(rawValue: rawCallType) ?? .video
    let callerUserId: String = stringValue(payload["from_user"] ?? payload["fromUser"]) ?? message.senderId
    guard let offer: CallSessionDescriptionSignal = sessionDescription(
      from: payload,
      objectKey: "offer",
      senderId: callerUserId,
      callId: callId
    ) else {
      return nil
    }

    return E2EIncomingCallDescriptor(
      systemUUID: systemUUID,
      callId: callId,
      conversation: conversation,
      offer: offer,
      callType: callType,
      callerUserId: callerUserId
    )
  }

  static func sessionDescription(
    from payload: [String: Any],
    objectKey: String,
    senderId: String,
    callId: String
  ) -> CallSessionDescriptionSignal? {
    guard hasValidEnvelope(payload),
      let object: [String: Any] = payload[objectKey] as? [String: Any],
      let type: String = stringValue(object["type"]),
      let sdp: String = stringValue(object["sdp"]),
      !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      isRelayOnlySessionDescription(sdp),
      let dtlsFingerprint: String = dtlsFingerprint(fromSDP: sdp),
      hasMatchingDTLSFingerprint(payload, sdp: sdp)
    else {
      return nil
    }

    let offerId: String? = normalizedOfferIdentifier(
      object["offer_id"] ?? object["offerId"]
    ) ?? normalizedOfferIdentifier(payload["offer_id"] ?? payload["offerId"])
    let answerToOfferId: String? = normalizedOfferIdentifier(
      object["answer_to_offer_id"] ?? object["answerToOfferId"]
    ) ?? normalizedOfferIdentifier(payload["answer_to_offer_id"] ?? payload["answerToOfferId"])

    return CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: senderId,
      type: type,
      sdp: sdp,
      dtlsFingerprint: dtlsFingerprint,
      offerId: offerId,
      answerToOfferId: answerToOfferId
    )
  }

  static func callId(from message: Message) -> String? {
    guard let payload: [String: Any] = payload(from: message) else {
      return nil
    }

    return stringValue(payload["call_id"] ?? payload["callId"])
  }

  static func sequence(from payload: [String: Any]) -> Int? {
    integerValue(payload["seq"])
  }

  static func sentAtDate(from payload: [String: Any]) -> Date? {
    guard let sentAt: String = stringValue(payload["sent_at"] ?? payload["sentAt"])?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !sentAt.isEmpty
    else {
      return nil
    }

    return ISO8601DateFormatter.withFractionalSeconds.date(from: sentAt)
      ?? ISO8601DateFormatter.standard.date(from: sentAt)
  }

  static func isInitialOffer(_ payload: [String: Any]) -> Bool {
    offerKind(from: payload) == "initial"
  }

  static func isReconnectOffer(_ payload: [String: Any]) -> Bool {
    offerKind(from: payload) == "ice_restart"
  }

  private static func offerKind(from payload: [String: Any]) -> String {
    let offerKind: String = stringValue(payload["offer_kind"] ?? payload["offerKind"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "initial"
    return offerKind
  }

  static func hasValidEnvelope(_ payload: [String: Any], now: Date = Date()) -> Bool {
    hasValidCallId(payload)
      && hasRelayTransportProfile(payload)
      && hasSupportedCallVersion(payload)
      && hasValidSentAt(payload, now: now)
      && hasValidDeviceBinding(payload)
      && hasValidTranscriptMetadata(payload)
  }

  static func hasValidCallId(_ payload: [String: Any]) -> Bool {
    guard let callId: String = callId(from: payload)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return false
    }

    return !callId.isEmpty
  }

  static func senderDeviceId(from payload: [String: Any]) -> String? {
    normalizedDeviceId(payload["sender_device_id"] ?? payload["senderDeviceId"])
  }

  static func targetDeviceId(from payload: [String: Any]) -> String? {
    normalizedDeviceId(payload["target_device_id"] ?? payload["targetDeviceId"])
  }

  static func hasValidDeviceBinding(_ payload: [String: Any]) -> Bool {
    senderDeviceId(from: payload) != nil && targetDeviceId(from: payload) != nil
  }

  static func isTargeted(to localDeviceId: String?, payload: [String: Any]) -> Bool {
    guard let expectedDeviceId: String = normalizedDeviceId(localDeviceId),
      let targetDeviceId: String = targetDeviceId(from: payload)
    else {
      return false
    }

    return targetDeviceId == expectedDeviceId
  }

  static func dtlsFingerprint(fromSDP sdp: String) -> String? {
    let fingerprints: Set<String> = Set(
      sdp.components(separatedBy: .newlines).compactMap { line in
        normalizedDTLSFingerprintLine(line)
      }
    )

    guard fingerprints.count == 1 else {
      return nil
    }

    return fingerprints.first
  }

  static func hasMatchingDTLSFingerprint(_ payload: [String: Any], sdp: String) -> Bool {
    guard let expected: String = normalizedDTLSFingerprint(payload["dtls_fingerprint"] ?? payload["dtlsFingerprint"]),
      let actual: String = dtlsFingerprint(fromSDP: sdp)
    else {
      return false
    }

    return expected == actual
  }

  static func hasRelayTransportProfile(_ payload: [String: Any]) -> Bool {
    let profile: String = stringValue(payload["transport_profile"] ?? payload["transportProfile"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return profile == CallSignalEnvelope.transportProfile
  }

  static func hasSupportedCallVersion(_ payload: [String: Any]) -> Bool {
    guard let version: Int = integerValue(payload["call_version"] ?? payload["callVersion"]) else {
      return false
    }

    return version == CallSignalEnvelope.currentVersion
  }

  static func hasValidSentAt(_ payload: [String: Any], now: Date = Date()) -> Bool {
    guard let sentAtDate: Date = sentAtDate(from: payload)
    else {
      return false
    }

    return sentAtDate >= now.addingTimeInterval(-maximumAcceptedSignalAge)
      && sentAtDate <= now.addingTimeInterval(maximumAcceptedFutureSkew)
  }

  static func hasValidTranscriptMetadata(_ payload: [String: Any]) -> Bool {
    guard let sequence: Int = integerValue(payload["seq"]),
      sequence > 0,
      let previousTranscriptHash: String = stringValue(payload["prev_event_hash"] ?? payload["prevEventHash"])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      isSHA256Hex(previousTranscriptHash),
      let transcriptHash: String = stringValue(payload["transcript_hash"] ?? payload["transcriptHash"])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      isSHA256Hex(transcriptHash)
    else {
      return false
    }

    return transcriptHash == CallSignalEnvelope.transcriptHash(for: payload)
  }

  static func isRelayOnlySessionDescription(_ sdp: String) -> Bool {
    let lines: [String] = sdp.components(separatedBy: .newlines)
    let candidateLines: [String] = lines.filter { line in
      let normalized: String = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return normalized.hasPrefix("a=candidate:") || normalized.hasPrefix("candidate:")
    }

    return candidateLines.allSatisfy(isRelayCandidate)
  }

  static func isRelayCandidate(_ candidate: String) -> Bool {
    let normalized: String = candidate
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    let tokens: [String] = normalized
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map { String($0).lowercased() }

    guard let typeIndex: Int = tokens.firstIndex(of: "typ"),
      tokens.indices.contains(typeIndex + 1)
    else {
      return false
    }

    return tokens[typeIndex + 1] == "relay"
  }

  static func iceCandidate(from payload: [String: Any], callId: String) -> CallICECandidateSignal? {
    guard hasValidEnvelope(payload) else {
      return nil
    }

    let source: [String: Any]
    if let nested: [String: Any] = payload["candidate"] as? [String: Any] {
      source = nested
    } else {
      source = payload
    }

    guard let candidate: String = stringValue(source["candidate"]) ?? stringValue(source["sdp"]),
      !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      isRelayCandidate(candidate)
    else {
      return nil
    }

    let sdpMid: String? = stringValue(source["sdpMid"]) ?? stringValue(source["sdp_mid"])
    let sdpMLineIndex: Int32 = int32Value(source["sdpMLineIndex"])
      ?? int32Value(source["sdp_mline_index"])
      ?? 0

    return CallICECandidateSignal(callId: callId, sdp: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
  }

  static func mediaState(from payload: [String: Any], callId: String) -> CallMediaStateSignal? {
    guard hasValidEnvelope(payload),
      let microphoneEnabled: Bool = boolValue(payload["microphone_enabled"] ?? payload["microphoneEnabled"])
    else {
      return nil
    }

    let cameraEnabled: Bool? = boolValue(payload["camera_enabled"] ?? payload["cameraEnabled"])
    return CallMediaStateSignal(
      callId: callId,
      isMicrophoneEnabled: microphoneEnabled,
      isCameraEnabled: cameraEnabled
    )
  }

  static func callId(from payload: [String: Any]) -> String? {
    stringValue(payload["call_id"] ?? payload["callId"])
  }

  private static func parseJSONObject(from raw: String) -> [String: Any]? {
    guard let data: Data = raw.data(using: .utf8),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: Any] = object as? [String: Any]
    else {
      return nil
    }

    return payload
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }

  private static func normalizedDeviceId(_ value: Any?) -> String? {
    guard let deviceId: String = stringValue(value)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !deviceId.isEmpty
    else {
      return nil
    }

    return deviceId
  }

  private static func normalizedOfferIdentifier(_ value: Any?) -> String? {
    guard let identifier: String = stringValue(value)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else {
      return nil
    }

    return identifier
  }

  private static func normalizedDTLSFingerprint(_ value: Any?) -> String? {
    guard let rawValue: String = stringValue(value) else {
      return nil
    }

    return normalizedDTLSFingerprintLine("a=fingerprint:\(rawValue)")
  }

  private static func normalizedDTLSFingerprintLine(_ line: String) -> String? {
    let trimmed: String = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased: String = trimmed.lowercased()
    let rawFingerprint: Substring
    if lowercased.hasPrefix("a=fingerprint:") {
      rawFingerprint = trimmed.dropFirst("a=fingerprint:".count)
    } else if lowercased.hasPrefix("fingerprint:") {
      rawFingerprint = trimmed.dropFirst("fingerprint:".count)
    } else {
      return nil
    }

    let parts: [Substring] = rawFingerprint.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count == 2 else {
      return nil
    }

    let algorithm: String = parts[0].lowercased()
    guard algorithm == "sha-256" else {
      return nil
    }

    let digest: String = parts[1].uppercased()
    let octets: [Substring] = digest.split(separator: ":")
    guard octets.count == 32,
      octets.allSatisfy({ octet in
        octet.count == 2 && octet.unicodeScalars.allSatisfy { scalar in
          CharacterSet(charactersIn: "0123456789ABCDEF").contains(scalar)
        }
      })
    else {
      return nil
    }

    return "\(algorithm) \(digest)"
  }

  private static func int32Value(_ value: Any?) -> Int32? {
    switch value {
    case let number as NSNumber:
      return number.int32Value
    case let intValue as Int:
      return Int32(intValue)
    case let string as String:
      return Int32(string)
    default:
      return nil
    }
  }

  private static func integerValue(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
      return number.intValue
    case let intValue as Int:
      return intValue
    case let string as String:
      return Int(string)
    default:
      return nil
    }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
      return bool
    case let number as NSNumber:
      return number.boolValue
    case let string as String:
      switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "y", "on":
        return true
      case "0", "false", "no", "n", "off":
        return false
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private static func isSHA256Hex(_ value: String) -> Bool {
    guard value.count == 64 else {
      return false
    }

    let hexScalars = CharacterSet(charactersIn: "0123456789abcdef")
    return value.unicodeScalars.allSatisfy { scalar in
      hexScalars.contains(scalar)
    }
  }
}
