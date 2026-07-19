import Foundation
@testable import messenger

enum TestDoubleError: Error {
  case unimplemented
}

final class MessageServiceStub: MessageServiceProtocol {
  var syncResponse: FederatedSyncResponse
  var pullSyncError: Error?

  init(
    syncResponse: FederatedSyncResponse = FederatedSyncResponse(deviceId: "test-device", blobs: []),
    pullSyncError: Error? = nil
  ) {
    self.syncResponse = syncResponse
    self.pullSyncError = pullSyncError
  }

  func sendDeliveries(_ deliveries: [FederatedDelivery]) async throws -> FederatedSendResponse {
    _ = deliveries
    throw TestDoubleError.unimplemented
  }

  func ackMessages(_ messageIds: [String]) async throws -> FederatedAckResponse {
    _ = messageIds
    throw TestDoubleError.unimplemented
  }

  func pullSync(deviceId: String?, limit: Int) async throws -> FederatedSyncResponse {
    _ = deviceId
    _ = limit
    if let pullSyncError {
      throw pullSyncError
    }
    return syncResponse
  }

  func initMediaUpload(
    mimeHint: String?,
    sizeHint: Int?,
    ttlSec: Int?
  ) async throws -> FederatedMediaUploadInitResponse {
    _ = mimeHint
    _ = sizeHint
    _ = ttlSec
    throw TestDoubleError.unimplemented
  }

  func uploadCiphertext(
    mediaId: String,
    ciphertext: Data,
    attestation: MediaUploadAttestationPayload
  ) async throws -> FederatedMediaUploadResponse {
    _ = mediaId
    _ = ciphertext
    _ = attestation
    throw TestDoubleError.unimplemented
  }

  func downloadCiphertext(
    mediaId: String,
    originServer: String,
    downloadCapability: String
  ) async throws -> Data {
    _ = mediaId
    _ = originServer
    _ = downloadCapability
    throw TestDoubleError.unimplemented
  }

  func listMessages(conversationId: String, limit: Int, offset: Int) async throws -> MessageListResponse {
    _ = conversationId
    _ = limit
    _ = offset
    throw TestDoubleError.unimplemented
  }

  func sendMessage(conversationId: String, payload: MessageSendPayload) async throws -> MessageResponse {
    _ = conversationId
    _ = payload
    throw TestDoubleError.unimplemented
  }

  func sendFileMessage(
    conversationId: String,
    payload: MessageSendPayload,
    file: MultiPartFile
  ) async throws -> MessageResponse {
    _ = conversationId
    _ = payload
    _ = file
    throw TestDoubleError.unimplemented
  }

  func markAsRead(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func markAsDelivered(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func editMessage(messageId: String, content: String) async throws -> MessageResponse {
    _ = messageId
    _ = content
    throw TestDoubleError.unimplemented
  }

  func deleteMessage(messageId: String) async throws -> MessageResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func deleteMessageForMe(messageId: String) async throws {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func addReaction(messageId: String, emoji: String) async throws -> ReactionResponse {
    _ = messageId
    _ = emoji
    throw TestDoubleError.unimplemented
  }

  func removeReaction(messageId: String) async throws -> ReactionsResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func listReactions(messageId: String) async throws -> ReactionsResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }

  func listEdits(messageId: String) async throws -> MessageEditsResponse {
    _ = messageId
    throw TestDoubleError.unimplemented
  }
}
