import Foundation

@MainActor
// Settings writes go through services so UI toggles cannot bypass device or push-token validation.
final class SettingsViewModel {
  private enum StorageKeys {
    static let manualReadReceiptsKey: String = "messaging.manual_read_receipts"
  }

  private enum DiagnosticsProbe {
    static let minimumRefreshInterval: TimeInterval = 30
  }

  private enum TurnCredentialProbeState: Equatable {
    case pending
    case checking
    case ok(String)
    case failed(String)

    var summary: String {
      switch self {
      case .pending:
        return "pending"
      case .checking:
        return "checking"
      case .ok(let detail):
        return "ok(\(detail))"
      case .failed(let detail):
        return "failed(\(detail))"
      }
    }
  }

  private let container: AppContainer
  private let defaults: UserDefaults

  private var stateObserverId: UUID?
  private var eventObserverId: UUID?
  private var isTurnCredentialProbeRunning: Bool = false
  private var lastTurnCredentialProbeAt: Date?

  private(set) var connectionState: SocketConnectionState = .disconnected
  private(set) var latestRTCConfig: RTCConfigEvent?
  private var turnCredentialProbeState: TurnCredentialProbeState = .pending

  init(container: AppContainer, defaults: UserDefaults = .standard) {
    self.container = container
    self.defaults = defaults

    stateObserverId = container.realtimeRouter.observeConnectionState { [weak self] state in
      self?.connectionState = state
    }

    eventObserverId = container.realtimeRouter.observeEvents { [weak self] event in
      guard let self else {
        return
      }

      if case .rtcConfig(let config) = event {
        self.latestRTCConfig = config
      }
    }
  }

  var currentUser: SessionUser? {
    container.sessionStore.currentUser
  }

  var hasPrivateKey: Bool {
    let lookupIds: [String] = keyMaterialLookupIds()
    return container.keyMaterialStore.hasAnyAccountKeyMaterial(lookupIds: lookupIds)
  }

  var manualReadReceiptsEnabled: Bool {
    defaults.bool(forKey: StorageKeys.manualReadReceiptsKey)
  }

  func setManualReadReceipts(enabled: Bool) {
    defaults.set(enabled, forKey: StorageKeys.manualReadReceiptsKey)
  }

  func refreshSession() async throws {
    _ = try await container.authService.refreshTokens()
    await container.pushNotificationService.syncDeviceTokenIfNeeded()
  }

  func logout() async {
    await container.pushNotificationService.unregisterCurrentDeviceTokenIfNeeded()
    try? await container.authService.logout()
    await container.realtimeRouter.disconnect()
    container.clearLocalSessionState(preserveDeviceIdentity: true)
  }

  func exportPrivateKey() throws -> String {
    let lookupIds: [String] = keyMaterialLookupIds()
    guard !lookupIds.isEmpty else {
      throw APIError.server(statusCode: 400, message: "Account key material not found")
    }

    if let resolvedSeed = container.keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds) {
      return resolvedSeed.seedPhrase
    }

    if let resolvedPrivateKey = container.keyMaterialStore.firstAvailablePrivateKeyPEM(lookupIds: lookupIds) {
      return resolvedPrivateKey.privateKey
    }

    throw APIError.server(statusCode: 400, message: "Account key material not found")
  }

  func importPrivateKey(_ pem: String) throws {
    let lookupIds: [String] = keyMaterialLookupIds()
    guard let userId: String = preferredStorageUserId(from: lookupIds) else {
      throw APIError.server(statusCode: 400, message: "No active user")
    }

    let normalized: String = pem.trimmingCharacters(in: .whitespacesAndNewlines)
    if container.seedService.decodeSeedPhrase(normalized) != nil {
      container.keyMaterialStore.saveSeedPhrase(normalized, for: userId)
      container.keyMaterialStore.setCurrentUserId(userId)
      return
    }

    _ = try container.cryptoService.importPrivateKeyPEM(normalized)
    container.keyMaterialStore.savePrivateKeyPEM(normalized, for: userId)
    container.keyMaterialStore.setCurrentUserId(userId)
  }

  func fetchPublicKey(userHandle: String) async throws -> PublicKeyResponse {
    try await container.authService.fetchPublicKey(userHandle: userHandle)
  }

  func authenticateLocal(reason: String) async throws {
    try await container.localAuthenticationService.authenticate(reason: reason)
  }

  func registerAPNSToken(_ tokenData: Data) async throws {
    _ = try await container.pushNotificationService.registerDeviceToken(tokenData)
  }

  func listDeviceTokens() async throws -> [DeviceToken] {
    let response: DeviceTokensResponse = try await container.callService.listDeviceTokens()
    return response.tokens
  }

  func refreshNetworkDiagnostics(force: Bool = false) async {
    container.systemCallCoordinator.refreshPushKitRegistrationIfVoIPTokenMissing()
    await container.pushNotificationService.syncDeviceTokenIfNeeded()

    guard !isTurnCredentialProbeRunning else {
      return
    }

    let now = Date()
    if !force,
      let lastTurnCredentialProbeAt,
      now.timeIntervalSince(lastTurnCredentialProbeAt) < DiagnosticsProbe.minimumRefreshInterval
    {
      return
    }

    isTurnCredentialProbeRunning = true
    lastTurnCredentialProbeAt = now
    turnCredentialProbeState = .checking
    defer {
      isTurnCredentialProbeRunning = false
    }

    do {
      let config: RTCConfig = try await container.callService.fetchTurnCredentials()
      turnCredentialProbeState = .ok(turnCredentialProbeDetail(config))
    } catch {
      turnCredentialProbeState = .failed(diagnosticDescription(for: error))
    }
  }

  func updateDeviceToken(token: String, pushEnabled: Bool) async throws {
    _ = try await container.callService.updateDeviceTokenPushEnabled(token: token, pushEnabled: pushEnabled)
  }

  func deleteDeviceToken(token: String) async throws {
    try await container.callService.deleteDeviceToken(token: token)
  }

  func diagnosticsSummary() -> String {
    let user: String = currentUser?.id ?? "none"
    let keyState: String = hasPrivateKey ? "present" : "missing"
    let pushState: String = container.pushNotificationService.diagnosticsSummary()
    let callState: String
    if let activeSession = container.e2eCallSessionStore.activeSession {
      callState = "active,pip=\(activeSession.pictureInPictureDiagnosticsSummary)"
    } else {
      callState = "none"
    }
    let turnState: String = turnCredentialProbeState.summary
    let rtcState: String = latestRTCConfig == nil ? "socket_event_pending" : "socket_event_received"
    return "user=\(user), key=\(keyState), socket=\(connectionState), push=\(pushState), call=\(callState), turn=\(turnState), rtc=\(rtcState), api=\(apiEndpointSummary()), ws=\(webSocketEndpointSummary())"
  }

  private func keyMaterialLookupIds() -> [String] {
    container.keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: currentUser?.id,
      sessionUser: currentUser
    )
  }

  private func preferredStorageUserId(from lookupIds: [String]) -> String? {
    for candidate in lookupIds {
      if candidate.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil {
        return candidate.lowercased()
      }
    }

    return lookupIds.first
  }

  private func turnCredentialProbeDetail(_ config: RTCConfig) -> String {
    let firstURL: String = sanitizedEndpoint(config.iceServers.first?.urls ?? "none")
    let policy: String = (config.iceTransportPolicy ?? "unknown")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let ttl: Int = config.turnCredentials.ttl
    return "policy=\(policy.isEmpty ? "unknown" : policy),servers=\(config.iceServers.count),ttl=\(ttl),first=\(firstURL)"
  }

  private func apiEndpointSummary() -> String {
    sanitizedEndpoint(container.environment.apiBaseURL.absoluteString)
  }

  private func webSocketEndpointSummary() -> String {
    sanitizedEndpoint(container.environment.webSocketBaseURL.absoluteString)
  }

  private func sanitizedEndpoint(_ rawValue: String) -> String {
    guard var components = URLComponents(string: rawValue) else {
      return sanitizeDiagnosticValue(rawValue)
    }

    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return sanitizeDiagnosticValue(components.string ?? rawValue)
  }

  private func diagnosticDescription(for error: Error) -> String {
    let rawValue: String
    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      rawValue = description
    } else {
      rawValue = String(describing: error)
    }

    return sanitizeDiagnosticValue(rawValue)
  }

  private func sanitizeDiagnosticValue(_ rawValue: String) -> String {
    let sanitized = rawValue
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "|", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(sanitized.prefix(180))
  }
}
