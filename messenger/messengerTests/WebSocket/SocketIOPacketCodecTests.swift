import XCTest
@testable import messenger

final class SocketIOPacketCodecTests: XCTestCase {
  func testDecodeSocketEventPacket() throws {
    let packet: SocketIOPacket = SocketIOPacketCodec.decode("42[\"new_message\",{\"id\":\"m1\"}]")

    switch packet {
    case .event(let name, let payload):
      XCTAssertEqual(name, "new_message")

      guard let payload else {
        XCTFail("Missing payload")
        return
      }

      let json: [String: String] = try JSONSerialization.jsonObject(with: payload) as? [String: String] ?? [:]
      XCTAssertEqual(json["id"], "m1")
    default:
      XCTFail("Unexpected packet case")
    }
  }

  func testEncodeEventPacket() throws {
    let encoded: String = try SocketIOPacketCodec.encodeEvent(
      name: "typing_start",
      payload: ["conversationId": "c1"]
    )

    XCTAssertTrue(encoded.hasPrefix("42[\"typing_start\""))
    XCTAssertTrue(encoded.contains("conversationId"))
  }

  func testDecodePing() {
    let packet: SocketIOPacket = SocketIOPacketCodec.decode("2")

    if case .ping = packet {
      XCTAssertTrue(true)
    } else {
      XCTFail("Expected ping packet")
    }
  }
}
