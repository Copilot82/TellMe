import XCTest

final class MessengerScreenSmokeUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testAuthScreenMandatoryIdentifiers() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: false,
        stubNetwork: false,
        disableRealtime: true,
        requestNotifications: false
      )
    )
    harness.launch()
    OnboardingScreen(app: harness.app).completeIfVisible()

    let auth = AuthScreen(app: harness.app)
    auth.waitForVisible()

    XCTAssertTrue(auth.handleInput.exists, "Missing \(UITestID.Input.authHandle)")
    XCTAssertTrue(auth.seedInput.exists, "Missing \(UITestID.Input.authSeed)")
    XCTAssertTrue(auth.modeControl.exists, "Missing \(UITestID.View.authMode)")
    XCTAssertTrue(auth.submitButton.exists, "Missing \(UITestID.Button.authSubmit)")
    XCTAssertTrue(auth.errorLabel.exists, "Missing \(UITestID.Label.authError)")
  }

  @MainActor
  func testChatsConversationAndContactCodeSmoke() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        requestNotifications: false
      )
    )
    harness.launch()

    let chats = ChatsScreen(app: harness.app)
    chats.waitForVisible()
    XCTAssertTrue(chats.searchInput.exists, "Missing \(UITestID.Input.chatsSearch)")
    XCTAssertTrue(chats.newChatButton.exists, "Missing \(UITestID.Button.chatsNew)")
    XCTAssertTrue(chats.myCodeButton.exists, "Missing \(UITestID.Button.chatsMyCode)")
    XCTAssertTrue(chats.conversationCell.waitForExistence(timeout: 5), "Missing \(UITestID.View.chatCell)")

    chats.myCodeButton.tap()
    let contactCode = ContactCodeScreen(app: harness.app)
    contactCode.waitForVisible()
    XCTAssertTrue(contactCode.qrImage.exists, "Missing \(UITestID.View.contactCodeQR)")
    XCTAssertTrue(contactCode.textCode.exists, "Missing \(UITestID.View.contactCodeText)")
    XCTAssertTrue(contactCode.copyButton.exists, "Missing \(UITestID.Button.contactCodeCopy)")
    XCTAssertTrue(contactCode.shareButton.exists, "Missing \(UITestID.Button.contactCodeShare)")

    goBack(in: harness.app)

    chats.newChatButton.tap()
    let newChat = NewChatScreen(app: harness.app)
    newChat.waitForVisible()
    XCTAssertTrue(newChat.handleInput.exists, "Missing \(UITestID.Input.newChatHandle)")
    XCTAssertTrue(newChat.trustLabel.exists, "Missing \(UITestID.Label.newChatTrust)")
    XCTAssertTrue(newChat.pasteButton.exists, "Missing \(UITestID.Button.newChatPaste)")
    XCTAssertTrue(newChat.scanButton.exists, "Missing \(UITestID.Button.newChatScanQr)")
    XCTAssertTrue(newChat.myCodeButton.exists, "Missing \(UITestID.Button.newChatShowMyCode)")
    XCTAssertTrue(newChat.openButton.exists, "Missing \(UITestID.Button.newChatOpen)")

    goBack(in: harness.app)

    chats.conversationCell.tap()
    let conversation = ConversationScreen(app: harness.app)
    conversation.waitForVisible()
    XCTAssertTrue(conversation.banner.exists, "Missing \(UITestID.View.conversationBanner)")
    XCTAssertTrue(conversation.pinnedBanner.exists, "Missing \(UITestID.View.conversationPinnedBanner)")
    XCTAssertTrue(conversation.verifyKeyButton.exists, "Missing \(UITestID.Button.conversationVerifyKey)")
    XCTAssertTrue(conversation.startCallButton.exists, "Missing \(UITestID.Button.conversationStartCall)")
    XCTAssertTrue(conversation.messagesList.exists, "Missing \(UITestID.View.conversationMessages)")
    XCTAssertTrue(conversation.messageCell.exists, "Missing \(UITestID.View.messageCell)")
    XCTAssertTrue(conversation.textInput.exists, "Missing \(UITestID.Input.conversationText)")
    XCTAssertTrue(conversation.sendButton.exists, "Missing \(UITestID.Button.conversationSend)")
    XCTAssertTrue(conversation.attachButton.exists, "Missing \(UITestID.Button.conversationAttach)")
    XCTAssertTrue(conversation.typingLabel.exists, "Missing \(UITestID.Label.conversationTyping)")
  }

  @MainActor
  func testSettingsSecurityAndNotificationsSmoke() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        requestNotifications: false
      )
    )
    harness.launch()

    harness.app.tabBars.buttons[UITestID.Button.tabSettings].tap()

    let settings = SettingsScreen(app: harness.app)
    settings.waitForVisible()
    XCTAssertTrue(settings.refreshSessionButton.exists, "Missing \(UITestID.Button.settingsRefreshSession)")
    XCTAssertTrue(settings.securityButton.exists, "Missing \(UITestID.Button.settingsSecurity)")
    XCTAssertTrue(settings.notificationsButton.exists, "Missing \(UITestID.Button.settingsNotifications)")
    XCTAssertTrue(settings.diagnosticsButton.exists, "Missing \(UITestID.Button.settingsDiagnostics)")
    XCTAssertTrue(settings.logoutButton.exists, "Missing \(UITestID.Button.settingsLogout)")

    settings.securityButton.tap()
    let security = SecurityScreen(app: harness.app)
    security.waitForVisible()
    XCTAssertTrue(security.statusLabel.exists, "Missing \(UITestID.Label.securityStatus)")
    XCTAssertTrue(security.manualReadSwitch.exists, "Missing \(UITestID.View.securityManualRead)")
    XCTAssertTrue(security.exportButton.exists, "Missing \(UITestID.Button.securityExportSeed)")
    XCTAssertTrue(security.importButton.exists, "Missing \(UITestID.Button.securityImportSeed)")
    XCTAssertTrue(security.checkPublicKeyButton.exists, "Missing \(UITestID.Button.securityCheckPublicKey)")
    XCTAssertTrue(security.linkDeviceButton.exists, "Missing \(UITestID.Button.securityLinkDevice)")
    XCTAssertTrue(security.output.exists, "Missing \(UITestID.View.securityOutput)")

    security.exportButton.tap()
    waitForNonEmptyValue(security.output)

    goBack(in: harness.app)

    settings.notificationsButton.tap()
    let notifications = NotificationsScreen(app: harness.app)
    notifications.waitForVisible()
    XCTAssertTrue(notifications.registerTokenButton.exists, "Missing \(UITestID.Button.notificationsRegisterToken)")
    XCTAssertTrue(notifications.statusLabel.exists, "Missing \(UITestID.Label.notificationsStatus)")
    XCTAssertTrue(notifications.tokenCell.exists, "Missing \(UITestID.View.notificationTokenCell)")
    XCTAssertTrue(notifications.tokenSwitch.exists, "Missing \(UITestID.View.notificationTokenSwitch)")
    XCTAssertTrue(notifications.deleteButton.exists, "Missing \(UITestID.View.notificationDeleteButton)")

    goBack(in: harness.app)

    settings.diagnosticsButton.tap()
    let diagnostics = DiagnosticsScreen(app: harness.app)
    diagnostics.waitForVisible()
    XCTAssertTrue(diagnostics.output.exists, "Missing \(UITestID.View.diagnosticsOutput)")
    XCTAssertTrue(diagnostics.copyButton.exists, "Missing \(UITestID.Button.diagnosticsCopy)")
    waitForNonEmptyValue(diagnostics.output)
  }

  @MainActor
  func testNotificationsMessagePushSimulationUpdatesStatus() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        requestNotifications: false
      )
    )
    harness.launch()

    harness.app.tabBars.buttons[UITestID.Button.tabSettings].tap()

    let settings = SettingsScreen(app: harness.app)
    settings.waitForVisible()
    settings.notificationsButton.tap()

    let notifications = NotificationsScreen(app: harness.app)
    notifications.waitForVisible()

    XCTAssertTrue(notifications.simulateMessagePushButton.exists)
    notifications.simulateMessagePushButton.tap()

    waitForLabel(notifications.statusLabel, containing: "ui-message-push-001")
    waitForLabel(notifications.statusLabel, containing: "message")
  }

  @MainActor
  func testNotificationsMissedCallPushSimulationUpdatesStatus() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        requestNotifications: false
      )
    )
    harness.launch()

    harness.app.tabBars.buttons[UITestID.Button.tabSettings].tap()

    let settings = SettingsScreen(app: harness.app)
    settings.waitForVisible()
    settings.notificationsButton.tap()

    let notifications = NotificationsScreen(app: harness.app)
    notifications.waitForVisible()

    XCTAssertTrue(notifications.simulateMissedCallPushButton.exists)
    notifications.simulateMissedCallPushButton.tap()

    waitForLabel(notifications.statusLabel, containing: "ui-missed-call-push-001")
    waitForLabel(notifications.statusLabel, containing: "missed_call")
  }

  @MainActor
  func testActiveCallScreenSmoke() throws {
    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        startRoute: "call_active",
        requestNotifications: false
      )
    )
    harness.launch()

    let call = ActiveCallScreen(app: harness.app)
    call.waitForVisible()
    XCTAssertTrue(call.statusLabel.exists, "Missing \(UITestID.Label.callStatus)")
    XCTAssertTrue(call.durationLabel.exists, "Missing \(UITestID.Label.callDuration)")
    XCTAssertTrue(call.remoteVideoView.exists, "Missing \(UITestID.View.callRemoteVideo)")
    XCTAssertTrue(call.localVideoView.exists, "Missing \(UITestID.View.callLocalVideo)")
    XCTAssertTrue(call.muteButton.exists, "Missing \(UITestID.Button.callMute)")
    XCTAssertTrue(call.cameraButton.exists, "Missing \(UITestID.Button.callCamera)")
    XCTAssertTrue(call.endButton.exists, "Missing \(UITestID.Button.callEnd)")
    XCTAssertTrue(call.diagnosticsValue.contains("pip="), "Missing active call PiP diagnostics")
  }

  @MainActor
  func testActiveCallPictureInPictureStartsWhenBackgroundedOnPhysicalDevice() throws {
    guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil else {
      throw XCTSkip("System Picture in Picture overlay requires a physical iPhone.")
    }

    let harness = MessengerUITestHarness(
      options: MessengerLaunchOptions(
        resetState: true,
        bootstrapSampleData: true,
        stubNetwork: true,
        disableRealtime: true,
        startRoute: "call_active",
        requestNotifications: false
      )
    )
    harness.launch()

    let call = ActiveCallScreen(app: harness.app)
    call.waitForVisible(timeout: 20)
    XCTAssertTrue(call.diagnosticsValue.contains("pip="), "Missing initial PiP diagnostics")

    XCUIDevice.shared.press(.home)
    RunLoop.current.run(until: Date().addingTimeInterval(4))
    harness.app.activate()

    call.waitForVisible(timeout: 20)
    let diagnostics = call.diagnosticsValue
    XCTAssertTrue(
      diagnostics.contains("call_pip_did_start"),
      "Expected system PiP to start while app was backgrounded. Diagnostics: \(diagnostics)"
    )
  }
}
