import Foundation

enum SocketIOPacket {
  case engineOpen
  case socketConnected
  case ping
  case pong
  case event(name: String, payload: Data?)
  case error(String)
  case unknown
}

enum SocketIOPacketCodec {
  static func decode(_ message: String) -> SocketIOPacket {
    if message == "2" {
      return .ping
    }

    if message == "3" {
      return .pong
    }

    if message.hasPrefix("0") {
      return .engineOpen
    }

    if message.hasPrefix("40") {
      return .socketConnected
    }

    if message.hasPrefix("44") {
      return .error(String(message.dropFirst(2)))
    }

    if message.hasPrefix("42") {
      let rawPayload: String = String(message.dropFirst(2))

      guard let data: Data = rawPayload.data(using: .utf8),
        let jsonArray: [Any] = try? JSONSerialization.jsonObject(with: data) as? [Any],
        let name: String = jsonArray.first as? String
      else {
        return .unknown
      }

      guard jsonArray.count > 1 else {
        return .event(name: name, payload: nil)
      }

      let eventPayload: Any = jsonArray[1]
      let payloadData: Data? = try? JSONSerialization.data(withJSONObject: eventPayload)
      return .event(name: name, payload: payloadData)
    }

    return .unknown
  }

  static func encodeConnect(auth: [String: Any]) throws -> String {
    let data: Data = try JSONSerialization.data(withJSONObject: auth)
    guard let string: String = String(data: data, encoding: .utf8) else {
      throw APIError.encoding("Socket connect payload encoding failed")
    }

    return "40\(string)"
  }

  static func encodeEvent(name: String, payload: [String: Any]?) throws -> String {
    var array: [Any] = [name]
    if let payload {
      array.append(payload)
    }

    let data: Data = try JSONSerialization.data(withJSONObject: array)
    guard let string: String = String(data: data, encoding: .utf8) else {
      throw APIError.encoding("Socket event encoding failed")
    }

    return "42\(string)"
  }
}
