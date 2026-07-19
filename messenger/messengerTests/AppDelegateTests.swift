import UserNotifications
import XCTest
@testable import messenger

final class AppDelegateTests: XCTestCase {
  func testPresentationOptionsShowsVisibleForegroundNotificationForMessages() {
    let options = AppDelegate.presentationOptions(for: ["hint": PushNotificationHint.message.rawValue])

    XCTAssertTrue(options.contains(.banner))
    XCTAssertTrue(options.contains(.list))
    XCTAssertTrue(options.contains(.sound))
    XCTAssertTrue(options.contains(.badge))
  }

  func testPresentationOptionsSuppressesForegroundNotificationWhenHintIsNone() {
    let options = AppDelegate.presentationOptions(for: ["hint": PushNotificationHint.none.rawValue])

    XCTAssertEqual(options, [])
  }
}
