import XCTest

final class PhysicalRealCallRegressionUITests: XCTestCase {
  private enum Role: String {
    case initiator
    case receiver
  }

  private enum ReceiverAppState: String {
    case foregroundChatList = "foreground_chat_list"
    case backgroundChatList = "background_chat_list"
  }

  private enum AuthMode: String {
    case login
    case register
  }

  private struct Config {
    let runId: String
    let role: Role
    let authMode: AuthMode
    let userHandle: String
    let seedPhrase: String
    let targetUserHandle: String
    let apiBaseURL: String
    let webSocketBaseURL: String?
    let receiverAppState: ReceiverAppState
    let resetState: Bool
    let startupDelaySeconds: TimeInterval
    let postAuthDelaySeconds: TimeInterval
    let setupDelaySeconds: TimeInterval
    let incomingCallWaitSeconds: TimeInterval
    let connectedTimeoutSeconds: TimeInterval
    let validatePictureInPicture: Bool
    let pictureInPictureDelaySeconds: TimeInterval
  }

  private static let initiatorHostConfigPath: String = "/tmp/messenger-realcall-initiator-config.json"
  private static let receiverHostConfigPath: String = "/tmp/messenger-realcall-receiver-config.json"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testRealCallUIInitiator() throws {
    try runLiveRealCallRegression(expectedRole: .initiator)
  }

  @MainActor
  func testRealCallUIReceiver() throws {
    try runLiveRealCallRegression(expectedRole: .receiver)
  }

  @MainActor
  private func runLiveRealCallRegression(expectedRole: Role) throws {
    let config: Config = try loadConfig(expectedRole: expectedRole)
    waitForSynchronization(seconds: config.startupDelaySeconds)

    let app: XCUIApplication = launchApp(config: config)
    dismissSystemAlerts(app: app)

    if config.role == .initiator {
      try performInitiatorFlow(app: app, config: config)
    } else {
      try performReceiverFlow(app: app, config: config)
    }
  }

  @MainActor
  private func performInitiatorFlow(app: XCUIApplication, config: Config) throws {
    try loginIfNeeded(app: app, config: config)
    waitForSynchronization(seconds: config.postAuthDelaySeconds)
    try openDirectConversation(app: app, peerHandle: config.targetUserHandle)
    waitForConversationProtected(app: app, timeout: 35)
    waitForSynchronization(seconds: config.setupDelaySeconds)

    let conversation = ConversationScreen(app: app)
    XCTAssertTrue(conversation.startCallButton.waitForExistence(timeout: 20), "Missing conversation call button")
    conversation.startCallButton.tap()

    let videoCallButton: XCUIElement = app.buttons["Видеозвонок"].firstMatch
    XCTAssertTrue(videoCallButton.waitForExistence(timeout: 10), "Missing video call action")
    videoCallButton.tap()

    let call: ActiveCallScreen = waitForActiveCallScreen(app: app, timeout: 30)
    XCTAssertTrue(call.remoteVideoView.exists, "Missing real call remote video view")
    waitForConnectedCall(call, timeout: config.connectedTimeoutSeconds)

    if config.validatePictureInPicture {
      try validatePictureInPictureStartsFromRealCallUI(
        app: app,
        call: call,
        delaySeconds: config.pictureInPictureDelaySeconds
      )
    }
  }

  @MainActor
  private func performReceiverFlow(app: XCUIApplication, config: Config) throws {
    try loginIfNeeded(app: app, config: config)
    waitForSynchronization(seconds: config.postAuthDelaySeconds)
    try openDirectConversation(app: app, peerHandle: config.targetUserHandle)
    waitForConversationProtected(app: app, timeout: 35)
    goBack(in: app)

    let chats = ChatsScreen(app: app)
    chats.waitForVisible(timeout: 15)
    prepareReceiverForIncomingCall(app: app, state: config.receiverAppState)

    waitForSynchronization(seconds: config.incomingCallWaitSeconds)
    restoreReceiverApp(app: app, state: config.receiverAppState)
    dismissSystemAlerts(app: app)

    let call: ActiveCallScreen = waitForActiveCallScreen(app: app, timeout: 30)
    XCTAssertTrue(call.remoteVideoView.exists, "Missing receiver real call remote video view")
    waitForConnectedCall(call, timeout: config.connectedTimeoutSeconds)

    let diagnostics: String = call.diagnosticsValue
    if config.receiverAppState == .backgroundChatList {
      XCTAssertTrue(
        diagnostics.contains("incoming=appState=background") || diagnostics.contains("incoming=appState=inactive"),
        "Expected incoming call to be reported while receiver app was backgrounded. Diagnostics: \(diagnostics)"
      )
    }
  }

  @MainActor
  private func validatePictureInPictureStartsFromRealCallUI(
    app: XCUIApplication,
    call: ActiveCallScreen,
    delaySeconds: TimeInterval
  ) throws {
    XCTAssertTrue(call.diagnosticsValue.contains("pip="), "Missing initial PiP diagnostics")

    XCUIDevice.shared.press(.home)
    waitForSynchronization(seconds: delaySeconds)
    app.activate()
    dismissSystemAlerts(app: app)

    call.waitForVisible(timeout: 20)
    let diagnostics: String = call.diagnosticsValue
    XCTAssertTrue(
      diagnostics.contains("call_pip_did_start"),
      "Expected system PiP to start from real call UI while app was backgrounded. Diagnostics: \(diagnostics)"
    )
  }

  private func launchApp(config: Config) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["UITEST_MODE"] = "1"
    app.launchEnvironment["UITEST_STORAGE_NAMESPACE"] = "real-call-\(config.runId)-\(config.role.rawValue)"
    app.launchEnvironment["UITEST_RESET_STATE"] = config.resetState ? "1" : "0"
    app.launchEnvironment["UITEST_BOOTSTRAP_SAMPLE_DATA"] = "0"
    app.launchEnvironment["UITEST_STUB_NETWORK"] = "0"
    app.launchEnvironment["UITEST_DISABLE_REALTIME"] = "0"
    app.launchEnvironment["UITEST_REQUEST_NOTIFICATIONS"] = "1"
    app.launchEnvironment["MESSENGER_APP_ENV"] = "production"
    app.launchEnvironment["E2E_API_BASE_URL"] = config.apiBaseURL
    app.launchEnvironment["E2E_AUTO_ACCEPT_INCOMING_CALL"] = config.role == .receiver ? "1" : "0"
    app.launchEnvironment["E2E_AUTO_PROTECT_CONVERSATION"] = "1"
    if let webSocketBaseURL: String = config.webSocketBaseURL, !webSocketBaseURL.isEmpty {
      app.launchEnvironment["E2E_WS_BASE_URL"] = webSocketBaseURL
    }
    app.launch()
    return app
  }

  @MainActor
  private func loginIfNeeded(app: XCUIApplication, config: Config) throws {
    dismissSystemAlerts(app: app)
    OnboardingScreen(app: app).completeIfVisible()

    let chats = ChatsScreen(app: app)
    if chats.root.waitForExistence(timeout: 5) {
      return
    }

    let auth = AuthScreen(app: app)
    auth.waitForVisible(timeout: 20)
    if config.authMode == .register {
      let registerSegment: XCUIElement = auth.modeControl.buttons["Регистрация"]
      XCTAssertTrue(registerSegment.waitForExistence(timeout: 5), "Missing registration auth segment")
      registerSegment.tap()
    }

    auth.handleInput.tap()
    auth.handleInput.typeText(config.userHandle)
    if config.authMode == .login {
      auth.seedInput.tap()
      auth.seedInput.typeText(config.seedPhrase)
    }
    auth.submitButton.tap()

    dismissSystemAlerts(app: app)
    if config.authMode == .register {
      let seedConfirmButton: XCUIElement = app.buttons[UITestID.Button.authSeedConfirm]
      if seedConfirmButton.waitForExistence(timeout: 30) {
        seedConfirmButton.tap()
      } else {
        let russianConfirmButton: XCUIElement = app.alerts.buttons["Я сохранил"]
        XCTAssertTrue(russianConfirmButton.waitForExistence(timeout: 5), "Missing registration seed confirmation alert")
        russianConfirmButton.tap()
      }
    }
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
    newChat.waitForVisible(timeout: 15)
    newChat.handleInput.tap()
    newChat.handleInput.typeText(peerHandle)
    newChat.openButton.tap()

    let conversation = ConversationScreen(app: app)
    XCTAssertTrue(
      conversation.textInput.waitForExistence(timeout: 30),
      "Expected direct conversation with \(peerHandle)"
    )
  }

  @MainActor
  private func prepareReceiverForIncomingCall(app: XCUIApplication, state: ReceiverAppState) {
    switch state {
    case .foregroundChatList:
      return
    case .backgroundChatList:
      XCUIDevice.shared.press(.home)
    }
  }

  @MainActor
  private func restoreReceiverApp(app: XCUIApplication, state: ReceiverAppState) {
    switch state {
    case .foregroundChatList, .backgroundChatList:
      app.activate()
    }
  }

  @MainActor
  private func waitForActiveCallScreen(app: XCUIApplication, timeout: TimeInterval) -> ActiveCallScreen {
    let call = ActiveCallScreen(app: app)
    let deadline: Date = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      dismissSystemAlerts(app: app)
      if call.root.exists {
        return call
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    XCTFail("Active call screen did not appear")
    return call
  }

  @MainActor
  private func waitForConnectedCall(_ call: ActiveCallScreen, timeout: TimeInterval) {
    let deadline: Date = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let label: String = call.statusLabel.label
      if label.contains("Соединено") {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    XCTFail("Call did not reach connected state. Status: \(call.statusLabel.label). Diagnostics: \(call.diagnosticsValue)")
  }

  @MainActor
  private func waitForConversationProtected(app: XCUIApplication, timeout: TimeInterval) {
    let conversation = ConversationScreen(app: app)
    let deadline: Date = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if conversation.startCallButton.exists, !conversation.banner.exists {
        return
      }
      dismissSystemAlerts(app: app)
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    XCTFail("Conversation did not reach protected trust state before call start")
  }

  private func loadConfig(expectedRole: Role) throws -> Config {
    let processEnvironment: [String: String] = ProcessInfo.processInfo.environment
#if targetEnvironment(simulator)
    let hostConfig: [String: String] = [:]
    let bundledConfig: [String: String] = [:]
#else
    let hostConfig: [String: String] = Self.loadHostConfig(role: expectedRole)
    let bundledConfig: [String: String] = Self.loadBundledRoleConfig(role: expectedRole.rawValue)
#endif
    let environment: [String: String] = bundledConfig
      .merging(hostConfig) { _, host in host }
      .merging(processEnvironment) { _, process in process }
    guard readBool(environment["E2E_RUN_LIVE_REAL_CALL_UI"]) else {
      throw XCTSkip("Set E2E_RUN_LIVE_REAL_CALL_UI=1 to execute the physical real-call UI regression test.")
    }

    guard let roleRaw: String = environment["E2E_ROLE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      let role: Role = Role(rawValue: roleRaw),
      role == expectedRole
    else {
      throw XCTSkip("This physical regression test is running for a different role.")
    }

    let authModeRaw: String = environment["E2E_AUTH_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let authMode: AuthMode = AuthMode(rawValue: authModeRaw) ?? .login

    guard let userHandle: String = environment["E2E_USER_HANDLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !userHandle.isEmpty,
      let targetUserHandle: String = environment["E2E_TARGET_USER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !targetUserHandle.isEmpty,
      let apiBaseURL: String = environment["E2E_API_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !apiBaseURL.isEmpty
    else {
      XCTFail("Missing E2E credentials or backend URLs for physical real-call UI regression")
      throw XCTSkip("Missing required E2E_* environment")
    }
    let seedPhrase: String = environment["E2E_SEED_PHRASE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if authMode == .login, seedPhrase.isEmpty {
      XCTFail("E2E_SEED_PHRASE is required for physical real-call UI login mode")
      throw XCTSkip("Missing required E2E_SEED_PHRASE")
    }

    let runId: String = environment["E2E_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? environment["E2E_RUN_ID"]!.trimmingCharacters(in: .whitespacesAndNewlines)
      : UUID().uuidString.lowercased()
    let receiverAppState = ReceiverAppState(
      rawValue: environment["E2E_RECEIVER_APP_STATE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    ) ?? .backgroundChatList

    return Config(
      runId: runId,
      role: role,
      authMode: authMode,
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      targetUserHandle: targetUserHandle,
      apiBaseURL: apiBaseURL,
      webSocketBaseURL: environment["E2E_WS_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      receiverAppState: receiverAppState,
      resetState: readBool(environment["E2E_RESET_STATE"] ?? "1"),
      startupDelaySeconds: readDouble(environment["E2E_STARTUP_DELAY_SECONDS"], defaultValue: 0),
      postAuthDelaySeconds: readDouble(environment["E2E_POST_AUTH_DELAY_SECONDS"], defaultValue: 8),
      setupDelaySeconds: readDouble(environment["E2E_SYNC_DELAY_SECONDS"], defaultValue: 16),
      incomingCallWaitSeconds: readDouble(environment["E2E_INCOMING_CALL_WAIT_SECONDS"], defaultValue: 32),
      connectedTimeoutSeconds: readDouble(environment["E2E_CALL_CONNECTED_TIMEOUT_SECONDS"], defaultValue: 90),
      validatePictureInPicture: readBool(environment["E2E_VALIDATE_CALL_PIP_BACKGROUND"]),
      pictureInPictureDelaySeconds: readDouble(environment["E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS"], defaultValue: 6)
    )
  }

  private func dismissSystemAlerts(app: XCUIApplication) {
    if tapAllowButton(in: app.alerts.firstMatch) {
      return
    }

    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    _ = tapAllowButton(in: springboard.alerts.firstMatch)
  }

  private func tapAllowButton(in alert: XCUIElement) -> Bool {
    guard alert.exists else {
      return false
    }

    for title in ["Allow", "OK", "Continue", "Разрешить", "Продолжить"] {
      let button = alert.buttons[title]
      if button.exists {
        button.tap()
        return true
      }
    }
    return false
  }

  private func waitForSynchronization(seconds: TimeInterval) {
    guard seconds > 0 else {
      return
    }

    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func readBool(_ value: String?) -> Bool {
    guard let value else {
      return false
    }

    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

  private static func loadHostConfig(role: Role) -> [String: String] {
    let path: String
    switch role {
    case .initiator:
      path = initiatorHostConfigPath
    case .receiver:
      path = receiverHostConfigPath
    }

    guard let data: Data = FileManager.default.contents(atPath: path),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let dictionary: [String: Any] = object as? [String: Any]
    else {
      return [:]
    }

    var result: [String: String] = [:]
    for (key, value) in dictionary {
      if let stringValue: String = value as? String {
        result[key] = stringValue
      } else if let numberValue: NSNumber = value as? NSNumber {
        result[key] = numberValue.stringValue
      }
    }
    return result
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
