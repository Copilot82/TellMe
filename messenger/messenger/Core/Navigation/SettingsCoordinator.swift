import UIKit

@MainActor
protocol SettingsCoordinatorDelegate: AnyObject {
  func settingsCoordinatorDidRequestLogout(_ coordinator: SettingsCoordinator)
}

@MainActor
final class SettingsCoordinator: Coordinator {
  private let navigationController: UINavigationController
  private let container: AppContainer
  private weak var delegate: SettingsCoordinatorDelegate?

  private let settingsViewModel: SettingsViewModel

  init(navigationController: UINavigationController, container: AppContainer, delegate: SettingsCoordinatorDelegate?) {
    self.navigationController = navigationController
    self.container = container
    self.delegate = delegate
    self.settingsViewModel = SettingsViewModel(container: container, defaults: container.defaults)
  }

  func start() {
    let controller: SettingsViewController = SettingsViewController(viewModel: settingsViewModel)

    controller.onOpenSecurity = { [weak self] in
      self?.openSecurity()
    }

    controller.onOpenNotifications = { [weak self] in
      self?.openNotifications()
    }

    controller.onOpenDiagnostics = { [weak self] in
      self?.openDiagnostics()
    }

    controller.onDidLogout = { [weak self] in
      guard let self else {
        return
      }
      self.delegate?.settingsCoordinatorDidRequestLogout(self)
    }

    navigationController.setViewControllers([controller], animated: false)
  }

  private func openSecurity() {
    let controller: SecurityViewController = SecurityViewController(
      viewModel: settingsViewModel,
      onOpenDeviceLink: { [weak self] in
        self?.openDeviceLink()
      }
    )
    navigationController.pushViewController(controller, animated: true)
  }

  private func openNotifications() {
    let controller: NotificationsSettingsViewController = NotificationsSettingsViewController(viewModel: settingsViewModel)
    navigationController.pushViewController(controller, animated: true)
  }

  private func openDiagnostics() {
    let controller: DiagnosticsViewController = DiagnosticsViewController(viewModel: settingsViewModel)
    navigationController.pushViewController(controller, animated: true)
  }

  private func openDeviceLink() {
    let controller = DeviceLinkHostViewController(viewModel: DeviceLinkViewModel(container: container))
    navigationController.pushViewController(controller, animated: true)
  }
}
