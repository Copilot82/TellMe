import XCTest
@testable import messenger

final class TestServerConfigurationTests: XCTestCase {
  func testBuildsHandleFromLogin() {
    XCTAssertEqual(
      TestServerConfiguration.userHandle(fromRegistrationInput: "Alice_01"),
      "@alice_01:messenger.surraund.com"
    )
  }

  func testAcceptsCompleteHandleForUITestCompatibility() {
    XCTAssertEqual(
      TestServerConfiguration.userHandle(
        fromRegistrationInput: "@alice:messenger.surraund.com"
      ),
      "@alice:messenger.surraund.com"
    )
  }

  func testRejectsAnotherServerAndInvalidCharacters() {
    XCTAssertNil(TestServerConfiguration.userHandle(fromRegistrationInput: "@alice:example.org"))
    XCTAssertNil(TestServerConfiguration.userHandle(fromRegistrationInput: "alice bob"))
  }
}
