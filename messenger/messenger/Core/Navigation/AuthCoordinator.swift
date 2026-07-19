import UIKit

@MainActor
protocol AuthCoordinatorDelegate: AnyObject {
  func authCoordinatorDidAuthenticate(_ coordinator: AuthCoordinator)
}

@MainActor
final class AuthCoordinator: Coordinator {
  private let navigationController: UINavigationController
  private let container: AppContainer
  private let viewModel: AuthViewModel
  private weak var delegate: AuthCoordinatorDelegate?

  private var pendingUser: User?

  init(navigationController: UINavigationController, container: AppContainer, delegate: AuthCoordinatorDelegate?) {
    self.navigationController = navigationController
    self.container = container
    self.viewModel = AuthViewModel(container: container)
    self.delegate = delegate
  }

  func start() {
    let viewController: AuthViewController = AuthViewController(
      viewModel: viewModel,
      onOpenDeviceLink: { [weak self] in
        self?.openDeviceLink()
      }
    )
    viewController.delegate = self

    navigationController.setViewControllers([viewController], animated: false)
  }

  private func showImportKeyScreen(for user: User) {
    let importController: ImportPrivateKeyViewController = ImportPrivateKeyViewController(
      viewModel: viewModel,
      userId: user.id
    )
    importController.delegate = self

    navigationController.setViewControllers([importController], animated: true)
  }

  private func openDeviceLink() {
    let controller = DeviceLinkJoinViewController(
      viewModel: DeviceLinkViewModel(container: container)
    ) { [weak self] _ in
      guard let self else {
        return
      }
      self.delegate?.authCoordinatorDidAuthenticate(self)
    }
    navigationController.pushViewController(controller, animated: true)
  }
}

extension AuthCoordinator: AuthViewControllerDelegate {
  func authViewController(_ viewController: AuthViewController, didAuthenticate result: AuthViewModel.AuthResult) {
    pendingUser = result.user

    if result.requiresPrivateKeyImport {
      showImportKeyScreen(for: result.user)
      return
    }

    delegate?.authCoordinatorDidAuthenticate(self)
  }
}

extension AuthCoordinator: ImportPrivateKeyViewControllerDelegate {
  func importPrivateKeyViewControllerDidFinish(_ viewController: ImportPrivateKeyViewController) {
    pendingUser = nil
    delegate?.authCoordinatorDidAuthenticate(self)
  }
}
