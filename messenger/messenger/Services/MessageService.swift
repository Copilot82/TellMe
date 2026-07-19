import Foundation

private struct LegacyCompatibleFederatedDelivery: Codable, Equatable {
  let wireVersion: Int
  let deliveryId: String
  let toServer: String
  let toUser: String
  let toDeviceId: String
  let messageId: String
  let timestamp: String
  let ttlSec: Int
  let ciphertextBlob: String
  let pushKind: PushKind?

  init(_ delivery: FederatedDelivery) {
    wireVersion = delivery.wireVersion
    deliveryId = delivery.deliveryId
    toServer = delivery.toServer
    toUser = delivery.toUser
    toDeviceId = delivery.toDeviceId
    messageId = delivery.messageId
    timestamp = delivery.timestamp
    ttlSec = delivery.ttlSec
    ciphertextBlob = delivery.ciphertextBlob
    pushKind = delivery.pushKind
  }
}

protocol MessageServiceProtocol {
  func sendDeliveries(_ deliveries: [FederatedDelivery]) async throws -> FederatedSendResponse
  func ackMessages(_ messageIds: [String]) async throws -> FederatedAckResponse
  func pullSync(deviceId: String?, limit: Int) async throws -> FederatedSyncResponse
  func initMediaUpload(mimeHint: String?, sizeHint: Int?, ttlSec: Int?) async throws -> FederatedMediaUploadInitResponse
  func uploadCiphertext(
    mediaId: String,
    ciphertext: Data,
    attestation: MediaUploadAttestationPayload
  ) async throws -> FederatedMediaUploadResponse
  func downloadCiphertext(
    mediaId: String,
    originServer: String,
    downloadCapability: String
  ) async throws -> Data

  func listMessages(conversationId: String, limit: Int, offset: Int) async throws -> MessageListResponse
  func sendMessage(conversationId: String, payload: MessageSendPayload) async throws -> MessageResponse
  func sendFileMessage(conversationId: String, payload: MessageSendPayload, file: MultiPartFile) async throws -> MessageResponse
  func markAsRead(messageId: String) async throws -> MessageResponse
  func markAsDelivered(messageId: String) async throws -> MessageResponse
  func editMessage(messageId: String, content: String) async throws -> MessageResponse
  func deleteMessage(messageId: String) async throws -> MessageResponse
  func deleteMessageForMe(messageId: String) async throws
  func addReaction(messageId: String, emoji: String) async throws -> ReactionResponse
  func removeReaction(messageId: String) async throws -> ReactionsResponse
  func listReactions(messageId: String) async throws -> ReactionsResponse
  func listEdits(messageId: String) async throws -> MessageEditsResponse
}

// Legacy message endpoints remain isolated from the federated encrypted delivery path.
final class MessageService: MessageServiceProtocol {
  private struct LegacyRemovedError: LocalizedError {
    var errorDescription: String? {
      "Legacy messages API removed. Use federated send/sync/ack APIs."
    }
  }

  private let apiClient: APIClient

  init(apiClient: APIClient) {
    self.apiClient = apiClient
  }

  func sendDeliveries(_ deliveries: [FederatedDelivery]) async throws -> FederatedSendResponse {
    try await sendDeliveriesRequest(deliveries)
  }

  func ackMessages(_ messageIds: [String]) async throws -> FederatedAckResponse {
    let body: Data = try apiClient.makeJSONBody(FederatedAckRequest(msgIds: messageIds))
    let request: APIRequest = APIRequest(path: "messages/ack", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func pullSync(deviceId: String?, limit: Int = 200) async throws -> FederatedSyncResponse {
    var queryItems: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(max(1, min(1000, limit))))]
    if let deviceId {
      queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
    }

    let request: APIRequest = APIRequest(path: "sync/stream", method: .get, queryItems: queryItems)
    return try await apiClient.send(request)
  }

  func initMediaUpload(mimeHint: String?, sizeHint: Int?, ttlSec: Int?) async throws -> FederatedMediaUploadInitResponse {
    let payload = FederatedMediaUploadInitRequest(mimeHint: mimeHint, sizeHint: sizeHint, ttlSec: ttlSec)
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "media/upload/init", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func uploadCiphertext(
    mediaId: String,
    ciphertext: Data,
    attestation: MediaUploadAttestationPayload
  ) async throws -> FederatedMediaUploadResponse {
    let request = APIRequest(
      path: "media/upload/\(mediaId)",
      method: .put,
      headers: [
        "Content-Type": "application/octet-stream",
        "x-media-download-capability": attestation.capabilityToken,
        "x-media-ciphertext-sha256": attestation.ciphertextSha256,
        "x-media-scan-verdict": attestation.scanVerdict.rawValue,
        "x-media-risk-flags": AttachmentSecurity.canonicalizeRiskFlags(attestation.riskFlags).joined(separator: ","),
        "x-media-scanner-version": String(attestation.scannerVersion),
        "x-media-rules-version": String(attestation.rulesVersion),
        "x-media-attestation-signature": attestation.attestationSignature,
      ],
      body: ciphertext
    )

    return try await apiClient.send(request)
  }

  func downloadCiphertext(
    mediaId: String,
    originServer: String,
    downloadCapability: String
  ) async throws -> Data {
    let request = APIRequest(
      path: "media/ciphertext/\(mediaId)",
      method: .get,
      headers: [
        "Authorization": "Bearer \(downloadCapability)",
      ],
      baseURLOverride: apiClient.environment.mediaOriginAPIBaseURL(serverDomain: originServer)
    )

    return try await apiClient.sendData(request, requiresAuth: false)
  }

  func listMessages(conversationId: String, limit: Int = 50, offset: Int = 0) async throws -> MessageListResponse {
    _ = conversationId
    _ = limit
    _ = offset
    throw LegacyRemovedError()
  }

  func sendMessage(conversationId: String, payload: MessageSendPayload) async throws -> MessageResponse {
    _ = conversationId
    _ = payload
    throw LegacyRemovedError()
  }

  func sendFileMessage(conversationId: String, payload: MessageSendPayload, file: MultiPartFile) async throws -> MessageResponse {
    _ = conversationId
    _ = payload
    _ = file
    throw LegacyRemovedError()
  }

  func markAsRead(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  func markAsDelivered(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  func editMessage(messageId: String, content: String) async throws -> MessageResponse {
    _ = messageId
    _ = content
    throw LegacyRemovedError()
  }

  func deleteMessage(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  func deleteMessageForMe(messageId: String) async throws {
    _ = messageId
    throw LegacyRemovedError()
  }

  func addReaction(messageId: String, emoji: String) async throws -> ReactionResponse {
    _ = messageId
    _ = emoji
    throw LegacyRemovedError()
  }

  func removeReaction(messageId: String) async throws -> ReactionsResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  func listReactions(messageId: String) async throws -> ReactionsResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  func listEdits(messageId: String) async throws -> MessageEditsResponse {
    _ = messageId
    throw LegacyRemovedError()
  }

  // Federated send keeps the compatibility shim local to request construction.
  private func sendDeliveriesRequest(
    _ deliveries: [FederatedDelivery]
  ) async throws -> FederatedSendResponse {
    let body: Data = try apiClient.makeJSONBody(FederatedSendRequest(deliveries: deliveries))
    let request: APIRequest = APIRequest(path: "messages/send", method: .post, body: body)
    return try await apiClient.send(request)
  }
}
