import Foundation
import XCTest
@testable import messenger

final class MessageServiceTests: XCTestCase {
  func testSendDeliveriesUsesFederatedEndpoint() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 202,
      json:
        """
        {
          "accepted": 1,
          "results": [
            {
              "delivery_id": "00000000-0000-0000-0000-000000000001",
              "status": "queued_local"
            }
          ]
        }
        """
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let deliveries: [FederatedDelivery] = [
      FederatedDelivery(
        wireVersion: 2,
        deliveryId: "00000000-0000-0000-0000-000000000001",
        toServer: "localhost",
        toUser: "@bob:localhost",
        toDeviceId: "*",
        messageId: "00000000-0000-0000-0000-000000000002",
        timestamp: makeISODateString(),
        ttlSec: 86400,
        ciphertextBlob: "ciphertext",
        pushKind: .message,
        wakeupClass: nil
      )
    ]

    let response: FederatedSendResponse = try await service.sendDeliveries(deliveries)

    XCTAssertEqual(response.accepted, 1)
    XCTAssertEqual(response.results.first?.status, "queued_local")
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/messages/send") == true)
    XCTAssertEqual(networkClient.requests.first?.httpMethod, "POST")

    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let payload: [String: Any] = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    let outgoing: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
    XCTAssertEqual(outgoing.first?["to_user"] as? String, "@bob:localhost")
    XCTAssertEqual(outgoing.first?["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(outgoing.first?["wakeup_class"])
  }

  func testSendDeliveriesEncodesVoipWakeupWithoutPlaintextCallPushKind() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 202,
      json:
        """
        {
          "accepted": 1,
          "results": [
            {
              "delivery_id": "00000000-0000-0000-0000-000000000003",
              "status": "queued_local"
            }
          ]
        }
        """
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let deliveries: [FederatedDelivery] = [
      FederatedDelivery(
        wireVersion: 2,
        deliveryId: "00000000-0000-0000-0000-000000000003",
        toServer: "localhost",
        toUser: "@bob:localhost",
        toDeviceId: "dev-b",
        messageId: "00000000-0000-0000-0000-000000000004",
        timestamp: makeISODateString(),
        ttlSec: 86400,
        ciphertextBlob: "ciphertext",
        pushKind: nil,
        wakeupClass: .voipOpaque
      )
    ]

    _ = try await service.sendDeliveries(deliveries)

    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let payload: [String: Any] = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    let outgoing: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
    XCTAssertNil(outgoing.first?["push_kind"] as? String)
    XCTAssertEqual(outgoing.first?["wakeup_class"] as? String, WakeupClass.voipOpaque.rawValue)
  }

  func testSendDeliveriesDoesNotRetryForUnrelatedValidationError() async {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 400,
      json: "{\"error\":\"\\\"deliveries [0] ciphertext_blob\\\" is not allowed\"}"
    )

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let deliveries: [FederatedDelivery] = [
      FederatedDelivery(
        wireVersion: 2,
        deliveryId: "00000000-0000-0000-0000-000000000001",
        toServer: "localhost",
        toUser: "@bob:localhost",
        toDeviceId: "*",
        messageId: "00000000-0000-0000-0000-000000000002",
        timestamp: makeISODateString(),
        ttlSec: 86400,
        ciphertextBlob: "ciphertext",
        pushKind: nil,
        wakeupClass: nil
      )
    ]

    do {
      _ = try await service.sendDeliveries(deliveries)
      XCTFail("Expected unrelated validation error to propagate")
    } catch let error as APIError {
      guard case .server(let statusCode, let message) = error else {
        XCTFail("Unexpected APIError case: \(error)")
        return
      }

      XCTAssertEqual(statusCode, 400)
      XCTAssertTrue(message.contains("ciphertext_blob"))
      XCTAssertEqual(networkClient.requests.count, 1)
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testAckMessagesUsesFederatedAckEndpoint() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: "{\"acked\":2}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let response: FederatedAckResponse = try await service.ackMessages([
      "00000000-0000-0000-0000-000000000011",
      "00000000-0000-0000-0000-000000000012",
    ])

    XCTAssertEqual(response.acked, 2)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/messages/ack") == true)

    let body: Data = networkClient.requests.first?.httpBody ?? Data()
    let payload: [String: Any] = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    let ids: [String] = payload["msg_ids"] as? [String] ?? []
    XCTAssertEqual(ids.count, 2)
  }

  func testPullSyncUsesDeviceAndLimitQueryItems() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, json: "{\"device_id\":\"dev_1\",\"blobs\":[]}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let response: FederatedSyncResponse = try await service.pullSync(deviceId: "dev_1", limit: 25)

    XCTAssertEqual(response.deviceId, "dev_1")
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("/api/sync/stream") == true)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("device_id=dev_1") == true)
    XCTAssertTrue(networkClient.requests.first?.url?.absoluteString.contains("limit=25") == true)
  }

  func testMediaUploadEndpointsUseFederatedPaths() async throws {
    let expiresAt: String = makeISODateString()
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(
      statusCode: 201,
      json:
        """
        {
          "media_id": "m_1",
          "upload_path": "/api/media/upload/m_1",
          "download_path": "/api/media/ciphertext/m_1",
          "download_capability": "cap-1",
          "origin_server": "messenger.example.com",
          "expires_at": "\(expiresAt)"
        }
        """
    )
    networkClient.enqueue(statusCode: 200, json: "{\"media_id\":\"m_1\",\"uploaded\":true}")

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let initResponse: FederatedMediaUploadInitResponse = try await service.initMediaUpload(
      mimeHint: "image/jpeg",
      sizeHint: 123,
      ttlSec: 3600
    )

    XCTAssertEqual(initResponse.mediaId, "m_1")
    XCTAssertEqual(initResponse.downloadCapability, "cap-1")
    XCTAssertEqual(initResponse.originServer, "messenger.example.com")
    XCTAssertTrue(networkClient.requests[0].url?.absoluteString.contains("/api/media/upload/init") == true)

    let uploadResponse: FederatedMediaUploadResponse = try await service.uploadCiphertext(
      mediaId: "m_1",
      ciphertext: Data([1, 2, 3]),
      attestation: MediaUploadAttestationPayload(
        capabilityToken: "cap-1",
        ciphertextSha256: "abc123",
        scanVerdict: .clean,
        riskFlags: [],
        scannerVersion: 1,
        rulesVersion: 1,
        attestationSignature: "sig-1"
      )
    )

    XCTAssertEqual(uploadResponse.uploaded, true)
    XCTAssertEqual(networkClient.requests[1].httpMethod, "PUT")
    XCTAssertTrue(networkClient.requests[1].url?.absoluteString.contains("/api/media/upload/m_1") == true)
    XCTAssertEqual(networkClient.requests[1].value(forHTTPHeaderField: "x-media-download-capability"), "cap-1")
    XCTAssertEqual(networkClient.requests[1].value(forHTTPHeaderField: "x-media-ciphertext-sha256"), "abc123")
    XCTAssertEqual(networkClient.requests[1].value(forHTTPHeaderField: "x-media-scan-verdict"), "clean")
    XCTAssertEqual(networkClient.requests[1].value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
  }

  func testDownloadCiphertextUsesOriginServerCapabilityBearer() async throws {
    let networkClient: MockNetworkClient = MockNetworkClient()
    networkClient.enqueue(statusCode: 200, data: Data([9, 8, 7]))

    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")
    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    let ciphertext: Data = try await service.downloadCiphertext(
      mediaId: "m_77",
      originServer: "origin.example.com",
      downloadCapability: "cap-77"
    )

    XCTAssertEqual(ciphertext, Data([9, 8, 7]))
    XCTAssertEqual(networkClient.requests.first?.url?.host, "origin.example.com")
    XCTAssertEqual(networkClient.requests.first?.url?.path, "/api/media/ciphertext/m_77")
    XCTAssertEqual(networkClient.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer cap-77")
  }

  func testLegacyMessagesListThrowsWhenApiRemoved() async {
    let networkClient: MockNetworkClient = MockNetworkClient()
    let tokenStore: InMemoryTokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "a", refreshToken: "r")

    let apiClient: APIClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service: MessageService = MessageService(apiClient: apiClient)

    do {
      _ = try await service.listMessages(conversationId: "conv1", limit: 20, offset: 0)
      XCTFail("Expected legacy messages API to be disabled")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Legacy messages API removed"))
    }

    XCTAssertEqual(networkClient.requests.count, 0)
  }

  private func requestBody(for request: URLRequest) throws -> [String: Any] {
    let body: Data = request.httpBody ?? Data()
    return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
  }
}
