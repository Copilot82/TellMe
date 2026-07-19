import Foundation

@MainActor
// Retained sessions keep active calls alive across controller transitions and Picture in Picture handoffs.
final class E2ECallSessionStore {
  private var sessionsByCallId: [String: E2ECallSessionViewModel] = [:]
  private var finishObserverIdsByCallId: [String: UUID] = [:]
  private var retainedCallIds: [String] = []

  var activeSession: E2ECallSessionViewModel? {
    retainedCallIds.reversed().compactMap { sessionsByCallId[$0] }.first
  }

  func session(callId: String) -> E2ECallSessionViewModel? {
    sessionsByCallId[callId]
  }

  @discardableResult
  func retain(_ session: E2ECallSessionViewModel) -> E2ECallSessionViewModel {
    let callId: String = session.activeCallId
    if let existing: E2ECallSessionViewModel = sessionsByCallId[callId] {
      return existing
    }

    sessionsByCallId[callId] = session
    retainedCallIds.append(callId)
    finishObserverIdsByCallId[callId] = session.addFinishObserver { [weak self, weak session] in
      guard let callId: String = session?.activeCallId else {
        return
      }
      self?.release(callId: callId)
    }

    notifyActiveSessionChanged()
    return session
  }

  func release(callId: String) {
    if let observerId: UUID = finishObserverIdsByCallId[callId],
      let session: E2ECallSessionViewModel = sessionsByCallId[callId]
    {
      session.removeFinishObserver(observerId)
    }

    finishObserverIdsByCallId[callId] = nil
    sessionsByCallId[callId] = nil
    retainedCallIds.removeAll { $0 == callId }
    notifyActiveSessionChanged()
  }

  func removeAll() {
    let sessions: [E2ECallSessionViewModel] = Array(sessionsByCallId.values)
    for session in sessions {
      session.finishForLocalSessionClear()
    }

    finishObserverIdsByCallId.removeAll()
    sessionsByCallId.removeAll()
    retainedCallIds.removeAll()
    notifyActiveSessionChanged()
  }

  private func notifyActiveSessionChanged() {
    NotificationCenter.default.post(name: .didChangeActiveE2ECallSession, object: self)
  }
}

extension Notification.Name {
  static let didChangeActiveE2ECallSession: Notification.Name = Notification.Name(
    "didChangeActiveE2ECallSession"
  )
}
