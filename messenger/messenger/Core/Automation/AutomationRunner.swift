import AVFoundation
import Foundation
import UIKit
import WebRTC

@MainActor
// Automation hooks are isolated from production flows and only drive public app actions.
final class AutomationRunner {
  private enum AutomationProbeError: LocalizedError {
    case deviceLinkPayloadInvalid
    case deviceLinkRequestMissing
    case deviceLinkApprovalMissing
    case linkedUserMismatch(expected: String, actual: String)
    case linkedDeviceMissing
    case linkedDeviceMatchesHost
    case hostDeviceIdentityMissing
    case revokedDeviceStillAdvertised
    case newDeviceSyncMissingText
    case newDeviceSyncMissingAttachment
    case newDeviceSyncMissingVoice

    var errorDescription: String? {
      switch self {
      case .deviceLinkPayloadInvalid:
        return "Device-link QR/link payload could not be decoded"
      case .deviceLinkRequestMissing:
        return "Device-link request did not become visible to host device"
      case .deviceLinkApprovalMissing:
        return "Device-link approval was not visible to joining device"
      case .linkedUserMismatch(let expected, let actual):
        return "Linked user mismatch: expected \(expected), got \(actual)"
      case .linkedDeviceMissing:
        return "Linked device identity was not persisted locally"
      case .linkedDeviceMatchesHost:
        return "Linked device reused host device identity"
      case .hostDeviceIdentityMissing:
        return "Host device identity is missing"
      case .revokedDeviceStillAdvertised:
        return "Revoked linked device is still advertised by prekey lookup"
      case .newDeviceSyncMissingText:
        return "Linked same-account device did not import the text message history"
      case .newDeviceSyncMissingAttachment:
        return "Linked same-account device did not import the attachment message history"
      case .newDeviceSyncMissingVoice:
        return "Linked same-account device did not import the voice message history"
      }
    }
  }

  private struct DeviceLinkProbeResult {
    let linkedDeviceId: String
    let linkedContainer: AppContainer
    let userHandle: String
  }

  private enum PushValidationTiming {
    static let sendGraceSeconds: TimeInterval = 3.0
    static let receiverSettleSeconds: TimeInterval = 1.0
    static let missedCallDispatchDelaySeconds: TimeInterval = 10.0
  }

  private enum ScenarioStatus: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
  }

  private enum AuthOutcome {
    case registered
    case loggedIn
    case registerThenLogin
  }

  private enum ScenarioID {
    static let registration = "registration"
    static let login = "login"
    static let newDeviceSync = "login_new_device_full_sync"
    static let deviceLinkSameAccount = "device_link_same_account"
    static let revokeDevice = "revoke_device"
    static let startDirectChat = "start_direct_chat"
    static let deleteDirectChat = "delete_direct_chat"
    static let blockUser = "block_user"
    static let sendMessage = "send_message"
    static let receiveMessage = "receive_message"
    static let sendAttachment = "send_attachment"
    static let receiveAttachment = "download_view_attachment"
    static let sendVoiceMessage = "send_voice_message"
    static let receiveVoiceMessage = "receive_play_voice_message"
    static let audioCall = "audio_call"
    static let videoCall = "video_call"
    static let pushMessageNotification = "message_notifications"
    static let pushMissedCallNotification = "missed_call_notifications"
    static let settingsRefreshSession = "settings_refresh_session"
    static let settingsManualReadReceipts = "settings_manual_read_receipts"
    static let settingsRecoveryPhraseExport = "settings_recovery_phrase_export"
    static let settingsRecoveryPhraseImport = "settings_recovery_phrase_import"
    static let settingsPublicKeyLookup = "settings_public_key_lookup"
    static let settingsNotificationTokenList = "settings_notification_token_list"
    static let settingsDiagnostics = "settings_diagnostics"
    static let settingsLogout = "settings_logout"
  }

  private let container: AppContainer
  private let viewModel: MessengerViewModel
  private let configuration: E2EAutomationConfiguration
  private let logHandler: (String) -> Void
  private let stateHandler: (String, UIColor) -> Void
  private let callScreenPresenter: ((E2ECallSessionViewModel) -> Bool)?
  private var lastCallMediaDetailByScenario: [String: String] = [:]

  init(
    container: AppContainer,
    viewModel: MessengerViewModel,
    configuration: E2EAutomationConfiguration,
    logHandler: @escaping (String) -> Void,
    stateHandler: @escaping (String, UIColor) -> Void,
    callScreenPresenter: ((E2ECallSessionViewModel) -> Bool)? = nil
  ) {
    self.container = container
    self.viewModel = viewModel
    self.configuration = configuration
    self.logHandler = logHandler
    self.stateHandler = stateHandler
    self.callScreenPresenter = callScreenPresenter
  }

  func run() async {
    stateHandler(
      "AUTOMATION_RUNNING runId=\(configuration.runId) role=\(configuration.role.rawValue)",
      .systemOrange
    )

    log("[E2E] Start runId=\(configuration.runId), role=\(configuration.role.rawValue)")

    if configuration.startupDelaySeconds > 0 {
      log("[E2E] Startup delay: \(configuration.startupDelaySeconds)s")
      try? await Task.sleep(nanoseconds: secondsToNanoseconds(configuration.startupDelaySeconds))
    }

    let authOutcome: AuthOutcome = await performAuthentication(configuration)

    guard viewModel.currentUser != nil else {
      let detail: String = viewModel.lastErrorMessage ?? "No detailed auth error"
      markScenario(ScenarioID.registration, status: .fail, detail: detail)
      markScenario(ScenarioID.login, status: .fail, detail: detail)
      failAutomation("Authentication did not produce active user: \(detail)")
      return
    }

    switch authOutcome {
    case .registered:
      markScenario(ScenarioID.registration, status: .pass)
      let loginSeed: String = viewModel.lastGeneratedSeedPhrase ?? ""
      let loginHandle: String = configuration.userHandle.trimmingCharacters(in: .whitespacesAndNewlines)

      if loginSeed.isEmpty {
        markScenario(ScenarioID.login, status: .fail, detail: "registration did not return seed phrase for login check")
        failAutomation("Cannot validate login after registration without generated seed phrase")
        return
      }

      await viewModel.logout()
      await viewModel.login(userHandle: loginHandle, seedPhrase: loginSeed)

      guard viewModel.currentUser != nil else {
        markScenario(ScenarioID.login, status: .fail, detail: viewModel.lastErrorMessage ?? "login after register failed")
        failAutomation("Login verification after registration failed")
        return
      }

      markScenario(ScenarioID.login, status: .pass)
    case .loggedIn:
      markScenario(ScenarioID.registration, status: .skip, detail: "registration mode was not requested")
      markScenario(ScenarioID.login, status: .pass)
    case .registerThenLogin:
      markScenario(ScenarioID.registration, status: .pass)
      markScenario(ScenarioID.login, status: .pass)
    }

    if configuration.performRefresh {
      await viewModel.refreshSession()
    }

    if configuration.settingsOnly {
      let userId: String = viewModel.currentUser?.id ?? "unknown"
      let settingsSucceeded: Bool = await runSettingsValidationFlow(
        configuration,
        includeLogout: configuration.performSettingsLogout
      )
      guard settingsSucceeded else {
        failAutomation("Settings validation failed")
        return
      }
      markNonSettingsScenariosDisabledForSettingsOnly()

      let successMessage: String =
        "AUTOMATION_SUCCESS runId=\(configuration.runId) role=\(configuration.role.rawValue) " +
        "mode=settings userId=\(userId)"
      log("[E2E] \(successMessage)")
      stateHandler(successMessage, .systemGreen)
      return
    }

    let deviceLifecycleSucceeded: Bool = await runDeviceLifecycleValidationFlow(configuration)
    guard deviceLifecycleSucceeded else {
      return
    }

    if configuration.deviceLifecycleOnly {
      let userId: String = viewModel.currentUser?.id ?? "unknown"
      let successMessage: String =
        "AUTOMATION_SUCCESS runId=\(configuration.runId) role=\(configuration.role.rawValue) " +
        "mode=device_lifecycle userId=\(userId)"
      log("[E2E] \(successMessage)")
      stateHandler(successMessage, .systemGreen)
      return
    }

    await viewModel.connectSocket()

    let socketReady: Bool = await waitUntil(timeout: configuration.socketTimeoutSeconds) {
      if case .connected = self.viewModel.socketState {
        return true
      }
      return false
    }

    guard socketReady else {
      failAutomation("Socket did not connect in \(configuration.socketTimeoutSeconds)s")
      return
    }

    let roleFlowSucceeded: Bool

    switch configuration.role {
    case .initiator:
      roleFlowSucceeded = await runInitiatorFlow(configuration)
    case .receiver:
      roleFlowSucceeded = await runReceiverFlow(configuration)
    case .companion:
      roleFlowSucceeded = await runCompanionFlow(configuration)
    }

    guard roleFlowSucceeded else {
      let reason: String = viewModel.lastErrorMessage ?? "Role flow failed"
      failAutomation(reason)
      return
    }

    let newDeviceSyncSucceeded: Bool = await runNewDeviceSyncProbeIfNeeded(configuration)
    guard newDeviceSyncSucceeded else {
      let reason: String = viewModel.lastErrorMessage ?? "New-device sync validation failed"
      failAutomation(reason)
      return
    }

    let pushValidationSucceeded: Bool = await runPushValidationFlow(configuration)
    guard pushValidationSucceeded else {
      let reason: String = viewModel.lastErrorMessage ?? "Push validation failed"
      failAutomation(reason)
      return
    }

    let postPushCleanupSucceeded: Bool = await runPostPushCleanupFlow(configuration)
    guard postPushCleanupSucceeded else {
      let reason: String = viewModel.lastErrorMessage ?? "Post-push cleanup failed"
      failAutomation(reason)
      return
    }

    let userId: String = viewModel.currentUser?.id ?? "unknown"
    let settingsSucceeded: Bool = await runSettingsValidationFlow(
      configuration,
      includeLogout: configuration.performSettingsLogout
    )
    guard settingsSucceeded else {
      failAutomation("Settings validation failed")
      return
    }

    let successMessage: String = "AUTOMATION_SUCCESS runId=\(configuration.runId) role=\(configuration.role.rawValue) userId=\(userId)"
    log("[E2E] \(successMessage)")
    stateHandler(successMessage, .systemGreen)
  }

  private func runDeviceLifecycleValidationFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    guard config.performDeviceLinkFlow else {
      markScenario(ScenarioID.deviceLinkSameAccount, status: .skip, detail: "device-link flow disabled")
      markScenario(ScenarioID.revokeDevice, status: .skip, detail: "device-link flow disabled")
      return true
    }

    guard config.role == .initiator else {
      markScenario(
        ScenarioID.deviceLinkSameAccount,
        status: .skip,
        detail: "device-link lifecycle is validated by initiator role"
      )
      markScenario(
        ScenarioID.revokeDevice,
        status: .skip,
        detail: "device revoke lifecycle is validated by initiator role"
      )
      return true
    }

    let probeResult: DeviceLinkProbeResult
    do {
      probeResult = try await performSameAccountDeviceLinkProbe(config)
    } catch {
      let message: String = describe(error)
      markScenario(ScenarioID.deviceLinkSameAccount, status: .fail, detail: message)
      markScenario(ScenarioID.revokeDevice, status: .fail, detail: "device-link failed before revoke")
      failAutomation("Device-link validation failed: \(message)")
      return false
    }

    markScenario(
      ScenarioID.deviceLinkSameAccount,
      status: .pass,
      detail: "linked temporary same-account device \(probeResult.linkedDeviceId)"
    )

    do {
      try await revokeLinkedDevice(deviceId: probeResult.linkedDeviceId, userHandle: config.userHandle)
      markScenario(
        ScenarioID.revokeDevice,
        status: .pass,
        detail: "revoked temporary linked device \(probeResult.linkedDeviceId)"
      )
      return true
    } catch {
      let message: String = describe(error)
      markScenario(ScenarioID.revokeDevice, status: .fail, detail: message)
      failAutomation("Device revoke validation failed: \(message)")
      return false
    }
  }

  private func performSameAccountDeviceLinkProbe(_ config: E2EAutomationConfiguration) async throws -> DeviceLinkProbeResult {
    let hostViewModel = DeviceLinkViewModel(container: container)
    let hostSession: DeviceLinkViewModel.HostSession = try await hostViewModel.startHostingLink(expiresInSec: 120)
    guard let linkPayload: DeviceLinkCodePayload = DeviceLinkCodeCodec.decode(hostSession.qrPayload) else {
      throw AutomationProbeError.deviceLinkPayloadInvalid
    }

    let joinContainer: AppContainer = makeDeviceLinkProbeContainer(config)
    let joinViewModel = DeviceLinkViewModel(container: joinContainer)
    let joinSession: DeviceLinkViewModel.JoinSession = try await joinViewModel.requestLink(using: linkPayload)
    let request: FederatedDeviceLinkSessionRequest = try await waitForDeviceLinkRequest(
      viewModel: hostViewModel,
      sessionId: hostSession.sessionId,
      requestId: joinSession.requestId,
      timeout: config.socketTimeoutSeconds
    )

    try await hostViewModel.approve(hostSession: hostSession, request: request)

    let approval: FederatedDeviceLinkPollResponse = try await waitForDeviceLinkApproval(
      viewModel: joinViewModel,
      joinSession: joinSession,
      timeout: config.socketTimeoutSeconds
    )
    guard let approvedDeviceCertificate: DeviceCertificateV2 = approval.approvedDeviceCertificate,
      let encryptedProvisioningBlob: String = approval.encryptedProvisioningBlob
    else {
      throw AutomationProbeError.deviceLinkApprovalMissing
    }

    let linkedUser: User = try await joinViewModel.complete(
      joinSession: joinSession,
      approvedDeviceCertificate: approvedDeviceCertificate,
      encryptedProvisioningBlob: encryptedProvisioningBlob
    )
    let expectedUserHandle: String = normalizedHandle(config.userHandle)
    let actualUserHandle: String = normalizedHandle(linkedUser.id)
    guard actualUserHandle == expectedUserHandle else {
      throw AutomationProbeError.linkedUserMismatch(expected: expectedUserHandle, actual: actualUserHandle)
    }

    guard let linkedDeviceId: String = joinContainer.keyMaterialStore.deviceId(for: expectedUserHandle),
      !linkedDeviceId.isEmpty
    else {
      throw AutomationProbeError.linkedDeviceMissing
    }
    let hostDeviceIdentity: PersistedDeviceIdentity = try currentHostDeviceIdentity(userHandle: expectedUserHandle)
    guard linkedDeviceId != hostDeviceIdentity.deviceId else {
      throw AutomationProbeError.linkedDeviceMatchesHost
    }

    log("[E2E][DeviceLink] Linked same-account device \(linkedDeviceId) for \(expectedUserHandle)")
    return DeviceLinkProbeResult(
      linkedDeviceId: linkedDeviceId,
      linkedContainer: joinContainer,
      userHandle: expectedUserHandle
    )
  }

  private func runNewDeviceSyncProbeIfNeeded(_ config: E2EAutomationConfiguration) async -> Bool {
    guard config.requireNewDeviceSyncCheck else {
      markScenario(ScenarioID.newDeviceSync, status: .skip, detail: "new-device sync check disabled")
      return true
    }

    guard config.role == .initiator else {
      markScenario(
        ScenarioID.newDeviceSync,
        status: .skip,
        detail: "same-account sync is validated by initiator role"
      )
      return true
    }

    do {
      let probeResult: DeviceLinkProbeResult = try await performSameAccountDeviceLinkProbe(config)
      do {
        try validateLinkedDeviceSnapshot(probeResult, config: config)
      } catch {
        try? await revokeLinkedDevice(deviceId: probeResult.linkedDeviceId, userHandle: config.userHandle)
        throw error
      }

      try? await revokeLinkedDevice(deviceId: probeResult.linkedDeviceId, userHandle: config.userHandle)
      markScenario(
        ScenarioID.newDeviceSync,
        status: .pass,
        detail: "linked device \(probeResult.linkedDeviceId) imported text/media history"
      )
      return true
    } catch {
      let message: String = describe(error)
      markScenario(ScenarioID.newDeviceSync, status: .fail, detail: message)
      return false
    }
  }

  private func validateLinkedDeviceSnapshot(
    _ probeResult: DeviceLinkProbeResult,
    config: E2EAutomationConfiguration
  ) throws {
    let archiveService = LocalConversationArchiveService(
      defaults: probeResult.linkedContainer.defaults,
      secureStateStore: probeResult.linkedContainer.secureStateStore,
      keyMaterialStore: probeResult.linkedContainer.keyMaterialStore,
      identityService: probeResult.linkedContainer.identityService
    )
    let snapshot: DeviceLinkLocalStateSnapshot = archiveService.exportSnapshot(for: probeResult.userHandle)
    let messages: [Message] = snapshot.conversations.flatMap(\.messages)
    let runMarker: String = config.runId.lowercased()

    let hasText: Bool = messages.contains { message in
      message.type == .text && message.content.lowercased().contains(runMarker)
    }
    guard hasText else {
      throw AutomationProbeError.newDeviceSyncMissingText
    }

    if config.performAttachmentFlow {
      let hasAttachment: Bool = messages.contains { message in
        message.type == .file && message.content.lowercased().contains(runMarker)
      }
      guard hasAttachment else {
        throw AutomationProbeError.newDeviceSyncMissingAttachment
      }
    }

    if config.performVoiceMessageFlow {
      let hasVoice: Bool = messages.contains { message in
        message.type == .media && message.content.lowercased().contains(runMarker)
      }
      guard hasVoice else {
        throw AutomationProbeError.newDeviceSyncMissingVoice
      }
    }
  }

  private func waitForDeviceLinkRequest(
    viewModel: DeviceLinkViewModel,
    sessionId: String,
    requestId: String,
    timeout: TimeInterval
  ) async throws -> FederatedDeviceLinkSessionRequest {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))
    while Date() < deadline {
      let requests: [FederatedDeviceLinkSessionRequest] = try await viewModel.fetchPendingRequests(sessionId: sessionId)
      if let request: FederatedDeviceLinkSessionRequest = requests.first(where: { $0.requestId == requestId }) {
        return request
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(1))
    }

    throw AutomationProbeError.deviceLinkRequestMissing
  }

  private func waitForDeviceLinkApproval(
    viewModel: DeviceLinkViewModel,
    joinSession: DeviceLinkViewModel.JoinSession,
    timeout: TimeInterval
  ) async throws -> FederatedDeviceLinkPollResponse {
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))
    while Date() < deadline {
      let response: FederatedDeviceLinkPollResponse = try await viewModel.poll(joinSession: joinSession)
      if response.status == "approved" {
        return response
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(1))
    }

    throw AutomationProbeError.deviceLinkApprovalMissing
  }

  private func revokeLinkedDevice(deviceId: String, userHandle: String) async throws {
    let hostIdentity: PersistedDeviceIdentity = try currentHostDeviceIdentity(userHandle: normalizedHandle(userHandle))
    let proof: String = "revoke|\(deviceId)|"
    let signature: String = try container.deviceKeysService.signMessage(message: proof, identity: hostIdentity)

    try await container.deviceLinkService.revokeDevice(deviceId: deviceId, signature: signature, timestamp: nil)

    let prekeys: FederatedPrekeysGetResponse = try await container.authService.fetchPrekeys(
      userHandle: userHandle,
      deviceId: deviceId,
      peek: true
    )
    if !prekeys.bundles.isEmpty {
      throw AutomationProbeError.revokedDeviceStillAdvertised
    }

    log("[E2E][DeviceLink] Revoked same-account device \(deviceId)")
  }

  private func makeDeviceLinkProbeContainer(_ config: E2EAutomationConfiguration) -> AppContainer {
    var environment: [String: String] = container.launchConfiguration.environment
    let namespaceSuffix: String = UUID().uuidString.lowercased()
    environment["UITEST_MODE"] = "1"
    environment["UITEST_STORAGE_NAMESPACE"] = "device-link-\(config.runId)-\(namespaceSuffix)"
    environment["UITEST_RESET_STATE"] = "1"
    environment["UITEST_BOOTSTRAP_SAMPLE_DATA"] = "0"
    environment["UITEST_STUB_NETWORK"] = "0"
    environment["UITEST_DISABLE_REALTIME"] = "1"

    let launchConfiguration = AppLaunchConfiguration(environment: environment)
    let probeContainer = AppContainer(
      environment: container.environment,
      launchConfiguration: launchConfiguration
    )
    AppTestStateManager.resetIfNeeded(
      configuration: launchConfiguration,
      defaults: probeContainer.defaults,
      tokenStore: probeContainer.tokenStore,
      keyMaterialStore: probeContainer.keyMaterialStore,
      sessionStore: probeContainer.sessionStore
    )
    return probeContainer
  }

  private func currentHostDeviceIdentity(userHandle: String) throws -> PersistedDeviceIdentity {
    let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: userHandle,
      sessionUser: container.sessionStore.currentUser
    )

    for lookupId in lookupIds {
      if let identity: PersistedDeviceIdentity = container.keyMaterialStore.deviceIdentity(for: lookupId) {
        return identity
      }
    }

    throw AutomationProbeError.hostDeviceIdentityMissing
  }

  private func runInitiatorFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    guard !config.targetUserId.isEmpty else {
      failAutomation("Initiator requires E2E_TARGET_USER_ID")
      return false
    }

    let trustReady: Bool = await viewModel.ensureProtectedTrust(
      with: config.targetUserId,
      timeout: config.socketTimeoutSeconds
    )
    guard trustReady else {
      failAutomation("Initiator could not establish protected E2E trust with peer")
      return false
    }

    await viewModel.loadConversations()
    await viewModel.createDirectConversation(with: config.targetUserId)

    guard viewModel.activeConversationId != nil else {
      markScenario(ScenarioID.startDirectChat, status: .fail, detail: viewModel.lastErrorMessage ?? "conversation create failed")
      failAutomation("Initiator could not create direct conversation")
      return false
    }
    markScenario(ScenarioID.startDirectChat, status: .pass)

    await viewModel.joinActiveConversationSocket()
    await viewModel.loadMessages()
    let textSent: Bool = await viewModel.sendMessage("\(config.message) [\(config.runId)]")
    if textSent {
      markScenario(ScenarioID.sendMessage, status: .pass)
    } else {
      markScenario(ScenarioID.sendMessage, status: .fail, detail: viewModel.lastErrorMessage ?? "text send failed")
      return false
    }

    if config.performAttachmentFlow {
      let attachmentPayload: Data = Data("attachment-\(config.runId)".utf8)
      let attachmentSent: Bool = await viewModel.sendAttachment(
        data: attachmentPayload,
        fileName: "e2e-\(config.runId).txt",
        mimeType: "text/plain",
        type: .file
      )

      if attachmentSent {
        markScenario(ScenarioID.sendAttachment, status: .pass)
      } else {
        markScenario(ScenarioID.sendAttachment, status: .fail, detail: viewModel.lastErrorMessage ?? "attachment send failed")
        return false
      }
    } else {
      markScenario(ScenarioID.sendAttachment, status: .skip, detail: "attachment flow disabled")
    }

    if config.performVoiceMessageFlow {
      let voicePayload: Data = Data((0..<3072).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
      let voiceSent: Bool = await viewModel.sendAttachment(
        data: voicePayload,
        fileName: "voice-\(config.runId).m4a",
        mimeType: "audio/m4a",
        type: .media
      )

      if voiceSent {
        markScenario(ScenarioID.sendVoiceMessage, status: .pass)
      } else {
        markScenario(ScenarioID.sendVoiceMessage, status: .fail, detail: viewModel.lastErrorMessage ?? "voice send failed")
        return false
      }
    } else {
      markScenario(ScenarioID.sendVoiceMessage, status: .skip, detail: "voice flow disabled")
    }

    if config.performCallFlow {
      let requestedTypes: Set<Call.CallType> = Set(config.callTypes)
      for callType in config.callTypes {
        let callFlowPassed: Bool = await performInitiatorCallFlow(config, callType: callType)
        let scenarioId: String = callType == .voice ? ScenarioID.audioCall : ScenarioID.videoCall
        if !callFlowPassed {
          markScenario(scenarioId, status: .fail, detail: viewModel.lastErrorMessage ?? "\(callType.rawValue) call flow failed")
          return false
        }
        let mediaDetail: String? = lastCallMediaDetailByScenario.removeValue(forKey: scenarioId)
        markScenario(scenarioId, status: .pass, detail: mediaDetail)
      }

      if !requestedTypes.contains(.voice) {
        markScenario(ScenarioID.audioCall, status: .skip, detail: "voice call was not requested")
      }
      if !requestedTypes.contains(.video) {
        markScenario(ScenarioID.videoCall, status: .skip, detail: "video call was not requested")
      }
    } else {
      markScenario(ScenarioID.audioCall, status: .skip, detail: "call flow disabled")
      markScenario(ScenarioID.videoCall, status: .skip, detail: "call flow disabled")
    }

    return true
  }

  private func runReceiverFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    guard !config.targetUserId.isEmpty else {
      failAutomation("Receiver requires E2E_TARGET_USER_ID")
      return false
    }

    let trustReady: Bool = await viewModel.ensureProtectedTrust(
      with: config.targetUserId,
      timeout: config.socketTimeoutSeconds
    )
    guard trustReady else {
      failAutomation("Receiver could not establish protected E2E trust with peer")
      return false
    }

    await viewModel.createDirectConversation(with: config.targetUserId)
    let hasConversation: Bool = await waitForConversation(timeout: config.conversationTimeoutSeconds)
    guard hasConversation else {
      markScenario(ScenarioID.startDirectChat, status: .fail, detail: "receiver did not get conversation")
      failAutomation("Receiver did not get conversation in \(config.conversationTimeoutSeconds)s")
      return false
    }
    markScenario(ScenarioID.startDirectChat, status: .pass)

    await viewModel.joinActiveConversationSocket()
    let hasIncomingMessages: Bool = await waitForInboundMessages(
      timeout: config.conversationTimeoutSeconds,
      minCount: 1,
      type: .text
    )
    let hasIncomingAttachment: Bool = config.performAttachmentFlow
      ? await waitForInboundMessages(
        timeout: config.conversationTimeoutSeconds,
        minCount: 1,
        type: .file
      )
      : false
    let hasIncomingVoiceMessage: Bool = config.performVoiceMessageFlow
      ? await waitForInboundMessages(
        timeout: config.conversationTimeoutSeconds,
        minCount: 1,
        type: .media,
        contentContains: ".m4a"
      )
      : false

    markScenario(
      ScenarioID.receiveMessage,
      status: hasIncomingMessages ? .pass : .fail,
      detail: hasIncomingMessages ? nil : "no inbound messages after sync"
    )
    markScenario(
      ScenarioID.receiveAttachment,
      status: config.performAttachmentFlow ? (hasIncomingAttachment ? .pass : .fail) : .skip,
      detail: config.performAttachmentFlow ? (hasIncomingAttachment ? nil : "no inbound attachment in sync stream") : "attachment flow disabled"
    )
    markScenario(
      ScenarioID.receiveVoiceMessage,
      status: config.performVoiceMessageFlow ? (hasIncomingVoiceMessage ? .pass : .fail) : .skip,
      detail: config.performVoiceMessageFlow ? (hasIncomingVoiceMessage ? nil : "no inbound voice message in sync stream") : "voice flow disabled"
    )

    if !hasIncomingMessages {
      return false
    }
    if config.performAttachmentFlow && !hasIncomingAttachment {
      return false
    }
    if config.performVoiceMessageFlow && !hasIncomingVoiceMessage {
      return false
    }

    if config.receiverSendsReply {
      let replySent: Bool = await viewModel.sendMessage("ACK from receiver [\(config.runId)]")
      if !replySent {
        markScenario(ScenarioID.sendMessage, status: .fail, detail: viewModel.lastErrorMessage ?? "receiver reply failed")
        return false
      }
    }

    if config.performCallFlow {
      let requestedTypes: Set<Call.CallType> = Set(config.callTypes)
      for callType in config.callTypes {
        let callFlowPassed: Bool = await performReceiverCallFlow(config, callType: callType)
        let scenarioId: String = callType == .voice ? ScenarioID.audioCall : ScenarioID.videoCall
        if !callFlowPassed {
          markScenario(scenarioId, status: .fail, detail: viewModel.lastErrorMessage ?? "receiver \(callType.rawValue) call flow failed")
          return false
        }
        let mediaDetail: String? = lastCallMediaDetailByScenario.removeValue(forKey: scenarioId)
        markScenario(scenarioId, status: .pass, detail: mediaDetail)
      }

      if !requestedTypes.contains(.voice) {
        markScenario(ScenarioID.audioCall, status: .skip, detail: "voice call was not requested")
      }
      if !requestedTypes.contains(.video) {
        markScenario(ScenarioID.videoCall, status: .skip, detail: "video call was not requested")
      }
    } else {
      markScenario(ScenarioID.audioCall, status: .skip, detail: "call flow disabled")
      markScenario(ScenarioID.videoCall, status: .skip, detail: "call flow disabled")
    }

    return true
  }

  private func runCompanionFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    markScenario(
      ScenarioID.deviceLinkSameAccount,
      status: .skip,
      detail: "validate QR/link-code linking manually on the third physical device before companion sync"
    )
    markScenario(
      ScenarioID.revokeDevice,
      status: .skip,
      detail: "validate revoke-device manually after multi-device sync confirmation"
    )

    guard config.requireNewDeviceSyncCheck else {
      markScenario(ScenarioID.newDeviceSync, status: .skip, detail: "new-device sync check disabled")
      return true
    }

    guard !config.targetUserId.isEmpty else {
      markScenario(ScenarioID.newDeviceSync, status: .fail, detail: "companion requires E2E_TARGET_USER_ID")
      failAutomation("Companion requires E2E_TARGET_USER_ID")
      return false
    }

    await viewModel.loadConversations()
    await viewModel.createDirectConversation(with: config.targetUserId)

    let hasConversation: Bool = await waitForConversation(timeout: config.conversationTimeoutSeconds)
    guard hasConversation else {
      markScenario(ScenarioID.newDeviceSync, status: .fail, detail: "companion did not hydrate same-account conversation")
      failAutomation("Companion did not load same-account conversation in \(config.conversationTimeoutSeconds)s")
      return false
    }

    await viewModel.joinActiveConversationSocket()

    let runMarker: String = config.runId
    let syncDeadline: Date = Date().addingTimeInterval(max(1, config.conversationTimeoutSeconds))
    let remainingTimeout: () -> TimeInterval = {
      max(1, syncDeadline.timeIntervalSinceNow)
    }

    let syncedText: Bool = await waitForConversationMessages(
      timeout: remainingTimeout(),
      minCount: 1,
      type: .text,
      contentContains: runMarker
    )
    guard syncedText else {
      let detail: String = "same-account sync missing text=false attachment=unknown voice=unknown"
      markScenario(ScenarioID.newDeviceSync, status: .fail, detail: detail)
      failAutomation(detail)
      return false
    }

    let syncedAttachment: Bool
    if config.performAttachmentFlow {
      syncedAttachment = await waitForConversationMessages(
        timeout: remainingTimeout(),
        minCount: 1,
        type: .file,
        contentContains: runMarker
      )

      guard syncedAttachment else {
        let detail: String = "same-account sync missing text=true attachment=false voice=unknown"
        markScenario(ScenarioID.newDeviceSync, status: .fail, detail: detail)
        failAutomation(detail)
        return false
      }
    } else {
      syncedAttachment = true
    }

    let syncedVoiceMessage: Bool
    if config.performVoiceMessageFlow {
      syncedVoiceMessage = await waitForConversationMessages(
        timeout: remainingTimeout(),
        minCount: 1,
        type: .media,
        contentContains: runMarker
      )

      guard syncedVoiceMessage else {
        let detail: String = "same-account sync missing text=true attachment=\(syncedAttachment) voice=false"
        markScenario(ScenarioID.newDeviceSync, status: .fail, detail: detail)
        failAutomation(detail)
        return false
      }
    } else {
      syncedVoiceMessage = true
    }

    markScenario(ScenarioID.newDeviceSync, status: .pass)
    return true
  }

  private func runPushValidationFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    guard config.performPushRegistration else {
      markScenario(ScenarioID.pushMessageNotification, status: .skip, detail: "push registration disabled")
      markScenario(ScenarioID.pushMissedCallNotification, status: .skip, detail: "push registration disabled")
      return true
    }

    if config.role == .companion {
      let detail: String = "push validation is executed on initiator/receiver pair only"
      markScenario(ScenarioID.pushMessageNotification, status: .skip, detail: detail)
      markScenario(ScenarioID.pushMissedCallNotification, status: .skip, detail: detail)
      return true
    }

    if config.role == .receiver {
      let tokenAvailable: Bool = await viewModel.waitForAPNSToken(timeout: max(20, config.socketTimeoutSeconds))
      guard tokenAvailable else {
        let detail: String = "APNS token was not received on receiver"
        markScenario(ScenarioID.pushMessageNotification, status: .fail, detail: detail)
        markScenario(ScenarioID.pushMissedCallNotification, status: .fail, detail: detail)
        return false
      }

      let registered: Bool = await viewModel.registerCurrentDeviceToken()
      guard registered else {
        let detail: String = viewModel.lastErrorMessage ?? "push token registration failed"
        markScenario(ScenarioID.pushMessageNotification, status: .fail, detail: detail)
        markScenario(ScenarioID.pushMissedCallNotification, status: .fail, detail: detail)
        return false
      }

      return await runReceiverPushValidationFlow(config)
    }

    return await runInitiatorPushValidationFlow(config)
  }

  private func runInitiatorPushValidationFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    let messageReady: String = pushReadyMarker(for: .message, runId: config.runId)
    let messagePayload: String = pushPayloadMarker(runId: config.runId)
    let missedTag: String = pushMissedCallTag(runId: config.runId)

    let receiverReadyForMessagePush: Bool = await waitForInboundMessages(
      timeout: max(20, config.conversationTimeoutSeconds),
      minCount: 1,
      type: .text,
      contentContains: messageReady
    )
    guard receiverReadyForMessagePush else {
      let detail: String = "receiver did not publish message push readiness marker"
      markScenario(ScenarioID.pushMessageNotification, status: .fail, detail: detail)
      markScenario(ScenarioID.pushMissedCallNotification, status: .fail, detail: "message push phase never started")
      return false
    }

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(PushValidationTiming.sendGraceSeconds))

    let messageSent: Bool = await viewModel.sendMessage(messagePayload)
    guard messageSent else {
      let detail: String = viewModel.lastErrorMessage ?? "initiator failed to send push-triggering message"
      markScenario(ScenarioID.pushMessageNotification, status: .fail, detail: detail)
      markScenario(ScenarioID.pushMissedCallNotification, status: .fail, detail: "message push phase failed")
      return false
    }

    markScenario(
      ScenarioID.pushMessageNotification,
      status: .pass,
      detail: "initiator dispatched real APNS message payload after receiver readiness"
    )

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(PushValidationTiming.missedCallDispatchDelaySeconds))

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(PushValidationTiming.sendGraceSeconds))

    let missedCallSent: Bool = await viewModel.sendMissedCallMarker(tag: missedTag)
    guard missedCallSent else {
      let detail: String = viewModel.lastErrorMessage ?? "initiator failed to send missed-call marker"
      markScenario(ScenarioID.pushMissedCallNotification, status: .fail, detail: detail)
      return false
    }

    markScenario(
      ScenarioID.pushMissedCallNotification,
      status: .pass,
      detail: "initiator dispatched real APNS missed-call payload after receiver readiness"
    )

    return true
  }

  private func runReceiverPushValidationFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    let messageReady: String = pushReadyMarker(for: .message, runId: config.runId)
    let messageAck: String = pushAckMarker(for: .message, runId: config.runId)
    let messagePayload: String = pushPayloadMarker(runId: config.runId)
    let missedReady: String = pushReadyMarker(for: .missedCall, runId: config.runId)
    let missedAck: String = pushAckMarker(for: .missedCall, runId: config.runId)
    let missedTag: String = pushMissedCallTag(runId: config.runId)
    let timeout: TimeInterval = max(20, config.conversationTimeoutSeconds)

    let messagePushReceived: Bool = await performReceiverPushCycle(
      hint: .message,
      readyMarker: messageReady,
      ackMarker: messageAck,
      timeout: timeout,
      validation: { [self] validationTimeout in
        let startedAt: Date = Date()
        let pushHandled: Bool = await viewModel.waitForRemoteNotification(
          hint: .message,
          timeout: validationTimeout,
          requireServerDelivery: true,
          after: startedAt
        )
        guard pushHandled else {
          return false
        }

        return await waitForInboundMessages(
          timeout: validationTimeout,
          minCount: 1,
          type: .text,
          contentContains: messagePayload
        )
      }
    )
    markScenario(
      ScenarioID.pushMessageNotification,
      status: messagePushReceived ? .pass : .fail,
      detail: messagePushReceived
        ? "receiver processed real APNS message notification and synced payload"
        : viewModel.lastErrorMessage ?? "receiver did not process real APNS message notification"
    )

    let missedCallPushReceived: Bool = await performReceiverPushCycle(
      hint: .missedCall,
      readyMarker: missedReady,
      ackMarker: missedAck,
      timeout: timeout,
      validation: { [self] validationTimeout in
        let startedAt: Date = Date()
        async let pushHandledTask: Bool = viewModel.waitForRemoteNotification(
          hint: .missedCall,
          timeout: validationTimeout,
          requireServerDelivery: true,
          after: startedAt
        )
        async let callMarkerReceivedTask: Bool = waitForInboundMessages(
          timeout: validationTimeout,
          minCount: 1,
          type: .callEnd,
          contentContains: missedTag
        )

        let callMarkerReceived: Bool = await callMarkerReceivedTask
        let pushHandled: Bool = await pushHandledTask

        if callMarkerReceived {
          return true
        }

        return pushHandled && callMarkerReceived
      }
    )
    markScenario(
      ScenarioID.pushMissedCallNotification,
      status: missedCallPushReceived ? .pass : .fail,
      detail: missedCallPushReceived
        ? "receiver processed real APNS missed-call notification and synced payload"
        : viewModel.lastErrorMessage ?? "receiver did not process real APNS missed-call notification"
    )

    return messagePushReceived && missedCallPushReceived
  }

  private func performReceiverPushCycle(
    hint: PushNotificationHint,
    readyMarker: String,
    ackMarker: String,
    timeout: TimeInterval,
    validation: @escaping (TimeInterval) async -> Bool
  ) async -> Bool {
    let readySent: Bool = await viewModel.sendMessage(readyMarker)
    guard readySent else {
      return false
    }

    await viewModel.disconnectSocket()
    let disconnected: Bool = await waitUntil(timeout: 10, pollInterval: 0.5) {
      if case .disconnected = self.viewModel.socketState {
        return true
      }
      return false
    }

    guard disconnected else {
      return false
    }

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(PushValidationTiming.receiverSettleSeconds))

    let validated: Bool = await validation(timeout)

    await viewModel.connectSocket()
    let reconnected: Bool = await waitUntil(timeout: max(10, timeout / 2), pollInterval: 0.5) {
      if case .connected = self.viewModel.socketState {
        return true
      }
      return false
    }

    guard reconnected else {
      return false
    }

    guard validated else {
      return false
    }

    let ackSent: Bool = await viewModel.sendMessage(ackMarker)
    if !ackSent {
      return false
    }

    return true
  }

  private func runPostPushCleanupFlow(_ config: E2EAutomationConfiguration) async -> Bool {
    guard config.role == .initiator else {
      return true
    }

    if config.performBlockFlow {
      let blocked: Bool = await viewModel.blockPeer(config.targetUserId)
      if blocked {
        markScenario(ScenarioID.blockUser, status: .pass)
      } else {
        markScenario(ScenarioID.blockUser, status: .fail, detail: viewModel.lastErrorMessage ?? "block flow failed")
        return false
      }
    } else {
      markScenario(ScenarioID.blockUser, status: .skip, detail: "block flow disabled")
    }

    if config.performDeleteConversationFlow {
      let deleted: Bool = await viewModel.deleteActiveConversation()
      if deleted {
        markScenario(ScenarioID.deleteDirectChat, status: .pass)
      } else {
        markScenario(ScenarioID.deleteDirectChat, status: .fail, detail: viewModel.lastErrorMessage ?? "delete flow failed")
        return false
      }
    } else {
      markScenario(ScenarioID.deleteDirectChat, status: .skip, detail: "delete flow disabled")
    }

    return true
  }

  private func runSettingsValidationFlow(_ config: E2EAutomationConfiguration, includeLogout: Bool) async -> Bool {
    guard config.performSettingsFlow else {
      markSettingsScenarios(status: .skip, detail: "settings flow disabled")
      return true
    }

    let settingsViewModel = SettingsViewModel(container: container, defaults: container.defaults)
    let normalizedUserHandle: String = normalizedHandle(config.userHandle)

    do {
      try await settingsViewModel.refreshSession()
      markScenario(ScenarioID.settingsRefreshSession, status: .pass)
    } catch {
      markScenario(ScenarioID.settingsRefreshSession, status: .fail, detail: describe(error))
      return false
    }

    let originalManualReadSetting: Bool = settingsViewModel.manualReadReceiptsEnabled
    settingsViewModel.setManualReadReceipts(enabled: !originalManualReadSetting)
    let toggledManualReadSetting: Bool = settingsViewModel.manualReadReceiptsEnabled
    settingsViewModel.setManualReadReceipts(enabled: originalManualReadSetting)
    guard toggledManualReadSetting == !originalManualReadSetting
      && settingsViewModel.manualReadReceiptsEnabled == originalManualReadSetting
    else {
      markScenario(ScenarioID.settingsManualReadReceipts, status: .fail, detail: "manual read receipts did not persist")
      return false
    }
    markScenario(ScenarioID.settingsManualReadReceipts, status: .pass)

    let exportedRecoveryPhrase: String
    do {
      exportedRecoveryPhrase = try settingsViewModel.exportPrivateKey()
      guard !exportedRecoveryPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        markScenario(ScenarioID.settingsRecoveryPhraseExport, status: .fail, detail: "exported key material is empty")
        return false
      }
      markScenario(ScenarioID.settingsRecoveryPhraseExport, status: .pass)
    } catch {
      markScenario(ScenarioID.settingsRecoveryPhraseExport, status: .fail, detail: describe(error))
      return false
    }

    do {
      try settingsViewModel.importPrivateKey(exportedRecoveryPhrase)
      guard settingsViewModel.hasPrivateKey else {
        markScenario(ScenarioID.settingsRecoveryPhraseImport, status: .fail, detail: "import did not preserve key material")
        return false
      }
      markScenario(ScenarioID.settingsRecoveryPhraseImport, status: .pass)
    } catch {
      markScenario(ScenarioID.settingsRecoveryPhraseImport, status: .fail, detail: describe(error))
      return false
    }

    do {
      let publicKey: PublicKeyResponse = try await settingsViewModel.fetchPublicKey(userHandle: normalizedUserHandle)
      guard normalizedHandle(publicKey.userId) == normalizedUserHandle,
        !publicKey.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        markScenario(
          ScenarioID.settingsPublicKeyLookup,
          status: .fail,
          detail: "public key lookup returned invalid identity or empty key"
        )
        return false
      }
      markScenario(ScenarioID.settingsPublicKeyLookup, status: .pass)
    } catch {
      markScenario(ScenarioID.settingsPublicKeyLookup, status: .fail, detail: describe(error))
      return false
    }

    do {
      let tokens: [DeviceToken] = try await settingsViewModel.listDeviceTokens()
      markScenario(ScenarioID.settingsNotificationTokenList, status: .pass, detail: "tokens=\(tokens.count)")
    } catch {
      markScenario(ScenarioID.settingsNotificationTokenList, status: .fail, detail: describe(error))
      return false
    }

    await settingsViewModel.refreshNetworkDiagnostics(force: true)
    let diagnosticsSummary: String = settingsViewModel.diagnosticsSummary()
    guard diagnosticsSummary.contains("user="), diagnosticsSummary.contains("key=present") else {
      markScenario(ScenarioID.settingsDiagnostics, status: .fail, detail: diagnosticsSummary)
      return false
    }
    markScenario(ScenarioID.settingsDiagnostics, status: .pass, detail: diagnosticsSummary)

    guard includeLogout else {
      markScenario(ScenarioID.settingsLogout, status: .skip, detail: "settings logout disabled")
      return true
    }

    await settingsViewModel.logout()
    guard settingsViewModel.currentUser == nil else {
      markScenario(ScenarioID.settingsLogout, status: .fail, detail: "current user still present after logout")
      return false
    }
    markScenario(ScenarioID.settingsLogout, status: .pass)
    return true
  }

  private func markSettingsScenarios(status: ScenarioStatus, detail: String) {
    markScenario(ScenarioID.settingsRefreshSession, status: status, detail: detail)
    markScenario(ScenarioID.settingsManualReadReceipts, status: status, detail: detail)
    markScenario(ScenarioID.settingsRecoveryPhraseExport, status: status, detail: detail)
    markScenario(ScenarioID.settingsRecoveryPhraseImport, status: status, detail: detail)
    markScenario(ScenarioID.settingsPublicKeyLookup, status: status, detail: detail)
    markScenario(ScenarioID.settingsNotificationTokenList, status: status, detail: detail)
    markScenario(ScenarioID.settingsDiagnostics, status: status, detail: detail)
    markScenario(ScenarioID.settingsLogout, status: status, detail: detail)
  }

  private func markNonSettingsScenariosDisabledForSettingsOnly() {
    markScenario(ScenarioID.newDeviceSync, status: .skip, detail: "new-device sync check disabled")
    markScenario(ScenarioID.deviceLinkSameAccount, status: .skip, detail: "device-link flow disabled")
    markScenario(ScenarioID.revokeDevice, status: .skip, detail: "device-link flow disabled")
    markScenario(ScenarioID.startDirectChat, status: .skip, detail: "conversation flow disabled")
    markScenario(ScenarioID.deleteDirectChat, status: .skip, detail: "delete flow disabled")
    markScenario(ScenarioID.blockUser, status: .skip, detail: "block flow disabled")
    markScenario(ScenarioID.audioCall, status: .skip, detail: "call flow disabled")
    markScenario(ScenarioID.videoCall, status: .skip, detail: "call flow disabled")
    markScenario(ScenarioID.sendMessage, status: .skip, detail: "message flow disabled")
    markScenario(ScenarioID.receiveMessage, status: .skip, detail: "message flow disabled")
    markScenario(ScenarioID.pushMessageNotification, status: .skip, detail: "push registration disabled")
    markScenario(ScenarioID.pushMissedCallNotification, status: .skip, detail: "push registration disabled")
    markScenario(ScenarioID.sendAttachment, status: .skip, detail: "attachment flow disabled")
    markScenario(ScenarioID.receiveAttachment, status: .skip, detail: "attachment flow disabled")
    markScenario(ScenarioID.sendVoiceMessage, status: .skip, detail: "voice flow disabled")
    markScenario(ScenarioID.receiveVoiceMessage, status: .skip, detail: "voice flow disabled")
  }

  private func performInitiatorCallFlow(
    _ config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    if config.validateCallPictureInPictureBackground && callType == .video {
      return await performInitiatorRealUICallFlow(config, callType: callType)
    }

    let mediaPermissionsGranted: Bool = await ensureMediaPermissionsGranted()
    guard mediaPermissionsGranted else {
      failAutomation("Initiator media permissions are not granted (camera/microphone)")
      return false
    }

    await viewModel.startCall(receiverId: config.targetUserId, type: callType)

    guard let callId: String = viewModel.activeCallId else {
      failAutomation("Initiator could not start call")
      return false
    }
    markAutomationCallState(phase: "DIALING", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)

    let rtcConfig: RTCConfig = await resolvedRTCConfig()

    viewModel.resetPendingCallSignals(callId: callId)

    let mediaEngine: WebRTCAutomationEngine
    do {
      let iceServers: [WebRTC.RTCIceServer] = CallRelayIceServerMapper.map(rtcConfig)
      mediaEngine = try WebRTCAutomationEngine(iceServers: iceServers, includeVideo: callType == .video) { [weak self] line in
        guard let self else { return }
        Task { @MainActor in
          self.log(line)
        }
      }
    } catch {
      failAutomation("Initiator media engine setup failed: \(error.localizedDescription)")
      return false
    }

    let toneController = CallToneController()
    defer {
      toneController.stop()
      mediaEngine.stop()
      viewModel.resetPendingCallSignals(callId: callId)
    }

    mediaEngine.onLocalCandidate = { [weak self] candidate in
      guard let self else { return }
      Task { @MainActor in
        let sent: Bool = await self.viewModel.sendCallICECandidate(
          callId: callId,
          targetUserId: config.targetUserId,
          candidate: candidate
        )
        self.log("[E2E][Media] Local relay ICE candidate signaling \(sent ? "sent" : "failed")")
      }
    }

    do {
      try await mediaEngine.startLocalMedia()
    } catch {
      failAutomation("Initiator failed to start local media: \(error.localizedDescription)")
      return false
    }

    let offer: CallSessionDescriptionSignal
    do {
      offer = try await mediaEngine.createOffer(callId: callId)
    } catch {
      failAutomation("Initiator failed to create SDP offer: \(error.localizedDescription)")
      return false
    }

    let offerSent: Bool = await viewModel.sendCallOffer(
      callId: callId,
      targetUserId: config.targetUserId,
      description: offer
    )
    guard offerSent else {
      failAutomation("Initiator failed to send call offer")
      return false
    }
    markAutomationCallState(phase: "CONNECTING", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)

    let answerReady: Bool = await waitUntil(timeout: config.incomingCallTimeoutSeconds, pollInterval: 0.5) {
      self.viewModel.pendingCallAnswer(callId: callId) != nil
    }

    guard answerReady, let answer: CallSessionDescriptionSignal = viewModel.takePendingCallAnswer(callId: callId) else {
      failAutomation("Initiator did not receive SDP answer in \(config.incomingCallTimeoutSeconds)s")
      return false
    }

    do {
      try await mediaEngine.applyRemoteDescription(answer)
    } catch {
      failAutomation("Initiator failed to apply remote SDP answer: \(error.localizedDescription)")
      return false
    }

    let _ = await viewModel.flushCallCandidates(callId: callId)

    let mediaReady: Bool = await waitForBidirectionalMedia(
      callId: callId,
      targetUserId: config.targetUserId,
      engine: mediaEngine,
      config: config,
      callType: callType
    )
    guard mediaReady else {
      return false
    }
    markAutomationCallState(phase: "ACTIVE", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(config.callDurationSeconds))
    await viewModel.endCurrentCall()
    markAutomationCallState(phase: "ENDED", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)
    return true
  }

  private func performInitiatorRealUICallFlow(
    _ config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    guard let callScreenPresenter else {
      failAutomation("PiP validation requires a real call screen presenter")
      return false
    }

    guard let session: E2ECallSessionViewModel = viewModel.makeOutgoingCallSession(
      receiverId: config.targetUserId,
      type: callType
    ) else {
      failAutomation(viewModel.lastErrorMessage ?? "Initiator could not create real UI call session")
      return false
    }

    let callId: String = session.activeCallId
    markAutomationCallState(phase: "DIALING", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)

    guard callScreenPresenter(session) else {
      failAutomation("Initiator could not present real call UI for PiP validation")
      return false
    }

    markAutomationCallState(phase: "CONNECTING", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)

    guard await waitForRealUICallConnected(
      session: session,
      callId: callId,
      peer: config.targetUserId,
      config: config,
      callType: callType
    ) else {
      return false
    }

    await runManualPictureInPictureStartProbeIfNeeded(
      session: session,
      callId: callId,
      config: config,
      callType: callType
    )
    markAutomationCallState(phase: "ACTIVE", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)
    try? await Task.sleep(nanoseconds: secondsToNanoseconds(config.callDurationSeconds))
    await session.endFromUser()
    markAutomationCallState(phase: "ENDED", role: config.role, callType: callType, callId: callId, peer: config.targetUserId)
    return true
  }

  private func performReceiverCallFlow(
    _ config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    if config.validateCallPictureInPictureBackground && callType == .video {
      return await performReceiverRealUICallFlow(config, callType: callType)
    }

    let mediaPermissionsGranted: Bool = await ensureMediaPermissionsGranted()
    guard mediaPermissionsGranted else {
      failAutomation("Receiver media permissions are not granted (camera/microphone)")
      return false
    }

    let previousIncomingCallId: String? = viewModel.lastIncomingCallId
    let incomingCallReady: Bool = await waitUntil(timeout: config.incomingCallTimeoutSeconds, pollInterval: 0.5) {
      guard let currentIncomingCallId: String = self.viewModel.lastIncomingCallId else {
        return false
      }

      if self.viewModel.pendingCallOffer(callId: currentIncomingCallId) != nil {
        return true
      }

      return currentIncomingCallId != previousIncomingCallId
    }

    guard incomingCallReady, let callId: String = viewModel.lastIncomingCallId else {
      failAutomation("Receiver did not receive incoming call in \(config.incomingCallTimeoutSeconds)s")
      return false
    }

    guard let callerId: String = viewModel.lastIncomingCallerId, !callerId.isEmpty else {
      failAutomation("Receiver did not get caller ID for call \(callId)")
      return false
    }
    markAutomationCallState(phase: "RINGING", role: config.role, callType: callType, callId: callId, peer: callerId)

    let offerReady: Bool = await waitUntil(timeout: config.incomingCallTimeoutSeconds, pollInterval: 0.5) {
      self.viewModel.pendingCallOffer(callId: callId) != nil
    }

    guard offerReady else {
      failAutomation("Receiver did not receive SDP offer in \(config.incomingCallTimeoutSeconds)s")
      return false
    }

    let incomingDescriptor: E2EIncomingCallDescriptor? = viewModel.pendingIncomingCallDescriptor(
      callId: callId,
      callType: callType
    )

    guard let offer: CallSessionDescriptionSignal = viewModel.takePendingCallOffer(callId: callId) else {
      failAutomation("Receiver could not load pending SDP offer for call \(callId)")
      return false
    }

    if let descriptor: E2EIncomingCallDescriptor = incomingDescriptor {
      let audioSessionReady: Bool = await SystemCallCoordinator.shared.answerIncomingCallThroughCallKit(
        descriptor,
        audioActivationTimeout: 8
      )
      if audioSessionReady {
        log("[E2E][CallKit] Incoming call audio session activated before media start")
      } else {
        log("[E2E][CallKit] Incoming call audio session was not activated before media start")
      }
    } else {
      log("[E2E][CallKit] Incoming call descriptor unavailable for CallKit answer")
    }

    await viewModel.answerIncomingCall(callId: callId)

    guard viewModel.activeCallId == callId else {
      failAutomation("Receiver could not answer incoming call")
      return false
    }
    markAutomationCallState(phase: "CONNECTING", role: config.role, callType: callType, callId: callId, peer: callerId)

    let rtcConfig: RTCConfig = await resolvedRTCConfig()

    let mediaEngine: WebRTCAutomationEngine
    do {
      let iceServers: [WebRTC.RTCIceServer] = CallRelayIceServerMapper.map(rtcConfig)
      mediaEngine = try WebRTCAutomationEngine(iceServers: iceServers, includeVideo: callType == .video) { [weak self] line in
        guard let self else { return }
        Task { @MainActor in
          self.log(line)
        }
      }
    } catch {
      failAutomation("Receiver media engine setup failed: \(error.localizedDescription)")
      return false
    }

    let toneController = CallToneController()
    defer {
      toneController.stop()
      mediaEngine.stop()
      viewModel.resetPendingCallSignals(callId: callId)
    }

    mediaEngine.onLocalCandidate = { [weak self] candidate in
      guard let self else { return }
      Task { @MainActor in
        let sent: Bool = await self.viewModel.sendCallICECandidate(
          callId: callId,
          targetUserId: callerId,
          candidate: candidate
        )
        self.log("[E2E][Media] Local relay ICE candidate signaling \(sent ? "sent" : "failed")")
      }
    }

    do {
      try await mediaEngine.applyRemoteDescription(offer)
    } catch {
      failAutomation("Receiver failed to apply SDP offer: \(error.localizedDescription)")
      return false
    }

    do {
      try await mediaEngine.startLocalMedia()
    } catch {
      failAutomation("Receiver failed to start local media after SDP offer: \(error.localizedDescription)")
      return false
    }

    let answer: CallSessionDescriptionSignal
    do {
      answer = try await mediaEngine.createAnswer(callId: callId)
    } catch {
      failAutomation("Receiver failed to create SDP answer: \(error.localizedDescription)")
      return false
    }

    let answerSent: Bool = await viewModel.sendCallAnswer(callId: callId, description: answer)
    guard answerSent else {
      failAutomation("Receiver failed to send call answer")
      return false
    }

    let _ = await viewModel.flushCallCandidates(callId: callId)

    let mediaReady: Bool = await waitForBidirectionalMedia(
      callId: callId,
      targetUserId: callerId,
      engine: mediaEngine,
      config: config,
      callType: callType
    )
    guard mediaReady else {
      return false
    }
    markAutomationCallState(phase: "ACTIVE", role: config.role, callType: callType, callId: callId, peer: callerId)

    try? await Task.sleep(nanoseconds: secondsToNanoseconds(config.callDurationSeconds))
    await viewModel.endCurrentCall()
    markAutomationCallState(phase: "ENDED", role: config.role, callType: callType, callId: callId, peer: callerId)
    return true
  }

  private func performReceiverRealUICallFlow(
    _ config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    guard let callScreenPresenter else {
      failAutomation("PiP validation requires a real call screen presenter")
      return false
    }

    let previousIncomingCallId: String? = viewModel.lastIncomingCallId
    let incomingCallReady: Bool = await waitUntil(timeout: config.incomingCallTimeoutSeconds, pollInterval: 0.5) {
      guard let currentIncomingCallId: String = self.viewModel.lastIncomingCallId else {
        return false
      }

      if self.viewModel.pendingCallOffer(callId: currentIncomingCallId) != nil {
        return true
      }

      return currentIncomingCallId != previousIncomingCallId
    }

    guard incomingCallReady, let callId: String = viewModel.lastIncomingCallId else {
      failAutomation("Receiver did not receive incoming call in \(config.incomingCallTimeoutSeconds)s")
      return false
    }

    guard let callerId: String = viewModel.lastIncomingCallerId, !callerId.isEmpty else {
      failAutomation("Receiver did not get caller ID for call \(callId)")
      return false
    }
    markAutomationCallState(phase: "RINGING", role: config.role, callType: callType, callId: callId, peer: callerId)

    let offerReady: Bool = await waitUntil(timeout: config.incomingCallTimeoutSeconds, pollInterval: 0.5) {
      self.viewModel.pendingCallOffer(callId: callId) != nil
    }

    guard offerReady else {
      failAutomation("Receiver did not receive SDP offer in \(config.incomingCallTimeoutSeconds)s")
      return false
    }

    guard let incomingDescriptor: E2EIncomingCallDescriptor = viewModel.pendingIncomingCallDescriptor(
      callId: callId,
      callType: callType
    ) else {
      failAutomation("Receiver could not resolve incoming CallKit descriptor for real UI call")
      return false
    }

    let audioSessionReady: Bool = await SystemCallCoordinator.shared.answerIncomingCallThroughCallKit(
      incomingDescriptor,
      audioActivationTimeout: 8
    )
    guard audioSessionReady else {
      failAutomation("Receiver CallKit audio session did not activate for real UI call")
      return false
    }
    log("[E2E][CallKit] Incoming real UI call answered with audio session activated")

    let retainedSessionReady: Bool = await waitUntil(timeout: 3, pollInterval: 0.1) {
      self.container.e2eCallSessionStore.session(callId: callId) != nil
    }
    guard retainedSessionReady,
      let session: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: callId)
    else {
      failAutomation("Receiver CallKit answer did not retain the real UI call session")
      return false
    }

    guard callScreenPresenter(session) else {
      failAutomation("Receiver could not present real call UI for PiP validation")
      return false
    }

    markAutomationCallState(phase: "CONNECTING", role: config.role, callType: callType, callId: callId, peer: callerId)

    guard await waitForRealUICallConnected(
      session: session,
      callId: callId,
      peer: callerId,
      config: config,
      callType: callType
    ) else {
      return false
    }

    markAutomationCallState(phase: "ACTIVE", role: config.role, callType: callType, callId: callId, peer: callerId)
    try? await Task.sleep(nanoseconds: secondsToNanoseconds(config.callDurationSeconds))
    await session.endFromUser()
    markAutomationCallState(phase: "ENDED", role: config.role, callType: callType, callId: callId, peer: callerId)
    return true
  }

  private func waitForRealUICallConnected(
    session: E2ECallSessionViewModel,
    callId: String,
    peer: String,
    config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(max(1, config.mediaTimeoutSeconds))
    var lastStatus: String = session.statusText

    while Date() < deadline {
      lastStatus = session.statusText
      switch session.state {
      case .connected:
        let scenarioId: String = callType == .voice ? ScenarioID.audioCall : ScenarioID.videoCall
        lastCallMediaDetailByScenario[scenarioId] =
          "real_ui=1 state=connected status=\"\(lastStatus)\" pip=\"\(session.pictureInPictureDiagnosticsSummary)\""
        PiPDiagnosticRecorder.shared.record(
          category: "automation_call",
          name: "real_ui_connected",
          callId: callId,
          detail: "peer=\(peer) type=\(callType.rawValue) \(session.pictureInPictureDiagnosticsSummary)"
        )
        return true
      case .failed(let reason):
        failAutomation("Real UI call \(callId) failed before media connected: \(reason)")
        return false
      case .ended:
        failAutomation("Real UI call \(callId) ended before media connected")
        return false
      default:
        break
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(0.5))
    }

    PiPDiagnosticRecorder.shared.record(
      category: "media_flow",
      name: "real_ui_call_connect_timeout",
      callId: callId,
      detail: "peer=\(peer) type=\(callType.rawValue) status=\(lastStatus) \(session.pictureInPictureDiagnosticsSummary)"
    )
    failAutomation(
      "Real UI call \(callId) did not connect in \(config.mediaTimeoutSeconds)s: \(lastStatus). " +
        session.pictureInPictureDiagnosticsSummary
    )
    return false
  }

  private func runManualPictureInPictureStartProbeIfNeeded(
    session: E2ECallSessionViewModel,
    callId: String,
    config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async {
    guard config.manuallyStartCallPictureInPictureBeforeBackground,
      callType == .video
    else {
      return
    }

    PiPDiagnosticRecorder.shared.record(
      category: "call_startup",
      name: "call_pip_manual_active_probe_begin",
      callId: callId,
      detail: session.pictureInPictureDiagnosticsSummary
    )
    let didRequestStart: Bool = session.startPictureInPictureIfPossible(reason: "automation_active_probe")
    try? await Task.sleep(nanoseconds: secondsToNanoseconds(2.0))
    PiPDiagnosticRecorder.shared.record(
      category: "call_startup",
      name: "call_pip_manual_active_probe_end",
      callId: callId,
      detail: "didRequestStart=\(didRequestStart) \(session.pictureInPictureDiagnosticsSummary)"
    )
  }

  private func waitForBidirectionalMedia(
    callId: String,
    targetUserId: String,
    engine: WebRTCAutomationEngine,
    config: E2EAutomationConfiguration,
    callType: Call.CallType
  ) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(max(1, config.mediaTimeoutSeconds))
    var lastSnapshot: WebRTCMediaFlowSnapshot?

    while Date() < deadline {
      let pendingCandidates: [CallICECandidateSignal] = viewModel.takePendingCallICECandidates(callId: callId)
      for candidate in pendingCandidates {
        do {
          try await engine.queueRemoteCandidate(candidate)
        } catch {
          log("[E2E][Media] Failed to apply remote ICE candidate: \(error.localizedDescription)")
        }
      }

      let snapshot: WebRTCMediaFlowSnapshot = await engine.currentMediaSnapshot()
      lastSnapshot = snapshot

      let connectionReady: Bool =
        snapshot.connectionState == .connected
        || snapshot.iceConnectionState == .connected
        || snapshot.iceConnectionState == .completed

      let mediaReady: Bool = {
        if callType == .voice {
          return snapshot.hasBidirectionalAudio(minBytes: config.mediaMinBytes)
        }

        return snapshot.hasBidirectionalAudioVideo(minBytes: config.mediaMinBytes)
      }()

      if connectionReady && mediaReady {
        let scenarioId: String = callType == .voice ? ScenarioID.audioCall : ScenarioID.videoCall
        let mediaDetail: String = snapshot.summary()
        lastCallMediaDetailByScenario[scenarioId] = mediaDetail
        log("[E2E][Media] Bidirectional media ready for \(callType.rawValue) call \(callId). \(mediaDetail)")
        return true
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(1))
    }

    let snapshotSummary: String = lastSnapshot?.summary() ?? "no snapshot"
    PiPDiagnosticRecorder.shared.record(
      category: "media_flow",
      name: "media_flow_check_failed",
      callId: callId,
      detail: "peer=\(targetUserId) \(snapshotSummary)"
    )
    failAutomation("Media flow check failed for call \(callId) with peer \(targetUserId): \(snapshotSummary)")
    return false
  }

  private func ensureMediaPermissionsGranted() async -> Bool {
    let microphoneAllowed: Bool = await requestMicrophonePermission()
    let cameraAllowed: Bool = await requestCameraPermission()

    if !microphoneAllowed {
      log("[E2E][Media] Microphone permission is not granted")
    }
    if !cameraAllowed {
      log("[E2E][Media] Camera permission is not granted")
    }

    return microphoneAllowed && cameraAllowed
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func requestCameraPermission() async -> Bool {
    let status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }

  private func resolvedRTCConfig() async -> RTCConfig {
    if let current: RTCConfig = viewModel.latestRTCConfig {
      return current
    }

    do {
      let fetched: RTCConfig = try await container.callService.fetchTurnCredentials()
      log("[E2E][Media] relay-only TURN config fetched")
      return fetched
    } catch {
      log("[E2E][Media] relay-only TURN config unavailable")
    }

    return RTCConfig(
      iceServers: [],
      turnCredentials: TurnCredentials(username: "", password: "", ttl: 0),
      iceTransportPolicy: "relay"
    )
  }

  private func performAuthentication(_ config: E2EAutomationConfiguration) async -> AuthOutcome {
    switch config.authMode {
    case .register:
      await viewModel.register(userHandle: config.userHandle)
      return .registered
    case .login:
      await viewModel.login(userHandle: config.userHandle, seedPhrase: config.seedPhrase)
      return .loggedIn
    case .registerOrLogin:
      await viewModel.register(userHandle: config.userHandle)
      if viewModel.currentUser == nil {
        await viewModel.login(userHandle: config.userHandle, seedPhrase: config.seedPhrase)
        return .registerThenLogin
      }
      return .registered
    }
  }

  private func waitForConversation(timeout: TimeInterval) async -> Bool {
    let pollInterval: TimeInterval = 2
    let deadline: Date = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      await viewModel.loadConversations()
      if viewModel.activeConversationId != nil {
        return true
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(pollInterval))
    }

    return viewModel.activeConversationId != nil
  }

  private func waitForInboundMessages(
    timeout: TimeInterval,
    minCount: Int,
    type: Message.MessageType? = nil,
    contentContains: String? = nil
  ) async -> Bool {
    let pollInterval: TimeInterval = 1
    let requiredCount = max(1, minCount)
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))

    while Date() < deadline {
      await viewModel.loadMessages()
      if viewModel.inboundMessageCount(type: type, contentContains: contentContains) >= requiredCount {
        return true
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(pollInterval))
    }

    return viewModel.inboundMessageCount(type: type, contentContains: contentContains) >= requiredCount
  }

  private func waitForConversationMessages(
    timeout: TimeInterval,
    minCount: Int,
    type: Message.MessageType? = nil,
    contentContains: String? = nil
  ) async -> Bool {
    let pollInterval: TimeInterval = 1
    let requiredCount = max(1, minCount)
    let deadline: Date = Date().addingTimeInterval(max(1, timeout))

    while Date() < deadline {
      await viewModel.loadMessages()
      if viewModel.messageCount(
        type: type,
        contentContains: contentContains,
        includeCurrentUser: true
      ) >= requiredCount {
        return true
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(pollInterval))
    }

    return viewModel.messageCount(
      type: type,
      contentContains: contentContains,
      includeCurrentUser: true
    ) >= requiredCount
  }

  private func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 1,
    condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() {
        return true
      }

      try? await Task.sleep(nanoseconds: secondsToNanoseconds(pollInterval))
    }

    return condition()
  }

  private func normalizedHandle(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func pushReadyMarker(for hint: PushNotificationHint, runId: String) -> String {
    "[[push-ready:\(hint.rawValue):\(runId)]]"
  }

  private func pushAckMarker(for hint: PushNotificationHint, runId: String) -> String {
    "[[push-ack:\(hint.rawValue):\(runId)]]"
  }

  private func pushPayloadMarker(runId: String) -> String {
    "[[push-apns-message:\(runId)]]"
  }

  private func pushMissedCallTag(runId: String) -> String {
    "push-apns-missed:\(runId)"
  }

  private func failAutomation(_ reason: String) {
    let sanitizedReason: String = reason.replacingOccurrences(of: "\n", with: " ")
    let failureMessage: String = "AUTOMATION_FAILED \(sanitizedReason)"
    PiPDiagnosticRecorder.shared.record(
      category: "automation",
      name: "automation_failed",
      callId: viewModel.activeCallId ?? "none",
      detail: sanitizedReason
    )
    log("[E2E] \(failureMessage)")
    stateHandler(failureMessage, .systemRed)
  }

  private func describe(_ error: Error) -> String {
    if let localizedError: LocalizedError = error as? LocalizedError,
      let description: String = localizedError.errorDescription,
      !description.isEmpty
    {
      return description
    }

    return error.localizedDescription
  }

  private func markScenario(_ id: String, status: ScenarioStatus, detail: String? = nil) {
    let normalizedDetail: String = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if normalizedDetail.isEmpty {
      log("[E2E][SCENARIO] \(id)=\(status.rawValue)")
    } else {
      let sanitized = normalizedDetail.replacingOccurrences(of: "\n", with: " ")
      log("[E2E][SCENARIO] \(id)=\(status.rawValue) detail=\"\(sanitized)\"")
    }
  }

  private func markAutomationCallState(
    phase: String,
    role: E2EAutomationConfiguration.Role,
    callType: Call.CallType,
    callId: String,
    peer: String
  ) {
    let message = "AUTOMATION_CALL_\(phase) role=\(role.rawValue) type=\(callType.rawValue) callId=\(callId) peer=\(peer)"
    let color: UIColor = phase == "ACTIVE" ? .systemGreen : (phase == "ENDED" ? .systemGray : .systemOrange)
    PiPDiagnosticRecorder.shared.record(
      category: "automation_call",
      name: phase.lowercased(),
      callId: callId,
      detail: "role=\(role.rawValue) type=\(callType.rawValue) peer=\(peer)"
    )
    log("[E2E][CallUI] \(message)")
    stateHandler(message, color)
  }

  private func secondsToNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    let clampedSeconds: TimeInterval = max(0, seconds)
    return UInt64(clampedSeconds * 1_000_000_000)
  }

  private func log(_ line: String) {
    print(line)
    logHandler(line)
  }
}

struct E2EAutomationConfiguration {
  enum Role: String {
    case initiator
    case receiver
    case companion
  }

  enum AuthMode: String {
    case register
    case login
    case registerOrLogin = "register_or_login"
  }

  let role: Role
  let authMode: AuthMode
  let runId: String
  let userHandle: String
  let seedPhrase: String
  let targetUserId: String
  let message: String
  let callTypes: [Call.CallType]

  let startupDelaySeconds: TimeInterval
  let socketTimeoutSeconds: TimeInterval
  let conversationTimeoutSeconds: TimeInterval
  let incomingCallTimeoutSeconds: TimeInterval
  let callDurationSeconds: TimeInterval
  let mediaTimeoutSeconds: TimeInterval
  let mediaMinBytes: Int64

  let performRefresh: Bool
  let performCallFlow: Bool
  let performPushRegistration: Bool
  let receiverSendsReply: Bool
  let performDeviceLinkFlow: Bool
  let performAttachmentFlow: Bool
  let performVoiceMessageFlow: Bool
  let performBlockFlow: Bool
  let performDeleteConversationFlow: Bool
  let requireNewDeviceSyncCheck: Bool
  let performSettingsFlow: Bool
  let performSettingsLogout: Bool
  let deviceLifecycleOnly: Bool
  let settingsOnly: Bool
  let validateCallPictureInPictureBackground: Bool
  let manuallyStartCallPictureInPictureBeforeBackground: Bool

  static func fromProcessEnvironment() -> E2EAutomationConfiguration? {
    let environment: [String: String] = ProcessInfo.processInfo.environment

    let automationEnabled: Bool = readBool(environment["E2E_AUTORUN"], defaultValue: false)
    guard automationEnabled else {
      return nil
    }

    let roleRaw: String = (environment["E2E_ROLE"] ?? Role.initiator.rawValue).lowercased()
    let role: Role = Role(rawValue: roleRaw) ?? .initiator

    let authModeRaw: String = (environment["E2E_AUTH_MODE"] ?? AuthMode.registerOrLogin.rawValue).lowercased()
    let authMode: AuthMode = AuthMode(rawValue: authModeRaw) ?? .registerOrLogin

    let fallbackRunId: String = "run-\(UUID().uuidString.prefix(8))"
    let providedRunId: String? = environment["E2E_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let runId: String = (providedRunId?.isEmpty == false ? providedRunId : nil) ?? fallbackRunId

    let rolePrefix: String = {
      switch role {
      case .initiator:
        return "iosa"
      case .receiver:
        return "iosb"
      case .companion:
        return "iosc"
      }
    }()
    let sanitizedRunId: String = runId.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    let defaultUserHandle: String = "@\(String((rolePrefix + sanitizedRunId).prefix(24))):localhost"

    let userHandle: String = trim(environment["E2E_USER_HANDLE"], fallback: defaultUserHandle)
    let seedPhrase: String = trim(environment["E2E_SEED_PHRASE"], fallback: "")
    let targetUserId: String = trim(environment["E2E_TARGET_USER_ID"], fallback: "")
    let message: String = trim(environment["E2E_MESSAGE"], fallback: "Hello from iOS E2E")

    let callTypes: [Call.CallType] = parseCallTypes(environment["E2E_CALL_TYPE"])

    return E2EAutomationConfiguration(
      role: role,
      authMode: authMode,
      runId: runId,
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      targetUserId: targetUserId,
      message: message,
      callTypes: callTypes,
      startupDelaySeconds: readDouble(environment["E2E_STARTUP_DELAY_SECONDS"], defaultValue: 0),
      socketTimeoutSeconds: readDouble(environment["E2E_SOCKET_TIMEOUT_SECONDS"], defaultValue: 40),
      conversationTimeoutSeconds: readDouble(environment["E2E_CONVERSATION_TIMEOUT_SECONDS"], defaultValue: 90),
      incomingCallTimeoutSeconds: readDouble(environment["E2E_CALL_TIMEOUT_SECONDS"], defaultValue: 120),
      callDurationSeconds: readDouble(environment["E2E_CALL_DURATION_SECONDS"], defaultValue: 6),
      mediaTimeoutSeconds: readDouble(environment["E2E_MEDIA_TIMEOUT_SECONDS"], defaultValue: 90),
      mediaMinBytes: readInt64(environment["E2E_MEDIA_MIN_BYTES"], defaultValue: 1024),
      performRefresh: readBool(environment["E2E_PERFORM_REFRESH"], defaultValue: true),
      performCallFlow: readBool(environment["E2E_PERFORM_CALL_FLOW"], defaultValue: true),
      performPushRegistration: readBool(environment["E2E_PERFORM_PUSH"], defaultValue: true),
      receiverSendsReply: readBool(environment["E2E_RECEIVER_SEND_REPLY"], defaultValue: true),
      performDeviceLinkFlow: readBool(environment["E2E_PERFORM_DEVICE_LINK"], defaultValue: true),
      performAttachmentFlow: readBool(environment["E2E_PERFORM_ATTACHMENTS"], defaultValue: true),
      performVoiceMessageFlow: readBool(environment["E2E_PERFORM_VOICE_MESSAGES"], defaultValue: true),
      performBlockFlow: readBool(environment["E2E_PERFORM_BLOCK"], defaultValue: true),
      performDeleteConversationFlow: readBool(environment["E2E_PERFORM_DELETE_CHAT"], defaultValue: true),
      requireNewDeviceSyncCheck: readBool(environment["E2E_REQUIRE_NEW_DEVICE_SYNC"], defaultValue: true),
      performSettingsFlow: readBool(environment["E2E_PERFORM_SETTINGS"], defaultValue: true),
      performSettingsLogout: readBool(environment["E2E_PERFORM_SETTINGS_LOGOUT"], defaultValue: true),
      deviceLifecycleOnly: readBool(environment["E2E_DEVICE_LIFECYCLE_ONLY"], defaultValue: false),
      settingsOnly: readBool(environment["E2E_SETTINGS_ONLY"], defaultValue: false),
      validateCallPictureInPictureBackground: readBool(
        environment["E2E_VALIDATE_CALL_PIP_BACKGROUND"],
        defaultValue: false
      ),
      manuallyStartCallPictureInPictureBeforeBackground: readBool(
        environment["E2E_CALL_PIP_MANUAL_START_BEFORE_BACKGROUND"],
        defaultValue: false
      )
    )
  }

  private static func trim(_ value: String?, fallback: String) -> String {
    guard let value else {
      return fallback
    }

    let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func readBool(_ value: String?, defaultValue: Bool) -> Bool {
    guard let value else {
      return defaultValue
    }

    switch value.lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    case "0", "false", "no", "n", "off":
      return false
    default:
      return defaultValue
    }
  }

  private static func readDouble(_ value: String?, defaultValue: Double) -> Double {
    guard let value, let parsed: Double = Double(value), parsed >= 0 else {
      return defaultValue
    }

    return parsed
  }

  private static func readInt64(_ value: String?, defaultValue: Int64) -> Int64 {
    guard let value, let parsed: Int64 = Int64(value), parsed >= 0 else {
      return defaultValue
    }

    return parsed
  }

  private static func parseCallTypes(_ raw: String?) -> [Call.CallType] {
    let value: String = trim(raw, fallback: "both").lowercased()
    if value == "both" || value == "all" {
      return [.video, .voice]
    }

    if value.contains(",") {
      let parsed: [Call.CallType] = value
        .split(separator: ",")
        .compactMap { token in
          let normalized: String = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if normalized == "audio" {
            return .voice
          }
          return Call.CallType(rawValue: normalized)
        }

      if !parsed.isEmpty {
        return Array(Set(parsed)).sorted { lhs, rhs in
          if lhs == rhs {
            return false
          }
          return lhs == .video
        }
      }
    }

    if value == "audio" {
      return [.voice]
    }

    if let single: Call.CallType = Call.CallType(rawValue: value) {
      return [single]
    }

    return [.video]
  }
}
