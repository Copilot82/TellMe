import XCTest
@testable import messenger

final class URLSessionNetworkClientTests: XCTestCase {
  func testDefaultPinningIsDisabledWithoutExplicitEnvironmentPins() {
    let pins = URLSessionNetworkClient.pinnedLeafCertificateHashes(environment: [:])

    XCTAssertTrue(pins.isEmpty)
  }

  func testExplicitEnvironmentPinsAreScopedToProductionHost() {
    let pins = URLSessionNetworkClient.pinnedLeafCertificateHashes(environment: [
      "E2E_API_PRIMARY_CERT_SHA256": " ABCD ",
      "E2E_API_BACKUP_CERT_SHA256": "ef01",
    ])

    XCTAssertEqual(pins["messenger.surraund.com"], Set(["abcd", "ef01"]))
  }

  func testLocalEnvironmentDisablesExplicitPins() {
    let pins = URLSessionNetworkClient.pinnedLeafCertificateHashes(environment: [
      "MESSENGER_APP_ENV": "local",
      "E2E_API_PRIMARY_CERT_SHA256": "abcd",
    ])

    XCTAssertTrue(pins.isEmpty)
  }

  func testCancelledTransportErrorDoesNotSurfaceBareCancelledMessage() {
    let message = URLSessionNetworkClient.describeTransportError(URLError(.cancelled))

    XCTAssertTrue(message.contains("TLS trust validation failed"))
    XCTAssertFalse(message.lowercased() == "cancelled")
  }
}
