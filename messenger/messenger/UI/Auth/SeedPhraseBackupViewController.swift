import UIKit

@MainActor
final class SeedPhraseBackupViewController: UIViewController {
  private let seedPhrase: String
  private let onConfirm: () -> Void

  private let scrollView: UIScrollView = UIScrollView()
  private let contentView: UIView = UIView()
  private let seedTextView: UITextView = UITextView()
  private let copyButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Скопировать")
  private let confirmButton: UIButton = TelegramStyle.makePrimaryButton(title: "Я сохранил")
  private let statusLabel: UILabel = UILabel()

  init(seedPhrase: String, onConfirm: @escaping () -> Void) {
    self.seedPhrase = seedPhrase
    self.onConfirm = onConfirm
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .clear
    view.accessibilityIdentifier = MessengerAccessibility.Screen.authSeedBackup
    isModalInPresentation = true
    TelegramStyle.installBackground(in: view)

    configureUI()
  }

  private func configureUI() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    contentView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    scrollView.addSubview(contentView)

    let cardView: UIView = UIView()
    TelegramStyle.styleGlassCard(cardView)
    cardView.translatesAutoresizingMaskIntoConstraints = false

    let iconContainer: UIView = UIView()
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.backgroundColor = TelegramStyle.warningColor.withAlphaComponent(0.16)
    iconContainer.layer.cornerRadius = 24
    iconContainer.layer.borderColor = TelegramStyle.warningColor.withAlphaComponent(0.38).cgColor
    iconContainer.layer.borderWidth = 1

    let iconWrapper: UIView = UIView()
    iconWrapper.translatesAutoresizingMaskIntoConstraints = false

    let iconView: UIImageView = UIImageView(image: UIImage(systemName: "key.horizontal.fill"))
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.tintColor = TelegramStyle.warningColor
    iconView.contentMode = .scaleAspectFit
    iconContainer.addSubview(iconView)

    let titleLabel: UILabel = UILabel()
    titleLabel.text = "Сохраните recovery phrase"
    titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
    titleLabel.textColor = TelegramStyle.textPrimaryColor
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0

    let descriptionLabel: UILabel = UILabel()
    descriptionLabel.text = "Эта фраза восстанавливает доступ к аккаунту и ключам шифрования. Сохраните её в надёжном месте."
    descriptionLabel.font = .systemFont(ofSize: 15, weight: .regular)
    descriptionLabel.textColor = TelegramStyle.textSecondaryColor
    descriptionLabel.textAlignment = .center
    descriptionLabel.numberOfLines = 0

    TelegramStyle.styleMonospaceTextView(seedTextView)
    seedTextView.text = seedPhrase
    seedTextView.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
    seedTextView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
    seedTextView.isEditable = false
    seedTextView.isSelectable = true
    seedTextView.isScrollEnabled = false
    seedTextView.autocorrectionType = .no
    seedTextView.autocapitalizationType = .none
    seedTextView.accessibilityIdentifier = MessengerAccessibility.View.authSeedPhrase

    let warningLabel: UILabel = UILabel()
    warningLabel.text = "Никому не отправляйте seed phrase. Даже если кто-то представится поддержкой TellMe: у нас нет поддержки, а TellMe никогда не просит seed phrase, ключи, коды или другие секретные данные."
    warningLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    warningLabel.textColor = TelegramStyle.warningColor
    warningLabel.numberOfLines = 0
    warningLabel.accessibilityIdentifier = MessengerAccessibility.Label.authSeedWarning

    let warningContainer: UIView = UIView()
    warningContainer.translatesAutoresizingMaskIntoConstraints = false
    warningContainer.backgroundColor = TelegramStyle.warningColor.withAlphaComponent(0.10)
    warningContainer.layer.cornerRadius = 12
    warningContainer.layer.borderColor = TelegramStyle.warningColor.withAlphaComponent(0.35).cgColor
    warningContainer.layer.borderWidth = 1
    warningContainer.addSubview(warningLabel)
    warningLabel.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.text = " "
    statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
    statusLabel.textColor = TelegramStyle.textSecondaryColor
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.accessibilityIdentifier = MessengerAccessibility.Label.authSeedCopyStatus

    copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
    copyButton.accessibilityIdentifier = MessengerAccessibility.Button.authSeedCopy

    confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
    confirmButton.accessibilityIdentifier = MessengerAccessibility.Button.authSeedConfirm

    let stackView: UIStackView = UIStackView(arrangedSubviews: [
      iconWrapper,
      titleLabel,
      descriptionLabel,
      seedTextView,
      copyButton,
      statusLabel,
      warningContainer,
      confirmButton,
    ])
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.spacing = 14
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.setCustomSpacing(18, after: descriptionLabel)
    stackView.setCustomSpacing(18, after: warningContainer)

    cardView.addSubview(stackView)
    contentView.addSubview(cardView)
    iconWrapper.addSubview(iconContainer)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      cardView.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      cardView.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      cardView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 24),
      cardView.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -24),

      stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
      stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
      stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22),
      stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -22),

      iconWrapper.heightAnchor.constraint(equalToConstant: 48),
      iconContainer.centerXAnchor.constraint(equalTo: iconWrapper.centerXAnchor),
      iconContainer.centerYAnchor.constraint(equalTo: iconWrapper.centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: 48),
      iconContainer.heightAnchor.constraint(equalToConstant: 48),

      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),

      seedTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 104),

      warningLabel.leadingAnchor.constraint(equalTo: warningContainer.leadingAnchor, constant: 12),
      warningLabel.trailingAnchor.constraint(equalTo: warningContainer.trailingAnchor, constant: -12),
      warningLabel.topAnchor.constraint(equalTo: warningContainer.topAnchor, constant: 12),
      warningLabel.bottomAnchor.constraint(equalTo: warningContainer.bottomAnchor, constant: -12),
    ])
  }

  @objc
  private func copyTapped() {
    UIPasteboard.general.string = seedPhrase
    let message: String = "Seed phrase скопирована. Не отправляйте её никому."
    statusLabel.text = message
    statusLabel.textColor = TelegramStyle.warningColor
    UIAccessibility.post(notification: .announcement, argument: message)
  }

  @objc
  private func confirmTapped() {
    dismiss(animated: true) { [onConfirm] in
      onConfirm()
    }
  }
}
