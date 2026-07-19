import Foundation

enum HTTPMethod: String {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"
}

enum APIError: Error, Equatable, LocalizedError {
  case invalidURL
  case invalidResponse
  case transport(String)
  case server(statusCode: Int, message: String)
  case decoding(String)
  case encoding(String)
  case unauthorized

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Invalid API URL"
    case .invalidResponse:
      return "Invalid API response"
    case .transport(let message):
      return message
    case .server(_, let message):
      return message
    case .decoding(let message):
      return "Response decoding failed: \(message)"
    case .encoding(let message):
      return "Request encoding failed: \(message)"
    case .unauthorized:
      return "Unauthorized. Please log in again."
    }
  }
}

struct APIRequest {
  let path: String
  let method: HTTPMethod
  let queryItems: [URLQueryItem]
  let headers: [String: String]
  let body: Data?
  let baseURLOverride: URL?

  init(
    path: String,
    method: HTTPMethod,
    queryItems: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil,
    baseURLOverride: URL? = nil
  ) {
    self.path = path
    self.method = method
    self.queryItems = queryItems
    self.headers = headers
    self.body = body
    self.baseURLOverride = baseURLOverride
  }
}

struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init<T: Encodable>(_ wrapped: T) {
    self.encodeClosure = wrapped.encode(to:)
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

struct MultiPartFile {
  let fieldName: String
  let fileName: String
  let mimeType: String
  let data: Data

  init(fieldName: String = "file", fileName: String, mimeType: String, data: Data) {
    self.fieldName = fieldName
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }
}
