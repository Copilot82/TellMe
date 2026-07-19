import UIKit

@MainActor
final class NotificationsSettingsViewController: UIViewController {
  private let viewModel: SettingsViewModel
  private let launchConfiguration: AppLaunchConfiguration = .current

  private let infoLabel: UILabel = UILabel()
  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)
  private lazy var testPushControlsStack: UIStackView = makeTestPushControlsStack()

  private var tokens: [DeviceToken] = []
  private var latestAPNSTokenData: Data?

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

    title = "Уведомления"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.notifications

    configureUI()
    setupObservers()

    Task {
      await reloadTokens()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func configureUI() {
    let refreshButton = UIBarButtonItem(title: "Обновить", style: .plain, target: self, action: #selector(refreshTapped))
    let registerButton = UIBarButtonItem(title: "Регистрация", style: .plain, target: self, action: #selector(registerTapped))
    registerButton.accessibilityIdentifier = MessengerAccessibility.Button.notificationsRegisterToken
    navigationItem.rightBarButtonItems = [refreshButton, registerButton]

    infoLabel.numberOfLines = 0
    infoLabel.font = .systemFont(ofSize: 13)
    infoLabel.textColor = TelegramStyle.textSecondaryColor
    infoLabel.text = "Ожидается APNS token…"
    infoLabel.accessibilityIdentifier = MessengerAccessibility.Label.notificationsStatus

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.register(NotificationTokenCell.self, forCellReuseIdentifier: "token")
    tableView.dataSource = self
    tableView.delegate = self
    TelegramStyle.styleTableView(tableView)
    var arrangedSubviews: [UIView] = [infoLabel]
    if launchConfiguration.isUITestMode {
      arrangedSubviews.append(testPushControlsStack)
    }
    arrangedSubviews.append(tableView)

    let stack: UIStackView = UIStackView(arrangedSubviews: arrangedSubviews)
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(self, selector: #selector(didReceiveAPNSToken(_:)), name: .didReceiveAPNSToken, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(didFailToReceiveAPNSToken(_:)), name: .didFailToRegisterAPNSToken, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didProcessRemoteNotificationSync(_:)),
      name: .didProcessRemoteNotificationSync,
      object: nil
    )
  }

  @objc
  private func didReceiveAPNSToken(_ notification: Notification) {
    latestAPNSTokenData = notification.userInfo?["token"] as? Data

    if let latestAPNSTokenData {
      infoLabel.text = "APNS token length: \(latestAPNSTokenData.count) bytes"
    } else {
      infoLabel.text = "APNS token получен"
    }
  }

  @objc
  private func didFailToReceiveAPNSToken(_ notification: Notification) {
    let error: Error? = notification.userInfo?["error"] as? Error
    infoLabel.text = "Ошибка APNS: \(error?.localizedDescription ?? "unknown")"
  }

  @objc
  private func didProcessRemoteNotificationSync(_ notification: Notification) {
    let hint: String = (notification.userInfo?["hint"] as? String ?? "unknown")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let messageId: String = (notification.userInfo?["message_id"] as? String ?? "none")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let synthetic: Bool = notification.userInfo?["synthetic"] as? Bool ?? false
    let source: String = synthetic ? "synthetic" : "server"
    infoLabel.text = "Последний push sync: \(hint) • \(messageId) • \(source)"
  }

  @objc
  private func refreshTapped() {
    Task {
      await reloadTokens()
    }
  }

  @objc
  private func registerTapped() {
    Task {
      do {
        guard let tokenData: Data = latestAPNSTokenData ?? PushNotificationService.shared?.currentAPNSToken() else {
          showErrorAlert(message: "APNS token ещё не получен")
          return
        }
        try await viewModel.registerAPNSToken(tokenData)
        await reloadTokens()
      } catch {
        showErrorAlert(message: "Не удалось зарегистрировать token")
      }
    }
  }

  private func reloadTokens() async {
    do {
      tokens = try await viewModel.listDeviceTokens()
      tableView.reloadData()
    } catch {
      showErrorAlert(message: "Не удалось загрузить device tokens")
    }
  }

  private func makeTestPushControlsStack() -> UIStackView {
    let messageButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Simulate Message Push")
    messageButton.accessibilityIdentifier = MessengerAccessibility.Button.notificationsSimulateMessagePush
    messageButton.addTarget(self, action: #selector(simulateMessagePushTapped), for: .touchUpInside)

    let missedCallButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Simulate Missed Call Push")
    missedCallButton.accessibilityIdentifier = MessengerAccessibility.Button.notificationsSimulateMissedCallPush
    missedCallButton.addTarget(self, action: #selector(simulateMissedCallPushTapped), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [messageButton, missedCallButton])
    stack.axis = .vertical
    stack.spacing = 8
    return stack
  }

  @objc
  private func simulateMessagePushTapped() {
    simulateSyntheticPush(hint: .message, messageId: "ui-message-push-001")
  }

  @objc
  private func simulateMissedCallPushTapped() {
    simulateSyntheticPush(hint: .missedCall, messageId: "ui-missed-call-push-001")
  }

  private func simulateSyntheticPush(hint: PushNotificationHint, messageId: String) {
    Task {
      let processed: Bool = await PushNotificationService.shared?.handleRemoteNotification([
        "uitest_remote_sync": true,
        "hint": hint.rawValue,
        "message_id": messageId,
      ]) ?? false

      if !processed {
        infoLabel.text = "Synthetic push не обработан"
      }
    }
  }

  private func toggleToken(_ token: DeviceToken) {
    Task {
      do {
        try await viewModel.updateDeviceToken(token: token.token, pushEnabled: !token.pushEnabled)
        await reloadTokens()
      } catch {
        showErrorAlert(message: "Не удалось обновить push_enabled")
      }
    }
  }

  private func deleteToken(_ token: DeviceToken) {
    Task {
      do {
        try await viewModel.deleteDeviceToken(token: token.token)
        await reloadTokens()
      } catch {
        showErrorAlert(message: "Не удалось удалить token")
      }
    }
  }
}

extension NotificationsSettingsViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    tokens.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let token: DeviceToken = tokens[indexPath.row]
    guard let cell = tableView.dequeueReusableCell(withIdentifier: "token", for: indexPath) as? NotificationTokenCell else {
      return UITableViewCell()
    }

    cell.configure(token: token)
    cell.onToggle = { [weak self] in
      self?.toggleToken(token)
    }
    cell.onDelete = { [weak self] in
      self?.deleteToken(token)
    }
    return cell
  }
}

extension NotificationsSettingsViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    nil
  }
}

private final class NotificationTokenCell: UITableViewCell {
  private let titleLabel: UILabel = UILabel()
  private let tokenLabel: UILabel = UILabel()
  private let pushSwitch: UISwitch = UISwitch()
  private let deleteButton: UIButton = TelegramStyle.makeDestructiveButton(title: "Удалить")
  private let rootStack: UIStackView = UIStackView()

  var onToggle: (() -> Void)?
  var onDelete: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    configureLayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onToggle = nil
    onDelete = nil
  }

  private func configureLayout() {
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
    titleLabel.textColor = TelegramStyle.textPrimaryColor
    titleLabel.numberOfLines = 1

    tokenLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    tokenLabel.textColor = TelegramStyle.textSecondaryColor
    tokenLabel.numberOfLines = 2

    pushSwitch.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

    let topRow: UIStackView = UIStackView(arrangedSubviews: [titleLabel, pushSwitch])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.distribution = .equalSpacing

    rootStack.axis = .vertical
    rootStack.spacing = 10
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootStack.addArrangedSubview(topRow)
    rootStack.addArrangedSubview(tokenLabel)
    rootStack.addArrangedSubview(deleteButton)

    let card: UIView = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(card, cornerRadius: 16)
    card.addSubview(rootStack)

    contentView.addSubview(card)

    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

      rootStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      rootStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      rootStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
      rootStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
    ])
  }

  func configure(token: DeviceToken) {
    titleLabel.text = "\(token.deviceType.rawValue) • \(token.pushEnabled ? "включен" : "выключен")"
    tokenLabel.text = token.token
    accessibilityIdentifier = MessengerAccessibility.View.notificationsTokenCell(token.id)
    pushSwitch.isOn = token.pushEnabled
    pushSwitch.accessibilityIdentifier = MessengerAccessibility.View.notificationsPushEnabled(token.id)
    deleteButton.accessibilityIdentifier = MessengerAccessibility.Button.notificationsDeleteToken(token.id)
  }

  @objc
  private func toggleChanged() {
    onToggle?()
  }

  @objc
  private func deleteTapped() {
    onDelete?()
  }
}
