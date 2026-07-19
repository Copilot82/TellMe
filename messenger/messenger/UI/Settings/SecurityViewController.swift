import UIKit

@MainActor
// Security settings expose local trust state without leaking private key material to the view layer.
final class SecurityViewController: UIViewController {
  private let viewModel: SettingsViewModel
  private let onOpenDeviceLink: (() -> Void)?

  private let statusLabel: UILabel = UILabel()
  private let outputTextView: UITextView = UITextView()
  private let manualReadSwitch: UISwitch = UISwitch()

  init(viewModel: SettingsViewModel, onOpenDeviceLink: (() -> Void)? = nil) {
    self.viewModel = viewModel
    self.onOpenDeviceLink = onOpenDeviceLink
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Безопасность"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.security

    configureUI()
    renderStatus()
  }

  private func configureUI() {
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.numberOfLines = 0
    statusLabel.textColor = TelegramStyle.textPrimaryColor
    statusLabel.accessibilityIdentifier = MessengerAccessibility.Label.securityStatus

    TelegramStyle.styleMonospaceTextView(outputTextView)
    outputTextView.isEditable = false
    outputTextView.accessibilityIdentifier = MessengerAccessibility.View.securityOutput
    outputTextView.heightAnchor.constraint(equalToConstant: 220).isActive = true

    let exportButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Экспорт recovery phrase")
    exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
    exportButton.accessibilityIdentifier = MessengerAccessibility.Button.securityExportSeed

    let importButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Импорт recovery phrase")
    importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
    importButton.accessibilityIdentifier = MessengerAccessibility.Button.securityImportSeed

    let checkPublicButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Проверить публичный ключ по handle")
    checkPublicButton.addTarget(self, action: #selector(checkPublicKeyTapped), for: .touchUpInside)
    checkPublicButton.accessibilityIdentifier = MessengerAccessibility.Button.securityCheckPublicKey

    let linkDeviceButton: UIButton = TelegramStyle.makePrimaryButton(title: "Привязать новое устройство")
    linkDeviceButton.addTarget(self, action: #selector(linkDeviceTapped), for: .touchUpInside)
    linkDeviceButton.accessibilityIdentifier = MessengerAccessibility.Button.securityLinkDevice

    let manualReadLabel: UILabel = UILabel()
    manualReadLabel.text = "Ручное подтверждение прочтения (2-я галочка)"
    manualReadLabel.font = .systemFont(ofSize: 14, weight: .medium)
    manualReadLabel.numberOfLines = 0
    manualReadLabel.textColor = TelegramStyle.textPrimaryColor

    manualReadSwitch.isOn = viewModel.manualReadReceiptsEnabled
    manualReadSwitch.addTarget(self, action: #selector(manualReadSwitchChanged), for: .valueChanged)
    manualReadSwitch.accessibilityIdentifier = MessengerAccessibility.View.securityManualRead

    let manualReadRow: UIStackView = UIStackView(arrangedSubviews: [manualReadLabel, manualReadSwitch])
    manualReadRow.axis = .horizontal
    manualReadRow.spacing = 12
    manualReadRow.alignment = .center

    let stack: UIStackView = UIStackView(arrangedSubviews: [
      statusLabel,
      manualReadRow,
      exportButton,
      importButton,
      checkPublicButton,
      linkDeviceButton,
      outputTextView,
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let containerView: UIView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(containerView)
    containerView.addSubview(stack)

    view.addSubview(containerView)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      containerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

      stack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
    ])
  }

  private func renderStatus() {
    let user: String = viewModel.currentUser?.id ?? "нет"
    let receiptsMode: String = viewModel.manualReadReceiptsEnabled ? "ручной" : "авто"
    statusLabel.text = "Пользователь: \(user)\nКлюч аккаунта (seed): \(viewModel.hasPrivateKey ? "есть" : "отсутствует")\nRead receipts: \(receiptsMode)"
    manualReadSwitch.setOn(viewModel.manualReadReceiptsEnabled, animated: false)
  }

  @objc
  private func manualReadSwitchChanged() {
    viewModel.setManualReadReceipts(enabled: manualReadSwitch.isOn)
    renderStatus()
  }

  @objc
  private func exportTapped() {
    Task {
      do {
        try await viewModel.authenticateLocal(
          reason: "Подтвердите доступ к recovery phrase TellMe."
        )
        outputTextView.text = try viewModel.exportPrivateKey()
      } catch let error as LocalAuthenticationError {
        showErrorAlert(message: error.localizedDescription)
      } catch {
        showErrorAlert(message: "Recovery phrase не найдена")
      }
    }
  }

  @objc
  private func importTapped() {
    let alert: UIAlertController = UIAlertController(title: "Импорт recovery phrase", message: nil, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.placeholder = "Вставьте seed phrase"
      textField.isSecureTextEntry = true
    }
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: "Импорт", style: .default, handler: { [weak self] _ in
      guard let self,
        let pem: String = alert.textFields?.first?.text
      else {
        return
      }

      do {
        try self.viewModel.importPrivateKey(pem)
        self.renderStatus()
        self.outputTextView.text = "Recovery phrase импортирована"
      } catch {
        self.showErrorAlert(message: "Невалидный seed/private key")
      }
    }))

    present(alert, animated: true)
  }

  @objc
  private func checkPublicKeyTapped() {
    showInputAlert(title: "Проверка публичного ключа", placeholder: "@user:domain") { [weak self] userHandle in
      guard let self else {
        return
      }

      Task {
        do {
          let response: PublicKeyResponse = try await self.viewModel.fetchPublicKey(userHandle: userHandle)
          self.outputTextView.text = response.publicKey
        } catch {
          self.showErrorAlert(message: "Не удалось получить публичный ключ")
        }
      }
    }
  }

  @objc
  private func linkDeviceTapped() {
    onOpenDeviceLink?()
  }
}
