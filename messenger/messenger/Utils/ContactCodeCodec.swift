import Foundation

enum ContactCodeCodec {
  static let textPrefix: String = "tm1:"

  enum DecodeError: Error {
    case invalidPayload
  }

  static func encodeJSON(_ card: QRContactCard) throws -> String {
    let data: Data = try JSONCoding.encoder.encode(card)
    guard let json: String = String(data: data, encoding: .utf8) else {
      throw DecodeError.invalidPayload
    }

    return json
  }

  static func encodeTextCode(_ card: QRContactCard) throws -> String {
    let json: String = try encodeJSON(card)
    let encoded: String = base64URLEncode(Data(json.utf8))
    return "\(textPrefix)\(encoded)"
  }

  static func decode(_ raw: String) -> QRContactCard? {
    let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if let card: QRContactCard = decodeJSON(trimmed) {
      return card
    }

    if trimmed.lowercased().hasPrefix(textPrefix),
      let token: String = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init),
      let decoded = base64URLDecode(token),
      let json: String = String(data: decoded, encoding: .utf8),
      let card: QRContactCard = decodeJSON(json)
    {
      return card
    }

    if let components: URLComponents = URLComponents(string: trimmed),
      let scheme: String = components.scheme?.lowercased(),
      scheme == "tellme" || scheme == "tm",
      let queryItems = components.queryItems,
      let code: String = queryItems.first(where: { $0.name == "code" })?.value,
      let decoded = base64URLDecode(code),
      let json: String = String(data: decoded, encoding: .utf8),
      let card: QRContactCard = decodeJSON(json)
    {
      return card
    }

    return nil
  }

  private static func decodeJSON(_ raw: String) -> QRContactCard? {
    guard let data: Data = raw.data(using: .utf8) else {
      return nil
    }

    return try? JSONCoding.decoder.decode(QRContactCard.self, from: data)
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64URLDecode(_ raw: String) -> Data? {
    let normalized = raw
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder: Int = normalized.count % 4
    let paddingCount: Int = remainder == 0 ? 0 : (4 - remainder)
    let padded = normalized + String(repeating: "=", count: paddingCount)
    return Data(base64Encoded: padded)
  }
}
