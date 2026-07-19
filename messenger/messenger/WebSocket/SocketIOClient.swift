import Foundation

// The socket client treats realtime events as hints; REST sync remains the source of truth.
protocol WebSocketTasking: AnyObject, Sendable {
  func resume()
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: @unchecked Sendable {}
extension URLSessionWebSocketTask: WebSocketTasking {}

actor SocketIOClient {
  private enum PresenceHeartbeat {
    static let intervalNanoseconds: UInt64 = 4_000_000_000
    static let offlineFlushNanoseconds: UInt64 = 150_000_000
  }

  private enum ReconnectPolicy {
    static let baseDelayNanoseconds: UInt64 = 500_000_000
    static let maxDelayNanoseconds: UInt64 = 8_000_000_000
  }

  private let baseURL: URL
  private let webSocketFactory: (URL) -> WebSocketTasking
  private let authTokenProvider: (() -> String?)?
  private let authRefreshHandler: (() async throws -> String?)?
  private let sleep: @Sendable (UInt64) async -> Void
  private let reconnectJitterProvider: @Sendable (UInt64) -> UInt64

  private var socketTask: WebSocketTasking?
  private var receiveLoopTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var authToken: String?
  private var reconnectAttempt: Int = 0
  private var shouldReconnect: Bool = false
  private var connectionGeneration: UInt64 = 0
  private var lastAuthRefreshAttemptToken: String?

  private(set) var state: SocketConnectionState = .disconnected {
    didSet {
      onStateChange?(state)
    }
  }

  private var onStateChange: ((SocketConnectionState) -> Void)?
  private var onEvent: ((SocketEvent) -> Void)?

  init(
    baseURL: URL,
    session: URLSession = .shared,
    webSocketFactory: ((URL) -> WebSocketTasking)? = nil,
    authTokenProvider: (() -> String?)? = nil,
    authRefreshHandler: (() async throws -> String?)? = nil,
    sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
      try? await Task.sleep(nanoseconds: delay)
    },
    reconnectJitterProvider: @escaping @Sendable (UInt64) -> UInt64 = { upperBound in
      guard upperBound > 0 else {
        return 0
      }

      return UInt64.random(in: 0..<upperBound)
    }
  ) {
    self.baseURL = baseURL
    self.webSocketFactory = webSocketFactory ?? { url in
      session.webSocketTask(with: url)
    }
    self.authTokenProvider = authTokenProvider
    self.authRefreshHandler = authRefreshHandler
    self.sleep = sleep
    self.reconnectJitterProvider = reconnectJitterProvider
  }

  func setOnStateChange(_ handler: @escaping (SocketConnectionState) -> Void) {
    onStateChange = handler
  }

  func setOnEvent(_ handler: @escaping (SocketEvent) -> Void) {
    onEvent = handler
  }

  func connect(token: String) async {
    if (authToken == token && state == .connected) || (authToken == token && state == .connecting) {
      return
    }

    authToken = token
    lastAuthRefreshAttemptToken = nil
    shouldReconnect = true
    reconnectTask?.cancel()
    reconnectTask = nil
    await establishConnection()
  }

  func disconnect() async {
    shouldReconnect = false
    connectionGeneration &+= 1
    reconnectAttempt = 0
    reconnectTask?.cancel()
    reconnectTask = nil

    if socketTask != nil {
      try? await emit(name: SocketEventName.presenceOffline)
      try? await Task.sleep(nanoseconds: PresenceHeartbeat.offlineFlushNanoseconds)
    }

    receiveLoopTask?.cancel()
    receiveLoopTask = nil
    stopPresenceHeartbeat()

    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil

    authToken = nil
    lastAuthRefreshAttemptToken = nil
    state = .disconnected
  }

  func emit(name: String, payload: [String: Any]? = nil) async throws {
    guard let socketTask else {
      throw APIError.transport("Socket is not connected")
    }

    let encoded: String = try SocketIOPacketCodec.encodeEvent(name: name, payload: payload)
    try await socketTask.send(.string(encoded))
  }

  func touchPresence() async throws {
    try await emit(name: SocketEventName.presenceTouch)
  }

  func joinConversation(_ conversationId: String, peerUserHandle: String?) async throws {
    var payload: [String: Any] = ["conversationId": conversationId]
    if let peerUserHandle {
      payload["peerUserHandle"] = peerUserHandle
    }

    try await emit(name: SocketEventName.joinConversation, payload: payload)
  }

  func subscribeSync() async throws {
    try await emit(name: SocketEventName.syncSubscribe)
  }

  func pullSync(limit: Int = 200) async throws {
    try await emit(
      name: SocketEventName.syncPull,
      payload: ["limit": max(1, min(1000, limit))]
    )
  }

  func leaveConversation(_ conversationId: String) async throws {
    try await emit(name: SocketEventName.leaveConversation, payload: ["conversationId": conversationId])
  }

  func typingStart(conversationId: String) async throws {
    try await emit(name: SocketEventName.typingStart, payload: ["conversationId": conversationId])
  }

  func typingStop(conversationId: String) async throws {
    try await emit(name: SocketEventName.typingStop, payload: ["conversationId": conversationId])
  }

  func sendCallOffer(
    callId: String,
    targetUserId: String,
    offer: [String: Any],
    signalingEncrypted: Bool = false,
    encryptedPayload: Bool = false
  ) async throws {
    _ = callId
    _ = targetUserId
    _ = offer
    _ = signalingEncrypted
    _ = encryptedPayload
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func sendCallAnswer(
    callId: String,
    answer: [String: Any],
    signalingEncrypted: Bool = false,
    encryptedPayload: Bool = false
  ) async throws {
    _ = callId
    _ = answer
    _ = signalingEncrypted
    _ = encryptedPayload
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func sendICECandidate(
    callId: String,
    targetUserId: String,
    candidate: [String: Any],
    signalingEncrypted: Bool = false,
    encryptedPayload: Bool = false
  ) async throws {
    _ = callId
    _ = targetUserId
    _ = candidate
    _ = signalingEncrypted
    _ = encryptedPayload
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func flushBufferedCandidates(callId: String) async throws {
    _ = callId
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func updateCallQuality(callId: String, quality: Double, connectionType: String?) async throws {
    _ = callId
    _ = quality
    _ = connectionType
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func toggleCallMute(callId: String, muted: Bool) async throws {
    _ = callId
    _ = muted
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func toggleCallCamera(callId: String, enabled: Bool) async throws {
    _ = callId
    _ = enabled
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func notifyCallReconnecting(callId: String) async throws {
    _ = callId
    throw APIError.server(statusCode: 410, message: "Call signaling moved to E2E message types")
  }

  func confirmMessageReceived(messageId: String) async throws {
    try await emit(name: SocketEventName.messageReceived, payload: ["messageId": messageId])
  }

  private func buildSocketURL() throws -> URL {
    guard var components: URLComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }

    if !components.path.hasSuffix("/") {
      components.path += "/"
    }

    components.queryItems = [
      URLQueryItem(name: "EIO", value: "4"),
      URLQueryItem(name: "transport", value: "websocket"),
    ]

    guard let url: URL = components.url else {
      throw APIError.invalidURL
    }

    return url
  }

  private func establishConnection() async {
    updateAuthTokenFromProvider()

    guard authToken != nil else {
      state = .disconnected
      return
    }

    receiveLoopTask?.cancel()
    receiveLoopTask = nil
    stopPresenceHeartbeat()
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    state = .connecting
    connectionGeneration &+= 1
    let generation: UInt64 = connectionGeneration

    do {
      let url: URL = try buildSocketURL()
      let task = webSocketFactory(url)
      socketTask = task
      task.resume()
      receiveLoopTask = Task { [weak self] in
        await self?.runReceiveLoop(task, generation: generation)
      }
    } catch {
      await handleSocketFailure(error.localizedDescription, generation: generation)
    }
  }

  private func runReceiveLoop(_ task: WebSocketTasking, generation: UInt64) async {
    while !Task.isCancelled {
      do {
        let message: URLSessionWebSocketTask.Message = try await task.receive()
        let text: String

        switch message {
        case .string(let value):
          text = value
        case .data(let data):
          guard let value: String = String(data: data, encoding: .utf8) else {
            continue
          }
          text = value
        @unknown default:
          continue
        }

        try await handleIncomingText(text, task: task, generation: generation)
      } catch {
        if Task.isCancelled {
          return
        }

        await handleSocketFailure(error.localizedDescription, generation: generation)
        return
      }
    }
  }

  private func handleIncomingText(
    _ text: String,
    task: WebSocketTasking,
    generation: UInt64
  ) async throws {
    guard isCurrentConnection(task: task, generation: generation) else {
      return
    }

    let packet: SocketIOPacket = SocketIOPacketCodec.decode(text)

    switch packet {
    case .engineOpen:
      if let authToken {
        let connectMessage: String = try SocketIOPacketCodec.encodeConnect(auth: ["token": authToken])
        try await task.send(.string(connectMessage))
      }
    case .socketConnected:
      reconnectAttempt = 0
      lastAuthRefreshAttemptToken = nil
      state = .connected
      startPresenceHeartbeat(generation: generation)
      try? await touchPresence()
    case .ping:
      try await task.send(.string("3"))
    case .event(let name, let payload):
      onEvent?(SocketEvent(name: name, payload: payload))
    case .error(let message):
      throw APIError.transport(message)
    case .pong, .unknown:
      break
    }
  }

  private func startPresenceHeartbeat(generation: UInt64) {
    stopPresenceHeartbeat()

    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: PresenceHeartbeat.intervalNanoseconds)
        guard let self else {
          return
        }

        do {
          try await self.touchPresence(generation: generation)
        } catch {
          await self.handleSocketFailure(error.localizedDescription, generation: generation)
          return
        }
      }
    }
  }

  private func stopPresenceHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  private func touchPresence(generation: UInt64) async throws {
    guard generation == connectionGeneration else {
      return
    }

    try await touchPresence()
  }

  private func handleSocketFailure(_ message: String, generation: UInt64) async {
    guard generation == connectionGeneration else {
      return
    }

    stopPresenceHeartbeat()
    receiveLoopTask?.cancel()
    receiveLoopTask = nil
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    await refreshAuthTokenAfterFailureIfNeeded(message)
    state = .failed(message)
    scheduleReconnectIfNeeded()
  }

  private func updateAuthTokenFromProvider() {
    guard let providedToken: String = authTokenProvider?() else {
      return
    }

    let providerToken: String = providedToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !providerToken.isEmpty
    else {
      return
    }

    authToken = providerToken
  }

  private func refreshAuthTokenAfterFailureIfNeeded(_ message: String) async {
    guard isAuthenticationFailure(message),
      let authRefreshHandler
    else {
      return
    }

    let attemptedToken: String = authToken ?? ""
    guard lastAuthRefreshAttemptToken != attemptedToken else {
      return
    }

    lastAuthRefreshAttemptToken = attemptedToken
    do {
      guard let rawRefreshedToken: String = try await authRefreshHandler() else {
        return
      }

      let refreshedToken: String = rawRefreshedToken.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !refreshedToken.isEmpty else {
        return
      }

      authToken = refreshedToken
    } catch {
      return
    }
  }

  private func isAuthenticationFailure(_ message: String) -> Bool {
    let normalized: String = message
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized.contains("authentication")
      || normalized.contains("unauthorized")
      || normalized.contains("invalid token")
      || normalized.contains("expired token")
  }

  private func isCurrentConnection(task: WebSocketTasking, generation: UInt64) -> Bool {
    guard generation == connectionGeneration, let socketTask else {
      return false
    }

    return ObjectIdentifier(socketTask) == ObjectIdentifier(task)
  }

  private func scheduleReconnectIfNeeded() {
    guard shouldReconnect, authToken != nil, reconnectTask == nil else {
      return
    }

    let exponent: UInt64 = UInt64(min(reconnectAttempt, 4))
    let maxMultiplier: UInt64 = 1 << exponent
    let backoffDelay: UInt64 = min(
      ReconnectPolicy.maxDelayNanoseconds,
      ReconnectPolicy.baseDelayNanoseconds * maxMultiplier
    )
    let jitter: UInt64 = reconnectJitterProvider(max(1, backoffDelay / 4))
    reconnectAttempt += 1

    reconnectTask = Task { [weak self] in
      guard let self else {
        return
      }

      await self.sleep(backoffDelay + jitter)
      await self.runScheduledReconnect()
    }
  }

  private func runScheduledReconnect() async {
    reconnectTask = nil
    guard shouldReconnect, authToken != nil else {
      return
    }

    await establishConnection()
  }
}
