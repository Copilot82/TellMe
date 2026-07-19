import Foundation

struct JoinConversationPayload: Codable, Equatable {
  let conversationId: String
}

struct TypingPayload: Codable, Equatable {
  let conversationId: String
}

struct CallOfferPayload: Codable, Equatable {
  let callId: String
  let targetUserId: String
  let offer: [String: String]
}

struct CallAnswerPayload: Codable, Equatable {
  let callId: String
  let answer: [String: String]
}

struct ICECandidatePayload: Codable, Equatable {
  let callId: String
  let targetUserId: String?
  let candidate: [String: JSONValue]
}

struct CallQualityUpdatePayload: Codable, Equatable {
  let callId: String
  let quality: Double
  let connectionType: String?
}

struct MessageReceivedPayload: Codable, Equatable {
  let messageId: String
}

struct SyncPullPayload: Codable, Equatable {
  let limit: Int
}

struct SyncBlobAvailableEvent: Codable, Equatable {
  let messageId: String
  let deliveryId: String
  let deviceId: String
}

struct IncomingCallEvent: Codable, Equatable {
  let callId: String
  let callerId: String
  let type: Call.CallType?
  let offer: [String: String]?
  let securityState: Call.SecurityState?
  let signalingEncrypted: Bool?
}

struct CallAnsweredEvent: Codable, Equatable {
  let callId: String
  let status: String?
  let answer: [String: String]?
  let securityState: Call.SecurityState?
  let signalingEncrypted: Bool?
}

struct CallICECandidateEvent: Codable, Equatable {
  let callId: String
  let candidate: [String: JSONValue]
  let senderUserId: String?
  let signalingEncrypted: Bool?
  let transportProfile: String?
}

struct CallEndedEvent: Codable, Equatable {
  let callId: String
  let status: String
}

struct MessageDeliveredEvent: Codable, Equatable {
  let messageId: String
  let deliveredTo: String
  let deliveredAt: Date?
}

struct TypingEvent: Codable, Equatable {
  let userId: String
  let conversationId: String
}

struct RTCConfigEvent: Codable, Equatable {
  let iceServers: [RTCIceServer]
  let turnCredentials: TurnCredentials
}

struct NewMessageEvent: Codable, Equatable {
  let id: String
  let conversationId: String
  let senderId: String
  let content: String
  let type: Message.MessageType
  let encryptionMode: Message.EncryptionMode?
  let encryptionKeyNonce: String?
  let createdAt: Date
  let attachment: FileAttachment?
}

struct MessageEditedEvent: Codable, Equatable {
  let messageId: String
  let content: String
  let editedAt: Date?
  let editedBy: String?
}

struct MessageDeletedEvent: Codable, Equatable {
  let messageId: String
  let deletedBy: String?
  let deletedAt: Date?
}

struct MessageReadEvent: Codable, Equatable {
  let messageId: String
  let readAt: Date?
}

struct ReactionAddedEvent: Codable, Equatable {
  let messageId: String
  let userId: String
  let emoji: String
  let createdAt: Date?
}

struct ReactionRemovedEvent: Codable, Equatable {
  let messageId: String
  let userId: String
  let emoji: String?
}

struct MessagePinnedEvent: Codable, Equatable {
  let conversationId: String
  let messageId: String
  let pinnedBy: String
  let pinnedAt: Date?
}

struct MessageUnpinnedEvent: Codable, Equatable {
  let conversationId: String
  let messageId: String
}

struct CallQualityEvent: Codable, Equatable {
  let callId: String
  let userId: String
  let quality: Double
}

struct CallMuteToggledEvent: Codable, Equatable {
  let callId: String
  let userId: String
  let muted: Bool
}

struct CallCameraToggledEvent: Codable, Equatable {
  let callId: String
  let userId: String
  let enabled: Bool
}

struct CallReconnectingEvent: Codable, Equatable {
  let callId: String
  let userId: String
}

struct TrustStateChangedEvent: Codable, Equatable {
  let fromUserId: String
  let peerUserId: String
  let state: TrustState
  let mutualVerified: Bool
}
