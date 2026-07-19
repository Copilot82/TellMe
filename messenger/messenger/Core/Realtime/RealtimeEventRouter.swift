import Foundation

@MainActor
enum RealtimeEvent {
  case rtcConfig(RTCConfigEvent)
  case incomingCall(IncomingCallEvent)
  case callAnswered(CallAnsweredEvent)
  case callICECandidate(CallICECandidateEvent)
  case callEnded(CallEndedEvent)
  case callQuality(CallQualityEvent)
  case callMute(CallMuteToggledEvent)
  case callCamera(CallCameraToggledEvent)
  case callReconnecting(CallReconnectingEvent)

  case newMessage(NewMessageEvent)
  case messageEdited(MessageEditedEvent)
  case messageDeleted(MessageDeletedEvent)
  case messageDeletedForMe(MessageDeletedEvent)
  case messageRead(MessageReadEvent)
  case messageDelivered(MessageDeliveredEvent)
  case syncBlobs(FederatedSyncResponse)
  case syncBlobAvailable(SyncBlobAvailableEvent)
  case reactionAdded(ReactionAddedEvent)
  case reactionRemoved(ReactionRemovedEvent)
  case messagePinned(MessagePinnedEvent)
  case messageUnpinned(MessageUnpinnedEvent)
  case userTyping(TypingEvent)
  case userStoppedTyping(TypingEvent)
  case trustStateChanged(TrustStateChangedEvent)

  case raw(name: String)
}

@MainActor
final class RealtimeEventRouter {
  typealias EventObserver = (RealtimeEvent) -> Void
  typealias StateObserver = (SocketConnectionState) -> Void

  private let socketClient: SocketIOClient
  private let allowsLegacyRawCallEvents: Bool

  private(set) var connectionState: SocketConnectionState = .disconnected

  private var eventObservers: [UUID: EventObserver] = [:]
  private var stateObservers: [UUID: StateObserver] = [:]

  init(socketClient: SocketIOClient, allowsLegacyRawCallEvents: Bool = false) {
    self.socketClient = socketClient
    self.allowsLegacyRawCallEvents = allowsLegacyRawCallEvents

    Task {
      await socketClient.setOnEvent { [weak self] event in
        Task { @MainActor in
          self?.route(event: event)
        }
      }

      await socketClient.setOnStateChange { [weak self] state in
        Task { @MainActor in
          guard let self else {
            return
          }

          self.connectionState = state
          for observer in self.stateObservers.values {
            observer(state)
          }
        }
      }
    }
  }

  @discardableResult
  func observeEvents(_ observer: @escaping EventObserver) -> UUID {
    let id: UUID = UUID()
    eventObservers[id] = observer
    return id
  }

  @discardableResult
  func observeConnectionState(_ observer: @escaping StateObserver) -> UUID {
    let id: UUID = UUID()
    stateObservers[id] = observer
    observer(connectionState)
    return id
  }

  func removeObserver(_ observerId: UUID) {
    eventObservers[observerId] = nil
    stateObservers[observerId] = nil
  }

  func connect(token: String) async {
    await socketClient.connect(token: token)
  }

  func disconnect() async {
    await socketClient.disconnect()
  }

#if DEBUG
  func routeForTesting(event: SocketEvent) {
    route(event: event)
  }

  func updateConnectionStateForTesting(_ state: SocketConnectionState) {
    connectionState = state
    for observer in stateObservers.values {
      observer(state)
    }
  }
#endif

  private func emit(_ event: RealtimeEvent) {
    for observer in eventObservers.values {
      observer(event)
    }
  }

  private func route(event: SocketEvent) {
    if LegacyRawCallSocketPolicy.isLegacyRawCallEvent(event.name), !allowsLegacyRawCallEvents {
      return
    }

    if event.name == SocketEventName.rtcConfig,
      let payload: RTCConfigEvent = decode(event)
    {
      emit(.rtcConfig(payload))
      return
    }

    if event.name == SocketEventName.incomingCall,
      let payload: IncomingCallEvent = decode(event)
    {
      emit(.incomingCall(payload))
      return
    }

    if event.name == SocketEventName.callAnswered,
      let payload: CallAnsweredEvent = decode(event)
    {
      emit(.callAnswered(payload))
      return
    }

    if event.name == SocketEventName.callICECandidate,
      let payload: CallICECandidateEvent = decode(event)
    {
      emit(.callICECandidate(payload))
      return
    }

    if event.name == SocketEventName.callEnded,
      let payload: CallEndedEvent = decode(event)
    {
      emit(.callEnded(payload))
      return
    }

    if event.name == SocketEventName.callQualityUpdate,
      let payload: CallQualityEvent = decode(event)
    {
      emit(.callQuality(payload))
      return
    }

    if event.name == SocketEventName.callMuteToggled,
      let payload: CallMuteToggledEvent = decode(event)
    {
      emit(.callMute(payload))
      return
    }

    if event.name == SocketEventName.callCameraToggled,
      let payload: CallCameraToggledEvent = decode(event)
    {
      emit(.callCamera(payload))
      return
    }

    if event.name == SocketEventName.callReconnecting,
      let payload: CallReconnectingEvent = decode(event)
    {
      emit(.callReconnecting(payload))
      return
    }

    if event.name == SocketEventName.newMessage,
      let payload: NewMessageEvent = decode(event)
    {
      emit(.newMessage(payload))
      return
    }

    if event.name == SocketEventName.messageEdited,
      let payload: MessageEditedEvent = decode(event)
    {
      emit(.messageEdited(payload))
      return
    }

    if event.name == SocketEventName.messageDeleted,
      let payload: MessageDeletedEvent = decode(event)
    {
      emit(.messageDeleted(payload))
      return
    }

    if event.name == SocketEventName.messageDeletedForMe,
      let payload: MessageDeletedEvent = decode(event)
    {
      emit(.messageDeletedForMe(payload))
      return
    }

    if event.name == SocketEventName.messageRead,
      let payload: MessageReadEvent = decode(event)
    {
      emit(.messageRead(payload))
      return
    }

    if event.name == SocketEventName.messageDelivered,
      let payload: MessageDeliveredEvent = decode(event)
    {
      emit(.messageDelivered(payload))
      return
    }

    if event.name == SocketEventName.syncBlobs,
      let payload: FederatedSyncResponse = decode(event)
    {
      emit(.syncBlobs(payload))
      return
    }

    if event.name == SocketEventName.syncBlobAvailable,
      let payload: SyncBlobAvailableEvent = decode(event)
    {
      emit(.syncBlobAvailable(payload))
      return
    }

    if event.name == SocketEventName.reactionAdded,
      let payload: ReactionAddedEvent = decode(event)
    {
      emit(.reactionAdded(payload))
      return
    }

    if event.name == SocketEventName.reactionRemoved,
      let payload: ReactionRemovedEvent = decode(event)
    {
      emit(.reactionRemoved(payload))
      return
    }

    if event.name == SocketEventName.messagePinned,
      let payload: MessagePinnedEvent = decode(event)
    {
      emit(.messagePinned(payload))
      return
    }

    if event.name == SocketEventName.messageUnpinned,
      let payload: MessageUnpinnedEvent = decode(event)
    {
      emit(.messageUnpinned(payload))
      return
    }

    if event.name == SocketEventName.userTyping,
      let payload: TypingEvent = decode(event)
    {
      emit(.userTyping(payload))
      return
    }

    if event.name == SocketEventName.userStoppedTyping,
      let payload: TypingEvent = decode(event)
    {
      emit(.userStoppedTyping(payload))
      return
    }

    if event.name == SocketEventName.trustStateChanged,
      let payload: TrustStateChangedEvent = decode(event)
    {
      emit(.trustStateChanged(payload))
      return
    }

    emit(.raw(name: event.name))
  }

  private func decode<T: Decodable>(_ event: SocketEvent) -> T? {
    guard let payload: Data = event.payload else {
      return nil
    }

    return try? JSONCoding.decoder.decode(T.self, from: payload)
  }
}
