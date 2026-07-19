import Foundation

// Device-link codes carry bootstrapping metadata but never private identity material.
enum DeviceLinkCodeCodec {
  static let textPrefix: String = "tml1:"

  static func encodeJSON(_ payload: DeviceLinkCodePayload) throws -> String {
    let data: Data = try JSONCoding.encoder.encode(payload)
    guard let json: String = String(data: data, encoding: .utf8) else {
      throw APIError.decoding("Invalid device link payload")
    }

    return json
  }

  static func encodeTextCode(_ payload: DeviceLinkCodePayload) throws -> String {
    let json: String = try encodeJSON(payload)
    let encoded: String = base64URLEncode(Data(json.utf8))
    return "\(textPrefix)\(encoded)"
  }

  static func decode(_ raw: String) -> DeviceLinkCodePayload? {
    let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if let payload: DeviceLinkCodePayload = decodeJSON(trimmed) {
      return payload
    }

    if trimmed.lowercased().hasPrefix(textPrefix),
      let token: String = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init),
      let decoded = base64URLDecode(token),
      let json: String = String(data: decoded, encoding: .utf8),
      let payload: DeviceLinkCodePayload = decodeJSON(json)
    {
      return payload
    }

    if let components: URLComponents = URLComponents(string: trimmed),
      let scheme: String = components.scheme?.lowercased(),
      scheme == "tellme" || scheme == "tm",
      let queryItems = components.queryItems,
      let code: String = queryItems.first(where: { $0.name == "link" })?.value,
      let decoded = base64URLDecode(code),
      let json: String = String(data: decoded, encoding: .utf8),
      let payload: DeviceLinkCodePayload = decodeJSON(json)
    {
      return payload
    }

    return nil
  }

  private static func decodeJSON(_ raw: String) -> DeviceLinkCodePayload? {
    guard let data: Data = raw.data(using: .utf8) else {
      return nil
    }

    return try? JSONCoding.decoder.decode(DeviceLinkCodePayload.self, from: data)
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
