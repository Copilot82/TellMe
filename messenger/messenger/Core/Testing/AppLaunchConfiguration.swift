import CryptoKit
import Foundation

enum AppTestStartRoute: String {
  case standard
  case activeCall = "call_active"
}

struct AppLaunchConfiguration {
  let environment: [String: String]
  let isUITestMode: Bool
  let isAutomationMode: Bool
  let shouldResetState: Bool
  let shouldBootstrapSampleData: Bool
  let shouldUseStubNetwork: Bool
  let shouldDisableRealtime: Bool
  let shouldRequestNotificationAuthorization: Bool
  let storageNamespace: String?
  let startRoute: AppTestStartRoute

  let sampleUserHandle: String
  let samplePeerHandle: String
  let sampleSeedPhrase: String
  let sampleConversationId: String
  let sampleCallId: String

  static var current: AppLaunchConfiguration {
    AppLaunchConfiguration(environment: ProcessInfo.processInfo.environment)
  }

  init(environment: [String: String]) {
    self.environment = environment

    let automationMode: Bool = AppLaunchConfiguration.readBool(environment["E2E_AUTORUN"])
    let bootstrapSampleData: Bool = AppLaunchConfiguration.readBool(environment["UITEST_BOOTSTRAP_SAMPLE_DATA"])
    let useStubNetwork: Bool = AppLaunchConfiguration.readBool(environment["UITEST_STUB_NETWORK"]) || bootstrapSampleData
    let disableRealtime: Bool = AppLaunchConfiguration.readBool(environment["UITEST_DISABLE_REALTIME"]) || useStubNetwork
    let uiTestMode: Bool = AppLaunchConfiguration.readBool(environment["UITEST_MODE"])
      || bootstrapSampleData
      || environment["UITEST_START_ROUTE"] != nil

    self.isAutomationMode = automationMode
    self.isUITestMode = uiTestMode

    let derivedNamespace: String? = {
      let explicit: String = AppLaunchConfiguration.trim(environment["UITEST_STORAGE_NAMESPACE"])
      if !explicit.isEmpty {
        return explicit
      }

      let runId: String = AppLaunchConfiguration.trim(environment["E2E_RUN_ID"])
      if !runId.isEmpty {
        return "e2e-\(runId)"
      }

      if uiTestMode {
        return "ui-tests"
      }

      if automationMode {
        return "automation"
      }

      return nil
    }()

    self.storageNamespace = AppLaunchConfiguration.sanitizeNamespace(derivedNamespace)
    self.shouldResetState = AppLaunchConfiguration.readBool(environment["UITEST_RESET_STATE"])
      || AppLaunchConfiguration.readBool(environment["E2E_RESET_STATE"])
    self.shouldBootstrapSampleData = bootstrapSampleData
    self.shouldUseStubNetwork = useStubNetwork
    self.shouldDisableRealtime = disableRealtime

    let route = AppTestStartRoute(
      rawValue: AppLaunchConfiguration.trim(environment["UITEST_START_ROUTE"]).lowercased()
    ) ?? .standard
    self.startRoute = route

    if uiTestMode {
      self.shouldRequestNotificationAuthorization = AppLaunchConfiguration.readBool(
        environment["UITEST_REQUEST_NOTIFICATIONS"]
      )
    } else if automationMode {
      self.shouldRequestNotificationAuthorization = AppLaunchConfiguration.readBool(environment["E2E_PERFORM_PUSH"])
    } else {
      self.shouldRequestNotificationAuthorization = true
    }

    let resolvedSampleUserHandle = AppLaunchConfiguration.trim(
      environment["UITEST_SAMPLE_USER_HANDLE"],
      fallback: "@ios-smoke-a:example.test"
    ).lowercased()
    let resolvedSamplePeerHandle = AppLaunchConfiguration.trim(
      environment["UITEST_SAMPLE_PEER_HANDLE"],
      fallback: "@ios-smoke-b:example.test"
    ).lowercased()
    self.sampleUserHandle = resolvedSampleUserHandle
    self.samplePeerHandle = resolvedSamplePeerHandle
    self.sampleSeedPhrase = AppLaunchConfiguration.trim(
      environment["UITEST_SAMPLE_SEED_PHRASE"],
      fallback: AppLaunchConfiguration.defaultSeedPhrase
    )
    self.sampleConversationId = AppLaunchConfiguration.trim(
      environment["UITEST_SAMPLE_CONVERSATION_ID"],
      fallback: AppLaunchConfiguration.directConversationId(
        localUserHandle: resolvedSampleUserHandle,
        peerUserHandle: resolvedSamplePeerHandle
      )
    )
    self.sampleCallId = AppLaunchConfiguration.trim(
      environment["UITEST_SAMPLE_CALL_ID"],
      fallback: "ui-test-call-001"
    )
  }

  var defaultsSuiteName: String? {
    guard let storageNamespace, !storageNamespace.isEmpty else {
      return nil
    }

    return "com.example.messenger.testing.\(storageNamespace)"
  }

  var tokenStoreService: String {
    if let storageNamespace, !storageNamespace.isEmpty {
      return "com.example.messenger.tokens.\(storageNamespace)"
    }

    return Bundle.main.bundleIdentifier ?? "com.example.messenger"
  }

  var keyMaterialStoreService: String {
    if let storageNamespace, !storageNamespace.isEmpty {
      return "com.example.messenger.keys.\(storageNamespace)"
    }

    return "com.example.messenger.keys"
  }

  func makeUserDefaults() -> UserDefaults {
    guard let defaultsSuiteName else {
      return .standard
    }

    return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
  }

  func makeNetworkClient() -> NetworkClient {
    if shouldUseStubNetwork {
      return UITestNetworkClient(configuration: self)
    }

    return URLSessionNetworkClient()
  }

  private static func trim(_ value: String?, fallback: String = "") -> String {
    let trimmed: String = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func readBool(_ value: String?) -> Bool {
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

  private static func sanitizeNamespace(_ value: String?) -> String? {
    guard let value = value?.lowercased(), !value.isEmpty else {
      return nil
    }

    let sanitized = value.map { character -> Character in
      if character.isLetter || character.isNumber {
        return character
      }
      return "-"
    }

    let result: String = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty ? nil : result
  }

  private static let defaultSeedPhrase: String = Data((0..<32).map { UInt8($0) }).base64EncodedString()

  private static func directConversationId(localUserHandle: String, peerUserHandle: String) -> String {
    let participants: [String] = [
      localUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      peerUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].sorted()
    let digest = SHA256.hash(data: Data("direct|\(participants.joined(separator: "|"))".utf8))
    let hex: String = digest.map { String(format: "%02x", $0) }.joined()
    return "dm-\(String(hex.prefix(32)))"
  }
}

enum AppTestStateManager {
  static func resetIfNeeded(
    configuration: AppLaunchConfiguration,
    defaults: UserDefaults,
    tokenStore: TokenStore,
    keyMaterialStore: KeyMaterialStore,
    sessionStore: AppSessionStore
  ) {
    guard configuration.shouldResetState else {
      return
    }

    if let suiteName: String = configuration.defaultsSuiteName {
      defaults.removePersistentDomain(forName: suiteName)
    } else if let bundleId: String = Bundle.main.bundleIdentifier {
      defaults.removePersistentDomain(forName: bundleId)
    }

    defaults.synchronize()
    sessionStore.clear()
    tokenStore.clear()
    keyMaterialStore.clearAll()
    URLCache.shared.removeAllCachedResponses()
    removeContentsIfPresent(at: FileManager.default.temporaryDirectory)

    let cacheURLs: [URL] = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    for cacheURL in cacheURLs {
      removeContentsIfPresent(at: cacheURL)
    }
  }

  static func bootstrapSampleDataIfNeeded(
    configuration: AppLaunchConfiguration,
    defaults: UserDefaults,
    tokenStore: TokenStore,
    keyMaterialStore: KeyMaterialStore,
    sessionStore: AppSessionStore
  ) {
    guard configuration.shouldBootstrapSampleData else {
      return
    }

    let userHandle: String = configuration.sampleUserHandle
    let peerHandle: String = configuration.samplePeerHandle
    let now: Date = Date()
    let sampleUser = User(
      id: userHandle,
      username: userHandle,
      email: userHandle,
      publicKey: "ui-test-public-key",
      createdAt: now,
      updatedAt: now
    )

    sessionStore.save(user: SessionUser(user: sampleUser))
    tokenStore.saveTokens(accessToken: "ui-test-access-token", refreshToken: "ui-test-refresh-token")
    keyMaterialStore.saveSeedPhrase(configuration.sampleSeedPhrase, for: userHandle)
    keyMaterialStore.saveDeviceId("ui-test-device-001", for: userHandle)
    keyMaterialStore.setCurrentUserId(userHandle)

    let conversation = Conversation(
      id: configuration.sampleConversationId,
      type: .direct,
      name: peerHandle,
      createdAt: now.addingTimeInterval(-180),
      updatedAt: now.addingTimeInterval(-15),
      participants: [
        ConversationParticipant(
          id: "participant-local",
          conversationId: configuration.sampleConversationId,
          userId: userHandle,
          joinedAt: now.addingTimeInterval(-180),
          role: .member
        ),
        ConversationParticipant(
          id: "participant-peer",
          conversationId: configuration.sampleConversationId,
          userId: peerHandle,
          joinedAt: now.addingTimeInterval(-180),
          role: .member
        ),
      ]
    )

    let messages: [Message] = [
      Message(
        id: "ui-msg-001",
        conversationId: configuration.sampleConversationId,
        senderId: peerHandle,
        content: "Secure hello from sample peer",
        type: .text,
        encryptionMode: .e2e,
        encryptionKeyNonce: nil,
        readAt: nil,
        deliveredAt: now.addingTimeInterval(-120),
        replyToMessageId: nil,
        forwardedFromMessageId: nil,
        deletedBy: nil,
        deletedAt: nil,
        createdAt: now.addingTimeInterval(-120),
        attachment: nil,
        reactions: [
          MessageReaction(
            id: "reaction-1",
            messageId: "ui-msg-001",
            userId: userHandle,
            emoji: "👍",
            createdAt: now.addingTimeInterval(-110)
          ),
        ]
      ),
      Message(
        id: "ui-msg-002",
        conversationId: configuration.sampleConversationId,
        senderId: userHandle,
        content: "Forwarded secure update",
        type: .text,
        encryptionMode: .e2e,
        encryptionKeyNonce: nil,
        readAt: now.addingTimeInterval(-50),
        deliveredAt: now.addingTimeInterval(-55),
        replyToMessageId: "ui-msg-001",
        forwardedFromMessageId: "ui-msg-001",
        deletedBy: nil,
        deletedAt: nil,
        createdAt: now.addingTimeInterval(-60),
        attachment: nil,
        reactions: nil
      ),
    ]

    let pinnedMessages: [PinnedMessage] = [
      PinnedMessage(
        id: "pin-1",
        conversationId: configuration.sampleConversationId,
        messageId: "ui-msg-001",
        pinnedBy: userHandle,
        pinnedAt: now.addingTimeInterval(-45),
        previewText: "Secure hello from sample peer",
        messageCreatedAt: now.addingTimeInterval(-120)
      ),
    ]

    persistConversations([conversation], owner: userHandle, defaults: defaults)
    persistMessages(messages, pinnedMessages: pinnedMessages, owner: userHandle, conversationId: configuration.sampleConversationId, defaults: defaults)
    defaults.set(false, forKey: "messaging.manual_read_receipts")

    Task {
      await UITestStubBackend.shared.seedIfNeeded(configuration: configuration)
    }
  }

  private static func removeContentsIfPresent(at directoryURL: URL) {
    let fileManager: FileManager = FileManager.default
    guard let children: [URL] = try? fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    for child in children {
      try? fileManager.removeItem(at: child)
    }
  }

  private static func persistConversations(_ conversations: [Conversation], owner: String, defaults: UserDefaults) {
    guard let data: Data = try? JSONCoding.encoder.encode(conversations) else {
      return
    }

    defaults.set(data, forKey: conversationStorageKey(owner: owner))
  }

  private static func persistMessages(
    _ messages: [Message],
    pinnedMessages: [PinnedMessage],
    owner: String,
    conversationId: String,
    defaults: UserDefaults
  ) {
    guard let messagesData: Data = try? JSONCoding.encoder.encode(messages.sorted(by: { $0.createdAt > $1.createdAt })),
      let pinnedData: Data = try? JSONCoding.encoder.encode(pinnedMessages)
    else {
      return
    }

    let suffix: String = conversationScopedSuffix(owner: owner, conversationId: conversationId)
    defaults.set(messagesData, forKey: "federated.local.messages.v2.\(suffix)")
    defaults.set(pinnedData, forKey: "federated.local.pins.v2.\(suffix)")
    defaults.set(Data("{}".utf8), forKey: "federated.local.message.edits.v2.\(suffix)")
    defaults.set(Data("{}".utf8), forKey: "federated.local.message.reply-previews.v2.\(suffix)")
    defaults.set(Data("[]".utf8), forKey: "federated.local.hidden-messages.v2.\(suffix)")
    defaults.set(Data("[]".utf8), forKey: "federated.local.sent-read-receipts.v2.\(suffix)")
  }

  private static func conversationStorageKey(owner: String) -> String {
    let digest = SHA256Hex.hash(owner.lowercased())
    return "federated.local.conversations.v2.\(String(digest.prefix(16)))"
  }

  private static func conversationScopedSuffix(owner: String, conversationId: String) -> String {
    let raw: String = "\(owner.lowercased())|\(conversationId.lowercased())"
    let digest = SHA256Hex.hash(raw)
    return String(digest.prefix(16))
  }
}

final class UITestNetworkClient: NetworkClient {
  private let configuration: AppLaunchConfiguration

  init(configuration: AppLaunchConfiguration) {
    self.configuration = configuration
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    await UITestStubBackend.shared.seedIfNeeded(configuration: configuration)

    let path: String = request.url?.path ?? "/"
    let method: String = request.httpMethod?.uppercased() ?? "GET"

    if path.hasSuffix("/sync/stream"), method == "GET" {
      let response = FederatedSyncResponse(deviceId: "ui-test-device-001", blobs: [])
      return try makeResponse(response, statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/auth/refresh"), method == "POST" {
      let response = FederatedSessionTokens(
        sessionToken: "ui-test-access-token-refreshed",
        refreshToken: "ui-test-refresh-token-refreshed",
        expiresIn: 3600
      )
      return try makeResponse(response, statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/auth/logout"), method == "POST" {
      return try makeResponse(FederatedLogoutResponse(success: true), statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/prekeys/get"), method == "GET" {
      let userHandle: String = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "user" })?
        .value?
        .lowercased() ?? configuration.samplePeerHandle

      let bundle = FederatedPrekeyBundle(
        protocolVersion: 2,
        userHandle: userHandle,
        deviceId: "ui-test-device-peer",
        accountSignPub: "ui-test-ik-sign-\(userHandle)",
        deviceSignPub: "ui-test-dk-sign-\(userHandle)",
        deviceDhPub: "ui-test-dk-dh-\(userHandle)",
        deviceCertificateChain: [
          DeviceCertificateV2(
            deviceCertificateVersion: 2,
            accountHandle: userHandle,
            deviceId: "ui-test-device-peer",
            deviceSignPub: "ui-test-dk-sign-\(userHandle)",
            deviceDhPub: "ui-test-dk-dh-\(userHandle)",
            issuerKind: "account",
            issuerDeviceId: nil,
            parentCertificateId: nil,
            issuedAt: Date(),
            expiresAt: nil,
            signature: "ui-test-device-signature"
          ),
        ],
        signedPrekey: FederatedPrekeySigned(
          prekeyId: "signed-prekey-001",
          signedPrekeyPub: "signed-prekey-pub-001",
          signature: "signed-prekey-signature",
          expiresAt: nil
        ),
        oneTimePrekey: FederatedPrekeyOneTime(prekeyId: "otp-001", prekeyPub: "otp-pub-001"),
        pushMode: .privacyFirst
      )

      return try makeResponse(FederatedPrekeysGetResponse(bundles: [bundle]), statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/prekeys/self"), method == "GET" {
      return try makeResponse(FederatedPrekeysGetResponse(bundles: []), statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/devices/push/tokens"), method == "GET" {
      let response = await UITestStubBackend.shared.listTokens()
      return try makeResponse(response, statusCode: 200, url: request.url)
    }

    if path.hasSuffix("/devices/push/tokens"), method == "POST" {
      let created: DeviceTokenResponse = try await UITestStubBackend.shared.registerToken(from: request.httpBody)
      return try makeResponse(created, statusCode: 200, url: request.url)
    }

    if let tokenPath: String = path.components(separatedBy: "/devices/push/tokens/").last,
      !tokenPath.isEmpty,
      method == "PUT"
    {
      let updated: DeviceTokenResponse = try await UITestStubBackend.shared.updateToken(
        idOrValue: tokenPath,
        body: request.httpBody
      )
      return try makeResponse(updated, statusCode: 200, url: request.url)
    }

    if let tokenPath: String = path.components(separatedBy: "/devices/push/tokens/").last,
      !tokenPath.isEmpty,
      method == "DELETE"
    {
      await UITestStubBackend.shared.deleteToken(idOrValue: tokenPath)
      return try makeResponse(EmptyResponse(), statusCode: 204, url: request.url)
    }

    throw APIError.transport("UITestNetworkClient does not handle \(method) \(path)")
  }

  private func makeResponse<T: Encodable>(
    _ payload: T,
    statusCode: Int,
    url: URL?
  ) throws -> (Data, HTTPURLResponse) {
    let data: Data
    if payload is EmptyResponse && statusCode == 204 {
      data = Data()
    } else {
      data = try JSONCoding.encoder.encode(AnyEncodable(payload))
    }

    let response = HTTPURLResponse(
      url: url ?? URL(string: "https://ui-tests.invalid")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
  }
}

actor UITestStubBackend {
  static let shared = UITestStubBackend()

  private var isSeeded: Bool = false
  private var tokens: [DeviceToken] = []

  func seedIfNeeded(configuration: AppLaunchConfiguration) {
    guard !isSeeded else {
      return
    }

    let now: Date = Date()
    tokens = [
      DeviceToken(
        id: "ui-token-001",
        userId: configuration.sampleUserHandle,
        deviceType: .ios,
        token: "ui-token-value-001",
        deviceName: "UI Test iPhone",
        osVersion: "18.6",
        appVersion: "1.0",
        pushEnabled: true,
        pushEnvironment: .sandbox,
        pushMode: .privacyFirst,
        tokenKind: .alert,
        lastUsedAt: now,
        createdAt: now
      ),
    ]

    isSeeded = true
  }

  func listTokens() -> DeviceTokensResponse {
    DeviceTokensResponse(tokens: tokens)
  }

  func registerToken(from body: Data?) throws -> DeviceTokenResponse {
    let payload: [String: Any] = try decodeJSONObject(body)
    let tokenValue: String = payload["token"] as? String ?? "ui-token-value-\(tokens.count + 1)"
    let pushEnabled: Bool = payload["pushEnabled"] as? Bool ?? true
    let deviceTypeRaw: String = payload["deviceType"] as? String ?? DeviceToken.DeviceType.ios.rawValue
    let deviceType = DeviceToken.DeviceType(rawValue: deviceTypeRaw) ?? .ios
    let pushEnvironmentRaw: String = payload["pushEnvironment"] as? String ?? PushEnvironment.sandbox.rawValue
    let pushEnvironment = PushEnvironment(rawValue: pushEnvironmentRaw) ?? .sandbox
    let pushModeRaw: String = payload["pushMode"] as? String ?? PushMode.privacyFirst.rawValue
    let pushMode = PushMode(rawValue: pushModeRaw) ?? .privacyFirst
    let tokenKindRaw: String = payload["tokenKind"] as? String ?? PushTokenKind.alert.rawValue
    let tokenKind = PushTokenKind(rawValue: tokenKindRaw) ?? .alert
    let now: Date = Date()

    let token = DeviceToken(
      id: "ui-token-\(String(format: "%03d", tokens.count + 1))",
      userId: payload["userId"] as? String ?? "local",
      deviceType: deviceType,
      token: tokenValue,
      deviceName: payload["deviceName"] as? String,
      osVersion: payload["osVersion"] as? String,
      appVersion: payload["appVersion"] as? String,
      pushEnabled: pushEnabled,
      pushEnvironment: pushEnvironment,
      pushMode: pushMode,
      tokenKind: tokenKind,
      lastUsedAt: now,
      createdAt: now
    )

    if let index: Int = tokens.firstIndex(where: { $0.token == tokenValue || $0.id == token.id }) {
      tokens[index] = token
    } else {
      tokens.insert(token, at: 0)
    }

    return DeviceTokenResponse(token: token)
  }

  func updateToken(idOrValue: String, body: Data?) throws -> DeviceTokenResponse {
    let payload: [String: Any] = try decodeJSONObject(body)
    let pushEnabled: Bool = payload["pushEnabled"] as? Bool ?? true
    let pushModeRaw: String = payload["pushMode"] as? String ?? tokens.first?.pushMode?.rawValue ?? PushMode.privacyFirst.rawValue
    let pushMode = PushMode(rawValue: pushModeRaw) ?? .privacyFirst
    let tokenKindRaw: String = payload["tokenKind"] as? String ?? tokens.first?.tokenKind?.rawValue ?? PushTokenKind.alert.rawValue
    let tokenKind = PushTokenKind(rawValue: tokenKindRaw) ?? .alert

    guard let index: Int = tokens.firstIndex(where: { $0.id == idOrValue || $0.token == idOrValue }) else {
      throw APIError.server(statusCode: 404, message: "Token not found")
    }

    let current = tokens[index]
    let updated = DeviceToken(
      id: current.id,
      userId: current.userId,
      deviceType: current.deviceType,
      token: current.token,
      deviceName: current.deviceName,
      osVersion: current.osVersion,
      appVersion: current.appVersion,
      pushEnabled: pushEnabled,
      pushEnvironment: current.pushEnvironment,
      pushMode: pushMode,
      tokenKind: tokenKind,
      lastUsedAt: Date(),
      createdAt: current.createdAt
    )
    tokens[index] = updated
    return DeviceTokenResponse(token: updated)
  }

  func deleteToken(idOrValue: String) {
    tokens.removeAll(where: { $0.id == idOrValue || $0.token == idOrValue })
  }

  private func decodeJSONObject(_ body: Data?) throws -> [String: Any] {
    guard let body, !body.isEmpty else {
      return [:]
    }

    let object: Any = try JSONSerialization.jsonObject(with: body, options: [])
    guard let payload: [String: Any] = object as? [String: Any] else {
      throw APIError.decoding("Invalid UITest JSON payload")
    }
    return payload
  }
}

private enum SHA256Hex {
  static func hash(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
