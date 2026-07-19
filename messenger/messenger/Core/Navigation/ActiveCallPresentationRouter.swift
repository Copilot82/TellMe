import UIKit

@MainActor
protocol ActiveCallPresenting: AnyObject {
  var activeCallPresentationScene: UIWindowScene? { get }

  func presentAcceptedIncomingCall(_ descriptor: E2EIncomingCallDescriptor)

  func restoreActiveCallInterface(
    callId: String,
    animated: Bool,
    completion: ((Bool) -> Void)?
  )
}

@MainActor
final class ActiveCallPresentationRouter {
  static let shared = ActiveCallPresentationRouter()

  static let activityType: String = "com.example.messenger.activity.active-call"
  static let callIdActivityKey: String = "call_id"

  private final class WeakPresenter {
    weak var presenter: ActiveCallPresenting?

    init(_ presenter: ActiveCallPresenting) {
      self.presenter = presenter
    }
  }

  private var presenters: [WeakPresenter] = []
  private var restoreObserver: NSObjectProtocol?
  private var acceptObserver: NSObjectProtocol?
  private var inFlightRestoreCallIds: Set<String> = []

  private init() {}

  func register(_ presenter: ActiveCallPresenting) {
    cleanupReleasedPresenters()
    guard !presenters.contains(where: { $0.presenter === presenter }) else {
      return
    }

    presenters.append(WeakPresenter(presenter))
    installNotificationObserversIfNeeded()
  }

  func unregister(_ presenter: ActiveCallPresenting) {
    presenters.removeAll { $0.presenter == nil || $0.presenter === presenter }
    if presenters.isEmpty {
      removeNotificationObservers()
    }
  }

  func cleanupReleasedPresenters() {
    presenters.removeAll { $0.presenter == nil }
    if presenters.isEmpty {
      removeNotificationObservers()
    }
  }

  func makeActiveCallActivity(callId: String) -> NSUserActivity {
    let activity = NSUserActivity(activityType: Self.activityType)
    activity.title = "Active call"
    activity.userInfo = [Self.callIdActivityKey: callId]
    activity.isEligibleForHandoff = false
    activity.isEligibleForSearch = false
    return activity
  }

  func handleUserActivity(_ userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == Self.activityType,
      let callId: String = userActivity.userInfo?[Self.callIdActivityKey] as? String,
      !callId.isEmpty
    else {
      return false
    }

    restoreActiveCallInterface(callId: callId, animated: false, completion: nil)
    return true
  }

  func restoreActiveCallInterface(
    callId: String,
    animated: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard !callId.isEmpty else {
      completion?(false)
      return
    }

    guard inFlightRestoreCallIds.insert(callId).inserted else {
      completion?(true)
      return
    }

    let presenter: ActiveCallPresenting? = preferredPresenter()
    guard let presenter else {
      inFlightRestoreCallIds.remove(callId)
      requestSceneActivation(callId: callId, completion: completion)
      return
    }

    presenter.restoreActiveCallInterface(callId: callId, animated: animated) { [weak self] restored in
      self?.inFlightRestoreCallIds.remove(callId)
      completion?(restored)
    }
  }

  func presentAcceptedIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    guard let presenter = preferredPresenter() else {
      requestSceneActivation(callId: descriptor.callId, completion: nil)
      return
    }

    presenter.presentAcceptedIncomingCall(descriptor)
  }

  private func preferredPresenter() -> ActiveCallPresenting? {
    cleanupReleasedPresenters()
    let livePresenters: [ActiveCallPresenting] = presenters.compactMap(\.presenter)

    return livePresenters.first(where: { $0.activeCallPresentationScene?.activationState == .foregroundActive })
      ?? livePresenters.first(where: { $0.activeCallPresentationScene?.activationState == .foregroundInactive })
      // During scene restoration a coordinator can be registered before its
      // navigation view is attached to a window. Allow that unambiguous
      // presenter without ever falling back to a known background scene.
      ?? (livePresenters.count == 1 && livePresenters[0].activeCallPresentationScene == nil
        ? livePresenters[0]
        : nil)
  }

  private func requestSceneActivation(callId: String, completion: ((Bool) -> Void)?) {
    let activity = makeActiveCallActivity(callId: callId)
    UIApplication.shared.requestSceneSessionActivation(
      nil,
      userActivity: activity,
      options: nil
    ) { error in
      _ = error
      completion?(false)
    }
  }

  private func installNotificationObserversIfNeeded() {
    guard restoreObserver == nil, acceptObserver == nil else {
      return
    }

    let notificationCenter = NotificationCenter.default

    restoreObserver = notificationCenter.addObserver(
      forName: .didRequestActiveCallInterfaceRestore,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let callId: String = notification.userInfo?["call_id"] as? String else {
        (notification.userInfo?["completion"] as? (Bool) -> Void)?(false)
        return
      }
      let completion: ((Bool) -> Void)? = notification.userInfo?["completion"] as? (Bool) -> Void

      Task { @MainActor [weak self] in
        self?.restoreActiveCallInterface(callId: callId, animated: true, completion: completion)
      }
    }

    acceptObserver = notificationCenter.addObserver(
      forName: .didAcceptSystemIncomingCall,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let descriptor = notification.userInfo?["descriptor"] as? E2EIncomingCallDescriptor else {
        return
      }

      Task { @MainActor [weak self] in
        self?.presentAcceptedIncomingCall(descriptor)
      }
    }
  }

  private func removeNotificationObservers() {
    let notificationCenter = NotificationCenter.default
    if let restoreObserver {
      notificationCenter.removeObserver(restoreObserver)
    }
    if let acceptObserver {
      notificationCenter.removeObserver(acceptObserver)
    }
    restoreObserver = nil
    acceptObserver = nil
  }
}
