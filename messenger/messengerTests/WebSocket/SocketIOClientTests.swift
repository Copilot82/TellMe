import Foundation
import XCTest
@testable import messenger

final class SocketIOClientTests: XCTestCase {
  func testReconnectsAfterReceiveFailure() async throws {
    let firstTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"first\"}"),
        .message("40"),
        .error(MockSocketError.disconnected),
      ]
    )
    let secondTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"second\"}"),
        .message("40"),
      ]
    )
    let factory = MockWebSocketFactory(tasks: [firstTask, secondTask])
    let client = SocketIOClient(
      baseURL: URL(string: "wss://example.com/socket.io")!,
      webSocketFactory: { url in
        factory.make(url: url)
      },
      sleep: { _ in },
      reconnectJitterProvider: { _ in 0 }
    )

    await client.connect(token: "token-123")

    let reconnected = await waitUntil {
      let state = await client.state
      return state == .connected && factory.createdCount == 2
    }

    XCTAssertTrue(reconnected)
    XCTAssertEqual(factory.createdCount, 2)
    XCTAssertTrue(firstTask.sentStrings.contains(where: { $0.contains("token-123") }))
    XCTAssertTrue(secondTask.sentStrings.contains(where: { $0.contains("token-123") }))

    await client.disconnect()
  }

  func testReconnectReadsLatestProvidedTokenAfterTransportFailure() async throws {
    let tokenBox = LockedString("old-token")
    let firstTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"first\"}"),
        .message("40"),
        .error(MockSocketError.disconnected),
      ]
    )
    let secondTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"second\"}"),
        .message("40"),
      ]
    )
    let factory = MockWebSocketFactory(tasks: [firstTask, secondTask])
    let client = SocketIOClient(
      baseURL: URL(string: "wss://example.com/socket.io")!,
      webSocketFactory: { url in
        factory.make(url: url)
      },
      authTokenProvider: {
        tokenBox.value
      },
      sleep: { _ in
        tokenBox.value = "fresh-token"
      },
      reconnectJitterProvider: { _ in 0 }
    )

    await client.connect(token: "old-token")

    let reconnected = await waitUntil {
      let state = await client.state
      return state == .connected && factory.createdCount == 2
    }

    XCTAssertTrue(reconnected)
    XCTAssertTrue(firstTask.sentStrings.contains(where: { $0.contains("old-token") }))
    XCTAssertTrue(secondTask.sentStrings.contains(where: { $0.contains("fresh-token") }))

    await client.disconnect()
  }

  func testReconnectRefreshesTokenAfterSocketAuthenticationFailure() async throws {
    let tokenBox = LockedString("expired-token")
    let firstTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"first\"}"),
        .message("44{\"message\":\"Authentication error\"}"),
      ]
    )
    let secondTask = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"second\"}"),
        .message("40"),
      ]
    )
    let factory = MockWebSocketFactory(tasks: [firstTask, secondTask])
    let client = SocketIOClient(
      baseURL: URL(string: "wss://example.com/socket.io")!,
      webSocketFactory: { url in
        factory.make(url: url)
      },
      authTokenProvider: {
        tokenBox.value
      },
      authRefreshHandler: {
        tokenBox.value = "refreshed-token"
        return tokenBox.value
      },
      sleep: { _ in },
      reconnectJitterProvider: { _ in 0 }
    )

    await client.connect(token: "expired-token")

    let reconnected = await waitUntil {
      let state = await client.state
      return state == .connected && factory.createdCount == 2
    }

    XCTAssertTrue(reconnected)
    XCTAssertTrue(firstTask.sentStrings.contains(where: { $0.contains("expired-token") }))
    XCTAssertTrue(secondTask.sentStrings.contains(where: { $0.contains("refreshed-token") }))

    await client.disconnect()
  }

  func testManualDisconnectDoesNotScheduleReconnect() async throws {
    let reconnectGate = AsyncGate()
    let task = MockWebSocketTask(
      steps: [
        .message("0{\"sid\":\"first\"}"),
        .message("40"),
        .error(MockSocketError.disconnected),
      ]
    )
    let factory = MockWebSocketFactory(tasks: [task])
    let client = SocketIOClient(
      baseURL: URL(string: "wss://example.com/socket.io")!,
      webSocketFactory: { url in
        factory.make(url: url)
      },
      sleep: { _ in
        await reconnectGate.wait()
      },
      reconnectJitterProvider: { _ in 0 }
    )

    await client.connect(token: "token-123")
    let failed = await waitUntil {
      let state = await client.state
      if case .failed = state {
        return factory.createdCount == 1
      }

      return false
    }
    XCTAssertTrue(failed)

    await client.disconnect()
    await reconnectGate.open()
    try? await Task.sleep(nanoseconds: 100_000_000)

    let finalState = await client.state
    XCTAssertEqual(factory.createdCount, 1)
    XCTAssertEqual(finalState, .disconnected)
    XCTAssertGreaterThan(task.cancelCount, 0)
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping () async -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if await condition() {
        return true
      }

      try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }

    return await condition()
  }
}

private enum MockSocketError: Error {
  case disconnected
}

private final class LockedString: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String

  init(_ value: String) {
    self.storage = value
  }

  var value: String {
    get {
      lock.withLock {
        storage
      }
    }
    set {
      lock.withLock {
        storage = newValue
      }
    }
  }
}

private actor AsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen: Bool = false

  func wait() async {
    if isOpen {
      return
    }

    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

private final class MockWebSocketFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var remainingTasks: [MockWebSocketTask]
  private(set) var requestedURLs: [URL] = []

  init(tasks: [MockWebSocketTask]) {
    remainingTasks = tasks
  }

  var createdCount: Int {
    lock.withLock {
      requestedURLs.count
    }
  }

  func make(url: URL) -> WebSocketTasking {
    lock.withLock {
      requestedURLs.append(url)
      if remainingTasks.isEmpty {
        return MockWebSocketTask(steps: [])
      }

      return remainingTasks.removeFirst()
    }
  }
}

private final class MockWebSocketTask: @unchecked Sendable, WebSocketTasking {
  enum Step {
    case message(String)
    case error(Error)
  }

  private let lock = NSLock()
  private var steps: [Step]
  private(set) var sentStrings: [String] = []
  private(set) var resumeCount: Int = 0
  private(set) var cancelCount: Int = 0

  init(steps: [Step]) {
    self.steps = steps
  }

  func resume() {
    lock.withLock {
      resumeCount += 1
    }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    _ = closeCode
    _ = reason
    lock.withLock {
      cancelCount += 1
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    let payload: String
    switch message {
    case .string(let string):
      payload = string
    case .data(let data):
      payload = String(data: data, encoding: .utf8) ?? "<binary>"
    @unknown default:
      payload = "<unknown>"
    }

    lock.withLock {
      sentStrings.append(payload)
    }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    while true {
      if Task.isCancelled {
        throw CancellationError()
      }

      let nextStep: Step? = lock.withLock {
        guard !steps.isEmpty else {
          return nil
        }

        return steps.removeFirst()
      }

      if let nextStep {
        switch nextStep {
        case .message(let payload):
          return .string(payload)
        case .error(let error):
          throw error
        }
      }

      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}
