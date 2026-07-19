import XCTest

enum UITestID {
  enum Screen {
    static let onboarding = "screen.onboarding"
    static let auth = "screen.auth"
    static let chats = "screen.chats"
    static let newChat = "screen.newChat"
    static let contactCode = "screen.contactCode"
    static let conversation = "screen.conversation.dm-9a459c6e2abae8b6505abf38b38566f7"
    static let settings = "screen.settings"
    static let security = "screen.security"
    static let notifications = "screen.notifications"
    static let diagnostics = "screen.diagnostics"
    static let deviceLinkHost = "screen.deviceLink.host"
    static let activeCall = "screen.call.active"
    static let automationCall = "screen.call.automation"
    static let authSeedBackup = "screen.auth.seedBackup"
  }

  enum Input {
    static let authHandle = "input.auth.handle"
    static let authSeed = "input.auth.seed"
    static let chatsSearch = "input.chats.search"
    static let newChatHandle = "input.newChat.handle"
    static let conversationText = "input.conversation.text"
  }

  enum Button {
    static let onboardingNext = "button.onboarding.next"
    static let onboardingFinish = "button.onboarding.finish"
    static let authSubmit = "button.auth.submit"
    static let authSeedConfirm = "button.auth.seed.confirm"
    static let authSeedCopy = "button.auth.seed.copy"
    static let chatsNew = "button.chats.new"
    static let chatsMyCode = "button.chats.myCode"
    static let newChatPaste = "button.newChat.paste"
    static let newChatScanQr = "button.newChat.scanQr"
    static let newChatShowMyCode = "button.newChat.showMyCode"
    static let newChatOpen = "button.newChat.open"
    static let contactCodeCopy = "button.contactCode.copy"
    static let contactCodeShare = "button.contactCode.share"
    static let conversationVerifyKey = "button.conversation.verifyKey"
    static let conversationStartCall = "button.conversation.startCall"
    static let conversationSend = "button.conversation.send"
    static let conversationAttach = "button.conversation.attach"
    static let conversationPinnedUnpin = "button.conversation.pinned.unpin"
    static let settingsRefreshSession = "button.settings.refreshSession"
    static let settingsNotifications = "button.settings.notifications"
    static let settingsSecurity = "button.settings.security"
    static let settingsDiagnostics = "button.settings.diagnostics"
    static let diagnosticsCopy = "button.diagnostics.copy"
    static let settingsLogout = "button.settings.logout"
    static let securityExportSeed = "button.security.exportSeed"
    static let securityImportSeed = "button.security.importSeed"
    static let securityCheckPublicKey = "button.security.checkPublicKey"
    static let securityLinkDevice = "button.security.linkDevice"
    static let deviceLinkHostCopyCode = "button.deviceLink.host.copyCode"
    static let deviceLinkHostApprove = "button.deviceLink.host.approve"
    static let notificationsRegisterToken = "button.notifications.registerToken"
    static let notificationsSimulateMessagePush = "button.notifications.simulateMessagePush"
    static let notificationsSimulateMissedCallPush = "button.notifications.simulateMissedCallPush"
    static let callMute = "button.call.mute"
    static let callCamera = "button.call.camera"
    static let callPictureInPicture = "button.call.pictureInPicture"
    static let callEnd = "button.call.end"
    static let tabChats = "tab.chats"
    static let tabSettings = "tab.settings"
  }

  enum Label {
    static let authError = "label.auth.error"
    static let authTestServer = "label.auth.testServer"
    static let authHandlePreview = "label.auth.handlePreview"
    static let authSeedWarning = "label.auth.seed.warning"
    static let authSeedCopyStatus = "label.auth.seed.copyStatus"
    static let newChatTrust = "label.newChat.trust"
    static let newChatError = "label.newChat.error"
    static let conversationTyping = "label.conversation.typing"
    static let securityStatus = "label.security.status"
    static let notificationsStatus = "label.notifications.status"
    static let deviceLinkHostStatus = "label.deviceLink.host.status"
    static let deviceLinkHostPendingRequest = "label.deviceLink.host.pendingRequest"
    static let callStatus = "label.call.status"
    static let callDuration = "label.call.duration"
  }

  enum View {
    static let authMode = "segmented.auth.mode"
    static let authSeedPhrase = "text.auth.seed.phrase"
    static let onboardingTestServer = "view.onboarding.testServer"
    static let onboardingContactSteps = "view.onboarding.contactSteps"
    static let contactCodeQR = "image.contactCode.qr"
    static let contactCodeText = "text.contactCode.code"
    static let conversationBanner = "banner.conversation.security"
    static let conversationPinnedBanner = "banner.conversation.pinned"
    static let conversationMessages = "list.conversation.messages"
    static let securityManualRead = "switch.security.manualRead"
    static let securityOutput = "text.security.output"
    static let diagnosticsOutput = "text.diagnostics.output"
    static let deviceLinkHostQR = "image.deviceLink.host.qr"
    static let deviceLinkHostTextCode = "text.deviceLink.host.code"
    static let chatCell = "cell.chat.dm-9a459c6e2abae8b6505abf38b38566f7"
    static let messageCell = "cell.message.ui-msg-001"
    static let notificationTokenCell = "cell.notifications.token.ui-token-001"
    static let notificationTokenSwitch = "switch.notifications.pushEnabled.ui-token-001"
    static let notificationDeleteButton = "button.notifications.deleteToken.ui-token-001"
    static let callRemoteVideo = "view.call.remoteVideo"
    static let callLocalVideo = "view.call.localVideo"
  }
}

struct OnboardingScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.onboarding] }
  var nextButton: XCUIElement { app.buttons[UITestID.Button.onboardingNext] }
  var finishButton: XCUIElement { app.buttons[UITestID.Button.onboardingFinish] }

  @MainActor
  func completeIfVisible(timeout: TimeInterval = 2) {
    guard root.waitForExistence(timeout: timeout) else {
      return
    }

    for _ in 0..<6 {
      if finishButton.exists {
        finishButton.tap()
        return
      }
      XCTAssertTrue(nextButton.waitForExistence(timeout: 2), "Missing onboarding continuation button")
      nextButton.tap()
    }
    XCTFail("Onboarding did not reach its final page")
  }
}

struct MessengerLaunchOptions {
  var resetState: Bool = true
  var bootstrapSampleData: Bool = false
  var stubNetwork: Bool = false
  var disableRealtime: Bool = false
  var startRoute: String? = nil
  var requestNotifications: Bool = false
}

final class MessengerUITestHarness {
  let app: XCUIApplication

  init(options: MessengerLaunchOptions) {
    app = XCUIApplication()
    app.launchEnvironment["UITEST_MODE"] = "1"
    app.launchEnvironment["UITEST_STORAGE_NAMESPACE"] = UUID().uuidString.lowercased()
    app.launchEnvironment["UITEST_RESET_STATE"] = options.resetState ? "1" : "0"
    app.launchEnvironment["UITEST_BOOTSTRAP_SAMPLE_DATA"] = options.bootstrapSampleData ? "1" : "0"
    app.launchEnvironment["UITEST_STUB_NETWORK"] = options.stubNetwork ? "1" : "0"
    app.launchEnvironment["UITEST_DISABLE_REALTIME"] = options.disableRealtime ? "1" : "0"
    app.launchEnvironment["UITEST_REQUEST_NOTIFICATIONS"] = options.requestNotifications ? "1" : "0"
    app.launchEnvironment["MESSENGER_APP_ENV"] = "local"

    if let startRoute = options.startRoute {
      app.launchEnvironment["UITEST_START_ROUTE"] = startRoute
    }
  }

  func launch() {
    app.launch()
  }
}

struct AuthScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.auth] }
  var handleInput: XCUIElement { app.textFields[UITestID.Input.authHandle] }
  var seedInput: XCUIElement { app.secureTextFields[UITestID.Input.authSeed] }
  var modeControl: XCUIElement { app.segmentedControls[UITestID.View.authMode] }
  var submitButton: XCUIElement { app.buttons[UITestID.Button.authSubmit] }
  var errorLabel: XCUIElement { app.staticTexts[UITestID.Label.authError] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct ChatsScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.chats] }
  var searchInput: XCUIElement { app.searchFields[UITestID.Input.chatsSearch] }
  var newChatButton: XCUIElement { app.buttons[UITestID.Button.chatsNew] }
  var myCodeButton: XCUIElement { app.buttons[UITestID.Button.chatsMyCode] }
  var conversationCell: XCUIElement { app.cells[UITestID.View.chatCell] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct NewChatScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.newChat] }
  var handleInput: XCUIElement { app.textFields[UITestID.Input.newChatHandle] }
  var trustLabel: XCUIElement { app.staticTexts[UITestID.Label.newChatTrust] }
  var pasteButton: XCUIElement { app.buttons[UITestID.Button.newChatPaste] }
  var scanButton: XCUIElement { app.buttons[UITestID.Button.newChatScanQr] }
  var myCodeButton: XCUIElement { app.buttons[UITestID.Button.newChatShowMyCode] }
  var openButton: XCUIElement { app.buttons[UITestID.Button.newChatOpen] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct ContactCodeScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.contactCode] }
  var qrImage: XCUIElement { app.images[UITestID.View.contactCodeQR] }
  var textCode: XCUIElement { app.textViews[UITestID.View.contactCodeText] }
  var copyButton: XCUIElement { app.buttons[UITestID.Button.contactCodeCopy] }
  var shareButton: XCUIElement { app.buttons[UITestID.Button.contactCodeShare] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct ConversationScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.conversation] }
  var banner: XCUIElement { app.otherElements[UITestID.View.conversationBanner] }
  var pinnedBanner: XCUIElement {
    app.descendants(matching: .any).matching(identifier: UITestID.View.conversationPinnedBanner).firstMatch
  }
  var pinnedUnpinButton: XCUIElement { app.buttons[UITestID.Button.conversationPinnedUnpin] }
  var verifyKeyButton: XCUIElement { app.buttons[UITestID.Button.conversationVerifyKey] }
  var startCallButton: XCUIElement { app.buttons[UITestID.Button.conversationStartCall] }
  var messagesList: XCUIElement { app.tables[UITestID.View.conversationMessages] }
  var messageCell: XCUIElement { app.cells[UITestID.View.messageCell] }
  var textInput: XCUIElement { app.textFields[UITestID.Input.conversationText] }
  var sendButton: XCUIElement { app.buttons[UITestID.Button.conversationSend] }
  var attachButton: XCUIElement { app.buttons[UITestID.Button.conversationAttach] }
  var typingLabel: XCUIElement { app.staticTexts[UITestID.Label.conversationTyping] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct SettingsScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.settings] }
  var refreshSessionButton: XCUIElement { app.cells[UITestID.Button.settingsRefreshSession] }
  var notificationsButton: XCUIElement { app.cells[UITestID.Button.settingsNotifications] }
  var securityButton: XCUIElement { app.cells[UITestID.Button.settingsSecurity] }
  var diagnosticsButton: XCUIElement { app.cells[UITestID.Button.settingsDiagnostics] }
  var logoutButton: XCUIElement { app.buttons[UITestID.Button.settingsLogout] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct SecurityScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.security] }
  var statusLabel: XCUIElement { app.staticTexts[UITestID.Label.securityStatus] }
  var manualReadSwitch: XCUIElement { app.switches[UITestID.View.securityManualRead] }
  var exportButton: XCUIElement { app.buttons[UITestID.Button.securityExportSeed] }
  var importButton: XCUIElement { app.buttons[UITestID.Button.securityImportSeed] }
  var checkPublicKeyButton: XCUIElement { app.buttons[UITestID.Button.securityCheckPublicKey] }
  var linkDeviceButton: XCUIElement { app.buttons[UITestID.Button.securityLinkDevice] }
  var output: XCUIElement { app.textViews[UITestID.View.securityOutput] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct DiagnosticsScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.diagnostics] }
  var output: XCUIElement { app.textViews[UITestID.View.diagnosticsOutput] }
  var copyButton: XCUIElement { app.buttons[UITestID.Button.diagnosticsCopy] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct DeviceLinkHostScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.deviceLinkHost] }
  var statusLabel: XCUIElement { app.staticTexts[UITestID.Label.deviceLinkHostStatus] }
  var qrImage: XCUIElement { app.images[UITestID.View.deviceLinkHostQR] }
  var textCode: XCUIElement { app.textViews[UITestID.View.deviceLinkHostTextCode] }
  var pendingRequestLabel: XCUIElement { app.staticTexts[UITestID.Label.deviceLinkHostPendingRequest] }
  var copyCodeButton: XCUIElement { app.buttons[UITestID.Button.deviceLinkHostCopyCode] }
  var approveButton: XCUIElement { app.buttons[UITestID.Button.deviceLinkHostApprove] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct NotificationsScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.notifications] }
  var statusLabel: XCUIElement { app.staticTexts[UITestID.Label.notificationsStatus] }
  var registerTokenButton: XCUIElement { app.buttons[UITestID.Button.notificationsRegisterToken] }
  var simulateMessagePushButton: XCUIElement { app.buttons[UITestID.Button.notificationsSimulateMessagePush] }
  var simulateMissedCallPushButton: XCUIElement { app.buttons[UITestID.Button.notificationsSimulateMissedCallPush] }
  var tokenCell: XCUIElement { app.cells[UITestID.View.notificationTokenCell] }
  var tokenSwitch: XCUIElement { app.switches[UITestID.View.notificationTokenSwitch] }
  var deleteButton: XCUIElement { app.buttons[UITestID.View.notificationDeleteButton] }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

struct ActiveCallScreen {
  let app: XCUIApplication

  var root: XCUIElement { app.otherElements[UITestID.Screen.activeCall] }
  var statusLabel: XCUIElement { app.staticTexts[UITestID.Label.callStatus] }
  var durationLabel: XCUIElement { app.staticTexts[UITestID.Label.callDuration] }
  var muteButton: XCUIElement { app.descendants(matching: .any)[UITestID.Button.callMute] }
  var cameraButton: XCUIElement { app.descendants(matching: .any)[UITestID.Button.callCamera] }
  var pictureInPictureButton: XCUIElement { app.buttons[UITestID.Button.callPictureInPicture] }
  var endButton: XCUIElement { app.buttons[UITestID.Button.callEnd] }
  var remoteVideoView: XCUIElement { app.otherElements[UITestID.View.callRemoteVideo] }
  var localVideoView: XCUIElement { app.otherElements[UITestID.View.callLocalVideo] }
  var diagnosticsValue: String { root.value as? String ?? "" }

  func waitForVisible(timeout: TimeInterval = 5) {
    XCTAssertTrue(root.waitForExistence(timeout: timeout))
  }
}

extension XCTestCase {
  func goBack(in app: XCUIApplication) {
    let button = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(button.waitForExistence(timeout: 3))
    button.tap()
  }

  func waitForLabel(
    _ element: XCUIElement,
    containing text: String,
    timeout: TimeInterval = 5
  ) {
    let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
    expectation(for: predicate, evaluatedWith: element)
    waitForExpectations(timeout: timeout)
  }

  func waitForNonEmptyValue(_ element: XCUIElement, timeout: TimeInterval = 5) {
    let predicate = NSPredicate(format: "value != nil AND value != ''")
    expectation(for: predicate, evaluatedWith: element)
    waitForExpectations(timeout: timeout)
  }
}
