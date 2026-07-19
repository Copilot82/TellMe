import CryptoKit
import Foundation

protocol AuthServiceProtocol {
  func registerFederated(_ request: FederatedRegisterRequest) async throws -> FederatedRegisterResponse
  func startChallenge(userHandle: String, deviceId: String?) async throws -> FederatedAuthStartResponse
  func finishChallenge(_ request: FederatedAuthFinishRequest) async throws -> FederatedSessionTokens
  func publishPrekeys(
    deviceId: String,
    signedPrekey: SignedPrekeyBundle,
    oneTimePrekeys: [OneTimePrekeyBundle]
  ) async throws -> FederatedPrekeysPublishResponse
  func fetchPrekeys(userHandle: String, deviceId: String?, peek: Bool) async throws -> FederatedPrekeysGetResponse
  func fetchSelfPrekeys(deviceId: String?, peek: Bool) async throws -> FederatedPrekeysGetResponse

  func refreshTokens() async throws -> FederatedSessionTokens
  func logout() async throws
  func fetchPublicKey(userHandle: String) async throws -> PublicKeyResponse
}

// Refresh coordination prevents parallel 401 retries from overwriting each other's token results.
actor AuthTokenRefreshCoordinator {
  private var inFlightRefresh: Task<FederatedSessionTokens, Error>?

  func refresh(
    operation: @escaping () async throws -> FederatedSessionTokens
  ) async throws -> FederatedSessionTokens {
    if let inFlightRefresh {
      return try await inFlightRefresh.value
    }

    let refreshTask = Task {
      try await operation()
    }
    inFlightRefresh = refreshTask

    do {
      let response = try await refreshTask.value
      inFlightRefresh = nil
      return response
    } catch {
      inFlightRefresh = nil
      throw error
    }
  }
}

// AuthService persists tokens only after server-side challenge proof succeeds.
final class AuthService: AuthServiceProtocol {
  private let apiClient: APIClient
  private let tokenStore: TokenStore
  private let refreshCoordinator: AuthTokenRefreshCoordinator

  init(
    apiClient: APIClient,
    tokenStore: TokenStore,
    refreshCoordinator: AuthTokenRefreshCoordinator = AuthTokenRefreshCoordinator()
  ) {
    self.apiClient = apiClient
    self.tokenStore = tokenStore
    self.refreshCoordinator = refreshCoordinator
  }

  func registerFederated(_ request: FederatedRegisterRequest) async throws -> FederatedRegisterResponse {
    let body: Data = try apiClient.makeJSONBody(request)
    let apiRequest: APIRequest = APIRequest(path: "auth/register", method: .post, body: body)
    let response: FederatedRegisterResponse = try await apiClient.send(apiRequest, requiresAuth: false)

    tokenStore.saveTokens(
      accessToken: response.sessionToken,
      refreshToken: response.refreshToken
    )

    return response
  }

  func startChallenge(userHandle: String, deviceId: String?) async throws -> FederatedAuthStartResponse {
    let payload = FederatedAuthStartRequest(userHandle: userHandle, deviceId: deviceId)
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "auth/start", method: .post, body: body)
    return try await apiClient.send(request, requiresAuth: false)
  }

  func finishChallenge(_ requestPayload: FederatedAuthFinishRequest) async throws -> FederatedSessionTokens {
    let body: Data = try apiClient.makeJSONBody(requestPayload)
    let request: APIRequest = APIRequest(path: "auth/finish", method: .post, body: body)
    let response: FederatedSessionTokens = try await apiClient.send(request, requiresAuth: false)

    tokenStore.saveTokens(
      accessToken: response.sessionToken,
      refreshToken: response.refreshToken
    )

    return response
  }

  func publishPrekeys(
    deviceId: String,
    signedPrekey: SignedPrekeyBundle,
    oneTimePrekeys: [OneTimePrekeyBundle]
  ) async throws -> FederatedPrekeysPublishResponse {
    let requestPayload = FederatedPrekeysPublishRequest(
      protocolVersion: 2,
      deviceId: deviceId,
      signedPrekey: FederatedPrekeySigned(
        prekeyId: signedPrekey.prekeyId,
        signedPrekeyPub: signedPrekey.signedPrekeyPub,
        signature: signedPrekey.signature,
        expiresAt: nil
      ),
      oneTimePrekeys: oneTimePrekeys.map {
        FederatedPrekeyOneTime(prekeyId: $0.prekeyId, prekeyPub: $0.prekeyPub)
      }
    )

    let body: Data = try apiClient.makeJSONBody(requestPayload)
    let request: APIRequest = APIRequest(path: "prekeys/publish", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func fetchPrekeys(userHandle: String, deviceId: String?, peek: Bool = false) async throws -> FederatedPrekeysGetResponse {
    var queryItems: [URLQueryItem] = [URLQueryItem(name: "user", value: userHandle)]
    if let deviceId {
      queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
    }
    if peek {
      queryItems.append(URLQueryItem(name: "peek", value: "true"))
    }

    let request: APIRequest = APIRequest(path: "prekeys/get", method: .get, queryItems: queryItems)
    let hasSessionToken: Bool = tokenStore.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    return try await apiClient.send(request, requiresAuth: hasSessionToken)
  }

  func fetchSelfPrekeys(deviceId: String?, peek: Bool = false) async throws -> FederatedPrekeysGetResponse {
    var queryItems: [URLQueryItem] = []
    if let deviceId {
      queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
    }
    if peek {
      queryItems.append(URLQueryItem(name: "peek", value: "true"))
    }

    let request: APIRequest = APIRequest(path: "prekeys/self", method: .get, queryItems: queryItems)
    return try await apiClient.send(request)
  }

  func refreshTokens() async throws -> FederatedSessionTokens {
    try await refreshCoordinator.refresh { [apiClient, tokenStore] in
      try await Self.performRefreshTokens(apiClient: apiClient, tokenStore: tokenStore)
    }
  }

  private static func performRefreshTokens(
    apiClient: APIClient,
    tokenStore: TokenStore
  ) async throws -> FederatedSessionTokens {
    guard let refreshToken: String = tokenStore.refreshToken else {
      throw APIError.unauthorized
    }

    let body: Data = try apiClient.makeJSONBody(FederatedRefreshRequest(refreshToken: refreshToken))
    let request: APIRequest = APIRequest(path: "auth/refresh", method: .post, body: body)
    let response: FederatedSessionTokens = try await apiClient.send(request, requiresAuth: false)

    tokenStore.saveTokens(
      accessToken: response.sessionToken,
      refreshToken: response.refreshToken
    )

    return response
  }

  func logout() async throws {
    let payload = FederatedLogoutRequest(
      sessionToken: tokenStore.accessToken,
      refreshToken: tokenStore.refreshToken
    )

    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "auth/logout", method: .post, body: body)
    _ = try await apiClient.send(request) as FederatedLogoutResponse
    tokenStore.clear()
  }

  func fetchPublicKey(userHandle: String) async throws -> PublicKeyResponse {
    let response = try await fetchPrekeys(userHandle: userHandle, deviceId: nil, peek: true)
    guard let firstBundle: FederatedPrekeyBundle = response.bundles.first else {
      throw APIError.server(statusCode: 404, message: "Unavailable")
    }

    let hash = SHA256.hash(data: Data(firstBundle.accountSignPub.utf8))
    let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined()

    return PublicKeyResponse(
      userId: userHandle,
      publicKey: firstBundle.accountSignPub,
      fingerprint: fingerprint
    )
  }
}
