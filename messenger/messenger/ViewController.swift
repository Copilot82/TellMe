import UIKit

final class ViewController: UIViewController {
  private let container: AppContainer
  private let viewModel: MessengerViewModel

  private let scrollView: UIScrollView = UIScrollView()
  private let stackView: UIStackView = UIStackView()

  private let userHandleField: UITextField = ViewController.makeTextField(
    placeholder: "User Handle (@user:domain)",
    defaultText: "@ios_user:localhost"
  )

  private let seedPhraseField: UITextField = ViewController.makeTextField(
    placeholder: "Seed Phrase (for login)",
    defaultText: ""
  )

  private let targetUserIdField: UITextField = ViewController.makeTextField(
    placeholder: "Target User ID",
    defaultText: ""
  )

  private let messageField: UITextField = ViewController.makeTextField(
    placeholder: "Message",
    defaultText: "Hello from iOS MVP"
  )

  private let statusLabel: UILabel = {
    let label: UILabel = UILabel()
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    return label
  }()

  private let automationStatusLabel: UILabel = {
    let label: UILabel = UILabel()
    label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
    label.textColor = .systemOrange
    label.numberOfLines = 0
    label.text = "AUTOMATION_IDLE"
    return label
  }()

  private let logTextView: UITextView = {
    let textView: UITextView = UITextView()
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.isEditable = false
    textView.isAccessibilityElement = true
    textView.accessibilityLabel = "Automation log"
    textView.accessibilityTraits = .staticText
    textView.backgroundColor = UIColor.secondarySystemBackground
    textView.layer.cornerRadius = 10
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    textView.heightAnchor.constraint(equalToConstant: 260).isActive = true
    return textView
  }()

  private let automationCallPanel: UIView = UIView()
  private let automationCallTitleLabel: UILabel = UILabel()
  private let automationCallStatusLabel: UILabel = UILabel()

  private var automationStarted: Bool = false
  private lazy var automationConfiguration: E2EAutomationConfiguration? = E2EAutomationConfiguration.fromProcessEnvironment()
  private var automationRunner: AutomationRunner?
  private var automationCallViewController: E2ECallViewController?

  init(container: AppContainer) {
    self.container = container
    self.viewModel = MessengerViewModel(container: container)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Federated Messenger MVP"
    view.backgroundColor = .systemBackground

    configureLayout()
    configureAccessibilityIdentifiers()
    bindViewModel()
    updateStatus()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startAutomationIfNeeded()
  }

  private func bindViewModel() {
    viewModel.onLogUpdate = { [weak self] line in
      guard let self else { return }
      self.appendLog(line)
    }

    viewModel.onStateUpdate = { [weak self] in
      self?.updateStatus()
    }
  }

  private func configureLayout() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stackView.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(scrollView)
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
      stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
      stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
      stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
    ])

    stackView.axis = .vertical
    stackView.spacing = 10

    addSectionTitle("Auth")
    addArranged([userHandleField, seedPhraseField])
    addButtonRow([
      makeActionButton("Register", identifier: "registerButton", action: #selector(registerTapped)),
      makeActionButton("Login", identifier: "loginButton", action: #selector(loginTapped)),
      makeActionButton("Refresh", identifier: "refreshButton", action: #selector(refreshTapped)),
      makeActionButton("Logout", identifier: "logoutButton", action: #selector(logoutTapped)),
    ])

    addSectionTitle("Realtime")
    addButtonRow([
      makeActionButton("Socket Connect", identifier: "socketConnectButton", action: #selector(connectSocketTapped)),
      makeActionButton("Load Conversations", identifier: "loadConversationsButton", action: #selector(loadConversationsTapped)),
    ])

    addSectionTitle("Messaging")
    addArranged([targetUserIdField, messageField])
    addButtonRow([
      makeActionButton("Create Direct", identifier: "createDirectButton", action: #selector(createDirectTapped)),
      makeActionButton("Load Messages", identifier: "loadMessagesButton", action: #selector(loadMessagesTapped)),
      makeActionButton("Send Message", identifier: "sendMessageButton", action: #selector(sendMessageTapped)),
    ])

    addSectionTitle("Calls")
    addButtonRow([
      makeActionButton("Start Voice Call", identifier: "startCallButton", action: #selector(startCallTapped)),
      makeActionButton("End Call", identifier: "endCallButton", action: #selector(endCallTapped)),
      makeActionButton("Register APNS", identifier: "registerApnsButton", action: #selector(registerDeviceTapped)),
    ])

    addSectionTitle("State")
    stackView.addArrangedSubview(statusLabel)

    addSectionTitle("Automation")
    configureAutomationCallPanel()
    stackView.addArrangedSubview(automationStatusLabel)
    stackView.addArrangedSubview(automationCallPanel)

    addSectionTitle("Logs")
    stackView.addArrangedSubview(logTextView)
  }

  private func configureAccessibilityIdentifiers() {
    userHandleField.accessibilityIdentifier = "userHandleField"
    seedPhraseField.accessibilityIdentifier = "seedPhraseField"
    targetUserIdField.accessibilityIdentifier = "targetUserIdField"
    messageField.accessibilityIdentifier = "messageField"

    statusLabel.accessibilityIdentifier = "statusLabel"
    automationStatusLabel.accessibilityIdentifier = "automationStatusLabel"
    logTextView.accessibilityIdentifier = "logTextView"
  }

  private func addSectionTitle(_ title: String) {
    let label: UILabel = UILabel()
    label.text = title
    label.font = .preferredFont(forTextStyle: .headline)
    stackView.addArrangedSubview(label)
  }

  private func addArranged(_ views: [UIView]) {
    for view in views {
      stackView.addArrangedSubview(view)
    }
  }

  private func addButtonRow(_ buttons: [UIButton]) {
    let row: UIStackView = UIStackView(arrangedSubviews: buttons)
    row.axis = .vertical
    row.spacing = 8
    row.distribution = .fillEqually
    stackView.addArrangedSubview(row)
  }

  private func makeActionButton(_ title: String, identifier: String, action: Selector) -> UIButton {
    let button: UIButton = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.accessibilityIdentifier = identifier
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.backgroundColor = .systemBlue
    button.tintColor = .white
    button.layer.cornerRadius = 8
    button.heightAnchor.constraint(equalToConstant: 42).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func appendLog(_ line: String) {
    let previous: String = logTextView.text ?? ""
    let next: String
    if previous.isEmpty {
      next = line
    } else {
      next = previous + "\n" + line
    }

    let lines: [Substring] = next.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > 300 {
      logTextView.text = lines.suffix(300).joined(separator: "\n")
    } else {
      logTextView.text = next
    }

    let range: NSRange = NSRange(location: max(logTextView.text.count - 1, 0), length: 1)
    logTextView.accessibilityValue = logTextView.text
    logTextView.scrollRangeToVisible(range)
  }

  private func updateStatus() {
    let userInfo: String = viewModel.currentUser?.id ?? "not logged in"
    let conversation: String = viewModel.activeConversationId ?? "none"
    let call: String = viewModel.activeCallId ?? "none"
    let rtc: String = viewModel.latestRTCConfig == nil ? "no" : "yes"
    let incomingCall: String = viewModel.lastIncomingCallId ?? "none"

    statusLabel.text = "User: \(userInfo)\nConversation: \(conversation)\nActive call: \(call)\nIncoming call: \(incomingCall)\nSocket: \(socketStateDescription(viewModel.socketState))\nRTC config received: \(rtc)"
  }

  private func socketStateDescription(_ state: SocketConnectionState) -> String {
    switch state {
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .failed(let message):
      return "failed (\(message))"
    }
  }

  private func setAutomationState(_ value: String, color: UIColor) {
    automationStatusLabel.text = value
    automationStatusLabel.textColor = color
    automationStatusLabel.accessibilityValue = value
    updateAutomationCallPanel(state: value)
  }

  private func configureAutomationCallPanel() {
    automationCallPanel.backgroundColor = UIColor.black
    automationCallPanel.layer.cornerRadius = 18
    automationCallPanel.layer.borderWidth = 1
    automationCallPanel.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.45).cgColor
    automationCallPanel.isHidden = true
    automationCallPanel.accessibilityIdentifier = MessengerAccessibility.Screen.automationCall

    automationCallTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    automationCallTitleLabel.textColor = .white
    automationCallTitleLabel.textAlignment = .center
    automationCallTitleLabel.adjustsFontSizeToFitWidth = true
    automationCallTitleLabel.minimumScaleFactor = 0.72

    automationCallStatusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    automationCallStatusLabel.textColor = UIColor.white.withAlphaComponent(0.78)
    automationCallStatusLabel.textAlignment = .center
    automationCallStatusLabel.numberOfLines = 0
    automationCallStatusLabel.accessibilityIdentifier = MessengerAccessibility.Label.callStatus

    let toneLabel = UILabel()
    toneLabel.text = "Контрольный гудок включен после media-ready"
    toneLabel.font = .systemFont(ofSize: 13, weight: .medium)
    toneLabel.textColor = UIColor.systemGreen
    toneLabel.textAlignment = .center
    toneLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [automationCallTitleLabel, automationCallStatusLabel, toneLabel])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    automationCallPanel.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: automationCallPanel.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: automationCallPanel.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: automationCallPanel.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: automationCallPanel.bottomAnchor, constant: -18),
      automationCallPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
    ])
  }

  private func updateAutomationCallPanel(state: String) {
    guard state.contains("AUTOMATION_CALL_") else {
      if state.contains("AUTOMATION_SUCCESS") || state.contains("AUTOMATION_FAILED") {
        automationCallPanel.isHidden = true
      }
      return
    }

    automationCallPanel.isHidden = false
    let type: String = automationField("type", in: state) ?? "call"
    let phase: String
    if state.contains("AUTOMATION_CALL_ACTIVE") {
      phase = "Соединено"
      automationCallPanel.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.7).cgColor
    } else if state.contains("AUTOMATION_CALL_ENDED") {
      phase = "Завершено"
      automationCallPanel.layer.borderColor = UIColor.systemGray.withAlphaComponent(0.7).cgColor
    } else {
      phase = "Подключение"
      automationCallPanel.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
    }

    automationCallTitleLabel.text = "\(phase): \(type == "video" ? "видеозвонок" : "аудиозвонок")"
    automationCallStatusLabel.text = state
  }

  private func automationField(_ key: String, in state: String) -> String? {
    let prefix = "\(key)="
    guard let range = state.range(of: prefix) else {
      return nil
    }

    let suffix = state[range.upperBound...]
    let token = suffix.split(separator: " ").first.map(String.init) ?? ""
    return token.isEmpty ? nil : token
  }

  private func startAutomationIfNeeded() {
    guard !automationStarted else {
      return
    }

    guard let config: E2EAutomationConfiguration = automationConfiguration else {
      return
    }

    automationStarted = true
    applyAutomationConfiguration(config)
    let runner: AutomationRunner = AutomationRunner(
      container: container,
      viewModel: viewModel,
      configuration: config,
      logHandler: { [weak self] line in
        self?.appendLog(line)
      },
      stateHandler: { [weak self] state, color in
        self?.setAutomationState(state, color: color)
      },
      callScreenPresenter: { [weak self] session in
        self?.presentAutomationCallScreen(session) ?? false
      }
    )
    automationRunner = runner

    Task {
      await runner.run()
    }
  }

  private func applyAutomationConfiguration(_ config: E2EAutomationConfiguration) {
    userHandleField.text = config.userHandle
    seedPhraseField.text = config.seedPhrase
    targetUserIdField.text = config.targetUserId
    messageField.text = config.message
  }

  private func presentAutomationCallScreen(_ session: E2ECallSessionViewModel) -> Bool {
    let retainedSession: E2ECallSessionViewModel = container.e2eCallSessionStore.retain(session)

    if automationCallViewController?.activeCallId == retainedSession.activeCallId {
      return true
    }

    dismissAutomationCallScreen()

    let controller = E2ECallViewController(
      viewModel: retainedSession,
      shouldAutoStart: true
    )
    controller.view.translatesAutoresizingMaskIntoConstraints = false

    addChild(controller)
    controller.beginAppearanceTransition(true, animated: false)
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.endAppearanceTransition()
    controller.didMove(toParent: self)
    automationCallViewController = controller
    return true
  }

  private func dismissAutomationCallScreen() {
    guard let controller: E2ECallViewController = automationCallViewController else {
      return
    }

    controller.willMove(toParent: nil)
    controller.beginAppearanceTransition(false, animated: false)
    controller.view.removeFromSuperview()
    controller.endAppearanceTransition()
    controller.removeFromParent()
    automationCallViewController = nil
  }

  @objc
  private func registerTapped() {
    Task {
      await viewModel.register(userHandle: userHandleField.text ?? "")
    }
  }

  @objc
  private func loginTapped() {
    Task {
      await viewModel.login(
        userHandle: userHandleField.text ?? "",
        seedPhrase: seedPhraseField.text
      )
    }
  }

  @objc
  private func refreshTapped() {
    Task {
      await viewModel.refreshSession()
    }
  }

  @objc
  private func logoutTapped() {
    Task {
      await viewModel.logout()
    }
  }

  @objc
  private func connectSocketTapped() {
    Task {
      await viewModel.connectSocket()
    }
  }

  @objc
  private func loadConversationsTapped() {
    Task {
      await viewModel.loadConversations()
    }
  }

  @objc
  private func createDirectTapped() {
    Task {
      await viewModel.createDirectConversation(with: targetUserIdField.text ?? "")
    }
  }

  @objc
  private func loadMessagesTapped() {
    Task {
      await viewModel.loadMessages()
    }
  }

  @objc
  private func sendMessageTapped() {
    Task {
      await viewModel.sendMessage(messageField.text ?? "")
    }
  }

  @objc
  private func startCallTapped() {
    Task {
      await viewModel.startVoiceCall(receiverId: targetUserIdField.text ?? "")
    }
  }

  @objc
  private func endCallTapped() {
    Task {
      await viewModel.endCurrentCall()
    }
  }

  @objc
  private func registerDeviceTapped() {
    Task {
      await viewModel.registerDummyDeviceToken()
    }
  }

  private static func makeTextField(placeholder: String, defaultText: String) -> UITextField {
    let field: UITextField = UITextField()
    field.placeholder = placeholder
    field.text = defaultText
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.borderStyle = .roundedRect
    return field
  }
}
