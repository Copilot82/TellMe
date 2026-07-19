import UIKit

@MainActor
protocol AuthViewControllerDelegate: AnyObject {
  func authViewController(_ viewController: AuthViewController, didAuthenticate result: AuthViewModel.AuthResult)
}

@MainActor
// Auth UI advances only after the view model commits the corresponding key or session state.
final class AuthViewController: UIViewController {
  private static let emptyErrorPlaceholder: String = " "

  weak var delegate: AuthViewControllerDelegate?

  private let viewModel: AuthViewModel
  private let onOpenDeviceLink: (() -> Void)?

  private let modeControl: UISegmentedControl = UISegmentedControl(items: ["Вход", "Регистрация"])
  private let userHandleField: UITextField = TelegramStyle.makeTextField(placeholder: "@alice:example.org")
  private let seedPhraseField: UITextField = TelegramStyle.makeTextField(placeholder: "Seed phrase")
  private let registrationServerView: UIView = UIView()
  private let registrationHandlePreviewLabel: UILabel = UILabel()
  private let submitButton: UIButton = TelegramStyle.makePrimaryButton(title: "Продолжить")
  private let linkDeviceButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Привязать устройство")
  private let errorLabel: UILabel = UILabel()
  private let activityView: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)

  private var displayedMode: AuthViewModel.Mode = .login
  private var loginHandleDraft: String = ""
  private var registrationLoginDraft: String = ""

  init(viewModel: AuthViewModel, onOpenDeviceLink: (() -> Void)? = nil) {
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

    title = "TellMe"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.auth

    configureUI()
    updateModeUI()
  }

  private func configureUI() {
    modeControl.selectedSegmentIndex = 0
    modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

    userHandleField.autocapitalizationType = .none
    userHandleField.autocorrectionType = .no
    userHandleField.keyboardType = .asciiCapable
    userHandleField.accessibilityIdentifier = MessengerAccessibility.Input.authHandle
    userHandleField.addTarget(self, action: #selector(handleTextChanged), for: .editingChanged)

    configureRegistrationServerView()

    registrationHandlePreviewLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    registrationHandlePreviewLabel.textColor = TelegramStyle.textSecondaryColor
    registrationHandlePreviewLabel.numberOfLines = 0
    registrationHandlePreviewLabel.accessibilityIdentifier = MessengerAccessibility.Label.authHandlePreview

    seedPhraseField.autocapitalizationType = .none
    seedPhraseField.autocorrectionType = .no
    seedPhraseField.keyboardType = .asciiCapable
    seedPhraseField.isSecureTextEntry = true
    seedPhraseField.accessibilityIdentifier = MessengerAccessibility.Input.authSeed

    errorLabel.textColor = TelegramStyle.warningColor
    errorLabel.font = .systemFont(ofSize: 13, weight: .regular)
    errorLabel.numberOfLines = 0
    errorLabel.accessibilityIdentifier = MessengerAccessibility.Label.authError
    setErrorText(nil)

    let titleLabel: UILabel = UILabel()
    titleLabel.text = "TellMe"
    titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
    titleLabel.textColor = TelegramStyle.textPrimaryColor
    titleLabel.textAlignment = .center

    let subtitleLabel: UILabel = UILabel()
    subtitleLabel.text = "Federated E2E (server-blind)"
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.textColor = TelegramStyle.textSecondaryColor
    subtitleLabel.textAlignment = .center

    submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
    submitButton.accessibilityIdentifier = MessengerAccessibility.Button.authSubmit
    linkDeviceButton.addTarget(self, action: #selector(linkDeviceTapped), for: .touchUpInside)
    modeControl.accessibilityIdentifier = MessengerAccessibility.View.authModeSegmented

    let stackView: UIStackView = UIStackView(arrangedSubviews: [
      titleLabel,
      subtitleLabel,
      modeControl,
      registrationServerView,
      userHandleField,
      registrationHandlePreviewLabel,
      seedPhraseField,
      errorLabel,
      submitButton,
      linkDeviceButton,
      activityView,
    ])

    stackView.axis = .vertical
    stackView.spacing = 12
    stackView.translatesAutoresizingMaskIntoConstraints = false

    let containerView: UIView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(containerView)
    containerView.addSubview(stackView)

    let topSpacer: UIView = UIView()
    let bottomSpacer: UIView = UIView()
    let centeringStackView: UIStackView = UIStackView(arrangedSubviews: [
      topSpacer,
      containerView,
      bottomSpacer,
    ])
    centeringStackView.axis = .vertical
    centeringStackView.spacing = 0
    centeringStackView.translatesAutoresizingMaskIntoConstraints = false

    let contentView: UIView = UIView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(centeringStackView)

    let scrollView: UIScrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.keyboardDismissMode = .interactive
    scrollView.addSubview(contentView)

    view.addSubview(scrollView)

    let equalSpacerHeights: NSLayoutConstraint = topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor)
    equalSpacerHeights.priority = .defaultHigh

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

      centeringStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      centeringStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      centeringStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
      centeringStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      topSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
      bottomSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
      equalSpacerHeights,

      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
    ])

    activityView.hidesWhenStopped = true
    activityView.color = TelegramStyle.accentColor
  }

  @objc
  private func modeChanged() {
    saveHandleDraft(for: displayedMode)
    displayedMode = currentMode
    userHandleField.text = displayedMode == .register ? registrationLoginDraft : loginHandleDraft
    setErrorText(nil)
    updateModeUI()
  }

  private func updateModeUI() {
    let isRegister = currentMode == .register
    registrationServerView.isHidden = !isRegister
    registrationHandlePreviewLabel.isHidden = !isRegister
    seedPhraseField.isHidden = isRegister
    linkDeviceButton.isHidden = isRegister
    submitButton.setTitle(isRegister ? "Создать аккаунт" : "Войти", for: .normal)
    setHandleFieldPresentation(isRegister: isRegister)
    updateRegistrationHandlePreview()
  }

  private var currentMode: AuthViewModel.Mode {
    modeControl.selectedSegmentIndex == 1 ? .register : .login
  }

  @objc
  private func submitTapped() {
    let rawHandle: String = userHandleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let seedPhrase = seedPhraseField.text?.trimmingCharacters(in: .whitespacesAndNewlines)

    let handle: String
    switch currentMode {
    case .login:
      guard !rawHandle.isEmpty else {
        setErrorText("Введите TellMe ID в формате @user:domain")
        return
      }
      handle = rawHandle
    case .register:
      guard !rawHandle.isEmpty else {
        setErrorText("Укажите login для тестового сервера")
        return
      }
      guard let registrationHandle: String = TestServerConfiguration.userHandle(fromRegistrationInput: rawHandle) else {
        setErrorText("Введите login латиницей: можно использовать цифры, точку, дефис и подчёркивание")
        return
      }
      handle = registrationHandle
    }

    if currentMode == .login && (seedPhrase ?? "").isEmpty {
      setErrorText("Введите seed phrase")
      return
    }

    setLoading(true)

    Task {
      defer { setLoading(false) }

      do {
        let result = try await viewModel.submit(
          mode: currentMode,
          userHandle: handle,
          seedPhrase: seedPhrase
        )

        if let phrase = result.generatedSeedPhrase {
          presentSeedPhraseBackup(phrase, result: result)
          return
        }

        delegate?.authViewController(self, didAuthenticate: result)
      } catch {
        setErrorText(readableError(error, for: currentMode))
      }
    }
  }

  private func presentSeedPhraseBackup(_ phrase: String, result: AuthViewModel.AuthResult) {
    let backupViewController: SeedPhraseBackupViewController = SeedPhraseBackupViewController(seedPhrase: phrase) { [weak self] in
      guard let self else { return }
      self.delegate?.authViewController(self, didAuthenticate: result)
    }
    backupViewController.modalPresentationStyle = .fullScreen
    present(backupViewController, animated: true)
  }

  private func setLoading(_ loading: Bool) {
    submitButton.isEnabled = !loading
    linkDeviceButton.isEnabled = !loading
    modeControl.isEnabled = !loading
    userHandleField.isEnabled = !loading
    seedPhraseField.isEnabled = !loading

    if loading {
      activityView.startAnimating()
    } else {
      activityView.stopAnimating()
    }
  }

  private func setErrorText(_ message: String?) {
    errorLabel.text = message ?? Self.emptyErrorPlaceholder
    errorLabel.accessibilityValue = message ?? ""
  }

  private func readableError(_ error: Error, for mode: AuthViewModel.Mode) -> String {
    if let apiError: APIError = error as? APIError {
      switch apiError {
      case .server(_, let message):
        return message
      case .transport(let message):
        return message
      case .unauthorized:
        switch mode {
        case .login:
          return "Неверный handle или seed phrase"
        case .register:
          return "Ошибка регистрации. Попробуйте ещё раз."
        }
      default:
        return "Ошибка запроса"
      }
    }

    return error.localizedDescription
  }

  @objc
  private func linkDeviceTapped() {
    onOpenDeviceLink?()
  }

  private func configureRegistrationServerView() {
    let iconView: UIImageView = UIImageView(image: UIImage(systemName: "server.rack"))
    iconView.tintColor = TelegramStyle.accentColor
    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let captionLabel: UILabel = UILabel()
    captionLabel.text = "ТЕСТОВЫЙ СЕРВЕР"
    captionLabel.font = .systemFont(ofSize: 10, weight: .bold)
    captionLabel.textColor = TelegramStyle.accentColor

    let domainLabel: UILabel = UILabel()
    domainLabel.text = TestServerConfiguration.domain
    domainLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
    domainLabel.textColor = TelegramStyle.textPrimaryColor
    domainLabel.adjustsFontSizeToFitWidth = true
    domainLabel.minimumScaleFactor = 0.78
    domainLabel.accessibilityIdentifier = MessengerAccessibility.Label.authTestServer

    let labelsStackView: UIStackView = UIStackView(arrangedSubviews: [captionLabel, domainLabel])
    labelsStackView.axis = .vertical
    labelsStackView.spacing = 3

    let rowStackView: UIStackView = UIStackView(arrangedSubviews: [iconView, labelsStackView])
    rowStackView.axis = .horizontal
    rowStackView.alignment = .center
    rowStackView.spacing = 12
    rowStackView.translatesAutoresizingMaskIntoConstraints = false

    registrationServerView.backgroundColor = TelegramStyle.accentColor.withAlphaComponent(0.08)
    registrationServerView.layer.cornerRadius = 11
    registrationServerView.layer.borderWidth = 1
    registrationServerView.layer.borderColor = TelegramStyle.accentColor.withAlphaComponent(0.24).cgColor
    registrationServerView.addSubview(rowStackView)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 26),
      iconView.heightAnchor.constraint(equalToConstant: 26),

      rowStackView.leadingAnchor.constraint(equalTo: registrationServerView.leadingAnchor, constant: 12),
      rowStackView.trailingAnchor.constraint(equalTo: registrationServerView.trailingAnchor, constant: -12),
      rowStackView.topAnchor.constraint(equalTo: registrationServerView.topAnchor, constant: 10),
      rowStackView.bottomAnchor.constraint(equalTo: registrationServerView.bottomAnchor, constant: -10),
    ])
  }

  private func setHandleFieldPresentation(isRegister: Bool) {
    let placeholder: String = isRegister ? "Выберите login" : "@alice:example.org"
    userHandleField.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: TelegramStyle.textSecondaryColor.withAlphaComponent(0.9)]
    )

    if isRegister {
      let prefixContainer: UIView = UIView(frame: CGRect(x: 0, y: 0, width: 42, height: 44))
      let prefixLabel: UILabel = UILabel(frame: CGRect(x: 8, y: 0, width: 34, height: 44))
      prefixLabel.text = "@"
      prefixLabel.font = .systemFont(ofSize: 16, weight: .semibold)
      prefixLabel.textAlignment = .center
      prefixLabel.textColor = TelegramStyle.textSecondaryColor
      prefixContainer.addSubview(prefixLabel)
      userHandleField.leftView = prefixContainer
      return
    }

    userHandleField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
  }

  private func saveHandleDraft(for mode: AuthViewModel.Mode) {
    let value: String = userHandleField.text ?? ""
    switch mode {
    case .login:
      loginHandleDraft = value
    case .register:
      registrationLoginDraft = value
      if loginHandleDraft.isEmpty,
        let fullHandle: String = TestServerConfiguration.userHandle(fromRegistrationInput: value)
      {
        loginHandleDraft = fullHandle
      }
    }
  }

  @objc
  private func handleTextChanged() {
    saveHandleDraft(for: displayedMode)
    updateRegistrationHandlePreview()
  }

  private func updateRegistrationHandlePreview() {
    guard currentMode == .register else {
      return
    }

    let input: String = userHandleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !input.isEmpty else {
      registrationHandlePreviewLabel.text = "Ваш TellMe ID: \(TestServerConfiguration.handleTemplate)"
      registrationHandlePreviewLabel.textColor = TelegramStyle.textSecondaryColor
      return
    }

    if let handle: String = TestServerConfiguration.userHandle(fromRegistrationInput: input) {
      registrationHandlePreviewLabel.text = "Ваш TellMe ID: \(handle)"
      registrationHandlePreviewLabel.textColor = TelegramStyle.textSecondaryColor
    } else {
      registrationHandlePreviewLabel.text = "Login содержит недопустимые символы"
      registrationHandlePreviewLabel.textColor = TelegramStyle.warningColor
    }
  }
}
