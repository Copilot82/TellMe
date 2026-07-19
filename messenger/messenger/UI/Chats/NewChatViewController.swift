import UIKit

@MainActor
// New-chat creation accepts handles only after local normalization to keep server lookups predictable.
final class NewChatViewController: UIViewController {
  var onConversationReady: ((Conversation) -> Void)?

  private let viewModel: ChatsViewModel
  private let pasteButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Вставить")
  private let scanButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Скан QR")
  private let myCodeButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Мой QR / код")

  private let userHandleField: UITextField = TelegramStyle.makeTextField(placeholder: "@alice:example.org")
  private let trustStateLabel: UILabel = UILabel()
  private let createButton: UIButton = TelegramStyle.makePrimaryButton(title: "Открыть чат")
  private let errorLabel: UILabel = UILabel()

  private var qrTrustVerified: Bool = false
  private var scannedContactCard: QRContactCard?

  init(viewModel: ChatsViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Новый чат"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.newChat

    configureUI()
    renderTrustState()
  }

  private func configureUI() {
    userHandleField.autocapitalizationType = .none
    userHandleField.autocorrectionType = .no
    userHandleField.keyboardType = .asciiCapable
    userHandleField.accessibilityIdentifier = MessengerAccessibility.Input.newChatHandle

    trustStateLabel.numberOfLines = 0
    trustStateLabel.font = .systemFont(ofSize: 13, weight: .medium)
    trustStateLabel.textColor = TelegramStyle.textSecondaryColor
    trustStateLabel.accessibilityIdentifier = MessengerAccessibility.Label.newChatTrust

    errorLabel.textColor = TelegramStyle.warningColor
    errorLabel.numberOfLines = 0
    errorLabel.font = .systemFont(ofSize: 13)
    errorLabel.accessibilityIdentifier = MessengerAccessibility.Label.newChatError

    pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
    pasteButton.accessibilityIdentifier = MessengerAccessibility.Button.newChatPaste

    scanButton.addTarget(self, action: #selector(scanQRTapped), for: .touchUpInside)
    scanButton.accessibilityIdentifier = MessengerAccessibility.Button.newChatScanQr

    myCodeButton.addTarget(self, action: #selector(showMyCodeTapped), for: .touchUpInside)
    myCodeButton.accessibilityIdentifier = MessengerAccessibility.Button.newChatShowMyCode

    createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
    createButton.accessibilityIdentifier = MessengerAccessibility.Button.newChatOpen

    let helperRow: UIStackView = UIStackView(arrangedSubviews: [pasteButton, scanButton, myCodeButton])
    helperRow.axis = .horizontal
    helperRow.distribution = .fillEqually
    helperRow.spacing = 8

    let stackView: UIStackView = UIStackView(arrangedSubviews: [
      userHandleField,
      trustStateLabel,
      helperRow,
      errorLabel,
      createButton,
    ])

    stackView.axis = .vertical
    stackView.spacing = 12
    stackView.translatesAutoresizingMaskIntoConstraints = false

    let containerView: UIView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(containerView)
    containerView.addSubview(stackView)

    view.addSubview(containerView)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      containerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
    ])
  }

  @objc
  private func pasteTapped() {
    let clipboard: String = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !clipboard.isEmpty else {
      return
    }

    handleScannedOrPastedValue(clipboard)
  }

  @objc
  private func scanQRTapped() {
    let scanner: QRScannerViewController = QRScannerViewController()
    scanner.onCodeScanned = { [weak self] value in
      self?.handleScannedOrPastedValue(value)
    }

    navigationController?.pushViewController(scanner, animated: true)
  }

  @objc
  private func showMyCodeTapped() {
    do {
      let shareData: ChatsViewModel.ContactShareData = try viewModel.myContactShareData()
      let controller: ContactShareViewController = ContactShareViewController(shareData: shareData)
      navigationController?.pushViewController(controller, animated: true)
    } catch {
      showErrorAlert(message: "Не удалось подготовить ваш QR/код. Выполните вход заново.")
    }
  }

  private func handleScannedOrPastedValue(_ value: String) {
    let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let card: QRContactCard = ContactCodeCodec.decode(trimmed) {
      userHandleField.text = card.userHandle
      scannedContactCard = card
      qrTrustVerified = true
      renderTrustState()
      return
    }

    userHandleField.text = trimmed
    scannedContactCard = nil
    qrTrustVerified = false
    renderTrustState()
  }

  @objc
  private func createTapped() {
    errorLabel.text = nil

    let handle: String = userHandleField.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard isValidHandle(handle) else {
      errorLabel.text = "Введите handle в формате @user:domain"
      return
    }

    Task {
      do {
        if let scannedContactCard {
          if scannedContactCard.userHandle != handle {
            errorLabel.text = "Сканированный код не соответствует введённому handle"
            return
          }

          try await viewModel.verifyContactCard(scannedContactCard)
        }

        let conversation: Conversation = try await viewModel.createDirectConversation(with: handle)
        onConversationReady?(conversation)
      } catch {
        errorLabel.text = error.localizedDescription.isEmpty ? "Не удалось открыть чат" : error.localizedDescription
      }
    }
  }

  private func renderTrustState() {
    if qrTrustVerified {
      trustStateLabel.text = "✅ E2E включено\n✅ Ключ подтвержден QR/кодом"
      return
    }

    trustStateLabel.text = "✅ E2E включено\n⚠️ E2E включено, но не подтверждено"
  }

  private func isValidHandle(_ value: String) -> Bool {
    value.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil
  }
}
