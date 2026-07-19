import Foundation
@testable import messenger

final class MockNetworkClient: NetworkClient {
  struct QueuedResponse {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
      self.statusCode = statusCode
      self.body = body
      self.headers = headers
    }
  }

  private enum QueuedItem {
    case staticResponse(QueuedResponse)
    case dynamicResponse((URLRequest) throws -> QueuedResponse)
    case error(Error)
  }

  private(set) var requests: [URLRequest] = []
  private var responses: [QueuedItem] = []
  private var fallbackResponders: [(URLRequest) throws -> QueuedResponse?] = []

  func enqueue(statusCode: Int, json: String = "{}", headers: [String: String] = [:]) {
    let body: Data = json.data(using: .utf8) ?? Data()
    responses.append(.staticResponse(QueuedResponse(statusCode: statusCode, body: body, headers: headers)))
  }

  func enqueue(statusCode: Int, data: Data, headers: [String: String] = [:]) {
    responses.append(.staticResponse(QueuedResponse(statusCode: statusCode, body: data, headers: headers)))
  }

  func enqueueResponder(_ responder: @escaping (URLRequest) throws -> QueuedResponse) {
    responses.append(.dynamicResponse(responder))
  }

  func enqueueError(_ error: Error) {
    responses.append(.error(error))
  }

  func registerFallbackResponder(_ responder: @escaping (URLRequest) throws -> QueuedResponse?) {
    fallbackResponders.append(responder)
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)

    for responder in fallbackResponders {
      if let response = try responder(request) {
        let httpResponse: HTTPURLResponse = HTTPURLResponse(
          url: request.url ?? URL(string: "https://example.com")!,
          statusCode: response.statusCode,
          httpVersion: nil,
          headerFields: response.headers
        )!
        return (response.body, httpResponse)
      }
    }

    guard !responses.isEmpty else {
      throw APIError.transport("No queued response")
    }

    let queuedItem = responses.removeFirst()
    let response: QueuedResponse
    switch queuedItem {
    case .staticResponse(let staticResponse):
      response = staticResponse
    case .dynamicResponse(let responder):
      response = try responder(request)
    case .error(let error):
      throw error
    }
    let httpResponse: HTTPURLResponse = HTTPURLResponse(
      url: request.url ?? URL(string: "https://example.com")!,
      statusCode: response.statusCode,
      httpVersion: nil,
      headerFields: response.headers
    )!

    return (response.body, httpResponse)
  }
}

func makeISODateString(_ date: Date = Date()) -> String {
  ISO8601DateFormatter.withFractionalSeconds.string(from: date)
}
