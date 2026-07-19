import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    PiPDiagnosticRecorder.shared.record(
      category: "app_lifecycle",
      name: "application_did_finish_launching",
      callId: "none",
      detail: "hasLaunchOptions=\(launchOptions?.isEmpty == false),autorun=\(ProcessInfo.processInfo.environment["E2E_AUTORUN"] ?? "0")"
    )
    let launchConfiguration: AppLaunchConfiguration = .current
    UNUserNotificationCenter.current().delegate = self

    MainActor.assumeIsolated {
      let container = AppRuntime.sharedContainer(launchConfiguration: launchConfiguration)
      container.systemCallCoordinator.startPushKitIfAvailable()
    }
    if launchConfiguration.shouldRequestNotificationAuthorization {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        if let error {
          print("Notification permission error: \(error.localizedDescription)")
        }

        if granted {
          DispatchQueue.main.async {
            application.registerForRemoteNotifications()
          }
        }
      }
    }

    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
  }

  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    PiPDiagnosticRecorder.shared.record(
      category: "app_lifecycle",
      name: "application_did_discard_scene_sessions",
      callId: "none",
      detail: "count=\(sceneSessions.count)"
    )
  }

  func applicationWillTerminate(_ application: UIApplication) {
    _ = application
    PiPDiagnosticRecorder.shared.record(
      category: "app_lifecycle",
      name: "application_will_terminate",
      callId: "none"
    )
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { @MainActor in
      let container = AppRuntime.sharedContainer()
      await container.pushNotificationService.handleAPNSToken(deviceToken)
    }

    NotificationCenter.default.post(
      name: .didReceiveAPNSToken,
      object: nil,
      userInfo: ["token": deviceToken]
    )
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NotificationCenter.default.post(
      name: .didFailToRegisterAPNSToken,
      object: nil,
      userInfo: ["error": error]
    )
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    _ = application
    Task { @MainActor in
      let container = AppRuntime.sharedContainer()
      let processed: Bool = await container.pushNotificationService.handleRemoteNotification(userInfo)
      completionHandler(processed ? .newData : .noData)
    }
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    _ = center
    let userInfo = notification.request.content.userInfo
    let container = AppRuntime.sharedContainer()

    if notification.request.identifier.hasPrefix("sync.") {
      completionHandler(Self.presentationOptions(for: userInfo))
      return
    }

    let options = container.pushNotificationService.shouldPresentForegroundNotification(userInfo)
      ? Self.presentationOptions(for: userInfo)
      : []

    completionHandler(options)

    Task { @MainActor in
      _ = await container.pushNotificationService.handleRemoteNotification(userInfo)
    }
  }

  static func presentationOptions(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
    let rawHint: String = (userInfo["hint"] as? String ?? userInfo["push_kind"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedHint: String = rawHint == "call_missed" ? PushNotificationHint.missedCall.rawValue : rawHint
    let hint: PushNotificationHint = PushNotificationHint(rawValue: normalizedHint) ?? .message

    switch hint {
    case .message, .missedCall:
      return [.banner, .list, .sound, .badge]
    case .none:
      return []
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    _ = center
    Task { @MainActor in
      let container = AppRuntime.sharedContainer()
      _ = await container.pushNotificationService.handleRemoteNotification(response.notification.request.content.userInfo)
      completionHandler()
    }
  }
}

extension Notification.Name {
  static let didReceiveAPNSToken: Notification.Name = Notification.Name("didReceiveAPNSToken")
  static let didFailToRegisterAPNSToken: Notification.Name = Notification.Name("didFailToRegisterAPNSToken")
  static let didProcessRemoteNotificationSync: Notification.Name = Notification.Name("didProcessRemoteNotificationSync")
}
