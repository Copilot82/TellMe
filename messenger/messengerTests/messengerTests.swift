import XCTest
@testable import messenger

final class messengerTests: XCTestCase {
  func testTokenStoreInMemoryLifecycle() {
    let store: InMemoryTokenStore = InMemoryTokenStore()

    XCTAssertNil(store.accessToken)
    XCTAssertNil(store.refreshToken)

    store.saveTokens(accessToken: "a", refreshToken: "r")

    XCTAssertEqual(store.accessToken, "a")
    XCTAssertEqual(store.refreshToken, "r")

    store.clear()

    XCTAssertNil(store.accessToken)
    XCTAssertNil(store.refreshToken)
  }
}
