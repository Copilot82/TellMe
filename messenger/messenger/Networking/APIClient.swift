import Foundation

// APIClient owns token refresh retries so services can describe requests without duplicating auth recovery.
final class APIClient {
  typealias RefreshHandler = () async throws -> Void

  let environment: AppEnvironment
  private let networkClient: NetworkClient
  private let tokenStore: TokenStore
  private var refreshHandler: RefreshHandler?

  init(environment: AppEnvironment, networkClient: NetworkClient, tokenStore: TokenStore) {
    self.environment = environment
    self.networkClient = networkClient
    self.tokenStore = tokenStore
  }

  func setRefreshHandler(_ handler: @escaping RefreshHandler) {
    refreshHandler = handler
  }

  func send<T: Decodable>(_ request: APIRequest, requiresAuth: Bool = true) async throws -> T {
    try await perform(request, requiresAuth: requiresAuth, allowsRetryOnUnauthorized: true)
  }

  func sendData(_ request: APIRequest, requiresAuth: Bool = true) async throws -> Data {
    try await performData(request, requiresAuth: requiresAuth, allowsRetryOnUnauthorized: true)
  }

  private func performData(
    _ request: APIRequest,
    requiresAuth: Bool,
    allowsRetryOnUnauthorized: Bool
  ) async throws -> Data {
    let urlRequest: URLRequest = try buildURLRequest(from: request, requiresAuth: requiresAuth)
    let (data, response): (Data, HTTPURLResponse) = try await networkClient.send(urlRequest)

    if (200...299).contains(response.statusCode) {
      return data
    }

    if response.statusCode == 401,
      requiresAuth,
      allowsRetryOnUnauthorized,
      let handler: RefreshHandler = refreshHandler
    {
      try await handler()
      return try await performData(request, requiresAuth: requiresAuth, allowsRetryOnUnauthorized: false)
    }

    let message: String = serverErrorMessage(from: data, response: response, request: request)
    if response.statusCode == 401, requiresAuth {
      throw APIError.unauthorized
    }

    throw APIError.server(statusCode: response.statusCode, message: message)
  }

  func sendVoid(_ request: APIRequest, requiresAuth: Bool = true) async throws {
    _ = try await perform(request, requiresAuth: requiresAuth, allowsRetryOnUnauthorized: true) as EmptyResponse
  }

  func makeJSONBody<T: Encodable>(_ value: T) throws -> Data {
    do {
      return try JSONCoding.encoder.encode(value)
    } catch {
      throw APIError.encoding(error.localizedDescription)
    }
  }

  func makeMultipartBody(fields: [String: String], file: MultiPartFile?) -> (Data, String) {
    let builder: MultipartFormDataBuilder = MultipartFormDataBuilder()
    return (builder.build(fields: fields, file: file), builder.contentType)
  }

  private func perform<T: Decodable>(
    _ request: APIRequest,
    requiresAuth: Bool,
    allowsRetryOnUnauthorized: Bool
  ) async throws -> T {
    let urlRequest: URLRequest = try buildURLRequest(from: request, requiresAuth: requiresAuth)
    let (data, response): (Data, HTTPURLResponse) = try await networkClient.send(urlRequest)

    if (200...299).contains(response.statusCode) {
      return try decodeResponse(T.self, from: data)
    }

    if response.statusCode == 401,
      requiresAuth,
      allowsRetryOnUnauthorized,
      let handler: RefreshHandler = refreshHandler
    {
      try await handler()
      return try await perform(request, requiresAuth: requiresAuth, allowsRetryOnUnauthorized: false)
    }

    let message: String = serverErrorMessage(from: data, response: response, request: request)

    if response.statusCode == 401, requiresAuth {
      throw APIError.unauthorized
    }

    throw APIError.server(statusCode: response.statusCode, message: message)
  }

  private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if data.isEmpty,
      let empty: T = EmptyResponse() as? T
    {
      return empty
    }

    do {
      return try JSONCoding.decoder.decode(type, from: data)
    } catch {
      throw APIError.decoding(error.localizedDescription)
    }
  }

  private func decodeServerErrorMessage(from data: Data) -> String? {
    guard !data.isEmpty else {
      return nil
    }

    return try? JSONCoding.decoder.decode(APIErrorResponse.self, from: data).error
  }

  private func serverErrorMessage(from data: Data, response: HTTPURLResponse, request: APIRequest) -> String {
    let fallback: String = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    let message: String = decodeServerErrorMessage(from: data) ?? fallback

    guard response.statusCode == 429 else {
      return message
    }

    let normalizedPath: String = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let retryAfterValue: String? = response
      .value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let retryAfter: String = retryAfterValue, !retryAfter.isEmpty else {
      return "Слишком много запросов для \(normalizedPath). Подождите минуту и повторите действие."
    }

    return "Слишком много запросов для \(normalizedPath). Подождите \(retryAfter) сек. и повторите действие."
  }

  private func buildURLRequest(from request: APIRequest, requiresAuth: Bool) throws -> URLRequest {
    let baseURL: URL = request.baseURLOverride ?? environment.apiBaseURL
    guard var components: URLComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw APIError.invalidURL
    }

    var normalizedPath: String = request.path
    if normalizedPath.hasPrefix("/") {
      normalizedPath.removeFirst()
    }

    if !components.path.hasSuffix("/") {
      components.path += "/"
    }

    components.path += normalizedPath

    if !request.queryItems.isEmpty {
      components.queryItems = request.queryItems
    }

    guard let url: URL = components.url else {
      throw APIError.invalidURL
    }

    var urlRequest: URLRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body

    if request.headers["Content-Type"] == nil,
      request.body != nil,
      request.headers["X-Body-Format"] != "multipart"
    {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    for (key, value) in request.headers where key != "X-Body-Format" {
      urlRequest.setValue(value, forHTTPHeaderField: key)
    }

    if requiresAuth {
      guard let accessToken: String = tokenStore.accessToken,
        !accessToken.isEmpty
      else {
        throw APIError.unauthorized
      }

      urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }

    return urlRequest
  }
}
