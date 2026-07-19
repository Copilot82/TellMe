import UIKit

// Scene setup owns UI bootstrapping only; protocol state is assembled later inside AppContainer.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var appCoordinator: AppCoordinator?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    _ = session

    guard let windowScene: UIWindowScene = scene as? UIWindowScene else {
      return
    }

    recordSceneLifecycle("scene_will_connect", scene: windowScene)

    let launchConfiguration: AppLaunchConfiguration = .current
    let container: AppContainer = AppRuntime.sharedContainer(launchConfiguration: launchConfiguration)
    let coordinator: AppCoordinator = AppCoordinator(windowScene: windowScene, container: container)
    appCoordinator = coordinator
    window = coordinator.appWindow
    coordinator.start(userActivity: connectionOptions.userActivities.first)
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let windowScene = scene as? UIWindowScene {
      recordSceneLifecycle(
        "scene_continue_user_activity",
        scene: windowScene,
        detail: "activityType=\(userActivity.activityType)"
      )
    }
    _ = appCoordinator?.continueUserActivity(userActivity)
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene {
      recordSceneLifecycle("scene_did_enter_background", scene: windowScene)
    }
    appCoordinator?.handleSceneDidEnterBackground()
  }

  func sceneWillResignActive(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene {
      recordSceneLifecycle("scene_will_resign_active", scene: windowScene)
    }
    appCoordinator?.handleSceneWillResignActive()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene {
      recordSceneLifecycle("scene_will_enter_foreground", scene: windowScene)
    }
    appCoordinator?.handleSceneWillEnterForeground()
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    if let windowScene = scene as? UIWindowScene {
      recordSceneLifecycle("scene_did_become_active", scene: windowScene)
    }
    appCoordinator?.handleSceneDidBecomeActive()
  }

  private func recordSceneLifecycle(_ name: String, scene: UIWindowScene, detail: String? = nil) {
    let activeCallId: String = AppRuntime.sharedContainer().e2eCallSessionStore.activeSession?.activeCallId ?? "none"
    let baseDetail: String = [
      "activation=\(String(describing: scene.activationState))",
      "windows=\(scene.windows.count)",
      "key=\(scene.windows.contains(where: \.isKeyWindow))",
      "visible=\(scene.windows.filter { !$0.isHidden && $0.alpha > 0 }.count)",
      "windowDetails=\(windowDiagnosticsSummary(scene.windows))",
    ].joined(separator: ",")
    let resolvedDetail: String = [baseDetail, detail].compactMap { $0 }.joined(separator: ",")
    PiPDiagnosticRecorder.shared.record(
      category: "app_lifecycle",
      name: name,
      callId: activeCallId,
      detail: resolvedDetail
    )
  }

  private func windowDiagnosticsSummary(_ windows: [UIWindow]) -> String {
    guard !windows.isEmpty else {
      return "none"
    }

    return windows.prefix(4).enumerated().map { index, window in
      [
        "\(index):\(String(describing: type(of: window)))",
        "key:\(window.isKeyWindow)",
        "hidden:\(window.isHidden)",
        "alpha:\(String(format: "%.2f", window.alpha))",
        "level:\(String(format: "%.1f", window.windowLevel.rawValue))",
        "root:\(window.rootViewController.map { String(describing: type(of: $0)) } ?? "nil")",
        "bounds:\(Int(window.bounds.width))x\(Int(window.bounds.height))",
      ].joined(separator: ";")
    }.joined(separator: "~")
  }
}
