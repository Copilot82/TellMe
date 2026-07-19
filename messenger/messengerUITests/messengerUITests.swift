import XCTest

final class messengerUITests: XCTestCase {
  private let forwardedKeys: [String] = [
    "E2E_ROLE",
    "E2E_AUTH_MODE",
    "E2E_RUN_ID",
    "E2E_USER_HANDLE",
    "E2E_SEED_PHRASE",
    "E2E_TARGET_USER_ID",
    "E2E_MESSAGE",
    "E2E_STARTUP_DELAY_SECONDS",
    "E2E_AUTOMATION_TIMEOUT_SECONDS",
    "E2E_SOCKET_TIMEOUT_SECONDS",
    "E2E_CONVERSATION_TIMEOUT_SECONDS",
    "E2E_CALL_TIMEOUT_SECONDS",
    "E2E_CALL_DURATION_SECONDS",
    "E2E_CALL_TYPE",
    "E2E_MEDIA_TIMEOUT_SECONDS",
    "E2E_MEDIA_MIN_BYTES",
    "E2E_API_BASE_URL",
    "E2E_WS_BASE_URL",
    "E2E_PERFORM_REFRESH",
    "E2E_PERFORM_CALL_FLOW",
    "E2E_PERFORM_PUSH",
    "E2E_PERFORM_DEVICE_LINK",
    "E2E_DEVICE_LIFECYCLE_ONLY",
    "E2E_PERFORM_SETTINGS",
    "E2E_PERFORM_SETTINGS_LOGOUT",
    "E2E_SETTINGS_ONLY",
    "E2E_RECEIVER_SEND_REPLY",
    "E2E_PERFORM_ATTACHMENTS",
    "E2E_PERFORM_VOICE_MESSAGES",
    "E2E_PERFORM_BLOCK",
    "E2E_PERFORM_DELETE_CHAT",
    "E2E_REQUIRE_NEW_DEVICE_SYNC",
    "E2E_VALIDATE_CALL_PIP_BACKGROUND",
    "E2E_VALIDATE_CALL_PIP_ROLE",
    "E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS",
    "E2E_CALL_PIP_MANUAL_START_BEFORE_BACKGROUND",
    "E2E_CALL_PIP_TAP_BUTTON_BEFORE_BACKGROUND",
    "E2E_CALL_PIP_SOURCE_MODE",
    "E2E_CALL_PIP_BACKGROUND_APP_BUNDLE_ID",
    "E2E_CALL_PIP_BACKGROUND_APP_SECONDS",
  ]

  private static let initiatorHostConfigPath: String = "/tmp/messenger-e2e-initiator-config.json"
  private static let receiverHostConfigPath: String = "/tmp/messenger-e2e-receiver-config.json"
  private static let companionHostConfigPath: String = "/tmp/messenger-e2e-companion-config.json"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testDualDeviceAutomationFlow() throws {
    try executeAutomationFlow(
      withHostConfigPath: nil,
      expectedRole: nil,
      fallbackEnvironment: [:]
    )
  }

  @MainActor
  func testDualDeviceAutomationFlowInitiator() throws {
    try executeAutomationFlow(
      withHostConfigPath: Self.initiatorHostConfigPath,
      expectedRole: "initiator",
      fallbackEnvironment: [:]
    )
  }

  @MainActor
  func testDualDeviceAutomationFlowReceiver() throws {
    try executeAutomationFlow(
      withHostConfigPath: Self.receiverHostConfigPath,
      expectedRole: "receiver",
      fallbackEnvironment: [:]
    )
  }

  @MainActor
  func testThreeDeviceAutomationFlowCompanion() throws {
    try executeAutomationFlow(
      withHostConfigPath: Self.companionHostConfigPath,
      expectedRole: "companion",
      fallbackEnvironment: [:]
    )
  }

  @MainActor
  private func executeAutomationFlow(
    withHostConfigPath hostConfigPath: String?,
    expectedRole: String?,
    fallbackEnvironment: [String: String]
  ) throws {
    let processEnvironment: [String: String] = ProcessInfo.processInfo.environment

    let hostConfig: [String: String] = Self.loadHostConfig(path: hostConfigPath)
    let bundledConfig: [String: String] = Self.loadBundledRoleConfig(role: expectedRole)
    let runLiveDualDevice: Bool = readBool(processEnvironment["E2E_RUN_LIVE_DUAL_DEVICE"])
      || readBool(hostConfig["E2E_RUN_LIVE_DUAL_DEVICE"])
      || readBool(bundledConfig["E2E_RUN_LIVE_DUAL_DEVICE"])
      || !fallbackEnvironment.isEmpty
    if !runLiveDualDevice {
      print(
        "[E2E][DEBUG] skip runLiveDualDevice=false role=\(expectedRole ?? "none") " +
          "hostConfigCount=\(hostConfig.count) bundledConfigCount=\(bundledConfig.count)"
      )
      throw XCTSkip("Set E2E_RUN_LIVE_DUAL_DEVICE=1 to execute dual-device automation UI tests.")
    }

    var resolvedEnvironment: [String: String] = fallbackEnvironment

    let hasForwardedEnvironment: Bool = forwardedKeys.contains { key in
      guard let value: String = processEnvironment[key] else {
        return false
      }

      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let allowFallback: Bool = readBool(processEnvironment["E2E_ALLOW_FALLBACK_CREDENTIALS"])
    if hostConfig.isEmpty
      && bundledConfig.isEmpty
      && !hasForwardedEnvironment
      && !allowFallback
      && fallbackEnvironment.isEmpty
    {
      throw XCTSkip(
        "Dual-device automation requires host config or E2E_* environment values. " +
          "Set E2E_ALLOW_FALLBACK_CREDENTIALS=1 to force fallback credentials."
      )
    }

    for key in forwardedKeys {
      if let value: String = processEnvironment[key], !value.isEmpty {
        resolvedEnvironment[key] = value
      }
    }

    for key in forwardedKeys {
      if let value: String = hostConfig[key], !value.isEmpty {
        resolvedEnvironment[key] = value
      }
    }

    for key in forwardedKeys {
      if let value: String = bundledConfig[key], !value.isEmpty {
        resolvedEnvironment[key] = value
      }
    }

    let app: XCUIApplication = XCUIApplication()
    app.launchEnvironment["E2E_AUTORUN"] = "1"

    for key in forwardedKeys {
      if let value: String = resolvedEnvironment[key], !value.isEmpty {
        app.launchEnvironment[key] = value
      }
    }

    app.launch()

    let automationStatusLabel: XCUIElement = app.staticTexts["automationStatusLabel"]
    XCTAssertTrue(
      automationStatusLabel.waitForExistence(timeout: 30),
      "automationStatusLabel is missing in app UI"
    )

    let automationTimeout: TimeInterval = {
      guard let raw: String = resolvedEnvironment["E2E_AUTOMATION_TIMEOUT_SECONDS"],
        let value: Double = Double(raw), value > 0
      else {
        return 420
      }
      return value
    }()

    let pollInterval: TimeInterval = 0.5
    let deadline: Date = Date().addingTimeInterval(automationTimeout)
    var capturedActiveCalls: Set<String> = []
    var capturedEndedCalls: Set<String> = []
    var didValidateBackgroundPictureInPicture: Bool = false
    let resolvedRole: String = expectedRole ?? resolvedEnvironment["E2E_ROLE"] ?? "unknown"
    let shouldValidateBackgroundPictureInPicture: Bool = readBool(
      resolvedEnvironment["E2E_VALIDATE_CALL_PIP_BACKGROUND"]
    )
    let pictureInPictureValidationRole: String = (
      resolvedEnvironment["E2E_VALIDATE_CALL_PIP_ROLE"] ?? "initiator"
    ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    while Date() < deadline {
      dismissSystemAlerts(app: app)
      let currentLabel: String = automationStatusLabel.label
      captureCallScreenshotIfNeeded(
        app: app,
        label: currentLabel,
        phase: "ACTIVE",
        capturedKeys: &capturedActiveCalls,
        role: expectedRole ?? resolvedEnvironment["E2E_ROLE"] ?? "unknown"
      )
      captureCallScreenshotIfNeeded(
        app: app,
        label: currentLabel,
        phase: "ENDED",
        capturedKeys: &capturedEndedCalls,
        role: expectedRole ?? resolvedEnvironment["E2E_ROLE"] ?? "unknown"
      )

      if shouldValidateBackgroundPictureInPicture,
        !didValidateBackgroundPictureInPicture,
        resolvedRole.lowercased() == pictureInPictureValidationRole,
        currentLabel.contains("AUTOMATION_CALL_ACTIVE")
      {
        didValidateBackgroundPictureInPicture = true
        try validateBackgroundPictureInPicture(
          app: app,
          resolvedEnvironment: resolvedEnvironment
        )
        let sourceMode: String = resolvedEnvironment["E2E_CALL_PIP_SOURCE_MODE"] ?? "default"
        let backgroundApp: String = backgroundPictureInPictureAppBundleId(resolvedEnvironment) ?? "home"
        let scenarioDetail: String = "pip_background=PASS source=\(sourceMode) background_app=\(backgroundApp)"
        print("[E2E][SCENARIO] video_call=PASS detail=\"\(scenarioDetail)\"")
        emitScenarioLines(app: app)
        return
      }

      if currentLabel.contains("AUTOMATION_SUCCESS") {
        emitScenarioLines(app: app)
        XCTAssertTrue(true)
        return
      }

      if currentLabel.contains("AUTOMATION_FAILED") {
        emitScenarioLines(app: app)
        let details: String = diagnosticsSummary(app: app)
        XCTFail("Automation failed. Final label: \(currentLabel). \(details)")
        return
      }

      RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }

    let details: String = diagnosticsSummary(app: app)
    emitScenarioLines(app: app)
    XCTFail("Automation timed out after \(automationTimeout)s. Final label: \(automationStatusLabel.label). \(details)")
  }

  private func validateBackgroundPictureInPicture(
    app: XCUIApplication,
    resolvedEnvironment: [String: String]
  ) throws {
    let delaySeconds: TimeInterval = {
      guard let raw: String = resolvedEnvironment["E2E_CALL_PIP_BACKGROUND_DELAY_SECONDS"],
        let value: Double = Double(raw), value > 0
      else {
        return 5
      }
      return value
    }()

    let callPanel: XCUIElement = app.otherElements[UITestID.Screen.activeCall]
    XCTAssertTrue(callPanel.waitForExistence(timeout: 10), "Active call screen is missing before PiP validation")

    let initialDiagnostics: String = callPanel.value as? String ?? ""
    guard initialDiagnostics.contains("pip=") else {
      throw XCTSkip("Background PiP validation requires the real E2ECallViewController call UI.")
    }
    let initialCallId: String = fieldValue("callId", in: initialDiagnostics) ?? "unknown"
    let screenshotRole: String = resolvedEnvironment["E2E_ROLE"] ?? "unknown"
    let callScreenshotToken: String = shortIdentifier(initialCallId)
    captureScreenAttachment(
      role: screenshotRole,
      key: "PIP-before-home-call-\(callScreenshotToken)"
    )

    if readBool(resolvedEnvironment["E2E_CALL_PIP_TAP_BUTTON_BEFORE_BACKGROUND"]) {
      let pictureInPictureButton: XCUIElement = app.buttons[UITestID.Button.callPictureInPicture]
      XCTAssertTrue(
        pictureInPictureButton.waitForExistence(timeout: 5),
        "Picture in Picture button is missing before manual tap validation"
      )
      pictureInPictureButton.tap()
      let didStartFromTap: Bool = waitForCallDiagnostics(
        callPanel: callPanel,
        contains: "call_pip_did_start",
        timeout: 5
      )
      XCTAssertTrue(
        didStartFromTap,
        "Expected manual PiP tap to start before backgrounding. Diagnostics: \(callPanel.value as? String ?? "")"
      )
    }

    XCUIDevice.shared.press(.home)
    if let backgroundAppBundleId: String = backgroundPictureInPictureAppBundleId(resolvedEnvironment) {
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      captureScreenAttachment(
        role: screenshotRole,
        key: "PIP-home-call-\(callScreenshotToken)"
      )
      let backgroundApp = XCUIApplication(bundleIdentifier: backgroundAppBundleId)
      backgroundApp.activate()
      XCTAssertTrue(
        backgroundApp.wait(for: .runningForeground, timeout: 10),
        "Background app \(backgroundAppBundleId) did not become foreground during PiP validation"
      )
      let backgroundDelay: TimeInterval = backgroundPictureInPictureAppDelay(resolvedEnvironment)
      let firstEvidenceDelay: TimeInterval = min(1, backgroundDelay)
      if firstEvidenceDelay > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(firstEvidenceDelay))
      }
      captureScreenAttachment(
        role: screenshotRole,
        key: "PIP-app-\(backgroundAppBundleId)-call-\(callScreenshotToken)-start"
      )
      let remainingDelay: TimeInterval = max(0, backgroundDelay - firstEvidenceDelay)
      if remainingDelay > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(remainingDelay))
      }
      captureScreenAttachment(
        role: screenshotRole,
        key: "PIP-app-\(backgroundAppBundleId)-call-\(callScreenshotToken)-end"
      )
    } else {
      let firstEvidenceDelay: TimeInterval = min(1, delaySeconds)
      if firstEvidenceDelay > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(firstEvidenceDelay))
      }
      captureScreenAttachment(
        role: screenshotRole,
        key: "PIP-home-call-\(callScreenshotToken)-start"
      )
      let remainingDelay: TimeInterval = max(0, delaySeconds - firstEvidenceDelay)
      if remainingDelay > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(remainingDelay))
      }
      captureScreenAttachment(
        role: screenshotRole,
        key: "PIP-home-call-\(callScreenshotToken)-end"
      )
    }
    app.activate()
    XCTAssertTrue(callPanel.waitForExistence(timeout: 15), "Active call screen did not restore after PiP validation")

    let diagnostics: String = callPanel.value as? String ?? ""
    let restoredCallId: String = fieldValue("callId", in: diagnostics) ?? "unknown"
    XCTAssertEqual(
      restoredCallId,
      initialCallId,
      "Active call screen restored with a different callId after PiP validation. Before: \(initialCallId). After: \(restoredCallId). Diagnostics: \(diagnostics)"
    )
    XCTAssertTrue(
      diagnostics.contains("call_pip_did_start"),
      "Expected live call PiP to start while app was backgrounded. Diagnostics: \(diagnostics)"
    )
  }

  private func backgroundPictureInPictureAppBundleId(_ environment: [String: String]) -> String? {
    let rawValue: String = environment["E2E_CALL_PIP_BACKGROUND_APP_BUNDLE_ID"] ?? ""
    let bundleId: String = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return bundleId.isEmpty ? nil : bundleId
  }

  private func backgroundPictureInPictureAppDelay(_ environment: [String: String]) -> TimeInterval {
    guard let raw: String = environment["E2E_CALL_PIP_BACKGROUND_APP_SECONDS"],
      let value: Double = Double(raw),
      value > 0
    else {
      return 4
    }

    return value
  }

  private func waitForCallDiagnostics(
    callPanel: XCUIElement,
    contains expectedValue: String,
    timeout: TimeInterval
  ) -> Bool {
    let deadline: Date = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let diagnostics: String = callPanel.value as? String ?? ""
      if diagnostics.contains(expectedValue) {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    return false
  }

  private func captureCallScreenshotIfNeeded(
    app: XCUIApplication,
    label: String,
    phase: String,
    capturedKeys: inout Set<String>,
    role: String
  ) {
    let marker = "AUTOMATION_CALL_\(phase)"
    guard label.contains(marker) else {
      return
    }

    let key = "\(phase)-\(fieldValue("type", in: label) ?? "call")-\(fieldValue("callId", in: label) ?? "unknown")"
    guard !capturedKeys.contains(key) else {
      return
    }

    capturedKeys.insert(key)
    scrollCallPanelIntoView(app: app)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "physical-\(role)-\(key)"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("[E2E][SCREENSHOT] \(attachment.name)")
  }

  private func captureScreenAttachment(role: String, key: String) {
    let sanitizedKey: String = sanitizedAttachmentComponent(key)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "physical-\(role)-\(sanitizedKey)"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("[E2E][SCREENSHOT] \(attachment.name)")
  }

  private func sanitizedAttachmentComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }.reduce(into: "") { partialResult, character in
      partialResult.append(character)
    }
  }

  private func shortIdentifier(_ value: String) -> String {
    let sanitized = sanitizedAttachmentComponent(value)
    guard sanitized.count > 12 else {
      return sanitized
    }

    return String(sanitized.prefix(12))
  }

  private func scrollCallPanelIntoView(app: XCUIApplication) {
    let callPanel: XCUIElement = app.otherElements[UITestID.Screen.activeCall]
    guard callPanel.exists else {
      return
    }

    for _ in 0..<8 where !callPanel.isHittable {
      app.swipeUp()
      RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
  }

  private func fieldValue(_ key: String, in label: String) -> String? {
    let prefix = "\(key)="
    guard let range = label.range(of: prefix) else {
      return nil
    }

    let suffix = label[range.upperBound...]
    let value = suffix.split(separator: " ").first.map(String.init) ?? ""
    return value.isEmpty ? nil : value
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
      "Cancel",
      "Разрешить",
      "Разрешить при использовании приложения",
      "При использовании приложения",
      "ОК",
      "Продолжить",
      "Отмена",
    ]

    for title in preferredTitles {
      let button: XCUIElement = alert.buttons[title]
      if button.exists, button.isHittable {
        button.tap()
        return true
      }
    }

    let fuzzyNeedles: [String] = [
      "allow",
      "ok",
      "continue",
      "cancel",
      "разреш",
      "использован",
      "продолж",
      "отмена",
    ]

    for button in alert.buttons.allElementsBoundByIndex where button.exists && button.isHittable {
      let label: String = button.label.lowercased()
      if fuzzyNeedles.contains(where: { label.contains($0) }) {
        button.tap()
        return true
      }
    }

    return false
  }

  private func diagnosticsSummary(app: XCUIApplication) -> String {
    let statusValue: String = app.staticTexts["statusLabel"].exists ? app.staticTexts["statusLabel"].label : "statusLabel:missing"
    let rawLog: String = automationLogText(app: app)

    let trimmedLog: String = tail(rawLog, maxLength: 1200).replacingOccurrences(of: "\n", with: " | ")
    let normalizedStatus: String = statusValue.replacingOccurrences(of: "\n", with: " | ")
    return "status=\(normalizedStatus); logTail=\(trimmedLog)"
  }

  private func emitScenarioLines(app: XCUIApplication) {
    let rawLog: String = automationLogText(app: app)

    guard !rawLog.isEmpty else {
      return
    }

    let lines: [Substring] = rawLog.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines where line.contains("[E2E][SCENARIO]") {
      print(String(line))
    }
  }

  private func automationLogText(app: XCUIApplication) -> String {
    let staticLogElement: XCUIElement = app.staticTexts["logTextView"]
    if staticLogElement.exists {
      if let value: String = staticLogElement.value as? String, !value.isEmpty {
        return value
      }
      return staticLogElement.label
    }

    let textLogElement: XCUIElement = app.textViews["logTextView"]
    if textLogElement.exists {
      if let value: String = textLogElement.value as? String, !value.isEmpty {
        return value
      }
      return textLogElement.label
    }

    return ""
  }

  private func tail(_ value: String, maxLength: Int) -> String {
    guard maxLength > 0, value.count > maxLength else {
      return value
    }

    let startIndex: String.Index = value.index(value.endIndex, offsetBy: -maxLength)
    return String(value[startIndex...])
  }

  private static func loadHostConfig(path: String?) -> [String: String] {
    guard let path, !path.isEmpty else {
      return [:]
    }

    let url: URL = URL(fileURLWithPath: path)
    guard let data: Data = try? Data(contentsOf: url) else {
      return [:]
    }

    guard let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: String] = object as? [String: String]
    else {
      return [:]
    }

    return payload
  }

  private static func loadBundledRoleConfig(role: String?) -> [String: String] {
    guard let role = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !role.isEmpty else {
      return [:]
    }

    guard let url: URL = Bundle(for: Self.self).url(forResource: "dual_iphone_runtime_config", withExtension: "json"),
      let data: Data = try? Data(contentsOf: url),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: Any] = object as? [String: Any]
    else {
      return [:]
    }

    guard let rolePayload: [String: String] = payload[role] as? [String: String] else {
      return [:]
    }

    return rolePayload
  }

  private func readBool(_ value: String?) -> Bool {
    guard let value else {
      return false
    }

    switch value.lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    default:
      return false
    }
  }
}
