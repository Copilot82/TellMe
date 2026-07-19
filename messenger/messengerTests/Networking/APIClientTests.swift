import XCTest
@testable import messenger

final class APIClientTests: XCTestCase {
  func testSendAddsAuthorizationHeader() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: "{\"message\":\"ok\"}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access-1", refreshToken: "refresh-1")

    let apiClient: APIClient = APIClient(
      environment: .local,
      networkClient: networkClient,
      tokenStore: tokenStore
    )

    struct Response: Codable {
      let message: String
    }

    let _: Response = try await apiClient.send(APIRequest(path: "health-check", method: .get))

    XCTAssertEqual(networkClient.requests.count, 1)
    XCTAssertEqual(networkClient.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
  }

  func testSendRetriesAfterRefreshOnUnauthorized() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 401, json: "{\"error\":\"Unauthorized\"}")
    networkClient.enqueue(statusCode: 200, json: "{\"message\":\"ok\"}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "expired", refreshToken: "refresh-1")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)

    var refreshCalled: Int = 0
    apiClient.setRefreshHandler {
      refreshCalled += 1
      tokenStore.saveTokens(accessToken: "fresh", refreshToken: "refresh-2")
    }

    struct Response: Codable {
      let message: String
    }

    let response: Response = try await apiClient.send(APIRequest(path: "retry-path", method: .get))

    XCTAssertEqual(response.message, "ok")
    XCTAssertEqual(refreshCalled, 1)
    XCTAssertEqual(networkClient.requests.count, 2)
    XCTAssertEqual(networkClient.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
  }

  func testSendThrowsServerErrorMessage() async {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 400, json: "{\"error\":\"bad request\"}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access", refreshToken: "refresh")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)

    do {
      struct Response: Codable {
        let id: String
      }

      let _: Response = try await apiClient.send(APIRequest(path: "boom", method: .get))
      XCTFail("Expected error")
    } catch let error as APIError {
      guard case .server(let statusCode, let message) = error else {
        XCTFail("Unexpected APIError case: \(error)")
        return
      }

      XCTAssertEqual(statusCode, 400)
      XCTAssertEqual(message, "bad request")
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testSendReportsRateLimitRetryAfter() async {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 429,
      json: "{\"error\":\"Too many requests\"}",
      headers: ["Retry-After": "60"]
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)

    do {
      struct Response: Codable {
        let id: String
      }

      let _: Response = try await apiClient.send(APIRequest(path: "auth/register", method: .post), requiresAuth: false)
      XCTFail("Expected rate limit error")
    } catch let error as APIError {
      guard case .server(let statusCode, let message) = error else {
        XCTFail("Unexpected APIError case: \(error)")
        return
      }

      XCTAssertEqual(statusCode, 429)
      XCTAssertEqual(message, "Слишком много запросов для auth/register. Подождите 60 сек. и повторите действие.")
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}
