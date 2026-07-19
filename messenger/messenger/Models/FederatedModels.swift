import Foundation

enum PushMode: String, Codable, Equatable {
  case privacyFirst = "privacy_first"
  case fastNotify = "fast_notify"
}

enum PushKind: String, Codable, Equatable {
  case message
  case other
}

enum WakeupClass: String, Codable, Equatable {
  case generic
  case voipOpaque = "voip_opaque"
}

struct DeviceCertificateV2: Codable, Equatable {
  let deviceCertificateVersion: Int
  let accountHandle: String
  let deviceId: String
  let deviceSignPub: String
  let deviceDhPub: String
  let issuerKind: String
  let issuerDeviceId: String?
  let parentCertificateId: String?
  let issuedAt: Date
  let expiresAt: Date?
  let signature: String
}

struct FederatedDevicePublicKeys: Codable, Equatable {
  let deviceId: String
  let dkSignPub: String
  let dkDhPub: String
}

struct FederatedInitialDevice: Codable, Equatable {
  let deviceId: String
  let dkSignPub: String
  let dkDhPub: String
  let deviceCertificateChain: [DeviceCertificateV2]
}

struct FederatedRegisterRequest: Codable, Equatable {
  let userHandle: String
  let ikSignPub: String
  let ikDhPub: String
  let signature: String
  let timestamp: String
  let initialDevice: FederatedInitialDevice
}

struct FederatedRegisterResponse: Codable, Equatable {
  let userHandle: String
  let deviceId: String
  let sessionToken: String
  let refreshToken: String
  let expiresIn: Int
}

struct FederatedAuthStartRequest: Codable, Equatable {
  let userHandle: String
  let deviceId: String?
}

struct FederatedAuthStartResponse: Codable, Equatable {
  let challengeId: String
  let nonce: String
  let expiresAt: Date
}

struct FederatedAuthFinishRequest: Codable, Equatable {
  let userHandle: String
  let deviceId: String
  let challengeId: String
  let signature: String
}

struct FederatedSessionTokens: Codable, Equatable {
  let sessionToken: String
  let refreshToken: String
  let expiresIn: Int
}

struct FederatedRefreshRequest: Codable, Equatable {
  let refreshToken: String
}

struct FederatedLogoutRequest: Codable, Equatable {
  let sessionToken: String?
  let refreshToken: String?
}

struct FederatedLogoutResponse: Codable, Equatable {
  let success: Bool
}

struct FederatedPrekeySigned: Codable, Equatable {
  let prekeyId: String
  let signedPrekeyPub: String
  let signature: String
  let expiresAt: Date?
}

struct FederatedPrekeyOneTime: Codable, Equatable {
  let prekeyId: String
  let prekeyPub: String
}

struct FederatedPrekeysPublishRequest: Codable, Equatable {
  let protocolVersion: Int
  let deviceId: String
  let signedPrekey: FederatedPrekeySigned
  let oneTimePrekeys: [FederatedPrekeyOneTime]
}

struct FederatedPrekeysPublishResponse: Codable, Equatable {
  let signedPrekeyId: String
  let oneTimePrekeysAdded: Int
}

struct FederatedPrekeyBundle: Codable, Equatable {
  let protocolVersion: Int
  let userHandle: String
  let deviceId: String
  let accountSignPub: String
  let deviceSignPub: String
  let deviceDhPub: String
  let deviceCertificateChain: [DeviceCertificateV2]
  let signedPrekey: FederatedPrekeySigned
  let oneTimePrekey: FederatedPrekeyOneTime?
  let pushMode: PushMode

  var ikSignPub: String {
    accountSignPub
  }

  var dkSignPub: String {
    deviceSignPub
  }

  var dkDhPub: String {
    deviceDhPub
  }

  var ikDeviceSignature: String {
    deviceCertificateChain.last?.signature ?? ""
  }
}

struct FederatedPrekeysGetResponse: Codable, Equatable {
  let bundles: [FederatedPrekeyBundle]
}

struct FederatedDeviceRegisterRequest: Codable, Equatable {
  let devicePubKeys: FederatedDevicePublicKeys
  let deviceCertificateChain: [DeviceCertificateV2]
}

struct FederatedDeviceRevokeRequest: Codable, Equatable {
  let deviceId: String
  let signature: String
  let timestamp: String?
}

struct FederatedDeviceLinkStartRequest: Codable, Equatable {
  let linkCode: String
  let lDhPub: String
  let expiresInSec: Int?
}

struct FederatedDeviceLinkStartResponse: Codable, Equatable {
  let linkSessionId: String
  let expiresAt: Date
}

struct FederatedDeviceLinkRequestRequest: Codable, Equatable {
  let userHandle: String
  let linkCode: String
  let nDhPub: String
  let devicePubKeys: FederatedDevicePublicKeys
}

struct FederatedDeviceLinkRequestResponse: Codable, Equatable {
  let requestId: String
  let status: String
  let pollToken: String
}

struct FederatedDeviceLinkApproveRequest: Codable, Equatable {
  let linkCode: String
  let requestId: String
  let approvedDeviceCertificate: DeviceCertificateV2
  let encryptedProvisioningBlob: String
}

struct FederatedDeviceLinkApproveResponse: Codable, Equatable {
  let requestId: String
  let status: String
}

struct FederatedDeviceLinkSessionRequest: Codable, Equatable {
  let requestId: String
  let status: String
  let newDeviceId: String
  let nDhPub: String
  let dkSignPub: String
  let dkDhPub: String
  let approvedDeviceCertificate: DeviceCertificateV2?
  let encryptedProvisioningBlob: String?
  let createdAt: Date
}

struct FederatedDeviceLinkSessionRequestsResponse: Codable, Equatable {
  let requests: [FederatedDeviceLinkSessionRequest]
}

struct FederatedDeviceLinkPollResponse: Codable, Equatable {
  let requestId: String
  let status: String
  let approvedDeviceCertificate: DeviceCertificateV2?
  let encryptedProvisioningBlob: String?
}

struct FederatedDeviceLinkCompleteRequest: Codable, Equatable {
  let requestId: String
  let pollToken: String
  let devicePubKeys: FederatedDevicePublicKeys
  let signedPrekey: FederatedPrekeySigned
  let oneTimePrekeys: [FederatedPrekeyOneTime]
}

struct FederatedDeviceLinkCompleteResponse: Codable, Equatable {
  let userHandle: String
  let deviceId: String
  let sessionToken: String
  let refreshToken: String
  let expiresIn: Int
}

struct FederatedDelivery: Codable, Equatable {
  let wireVersion: Int
  let deliveryId: String
  let toServer: String
  let toUser: String
  let toDeviceId: String
  let messageId: String
  let timestamp: String
  let ttlSec: Int
  let ciphertextBlob: String
  let pushKind: PushKind?
  let wakeupClass: WakeupClass?
}

struct FederatedSendRequest: Codable, Equatable {
  let deliveries: [FederatedDelivery]
}

struct FederatedSendResult: Codable, Equatable {
  let deliveryId: String
  let status: String
}

struct FederatedSendResponse: Codable, Equatable {
  let accepted: Int
  let results: [FederatedSendResult]
}

struct FederatedAckRequest: Codable, Equatable {
  let msgIds: [String]
}

struct FederatedAckResponse: Codable, Equatable {
  let acked: Int
}

struct FederatedMailboxBlob: Codable, Equatable {
  let id: String
  let ownerAccountId: String
  let ownerDeviceId: String
  let senderServer: String
  let messageId: String
  let deliveryId: String
  let ciphertextBlob: String
  let ttlSec: Int
  let expiresAt: Date
  let ackedAt: Date?
  let createdAt: Date
}

struct FederatedSyncResponse: Codable, Equatable {
  let deviceId: String
  let blobs: [FederatedMailboxBlob]
}

struct FederatedMediaUploadInitRequest: Codable, Equatable {
  let mimeHint: String?
  let sizeHint: Int?
  let ttlSec: Int?
}

struct FederatedMediaUploadInitResponse: Codable, Equatable {
  let mediaId: String
  let uploadPath: String
  let downloadPath: String
  let downloadCapability: String
  let originServer: String
  let expiresAt: Date
}

struct FederatedMediaUploadResponse: Codable, Equatable {
  let mediaId: String
  let uploaded: Bool
  let attestationPayload: String?
}

struct E2EAttachmentReference: Codable, Equatable {
  let originServer: String
  let mediaId: String
  let downloadCapability: String
  let fileKey: String
  let hashCipherFile: String
  let mime: String?
  let size: Int?
  let scanVerdict: AttachmentScanVerdict
  let riskFlags: [String]
  let scannerVersion: Int
  let rulesVersion: Int
}

struct E2EMessagePayload: Codable, Equatable {
  let conversationId: String
  let msgType: String
  let body: String
  let attachments: [E2EAttachmentReference]
  let padding: String
}

enum EncryptedMessageEnvelopeKind: String, Codable, Equatable {
  case prekeyInit = "prekey_init"
  case ratchetMessage = "ratchet_message"
}

struct EncryptedMessageHeader: Codable, Equatable {
  let conversationId: String
  let senderUserHandle: String
  let senderDeviceId: String
  let messageIndex: Int
  let previousChainLength: Int
  let ratchetPub: String?
  let direction: String
  let sentAt: Date
}

struct EncryptedMessageEnvelope: Codable, Equatable {
  let protocolVersion: Int
  let kind: EncryptedMessageEnvelopeKind
  let sessionId: String
  /// Ephemeral DH pub from X3DH initiator (legacy: decoded from "bootstrap_dh_pub")
  let ephemeralPub: String?
  /// Sender device DH pub needed to derive initial X3DH session for inbound prekey_init.
  let senderDeviceDhPub: String?
  /// Current DH ratchet public key (visible outer field)
  let ratchetPub: String?
  let signedPrekeyId: String?
  let oneTimePrekeyId: String?
  let encryptedHeader: AEADCiphertextEnvelope
  let encryptedBody: AEADCiphertextEnvelope

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case kind
    case sessionId = "session_id"
    case ephemeralPub = "bootstrap_dh_pub"
    case senderDeviceDhPub = "sender_device_dh_pub"
    case ratchetPub = "ratchet_pub"
    case signedPrekeyId = "signed_prekey_id"
    case oneTimePrekeyId = "one_time_prekey_id"
    case encryptedHeader = "encrypted_header"
    case encryptedBody = "encrypted_body"
  }
}

struct QRContactCard: Codable, Equatable {
  let userHandle: String
  let ikSignPub: String
  let ikDhPub: String
  let deviceListDigest: String?
  let inviteToken: String?
}

struct DeviceLinkCodePayload: Codable, Equatable {
  let userHandle: String
  let linkCode: String
  let lDhPub: String
}

struct DeviceLinkProvisioningPayload: Codable, Equatable {
  let userHandle: String
  let accountSignPub: String
  let generatedAt: Date
  let localState: DeviceLinkLocalStateSnapshot?
  let trustState: DeviceLinkTrustStateSnapshot?
}

struct DeviceLinkLocalStateSnapshot: Codable, Equatable {
  let exportedAt: Date
  let conversations: [DeviceLinkConversationArchive]
}

struct DeviceLinkTrustStateSnapshot: Codable, Equatable {
  let exportedAt: Date
  let trustByPeerUserId: [String: TrustedPeerKeyRecord]
  let consentByPeerUserId: [String: KeyExchangeConsent]
}

struct DeviceLinkConversationArchive: Codable, Equatable {
  let conversation: Conversation
  let messages: [Message]
  let editsByMessageId: [String: [MessageEdit]]
  let replyPreviewByReplyMessageId: [String: String]
  let pinnedMessages: [PinnedMessage]
  let hiddenPinnedMessageIds: [String]?
  let hiddenMessageIds: [String]
  let sentReadReceiptMessageIds: [String]
  let pendingReadReceiptMessageIds: [String]
  let deferredControlMessages: [Message]
}

enum ConversationTrustState: String, Codable, Equatable {
  case verified = "qr_verified"
  case unverified = "unverified"
}
