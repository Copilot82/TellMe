import Foundation

protocol CallServiceProtocol {
  func fetchTurnCredentials() async throws -> RTCConfig
  func registerDeviceToken(_ payload: DeviceTokenRegistrationPayload) async throws -> DeviceTokenResponse
  func updateDeviceTokenPushEnabled(token: String, pushEnabled: Bool) async throws -> DeviceTokenResponse
  func listDeviceTokens() async throws -> DeviceTokensResponse
  func deleteDeviceToken(token: String) async throws
}

// CallService fetches relay configuration separately from signaling so TURN failures stay recoverable.
final class CallService: CallServiceProtocol {
  private static let turnCredentialRetryDelaysNanoseconds: [UInt64] = [
    250_000_000,
    750_000_000,
    1_500_000_000,
    3_000_000_000,
  ]

  private struct UpdateDeviceTokenPayload: Encodable {
    let pushEnabled: Bool
  }

  private struct TurnCredentialsRequestPayload: Encodable {
    let purpose: String = "call_media"
    let transportProfile: String = "webrtc_turn_relay"
    let capabilities: [String: Bool] = [
      "audio": true,
      "video": true,
    ]
  }

  private let apiClient: APIClient
  private let sleep: @Sendable (UInt64) async throws -> Void

  init(
    apiClient: APIClient,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { delay in
      try await Task.sleep(nanoseconds: delay)
    }
  ) {
    self.apiClient = apiClient
    self.sleep = sleep
  }

  func fetchTurnCredentials() async throws -> RTCConfig {
    var lastError: Error?
    let maxAttemptIndex: Int = Self.turnCredentialRetryDelaysNanoseconds.count

    for attemptIndex in 0...maxAttemptIndex {
      do {
        return try await fetchTurnCredentialsOnce()
      } catch {
        lastError = error
        guard attemptIndex < maxAttemptIndex,
          Self.isTransientTurnCredentialError(error)
        else {
          throw error
        }

        try await sleep(Self.turnCredentialRetryDelaysNanoseconds[attemptIndex])
      }
    }

    throw lastError ?? APIError.transport("TURN relay credential request failed")
  }

  private func fetchTurnCredentialsOnce() async throws -> RTCConfig {
    let payload: TurnCredentialsRequestPayload = TurnCredentialsRequestPayload()
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "turn/credentials", method: .post, body: body)
    return try await apiClient.send(request)
  }

  private static func isTransientTurnCredentialError(_ error: Error) -> Bool {
    guard let apiError: APIError = error as? APIError else {
      return false
    }

    switch apiError {
    case .transport:
      return true
    case .server(let statusCode, _):
      return (500...599).contains(statusCode)
    case .invalidURL, .invalidResponse, .decoding, .encoding, .unauthorized:
      return false
    }
  }

  func registerDeviceToken(_ payload: DeviceTokenRegistrationPayload) async throws -> DeviceTokenResponse {
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "devices/push/tokens", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func updateDeviceTokenPushEnabled(token: String, pushEnabled: Bool) async throws -> DeviceTokenResponse {
    let payload: UpdateDeviceTokenPayload = UpdateDeviceTokenPayload(pushEnabled: pushEnabled)
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "devices/push/tokens/\(token)", method: .put, body: body)
    return try await apiClient.send(request)
  }

  func listDeviceTokens() async throws -> DeviceTokensResponse {
    let request: APIRequest = APIRequest(path: "devices/push/tokens", method: .get)
    return try await apiClient.send(request)
  }

  func deleteDeviceToken(token: String) async throws {
    let request: APIRequest = APIRequest(path: "devices/push/tokens/\(token)", method: .delete)
    try await apiClient.sendVoid(request)
  }
}
