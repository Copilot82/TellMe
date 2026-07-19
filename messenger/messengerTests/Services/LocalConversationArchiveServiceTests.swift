import CryptoKit
import Foundation
import XCTest
@testable import messenger

final class LocalConversationArchiveServiceTests: XCTestCase {
  @MainActor
  func testSnapshotRoundTripPreservesConversationHistory() throws {
    let sourceSuite: String = "LocalConversationArchiveServiceTests.source.\(UUID().uuidString)"
    let targetSuite: String = "LocalConversationArchiveServiceTests.target.\(UUID().uuidString)"
    guard let sourceDefaults: UserDefaults = UserDefaults(suiteName: sourceSuite),
      let targetDefaults: UserDefaults = UserDefaults(suiteName: targetSuite)
    else {
      XCTFail("Failed to create isolated UserDefaults suites")
      return
    }

    defer {
      sourceDefaults.removePersistentDomain(forName: sourceSuite)
      targetDefaults.removePersistentDomain(forName: targetSuite)
    }

    let userHandle: String = "@alice:example.org"
    let peerHandle: String = "@bob:example.org"
    let conversationId: String = "conv-1"
    let messageId: String = "msg-1"
    let conversation = Conversation(
      id: conversationId,
      type: .direct,
      name: peerHandle,
      createdAt: Date(),
      updatedAt: Date(),
      participants: [
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: conversationId,
          userId: userHandle,
          joinedAt: Date(),
          role: .member
        ),
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: conversationId,
          userId: peerHandle,
          joinedAt: Date(),
          role: .member
        ),
      ]
    )
    let message = Message(
      id: messageId,
      conversationId: conversationId,
      senderId: peerHandle,
      content: "hello",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
    let pin = PinnedMessage(
      id: UUID().uuidString,
      conversationId: conversationId,
      messageId: messageId,
      pinnedBy: userHandle,
      pinnedAt: Date(),
      previewText: "hello",
      messageCreatedAt: message.createdAt
    )

    sourceDefaults.set(
      try JSONCoding.encoder.encode([conversation]),
      forKey: conversationsStorageKey(owner: userHandle)
    )
    sourceDefaults.set(
      try JSONCoding.encoder.encode([message]),
      forKey: conversationStorageKey(
        prefix: "federated.local.messages.v2",
        owner: userHandle,
        conversationId: conversationId
      )
    )
    sourceDefaults.set(
      try JSONCoding.encoder.encode(["\(messageId)": "hello"]),
      forKey: conversationStorageKey(
        prefix: "federated.local.message.reply-previews.v2",
        owner: userHandle,
        conversationId: conversationId
      )
    )
    sourceDefaults.set(
      try JSONCoding.encoder.encode([pin]),
      forKey: conversationStorageKey(
        prefix: "federated.local.pins.v2",
        owner: userHandle,
        conversationId: conversationId
      )
    )
    sourceDefaults.set(
      try JSONCoding.encoder.encode([messageId]),
      forKey: conversationStorageKey(
        prefix: "federated.local.hidden-pins.v2",
        owner: userHandle,
        conversationId: conversationId
      )
    )

    let sourceService = LocalConversationArchiveService(defaults: sourceDefaults)
    let snapshot: DeviceLinkLocalStateSnapshot = sourceService.exportSnapshot(for: userHandle)

    XCTAssertEqual(snapshot.conversations.count, 1)
    XCTAssertEqual(snapshot.conversations.first?.messages.first?.content, "hello")

    let targetService = LocalConversationArchiveService(defaults: targetDefaults)
    targetService.importSnapshot(snapshot, for: userHandle)

    let restoredSnapshot: DeviceLinkLocalStateSnapshot = targetService.exportSnapshot(for: userHandle)
    XCTAssertEqual(restoredSnapshot.conversations.count, 1)
    XCTAssertEqual(restoredSnapshot.conversations.first?.conversation.id, conversationId)
    XCTAssertEqual(restoredSnapshot.conversations.first?.messages.first?.id, messageId)
    XCTAssertEqual(restoredSnapshot.conversations.first?.replyPreviewByReplyMessageId[messageId], "hello")
    XCTAssertEqual(restoredSnapshot.conversations.first?.pinnedMessages.first?.messageId, messageId)
    XCTAssertEqual(restoredSnapshot.conversations.first?.hiddenPinnedMessageIds, [messageId])
  }

  private func conversationsStorageKey(owner: String) -> String {
    let digest = SHA256.hash(data: Data(owner.lowercased().utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "federated.local.conversations.v2.\(suffix)"
  }

  private func conversationStorageKey(prefix: String, owner: String, conversationId: String) -> String {
    let rawKey: String = "\(owner.lowercased())|\(conversationId.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(prefix).\(suffix)"
  }
}
