import Foundation
import UIKit

struct AppBackgroundRealtimePolicy {
  static func shouldSuspendRealtime(
    isAutomationModeEnabled: Bool,
    shouldDisableRealtime: Bool,
    accessToken: String?,
    hasActiveE2ECallSession: Bool,
    hasForegroundScene: Bool = false
  ) -> Bool {
    !isAutomationModeEnabled
      && !shouldDisableRealtime
      && accessToken?.isEmpty == false
      && !hasActiveE2ECallSession
      && !hasForegroundScene
  }
}

@MainActor
private enum AppForegroundSceneTracker {
  private static var activeSceneIds: Set<ObjectIdentifier> = []

  static func markActive(_ scene: UIWindowScene) {
    activeSceneIds.insert(ObjectIdentifier(scene))
  }

  static func markInactive(_ scene: UIWindowScene) {
    activeSceneIds.remove(ObjectIdentifier(scene))
  }

  static var hasForegroundScene: Bool {
    !activeSceneIds.isEmpty
  }
}

@MainActor
protocol AppCoordinatorDelegate: AnyObject {
  func appCoordinatorDidRequestLogout(_ coordinator: AppCoordinator)
}

@MainActor
// Coordinators keep UIKit navigation state separate from protocol view models.
final class AppCoordinator: Coordinator {
  private let window: UIWindow
  private let windowScene: UIWindowScene
  private let container: AppContainer
  private let onboardingStateStore: OnboardingStateStore

  private var authCoordinator: AuthCoordinator?
  private var mainTabCoordinator: MainTabCoordinator?
  private var realtimeSuspendedForBackground: Bool = false
  private var backgroundDisconnectTaskId: UIBackgroundTaskIdentifier = .invalid
  private var disconnectTask: Task<Void, Never>?
  private var pendingReconnectToken: String?

  init(windowScene: UIWindowScene, container: AppContainer) {
    self.windowScene = windowScene
    self.window = UIWindow(windowScene: windowScene)
    self.container = container
    self.onboardingStateStore = OnboardingStateStore(defaults: container.defaults)
  }

  deinit {
    let scene: UIWindowScene = windowScene
    Task { @MainActor in
      AppForegroundSceneTracker.markInactive(scene)
      ActiveCallPresentationRouter.shared.cleanupReleasedPresenters()
    }
  }

  var appWindow: UIWindow {
    window
  }

  func start() {
    start(userActivity: nil)
  }

  func start(userActivity: NSUserActivity?) {
    TelegramStyle.applyGlobalAppearance()
    window.overrideUserInterfaceStyle = .dark
    window.makeKeyAndVisible()

    if isAutomationModeEnabled {
      showAutomationFlow()
      return
    }

    if container.launchConfiguration.shouldBootstrapSampleData {
      showMainFlow()
      if let userActivity {
        _ = ActiveCallPresentationRouter.shared.handleUserActivity(userActivity)
      }
      return
    }

    let hasToken: Bool = container.tokenStore.accessToken?.isEmpty == false
    let hasUser: Bool = container.sessionStore.currentUser != nil
    let hasAccountKeyMaterial: Bool = {
      let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
        explicitUserId: container.sessionStore.currentUser?.id,
        sessionUser: container.sessionStore.currentUser
      )
      return container.keyMaterialStore.hasAnyAccountKeyMaterial(lookupIds: lookupIds)
    }()

    if hasToken && hasUser && hasAccountKeyMaterial {
      onboardingStateStore.markInitialAuthCompleted()
      showMainFlow()
      if let userActivity {
        _ = ActiveCallPresentationRouter.shared.handleUserActivity(userActivity)
      }
    } else if onboardingStateStore.hasCompletedInitialAuth {
      showAuthFlow()
    } else {
      showOnboardingFlow()
    }
  }

  func continueUserActivity(_ userActivity: NSUserActivity) -> Bool {
    ActiveCallPresentationRouter.shared.handleUserActivity(userActivity)
  }

  private var isAutomationModeEnabled: Bool {
    let rawValue: String = ProcessInfo.processInfo.environment["E2E_AUTORUN"]?.lowercased() ?? ""
    return rawValue == "1" || rawValue == "true" || rawValue == "yes"
  }

  private var isPictureInPictureValidationModeEnabled: Bool {
    let rawValue: String = ProcessInfo.processInfo.environment["E2E_VALIDATE_CALL_PIP_BACKGROUND"]?.lowercased() ?? ""
    return rawValue == "1" || rawValue == "true" || rawValue == "yes"
  }

  private func showAutomationFlow() {
    let automationController: ViewController = ViewController(container: container)
    let navigationController: UINavigationController = UINavigationController(rootViewController: automationController)

    window.rootViewController = navigationController
    authCoordinator = nil
    mainTabCoordinator = nil
    ActiveCallPresentationRouter.shared.register(self)
  }

  private func prepareUnauthenticatedRoot() {
    ActiveCallPresentationRouter.shared.unregister(self)
    pendingReconnectToken = nil
    endBackgroundDisconnectTaskIfNeeded()
    Task {
      await container.realtimeRouter.disconnect()
    }
    realtimeSuspendedForBackground = false
  }

  private func showOnboardingFlow() {
    prepareUnauthenticatedRoot()

    let controller: OnboardingViewController = OnboardingViewController { [weak self] in
      self?.showAuthFlow()
    }

    authCoordinator = nil
    mainTabCoordinator = nil
    window.rootViewController = controller
  }

  private func showAuthFlow() {
    prepareUnauthenticatedRoot()

    let navigationController: UINavigationController = UINavigationController()
    let coordinator: AuthCoordinator = AuthCoordinator(
      navigationController: navigationController,
      container: container,
      delegate: self
    )

    authCoordinator = coordinator
    mainTabCoordinator = nil

    coordinator.start()
    window.rootViewController = navigationController
  }

  private func showMainFlow() {
    if container.launchConfiguration.startRoute == .activeCall, container.launchConfiguration.shouldUseStubNetwork {
      showUITestActiveCallFlow()
      return
    }

    let coordinator: MainTabCoordinator = MainTabCoordinator(container: container, delegate: self)
    coordinator.start()

    authCoordinator = nil
    mainTabCoordinator = coordinator

    window.rootViewController = coordinator.rootViewController
    ActiveCallPresentationRouter.shared.register(self)

    container.systemCallCoordinator.refreshPushKitRegistrationIfVoIPTokenMissing()
    if !container.launchConfiguration.shouldDisableRealtime,
      let token: String = container.tokenStore.accessToken
    {
      Task {
        await container.realtimeRouter.connect(token: token)
      }
    }
    pendingReconnectToken = nil
    endBackgroundDisconnectTaskIfNeeded()
    realtimeSuspendedForBackground = false

    Task {
      await container.pushNotificationService.warmAuthenticatedPushRegistration(timeout: 8)
      _ = await container.pushNotificationService.synchronizeIncomingMailbox(reason: "main_flow_start")
    }
  }

  func handleSceneDidEnterBackground() {
    AppForegroundSceneTracker.markInactive(windowScene)
    suspendRealtimeForBackground()
  }

  func handleSceneWillResignActive() {
    AppForegroundSceneTracker.markInactive(windowScene)
    suspendRealtimeForBackground()
  }

  func handleSceneWillEnterForeground() {
    AppForegroundSceneTracker.markActive(windowScene)
    resumeRealtimeAfterBackground()
  }

  func handleSceneDidBecomeActive() {
    AppForegroundSceneTracker.markActive(windowScene)
    resumeRealtimeAfterBackground()
    container.systemCallCoordinator.refreshPushKitRegistrationIfVoIPTokenMissing()
    syncDeviceTokensAfterForeground()
    syncIncomingMailboxAfterForeground()
    restoreActiveCallAfterForegroundIfNeeded()
  }

  private func shouldManageRealtimeLifecycle() -> Bool {
    AppBackgroundRealtimePolicy.shouldSuspendRealtime(
      isAutomationModeEnabled: isAutomationModeEnabled,
      shouldDisableRealtime: container.launchConfiguration.shouldDisableRealtime,
      accessToken: container.tokenStore.accessToken,
      hasActiveE2ECallSession: container.e2eCallSessionStore.activeSession != nil,
      hasForegroundScene: AppForegroundSceneTracker.hasForegroundScene
    )
  }

  private func syncDeviceTokensAfterForeground() {
    Task {
      await container.pushNotificationService.warmAuthenticatedPushRegistration(timeout: 4)
    }
  }

  private func syncIncomingMailboxAfterForeground() {
    Task {
      _ = await container.pushNotificationService.synchronizeIncomingMailbox(reason: "scene_foreground")
    }
  }

  private func restoreActiveCallAfterForegroundIfNeeded() {
    guard (!isAutomationModeEnabled || isPictureInPictureValidationModeEnabled),
      let activeSession: E2ECallSessionViewModel = container.e2eCallSessionStore.activeSession
    else {
      return
    }

    ActiveCallPresentationRouter.shared.restoreActiveCallInterface(
      callId: activeSession.activeCallId,
      animated: false,
      completion: nil
    )
  }

  private func suspendRealtimeForBackground() {
    container.pushNotificationService.setVisibleConversationPeerUserId(nil)

    guard shouldManageRealtimeLifecycle() else {
      return
    }

    realtimeSuspendedForBackground = true
    pendingReconnectToken = nil

    guard disconnectTask == nil else {
      return
    }

    beginBackgroundDisconnectTaskIfNeeded()
    disconnectTask = Task { [weak self] in
      guard let self else {
        return
      }

      await self.container.realtimeRouter.disconnect()

      await MainActor.run {
        self.disconnectTask = nil
        self.endBackgroundDisconnectTaskIfNeeded()

        guard !self.realtimeSuspendedForBackground,
          let token: String = self.pendingReconnectToken,
          !token.isEmpty
        else {
          self.pendingReconnectToken = nil
          return
        }

        self.pendingReconnectToken = nil
        Task {
          await self.container.realtimeRouter.connect(token: token)
        }
      }
    }
  }

  private func resumeRealtimeAfterBackground() {
    guard !isAutomationModeEnabled,
      realtimeSuspendedForBackground,
      !container.launchConfiguration.shouldDisableRealtime,
      let token: String = container.tokenStore.accessToken,
      !token.isEmpty
    else {
      endBackgroundDisconnectTaskIfNeeded()
      return
    }

    realtimeSuspendedForBackground = false
    if disconnectTask != nil {
      pendingReconnectToken = token
      return
    }

    pendingReconnectToken = nil
    endBackgroundDisconnectTaskIfNeeded()
    Task {
      await container.realtimeRouter.connect(token: token)
    }
  }

  private func beginBackgroundDisconnectTaskIfNeeded() {
    guard backgroundDisconnectTaskId == .invalid else {
      return
    }

    backgroundDisconnectTaskId = UIApplication.shared.beginBackgroundTask(
      withName: "realtime.disconnect"
    ) { [weak self] in
      Task { @MainActor in
        self?.endBackgroundDisconnectTaskIfNeeded()
      }
    }
  }

  private func endBackgroundDisconnectTaskIfNeeded() {
    guard backgroundDisconnectTaskId != .invalid else {
      return
    }

    UIApplication.shared.endBackgroundTask(backgroundDisconnectTaskId)
    backgroundDisconnectTaskId = .invalid
  }

  private func showUITestActiveCallFlow() {
    let navigationController: UINavigationController = UINavigationController()
    let now = Date()
    let conversation = Conversation(
      id: container.launchConfiguration.sampleConversationId,
      type: .direct,
      name: container.launchConfiguration.samplePeerHandle,
      createdAt: now,
      updatedAt: now,
      participants: [
        ConversationParticipant(
          id: "ui-test-call-local",
          conversationId: container.launchConfiguration.sampleConversationId,
          userId: container.launchConfiguration.sampleUserHandle,
          joinedAt: now,
          role: .member
        ),
        ConversationParticipant(
          id: "ui-test-call-peer",
          conversationId: container.launchConfiguration.sampleConversationId,
          userId: container.launchConfiguration.samplePeerHandle,
          joinedAt: now,
          role: .member
        ),
      ]
    )
    let conversationViewModel = ConversationViewModel(
      container: container,
      conversation: conversation,
      defaults: container.defaults
    )
    let callViewModel = E2ECallSessionViewModel(
      conversationViewModel: conversationViewModel,
      role: .initiator,
      callId: container.launchConfiguration.sampleCallId,
      peerUserId: container.launchConfiguration.samplePeerHandle,
      callType: .video
    )
#if DEBUG
    callViewModel.pictureInPictureAvailabilityOverrideForTesting = true
#endif
    let controller = E2ECallViewController(
      viewModel: container.e2eCallSessionStore.retain(callViewModel),
      shouldAutoStart: false
    )
    navigationController.setViewControllers([controller], animated: false)

    authCoordinator = nil
    mainTabCoordinator = nil
    window.rootViewController = navigationController
    ActiveCallPresentationRouter.shared.register(self)
  }
}

extension AppCoordinator: AuthCoordinatorDelegate {
  func authCoordinatorDidAuthenticate(_ coordinator: AuthCoordinator) {
    onboardingStateStore.markInitialAuthCompleted()
    showMainFlow()
  }
}

extension AppCoordinator: MainTabCoordinatorDelegate {
  func mainTabCoordinatorDidRequestLogout(_ coordinator: MainTabCoordinator) {
    showAuthFlow()
  }
}

extension AppCoordinator: ActiveCallPresenting {
  var activeCallPresentationScene: UIWindowScene? {
    windowScene
  }

  func presentAcceptedIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    guard !isAutomationModeEnabled else {
      return
    }

    if mainTabCoordinator == nil {
      showMainFlow()
    }

    mainTabCoordinator?.presentAcceptedIncomingCall(descriptor)
  }

  func restoreActiveCallInterface(
    callId: String,
    animated: Bool,
    completion: ((Bool) -> Void)?
  ) {
    if restoreActiveCallInRootNavigationController(
      callId: callId,
      animated: animated,
      completion: completion
    ) {
      return
    }

    if mainTabCoordinator == nil {
      showMainFlow()
    }

    mainTabCoordinator?.restoreActiveCallInterface(
      callId: callId,
      animated: animated,
      completion: completion
    )
  }

  private func restoreActiveCallInRootNavigationController(
    callId: String,
    animated: Bool,
    completion: ((Bool) -> Void)?
  ) -> Bool {
    guard mainTabCoordinator == nil,
      let session: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: callId),
      let navigationController: UINavigationController = window.rootViewController as? UINavigationController
    else {
      return false
    }

    if let existing: E2ECallViewController = navigationController.viewControllers
      .compactMap({ $0 as? E2ECallViewController })
      .first(where: { $0.activeCallId == callId })
    {
      navigationController.popToViewController(existing, animated: animated)
      completion?(true)
      return true
    }

    let controller = E2ECallViewController(
      viewModel: session,
      shouldAutoStart: false
    )
    controller.hidesBottomBarWhenPushed = true

    if animated {
      CATransaction.begin()
      CATransaction.setCompletionBlock {
        completion?(true)
      }
      navigationController.pushViewController(controller, animated: true)
      CATransaction.commit()
    } else {
      navigationController.pushViewController(controller, animated: false)
      completion?(true)
    }
    return true
  }
}
