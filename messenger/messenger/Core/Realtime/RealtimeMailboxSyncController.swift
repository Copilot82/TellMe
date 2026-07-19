import Foundation

@MainActor
// Realtime wakeups are coalesced so bursts of socket events produce one mailbox drain at a time.
final class RealtimeMailboxSyncController {
  private typealias SubscribeSync = () async -> Void
  private typealias SynchronizeMailbox = (String) async -> Bool

  private let realtimeRouter: RealtimeEventRouter
  private let subscribeSync: SubscribeSync
  private let synchronizeMailbox: SynchronizeMailbox

  private var eventObserverId: UUID?
  private var stateObserverId: UUID?
  private var syncTask: Task<Void, Never>?
  private var hasPendingSync: Bool = false

  init(
    socketClient: SocketIOClient,
    realtimeRouter: RealtimeEventRouter,
    pushNotificationService: PushNotificationService
  ) {
    self.realtimeRouter = realtimeRouter
    self.subscribeSync = {
      try? await socketClient.subscribeSync()
    }
    self.synchronizeMailbox = { reason in
      await pushNotificationService.synchronizeIncomingMailbox(reason: reason)
    }

    observeRealtime()
  }

#if DEBUG
  init(
    realtimeRouter: RealtimeEventRouter,
    subscribeSync: @escaping () async -> Void,
    synchronizeMailbox: @escaping (String) async -> Bool
  ) {
    self.realtimeRouter = realtimeRouter
    self.subscribeSync = subscribeSync
    self.synchronizeMailbox = synchronizeMailbox

    observeRealtime()
  }
#endif

  deinit {
    let realtimeRouter = realtimeRouter
    let eventObserverId = eventObserverId
    let stateObserverId = stateObserverId
    syncTask?.cancel()
    Task { @MainActor in
      if let eventObserverId {
        realtimeRouter.removeObserver(eventObserverId)
      }
      if let stateObserverId {
        realtimeRouter.removeObserver(stateObserverId)
      }
    }
  }

  private func observeRealtime() {
    eventObserverId = realtimeRouter.observeEvents { [weak self] event in
      guard let self else {
        return
      }

      switch event {
      case .syncBlobAvailable:
        scheduleMailboxSync(reason: "sync_blob_available")
      case .syncBlobs:
        scheduleMailboxSync(reason: "sync_blobs")
      default:
        break
      }
    }

    stateObserverId = realtimeRouter.observeConnectionState { [weak self] state in
      guard let self, state == .connected else {
        return
      }

      Task { @MainActor [weak self] in
        guard let self else {
          return
        }

        await subscribeSync()
        scheduleMailboxSync(reason: "socket_connected")
      }
    }
  }

  private func scheduleMailboxSync(reason: String) {
    guard syncTask == nil else {
      hasPendingSync = true
      return
    }

    syncTask = Task { @MainActor [weak self] in
      await self?.drainMailboxSync(reason: reason)
    }
  }

  private func drainMailboxSync(reason: String) async {
    var currentReason: String = reason
    while !Task.isCancelled {
      hasPendingSync = false
      _ = await synchronizeMailbox(currentReason)
      guard hasPendingSync else {
        break
      }

      currentReason = "coalesced_realtime"
    }

    syncTask = nil
  }
}
