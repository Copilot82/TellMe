import Foundation

// Multipart boundaries are generated per request to avoid collisions with ciphertext bytes.
struct MultipartFormDataBuilder {
  private let boundary: String

  init(boundary: String = "Boundary-\(UUID().uuidString)") {
    self.boundary = boundary
  }

  var contentType: String {
    "multipart/form-data; boundary=\(boundary)"
  }

  func build(fields: [String: String], file: MultiPartFile?) -> Data {
    var body: Data = Data()

    for (key, value) in fields {
      body.append("--\(boundary)\r\n")
      body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
      body.append("\(value)\r\n")
    }

    if let file {
      body.append("--\(boundary)\r\n")
      body.append(
        "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n"
      )
      body.append("Content-Type: \(file.mimeType)\r\n\r\n")
      body.append(file.data)
      body.append("\r\n")
    }

    body.append("--\(boundary)--\r\n")
    return body
  }
}

private extension Data {
  mutating func append(_ string: String) {
    if let data: Data = string.data(using: .utf8) {
      append(data)
    }
  }
}
