import Foundation

enum SocketConnectionState: Equatable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

struct SocketEvent: Equatable {
  let name: String
  let payload: Data?

  func decodePayload<T: Decodable>(as type: T.Type) throws -> T {
    guard let payload else {
      throw APIError.decoding("Event payload is empty")
    }

    return try JSONCoding.decoder.decode(type, from: payload)
  }
}

enum SocketEventName {
  static let rtcConfig: String = "rtc_config"

  static let joinConversation: String = "join_conversation"
  static let leaveConversation: String = "leave_conversation"
  static let typingStart: String = "typing_start"
  static let typingStop: String = "typing_stop"
  static let userTyping: String = "user_typing"
  static let userStoppedTyping: String = "user_stopped_typing"

  static let callOffer: String = "call_offer"
  static let callAnswer: String = "call_answer"
  static let callICECandidate: String = "call_ice_candidate"
  static let callMediaState: String = "call_media_state"
  static let callFlushCandidates: String = "call_flush_candidates"
  static let incomingCall: String = "incoming_call"
  static let callAnswered: String = "call_answered"
  static let callEnded: String = "call_ended"
  static let callMissed: String = "call_missed"
  static let callQualityUpdate: String = "call_quality_update"
  static let callMuteToggled: String = "call_mute_toggled"
  static let callCameraToggled: String = "call_camera_toggled"
  static let callReconnecting: String = "call_reconnecting"

  static let messageReceived: String = "message_received"
  static let presenceTouch: String = "presence_touch"
  static let presenceOffline: String = "presence_offline"
  static let syncSubscribe: String = "sync_subscribe"
  static let syncPull: String = "sync_pull"
  static let syncBlobs: String = "sync_blobs"
  static let syncBlobAvailable: String = "sync_blob_available"
  static let newMessage: String = "new_message"
  static let messageEdited: String = "message_edited"
  static let messageDeleted: String = "message_deleted"
  static let messageDeletedForMe: String = "message_deleted_for_me"
  static let messageRead: String = "message_read"
  static let messageDelivered: String = "message_delivered"
  static let reactionAdded: String = "reaction_added"
  static let reactionRemoved: String = "reaction_removed"
  static let messagePinned: String = "message_pinned"
  static let messageUnpinned: String = "message_unpinned"

  static let trustStateChanged: String = "trust_state_changed"
}

enum LegacyRawCallSocketPolicy {
  private static let legacyEventNames: Set<String> = [
    SocketEventName.callOffer,
    SocketEventName.callAnswer,
    SocketEventName.callICECandidate,
    SocketEventName.callMediaState,
    SocketEventName.callFlushCandidates,
    SocketEventName.incomingCall,
    SocketEventName.callAnswered,
    SocketEventName.callEnded,
    SocketEventName.callMissed,
    SocketEventName.callQualityUpdate,
    SocketEventName.callMuteToggled,
    SocketEventName.callCameraToggled,
    SocketEventName.callReconnecting,
  ]

  static func isLegacyRawCallEvent(_ eventName: String) -> Bool {
    legacyEventNames.contains(eventName)
  }

  static func allowsRawCallEvents(configuration: AppLaunchConfiguration) -> Bool {
    configuration.shouldUseStubNetwork
  }
}
