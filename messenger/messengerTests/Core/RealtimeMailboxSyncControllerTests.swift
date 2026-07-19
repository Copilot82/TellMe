import XCTest
@testable import messenger

@MainActor
final class RealtimeMailboxSyncControllerTests: XCTestCase {
  func testSubscribesAndSynchronizesMailboxWhenSocketConnects() async {
    let client = SocketIOClient(baseURL: URL(string: "wss://example.com/socket.io")!)
    let router = RealtimeEventRouter(socketClient: client)
    let subscribeExpectation = expectation(description: "sync subscription requested")
    let syncExpectation = expectation(description: "mailbox sync requested")
    var observedReasons: [String] = []

    let controller = RealtimeMailboxSyncController(
      realtimeRouter: router,
      subscribeSync: {
        subscribeExpectation.fulfill()
      },
      synchronizeMailbox: { reason in
        observedReasons.append(reason)
        syncExpectation.fulfill()
        return true
      }
    )

    router.updateConnectionStateForTesting(.connected)

    await fulfillment(of: [subscribeExpectation, syncExpectation], timeout: 1)
    XCTAssertEqual(observedReasons, ["socket_connected"])
    _ = controller
  }

  func testSynchronizesMailboxWhenRealtimeSyncBlobBecomesAvailable() async throws {
    let client = SocketIOClient(baseURL: URL(string: "wss://example.com/socket.io")!)
    let router = RealtimeEventRouter(socketClient: client)
    let syncExpectation = expectation(description: "mailbox sync requested")
    var observedReasons: [String] = []

    let controller = RealtimeMailboxSyncController(
      realtimeRouter: router,
      subscribeSync: {},
      synchronizeMailbox: { reason in
        observedReasons.append(reason)
        syncExpectation.fulfill()
        return true
      }
    )

    let payload = SyncBlobAvailableEvent(
      messageId: "message-1",
      deliveryId: "delivery-1",
      deviceId: "device-1"
    )
    router.routeForTesting(
      event: SocketEvent(
        name: SocketEventName.syncBlobAvailable,
        payload: try JSONCoding.encoder.encode(payload)
      )
    )

    await fulfillment(of: [syncExpectation], timeout: 1)
    XCTAssertEqual(observedReasons, ["sync_blob_available"])
    _ = controller
  }
}
