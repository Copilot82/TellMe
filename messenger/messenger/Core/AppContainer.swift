import Foundation

private enum LocalStorageCleanup {
  static let conversationPrefixes: [String] = [
    "federated.local.conversations",
    "federated.local.conversations.v2",
    "federated.local.messages.v2",
    "federated.local.message.edits.v2",
    "federated.local.message.reply-previews.v2",
    "federated.local.pins.v2",
    "federated.local.hidden-pins.v2",
    "federated.local.hidden-messages.v2",
    "federated.local.sent-read-receipts.v2",
    "federated.local.pending-read-receipts.v2",
    "federated.local.deferred-controls.v2",
  ]

  static func clearConversationState(defaults: UserDefaults) {
    for key in defaults.dictionaryRepresentation().keys {
      if conversationPrefixes.contains(where: {
        key.hasPrefix($0) || key.hasPrefix("secure_state.\($0)")
      }) {
        defaults.removeObject(forKey: key)
      }
    }
  }
}

// Protocol cutover clears local caches that were shaped by older plaintext-compatible flows.
private enum ProtocolV2CutoverManager {
  static let currentVersion: Int = 2
  static let appliedVersionKey: String = "app.protocol_v2_cutover_version"

  static func applyIfNeeded(
    defaults: UserDefaults,
    tokenStore: TokenStore,
    sessionStore: AppSessionStore
  ) {
    let appliedVersion: Int = defaults.integer(forKey: appliedVersionKey)
    guard appliedVersion < currentVersion else {
      return
    }

    sessionStore.clear()
    tokenStore.clear()
    defaults.removeObject(forKey: "push.latest_apns_token")
    defaults.removeObject(forKey: "push.last_registered_signature")
    defaults.removeObject(forKey: "ratchet_sessions")
    defaults.removeObject(forKey: "secure_state.ratchet_sessions")
    LocalStorageCleanup.clearConversationState(defaults: defaults)
    defaults.set(currentVersion, forKey: appliedVersionKey)
  }
}

// AppContainer is the composition root; security services are wired once and passed by dependency.
@MainActor
final class AppContainer {
  let defaults: UserDefaults
  let launchConfiguration: AppLaunchConfiguration
  let environment: AppEnvironment
  let tokenStore: TokenStore
  let keyMaterialStore: KeyMaterialStore
  let sessionStore: AppSessionStore
  let apiClient: APIClient

  let authService: AuthService
  let messageService: MessageService
  let callService: CallService
  let e2eSecurityService: E2ESecurityService
  let pushNotificationService: PushNotificationService
  let systemCallCoordinator: SystemCallCoordinator
  let deviceLinkService: DeviceLinkService
  let localAuthenticationService: LocalAuthenticationService
  let cryptoService: CryptoService
  let seedService: SeedService
  let identityService: IdentityService
  let deviceKeysService: DeviceKeysService
  let prekeyPrivateStore: PrekeyPrivateStoreProtocol
  let prekeysService: PrekeysService
  let secureStateStore: SecureStateStore
  let ratchetSessionStore: RatchetSessionStore
  let x3dhService: X3DHService
  let doubleRatchetService: DoubleRatchetService
  let envelopeService: EnvelopeService
  let attachmentInspectionService: AttachmentInspectionService
  let attachmentPreviewService: AttachmentPreviewService
  let socketClient: SocketIOClient
  let realtimeRouter: RealtimeEventRouter
  let realtimeMailboxSyncController: RealtimeMailboxSyncController
  let e2eCallSessionStore: E2ECallSessionStore

  init(
    environment: AppEnvironment = .current,
    defaults: UserDefaults? = nil,
    tokenStore: TokenStore? = nil,
    keyMaterialStore: KeyMaterialStore? = nil,
    sessionStore: AppSessionStore? = nil,
    prekeyPrivateStore: PrekeyPrivateStoreProtocol? = nil,
    networkClient: NetworkClient? = nil,
    launchConfiguration: AppLaunchConfiguration = .current
  ) {
    let resolvedDefaults: UserDefaults = defaults ?? launchConfiguration.makeUserDefaults()
    let resolvedTokenStore: TokenStore = tokenStore
      ?? KeychainTokenStore(service: launchConfiguration.tokenStoreService)
    let resolvedKeyMaterialStore: KeyMaterialStore = keyMaterialStore
      ?? KeychainKeyMaterialStore(service: launchConfiguration.keyMaterialStoreService)
    let resolvedNetworkClient: NetworkClient = networkClient ?? launchConfiguration.makeNetworkClient()
    let cryptoService = CryptoService()
    let seedService = SeedService(cryptoService: cryptoService)
    let identityService = IdentityService(seedService: seedService, cryptoService: cryptoService)
    let secureStateStore = SecureStateStore(defaults: resolvedDefaults, cryptoService: cryptoService)
    let resolvedSessionStore: AppSessionStore = sessionStore ?? UserDefaultsSessionStore(
      defaults: resolvedDefaults,
      secureStateStore: secureStateStore,
      keyMaterialStore: resolvedKeyMaterialStore,
      identityService: identityService
    )

    self.defaults = resolvedDefaults
    self.launchConfiguration = launchConfiguration
    self.environment = environment
    self.tokenStore = resolvedTokenStore
    self.keyMaterialStore = resolvedKeyMaterialStore
    self.sessionStore = resolvedSessionStore

    let apiClient: APIClient = APIClient(
      environment: environment,
      networkClient: resolvedNetworkClient,
      tokenStore: resolvedTokenStore
    )

    self.apiClient = apiClient

    let authService: AuthService = AuthService(apiClient: apiClient, tokenStore: resolvedTokenStore)
    self.authService = authService
    self.messageService = MessageService(apiClient: apiClient)
    self.callService = CallService(apiClient: apiClient)
    self.e2eSecurityService = E2ESecurityService(
      apiClient: apiClient,
      sessionStore: resolvedSessionStore,
      defaults: resolvedDefaults,
      keyMaterialStore: resolvedKeyMaterialStore,
      identityService: identityService,
      secureStateStore: secureStateStore
    )
    self.pushNotificationService = PushNotificationService(
      callService: callService,
      messageService: self.messageService,
      sessionStore: resolvedSessionStore,
      keyMaterialStore: resolvedKeyMaterialStore,
      defaults: resolvedDefaults,
      identityService: identityService,
      secureStateStore: secureStateStore
    )
    self.systemCallCoordinator = SystemCallCoordinator.shared
    self.deviceLinkService = DeviceLinkService(apiClient: apiClient)
    self.localAuthenticationService = LocalAuthenticationService()
    self.cryptoService = cryptoService
    self.seedService = seedService
    self.identityService = identityService
    self.deviceKeysService = DeviceKeysService(seedService: seedService, cryptoService: cryptoService)
    let resolvedPrekeyPrivateStore = prekeyPrivateStore
      ?? KeychainPrekeyPrivateStore(service: "\(launchConfiguration.keyMaterialStoreService).prekeys")
    self.prekeyPrivateStore = resolvedPrekeyPrivateStore
    self.prekeysService = PrekeysService(
      seedService: seedService,
      cryptoService: cryptoService,
      prekeyPrivateStore: resolvedPrekeyPrivateStore
    )
    self.secureStateStore = secureStateStore
    self.ratchetSessionStore = RatchetSessionStore(stateStore: secureStateStore)
    self.x3dhService = X3DHService(seedService: seedService, cryptoService: cryptoService)
    self.doubleRatchetService = DoubleRatchetService()
    self.envelopeService = EnvelopeService(cryptoService: cryptoService, ratchetService: doubleRatchetService)
    self.attachmentInspectionService = AttachmentInspectionService()
    self.attachmentPreviewService = AttachmentPreviewService(
      messageService: MessageService(apiClient: apiClient)
    )
    let socketClient = SocketIOClient(
      baseURL: environment.webSocketBaseURL,
      authTokenProvider: {
        resolvedTokenStore.accessToken
      },
      authRefreshHandler: { [weak authService] in
        guard let authService else {
          return nil
        }

        _ = try await authService.refreshTokens()
        return resolvedTokenStore.accessToken
      }
    )
    self.socketClient = socketClient
    self.realtimeRouter = RealtimeEventRouter(
      socketClient: socketClient,
      allowsLegacyRawCallEvents: LegacyRawCallSocketPolicy.allowsRawCallEvents(configuration: launchConfiguration)
    )
    self.e2eCallSessionStore = E2ECallSessionStore()
    self.realtimeMailboxSyncController = RealtimeMailboxSyncController(
      socketClient: socketClient,
      realtimeRouter: realtimeRouter,
      pushNotificationService: pushNotificationService
    )
    self.pushNotificationService.attach(container: self)
    self.systemCallCoordinator.attach(container: self)

    apiClient.setRefreshHandler { [weak authService] in
      guard let authService else {
        throw APIError.unauthorized
      }

      _ = try await authService.refreshTokens()
      if let accessToken: String = resolvedTokenStore.accessToken,
        !accessToken.isEmpty
      {
        await socketClient.connect(token: accessToken)
      }
    }
  }

  func clearLocalSessionState(preserveDeviceIdentity: Bool) {
    let currentUserId: String? = sessionStore.currentUser?.id
      ?? keyMaterialStore.currentUserId

    if let currentUserId, !currentUserId.isEmpty {
      keyMaterialStore.removeSeedPhrase(for: currentUserId)
      keyMaterialStore.removePrivateKey(for: currentUserId)
      if preserveDeviceIdentity {
        if let deviceIdentity: PersistedDeviceIdentity = keyMaterialStore.deviceIdentity(for: currentUserId) {
          keyMaterialStore.saveDeviceIdentity(deviceIdentity, for: currentUserId)
        }
      } else {
        keyMaterialStore.removeDeviceIdentity(for: currentUserId)
      }
    }

    keyMaterialStore.setCurrentUserId(nil)
    sessionStore.clear()
    tokenStore.clear()
    try? ratchetSessionStore.clear()
    e2eCallSessionStore.removeAll()
    pushNotificationService.resetRegistrationState()
    clearLocalConversationState()
  }

  private func clearLocalConversationState() {
    LocalStorageCleanup.clearConversationState(defaults: defaults)
  }
}

@MainActor
enum AppRuntime {
  private static var sharedContainerStorage: AppContainer?

  static func sharedContainer(
    launchConfiguration: AppLaunchConfiguration = .current
  ) -> AppContainer {
    if let sharedContainerStorage {
      return sharedContainerStorage
    }

    let defaults: UserDefaults = launchConfiguration.makeUserDefaults()
    let tokenStore: TokenStore = KeychainTokenStore(service: launchConfiguration.tokenStoreService)
    let keyMaterialStore: KeyMaterialStore = KeychainKeyMaterialStore(
      service: launchConfiguration.keyMaterialStoreService
    )
    let cryptoService = CryptoService()
    let seedService = SeedService(cryptoService: cryptoService)
    let identityService = IdentityService(seedService: seedService, cryptoService: cryptoService)
    let secureStateStore = SecureStateStore(defaults: defaults, cryptoService: cryptoService)
    let sessionStore: AppSessionStore = UserDefaultsSessionStore(
      defaults: defaults,
      secureStateStore: secureStateStore,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )

    ProtocolV2CutoverManager.applyIfNeeded(
      defaults: defaults,
      tokenStore: tokenStore,
      sessionStore: sessionStore
    )

    AppTestStateManager.resetIfNeeded(
      configuration: launchConfiguration,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore
    )

    AppTestStateManager.bootstrapSampleDataIfNeeded(
      configuration: launchConfiguration,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore
    )

    let container = AppContainer(
      environment: .current,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      networkClient: launchConfiguration.makeNetworkClient(),
      launchConfiguration: launchConfiguration
    )
    sharedContainerStorage = container
    return container
  }
}
