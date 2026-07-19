import XCTest

final class PhysicalBackgroundConversationPushRegressionUITests: XCTestCase {
  private enum Role: String {
    case initiator
    case receiver
  }

  private struct Config {
    let runId: String
    let role: Role
    let userHandle: String
    let seedPhrase: String
    let targetUserHandle: String
    let apiBaseURL: String
    let webSocketBaseURL: String?
    let syncDelaySeconds: TimeInterval
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testBackgroundConversationPushRegressionInitiator() throws {
    try runScenario(expectedRole: .initiator)
  }

  @MainActor
  func testBackgroundConversationPushRegressionReceiver() throws {
    try runScenario(expectedRole: .receiver)
  }

  @MainActor
  private func runScenario(expectedRole: Role) throws {
    let config: Config = try loadConfig(expectedRole: expectedRole)
    let app: XCUIApplication = launchApp(config: config)

    if config.role == .initiator {
      try performInitiatorFlow(app: app, config: config)
    } else {
      try performReceiverFlow(app: app, config: config)
    }
  }

  @MainActor
  private func performInitiatorFlow(app: XCUIApplication, config: Config) throws {
    try loginIfNeeded(app: app, handle: config.userHandle, seedPhrase: config.seedPhrase)
    try openDirectConversation(app: app, peerHandle: config.targetUserHandle)
    waitForSynchronization(seconds: config.syncDelaySeconds)

    let message: String = uniqueMessage(runId: config.runId)
    let conversation = ConversationScreen(app: app)
    XCTAssertTrue(conversation.textInput.waitForExistence(timeout: 10))
    conversation.textInput.tap()
    conversation.textInput.typeText(message)
    conversation.sendButton.tap()
  }

  @MainActor
  private func performReceiverFlow(app: XCUIApplication, config: Config) throws {
    try loginIfNeeded(app: app, handle: config.userHandle, seedPhrase: config.seedPhrase)
    try openDirectConversation(app: app, peerHandle: config.targetUserHandle)

    XCUIDevice.shared.press(.home)

    let springboard: XCUIApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let notificationBody = springboard.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Новое защищённое сообщение")
    ).firstMatch

    XCTAssertTrue(
      notificationBody.waitForExistence(timeout: 45),
      "Expected visible push banner/body while app was backgrounded with the conversation open"
    )

    app.activate()
    dismissSystemAlerts(app: app)
    try ensureConversationVisible(
      app: app,
      handle: config.userHandle,
      seedPhrase: config.seedPhrase,
      peerHandle: config.targetUserHandle
    )

    let messageLabel = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", uniqueMessage(runId: config.runId))
    ).firstMatch
    XCTAssertTrue(
      messageLabel.waitForExistence(timeout: 30),
      "Expected synced message after returning from backgrounded conversation"
    )
  }

  @MainActor
  private func loginIfNeeded(app: XCUIApplication, handle: String, seedPhrase: String) throws {
    dismissSystemAlerts(app: app)

    let chats = ChatsScreen(app: app)
    let conversation = ConversationScreen(app: app)
    if chats.root.waitForExistence(timeout: 5) || conversation.root.waitForExistence(timeout: 5) {
      return
    }

    let auth = AuthScreen(app: app)
    auth.waitForVisible(timeout: 20)

    auth.handleInput.tap()
    auth.handleInput.typeText(handle)
    auth.seedInput.tap()
    auth.seedInput.typeText(seedPhrase)
    auth.submitButton.tap()

    dismissSystemAlerts(app: app)
    chats.waitForVisible(timeout: 30)
  }

  @MainActor
  private func openDirectConversation(app: XCUIApplication, peerHandle: String) throws {
    let chats = ChatsScreen(app: app)
    if !chats.root.waitForExistence(timeout: 5) {
      app.tabBars.buttons[UITestID.Button.tabChats].tap()
      chats.waitForVisible(timeout: 15)
    }

    chats.newChatButton.tap()

    let newChat = NewChatScreen(app: app)
    newChat.waitForVisible(timeout: 10)
    newChat.handleInput.tap()
    newChat.handleInput.typeText(peerHandle)
    newChat.openButton.tap()

    let conversation = ConversationScreen(app: app)
    XCTAssertTrue(
      conversation.textInput.waitForExistence(timeout: 20),
      "Expected direct conversation with \(peerHandle)"
    )
  }

  @MainActor
  private func ensureConversationVisible(
    app: XCUIApplication,
    handle: String,
    seedPhrase: String,
    peerHandle: String
  ) throws {
    let conversation = ConversationScreen(app: app)
    if conversation.textInput.waitForExistence(timeout: 10) {
      return
    }

    try loginIfNeeded(app: app, handle: handle, seedPhrase: seedPhrase)
    try openDirectConversation(app: app, peerHandle: peerHandle)
  }

  private func launchApp(config: Config) -> XCUIApplication {
    let app: XCUIApplication = XCUIApplication()
    app.launchEnvironment["UITEST_MODE"] = "1"
    app.launchEnvironment["UITEST_STORAGE_NAMESPACE"] = "background-conversation-push-\(config.runId)-\(config.role.rawValue)"
    app.launchEnvironment["UITEST_RESET_STATE"] = "1"
    app.launchEnvironment["UITEST_BOOTSTRAP_SAMPLE_DATA"] = "0"
    app.launchEnvironment["UITEST_STUB_NETWORK"] = "0"
    app.launchEnvironment["UITEST_DISABLE_REALTIME"] = "0"
    app.launchEnvironment["UITEST_REQUEST_NOTIFICATIONS"] = "1"
    app.launchEnvironment["MESSENGER_APP_ENV"] = "production"
    app.launchEnvironment["E2E_API_BASE_URL"] = config.apiBaseURL
    if let webSocketBaseURL: String = config.webSocketBaseURL, !webSocketBaseURL.isEmpty {
      app.launchEnvironment["E2E_WS_BASE_URL"] = webSocketBaseURL
    }
    app.launch()
    return app
  }

  private func loadConfig(expectedRole: Role) throws -> Config {
    let processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    let bundledConfig: [String: String] = Self.loadBundledRoleConfig(role: expectedRole.rawValue)
    let environment: [String: String] = bundledConfig.merging(processEnvironment) { _, process in process }

    guard readBool(environment["E2E_RUN_LIVE_BACKGROUND_CONVERSATION_PUSH"]) else {
      throw XCTSkip("Set E2E_RUN_LIVE_BACKGROUND_CONVERSATION_PUSH=1 to execute the background-conversation push regression test.")
    }

    guard let roleRaw: String = environment["E2E_ROLE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      let role: Role = Role(rawValue: roleRaw),
      role == expectedRole
    else {
      throw XCTSkip("This physical regression test is running for a different role.")
    }

    guard let userHandle: String = environment["E2E_USER_HANDLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !userHandle.isEmpty,
      let seedPhrase: String = environment["E2E_SEED_PHRASE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !seedPhrase.isEmpty,
      let targetUserHandle: String = environment["E2E_TARGET_USER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !targetUserHandle.isEmpty,
      let apiBaseURL: String = environment["E2E_API_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !apiBaseURL.isEmpty
    else {
      XCTFail("Missing required E2E_* environment for background-conversation push regression")
      throw XCTSkip("Missing required E2E_* environment")
    }

    let runId: String = environment["E2E_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? environment["E2E_RUN_ID"]!.trimmingCharacters(in: .whitespacesAndNewlines)
      : UUID().uuidString.lowercased()

    return Config(
      runId: runId,
      role: role,
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      targetUserHandle: targetUserHandle,
      apiBaseURL: apiBaseURL,
      webSocketBaseURL: environment["E2E_WS_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      syncDelaySeconds: readDouble(environment["E2E_SYNC_DELAY_SECONDS"], defaultValue: 20)
    )
  }

  private func dismissSystemAlerts(app: XCUIApplication) {
    if tapAllowButton(in: app.alerts.firstMatch) {
      return
    }

    let springboard: XCUIApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    _ = tapAllowButton(in: springboard.alerts.firstMatch)
  }

  private func tapAllowButton(in alert: XCUIElement) -> Bool {
    guard alert.exists else {
      return false
    }

    let preferredTitles: [String] = [
      "Allow",
      "Allow While Using App",
      "Allow While Using the App",
      "OK",
      "Continue",
      "Разрешить",
      "Разрешить при использовании приложения",
      "При использовании приложения",
      "ОК",
      "Продолжить",
    ]

    for title in preferredTitles {
      let button: XCUIElement = alert.buttons[title]
      if button.exists, button.isHittable {
        button.tap()
        return true
      }
    }

    return false
  }

  private func uniqueMessage(runId: String) -> String {
    "background-conversation-push-\(runId)"
  }

  private func waitForSynchronization(seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(max(0, seconds)))
  }

  private func readBool(_ rawValue: String?) -> Bool {
    guard let rawValue else {
      return false
    }

    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    default:
      return false
    }
  }

  private func readDouble(_ value: String?, defaultValue: TimeInterval) -> TimeInterval {
    guard let value,
      let parsed: Double = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
      parsed >= 0
    else {
      return defaultValue
    }

    return parsed
  }

  private static func loadBundledRoleConfig(role: String) -> [String: String] {
    guard let url: URL = Bundle(for: Self.self).url(forResource: "dual_iphone_runtime_config", withExtension: "json"),
      let data: Data = try? Data(contentsOf: url),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: Any] = object as? [String: Any],
      let rolePayload: [String: String] = payload[role] as? [String: String]
    else {
      return [:]
    }

    return rolePayload
  }
}
