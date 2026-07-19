import UIKit

@MainActor
final class DeviceLinkJoinViewController: UIViewController {
  private let viewModel: DeviceLinkViewModel
  private let onAuthenticated: (User) -> Void

  private let codeTextView: UITextView = UITextView()
  private let statusLabel: UILabel = UILabel()
  private let activityView: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)

  private var joinTask: Task<Void, Never>?
  private var linkPayload: DeviceLinkCodePayload?
  private var pendingScannedPayload: DeviceLinkCodePayload?
  private var isLinking: Bool = false

  init(viewModel: DeviceLinkViewModel, onAuthenticated: @escaping (User) -> Void) {
    self.viewModel = viewModel
    self.onAuthenticated = onAuthenticated
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    joinTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Новое устройство"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)

    configureUI()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    guard let pendingScannedPayload, !isLinking else {
      return
    }

    self.pendingScannedPayload = nil
    startLinking(with: pendingScannedPayload)
  }

  private func configureUI() {
    let titleLabel: UILabel = UILabel()
    titleLabel.text = "Сканируйте QR или вставьте link-code со старого устройства"
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.numberOfLines = 0
    titleLabel.textColor = TelegramStyle.textPrimaryColor

    TelegramStyle.styleMonospaceTextView(codeTextView)
    codeTextView.isEditable = true
    codeTextView.autocorrectionType = .no
    codeTextView.autocapitalizationType = .none
    codeTextView.keyboardType = .asciiCapable
    codeTextView.heightAnchor.constraint(equalToConstant: 140).isActive = true

    let pasteButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Вставить код")
    pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

    let scanButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Скан QR")
    scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)

    let startButton: UIButton = TelegramStyle.makePrimaryButton(title: "Начать привязку")
    startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

    statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
    statusLabel.numberOfLines = 0
    statusLabel.textColor = TelegramStyle.textSecondaryColor
    statusLabel.text = "После запроса подтвердите новое устройство на старом client."

    activityView.hidesWhenStopped = true
    activityView.color = TelegramStyle.accentColor

    let helperRow: UIStackView = UIStackView(arrangedSubviews: [pasteButton, scanButton])
    helperRow.axis = .horizontal
    helperRow.spacing = 12
    helperRow.distribution = .fillEqually

    let stack: UIStackView = UIStackView(arrangedSubviews: [
      titleLabel,
      codeTextView,
      helperRow,
      startButton,
      statusLabel,
      activityView,
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container: UIView = UIView()
    TelegramStyle.styleGlassCard(container)
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)

    view.addSubview(container)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
    ])
  }

  @objc
  private func pasteTapped() {
    codeTextView.text = UIPasteboard.general.string ?? ""
    _ = parseCurrentPayload()
  }

  @objc
  private func scanTapped() {
    let scanner: QRScannerViewController = QRScannerViewController()
    scanner.onCodeScanned = { [weak self] value in
      self?.codeTextView.text = value
      guard let payload: DeviceLinkCodePayload = self?.parseCurrentPayload() else {
        return
      }

      self?.pendingScannedPayload = payload
    }
    navigationController?.pushViewController(scanner, animated: true)
  }

  @objc
  private func startTapped() {
    guard let payload: DeviceLinkCodePayload = linkPayload ?? parseCurrentPayload() else {
      showErrorAlert(message: "Не удалось распознать link-code.")
      return
    }

    startLinking(with: payload)
  }

  private func startLinking(with payload: DeviceLinkCodePayload) {
    guard !isLinking else {
      return
    }

    isLinking = true
    joinTask?.cancel()
    activityView.startAnimating()
    statusLabel.text = "Отправляем запрос привязки и ждём подтверждение..."
    linkPayload = payload

    joinTask = Task { [weak self] in
      guard let self else {
        return
      }

      defer {
        self.activityView.stopAnimating()
        self.joinTask = nil
        self.isLinking = false
      }

      do {
        let joinSession: DeviceLinkViewModel.JoinSession = try await self.viewModel.requestLink(using: payload)
        try await self.waitForApproval(joinSession: joinSession)
      } catch is CancellationError {
        self.statusLabel.text = "Привязка отменена."
      } catch {
        if self.isBenignCancellation(error) {
          self.statusLabel.text = "Привязка отменена."
          return
        }

        self.statusLabel.text = "Привязка не завершена."
        self.showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  private func parseCurrentPayload() -> DeviceLinkCodePayload? {
    let raw: String = codeTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload: DeviceLinkCodePayload? = DeviceLinkCodeCodec.decode(raw)
    linkPayload = payload
    if let payload {
      statusLabel.text = "Будет привязан аккаунт \(payload.userHandle). Подтвердите запрос на старом устройстве."
    } else {
      statusLabel.text = "Введите link-code или отсканируйте QR со старого устройства."
    }
    return payload
  }

  private func waitForApproval(joinSession: DeviceLinkViewModel.JoinSession) async throws {
    let deadline: Date = Date().addingTimeInterval(90)

    while Date() < deadline {
      let response: FederatedDeviceLinkPollResponse = try await viewModel.poll(joinSession: joinSession)
      if response.status == "approved",
        let approvedDeviceCertificate = response.approvedDeviceCertificate,
        let encryptedProvisioningBlob: String = response.encryptedProvisioningBlob
      {
        let user: User = try await viewModel.complete(
          joinSession: joinSession,
          approvedDeviceCertificate: approvedDeviceCertificate,
          encryptedProvisioningBlob: encryptedProvisioningBlob
        )
        onAuthenticated(user)
        return
      }

      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    throw APIError.transport("Истекло ожидание подтверждения привязки")
  }

  private func isBenignCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }

    if let apiError: APIError = error as? APIError,
      case .transport(let message) = apiError
    {
      let normalizedMessage: String = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return normalizedMessage == "cancelled" || normalizedMessage == "canceled"
    }

    return false
  }
}
