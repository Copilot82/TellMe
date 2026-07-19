import UIKit

// Centralized identifiers keep UI automation stable while screens are refactored.
enum MessengerAccessibility {
  enum Screen {
    static let auth: String = "screen.auth"
    static let chats: String = "screen.chats"
    static let newChat: String = "screen.newChat"
    static let contactCode: String = "screen.contactCode"
    static let qrScanner: String = "screen.qrScanner"
    static let settings: String = "screen.settings"
    static let security: String = "screen.security"
    static let notifications: String = "screen.notifications"
    static let diagnostics: String = "screen.diagnostics"
    static let deviceLinkHost: String = "screen.deviceLink.host"
    static let activeCall: String = "screen.call.active"
    static let automationCall: String = "screen.call.automation"
    static let onboarding: String = "screen.onboarding"
    static let authSeedBackup: String = "screen.auth.seedBackup"

    static func conversation(_ conversationId: String) -> String {
      "screen.conversation.\(sanitize(conversationId))"
    }
  }

  enum Input {
    static let authHandle: String = "input.auth.handle"
    static let authSeed: String = "input.auth.seed"
    static let chatsSearch: String = "input.chats.search"
    static let newChatHandle: String = "input.newChat.handle"
    static let conversationText: String = "input.conversation.text"
  }

  enum Button {
    static let authSubmit: String = "button.auth.submit"
    static let authSeedConfirm: String = "button.auth.seed.confirm"
    static let authSeedCopy: String = "button.auth.seed.copy"
    static let chatsNew: String = "button.chats.new"
    static let chatsMyCode: String = "button.chats.myCode"
    static let newChatPaste: String = "button.newChat.paste"
    static let newChatScanQr: String = "button.newChat.scanQr"
    static let newChatShowMyCode: String = "button.newChat.showMyCode"
    static let newChatOpen: String = "button.newChat.open"
    static let contactCodeCopy: String = "button.contactCode.copy"
    static let contactCodeShare: String = "button.contactCode.share"
    static let conversationVerifyKey: String = "button.conversation.verifyKey"
    static let conversationStartCall: String = "button.conversation.startCall"
    static let conversationSend: String = "button.conversation.send"
    static let conversationAttach: String = "button.conversation.attach"
    static let conversationPinnedUnpin: String = "button.conversation.pinned.unpin"
    static let conversationScrollToBottom: String = "button.conversation.scrollToBottom"
    static let settingsRefreshSession: String = "button.settings.refreshSession"
    static let settingsNotifications: String = "button.settings.notifications"
    static let settingsSecurity: String = "button.settings.security"
    static let settingsDiagnostics: String = "button.settings.diagnostics"
    static let diagnosticsCopy: String = "button.diagnostics.copy"
    static let settingsLogout: String = "button.settings.logout"
    static let securityExportSeed: String = "button.security.exportSeed"
    static let securityImportSeed: String = "button.security.importSeed"
    static let securityCheckPublicKey: String = "button.security.checkPublicKey"
    static let securityLinkDevice: String = "button.security.linkDevice"
    static let deviceLinkHostCopyCode: String = "button.deviceLink.host.copyCode"
    static let deviceLinkHostApprove: String = "button.deviceLink.host.approve"
    static let notificationsRegisterToken: String = "button.notifications.registerToken"
    static let notificationsSimulateMessagePush: String = "button.notifications.simulateMessagePush"
    static let notificationsSimulateMissedCallPush: String = "button.notifications.simulateMissedCallPush"
    static let onboardingBack: String = "button.onboarding.back"
    static let onboardingNext: String = "button.onboarding.next"
    static let onboardingFinish: String = "button.onboarding.finish"
    static let callAnswer: String = "button.call.answer"
    static let callEnd: String = "button.call.end"
    static let callMute: String = "button.call.mute"
    static let callCamera: String = "button.call.camera"
    static let callAcceptIncoming: String = "button.call.acceptIncoming"
    static let callDeclineIncoming: String = "button.call.declineIncoming"
    static let tabChats: String = "tab.chats"
    static let tabSettings: String = "tab.settings"

    static func notificationsDeleteToken(_ tokenId: String) -> String {
      "button.notifications.deleteToken.\(sanitize(tokenId))"
    }
  }

  enum Label {
    static let authError: String = "label.auth.error"
    static let authTestServer: String = "label.auth.testServer"
    static let authHandlePreview: String = "label.auth.handlePreview"
    static let authSeedWarning: String = "label.auth.seed.warning"
    static let authSeedCopyStatus: String = "label.auth.seed.copyStatus"
    static let newChatTrust: String = "label.newChat.trust"
    static let newChatError: String = "label.newChat.error"
    static let qrScannerError: String = "label.qrScanner.error"
    static let conversationTyping: String = "label.conversation.typing"
    static let securityStatus: String = "label.security.status"
    static let notificationsStatus: String = "label.notifications.status"
    static let deviceLinkHostStatus: String = "label.deviceLink.host.status"
    static let deviceLinkHostPendingRequest: String = "label.deviceLink.host.pendingRequest"
    static let callStatus: String = "label.call.status"
    static let callDuration: String = "label.call.duration"
  }

  enum View {
    static let authModeSegmented: String = "segmented.auth.mode"
    static let authSeedPhrase: String = "text.auth.seed.phrase"
    static let contactCodeQR: String = "image.contactCode.qr"
    static let contactCodeText: String = "text.contactCode.code"
    static let qrScannerPreview: String = "view.qrScanner.preview"
    static let conversationSecurityBanner: String = "banner.conversation.security"
    static let conversationPinnedBanner: String = "banner.conversation.pinned"
    static let conversationMessagesList: String = "list.conversation.messages"
    static let securityOutput: String = "text.security.output"
    static let securityManualRead: String = "switch.security.manualRead"
    static let diagnosticsOutput: String = "text.diagnostics.output"
    static let deviceLinkHostQR: String = "image.deviceLink.host.qr"
    static let deviceLinkHostTextCode: String = "text.deviceLink.host.code"
    static let callRemoteVideo: String = "view.call.remoteVideo"
    static let callLocalVideo: String = "view.call.localVideo"
    static let onboardingPageControl: String = "pageControl.onboarding"
    static let onboardingTestServer: String = "view.onboarding.testServer"
    static let onboardingContactSteps: String = "view.onboarding.contactSteps"

    static func chatCell(_ conversationId: String) -> String {
      "cell.chat.\(sanitize(conversationId))"
    }

    static func messageCell(_ messageId: String) -> String {
      "cell.message.\(sanitize(messageId))"
    }

    static func notificationsTokenCell(_ tokenId: String) -> String {
      "cell.notifications.token.\(sanitize(tokenId))"
    }

    static func notificationsPushEnabled(_ tokenId: String) -> String {
      "switch.notifications.pushEnabled.\(sanitize(tokenId))"
    }
  }

  enum Action {
    static let chatDelete: UIAction.Identifier = UIAction.Identifier("action.chat.delete")
    static let chatBlock: UIAction.Identifier = UIAction.Identifier("action.chat.block")
    static let messageReply: UIAction.Identifier = UIAction.Identifier("action.message.reply")
    static let messageForward: UIAction.Identifier = UIAction.Identifier("action.message.forward")
    static let messageEdit: UIAction.Identifier = UIAction.Identifier("action.message.edit")
    static let messageDeleteForAll: UIAction.Identifier = UIAction.Identifier("action.message.deleteForAll")
    static let messageDeleteForMe: UIAction.Identifier = UIAction.Identifier("action.message.deleteForMe")
    static let messageReact: UIAction.Identifier = UIAction.Identifier("action.message.react")
    static let messagePin: UIAction.Identifier = UIAction.Identifier("action.message.pin")
    static let messageUnpin: UIAction.Identifier = UIAction.Identifier("action.message.unpin")
    static let messageMarkRead: UIAction.Identifier = UIAction.Identifier("action.message.markRead")
  }

  enum Alert {
    static let authSeed: String = "alert.auth.seed"
  }

  static func sanitize(_ raw: String) -> String {
    let filtered = raw.map { character -> Character in
      if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
        return character
      }

      return "-"
    }

    return String(filtered)
  }
}

extension UIView {
  func assignAccessibilityIdentifier(_ identifier: String) {
    accessibilityIdentifier = identifier
    isAccessibilityElement = true
  }
}
