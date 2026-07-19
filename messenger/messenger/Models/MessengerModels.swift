import Foundation

struct APIErrorResponse: Codable {
  let error: String
}

struct EmptyResponse: Codable {
}

struct AuthPayload: Codable {
  let userId: String
  let iat: Int
  let exp: Int
  let counter: Int
}

struct User: Codable, Equatable {
  let id: String
  let username: String
  let email: String
  let publicKey: String
  let createdAt: Date?
  let updatedAt: Date?
}

struct PublicKeyResponse: Codable, Equatable {
  let userId: String
  let publicKey: String
  let fingerprint: String?
}

// UI models intentionally mirror encrypted-message workflow state rather than backend table names.
struct Conversation: Codable, Equatable {
  enum ConversationType: String, Codable, Equatable {
    case direct
    case group
  }

  let id: String
  let type: ConversationType
  let name: String?
  let createdAt: Date?
  let updatedAt: Date?
  let participants: [ConversationParticipant]?
}

struct ConversationParticipant: Codable, Equatable {
  enum Role: String, Codable, Equatable {
    case member
    case admin
  }

  let id: String
  let conversationId: String
  let userId: String
  let joinedAt: Date?
  let role: Role
}

struct CreateConversationResponse: Codable, Equatable {
  let conversation: Conversation
  let isNew: Bool
}

struct ConversationsResponse: Codable, Equatable {
  let conversations: [Conversation]
}

struct ConversationResponse: Codable, Equatable {
  let conversation: Conversation
}

struct ParticipantsResponse: Codable, Equatable {
  let participants: [ConversationParticipant]
}

struct ParticipantResponse: Codable, Equatable {
  let participant: ConversationParticipant
}

struct ServerMessageResponse: Codable, Equatable {
  let message: String
}

struct Message: Codable, Equatable {
  enum OutboundTransportState: String, Codable, Equatable {
    case pending
    case accepted
    case partialFailure = "partial_failure"
    case failed
  }

  enum MessageType: String, Codable, Equatable {
    case text
    case file
    case media
    case system
    case callOffer = "call_offer"
    case callAnswer = "call_answer"
    case callIceCandidate = "call_ice_candidate"
    case callMediaState = "call_media_state"
    case callEnd = "call_end"

    var isCallSignaling: Bool {
      switch self {
      case .callOffer, .callAnswer, .callIceCandidate, .callMediaState, .callEnd:
        return true
      default:
        return false
      }
    }
  }

  enum EncryptionMode: String, Codable, Equatable {
    case none
    case e2e
  }

  let id: String
  let conversationId: String
  let senderId: String
  let content: String
  let type: MessageType
  let encryptionMode: EncryptionMode?
  let encryptionKeyNonce: String?
  let readAt: Date?
  let deliveredAt: Date?
  let replyToMessageId: String?
  let forwardedFromMessageId: String?
  let deletedBy: String?
  let deletedAt: Date?
  let createdAt: Date
  var attachment: FileAttachment?
  var reactions: [MessageReaction]?
  var transportState: OutboundTransportState? = nil
  var transportErrorDetail: String? = nil

  var isUserVisibleInConversation: Bool {
    !type.isCallSignaling
  }
}

struct FileAttachment: Codable, Equatable {
  let id: String
  let messageId: String
  let storageUrl: String
  let mimeType: String
  let fileSize: Int
  let fileName: String?
  let originServer: String?
  let downloadCapability: String?
  let fileKey: String?
  let hashCipherFile: String?
  let scanVerdict: AttachmentScanVerdict?
  let riskFlags: [String]?
  let scannerVersion: Int?
  let rulesVersion: Int?
  let createdAt: Date?
}

struct MessageReaction: Codable, Equatable {
  let id: String?
  let messageId: String?
  let userId: String
  let emoji: String
  let createdAt: Date?
}

struct MessageEdit: Codable, Equatable {
  let id: String
  let messageId: String
  let oldContent: String
  let editedBy: String
  let editedAt: Date
}

struct PinnedMessage: Codable, Equatable {
  let id: String
  let conversationId: String
  let messageId: String
  let pinnedBy: String
  let pinnedAt: Date
  let previewText: String?
  let messageCreatedAt: Date?
}

struct MessageListResponse: Codable, Equatable {
  let messages: [Message]
  let total: Int
  let limit: Int
  let offset: Int
}

struct MessageResponse: Codable, Equatable {
  let message: Message
  let attachment: FileAttachment?
}

struct MessageEditsResponse: Codable, Equatable {
  let edits: [MessageEdit]
}

struct ReactionsResponse: Codable, Equatable {
  let reactions: [MessageReaction]
}

struct ReactionResponse: Codable, Equatable {
  let reaction: MessageReaction
  let reactions: [MessageReaction]
}

struct PinnedMessagesResponse: Codable, Equatable {
  let pinnedMessages: [PinnedMessage]
}

struct PinnedMessageResponse: Codable, Equatable {
  let pinnedMessage: PinnedMessage
}

struct Call: Codable, Equatable {
  enum CallType: String, Codable, Equatable {
    case voice
    case video
  }

  enum CallStatus: String, Codable, Equatable {
    case initiated
    case active
    case ended
    case missed
  }

  enum ConnectionType: String, Codable, Equatable {
    case direct
    case relay
    case unknown
  }

  enum SecurityState: String, Codable, Equatable {
    case protected
    case unprotected
    case blocked
  }

  let id: String
  let callerId: String
  let receiverId: String
  let type: CallType
  var status: CallStatus
  let startedAt: Date
  var endedAt: Date?
  var duration: Int
  var qualityScore: Double
  var connectionType: ConnectionType
  var callerMuted: Bool
  var receiverMuted: Bool
  var callerCameraEnabled: Bool
  var receiverCameraEnabled: Bool
  var iceCandidatesCount: Int
  var reconnectCount: Int
  var lastQualityUpdate: Date?
  var securityState: SecurityState?
}

struct CallResponse: Codable, Equatable {
  let call: Call
}

struct CallsHistoryResponse: Codable, Equatable {
  let data: [Call]
  let total: Int
  let page: Int
  let limit: Int
}

struct CallsStatsResponse: Codable, Equatable {
  let stats: CallStats
}

struct CallStats: Codable, Equatable {
  let totalCalls: Int
  let completedCalls: Int
  let missedCalls: Int
  let avgDuration: Double?
}

enum PushEnvironment: String, Codable, Equatable {
  case sandbox
  case production
}

enum PushTokenKind: String, Codable, Equatable {
  case alert
  case voip
}

enum PushNotificationHint: String, Codable, Equatable {
  case none
  case message
  case missedCall = "missed_call"
}

struct DeviceToken: Codable, Equatable {
  enum DeviceType: String, Codable, Equatable {
    case ios
    case macos
    case windows
    case android
    case web
  }

  let id: String
  let userId: String
  let deviceType: DeviceType
  let token: String
  let deviceName: String?
  let osVersion: String?
  let appVersion: String?
  let pushEnabled: Bool
  let pushEnvironment: PushEnvironment?
  let pushMode: PushMode?
  let tokenKind: PushTokenKind?
  let lastUsedAt: Date
  let createdAt: Date
}

struct DeviceTokenResponse: Codable, Equatable {
  let token: DeviceToken
}

struct DeviceTokensResponse: Codable, Equatable {
  let tokens: [DeviceToken]
}

struct CallQualityMetric: Codable, Equatable {
  let id: String?
  let callId: String?
  let userId: String?
  let timestamp: Date?
  let bitrateKbps: Int?
  let packetLossPercent: Double?
  let latencyMs: Int?
  let jitterMs: Int?
  let videoWidth: Int?
  let videoHeight: Int?
  let audioLevel: Double?
}

enum TrustVerificationMethod: String, Codable, Equatable {
  case qr
  case manual
  case p2p
}

enum TrustState: String, Codable, Equatable {
  case unverified
  case verified
  case mismatch
  case revoked
}

struct KeyExchangeConsent: Codable, Equatable {
  let id: String
  let ownerUserId: String
  let peerUserId: String
  let consentGiven: Bool
  let consentSource: String
  let createdAt: Date?
  let updatedAt: Date?
}

struct TrustedPeerKeyRecord: Codable, Equatable {
  let id: String
  let ownerUserId: String
  let peerUserId: String
  let peerFingerprint: String
  let verifiedMethod: TrustVerificationMethod
  let state: TrustState
  let peerPublicKeyHash: String?
  let verifiedAt: Date?
  let createdAt: Date?
  let updatedAt: Date?
}

struct E2ETrustStatusResponse: Codable, Equatable {
  enum E2EMode: String, Codable, Equatable {
    case protected
    case unprotected
    case blocked
  }

  let ownerUserId: String
  let peerUserId: String
  let peerFingerprint: String
  let consent: KeyExchangeConsent?
  let mutualConsent: Bool
  let trustRecord: TrustedPeerKeyRecord?
  let effectiveState: TrustState
  let mode: E2EMode
}

struct E2ETrustRecordsResponse: Codable, Equatable {
  let trustRecords: [TrustedPeerKeyRecord]
}

struct E2EVerifyTrustResponse: Codable, Equatable {
  let trustRecord: TrustedPeerKeyRecord
  let fingerprintMatchesServer: Bool?
  let mode: E2ETrustStatusResponse.E2EMode
}

struct E2EConsentResponse: Codable, Equatable {
  let consent: KeyExchangeConsent?
  let mutualConsent: Bool
}

struct PublicKeyFingerprintResponse: Codable, Equatable {
  let userId: String
  let fingerprint: String
}

struct RTCIceServer: Codable, Equatable {
  let urls: String
  let urlStrings: [String]
  let username: String?
  let credential: String?

  enum CodingKeys: String, CodingKey {
    case urls
    case username
    case credential
  }

  init(urls: String, username: String?, credential: String?) {
    self.urls = urls
    self.urlStrings = urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [urls]
    self.username = username
    self.credential = credential
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let url: String = try? container.decode(String.self, forKey: .urls) {
      urls = url
      urlStrings = url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [url]
    } else {
      let decodedUrls: [String] = try container.decode([String].self, forKey: .urls)
      urlStrings = decodedUrls
      urls = decodedUrls.first ?? ""
    }
    username = try container.decodeIfPresent(String.self, forKey: .username)
    credential = try container.decodeIfPresent(String.self, forKey: .credential)
  }
}

struct TurnCredentials: Codable, Equatable {
  let username: String
  let password: String
  let credential: String?
  let expiresAt: Int?
  let ttl: Int

  enum CodingKeys: String, CodingKey {
    case username
    case password
    case credential
    case expiresAt
    case ttl
  }

  init(username: String, password: String, ttl: Int) {
    self.username = username
    self.password = password
    self.credential = password
    self.expiresAt = nil
    self.ttl = ttl
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    username = try container.decode(String.self, forKey: .username)
    let decodedCredential: String? = try container.decodeIfPresent(String.self, forKey: .credential)
    password = try container.decodeIfPresent(String.self, forKey: .password) ?? decodedCredential ?? ""
    credential = decodedCredential
    expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
    ttl = try container.decode(Int.self, forKey: .ttl)
  }
}

struct RTCConfig: Codable, Equatable {
  let iceServers: [RTCIceServer]
  let turnCredentials: TurnCredentials
  let iceTransportPolicy: String?

  init(iceServers: [RTCIceServer], turnCredentials: TurnCredentials, iceTransportPolicy: String? = nil) {
    self.iceServers = iceServers
    self.turnCredentials = turnCredentials
    self.iceTransportPolicy = iceTransportPolicy
  }
}

struct EncryptedPayload: Codable, Equatable {
  let encryptedKey: String
  let iv: String
  let authTag: String
  let ciphertext: String
  let signature: String?
  let senderPublicKey: String?
}

struct JSONValue: Codable, Equatable {
  let value: AnyHashable

  init(value: AnyHashable) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container: SingleValueDecodingContainer = try decoder.singleValueContainer()

    if let intValue: Int = try? container.decode(Int.self) {
      value = intValue
      return
    }

    if let doubleValue: Double = try? container.decode(Double.self) {
      value = doubleValue
      return
    }

    if let stringValue: String = try? container.decode(String.self) {
      value = stringValue
      return
    }

    if let boolValue: Bool = try? container.decode(Bool.self) {
      value = boolValue
      return
    }

    if let stringArray: [String] = try? container.decode([String].self) {
      value = stringArray as NSArray
      return
    }

    if let dictionary: [String: String] = try? container.decode([String: String].self) {
      value = dictionary as NSDictionary
      return
    }

    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
  }

  func encode(to encoder: Encoder) throws {
    var container: SingleValueEncodingContainer = encoder.singleValueContainer()

    switch value {
    case let intValue as Int:
      try container.encode(intValue)
    case let doubleValue as Double:
      try container.encode(doubleValue)
    case let stringValue as String:
      try container.encode(stringValue)
    case let boolValue as Bool:
      try container.encode(boolValue)
    case let stringArray as [String]:
      try container.encode(stringArray)
    case let dictionary as [String: String]:
      try container.encode(dictionary)
    default:
      try container.encodeNil()
    }
  }
}

struct Pagination {
  let limit: Int
  let offset: Int
}

struct MessageSendPayload: Encodable {
  let content: String
  let type: Message.MessageType
  let encryptionMode: Message.EncryptionMode?
  let encryptionKeyNonce: String?
  let fileName: String?
  let replyToMessageId: String?
  let forwardFromMessageId: String?

  enum CodingKeys: String, CodingKey {
    case content
    case type
    case encryptionMode = "encryption_mode"
    case encryptionKeyNonce = "encryption_key_nonce"
    case fileName
    case replyToMessageId
    case forwardFromMessageId
  }
}

struct CreateConversationPayload: Encodable {
  let type: Conversation.ConversationType
  let name: String?
  let participantIds: [String]

  enum CodingKeys: String, CodingKey {
    case type
    case name
    case participantIds
  }
}

struct AddParticipantsPayload: Encodable {
  let userIds: [String]
  let role: ConversationParticipant.Role

  enum CodingKeys: String, CodingKey {
    case userIds
    case role
  }
}

struct UpdateParticipantRolePayload: Encodable {
  let role: ConversationParticipant.Role
}

struct CallCreatePayload: Encodable {
  let receiverId: String
  let type: Call.CallType

  enum CodingKeys: String, CodingKey {
    case receiverId = "receiver_id"
    case type
  }
}

struct CallMutePayload: Encodable {
  let muted: Bool
}

struct CallCameraPayload: Encodable {
  let enabled: Bool
}

struct CallStatsPayload: Encodable {
  let qualityScore: Double?
  let connectionType: Call.ConnectionType?
}

struct DeviceTokenRegistrationPayload: Encodable {
  let deviceType: DeviceToken.DeviceType
  let token: String
  let deviceName: String?
  let osVersion: String?
  let appVersion: String?
  let pushEnabled: Bool
  let pushEnvironment: PushEnvironment
  let pushMode: PushMode
  let tokenKind: PushTokenKind
}

struct E2EVerifyPayload: Encodable {
  let peerFingerprint: String
  let method: TrustVerificationMethod
}

struct E2EMismatchPayload: Encodable {
  let peerFingerprint: String
}

struct E2EConsentPayload: Encodable {
  let consent: Bool
  let source: String?
}
