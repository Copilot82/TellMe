import CoreImage
import UIKit

@MainActor
final class DeviceLinkHostViewController: UIViewController {
  private let viewModel: DeviceLinkViewModel

  private let statusLabel: UILabel = UILabel()
  private let qrImageView: UIImageView = UIImageView()
  private let textCodeView: UITextView = UITextView()
  private let pendingRequestLabel: UILabel = UILabel()
  private let approveButton: UIButton = TelegramStyle.makePrimaryButton(title: "Подтвердить устройство")

  private var hostSession: DeviceLinkViewModel.HostSession?
  private var pendingRequest: FederatedDeviceLinkSessionRequest?
  private var pollTask: Task<Void, Never>?

  init(viewModel: DeviceLinkViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    pollTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Привязка устройства"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.deviceLinkHost

    configureUI()
    startHostingFlow()
  }

  private func configureUI() {
    statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
    statusLabel.numberOfLines = 0
    statusLabel.textColor = TelegramStyle.textPrimaryColor
    statusLabel.text = "Готовим одноразовый QR/link-code..."
    statusLabel.accessibilityIdentifier = MessengerAccessibility.Label.deviceLinkHostStatus

    qrImageView.contentMode = .scaleAspectFit
    qrImageView.layer.cornerRadius = 12
    qrImageView.clipsToBounds = true
    qrImageView.backgroundColor = UIColor.white.withAlphaComponent(0.95)
    qrImageView.accessibilityIdentifier = MessengerAccessibility.View.deviceLinkHostQR
    qrImageView.heightAnchor.constraint(equalToConstant: 260).isActive = true

    TelegramStyle.styleMonospaceTextView(textCodeView)
    textCodeView.isEditable = false
    textCodeView.accessibilityIdentifier = MessengerAccessibility.View.deviceLinkHostTextCode
    textCodeView.heightAnchor.constraint(equalToConstant: 110).isActive = true

    pendingRequestLabel.font = .systemFont(ofSize: 13, weight: .regular)
    pendingRequestLabel.numberOfLines = 0
    pendingRequestLabel.textColor = TelegramStyle.textSecondaryColor
    pendingRequestLabel.text = "Ожидается запрос с нового устройства."
    pendingRequestLabel.accessibilityIdentifier = MessengerAccessibility.Label.deviceLinkHostPendingRequest

    approveButton.addTarget(self, action: #selector(approveTapped), for: .touchUpInside)
    approveButton.isEnabled = false
    approveButton.accessibilityIdentifier = MessengerAccessibility.Button.deviceLinkHostApprove

    let copyButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Копировать код")
    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    copyButton.accessibilityIdentifier = MessengerAccessibility.Button.deviceLinkHostCopyCode

    let stack: UIStackView = UIStackView(arrangedSubviews: [
      statusLabel,
      qrImageView,
      textCodeView,
      copyButton,
      pendingRequestLabel,
      approveButton,
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

  private func startHostingFlow() {
    Task {
      do {
        let session: DeviceLinkViewModel.HostSession = try await viewModel.startHostingLink()
        hostSession = session
        qrImageView.image = makeQRCodeImage(from: session.qrPayload)
        textCodeView.text = session.textCode
        statusLabel.text = "Покажите QR или передайте link-code новому устройству.\nИстекает: \(formatted(session.expiresAt))"
        beginPolling(sessionId: session.sessionId)
      } catch {
        showErrorAlert(message: error.localizedDescription)
        statusLabel.text = "Не удалось создать одноразовый link-code."
      }
    }
  }

  private func beginPolling(sessionId: String) {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        do {
          let requests: [FederatedDeviceLinkSessionRequest] = try await self.viewModel.fetchPendingRequests(
            sessionId: sessionId
          )
          if let request: FederatedDeviceLinkSessionRequest = requests.first(where: { $0.status == "pending" }) {
            self.pendingRequest = request
            self.pendingRequestLabel.text = "Новое устройство запрашивает доступ: \(request.newDeviceId)"
            self.approveButton.isEnabled = true
          } else if self.pendingRequest == nil {
            self.pendingRequestLabel.text = "Ожидается запрос с нового устройства."
            self.approveButton.isEnabled = false
          }
        } catch {
          self.pendingRequestLabel.text = "Не удалось получить входящие link requests."
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  @objc
  private func approveTapped() {
    guard let hostSession, let pendingRequest else {
      return
    }

    approveButton.isEnabled = false
    Task {
      do {
        try await viewModel.approve(hostSession: hostSession, request: pendingRequest)
        statusLabel.text = "Устройство подтверждено. Новый client завершит provisioning автоматически."
        pendingRequestLabel.text = "Запрос \(pendingRequest.newDeviceId) подтверждён."
      } catch {
        approveButton.isEnabled = true
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  @objc
  private func copyTapped() {
    UIPasteboard.general.string = textCodeView.text
    showErrorAlert(message: "Link-code скопирован", title: "Готово")
  }

  private func formatted(_ date: Date) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func makeQRCodeImage(from payload: String) -> UIImage? {
    guard let data: Data = payload.data(using: .utf8),
      let filter: CIFilter = CIFilter(name: "CIQRCodeGenerator")
    else {
      return nil
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")

    guard let outputImage: CIImage = filter.outputImage else {
      return nil
    }

    let transform = CGAffineTransform(scaleX: 10, y: 10)
    let scaledImage: CIImage = outputImage.transformed(by: transform)
    let context: CIContext = CIContext(options: nil)

    guard let cgImage: CGImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
      return nil
    }

    return UIImage(cgImage: cgImage)
  }
}
