import UIKit

@MainActor
protocol MainTabCoordinatorDelegate: AnyObject {
  func mainTabCoordinatorDidRequestLogout(_ coordinator: MainTabCoordinator)
}

@MainActor
final class MainTabCoordinator: NSObject, Coordinator {
  private let container: AppContainer
  private weak var delegate: MainTabCoordinatorDelegate?

  private let tabBarController: UITabBarController = UITabBarController()

  private var chatsCoordinator: ChatsCoordinator?
  private var settingsCoordinator: SettingsCoordinator?

  init(container: AppContainer, delegate: MainTabCoordinatorDelegate?) {
    self.container = container
    self.delegate = delegate
    super.init()
  }

  var rootViewController: UIViewController {
    tabBarController
  }

  func start() {
    let chatsNavigation: UINavigationController = UINavigationController()
    let settingsNavigation: UINavigationController = UINavigationController()
    chatsNavigation.delegate = self
    settingsNavigation.delegate = self

    chatsNavigation.tabBarItem = UITabBarItem(title: "Чаты", image: UIImage(systemName: "bubble.left.and.bubble.right.fill"), tag: 1)
    settingsNavigation.tabBarItem = UITabBarItem(title: "Настройки", image: UIImage(systemName: "gearshape.fill"), tag: 0)
    chatsNavigation.tabBarItem.accessibilityIdentifier = MessengerAccessibility.Button.tabChats
    settingsNavigation.tabBarItem.accessibilityIdentifier = MessengerAccessibility.Button.tabSettings

    let chatsCoordinator: ChatsCoordinator = ChatsCoordinator(
      navigationController: chatsNavigation,
      container: container
    )
    chatsCoordinator.onCallPresentationRequested = { [weak self] in
      self?.tabBarController.selectedIndex = 0
    }

    let settingsCoordinator: SettingsCoordinator = SettingsCoordinator(
      navigationController: settingsNavigation,
      container: container,
      delegate: self
    )

    self.chatsCoordinator = chatsCoordinator
    self.settingsCoordinator = settingsCoordinator

    chatsCoordinator.start()
    settingsCoordinator.start()

    tabBarController.viewControllers = [chatsNavigation, settingsNavigation]
    tabBarController.selectedIndex = 0
  }

  func presentAcceptedIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    tabBarController.selectedIndex = 0
    chatsCoordinator?.openIncomingSystemCall(descriptor)
  }

  func restoreActiveCallInterface(
    callId: String,
    animated: Bool = true,
    completion: ((Bool) -> Void)?
  ) {
    tabBarController.selectedIndex = 0
    chatsCoordinator?.restoreActiveCallInterface(
      callId: callId,
      animated: animated,
      completion: completion
    )
  }
}

extension MainTabCoordinator: SettingsCoordinatorDelegate {
  func settingsCoordinatorDidRequestLogout(_ coordinator: SettingsCoordinator) {
    delegate?.mainTabCoordinatorDidRequestLogout(self)
  }
}

extension MainTabCoordinator: UINavigationControllerDelegate {
  func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    _ = navigationController
    _ = viewController
    _ = animated
  }
}
