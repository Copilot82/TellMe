import CoreImage
import UIKit

@MainActor
final class ContactShareViewController: UIViewController {
  private let shareData: ChatsViewModel.ContactShareData

  private let qrImageView: UIImageView = UIImageView()
  private let textCodeView: UITextView = UITextView()

  init(shareData: ChatsViewModel.ContactShareData) {
    self.shareData = shareData
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Мой QR / код"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.contactCode

    configureUI()
  }

  private func configureUI() {
    let handleLabel: UILabel = UILabel()
    handleLabel.text = shareData.card.userHandle
    handleLabel.numberOfLines = 0
    handleLabel.textAlignment = .center
    handleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
    handleLabel.textColor = TelegramStyle.textPrimaryColor

    qrImageView.contentMode = .scaleAspectFit
    qrImageView.image = makeQRCodeImage(from: shareData.qrPayload)
    qrImageView.layer.cornerRadius = 12
    qrImageView.clipsToBounds = true
    qrImageView.backgroundColor = UIColor.white.withAlphaComponent(0.95)
    qrImageView.accessibilityIdentifier = MessengerAccessibility.View.contactCodeQR
    qrImageView.heightAnchor.constraint(equalToConstant: 260).isActive = true

    TelegramStyle.styleMonospaceTextView(textCodeView)
    textCodeView.isEditable = false
    textCodeView.text = shareData.textCode
    textCodeView.accessibilityIdentifier = MessengerAccessibility.View.contactCodeText
    textCodeView.heightAnchor.constraint(equalToConstant: 110).isActive = true

    let copyButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Копировать код")
    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    copyButton.accessibilityIdentifier = MessengerAccessibility.Button.contactCodeCopy

    let shareButton: UIButton = TelegramStyle.makePrimaryButton(title: "Поделиться")
    shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
    shareButton.accessibilityIdentifier = MessengerAccessibility.Button.contactCodeShare

    let stack: UIStackView = UIStackView(arrangedSubviews: [
      handleLabel,
      qrImageView,
      textCodeView,
      copyButton,
      shareButton,
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
  private func copyTapped() {
    UIPasteboard.general.string = shareData.textCode
    showErrorAlert(message: "Текстовый код скопирован", title: "Готово")
  }

  @objc
  private func shareTapped() {
    let activity = UIActivityViewController(
      activityItems: [shareData.qrPayload, shareData.textCode],
      applicationActivities: nil
    )
    present(activity, animated: true)
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
