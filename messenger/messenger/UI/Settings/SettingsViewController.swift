import UIKit

@MainActor
final class SettingsViewController: UIViewController {
  var onOpenSecurity: (() -> Void)?
  var onOpenNotifications: (() -> Void)?
  var onOpenDiagnostics: (() -> Void)?
  var onDidLogout: (() -> Void)?

  private let viewModel: SettingsViewModel
  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)

  init(viewModel: SettingsViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Настройки"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.settings

    configureTable()
  }

  private func configureTable() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "setting")
    TelegramStyle.styleTableView(tableView)

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func refreshSession() {
    Task {
      do {
        try await viewModel.refreshSession()
        tableView.reloadData()
      } catch {
        showErrorAlert(message: "Не удалось обновить сессию")
      }
    }
  }

  private func logout() {
    Task {
      await viewModel.logout()
      onDidLogout?()
    }
  }
}

extension SettingsViewController: UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int {
    3
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0:
      return 2
    case 1:
      return 3
    default:
      return 1
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0:
      return "Аккаунт"
    case 1:
      return "Разделы"
    default:
      return "Сессия"
    }
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: "setting", for: indexPath)
    var content: UIListContentConfiguration = cell.defaultContentConfiguration()
    var primaryColor: UIColor = TelegramStyle.textPrimaryColor
    cell.accessibilityIdentifier = nil

    switch indexPath.section {
    case 0:
      if indexPath.row == 0 {
        content.text = viewModel.currentUser?.id ?? "Пользователь не авторизован"
        content.secondaryText = nil
      } else {
        content.text = "Ключ аккаунта (seed): \(viewModel.hasPrivateKey ? "есть" : "отсутствует")"
        content.secondaryText = nil
      }
      cell.accessoryType = .none
    case 1:
      let titles: [String] = ["Безопасность", "Уведомления", "Диагностика"]
      content.text = titles[indexPath.row]
      content.secondaryText = nil
      cell.accessoryType = .disclosureIndicator
      switch indexPath.row {
      case 0:
        cell.accessibilityIdentifier = MessengerAccessibility.Button.settingsSecurity
      case 1:
        cell.accessibilityIdentifier = MessengerAccessibility.Button.settingsNotifications
      default:
        cell.accessibilityIdentifier = MessengerAccessibility.Button.settingsDiagnostics
      }
    default:
      if indexPath.row == 0 {
        content.text = "Обновить сессию"
        primaryColor = TelegramStyle.accentColor
        cell.accessibilityIdentifier = MessengerAccessibility.Button.settingsRefreshSession
      }
      cell.accessoryType = .none
    }

    content.textProperties.color = primaryColor
    content.secondaryTextProperties.color = TelegramStyle.textSecondaryColor
    cell.contentConfiguration = content
    TelegramStyle.styleListCell(cell)
    return cell
  }
}

extension SettingsViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    switch indexPath.section {
    case 1:
      switch indexPath.row {
      case 0:
        onOpenSecurity?()
      case 1:
        onOpenNotifications?()
      case 2:
        onOpenDiagnostics?()
      default:
        break
      }
    case 2:
      refreshSession()
    default:
      break
    }
  }

  func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    guard section == 2 else {
      return nil
    }

    let button: UIButton = TelegramStyle.makeDestructiveButton(title: "Выйти")
    button.addTarget(self, action: #selector(logoutTapped), for: .touchUpInside)
    button.accessibilityIdentifier = MessengerAccessibility.Button.settingsLogout

    let container: UIView = UIView()
    container.addSubview(button)
    button.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      button.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    return container
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    section == 2 ? 64 : .leastNormalMagnitude
  }

  @objc
  private func logoutTapped() {
    logout()
  }
}
