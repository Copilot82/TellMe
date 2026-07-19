import AVKit
import CryptoKit
import Foundation
import UIKit
import WebRTC
import XCTest
@testable import messenger

final class ConversationViewModelTests: XCTestCase {
  @MainActor
  func testStatusSymbolOutgoingMessageLifecycle() throws {
    let fixture = try makeFixture(manualReadReceipts: false)

    let pending = makeMessage(
      senderId: fixture.localUserId,
      deliveredAt: nil,
      readAt: nil,
      transportState: .pending
    )
    let accepted = makeMessage(
      senderId: fixture.localUserId,
      deliveredAt: nil,
      readAt: nil,
      transportState: .accepted
    )
    let failed = makeMessage(
      senderId: fixture.localUserId,
      deliveredAt: nil,
      readAt: nil,
      transportState: .failed
    )
    let read = makeMessage(
      senderId: fixture.localUserId,
      deliveredAt: nil,
      readAt: Date(),
      transportState: .accepted
    )

    XCTAssertEqual(fixture.viewModel.statusSymbol(for: pending), "⏳")
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: accepted), "✓")
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: failed), "!")
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: read), "✓✓")
  }

  @MainActor
  func testCanManuallyMarkReadDependsOnSecurityModeAndDirection() throws {
    let manualFixture = try makeFixture(manualReadReceipts: true)
    let autoFixture = try makeFixture(manualReadReceipts: false)

    let incomingUnread = makeMessage(senderId: manualFixture.peerUserId, deliveredAt: nil, readAt: nil)
    let incomingRead = makeMessage(senderId: manualFixture.peerUserId, deliveredAt: nil, readAt: Date())
    let outgoingUnread = makeMessage(
      senderId: manualFixture.localUserId,
      deliveredAt: nil,
      readAt: nil,
      transportState: .pending
    )

    XCTAssertTrue(manualFixture.viewModel.canManuallyMarkRead(incomingUnread))
    XCTAssertFalse(manualFixture.viewModel.canManuallyMarkRead(incomingRead))
    XCTAssertFalse(manualFixture.viewModel.canManuallyMarkRead(outgoingUnread))
    XCTAssertFalse(autoFixture.viewModel.canManuallyMarkRead(incomingUnread))
  }

  @MainActor
  func testListPinnedMessagesHidesEntriesUnpinnedForCurrentUser() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let message = makeMessage(
      senderId: fixture.peerUserId,
      deliveredAt: nil,
      readAt: nil,
      transportState: nil
    )
    let pin = PinnedMessage(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      messageId: message.id,
      pinnedBy: fixture.peerUserId,
      pinnedAt: Date(),
      previewText: "Pinned preview",
      messageCreatedAt: message.createdAt
    )
    try persistMessages(
      [message],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )
    try persistPinnedMessages(
      [pin],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let viewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )

    let visibleBefore = try await viewModel.listPinnedMessages()
    XCTAssertEqual(visibleBefore.map(\.messageId), [message.id.lowercased()])
    XCTAssertTrue(viewModel.isMessagePinned(message.id))

    viewModel.unpinMessageForCurrentUser(messageId: message.id)

    let visibleAfter = try await viewModel.listPinnedMessages()
    XCTAssertTrue(visibleAfter.isEmpty)
    XCTAssertTrue(viewModel.isMessagePinned(message.id))
    XCTAssertEqual(viewModel.pinnedMessageRecord(messageId: message.id)?.messageId, message.id.lowercased())
  }

  @MainActor
  func testPinnedMessagePreviewTextUsesPersistedPreviewWhenTargetMessageIsNotLoaded() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let hiddenMessageId = UUID().uuidString
    let pin = PinnedMessage(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      messageId: hiddenMessageId,
      pinnedBy: fixture.localUserId,
      pinnedAt: Date(),
      previewText: "Remote preview snippet",
      messageCreatedAt: nil
    )
    try persistPinnedMessages(
      [pin],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let viewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )

    XCTAssertEqual(viewModel.pinnedMessagePreviewText(hiddenMessageId), "Remote preview snippet")
    XCTAssertTrue(viewModel.canUnpinMessageForEveryone(pin))
  }

  @MainActor
  func testVisiblePinnedMessagesPreferMessageCreatedAtOverPinTime() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let olderMessage = Message(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: "older",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(timeIntervalSince1970: 100),
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
    let newerMessage = Message(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: "newer",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(timeIntervalSince1970: 200),
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
    let olderMessagePinnedLater = PinnedMessage(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      messageId: olderMessage.id,
      pinnedBy: fixture.localUserId,
      pinnedAt: Date(timeIntervalSince1970: 500),
      previewText: "older",
      messageCreatedAt: olderMessage.createdAt
    )
    let newerMessagePinnedEarlier = PinnedMessage(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      messageId: newerMessage.id,
      pinnedBy: fixture.localUserId,
      pinnedAt: Date(timeIntervalSince1970: 300),
      previewText: "newer",
      messageCreatedAt: newerMessage.createdAt
    )

    try persistMessages(
      [olderMessage, newerMessage],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )
    try persistPinnedMessages(
      [olderMessagePinnedLater, newerMessagePinnedEarlier],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let viewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )

    let visiblePinnedMessages = try await viewModel.listPinnedMessages()
    XCTAssertEqual(
      visiblePinnedMessages.map(\.messageId),
      [newerMessage.id.lowercased(), olderMessage.id.lowercased()]
    )
  }

  @MainActor
  func testIngestMailboxBlobsDoesNotAckRetryableDecryptFailures() async throws {
    let fixture = try makeFixture(manualReadReceipts: false, persistSeedPhrase: false)
    let blob = try makeIncomingBlob(fixture: fixture, text: "retry later")

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertTrue(ackedIds.isEmpty)
    XCTAssertTrue(fixture.viewModel.messages.isEmpty)
    XCTAssertTrue(fixture.networkClient.requests.isEmpty)
  }

  @MainActor
  func testIngestMailboxBlobsAcksMalformedEnvelope() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")

    let malformedBlob = FederatedMailboxBlob(
      id: UUID().uuidString,
      ownerAccountId: "acc-local",
      ownerDeviceId: fixture.localDeviceId,
      senderServer: "example.org",
      messageId: UUID().uuidString,
      deliveryId: UUID().uuidString,
      ciphertextBlob: "!!!not-base64!!!",
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([malformedBlob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([malformedBlob.messageId.lowercased()]))
    XCTAssertTrue(fixture.viewModel.messages.isEmpty)
    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertTrue(fixture.networkClient.requests[0].url?.absoluteString.contains("/api/messages/ack") == true)

    let payload = try requestJSONBody(fixture.networkClient.requests[0])
    let messageIds: [String] = payload["msg_ids"] as? [String] ?? []
    XCTAssertEqual(messageIds, [malformedBlob.messageId.lowercased()])
  }

  @MainActor
  func testBackgroundPushIngestDoesNotMarkMessagesReadOrSendReceipts() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "hello from push")

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([blob.messageId.lowercased()]))
    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertNil(fixture.viewModel.messages[0].readAt)
    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertTrue(fixture.networkClient.requests[0].url?.absoluteString.contains("/api/messages/ack") == true)
  }

  @MainActor
  func testVisibleConversationAutoMarksBackgroundMessagesReadInAutoMode() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "hello from push")

    _ = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)
    XCTAssertNil(fixture.viewModel.messages[0].readAt)

    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: false)

    await fixture.viewModel.beginVisibleConversationTracking()

    XCTAssertNotNil(fixture.viewModel.messages[0].readAt)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)
    XCTAssertTrue(fixture.networkClient.requests[1].url?.absoluteString.contains("/api/prekeys/get") == true)
    XCTAssertTrue(fixture.networkClient.requests[2].url?.absoluteString.contains("/api/prekeys/self") == true)
    XCTAssertTrue(fixture.networkClient.requests[3].url?.absoluteString.contains("/api/messages/send") == true)
  }

  @MainActor
  func testRealtimeIngestDoesNotAutoMarkMessagesReadWhenConversationIsNotVisible() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "realtime hidden")

    _ = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .realtime)

    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertNil(fixture.viewModel.messages[0].readAt)
    XCTAssertTrue(fixture.networkClient.requests[0].url?.absoluteString.contains("/api/messages/ack") == true)
  }

  @MainActor
  func testManualModeDoesNotAutoSendReadReceiptsButExplicitMarkStillWorks() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "manual mode")

    _ = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    let messageId = fixture.viewModel.messages[0].id
    await fixture.viewModel.beginVisibleConversationTracking()

    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertNil(fixture.viewModel.messages[0].readAt)

    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: false)
    try await fixture.viewModel.markAsRead(messageId: messageId)

    XCTAssertNotNil(fixture.viewModel.messages[0].readAt)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)
    XCTAssertTrue(fixture.networkClient.requests[1].url?.absoluteString.contains("/api/prekeys/get") == true)
    XCTAssertTrue(fixture.networkClient.requests[2].url?.absoluteString.contains("/api/prekeys/self") == true)
    XCTAssertTrue(fixture.networkClient.requests[3].url?.absoluteString.contains("/api/messages/send") == true)
  }

  @MainActor
  func testManualReadReceiptRetriesAfterTransientTransportFailure() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "retry receipt")

    _ = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    let messageId = fixture.viewModel.messages[0].id
    await fixture.viewModel.beginVisibleConversationTracking()

    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertNil(fixture.viewModel.messages[0].readAt)

    try await fixture.viewModel.markAsRead(messageId: messageId)

    XCTAssertNotNil(fixture.viewModel.messages[0].readAt)
    XCTAssertEqual(fixture.networkClient.requests.count, 2)
    XCTAssertTrue(fixture.networkClient.requests[1].url?.absoluteString.contains("/api/prekeys/get") == true)

    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: false)
    await fixture.viewModel.beginVisibleConversationTracking()

    XCTAssertEqual(fixture.networkClient.requests.count, 5)
    XCTAssertTrue(fixture.networkClient.requests[2].url?.absoluteString.contains("/api/prekeys/get") == true)
    XCTAssertTrue(fixture.networkClient.requests[3].url?.absoluteString.contains("/api/prekeys/self") == true)
    XCTAssertTrue(fixture.networkClient.requests[4].url?.absoluteString.contains("/api/messages/send") == true)
  }

  @MainActor
  func testVisibleConversationTrackingOnlyUpdatesLocalPushSuppressMarker() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)

    await fixture.viewModel.beginVisibleConversationTracking()
    XCTAssertEqual(
      fixture.container.pushNotificationService.visibleConversationPeerUserId(),
      fixture.peerUserId
    )

    await fixture.viewModel.endVisibleConversationTracking()
    XCTAssertNil(fixture.container.pushNotificationService.visibleConversationPeerUserId())
  }

  @MainActor
  func testRemoteNotificationSyncReloadsPersistedBackgroundMessagesIntoActiveConversation() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    let pushProcessor = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingBlob(fixture: fixture, text: "background delivered")

    _ = try await pushProcessor.ingestMailboxBlobs([blob], source: .backgroundPush)
    NotificationCenter.default.post(name: .didProcessRemoteNotificationSync, object: nil)
    await flushMainQueue()

    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertEqual(fixture.viewModel.messages[0].id, blob.messageId.lowercased())
    XCTAssertEqual(fixture.viewModel.messages[0].content, "background delivered")
  }

  @MainActor
  func testRemoteNotificationSyncReloadsPersistedReadReceiptsIntoActiveConversation() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendText(plaintext: "awaiting push receipt")
    let pushProcessor = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(fixture: fixture, targetMessageIds: [sent.id])

    _ = try await pushProcessor.ingestMailboxBlobs([readBlob], source: .backgroundPush)
    NotificationCenter.default.post(name: .didProcessRemoteNotificationSync, object: nil)
    await flushMainQueue()

    let updated = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.id == sent.id }))
    XCTAssertNotNil(updated.readAt)
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: updated), "✓✓")
  }

  @MainActor
  func testDeferredReadReceiptSurvivesAcrossBackgroundPushProcessors() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    let targetMessageId = UUID().uuidString

    let firstPushProcessor = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(fixture: fixture, targetMessageIds: [targetMessageId])
    _ = try await firstPushProcessor.ingestMailboxBlobs([readBlob], source: .backgroundPush)

    let secondPushProcessor = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let delayedTargetBlob = try makeIncomingBlob(
      fixture: fixture,
      text: "arrived from push later",
      messageId: targetMessageId
    )
    _ = try await secondPushProcessor.ingestMailboxBlobs([delayedTargetBlob], source: .backgroundPush)

    NotificationCenter.default.post(name: .didProcessRemoteNotificationSync, object: nil)
    await flushMainQueue()

    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertEqual(fixture.viewModel.messages[0].id, targetMessageId.lowercased())
    XCTAssertNotNil(fixture.viewModel.messages[0].readAt)
  }

  @MainActor
  func testSendTextMarksPartialFailureWhenDeliveryResultsAreIncomplete() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "unavailable",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": 0,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendText(plaintext: "partial")

    XCTAssertEqual(sent.transportState, .partialFailure)
    XCTAssertNil(sent.deliveredAt)
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: sent), "!")
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .partialFailure)
  }

  @MainActor
  func testSendTextFetchesBootstrapOnlyForNewPeerDevice() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let existingBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let newDeviceId = "peer-device-2"
    let newBundle = try makePeerBundle(fixture: fixture, deviceId: newDeviceId)
    let existingPeerIkDhPublic = existingBundle.deviceDhPub

    let existingSession = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.localUserId,
      localDeviceId: fixture.localDeviceId,
      peerUserHandle: fixture.peerUserId,
      peerDeviceId: existingBundle.deviceId,
      peerIkDhPublic: existingPeerIkDhPublic,
      sessionId: "existing-session-1",
      conversationId: fixture.conversation.id
    )
    try fixture.container.ratchetSessionStore.upsert(existingSession)

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([existingBundle, newBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([newBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendText(plaintext: "fanout")

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)
    XCTAssertTrue(fixture.networkClient.requests[0].url?.absoluteString.contains("/api/prekeys/get") == true)
    XCTAssertTrue(fixture.networkClient.requests[1].url?.absoluteString.contains("/api/prekeys/self") == true)
    XCTAssertTrue(fixture.networkClient.requests[2].url?.absoluteString.contains("device_id=\(newDeviceId)") == true)

    let sendPayload = try requestJSONBody(fixture.networkClient.requests[3])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    let targetDeviceIds = Set(deliveries.compactMap { $0["to_device_id"] as? String })
    XCTAssertEqual(targetDeviceIds, Set([fixture.peerDeviceId, newDeviceId]))
  }

  @MainActor
  func testSendTextFansOutEncryptedSelfCopiesToCompanionDevices() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-1")

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendText(plaintext: "mirror me")

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 5)

    let sendPayload = try requestJSONBody(fixture.networkClient.requests[4])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    XCTAssertEqual(deliveries.count, 2)

    let peerDelivery = try XCTUnwrap(deliveries.first(where: { ($0["to_user"] as? String) == fixture.peerUserId }))
    XCTAssertEqual(peerDelivery["push_kind"] as? String, PushKind.message.rawValue)

    let selfDelivery = try XCTUnwrap(deliveries.first(where: { ($0["to_user"] as? String) == fixture.localUserId }))
    XCTAssertEqual(selfDelivery["to_device_id"] as? String, "companion-device-1")
    XCTAssertEqual(selfDelivery["push_kind"] as? String, PushKind.message.rawValue)
  }

  @MainActor
  func testInitialCallOfferUsesVoipWakeupDeliveryMetadata() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)

    let peerDelivery = try peerDeliveryPayload(fixture: fixture, sendRequestIndex: 3)
    XCTAssertNil(peerDelivery["push_kind"] as? String)
    XCTAssertEqual(peerDelivery["wakeup_class"] as? String, WakeupClass.voipOpaque.rawValue)
  }

  @MainActor
  func testInitialCallOfferUsesVoipWakeupOnlyForPeerDelivery() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-1")

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-self-sync-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 5)

    let sendPayload = try requestJSONBody(fixture.networkClient.requests[4])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    XCTAssertEqual(deliveries.count, 2)

    let peerDelivery = try XCTUnwrap(deliveries.first(where: { ($0["to_user"] as? String) == fixture.peerUserId }))
    XCTAssertNil(peerDelivery["push_kind"] as? String)
    XCTAssertEqual(peerDelivery["wakeup_class"] as? String, WakeupClass.voipOpaque.rawValue)

    let selfDelivery = try XCTUnwrap(deliveries.first(where: { ($0["to_user"] as? String) == fixture.localUserId }))
    XCTAssertEqual(selfDelivery["to_device_id"] as? String, "companion-device-call-1")
    XCTAssertEqual(selfDelivery["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(selfDelivery["wakeup_class"] as? String)
  }

  @MainActor
  func testInitialCallOfferSendsPeerInviteWhenSelfPrekeyInventoryFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"self prekey inventory unavailable"}"#.utf8)
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-self-inventory-failed-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 1)

    let sendRequests = fixture.networkClient.requests.filter { request in
      request.url?.path.hasSuffix("/api/messages/send") == true
    }
    let sendRequest = try XCTUnwrap(sendRequests.first)
    let sendPayload = try requestJSONBody(sendRequest)
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []

    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?["to_user"] as? String, fixture.peerUserId)
    XCTAssertNil(deliveries.first?["push_kind"] as? String)
    XCTAssertEqual(deliveries.first?["wakeup_class"] as? String, WakeupClass.voipOpaque.rawValue)
  }

  @MainActor
  func testInitialCallOfferSendsPeerInviteWhenSelfCompanionBootstrapFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfDeviceId = "companion-device-call-bootstrap-failed-1"
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: selfDeviceId)
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self"),
        request.url?.absoluteString.contains("device_id=\(selfDeviceId)") == true
      {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"self companion prekey unavailable"}"#.utf8)
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-self-bootstrap-failed-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 1)

    let sendRequest = try XCTUnwrap(
      fixture.networkClient.requests.first { $0.url?.path.hasSuffix("/api/messages/send") == true }
    )
    let sendPayload = try requestJSONBody(sendRequest)
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []

    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?["to_user"] as? String, fixture.peerUserId)
    XCTAssertNil(deliveries.first?["push_kind"] as? String)
    XCTAssertEqual(deliveries.first?["wakeup_class"] as? String, WakeupClass.voipOpaque.rawValue)
  }

  @MainActor
  func testCallAnswerSendsPeerSignalWhenSelfPrekeyInventoryFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"self prekey inventory unavailable"}"#.utf8)
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callAnswer.rawValue,
      payloadObject: makeCallAnswerPayload(callId: "call-answer-self-inventory-failed-1"),
      errorMessage: "Call answer delivery incomplete for peer devices"
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 1)

    let sendRequest = try XCTUnwrap(
      fixture.networkClient.requests.first { $0.url?.path.hasSuffix("/api/messages/send") == true }
    )
    let sendPayload = try requestJSONBody(sendRequest)
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []

    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?["to_user"] as? String, fixture.peerUserId)
    XCTAssertEqual(deliveries.first?["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(deliveries.first?["wakeup_class"] as? String)
  }

  @MainActor
  func testCallIceCandidateSendsPeerSignalWhenSelfCompanionBootstrapFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfDeviceId = "companion-device-ice-bootstrap-failed-1"
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: selfDeviceId)
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self"),
        request.url?.absoluteString.contains("device_id=\(selfDeviceId)") == true
      {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"self companion prekey unavailable"}"#.utf8)
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callIceCandidate.rawValue,
      payloadObject: makeCallICECandidatePayload(callId: "call-ice-self-bootstrap-failed-1"),
      errorMessage: "ICE candidate delivery incomplete for peer devices"
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 1)

    let sendRequest = try XCTUnwrap(
      fixture.networkClient.requests.first { $0.url?.path.hasSuffix("/api/messages/send") == true }
    )
    let sendPayload = try requestJSONBody(sendRequest)
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []

    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?["to_user"] as? String, fixture.peerUserId)
    XCTAssertEqual(deliveries.first?["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(deliveries.first?["wakeup_class"] as? String)
  }

  @MainActor
  func testTextSendStillFailsWhenSelfPrekeyInventoryFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"self prekey inventory unavailable"}"#.utf8)
        )
      }

      return nil
    }

    do {
      _ = try await fixture.viewModel.sendText(plaintext: "strict self sync")
      XCTFail("Non-call messages must not ignore self-copy preparation failures")
    } catch let error as APIError {
      XCTAssertEqual(error, .server(statusCode: 503, message: "self prekey inventory unavailable"))
    }

    XCTAssertFalse(
      fixture.networkClient.requests.contains { $0.url?.path.hasSuffix("/api/messages/send") == true }
    )
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .failed)
  }

  func testDefaultInitialCallOfferRetryPolicyStartsWithImmediateRetry() {
    XCTAssertEqual(
      ConversationViewModel.defaultInitialCallOfferPeerDeliveryRetryDelaysSeconds,
      [0, 0.4, 1.2, 2.4]
    )
  }

  @MainActor
  func testInitialCallOfferRetriesPeerDeliveryAndSucceedsAfterTransientUnavailable() async throws {
    let fixture = try makeFixture(
      manualReadReceipts: false,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0, 0]
    )
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-retry-1")
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        let isPeerDelivery: Bool = (delivery["to_user"] as? String) == fixture.peerUserId
        let status: String = sendAttemptCount == 1 && isPeerDelivery ? "unavailable" : "queued_local"
        return [
          "delivery_id": deliveryId,
          "status": status,
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] != "unavailable" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-transient-retry-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 2)
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .accepted)
  }

  @MainActor
  func testInitialCallOfferRetryReusesTargetBoundTranscriptMetadata() async throws {
    let sender = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@alice:example.org",
      peerUserId: "@bob:example.org",
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0]
    )
    let senderDeviceIdentity = try XCTUnwrap(
      sender.container.keyMaterialStore.deviceIdentity(for: sender.localUserId)
    )
    let senderBundle = try makePublishedBundle(
      container: sender.container,
      userHandle: sender.localUserId,
      identity: sender.localIdentity,
      deviceIdentity: senderDeviceIdentity
    )
    let receiver = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@bob:example.org",
      peerUserId: "@alice:example.org",
      peekBundleResolver: { requestedUser, requestedDeviceId in
        guard requestedUser == sender.localUserId, requestedDeviceId == sender.localDeviceId else {
          return nil
        }

        return senderBundle
      }
    )
    let receiverDeviceIdentity = try XCTUnwrap(
      receiver.container.keyMaterialStore.deviceIdentity(for: receiver.localUserId)
    )
    let receiverBundle = try makePublishedBundle(
      container: receiver.container,
      userHandle: receiver.localUserId,
      identity: receiver.localIdentity,
      deviceIdentity: receiverDeviceIdentity
    )
    var sendAttemptCount: Int = 0

    sender.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([receiverBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": sendAttemptCount == 1 ? "unavailable" : "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": sendAttemptCount == 1 ? 0 : results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await sender.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-idempotent-retry-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 2)

    let sendRequests = sender.networkClient.requests.filter { request in
      request.url?.path.hasSuffix("/api/messages/send") == true
    }
    XCTAssertEqual(sendRequests.count, 2)

    func receiverBlob(from request: URLRequest) throws -> FederatedMailboxBlob {
      let payload = try requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let receiverDelivery = try XCTUnwrap(deliveries.first { delivery in
        (delivery["to_user"] as? String) == receiver.localUserId
      })
      let ciphertextBlob = try XCTUnwrap(receiverDelivery["ciphertext_blob"] as? String)
      let messageId = try XCTUnwrap(receiverDelivery["message_id"] as? String)
      let deliveryId = try XCTUnwrap(receiverDelivery["delivery_id"] as? String)
      return FederatedMailboxBlob(
        id: deliveryId.lowercased(),
        ownerAccountId: "acc-receiver",
        ownerDeviceId: receiver.localDeviceId,
        senderServer: "example.org",
        messageId: messageId,
        deliveryId: deliveryId,
        ciphertextBlob: ciphertextBlob,
        ttlSec: 600,
        expiresAt: Date().addingTimeInterval(600),
        ackedAt: nil,
        createdAt: Date()
      )
    }

    let firstBlob = try receiverBlob(from: sendRequests[0])
    let firstInspectionResult = try await ConversationViewModel.inspectMailboxBlob(
      container: receiver.container,
      blob: firstBlob
    )
    let firstInspection = try XCTUnwrap(firstInspectionResult)
    let firstPayload = try jsonObject(from: firstInspection.payload.body)
    receiver.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    _ = try await receiver.viewModel.ingestMailboxBlobs([firstBlob], source: .backgroundPush)

    let secondBlob = try receiverBlob(from: sendRequests[1])
    let secondInspectionResult = try await ConversationViewModel.inspectMailboxBlob(
      container: receiver.container,
      blob: secondBlob
    )
    let secondInspection = try XCTUnwrap(secondInspectionResult)
    let secondPayload = try jsonObject(from: secondInspection.payload.body)

    XCTAssertEqual((firstPayload["seq"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(firstPayload["seq"] as? NSNumber, secondPayload["seq"] as? NSNumber)
    XCTAssertEqual(firstPayload["prev_event_hash"] as? String, secondPayload["prev_event_hash"] as? String)
    XCTAssertEqual(firstPayload["transcript_hash"] as? String, secondPayload["transcript_hash"] as? String)
    XCTAssertEqual(firstPayload["sent_at"] as? String, secondPayload["sent_at"] as? String)
    XCTAssertEqual(CallSignalParser.targetDeviceId(from: firstPayload), receiver.localDeviceId)
    XCTAssertEqual(CallSignalParser.targetDeviceId(from: secondPayload), receiver.localDeviceId)
  }

  @MainActor
  func testInitialCallOfferRetriesTransientSendFailureBeforeFailingPeerDelivery() async throws {
    let fixture = try makeFixture(
      manualReadReceipts: false,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0, 0]
    )
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-send-retry-1")
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      if sendAttemptCount == 1 {
        return MockNetworkClient.QueuedResponse(
          statusCode: 503,
          body: Data(#"{"error":"transient send outage"}"#.utf8)
        )
      }

      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-transient-send-retry-1", offerKind: "initial")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sendAttemptCount, 2)
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .accepted)
  }

  @MainActor
  func testInitialCallOfferDoesNotWaitForStalePeerDeviceAfterOnePeerDeviceAccepts() async throws {
    let fixture = try makeFixture(
      manualReadReceipts: false,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0, 0]
    )
    let reachablePeerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let stalePeerDeviceId = "peer-device-stale-call-1"
    let stalePeerBundle = try makePeerBundle(fixture: fixture, deviceId: stalePeerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-stale-peer-1")
    var sendAttemptCount: Int = 0
    var peerDeliveryStatuses: [String: String] = [:]

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([reachablePeerBundle, stalePeerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String,
          let toDeviceId: String = delivery["to_device_id"] as? String
        else {
          return nil
        }

        let status: String = toDeviceId == stalePeerDeviceId ? "unavailable" : "queued_local"
        if (delivery["to_user"] as? String) == fixture.peerUserId {
          peerDeliveryStatuses[toDeviceId] = status
        }
        return [
          "delivery_id": deliveryId,
          "status": status,
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] != "unavailable" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-initial-stale-peer-device-1", offerKind: "initial")
    )

    XCTAssertEqual(sendAttemptCount, 1)
    XCTAssertEqual(sent.transportState, .partialFailure)
    XCTAssertEqual(peerDeliveryStatuses[fixture.peerDeviceId], "queued_local")
    XCTAssertEqual(peerDeliveryStatuses[stalePeerDeviceId], "unavailable")
  }

  @MainActor
  func testInitialCallOfferDoesNotRetryPermanentSendFailure() async throws {
    let fixture = try makeFixture(
      manualReadReceipts: false,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0, 0]
    )
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-permanent-failure-1")
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      return MockNetworkClient.QueuedResponse(
        statusCode: 400,
        body: Data(#"{"error":"invalid call invite"}"#.utf8)
      )
    }

    do {
      _ = try await fixture.viewModel.sendSignalingPayload(
        msgType: Message.MessageType.callOffer.rawValue,
        payloadObject: makeCallOfferPayload(callId: "call-initial-permanent-failure-1", offerKind: "initial")
      )
      XCTFail("Permanent call invite send failure must not be retried")
    } catch let error as APIError {
      XCTAssertEqual(error, .server(statusCode: 400, message: "invalid call invite"))
    }

    XCTAssertEqual(sendAttemptCount, 1)
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .failed)
    XCTAssertEqual(fixture.viewModel.messages.first?.transportErrorDetail, "invalid call invite")
  }

  @MainActor
  func testInitialCallOfferFailsWhenPeerDeliveryIsUnavailableButSelfCopySucceeds() async throws {
    let fixture = try makeFixture(
      manualReadReceipts: false,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: [0, 0]
    )
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-call-failure-1")
    var sendAttemptCount: Int = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([selfBundle])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        let status: String = (delivery["to_user"] as? String) == fixture.peerUserId
          ? "unavailable"
          : "queued_local"
        return [
          "delivery_id": deliveryId,
          "status": status,
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] != "unavailable" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    do {
      _ = try await fixture.viewModel.sendSignalingPayload(
        msgType: Message.MessageType.callOffer.rawValue,
        payloadObject: makeCallOfferPayload(callId: "call-initial-peer-missing-1", offerKind: "initial")
      )
      XCTFail("Initial call offer must fail when no peer device accepted delivery")
    } catch let error as APIError {
      XCTAssertEqual(
        error,
        .server(statusCode: 503, message: "Delivery incomplete for \(fixture.peerDeviceId):unavailable")
      )
    }

    let localMessage = try XCTUnwrap(fixture.viewModel.messages.first)
    XCTAssertEqual(localMessage.transportState, .failed)
    XCTAssertEqual(localMessage.transportErrorDetail, "Delivery incomplete for \(fixture.peerDeviceId):unavailable")

    let sendPayload = try requestJSONBody(fixture.networkClient.requests[4])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    XCTAssertEqual(deliveries.count, 2)
    XCTAssertEqual(sendAttemptCount, 3)
  }

  @MainActor
  func testIceRestartCallOfferDoesNotTriggerVoipWakeupDeliveryMetadata() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(callId: "call-reconnect-1", offerKind: "ice_restart")
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)

    let peerDelivery = try peerDeliveryPayload(fixture: fixture, sendRequestIndex: 3)
    XCTAssertEqual(peerDelivery["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(peerDelivery["wakeup_class"] as? String)
  }

  @MainActor
  func testCallMediaStateDoesNotTriggerVoipWakeupDeliveryMetadata() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callMediaState.rawValue,
      payloadObject: [
        "call_id": "call-media-state-push-1",
        "microphone_enabled": false,
        "camera_enabled": true,
      ]
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(fixture.networkClient.requests.count, 4)

    let peerDelivery = try peerDeliveryPayload(fixture: fixture, sendRequestIndex: 3)
    XCTAssertEqual(peerDelivery["push_kind"] as? String, PushKind.message.rawValue)
    XCTAssertNil(peerDelivery["wakeup_class"] as? String)
  }

  @MainActor
  func testCallMediaStateIsProtocolOnlyAndNotUserVisible() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callMediaState.rawValue,
      payloadObject: [
        "call_id": "call-media-state-visible-1",
        "microphone_enabled": false,
        "camera_enabled": true,
      ]
    )

    XCTAssertEqual(fixture.viewModel.messages.map(\.id), [sent.id])
    XCTAssertEqual(sent.type, .callMediaState)
    XCTAssertTrue(fixture.viewModel.visibleMessages().isEmpty)
    XCTAssertNil(fixture.viewModel.replyPreviewText(messageId: sent.id))

    let requestCountBeforeManualActions = fixture.networkClient.requests.count
    try await fixture.viewModel.pinMessage(messageId: sent.id)
    try await fixture.viewModel.toggleReaction(messageId: sent.id, emoji: "👍")

    XCTAssertTrue(fixture.viewModel.visiblePinnedMessages().isEmpty)
    let reactions = try await fixture.viewModel.listReactions(messageId: sent.id)
    XCTAssertTrue(reactions.isEmpty)
    XCTAssertEqual(fixture.networkClient.requests.count, requestCountBeforeManualActions)

    do {
      _ = try await fixture.viewModel.sendText(plaintext: "reply to protocol state", replyToMessageId: sent.id)
      XCTFail("Expected protocol-only call state to be rejected as a reply target")
    } catch let error as APIError {
      guard case .server(let statusCode, let message) = error else {
        XCTFail("Unexpected API error: \(error)")
        return
      }
      XCTAssertEqual(statusCode, 400)
      XCTAssertEqual(message, "Reply target is unavailable")
    }
  }

  @MainActor
  func testCallSessionAppliesRemoteMediaStateToRecoveryExpectations() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-remote-media-state-1")

    XCTAssertEqual(viewModel.remoteMediaStateForTesting.microphone, true)
    XCTAssertEqual(viewModel.remoteMediaStateForTesting.camera, true)

    viewModel.applyRemoteMediaStateForTesting(
      CallMediaStateSignal(
        callId: "call-remote-media-state-1",
        isMicrophoneEnabled: false,
        isCameraEnabled: nil
      )
    )

    XCTAssertEqual(viewModel.remoteMediaStateForTesting.microphone, false)
    XCTAssertEqual(viewModel.remoteMediaStateForTesting.camera, true)

    viewModel.applyRemoteMediaStateForTesting(
      CallMediaStateSignal(
        callId: "call-remote-media-state-1",
        isMicrophoneEnabled: true,
        isCameraEnabled: false
      )
    )

    XCTAssertEqual(viewModel.remoteMediaStateForTesting.microphone, true)
    XCTAssertEqual(viewModel.remoteMediaStateForTesting.camera, false)
  }

  @MainActor
  func testRecoverableDisconnectRefreshesRelayAndSendsIceRestartOffer() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-recovery-ice-restart-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let restartSDP = sdpWithDTLSFingerprint()
    let engine = SpyCallMediaRecoveryEngine(
      restartOffer: CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: nil,
        type: "offer",
        sdp: restartSDP,
        dtlsFingerprint: testDTLSFingerprint()
      )
    )
    fixture.networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "ice_servers": [
          {
            "urls": "turn:relay.example.org:3478?transport=udp",
            "username": "turn-user",
            "credential": "turn-pass"
          }
        ],
        "turn_credentials": {
          "username": "fallback-user",
          "credential": "fallback-pass",
          "ttl": 600
        },
        "ice_transport_policy": "relay"
      }
      """
    )
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    await viewModel.handleRecoverableDisconnectForTesting(
      decision: CallMediaRecoveryDecision(
        status: .reconnecting,
        shouldRefreshRelay: true,
        shouldSendRestartOffer: true
      ),
      mediaEngine: engine
    )

    XCTAssertEqual(viewModel.state, .reconnecting)
    XCTAssertEqual(viewModel.statusText, "Reconnect offer отправлен")
    XCTAssertEqual(engine.updatedRelayURLSets, [["turn:relay.example.org:3478?transport=udp"]])
    XCTAssertEqual(engine.restartCallIds, [callId])

    let callOfferMessage = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.type == .callOffer }))
    let payload = try jsonObject(from: callOfferMessage.content)
    let offer = try XCTUnwrap(payload["offer"] as? [String: Any])
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(payload["offer_kind"] as? String, "ice_restart")
    XCTAssertEqual(payload["dtls_fingerprint"] as? String, testDTLSFingerprint())
    XCTAssertEqual(offer["type"] as? String, "offer")
    XCTAssertEqual(offer["sdp"] as? String, restartSDP)
    let offerId = try XCTUnwrap(offer["offer_id"] as? String)
    XCTAssertNotNil(UUID(uuidString: offerId))
  }

  @MainActor
  func testUnansweredInitialOfferRollsBackAndSendsReconnectOffer() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-unanswered-initial-recovery-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.unansweredInitialOfferRecoveryDelaysOverrideForTesting = [0]
    viewModel.unansweredInitialOfferFailureTimeoutOverrideForTesting = 30
    let restartSDP = sdpWithDTLSFingerprint()
    let engine = SpyCallMediaRecoveryEngine(
      restartOffer: CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: nil,
        type: "offer",
        sdp: restartSDP,
        dtlsFingerprint: testDTLSFingerprint()
      )
    )
    fixture.networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "ice_servers": [
          {
            "urls": "turn:relay.example.org:3478?transport=udp",
            "username": "turn-user",
            "credential": "turn-pass"
          }
        ],
        "turn_credentials": {
          "username": "fallback-user",
          "credential": "fallback-pass",
          "ttl": 600
        },
        "ice_transport_policy": "relay"
      }
      """
    )
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)
    let startedAt = Date(timeIntervalSince1970: 7_000)

    viewModel.markWaitingForPeerForTesting(startedAt: startedAt)
    await viewModel.recoverUnansweredInitialOfferForTesting(
      mediaEngine: engine,
      now: startedAt.addingTimeInterval(1)
    )

    XCTAssertEqual(viewModel.state, .waitingForPeer)
    XCTAssertEqual(viewModel.statusText, "Вызов отправлен повторно")
    XCTAssertEqual(viewModel.unansweredOfferRecoveryAttemptCountForTesting, 1)
    XCTAssertEqual(engine.rollbackCallCount, 1)
    XCTAssertEqual(engine.updatedRelayURLSets, [["turn:relay.example.org:3478?transport=udp"]])
    XCTAssertEqual(engine.restartCallIds, [callId])

    let callOfferMessage = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.type == .callOffer }))
    let payload = try jsonObject(from: callOfferMessage.content)
    let offer = try XCTUnwrap(payload["offer"] as? [String: Any])
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(payload["offer_kind"] as? String, "ice_restart")
    XCTAssertEqual(payload["dtls_fingerprint"] as? String, testDTLSFingerprint())
    XCTAssertEqual(offer["type"] as? String, "offer")
    XCTAssertEqual(offer["sdp"] as? String, restartSDP)
    let offerId = try XCTUnwrap(offer["offer_id"] as? String)
    XCTAssertNotNil(UUID(uuidString: offerId))
  }

  @MainActor
  func testRecoverableDisconnectRetriesReconnectOfferAfterPeerDeliveryFailure() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-recovery-ice-restart-peer-fail-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.reconnectOfferPeerDeliveryRetryDelaysOverrideForTesting = [0]
    let restartSDP = sdpWithDTLSFingerprint()
    let engine = SpyCallMediaRecoveryEngine(
      restartOffer: CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: nil,
        type: "offer",
        sdp: restartSDP,
        dtlsFingerprint: testDTLSFingerprint()
      )
    )
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount: Int = 0
    fixture.networkClient.enqueue(
      statusCode: 200,
      json: """
      {
        "ice_servers": [
          {
            "urls": "turn:relay.example.org:3478?transport=udp",
            "username": "turn-user",
            "credential": "turn-pass"
          }
        ],
        "turn_credentials": {
          "username": "fallback-user",
          "credential": "fallback-pass",
          "ttl": 600
        },
        "ice_transport_policy": "relay"
      }
      """
    )
    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        let isPeerDelivery: Bool = (delivery["to_user"] as? String) == fixture.peerUserId
        let status: String = sendAttemptCount == 1 && isPeerDelivery ? "unavailable" : "queued_local"
        return [
          "delivery_id": deliveryId,
          "status": status,
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] != "unavailable" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    await viewModel.handleRecoverableDisconnectForTesting(
      decision: CallMediaRecoveryDecision(
        status: .reconnecting,
        shouldRefreshRelay: true,
        shouldSendRestartOffer: true
      ),
      mediaEngine: engine
    )

    XCTAssertEqual(viewModel.state, .reconnecting)
    XCTAssertEqual(viewModel.statusText, "Reconnect offer ожидает повторной доставки")
    XCTAssertEqual(viewModel.pendingReconnectOfferRetryCountForTesting, 1)
    XCTAssertTrue(viewModel.hasPendingLocalOfferAnswerForTesting)
    XCTAssertEqual(engine.updatedRelayURLSets, [["turn:relay.example.org:3478?transport=udp"]])
    XCTAssertEqual(engine.restartCallIds, [callId])
    XCTAssertEqual(
      fixture.viewModel.messages.first(where: { $0.type == .callOffer })?.transportState,
      .failed
    )

    await viewModel.flushPendingReconnectOfferForTesting()

    XCTAssertEqual(viewModel.state, .reconnecting)
    XCTAssertEqual(viewModel.statusText, "Reconnect offer отправлен")
    XCTAssertEqual(viewModel.pendingReconnectOfferRetryCountForTesting, 0)
    XCTAssertTrue(viewModel.hasPendingLocalOfferAnswerForTesting)
    XCTAssertEqual(engine.restartCallIds, [callId])
    XCTAssertEqual(sendAttemptCount, 2)

    let callOfferMessages = fixture.viewModel.messages.filter { $0.type == .callOffer }
    XCTAssertEqual(callOfferMessages.count, 2)
    let retryOfferIds: [String] = try callOfferMessages.map { message in
      let retryPayload = try jsonObject(from: message.content)
      let retryOffer = try XCTUnwrap(retryPayload["offer"] as? [String: Any])
      return try XCTUnwrap(retryOffer["offer_id"] as? String)
    }
    XCTAssertEqual(Set(retryOfferIds).count, 1)
    let acceptedCallOffer = try XCTUnwrap(callOfferMessages.first(where: { $0.transportState == .accepted }))
    let payload = try jsonObject(from: acceptedCallOffer.content)
    let offer = try XCTUnwrap(payload["offer"] as? [String: Any])
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(payload["offer_kind"] as? String, "ice_restart")
    XCTAssertEqual(payload["dtls_fingerprint"] as? String, testDTLSFingerprint())
    XCTAssertEqual(offer["type"] as? String, "offer")
    XCTAssertEqual(offer["sdp"] as? String, restartSDP)
    XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(offer["offer_id"] as? String)))
  }

  @MainActor
  func testFailedLocalIceCandidateSendIsRetriedAfterNetworkRecovery() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-local-ice-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let candidate = CallICECandidateSignal(
      callId: callId,
      sdp: "candidate:31 1 udp 1677729535 203.0.113.31 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 0
    )

    await viewModel.sendICECandidateForTesting(candidate)

    XCTAssertEqual(viewModel.pendingLocalICECandidateCountForTesting, 1)
    XCTAssertEqual(fixture.viewModel.messages.filter { $0.type == .callIceCandidate }.count, 1)
    XCTAssertEqual(fixture.viewModel.messages.last?.transportState, .failed)

    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)
    await viewModel.flushPendingLocalICECandidatesForTesting()

    XCTAssertEqual(viewModel.pendingLocalICECandidateCountForTesting, 0)
    let candidateMessages = fixture.viewModel.messages.filter { $0.type == .callIceCandidate }
    XCTAssertEqual(candidateMessages.count, 2)
    let acceptedCandidateMessage = try XCTUnwrap(
      candidateMessages.first(where: { $0.transportState == .accepted })
    )

    let payload = try jsonObject(from: acceptedCandidateMessage.content)
    let candidatePayload = try XCTUnwrap(payload["candidate"] as? [String: Any])
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(candidatePayload["candidate"] as? String, candidate.sdp)
    XCTAssertEqual(candidatePayload["sdpMid"] as? String, "audio")
    XCTAssertEqual(candidatePayload["sdpMLineIndex"] as? Int, 0)
  }

  @MainActor
  func testPartialLocalIceCandidatePeerDeliveryIsRetried() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-local-ice-partial-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let candidate = CallICECandidateSignal(
      callId: callId,
      sdp: "candidate:32 1 udp 1677729535 203.0.113.32 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 0
    )

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "unavailable",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": 0,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    await viewModel.sendICECandidateForTesting(candidate)

    XCTAssertEqual(viewModel.pendingLocalICECandidateCountForTesting, 1)
    XCTAssertEqual(
      fixture.viewModel.messages.first(where: { $0.type == .callIceCandidate })?.transportState,
      .failed
    )

    try enqueueSuccessfulExistingSessionSendResponses(fixture: fixture)
    await viewModel.flushPendingLocalICECandidatesForTesting()

    XCTAssertEqual(viewModel.pendingLocalICECandidateCountForTesting, 0)
    XCTAssertEqual(
      fixture.viewModel.messages.filter { $0.type == .callIceCandidate && $0.transportState == .accepted }.count,
      1
    )
  }

  @MainActor
  func testRequiredPeerSignalingDeliveryAllowsSelfCopyFailureAfterPeerAccepts() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let selfBundle = try makeSelfBundle(fixture: fixture, deviceId: "companion-device-required-peer-1")

    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([selfBundle]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        let status: String = (delivery["to_user"] as? String) == fixture.peerUserId
          ? "queued_local"
          : "unavailable"
        return [
          "delivery_id": deliveryId,
          "status": status,
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] == "queued_local" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await fixture.viewModel.sendSignalingPayloadRequiringPeerDelivery(
      msgType: Message.MessageType.callAnswer.rawValue,
      payloadObject: CallSignalEnvelope.payload(
        callId: "call-required-peer-self-copy-1",
        values: [
          "answer": [
            "type": "answer",
            "sdp": sdpWithDTLSFingerprint(),
          ],
        ]
      ),
      errorMessage: "answer peer delivery required"
    )

    XCTAssertEqual(sent.transportState, .partialFailure)
    XCTAssertEqual(fixture.viewModel.messages.first?.transportState, .partialFailure)
  }

  @MainActor
  func testTransientRemoteIceCandidateApplyFailureIsRetried() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-remote-ice-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let candidateSDP = "candidate:41 1 udp 1677729535 203.0.113.41 3478 typ relay generation 0"
    let payload = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: fixture.localDeviceId,
      values: [
        "candidate": [
          "candidate": candidateSDP,
          "sdpMid": "audio",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    let message = makeCallSignalMessage(
      fixture: fixture,
      id: "remote-ice-retry-message-1",
      type: .callIceCandidate,
      payload: payload,
      createdAt: Date()
    )
    let engine = FlakyRemoteICECandidateEngine(failuresBeforeSuccess: 1)

    await viewModel.handleRemoteICECandidateForTesting(message: message, mediaEngine: engine)

    XCTAssertFalse(viewModel.hasProcessedMessageForTesting(message.id))
    XCTAssertEqual(viewModel.remoteICECandidateRetryCountForTesting(messageId: message.id), 1)
    XCTAssertEqual(engine.queuedCandidates.map(\.sdp), [candidateSDP])

    await viewModel.handleRemoteICECandidateForTesting(message: message, mediaEngine: engine)

    XCTAssertTrue(viewModel.hasProcessedMessageForTesting(message.id))
    XCTAssertEqual(viewModel.remoteICECandidateRetryCountForTesting(messageId: message.id), 0)
    XCTAssertEqual(engine.queuedCandidates.map(\.sdp), [candidateSDP, candidateSDP])
  }

  @MainActor
  func testNonRelayRemoteIceCandidateIsProcessedWithoutRetry() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-remote-ice-host-drop-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let payload = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: fixture.localDeviceId,
      values: [
        "candidate": [
          "candidate": "candidate:42 1 udp 2122260223 192.168.1.42 5000 typ host generation 0",
          "sdpMid": "audio",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    let message = makeCallSignalMessage(
      fixture: fixture,
      id: "remote-ice-host-message-1",
      type: .callIceCandidate,
      payload: payload,
      createdAt: Date()
    )
    let engine = FlakyRemoteICECandidateEngine(failuresBeforeSuccess: 0)

    await viewModel.handleRemoteICECandidateForTesting(message: message, mediaEngine: engine)

    XCTAssertTrue(viewModel.hasProcessedMessageForTesting(message.id))
    XCTAssertEqual(viewModel.remoteICECandidateRetryCountForTesting(messageId: message.id), 0)
    XCTAssertTrue(engine.queuedCandidates.isEmpty)
  }

  @MainActor
  func testIncomingCallDescriptorIgnoresIceRestartOffers() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let initialMessage = try makeCallOfferMessage(
      fixture: fixture,
      callId: "call-initial-1",
      offerKind: "initial"
    )
    let restartMessage = try makeCallOfferMessage(
      fixture: fixture,
      callId: "call-reconnect-1",
      offerKind: "ice_restart"
    )

    XCTAssertNotNil(
      CallSignalParser.incomingCallDescriptor(
        from: initialMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: restartMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testCallOfferKindHelpersDistinguishInitialAndReconnectOffers() throws {
    let initialPayload = makeCallOfferPayload(callId: "call-offer-kind-initial-1", offerKind: "initial")
    let reconnectPayload = makeCallOfferPayload(callId: "call-offer-kind-reconnect-1", offerKind: "ice_restart")
    var camelCaseReconnectPayload = reconnectPayload
    camelCaseReconnectPayload.removeValue(forKey: "offer_kind")
    camelCaseReconnectPayload["offerKind"] = "ICE_RESTART"

    XCTAssertTrue(CallSignalParser.isInitialOffer(initialPayload))
    XCTAssertFalse(CallSignalParser.isReconnectOffer(initialPayload))
    XCTAssertFalse(CallSignalParser.isInitialOffer(reconnectPayload))
    XCTAssertTrue(CallSignalParser.isReconnectOffer(reconnectPayload))
    XCTAssertTrue(CallSignalParser.isReconnectOffer(camelCaseReconnectPayload))
  }

  func testCallRenegotiationStateAcceptsOnlyIceRestartRemoteOffers() {
    var state = CallRenegotiationState()
    let initialPayload = makeCallOfferPayload(callId: "call-renegotiation-initial-1", offerKind: "initial")
    let reconnectPayload = makeCallOfferPayload(callId: "call-renegotiation-reconnect-1", offerKind: "ice_restart")
    let reconnectSDP = "v=0\r\na=fingerprint:\(testDTLSFingerprint())\r\n"

    XCTAssertFalse(state.shouldApplyRemoteReconnectOffer(payload: initialPayload, sdp: reconnectSDP))
    XCTAssertTrue(state.shouldApplyRemoteReconnectOffer(payload: reconnectPayload, sdp: reconnectSDP))

    state.markRemoteOfferApplied(sdp: reconnectSDP)

    XCTAssertFalse(state.shouldApplyRemoteReconnectOffer(payload: reconnectPayload, sdp: reconnectSDP))
  }

  func testCallRenegotiationStateResolvesCompetingIceRestartOffersDeterministically() {
    let reconnectPayload = makeCallOfferPayload(callId: "call-renegotiation-glare-1", offerKind: "ice_restart")
    let reconnectSDP = "v=0\r\na=fingerprint:\(testDTLSFingerprint())\r\n"
    var impolitePeerState = CallRenegotiationState()
    var politePeerState = CallRenegotiationState()

    impolitePeerState.markLocalOfferSent(offerId: "impolite-offer-1")
    politePeerState.markLocalOfferSent(offerId: "polite-offer-1")

    XCTAssertEqual(
      impolitePeerState.remoteReconnectOfferDisposition(
        payload: reconnectPayload,
        sdp: reconnectSDP,
        localUserId: "@alice:example.org",
        remoteUserId: "@bob:example.org"
      ),
      .ignore
    )
    XCTAssertEqual(
      politePeerState.remoteReconnectOfferDisposition(
        payload: reconnectPayload,
        sdp: reconnectSDP,
        localUserId: "@bob:example.org",
        remoteUserId: "@alice:example.org"
      ),
      .rollbackLocalOfferAndApply
    )

    politePeerState.markLocalOfferRolledBack()
    XCTAssertFalse(politePeerState.hasPendingLocalOfferAnswer)
    politePeerState.markRemoteOfferApplied(sdp: reconnectSDP)
    XCTAssertFalse(politePeerState.hasPendingLocalOfferAnswer)
  }

  func testCallRenegotiationStateAppliesAnswerOnlyAfterLocalOfferAndClearsPending() {
    var state = CallRenegotiationState()

    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(sdp: "answer-sdp-1", answerToOfferId: "offer-1")
    )

    state.markLocalOfferSent(offerId: "offer-1")
    XCTAssertTrue(state.hasPendingLocalOfferAnswer)
    XCTAssertTrue(
      state.shouldApplyRemoteAnswer(sdp: "answer-sdp-1", answerToOfferId: "offer-1")
    )
    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(sdp: "answer-sdp-1", answerToOfferId: "different-offer")
    )

    state.markRemoteAnswerApplied(sdp: "answer-sdp-1", answerToOfferId: "offer-1")
    XCTAssertFalse(state.hasPendingLocalOfferAnswer)
    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(sdp: "answer-sdp-1", answerToOfferId: "offer-1")
    )

    state.markLocalOfferSent(offerId: "offer-2")
    XCTAssertTrue(
      state.shouldApplyRemoteAnswer(sdp: "answer-sdp-1", answerToOfferId: "offer-2")
    )
  }

  func testCallRenegotiationStateRejectsLateInitialAnswerAfterIceRestart() {
    var state = CallRenegotiationState()

    state.markLocalOfferSent(offerId: "initial-offer")
    state.markLocalOfferRolledBack()
    state.markLocalOfferSent(offerId: "ice-restart-offer")

    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(
        sdp: "late-initial-answer-sdp",
        answerToOfferId: "initial-offer"
      )
    )
    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(
        sdp: "uncorrelated-legacy-answer-sdp",
        answerToOfferId: nil
      )
    )
    XCTAssertTrue(
      state.shouldApplyRemoteAnswer(
        sdp: "current-restart-answer-sdp",
        answerToOfferId: "ice-restart-offer"
      )
    )
  }

  func testCallRenegotiationStateAllowsLegacyAnswerOnlyForFirstLocalOffer() {
    var state = CallRenegotiationState()

    state.markLocalOfferSent(offerId: "first-offer")
    state.markLocalOfferSent(offerId: "first-offer")

    XCTAssertEqual(state.localOfferGeneration, 1)
    XCTAssertTrue(
      state.shouldApplyRemoteAnswer(sdp: "legacy-initial-answer-sdp", answerToOfferId: nil)
    )

    state.markLocalOfferRolledBack()
    state.markLocalOfferSent(offerId: "replacement-offer")

    XCTAssertEqual(state.localOfferGeneration, 2)
    XCTAssertFalse(
      state.shouldApplyRemoteAnswer(sdp: "legacy-replacement-answer-sdp", answerToOfferId: nil)
    )
  }

  func testSessionDescriptionCorrelationIdentifiersSurviveJSONEncodingAndParsing() throws {
    let callId = "call-description-correlation-roundtrip-1"
    let offerId = "offer-generation-1"
    let offerPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
          "offer_id": offerId,
        ],
      ]
    )
    let encodedOffer = try JSONSerialization.data(withJSONObject: offerPayload, options: [.sortedKeys])
    let decodedOffer = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encodedOffer) as? [String: Any]
    )
    let parsedOffer = try XCTUnwrap(
      CallSignalParser.sessionDescription(
        from: decodedOffer,
        objectKey: "offer",
        senderId: "@peer:example.org",
        callId: callId
      )
    )

    XCTAssertEqual(parsedOffer.offerId, offerId)
    XCTAssertNil(parsedOffer.answerToOfferId)

    let answerPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: "local-device-1",
      targetDeviceId: "peer-device-1",
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "answer": [
          "type": "answer",
          "sdp": sdpWithDTLSFingerprint(),
          "answer_to_offer_id": offerId,
        ],
      ]
    )
    let encodedAnswer = try JSONSerialization.data(withJSONObject: answerPayload, options: [.sortedKeys])
    let decodedAnswer = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encodedAnswer) as? [String: Any]
    )
    let parsedAnswer = try XCTUnwrap(
      CallSignalParser.sessionDescription(
        from: decodedAnswer,
        objectKey: "answer",
        senderId: "@local:example.org",
        callId: callId
      )
    )

    XCTAssertEqual(parsedAnswer.answerToOfferId, offerId)
    XCTAssertNil(parsedAnswer.offerId)
  }

  func testSessionDescriptionParserAcceptsTopLevelCamelCaseCorrelationIdentifiers() throws {
    let callId = "call-description-correlation-compat-1"
    let offerId = "legacy-top-level-offer-id"
    var payload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "offerId": offerId,
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
    payload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: payload)

    let parsedOffer = try XCTUnwrap(
      CallSignalParser.sessionDescription(
        from: payload,
        objectKey: "offer",
        senderId: "@peer:example.org",
        callId: callId
      )
    )

    XCTAssertEqual(parsedOffer.offerId, offerId)
  }

  @MainActor
  func testIncomingCallDescriptorRequiresRelayTransportProfile() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var payload = makeCallOfferPayload(callId: "call-missing-transport-1", offerKind: "initial")
    payload.removeValue(forKey: "transport_profile")
    let message = try makeCallOfferMessage(fixture: fixture, payload: payload)

    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testIncomingCallDescriptorRequiresCallVersionAndSentAt() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var missingVersionPayload = makeCallOfferPayload(callId: "call-missing-version-1", offerKind: "initial")
    missingVersionPayload.removeValue(forKey: "call_version")
    let missingVersionMessage = try makeCallOfferMessage(fixture: fixture, payload: missingVersionPayload)

    var missingSentAtPayload = makeCallOfferPayload(callId: "call-missing-sent-at-1", offerKind: "initial")
    missingSentAtPayload.removeValue(forKey: "sent_at")
    let missingSentAtMessage = try makeCallOfferMessage(fixture: fixture, payload: missingSentAtPayload)

    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: missingVersionMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: missingSentAtMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testIncomingCallDescriptorRequiresMatchingTargetDeviceWhenLocalDeviceProvided() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let matchingPayload = makeCallOfferPayload(
      callId: "call-targeted-local-device-1",
      offerKind: "initial",
      targetDeviceId: fixture.localDeviceId
    )
    let matchingMessage = try makeCallOfferMessage(fixture: fixture, payload: matchingPayload)

    let otherDevicePayload = makeCallOfferPayload(
      callId: "call-targeted-other-device-1",
      offerKind: "initial",
      targetDeviceId: "other-local-device-1"
    )
    let otherDeviceMessage = try makeCallOfferMessage(fixture: fixture, payload: otherDevicePayload)

    XCTAssertNotNil(
      CallSignalParser.incomingCallDescriptor(
        from: matchingMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId,
        localDeviceId: fixture.localDeviceId
      )
    )
    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: otherDeviceMessage,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId,
        localDeviceId: fixture.localDeviceId
      )
    )
  }

  @MainActor
  func testIncomingCallDescriptorRejectsNonRelayInlineSDPCandidates() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var payload = makeCallOfferPayload(callId: "call-host-candidate-1", offerKind: "initial")
    var offer = try XCTUnwrap(payload["offer"] as? [String: Any])
    offer["sdp"] = sdpWithDTLSFingerprint(
      candidate: "candidate:1 1 udp 2122260223 192.168.1.2 5000 typ host"
    )
    payload["offer"] = offer
    payload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: payload)
    let message = try makeCallOfferMessage(fixture: fixture, payload: payload)

    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testIncomingCallDescriptorAcceptsRelayOnlyInlineSDPCandidates() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var payload = makeCallOfferPayload(callId: "call-relay-candidate-1", offerKind: "initial")
    var offer = try XCTUnwrap(payload["offer"] as? [String: Any])
    offer["sdp"] = sdpWithDTLSFingerprint(
      candidate: "candidate:2 1 udp 1677729535 203.0.113.10 3478 typ relay"
    )
    payload["offer"] = offer
    payload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: payload)
    let message = try makeCallOfferMessage(fixture: fixture, payload: payload)

    XCTAssertNotNil(
      CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testIncomingCallDescriptorRejectsMismatchedDTLSFingerprintBinding() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var payload = makeCallOfferPayload(callId: "call-dtls-descriptor-1", offerKind: "initial")
    payload["dtls_fingerprint"] = mismatchedTestDTLSFingerprint()
    payload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: payload)
    let message = try makeCallOfferMessage(fixture: fixture, payload: payload)

    XCTAssertNil(
      CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: fixture.conversation,
        currentUserId: fixture.localUserId
      )
    )
  }

  @MainActor
  func testSessionDescriptionParserRejectsNonRelayAnswerCandidates() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let payload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-answer-srflx-1",
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: fixture.localDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "answer": [
          "type": "answer",
          "sdp": sdpWithDTLSFingerprint(
            candidate: "candidate:3 1 udp 1686052607 198.51.100.2 4000 typ srflx"
          ),
        ],
      ],
    )

    XCTAssertNil(
      CallSignalParser.sessionDescription(
        from: payload,
        objectKey: "answer",
        senderId: fixture.peerUserId,
        callId: "call-answer-srflx-1"
      )
    )
  }

  @MainActor
  func testSessionDescriptionParserRequiresMatchingDTLSFingerprintBinding() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let payload = makeCallOfferPayload(callId: "call-dtls-bound-1", offerKind: "initial")

    let description = try XCTUnwrap(
      CallSignalParser.sessionDescription(
        from: payload,
        objectKey: "offer",
        senderId: fixture.peerUserId,
        callId: "call-dtls-bound-1"
      )
    )

    XCTAssertEqual(description.dtlsFingerprint, testDTLSFingerprint())
    XCTAssertEqual(CallSignalParser.dtlsFingerprint(fromSDP: description.sdp), testDTLSFingerprint())
    XCTAssertTrue(CallSignalParser.hasMatchingDTLSFingerprint(payload, sdp: description.sdp))
  }

  @MainActor
  func testSessionDescriptionParserRejectsMissingOrMismatchedDTLSFingerprintBinding() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let payload = makeCallOfferPayload(callId: "call-dtls-mismatch-1", offerKind: "initial")

    var missingFingerprintPayload: [String: Any] = payload
    missingFingerprintPayload.removeValue(forKey: "dtls_fingerprint")
    missingFingerprintPayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: missingFingerprintPayload)

    var mismatchedFingerprintPayload: [String: Any] = payload
    mismatchedFingerprintPayload["dtls_fingerprint"] = mismatchedTestDTLSFingerprint()
    mismatchedFingerprintPayload["transcript_hash"] =
      CallSignalEnvelope.transcriptHash(for: mismatchedFingerprintPayload)

    XCTAssertNil(
      CallSignalParser.sessionDescription(
        from: missingFingerprintPayload,
        objectKey: "offer",
        senderId: fixture.peerUserId,
        callId: "call-dtls-mismatch-1"
      )
    )
    XCTAssertNil(
      CallSignalParser.sessionDescription(
        from: mismatchedFingerprintPayload,
        objectKey: "offer",
        senderId: fixture.peerUserId,
        callId: "call-dtls-mismatch-1"
      )
    )
  }

  @MainActor
  func testCallSessionRejectsLocalDescriptionWithMismatchedDTLSFingerprintBinding() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-local-dtls-bound-1")
    let description = CallSessionDescriptionSignal(
      callId: "call-local-dtls-bound-1",
      fromUserId: fixture.localUserId,
      type: "offer",
      sdp: sdpWithDTLSFingerprint(),
      dtlsFingerprint: mismatchedTestDTLSFingerprint()
    )

    XCTAssertThrowsError(try viewModel.boundDTLSFingerprintForTesting(description)) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "Local SDP DTLS fingerprint is not transcript-bound"
      )
    }
  }

  @MainActor
  func testCallSessionAcceptsLocalDescriptionWithMatchingDTLSFingerprintBinding() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-local-dtls-bound-2")
    let description = CallSessionDescriptionSignal(
      callId: "call-local-dtls-bound-2",
      fromUserId: fixture.localUserId,
      type: "offer",
      sdp: sdpWithDTLSFingerprint(),
      dtlsFingerprint: testDTLSFingerprint()
    )

    XCTAssertEqual(try viewModel.boundDTLSFingerprintForTesting(description), testDTLSFingerprint())
  }

  @MainActor
  func testIceCandidateParserRequiresRelayTransportProfile() throws {
    let relayCandidate: String = "candidate:4 1 udp 1677729535 203.0.113.10 3478 typ relay"
    var missingProfilePayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-ice-profile-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "candidate": [
          "candidate": relayCandidate,
          "sdpMLineIndex": 0,
        ],
      ]
    )
    missingProfilePayload.removeValue(forKey: "transport_profile")
    var wrongProfilePayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-ice-profile-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "candidate": [
          "candidate": relayCandidate,
          "sdpMLineIndex": 0,
        ],
      ]
    )
    wrongProfilePayload["transport_profile"] = "webrtc_direct"
    wrongProfilePayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: wrongProfilePayload)

    XCTAssertNil(CallSignalParser.iceCandidate(from: missingProfilePayload, callId: "call-ice-profile-1"))
    XCTAssertNil(CallSignalParser.iceCandidate(from: wrongProfilePayload, callId: "call-ice-profile-1"))
  }

  @MainActor
  func testIceCandidateParserRequiresCallVersionAndSentAt() throws {
    var missingVersionPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-ice-version-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "candidate": [
          "candidate": "candidate:10 1 udp 1677729535 203.0.113.10 3478 typ relay",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    missingVersionPayload.removeValue(forKey: "call_version")
    var missingSentAtPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-ice-sent-at-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "candidate": [
          "candidate": "candidate:11 1 udp 1677729535 203.0.113.10 3478 typ relay",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    missingSentAtPayload.removeValue(forKey: "sent_at")

    XCTAssertNil(CallSignalParser.iceCandidate(from: missingVersionPayload, callId: "call-ice-version-1"))
    XCTAssertNil(CallSignalParser.iceCandidate(from: missingSentAtPayload, callId: "call-ice-sent-at-1"))
  }

  @MainActor
  func testIceCandidateParserRequiresExactRelayTypeToken() throws {
    XCTAssertTrue(CallSignalParser.isRelayCandidate(
      "candidate:5 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0"
    ))
    XCTAssertFalse(CallSignalParser.isRelayCandidate(
      "candidate:6 1 udp 1677729535 203.0.113.10 3478 typ relayx generation 0"
    ))
    XCTAssertFalse(CallSignalParser.isRelayCandidate(
      "candidate:7 1 udp 2122260223 192.168.1.2 5000 typ host relay"
    ))
  }

  @MainActor
  func testIceCandidateParserAcceptsRelayCandidateWithSnakeCaseFields() throws {
    let payload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-ice-relay-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "candidate": [
          "candidate": "candidate:8 1 udp 1677729535 203.0.113.10 3478 typ relay",
          "sdp_mid": "audio",
          "sdp_mline_index": "2",
        ],
      ]
    )

    let candidate = try XCTUnwrap(CallSignalParser.iceCandidate(from: payload, callId: "call-ice-relay-1"))

    XCTAssertEqual(candidate.callId, "call-ice-relay-1")
    XCTAssertEqual(candidate.sdpMid, "audio")
    XCTAssertEqual(candidate.sdpMLineIndex, 2)
  }

  @MainActor
  func testIceCandidateDedupeKeyNormalizesWhitespaceButPreservesMediaLine() throws {
    let first = CallICECandidateSignal(
      callId: "call-ice-dedupe-1",
      sdp: " candidate:21 1 udp 1677729535 203.0.113.10 3478 typ relay\r\n generation 0 ",
      sdpMid: " audio ",
      sdpMLineIndex: 0
    )
    let duplicate = CallICECandidateSignal(
      callId: " call-ice-dedupe-1 ",
      sdp: "candidate:21 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 0
    )
    let differentMediaLine = CallICECandidateSignal(
      callId: "call-ice-dedupe-1",
      sdp: "candidate:21 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 1
    )

    XCTAssertEqual(first.dedupeKey, duplicate.dedupeKey)
    XCTAssertNotEqual(first.dedupeKey, differentMediaLine.dedupeKey)
  }

  @MainActor
  func testMessengerPendingIceCandidateQueueDropsDuplicates() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = MessengerViewModel(container: fixture.container)
    let callId = "call-ice-pending-dedupe-1"
    let first = CallICECandidateSignal(
      callId: callId,
      sdp: "candidate:22 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 0
    )
    let duplicate = CallICECandidateSignal(
      callId: callId,
      sdp: " candidate:22 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0 ",
      sdpMid: "audio",
      sdpMLineIndex: 0
    )
    let differentMediaLine = CallICECandidateSignal(
      callId: callId,
      sdp: "candidate:22 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
      sdpMid: "audio",
      sdpMLineIndex: 1
    )

    XCTAssertTrue(viewModel.appendPendingCallICECandidateForTesting(first, callId: callId))
    XCTAssertFalse(viewModel.appendPendingCallICECandidateForTesting(duplicate, callId: callId))
    XCTAssertTrue(viewModel.appendPendingCallICECandidateForTesting(differentMediaLine, callId: callId))

    XCTAssertEqual(viewModel.takePendingCallICECandidates(callId: callId), [first, differentMediaLine])
    XCTAssertTrue(viewModel.takePendingCallICECandidates(callId: callId).isEmpty)
  }

  @MainActor
  func testCallSignalPollingUsesFastIntervalUntilConnected() throws {
    XCTAssertEqual(
      E2ECallSessionViewModel.callSignalPollIntervalNanoseconds(for: .connecting),
      250_000_000
    )
    XCTAssertEqual(
      E2ECallSessionViewModel.callSignalPollIntervalNanoseconds(for: .waitingForPeer),
      250_000_000
    )
    XCTAssertEqual(
      E2ECallSessionViewModel.callSignalPollIntervalNanoseconds(for: .reconnecting),
      250_000_000
    )
    XCTAssertEqual(
      E2ECallSessionViewModel.callSignalPollIntervalNanoseconds(for: .connected),
      1_000_000_000
    )
  }

  @MainActor
  func testLegacyRawCallSocketPolicyBlocksProductionCallEvents() throws {
    let production = AppLaunchConfiguration(environment: [:])
    let stub = AppLaunchConfiguration(environment: ["UITEST_STUB_NETWORK": "1"])

    XCTAssertTrue(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.incomingCall))
    XCTAssertTrue(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.callAnswered))
    XCTAssertTrue(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.callICECandidate))
    XCTAssertTrue(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.callMediaState))
    XCTAssertTrue(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.callQualityUpdate))
    XCTAssertFalse(LegacyRawCallSocketPolicy.isLegacyRawCallEvent(SocketEventName.rtcConfig))
    XCTAssertFalse(LegacyRawCallSocketPolicy.allowsRawCallEvents(configuration: production))
    XCTAssertTrue(LegacyRawCallSocketPolicy.allowsRawCallEvents(configuration: stub))
  }

  func testAppBackgroundRealtimePolicyKeepsRealtimeAliveDuringActiveE2ECall() {
    XCTAssertFalse(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: false,
        shouldDisableRealtime: false,
        accessToken: "token-123",
        hasActiveE2ECallSession: true
      )
    )
  }

  func testAppBackgroundRealtimePolicySuspendsRealtimeOnlyWhenSafe() {
    XCTAssertTrue(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: false,
        shouldDisableRealtime: false,
        accessToken: "token-123",
        hasActiveE2ECallSession: false
      )
    )
    XCTAssertFalse(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: true,
        shouldDisableRealtime: false,
        accessToken: "token-123",
        hasActiveE2ECallSession: false
      )
    )
    XCTAssertFalse(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: false,
        shouldDisableRealtime: true,
        accessToken: "token-123",
        hasActiveE2ECallSession: false
      )
    )
    XCTAssertFalse(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: false,
        shouldDisableRealtime: false,
        accessToken: nil,
        hasActiveE2ECallSession: false
      )
    )
    XCTAssertFalse(
      AppBackgroundRealtimePolicy.shouldSuspendRealtime(
        isAutomationModeEnabled: false,
        shouldDisableRealtime: false,
        accessToken: "",
        hasActiveE2ECallSession: false
      )
    )
  }

  @MainActor
  func testCallIceCandidateEventDecodesRelayTransportProfile() throws {
    let payload = """
    {
      "call_id": "call-ice-socket-1",
      "call_version": 1,
      "sent_at": "2026-06-11T12:00:00.000Z",
      "transport_profile": "webrtc_turn_relay",
      "candidate": {
        "candidate": "candidate:9 1 udp 1677729535 203.0.113.10 3478 typ relay",
        "sdpMid": "video",
        "sdpMLineIndex": 1
      }
    }
    """
    let event = try JSONCoding.decoder.decode(CallICECandidateEvent.self, from: Data(payload.utf8))

    XCTAssertEqual(event.callId, "call-ice-socket-1")
    XCTAssertEqual(event.transportProfile, "webrtc_turn_relay")
    XCTAssertEqual(event.candidate["sdpMid"]?.value as? String, "video")
  }

  @MainActor
  func testCallSignalEnvelopeRequiresTranscriptHashMetadata() throws {
    let payload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-transcript-required-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "status": "ended",
      ]
    )

    XCTAssertTrue(CallSignalParser.hasValidEnvelope(payload))
    XCTAssertEqual(CallSignalParser.senderDeviceId(from: payload), "peer-device-1")
    XCTAssertEqual(CallSignalParser.targetDeviceId(from: payload), "local-device-1")
    XCTAssertTrue(CallSignalParser.isTargeted(to: "local-device-1", payload: payload))

    var missingSequencePayload: [String: Any] = payload
    missingSequencePayload.removeValue(forKey: "seq")
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(missingSequencePayload))

    var missingPreviousHashPayload: [String: Any] = payload
    missingPreviousHashPayload.removeValue(forKey: "prev_event_hash")
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(missingPreviousHashPayload))

    var missingTranscriptHashPayload: [String: Any] = payload
    missingTranscriptHashPayload.removeValue(forKey: "transcript_hash")
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(missingTranscriptHashPayload))

    var missingSenderDevicePayload: [String: Any] = payload
    missingSenderDevicePayload.removeValue(forKey: "sender_device_id")
    missingSenderDevicePayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: missingSenderDevicePayload)
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(missingSenderDevicePayload))

    var missingTargetDevicePayload: [String: Any] = payload
    missingTargetDevicePayload.removeValue(forKey: "target_device_id")
    missingTargetDevicePayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: missingTargetDevicePayload)
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(missingTargetDevicePayload))
    XCTAssertFalse(CallSignalParser.isTargeted(to: "other-device-1", payload: payload))

    var tamperedPayload: [String: Any] = payload
    tamperedPayload["status"] = "rejected"
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(tamperedPayload))
  }

  @MainActor
  func testCallSignalEnvelopeRejectsStaleAndFutureSentAt() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let freshPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-fresh-sent-at-1",
      sentAt: now.addingTimeInterval(-60),
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "status": "ended",
      ]
    )
    let stalePayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-stale-sent-at-1",
      sentAt: now.addingTimeInterval(-601),
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "status": "ended",
      ]
    )
    let futurePayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-future-sent-at-1",
      sentAt: now.addingTimeInterval(121),
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "status": "ended",
      ]
    )

    XCTAssertTrue(CallSignalParser.hasValidEnvelope(freshPayload, now: now))
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(stalePayload, now: now))
    XCTAssertFalse(CallSignalParser.hasValidEnvelope(futurePayload, now: now))
  }

  @MainActor
  func testCallSignalProcessingOrderUsesTranscriptSequenceBeforeCreatedAt() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-processing-order-1"
    let baseDate = Date(timeIntervalSince1970: 7_000)
    let candidatePayload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      sequence: 2,
      previousTranscriptHash: CallSignalEnvelope.initialTranscriptHash,
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: fixture.localDeviceId,
      values: [
        "candidate": [
          "candidate": "candidate:20 1 udp 1677729535 203.0.113.10 3478 typ relay",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    let offerPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      sequence: 1,
      previousTranscriptHash: CallSignalEnvelope.initialTranscriptHash,
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: fixture.localDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": "ice_restart",
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
    let outOfBandText = Message(
      id: "call-processing-order-text-1",
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: "not a call signal",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: baseDate.addingTimeInterval(-20),
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
    let candidateMessage = makeCallSignalMessage(
      fixture: fixture,
      id: "call-processing-order-candidate-1",
      type: .callIceCandidate,
      payload: candidatePayload,
      createdAt: baseDate
    )
    let offerMessage = makeCallSignalMessage(
      fixture: fixture,
      id: "call-processing-order-offer-1",
      type: .callOffer,
      payload: offerPayload,
      createdAt: baseDate.addingTimeInterval(10)
    )

    let sorted = CallSignalProcessingOrder.sorted(
      [candidateMessage, outOfBandText, offerMessage],
      callId: callId
    )

    XCTAssertEqual(sorted.map(\.id), [
      "call-processing-order-offer-1",
      "call-processing-order-candidate-1",
      "call-processing-order-text-1",
    ])
  }

  @MainActor
  func testCallMediaStateParserRequiresValidCallEnvelope() throws {
    let payload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-media-state-parse-1",
      senderDeviceId: "peer-device-1",
      targetDeviceId: "local-device-1",
      values: [
        "microphone_enabled": false,
        "camera_enabled": true,
      ]
    )

    let state = try XCTUnwrap(CallSignalParser.mediaState(from: payload, callId: "call-media-state-parse-1"))

    XCTAssertEqual(state.callId, "call-media-state-parse-1")
    XCTAssertFalse(state.isMicrophoneEnabled)
    XCTAssertEqual(state.isCameraEnabled, true)

    var missingMicrophonePayload = payload
    missingMicrophonePayload.removeValue(forKey: "microphone_enabled")
    missingMicrophonePayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: missingMicrophonePayload)
    XCTAssertNil(CallSignalParser.mediaState(from: missingMicrophonePayload, callId: "call-media-state-parse-1"))

    var tamperedPayload = payload
    tamperedPayload["camera_enabled"] = false
    XCTAssertNil(CallSignalParser.mediaState(from: tamperedPayload, callId: "call-media-state-parse-1"))
  }

  @MainActor
  func testSendSignalingPayloadAddsCallTranscriptMetadataAndChainsSequence() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-transcript-chain-1"
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let first = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: makeCallOfferPayload(
        callId: callId,
        offerKind: "initial",
        senderDeviceId: fixture.localDeviceId,
        targetDeviceId: fixture.peerDeviceId
      )
    )
    let firstPayload: [String: Any] = try jsonObject(from: first.content)

    XCTAssertTrue(CallSignalParser.hasValidEnvelope(firstPayload))
    XCTAssertEqual((firstPayload["seq"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(firstPayload["prev_event_hash"] as? String, CallSignalEnvelope.initialTranscriptHash)
    XCTAssertEqual(firstPayload["sender_device_id"] as? String, fixture.localDeviceId)
    XCTAssertEqual(firstPayload["target_device_id"] as? String, fixture.peerDeviceId)
    XCTAssertEqual(firstPayload["dtls_fingerprint"] as? String, testDTLSFingerprint())

    let firstTranscriptHash = try XCTUnwrap(firstPayload["transcript_hash"] as? String)
    XCTAssertEqual(firstTranscriptHash, CallSignalEnvelope.transcriptHash(for: firstPayload))

    try enqueueSuccessfulExistingSessionSendResponses(fixture: fixture)
    let second = try await fixture.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callIceCandidate.rawValue,
      payloadObject: [
        "call_id": callId,
        "target_device_id": fixture.peerDeviceId,
        "candidate": [
          "candidate": "candidate:12 1 udp 1677729535 203.0.113.10 3478 typ relay",
          "sdpMLineIndex": 0,
        ],
      ]
    )
    let secondPayload: [String: Any] = try jsonObject(from: second.content)

    XCTAssertTrue(CallSignalParser.hasValidEnvelope(secondPayload))
    XCTAssertEqual((secondPayload["seq"] as? NSNumber)?.intValue, 2)
    XCTAssertEqual(secondPayload["prev_event_hash"] as? String, firstTranscriptHash)
    XCTAssertEqual(secondPayload["sender_device_id"] as? String, fixture.localDeviceId)
    XCTAssertEqual(secondPayload["target_device_id"] as? String, fixture.peerDeviceId)
    XCTAssertEqual(
      secondPayload["transcript_hash"] as? String,
      CallSignalEnvelope.transcriptHash(for: secondPayload)
    )
  }

  @MainActor
  func testWebRTCMediaQualityProfileUsesRelayFriendlyLowLatencyDefaults() throws {
    XCTAssertEqual(WebRTCMediaQualityProfile.targetVideoWidth, 1280)
    XCTAssertEqual(WebRTCMediaQualityProfile.targetVideoHeight, 720)
    XCTAssertLessThanOrEqual(WebRTCMediaQualityProfile.targetVideoMaxFramerate, 24)
    XCTAssertGreaterThanOrEqual(WebRTCMediaQualityProfile.targetVideoMinFramerate, 10)
    XCTAssertEqual(WebRTCMediaQualityProfile.preferredAudioSampleRate, 48_000)
    XCTAssertLessThanOrEqual(WebRTCMediaQualityProfile.preferredAudioIOBufferDuration, 0.01)
    XCTAssertLessThanOrEqual(WebRTCMediaQualityProfile.videoMaxBitrateBps, 1_400_000)
    XCTAssertLessThanOrEqual(WebRTCMediaQualityProfile.audioMaxBitrateBps, 96_000)
    XCTAssertLessThanOrEqual(
      WebRTCMediaQualityProfile.relayBackupCandidatePairPingIntervalMs,
      1_000
    )
    XCTAssertLessThanOrEqual(
      WebRTCMediaQualityProfile.videoMinBitrateBps,
      WebRTCMediaQualityProfile.videoStartBitrateBps
    )
    XCTAssertLessThanOrEqual(
      WebRTCMediaQualityProfile.videoStartBitrateBps,
      WebRTCMediaQualityProfile.videoMaxBitrateBps
    )
  }

  func testWebRTCRelayConfigurationUsesRelayOnlyLowLatencyPolicy() {
    let iceServers = [
      RTCIceServer(
        urlStrings: ["turn:relay.example.org:3478?transport=udp"],
        username: "call-user",
        credential: "call-credential"
      ),
    ]

    let configuration = WebRTCAutomationEngine.relayConfigurationForTesting(iceServers: iceServers)

    XCTAssertTrue(configuration.enableDscp)
    XCTAssertEqual(configuration.sdpSemantics, .unifiedPlan)
    XCTAssertEqual(configuration.bundlePolicy, .maxBundle)
    XCTAssertEqual(configuration.rtcpMuxPolicy, .require)
    XCTAssertEqual(configuration.tcpCandidatePolicy, .enabled)
    XCTAssertEqual(configuration.candidateNetworkPolicy, .all)
    XCTAssertEqual(configuration.continualGatheringPolicy, .gatherContinually)
    XCTAssertEqual(configuration.iceTransportPolicy, .relay)
    XCTAssertEqual(configuration.iceCandidatePoolSize, 0)
    XCTAssertTrue(configuration.shouldPruneTurnPorts)
    XCTAssertTrue(configuration.shouldPresumeWritableWhenFullyRelayed)
    XCTAssertTrue(configuration.audioJitterBufferFastAccelerate)
    XCTAssertEqual(
      configuration.audioJitterBufferMaxPackets,
      WebRTCMediaQualityProfile.audioJitterBufferMaxPackets
    )
    XCTAssertEqual(
      configuration.iceBackupCandidatePairPingInterval,
      WebRTCMediaQualityProfile.relayBackupCandidatePairPingIntervalMs
    )
    XCTAssertEqual(configuration.iceServers.count, 1)
  }

  func testWebRTCSdpTypeParserTrimsAndAcceptsSupportedTypes() throws {
    XCTAssertEqual(
      RTCSessionDescription.string(for: try WebRTCAutomationEngine.sdpTypeForTesting(" OFFER\n")),
      "offer"
    )
    XCTAssertEqual(
      RTCSessionDescription.string(for: try WebRTCAutomationEngine.sdpTypeForTesting("\tanswer ")),
      "answer"
    )
    XCTAssertEqual(
      RTCSessionDescription.string(for: try WebRTCAutomationEngine.sdpTypeForTesting("pranswer")),
      "pranswer"
    )
    XCTAssertEqual(
      RTCSessionDescription.string(for: try WebRTCAutomationEngine.sdpTypeForTesting(" rollback ")),
      "rollback"
    )
  }

  func testWebRTCSdpTypeParserRejectsUnsupportedTypes() {
    XCTAssertThrowsError(try WebRTCAutomationEngine.sdpTypeForTesting("candidate")) { error in
      guard case let WebRTCAutomationEngineError.signalingStateInvalid(message) = error else {
        XCTFail("Expected signalingStateInvalid, got \(error)")
        return
      }

      XCTAssertEqual(message, "Unsupported SDP type: candidate")
    }
  }

  func testCallRelayIceServerMapperKeepsOnlyTurnServersAndPreservesPriorityCredentials() {
    let rtcConfig = RTCConfig(
      iceServers: [
        RTCIceServer(urls: " stun:stun.example.org:3478 ", username: "stun-user", credential: "stun-pass"),
        RTCIceServer(urls: " turn:relay.example.org:3478?transport=udp ", username: nil, credential: nil),
        RTCIceServer(urls: "turns:relay.example.org:5349?transport=tcp", username: "server-user", credential: nil),
        RTCIceServer(urls: "turn:relay-backup.example.org:3478?transport=tcp", username: nil, credential: "server-pass"),
        RTCIceServer(urls: " ", username: "empty-user", credential: "empty-pass"),
      ],
      turnCredentials: TurnCredentials(username: "fallback-user", password: "fallback-pass", ttl: 600),
      iceTransportPolicy: "relay"
    )

    let iceServers = CallRelayIceServerMapper.map(rtcConfig)

    XCTAssertEqual(iceServers.count, 3)
    XCTAssertEqual(iceServers[0].urlStrings, ["turn:relay.example.org:3478?transport=udp"])
    XCTAssertEqual(iceServers[0].username, "fallback-user")
    XCTAssertEqual(iceServers[0].credential, "fallback-pass")
    XCTAssertEqual(iceServers[1].urlStrings, ["turns:relay.example.org:5349?transport=tcp"])
    XCTAssertEqual(iceServers[1].username, "server-user")
    XCTAssertEqual(iceServers[1].credential, "fallback-pass")
    XCTAssertEqual(iceServers[2].urlStrings, ["turn:relay-backup.example.org:3478?transport=tcp"])
    XCTAssertEqual(iceServers[2].username, "fallback-user")
    XCTAssertEqual(iceServers[2].credential, "server-pass")
  }

  func testCallRelayIceServerMapperPreservesMultipleTurnUrlsFromServerJSON() throws {
    let payload = """
      {
        "ice_servers": [
          {
            "urls": [
              "turn:turn.example.org:3478?transport=udp",
              "turn:turn.example.org:3478?transport=tcp"
            ],
            "username": "server-user",
            "credential": "server-pass"
          }
        ],
        "turn_credentials": {
          "username": "fallback-user",
          "credential": "fallback-pass",
          "expires_at": 1700000300,
          "ttl": 300
        },
        "ice_transport_policy": "relay"
      }
      """.data(using: .utf8)!

    let config = try JSONCoding.decoder.decode(RTCConfig.self, from: payload)
    let iceServers = CallRelayIceServerMapper.map(config)

    XCTAssertEqual(config.iceServers.first?.urlStrings, [
      "turn:turn.example.org:3478?transport=udp",
      "turn:turn.example.org:3478?transport=tcp",
    ])
    XCTAssertEqual(iceServers.count, 1)
    XCTAssertEqual(iceServers.first?.urlStrings, [
      "turn:turn.example.org:3478?transport=udp",
      "turn:turn.example.org:3478?transport=tcp",
    ])
    XCTAssertEqual(iceServers.first?.username, "server-user")
    XCTAssertEqual(iceServers.first?.credential, "server-pass")
  }

  func testWebRTCMediaFlowSnapshotReadinessRequiresExpectedRemoteTracks() {
    let audioOnlyReady = WebRTCMediaFlowSnapshot(
      outboundAudioBytes: 0,
      outboundVideoBytes: 0,
      inboundAudioBytes: 0,
      inboundVideoBytes: 0,
      outboundAudioPackets: 1,
      outboundVideoPackets: 0,
      inboundAudioPackets: 1,
      inboundVideoPackets: 0,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: false,
      connectionState: .connected,
      iceConnectionState: .connected
    )
    let audioVideoMissingRemoteTrack = WebRTCMediaFlowSnapshot(
      outboundAudioBytes: 1_000,
      outboundVideoBytes: 1_000,
      inboundAudioBytes: 1_000,
      inboundVideoBytes: 1_000,
      outboundAudioPackets: 0,
      outboundVideoPackets: 0,
      inboundAudioPackets: 0,
      inboundVideoPackets: 0,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: false,
      connectionState: .connected,
      iceConnectionState: .connected
    )
    let audioVideoReady = WebRTCMediaFlowSnapshot(
      outboundAudioBytes: 1_000,
      outboundVideoBytes: 1_000,
      inboundAudioBytes: 1_000,
      inboundVideoBytes: 1_000,
      outboundAudioPackets: 0,
      outboundVideoPackets: 0,
      inboundAudioPackets: 0,
      inboundVideoPackets: 0,
      remoteAudioTrackSeen: true,
      remoteVideoTrackSeen: true,
      connectionState: .connected,
      iceConnectionState: .completed
    )

    XCTAssertTrue(audioOnlyReady.hasBidirectionalAudio(minBytes: 512))
    XCTAssertFalse(audioOnlyReady.hasBidirectionalAudioVideo(minBytes: 512))
    XCTAssertFalse(audioVideoMissingRemoteTrack.hasBidirectionalAudioVideo(minBytes: 512))
    XCTAssertTrue(audioVideoReady.hasBidirectionalAudio(minBytes: 512))
    XCTAssertTrue(audioVideoReady.hasBidirectionalAudioVideo(minBytes: 512))

    let summary = audioVideoReady.summary()
    XCTAssertTrue(summary.contains("audio=present"))
    XCTAssertTrue(summary.contains("video=present"))
    XCTAssertFalse(summary.contains("1000"))
  }

  func testCallDiagnosticLogMessagesDoNotExposeCallMetadata() {
    let forbiddenFragments: [String] = [
      "call-",
      "@alice",
      "from ",
      "status",
      "sdp",
      "fingerprint",
      "candidate:",
    ]

    for message in CallDiagnosticLog.redactedMessagesForTesting {
      for fragment in forbiddenFragments {
        XCTAssertFalse(
          message.localizedCaseInsensitiveContains(fragment),
          "Call diagnostic log leaked \(fragment): \(message)"
        )
      }
    }
  }

  func testVideoCallBundleCapabilitiesDeclareBackgroundAndMultitaskingCameraAccess() throws {
    let infoPlist = try sourcePlist(at: ["messenger", "messenger", "Info.plist"])
    let backgroundModes = try XCTUnwrap(infoPlist["UIBackgroundModes"] as? [String])
    XCTAssertTrue(backgroundModes.contains("audio"))
    XCTAssertTrue(backgroundModes.contains("voip"))
    XCTAssertTrue(backgroundModes.contains("remote-notification"))

    let entitlements = try sourcePlist(at: ["messenger", "messenger", "messenger.entitlements"])
    XCTAssertEqual(
      entitlements["com.apple.developer.avfoundation.multitasking-camera-access"] as? Bool,
      true
    )
  }

  func testCallToneControllerStartsOutgoingRingbackAndRepeatsThroughTimer() throws {
    let audioPlayer = SpyCallToneAudioPlayer()
    let timerScheduler = SpyCallToneTimerScheduler()
    let controller = CallToneController(audioPlayer: audioPlayer, timerScheduler: timerScheduler)

    controller.startOutgoingRingback()

    XCTAssertEqual(audioPlayer.playedTones, [
      SpyCallToneAudioPlayer.PlayedTone(frequency: 440, duration: 0.28),
    ])
    let timer = try XCTUnwrap(timerScheduler.scheduledTimers.last)
    XCTAssertEqual(timer.interval, 2.0)
    XCTAssertEqual(timer.invalidateCount, 0)

    timer.fire()

    XCTAssertEqual(audioPlayer.playedTones, [
      SpyCallToneAudioPlayer.PlayedTone(frequency: 440, duration: 0.28),
      SpyCallToneAudioPlayer.PlayedTone(frequency: 440, duration: 0.28),
    ])
  }

  func testCallToneControllerReplacesRepeatingToneWhenModeChanges() throws {
    let audioPlayer = SpyCallToneAudioPlayer()
    let timerScheduler = SpyCallToneTimerScheduler()
    let controller = CallToneController(audioPlayer: audioPlayer, timerScheduler: timerScheduler)

    controller.startOutgoingRingback()
    let outgoingTimer = try XCTUnwrap(timerScheduler.scheduledTimers.last)

    controller.startIncomingRingtone()

    XCTAssertEqual(outgoingTimer.invalidateCount, 1)
    XCTAssertEqual(audioPlayer.playedTones, [
      SpyCallToneAudioPlayer.PlayedTone(frequency: 440, duration: 0.28),
      SpyCallToneAudioPlayer.PlayedTone(frequency: 660, duration: 0.18),
    ])
    let incomingTimer = try XCTUnwrap(timerScheduler.scheduledTimers.last)
    XCTAssertEqual(incomingTimer.interval, 1.2)

    incomingTimer.fire()

    XCTAssertEqual(audioPlayer.playedTones.last, SpyCallToneAudioPlayer.PlayedTone(frequency: 660, duration: 0.18))
  }

  func testCallToneControllerConnectedCheckToneStopsRepeatingTone() throws {
    let audioPlayer = SpyCallToneAudioPlayer()
    let timerScheduler = SpyCallToneTimerScheduler()
    let controller = CallToneController(audioPlayer: audioPlayer, timerScheduler: timerScheduler)

    controller.startMediaCheckTone()
    let mediaTimer = try XCTUnwrap(timerScheduler.scheduledTimers.last)

    controller.playConnectedCheckTone()

    XCTAssertEqual(mediaTimer.invalidateCount, 1)
    XCTAssertEqual(audioPlayer.playedTones, [
      SpyCallToneAudioPlayer.PlayedTone(frequency: 880, duration: 0.22),
      SpyCallToneAudioPlayer.PlayedTone(frequency: 880, duration: 0.22),
    ])
    XCTAssertEqual(audioPlayer.stopCount, 0)
  }

  func testCallToneControllerStopInvalidatesTimerAndStopsAudioPlayerOnce() throws {
    let audioPlayer = SpyCallToneAudioPlayer()
    let timerScheduler = SpyCallToneTimerScheduler()
    let controller = CallToneController(audioPlayer: audioPlayer, timerScheduler: timerScheduler)

    controller.startIncomingRingtone()
    let timer = try XCTUnwrap(timerScheduler.scheduledTimers.last)

    controller.stop()
    controller.stop()

    XCTAssertEqual(timer.invalidateCount, 1)
    XCTAssertEqual(audioPlayer.stopCount, 2)
  }

  @MainActor
  func testCallSessionStoreReturnsExistingSessionForSameCallId() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let store = E2ECallSessionStore()
    let first = makeCallSessionViewModel(fixture: fixture, callId: "call-store-1")
    let duplicate = makeCallSessionViewModel(fixture: fixture, callId: "call-store-1")

    XCTAssertTrue(store.retain(first) === first)
    XCTAssertTrue(store.retain(duplicate) === first)
    XCTAssertTrue(store.activeSession === first)

    store.release(callId: "call-store-1")
    XCTAssertNil(store.activeSession)
    XCTAssertNil(store.session(callId: "call-store-1"))
  }

  @MainActor
  func testCallSessionStoreActiveSessionUsesMostRecentRetainedCall() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let store = E2ECallSessionStore()
    let first = makeCallSessionViewModel(fixture: fixture, callId: "call-store-active-1")
    let second = makeCallSessionViewModel(fixture: fixture, callId: "call-store-active-2")

    XCTAssertTrue(store.retain(first) === first)
    XCTAssertTrue(store.activeSession === first)
    XCTAssertTrue(store.retain(second) === second)
    XCTAssertTrue(store.activeSession === second)

    store.release(callId: "call-store-active-2")
    XCTAssertTrue(store.activeSession === first)
  }

  @MainActor
  func testCallSessionStoreRemoveAllFinishesRetainedSessions() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let store = E2ECallSessionStore()
    let first = makeCallSessionViewModel(fixture: fixture, callId: "call-store-clear-1")
    let second = makeCallSessionViewModel(fixture: fixture, callId: "call-store-clear-2")
    var finishedCallIds: [String] = []

    _ = first.addFinishObserver {
      finishedCallIds.append(first.activeCallId)
    }
    _ = second.addFinishObserver {
      finishedCallIds.append(second.activeCallId)
    }
    store.retain(first)
    store.retain(second)

    store.removeAll()

    XCTAssertNil(store.activeSession)
    XCTAssertNil(store.session(callId: "call-store-clear-1"))
    XCTAssertNil(store.session(callId: "call-store-clear-2"))
    XCTAssertEqual(first.state, .ended)
    XCTAssertEqual(second.state, .ended)
    XCTAssertEqual(Set(finishedCallIds), Set(["call-store-clear-1", "call-store-clear-2"]))
  }

  @MainActor
  func testFinishedCallSessionReleasesTaskAndCannotRestart() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-finished-no-restart-1")

    XCTAssertFalse(viewModel.hasSessionTaskForTesting)
    viewModel.start()
    XCTAssertTrue(viewModel.hasSessionTaskForTesting)

    viewModel.finishForLocalSessionClear()
    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertFalse(viewModel.hasSessionTaskForTesting)

    viewModel.start()
    XCTAssertFalse(viewModel.hasSessionTaskForTesting)
    XCTAssertEqual(viewModel.state, .ended)
  }

  @MainActor
  func testFinishedCallSessionRejectsDirectPictureInPictureStart() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-finished-direct-no-pip-1")
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      true
    }

    viewModel.finishForLocalSessionClear()

    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertFalse(viewModel.startPictureInPictureIfPossible())
    XCTAssertEqual(pictureInPictureStartRequests, 0)
  }

  @MainActor
  func testRetainedCallSessionEndsWhenSystemCallEndsWithoutActiveScreen() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let store = E2ECallSessionStore()
    let callId = "call-system-ended-no-screen-1"
    var viewModel: E2ECallSessionViewModel? = makeCallSessionViewModel(fixture: fixture, callId: callId)
    weak var weakViewModel: E2ECallSessionViewModel? = viewModel
    let finishExpectation = expectation(description: "retained call session finished")

    _ = viewModel?.addFinishObserver {
      finishExpectation.fulfill()
    }
    _ = store.retain(try XCTUnwrap(viewModel))
    XCTAssertNotNil(store.session(callId: callId))

    NotificationCenter.default.post(
      name: .didEndSystemCall,
      object: nil,
      userInfo: ["call_id": callId]
    )

    await fulfillment(of: [finishExpectation], timeout: 1)
    XCTAssertNil(store.session(callId: callId))
    XCTAssertNil(store.activeSession)
    XCTAssertEqual(viewModel?.state, .ended)

    viewModel = nil
    await flushMainQueue()
    XCTAssertNil(weakViewModel)
    weakViewModel = nil
  }

  @MainActor
  func testSystemCallCoordinatorClearsOutgoingMappingWhenStartRequestFails() {
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let callId = "callkit-start-failed-1"
    let uuid = UUID()

    coordinator.recordOutgoingCallForTesting(callId: callId, uuid: uuid)
    XCTAssertEqual(coordinator.testingSnapshot().callIdByUUID[uuid], callId)
    XCTAssertEqual(coordinator.testingSnapshot().uuidByCallId[callId], uuid)

    coordinator.handleCallControllerRequestFailureForTesting(uuid: uuid)

    let snapshot = coordinator.testingSnapshot()
    XCTAssertNil(snapshot.callIdByUUID[uuid])
    XCTAssertNil(snapshot.uuidByCallId[callId])
  }

  @MainActor
  func testSystemCallCoordinatorManagedAudioWaitStopsPromptlyWhenCancelled() async {
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let callId = "callkit-cancelled-audio-wait-1"
    let uuid = UUID()

    coordinator.recordOutgoingCallForTesting(callId: callId, uuid: uuid)
    XCTAssertTrue(CallAudioSessionCoordinator.shared.beginCallKitRequest(callUUID: uuid, hasVideo: false))

    let waitTask = Task { @MainActor in
      await coordinator.waitForCallKitAudioIfManaged(
        callId: callId,
        audioActivationTimeout: 8
      )
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    let cancelledAt = Date()
    waitTask.cancel()
    let result = await waitTask.value

    XCTAssertFalse(result)
    XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
  }

  @MainActor
  func testSystemCallCoordinatorReusesOutgoingUUIDForRepeatedNonUUIDCallId() {
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let callId = "callkit-repeated-outgoing-non-uuid-1"
    let endExpectation = expectation(description: "single outgoing call mapping ended")
    var endedCallIds: [String] = []
    let observer = NotificationCenter.default.addObserver(
      forName: .didEndSystemCall,
      object: nil,
      queue: .main
    ) { notification in
      if let endedCallId = notification.userInfo?["call_id"] as? String {
        endedCallIds.append(endedCallId)
      }
      endExpectation.fulfill()
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    let firstUUID = coordinator.storeOutgoingCallForTesting(callId: callId)
    let secondUUID = coordinator.storeOutgoingCallForTesting(callId: callId)

    XCTAssertEqual(firstUUID, secondUUID)
    XCTAssertEqual(coordinator.testingSnapshot().callIdByUUID, [firstUUID: callId])
    XCTAssertEqual(coordinator.testingSnapshot().uuidByCallId, [callId: firstUUID])

    coordinator.handleProviderResetForTesting()

    wait(for: [endExpectation], timeout: 1)
    XCTAssertEqual(endedCallIds, [callId])
    XCTAssertTrue(coordinator.testingSnapshot().callIdByUUID.isEmpty)
    XCTAssertTrue(coordinator.testingSnapshot().uuidByCallId.isEmpty)
  }

  @MainActor
  func testSystemCallCoordinatorResolvesEncryptedOfferToOldestOpaqueWake() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let olderOpaqueUUID = UUID()
    let newerOpaqueUUID = UUID()
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-opaque-resolved-1"
    )

    coordinator.recordOpaqueIncomingWakeForTesting(
      uuid: newerOpaqueUUID,
      createdAt: Date().addingTimeInterval(-1)
    )
    coordinator.recordOpaqueIncomingWakeForTesting(
      uuid: olderOpaqueUUID,
      createdAt: Date().addingTimeInterval(-2)
    )

    let resolvedUUID = coordinator.storeIncomingCallForTesting(descriptor)
    let snapshot = coordinator.testingSnapshot()

    XCTAssertEqual(resolvedUUID, olderOpaqueUUID)
    XCTAssertEqual(snapshot.callIdByUUID[olderOpaqueUUID], descriptor.callId)
    XCTAssertEqual(snapshot.uuidByCallId[descriptor.callId], olderOpaqueUUID)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID[olderOpaqueUUID], descriptor.callId)
    XCTAssertFalse(snapshot.opaqueIncomingUUIDs.contains(olderOpaqueUUID))
    XCTAssertTrue(snapshot.opaqueIncomingUUIDs.contains(newerOpaqueUUID))
  }

  @MainActor
  func testSystemCallCoordinatorDoesNotResolveEncryptedOfferToExpiredOpaqueWake() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let expiredOpaqueUUID = UUID()
    let descriptorUUID = UUID()
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: descriptorUUID,
      callId: "callkit-expired-opaque-1"
    )

    coordinator.recordOpaqueIncomingWakeForTesting(
      uuid: expiredOpaqueUUID,
      createdAt: Date().addingTimeInterval(-25)
    )

    let resolvedUUID = coordinator.storeIncomingCallForTesting(descriptor)
    let snapshot = coordinator.testingSnapshot()

    XCTAssertEqual(resolvedUUID, descriptorUUID)
    XCTAssertEqual(snapshot.callIdByUUID[descriptorUUID], descriptor.callId)
    XCTAssertEqual(snapshot.uuidByCallId[descriptor.callId], descriptorUUID)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID[descriptorUUID], descriptor.callId)
    XCTAssertFalse(snapshot.opaqueIncomingUUIDs.contains(expiredOpaqueUUID))
  }

  @MainActor
  func testSystemCallCoordinatorClearsUnresolvedOpaqueIncomingWakesAfterProcessedVoipSync() {
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let firstOpaqueUUID = UUID()
    let secondOpaqueUUID = UUID()

    coordinator.recordOpaqueIncomingWakeForTesting(uuid: firstOpaqueUUID)
    coordinator.recordOpaqueIncomingWakeForTesting(uuid: secondOpaqueUUID)

    coordinator.clearUnresolvedOpaqueIncomingWakes()

    let snapshot = coordinator.testingSnapshot()
    XCTAssertTrue(snapshot.opaqueIncomingUUIDs.isEmpty)
    XCTAssertTrue(snapshot.answeredBeforeDecryptUUIDs.isEmpty)
    XCTAssertTrue(snapshot.callIdByUUID.isEmpty)
    XCTAssertTrue(snapshot.uuidByCallId.isEmpty)
  }

  @MainActor
  func testSystemCallCoordinatorKeepsResolvedOpaqueIncomingCallAfterCleanup() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let opaqueUUID = UUID()
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-resolved-opaque-cleanup-1"
    )

    coordinator.recordOpaqueIncomingWakeForTesting(uuid: opaqueUUID)
    let resolvedUUID = coordinator.storeIncomingCallForTesting(descriptor)
    coordinator.clearUnresolvedOpaqueIncomingWakes()

    let snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(resolvedUUID, opaqueUUID)
    XCTAssertTrue(snapshot.opaqueIncomingUUIDs.isEmpty)
    XCTAssertEqual(snapshot.callIdByUUID[opaqueUUID], descriptor.callId)
    XCTAssertEqual(snapshot.uuidByCallId[descriptor.callId], opaqueUUID)
    XCTAssertEqual(snapshot.incomingCallIdsByUUID[opaqueUUID], descriptor.callId)
  }

  @MainActor
  func testSystemCallCoordinatorAcceptsIncomingCallAnsweredBeforeDecryption() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let opaqueUUID = UUID()
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-answer-before-decrypt-1"
    )
    let acceptExpectation = expectation(description: "accepted system incoming call notification")
    var acceptedCallId: String?
    let observer = NotificationCenter.default.addObserver(
      forName: .didAcceptSystemIncomingCall,
      object: nil,
      queue: .main
    ) { notification in
      acceptedCallId = (notification.userInfo?["descriptor"] as? E2EIncomingCallDescriptor)?.callId
      acceptExpectation.fulfill()
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    coordinator.handleAnswerActionForTesting(uuid: opaqueUUID)
    XCTAssertTrue(coordinator.testingSnapshot().answeredBeforeDecryptUUIDs.contains(opaqueUUID))
    coordinator.recordOpaqueIncomingWakeForTesting(uuid: opaqueUUID)

    let resolvedUUID = coordinator.completeIncomingCallDecryptionForTesting(descriptor)

    wait(for: [acceptExpectation], timeout: 1)
    XCTAssertEqual(resolvedUUID, opaqueUUID)
    XCTAssertEqual(acceptedCallId, descriptor.callId)
    XCTAssertFalse(coordinator.testingSnapshot().answeredBeforeDecryptUUIDs.contains(opaqueUUID))
    XCTAssertEqual(coordinator.takeAcceptedIncomingCalls().map(\.callId), [descriptor.callId])
    XCTAssertTrue(coordinator.takeAcceptedIncomingCalls().isEmpty)
  }

  @MainActor
  func testSystemCallCoordinatorStartsAcceptedSessionWithoutForegroundPresenter() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    coordinator.attach(container: fixture.container)
    defer {
      fixture.container.e2eCallSessionStore.removeAll()
      coordinator.resetForTesting()
    }
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-background-accepted-session-1"
    )

    let uuid = coordinator.storeIncomingCallForTesting(descriptor)
    coordinator.handleAnswerActionForTesting(uuid: uuid)

    let retainedSession = try XCTUnwrap(
      fixture.container.e2eCallSessionStore.session(callId: descriptor.callId)
    )
    XCTAssertTrue(retainedSession.hasSessionTaskForTesting)
    XCTAssertEqual(coordinator.takeAcceptedIncomingCalls().map(\.callId), [descriptor.callId])
  }

  @MainActor
  func testSystemCallCoordinatorDuplicateOfferAfterAcceptDoesNotRestoreUnansweredState() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-duplicate-after-accept-1"
    )

    let uuid = coordinator.storeIncomingCallForTesting(descriptor)
    coordinator.handleAnswerActionForTesting(uuid: uuid)
    XCTAssertEqual(coordinator.takeAcceptedIncomingCalls().map(\.callId), [descriptor.callId])
    XCTAssertNil(coordinator.testingSnapshot().incomingCallIdsByUUID[uuid])

    let duplicateUUID = coordinator.storeIncomingCallForTesting(descriptor)

    var snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(duplicateUUID, uuid)
    XCTAssertEqual(snapshot.callIdByUUID[uuid], descriptor.callId)
    XCTAssertEqual(snapshot.uuidByCallId[descriptor.callId], uuid)
    XCTAssertNil(snapshot.incomingCallIdsByUUID[uuid])
    XCTAssertTrue(snapshot.acceptedCallIds.isEmpty)

    coordinator.handleEndActionForTesting(uuid: uuid)

    snapshot = coordinator.testingSnapshot()
    XCTAssertNil(snapshot.callIdByUUID[uuid])
    XCTAssertNil(snapshot.uuidByCallId[descriptor.callId])
    XCTAssertNil(snapshot.incomingCallIdsByUUID[uuid])
  }

  @MainActor
  func testSystemCallCoordinatorEndBeforeDecryptionClearsAnsweredOpaqueWake() {
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let opaqueUUID = UUID()

    coordinator.handleAnswerActionForTesting(uuid: opaqueUUID)
    XCTAssertTrue(coordinator.testingSnapshot().answeredBeforeDecryptUUIDs.contains(opaqueUUID))

    coordinator.handleEndActionForTesting(uuid: opaqueUUID)

    let snapshot = coordinator.testingSnapshot()
    XCTAssertFalse(snapshot.answeredBeforeDecryptUUIDs.contains(opaqueUUID))
    XCTAssertTrue(snapshot.callIdByUUID.isEmpty)
    XCTAssertTrue(snapshot.uuidByCallId.isEmpty)
    XCTAssertTrue(snapshot.incomingCallIdsByUUID.isEmpty)
  }

  @MainActor
  func testSystemCallCoordinatorEndActionPostsEndAndClearsIncomingMapping() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let descriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-end-action-1"
    )
    let endExpectation = expectation(description: "system call ended notification")
    var endedCallId: String?
    var endedUUID: UUID?
    let observer = NotificationCenter.default.addObserver(
      forName: .didEndSystemCall,
      object: nil,
      queue: .main
    ) { notification in
      endedCallId = notification.userInfo?["call_id"] as? String
      endedUUID = notification.userInfo?["uuid"] as? UUID
      endExpectation.fulfill()
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    let uuid = coordinator.storeIncomingCallForTesting(descriptor)
    XCTAssertEqual(coordinator.testingSnapshot().incomingCallIdsByUUID[uuid], descriptor.callId)

    coordinator.handleEndActionForTesting(uuid: uuid)

    wait(for: [endExpectation], timeout: 1)
    let snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(endedCallId, descriptor.callId)
    XCTAssertEqual(endedUUID, uuid)
    XCTAssertNil(snapshot.callIdByUUID[uuid])
    XCTAssertNil(snapshot.uuidByCallId[descriptor.callId])
    XCTAssertNil(snapshot.incomingCallIdsByUUID[uuid])
  }

  @MainActor
  func testSystemCallCoordinatorProviderResetEndsMappedCallsAndClearsState() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let coordinator = SystemCallCoordinator.shared
    coordinator.resetForTesting()
    defer {
      coordinator.resetForTesting()
    }
    let outgoingUUID = UUID()
    let outgoingCallId = "callkit-reset-outgoing-1"
    let incomingDescriptor = makeIncomingCallDescriptor(
      fixture: fixture,
      systemUUID: UUID(),
      callId: "callkit-reset-incoming-1"
    )
    var endedCalls: [String: UUID] = [:]
    let endExpectation = expectation(description: "system provider reset ended mapped calls")
    endExpectation.expectedFulfillmentCount = 2
    let observer = NotificationCenter.default.addObserver(
      forName: .didEndSystemCall,
      object: nil,
      queue: .main
    ) { notification in
      if let callId: String = notification.userInfo?["call_id"] as? String,
        let uuid: UUID = notification.userInfo?["uuid"] as? UUID
      {
        endedCalls[callId] = uuid
      }
      endExpectation.fulfill()
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    coordinator.recordOutgoingCallForTesting(callId: outgoingCallId, uuid: outgoingUUID)
    let incomingUUID = coordinator.storeIncomingCallForTesting(incomingDescriptor)
    coordinator.setProviderAudioSessionActiveForTesting(true)
    XCTAssertTrue(coordinator.testingSnapshot().providerAudioSessionActive)

    coordinator.handleProviderResetForTesting()

    wait(for: [endExpectation], timeout: 1)
    let snapshot = coordinator.testingSnapshot()
    XCTAssertEqual(endedCalls[outgoingCallId], outgoingUUID)
    XCTAssertEqual(endedCalls[incomingDescriptor.callId], incomingUUID)
    XCTAssertTrue(snapshot.callIdByUUID.isEmpty)
    XCTAssertTrue(snapshot.uuidByCallId.isEmpty)
    XCTAssertTrue(snapshot.incomingCallIdsByUUID.isEmpty)
    XCTAssertTrue(snapshot.opaqueIncomingUUIDs.isEmpty)
    XCTAssertTrue(snapshot.answeredBeforeDecryptUUIDs.isEmpty)
    XCTAssertTrue(snapshot.acceptedCallIds.isEmpty)
    XCTAssertFalse(snapshot.providerAudioSessionActive)
  }

  @MainActor
  func testRapidCallMediaControlChangesSendLatestStateOnce() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-controls-coalesced-media-state-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    viewModel.setMuted(true)
    viewModel.setCameraEnabled(false)
    XCTAssertTrue(viewModel.isMuted)
    XCTAssertFalse(viewModel.isCameraEnabled)
    XCTAssertTrue(viewModel.hasPendingMediaStateTaskForTesting)

    let mediaStateSent = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callMediaState }.count == 1
    }
    XCTAssertTrue(mediaStateSent, "Coalesced media-state send did not finish")
    XCTAssertFalse(viewModel.hasPendingMediaStateTaskForTesting)

    try? await Task.sleep(nanoseconds: 300_000_000)
    let mediaStateMessages = fixture.viewModel.messages.filter { $0.type == .callMediaState }
    XCTAssertEqual(mediaStateMessages.count, 1)
    let mediaStatePayload = try jsonObject(from: try XCTUnwrap(mediaStateMessages.first).content)
    XCTAssertEqual(mediaStatePayload["call_id"] as? String, callId)
    XCTAssertEqual(mediaStatePayload["microphone_enabled"] as? Bool, false)
    XCTAssertEqual(mediaStatePayload["camera_enabled"] as? Bool, false)
  }

  @MainActor
  func testFinishedCallSessionCancelsPendingMediaStateSend() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-controls-cancel-pending-state-1")
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    viewModel.setMuted(true)
    XCTAssertTrue(viewModel.hasPendingMediaStateTaskForTesting)

    viewModel.finishForLocalSessionClear()
    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertFalse(viewModel.hasPendingMediaStateTaskForTesting)

    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertTrue(fixture.networkClient.requests.isEmpty)
    XCTAssertTrue(fixture.viewModel.messages.filter { $0.type == .callMediaState }.isEmpty)
  }

  @MainActor
  func testCallSessionMuteAndCameraControlsSendEncryptedMediaState() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-controls-media-state-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)
    try enqueueSuccessfulExistingSessionSendResponses(fixture: fixture)

    viewModel.setMuted(true)
    XCTAssertTrue(viewModel.isMuted)
    let muteMediaStateSent = await waitUntil { fixture.networkClient.requests.count >= 4 }
    XCTAssertTrue(muteMediaStateSent, "Mute media-state send did not finish")

    let muteMessage = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.type == .callMediaState }))
    let mutePayload = try jsonObject(from: muteMessage.content)
    XCTAssertEqual(mutePayload["call_id"] as? String, callId)
    XCTAssertEqual(mutePayload["microphone_enabled"] as? Bool, false)
    XCTAssertEqual(mutePayload["camera_enabled"] as? Bool, true)
    XCTAssertTrue(fixture.viewModel.visibleMessages().isEmpty)

    viewModel.setCameraEnabled(false)
    XCTAssertFalse(viewModel.isCameraEnabled)
    let cameraMediaStateSent = await waitUntil { fixture.networkClient.requests.count >= 7 }
    XCTAssertTrue(cameraMediaStateSent, "Camera media-state send did not finish")

    let mediaStateMessages = fixture.viewModel.messages
      .filter { $0.type == .callMediaState }
      .sorted(by: { $0.createdAt < $1.createdAt })
    XCTAssertEqual(mediaStateMessages.count, 2)
    let cameraPayload = try jsonObject(from: try XCTUnwrap(mediaStateMessages.last).content)
    XCTAssertEqual(cameraPayload["call_id"] as? String, callId)
    XCTAssertEqual(cameraPayload["microphone_enabled"] as? Bool, false)
    XCTAssertEqual(cameraPayload["camera_enabled"] as? Bool, false)
  }

  @MainActor
  func testCallSessionMediaStateRetriesAfterPeerDeliveryFailure() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-controls-media-state-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.mediaStatePeerDeliveryRetryDelaysOverrideForTesting = [0]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": sendAttemptCount == 1 ? "unavailable" : "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] == "queued_local" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    viewModel.setMuted(true)

    let retried = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callMediaState }.count == 2
    }
    XCTAssertTrue(retried, "media-state retry did not finish")
    XCTAssertEqual(sendAttemptCount, 2)
    XCTAssertFalse(viewModel.hasPendingMediaStateTaskForTesting)
    XCTAssertEqual(
      fixture.viewModel.messages.filter { $0.type == .callMediaState && $0.transportState == .accepted }.count,
      1
    )
  }

  @MainActor
  func testCallSessionMediaStateRetrySendsLatestStateAfterControlChanges() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-controls-media-state-latest-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.mediaStatePeerDeliveryRetryDelaysOverrideForTesting = [0.2]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": sendAttemptCount == 1 ? "unavailable" : "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] == "queued_local" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    viewModel.setMuted(true)
    let firstFailed = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callMediaState }.count == 1
    }
    XCTAssertTrue(firstFailed, "initial media-state attempt did not finish")

    viewModel.setCameraEnabled(false)

    let secondSent = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callMediaState }.count == 2
    }
    XCTAssertTrue(secondSent, "latest media-state send did not finish")

    let acceptedMessage = try XCTUnwrap(
      fixture.viewModel.messages.first { $0.type == .callMediaState && $0.transportState == .accepted }
    )
    let payload = try jsonObject(from: acceptedMessage.content)
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(payload["microphone_enabled"] as? Bool, false)
    XCTAssertEqual(payload["camera_enabled"] as? Bool, false)
  }

  @MainActor
  func testCallSessionAnswerRetriesAfterPeerDeliveryFailure() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-answer-delivery-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.callAnswerPeerDeliveryRetryDelaysOverrideForTesting = [0]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let answerSDP = sdpWithDTLSFingerprint()
    let answer = CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: fixture.localUserId,
      type: "answer",
      sdp: answerSDP,
      dtlsFingerprint: testDTLSFingerprint(),
      answerToOfferId: "offer-generation-for-answer-retry"
    )
    var sendAttemptCount = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": sendAttemptCount == 1 ? "unavailable" : "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] == "queued_local" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let deliveredImmediately: Bool = try await viewModel.sendCallAnswerForTesting(answer)

    XCTAssertFalse(deliveredImmediately)
    XCTAssertEqual(viewModel.pendingCallAnswerRetryCountForTesting, 1)
    XCTAssertEqual(sendAttemptCount, 1)

    await viewModel.flushPendingCallAnswerForTesting()

    XCTAssertEqual(sendAttemptCount, 2)
    XCTAssertEqual(viewModel.pendingCallAnswerRetryCountForTesting, 0)
    XCTAssertEqual(
      fixture.viewModel.messages.filter { $0.type == .callAnswer && $0.transportState == .accepted }.count,
      1
    )
    let acceptedAnswerMessage = try XCTUnwrap(
      fixture.viewModel.messages.first { $0.type == .callAnswer && $0.transportState == .accepted }
    )
    let payload = try jsonObject(from: acceptedAnswerMessage.content)
    let answerPayload = try XCTUnwrap(payload["answer"] as? [String: Any])
    XCTAssertEqual(payload["call_id"] as? String, callId)
    XCTAssertEqual(payload["dtls_fingerprint"] as? String, testDTLSFingerprint())
    XCTAssertEqual(answerPayload["type"] as? String, "answer")
    XCTAssertEqual(answerPayload["sdp"] as? String, answerSDP)
    XCTAssertEqual(
      answerPayload["answer_to_offer_id"] as? String,
      "offer-generation-for-answer-retry"
    )
    let retryAnswerIds: [String] = try fixture.viewModel.messages
      .filter { $0.type == .callAnswer }
      .map { message in
        let retryPayload = try jsonObject(from: message.content)
        let retryAnswer = try XCTUnwrap(retryPayload["answer"] as? [String: Any])
        return try XCTUnwrap(retryAnswer["answer_to_offer_id"] as? String)
      }
    XCTAssertEqual(retryAnswerIds, [
      "offer-generation-for-answer-retry",
      "offer-generation-for-answer-retry",
    ])
    XCTAssertTrue(fixture.viewModel.visibleMessages().isEmpty)
  }

  @MainActor
  func testPendingCallAnswerRetryIsClearedWhenSessionFinishes() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-answer-delivery-finish-clear-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.callAnswerPeerDeliveryRetryDelaysOverrideForTesting = [0]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    let answer = CallSessionDescriptionSignal(
      callId: callId,
      fromUserId: fixture.localUserId,
      type: "answer",
      sdp: sdpWithDTLSFingerprint(),
      dtlsFingerprint: testDTLSFingerprint()
    )
    var sendAttemptCount = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "unavailable",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": 0,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let deliveredImmediately: Bool = try await viewModel.sendCallAnswerForTesting(answer)

    XCTAssertFalse(deliveredImmediately)
    XCTAssertEqual(sendAttemptCount, 1)
    XCTAssertEqual(viewModel.pendingCallAnswerRetryCountForTesting, 1)

    viewModel.finishForLocalSessionClear()
    await viewModel.flushPendingCallAnswerForTesting()

    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertEqual(viewModel.pendingCallAnswerRetryCountForTesting, 0)
    XCTAssertEqual(sendAttemptCount, 1)
  }

  @MainActor
  func testCallSessionEndFromUserSendsCallEndAndFinishesOnce() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-user-ended-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let finishExpectation = expectation(description: "call session finished")
    var finishCount = 0

    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)
    viewModel.onFinished = {
      finishCount += 1
      finishExpectation.fulfill()
    }

    await viewModel.endFromUser()
    await fulfillment(of: [finishExpectation], timeout: 1)
    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertEqual(viewModel.statusText, "Звонок завершен")
    XCTAssertEqual(finishCount, 1)

    let callEndMessage = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.type == .callEnd }))
    let callEndPayload = try jsonObject(from: callEndMessage.content)
    XCTAssertEqual(callEndPayload["call_id"] as? String, callId)
    XCTAssertEqual(callEndPayload["status"] as? String, "ended")
    XCTAssertTrue(fixture.viewModel.visibleMessages().isEmpty)

    await viewModel.endFromUser()
    XCTAssertEqual(finishCount, 1)
    XCTAssertEqual(fixture.viewModel.messages.filter { $0.type == .callEnd }.count, 1)
  }

  @MainActor
  func testCallSessionEndFromUserRetriesCallEndAfterPeerDeliveryFailure() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-user-ended-retry-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.callEndPeerDeliveryRetryDelaysOverrideForTesting = [0]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    var sendAttemptCount = 0

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      sendAttemptCount += 1
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": sendAttemptCount == 1 ? "unavailable" : "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.filter { $0["status"] == "queued_local" }.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    await viewModel.endFromUser()

    XCTAssertEqual(viewModel.state, .ended)
    let retried = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callEnd }.count == 2
    }
    XCTAssertTrue(retried, "call_end retry did not finish")
    XCTAssertEqual(sendAttemptCount, 2)
    XCTAssertEqual(
      fixture.viewModel.messages.filter { $0.type == .callEnd && $0.transportState == .accepted }.count,
      1
    )
  }

  @MainActor
  func testCallSessionEndFromUserStillFinishesWhenCallEndPeerDeliveryFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let callId = "call-user-ended-peer-fail-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    viewModel.callEndPeerDeliveryRetryDelaysOverrideForTesting = [0]
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)

    fixture.networkClient.registerFallbackResponder { [self] request in
      guard let path: String = request.url?.path else {
        return nil
      }

      if path.hasSuffix("/api/prekeys/get") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([peerBundle])
        )
      }

      if path.hasSuffix("/api/prekeys/self") {
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([])
        )
      }

      guard path.hasSuffix("/api/messages/send") else {
        return nil
      }

      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "unavailable",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": 0,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    await viewModel.endFromUser()

    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertEqual(viewModel.statusText, "Звонок завершен")
    let retried = await waitUntil {
      fixture.viewModel.messages.filter { $0.type == .callEnd }.count == 2
    }
    XCTAssertTrue(retried, "call_end retry did not finish")
    XCTAssertEqual(
      fixture.viewModel.messages.filter { $0.type == .callEnd && $0.transportState == .failed }.count,
      2
    )
  }

  @MainActor
  func testPictureInPictureRestorePostsActiveCallInterfaceRequest() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-restore-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let restoreExpectation = expectation(description: "PiP restore notification")

    var observedCallId: String?
    var completionResult: Bool?
    let observer = NotificationCenter.default.addObserver(
      forName: .didRequestActiveCallInterfaceRestore,
      object: nil,
      queue: .main
    ) { notification in
      observedCallId = notification.userInfo?["call_id"] as? String
      let completion: ((Bool) -> Void)? = notification.userInfo?["completion"] as? (Bool) -> Void
      completion?(true)
      restoreExpectation.fulfill()
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    let sourceView = UIView()
    let contentController = AVPictureInPictureVideoCallViewController()
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: sourceView,
      contentViewController: contentController
    )
    let avPictureInPictureController = AVPictureInPictureController(contentSource: contentSource)

    pictureInPictureController.pictureInPictureController(
      avPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
        completionResult = restored
      }
    )

    wait(for: [restoreExpectation], timeout: 1)
    XCTAssertEqual(observedCallId, "call-pip-restore-1")
    XCTAssertEqual(completionResult, true)
  }

  @MainActor
  func testPictureInPictureRestoreCompletesFalseWhenSessionHasBeenReleased() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    var viewModel: E2ECallSessionViewModel? = makeCallSessionViewModel(
      fixture: fixture,
      callId: "call-pip-restore-released-1"
    )
    let pictureInPictureController = E2ECallPictureInPictureController(session: try XCTUnwrap(viewModel))
    let sourceView = UIView()
    let contentController = AVPictureInPictureVideoCallViewController()
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: sourceView,
      contentViewController: contentController
    )
    let avPictureInPictureController = AVPictureInPictureController(contentSource: contentSource)
    var completionResult: Bool?

    viewModel = nil

    pictureInPictureController.pictureInPictureController(
      avPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
        completionResult = restored
      }
    )

    XCTAssertEqual(completionResult, false)
  }

  @MainActor
  func testChatsCoordinatorRestoreActiveCallInterfaceReturnsFalseForMissingSession() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let navigationController = UINavigationController(rootViewController: UIViewController())
    let coordinator = ChatsCoordinator(navigationController: navigationController, container: fixture.container)
    var restoreResult: Bool?

    coordinator.restoreActiveCallInterfaceForTesting(callId: "missing-call-id") { restored in
      restoreResult = restored
    }

    XCTAssertEqual(restoreResult, false)
    XCTAssertEqual(navigationController.viewControllers.count, 1)
  }

  @MainActor
  func testChatsCoordinatorRestoreActiveCallInterfacePresentsRetainedSession() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let navigationController = UINavigationController(rootViewController: UIViewController())
    let coordinator = ChatsCoordinator(navigationController: navigationController, container: fixture.container)
    let callId = "call-restore-retained-session-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    var presentationRequests: Int = 0
    var restoreResult: Bool?

    coordinator.onCallPresentationRequested = {
      presentationRequests += 1
    }
    fixture.container.e2eCallSessionStore.retain(viewModel)

    coordinator.restoreActiveCallInterfaceForTesting(callId: callId) { restored in
      restoreResult = restored
    }

    XCTAssertEqual(restoreResult, true)
    XCTAssertEqual(presentationRequests, 1)
    XCTAssertTrue(navigationController.topViewController is E2ECallViewController)
    XCTAssertEqual(
      navigationController.viewControllers.compactMap { $0 as? E2ECallViewController }.map(\.activeCallId),
      [callId]
    )
  }

  @MainActor
  func testChatsCoordinatorRestoreActiveCallInterfaceReusesExistingCallScreen() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let navigationController = UINavigationController(rootViewController: UIViewController())
    let coordinator = ChatsCoordinator(navigationController: navigationController, container: fixture.container)
    let callId = "call-restore-existing-screen-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    var firstRestoreResult: Bool?
    var secondRestoreResult: Bool?

    fixture.container.e2eCallSessionStore.retain(viewModel)
    coordinator.restoreActiveCallInterfaceForTesting(callId: callId) { restored in
      firstRestoreResult = restored
    }
    let firstCallScreen = try XCTUnwrap(navigationController.topViewController as? E2ECallViewController)

    navigationController.pushViewController(UIViewController(), animated: false)
    XCTAssertFalse(navigationController.topViewController === firstCallScreen)

    coordinator.restoreActiveCallInterfaceForTesting(callId: callId) { restored in
      secondRestoreResult = restored
    }

    XCTAssertEqual(firstRestoreResult, true)
    XCTAssertEqual(secondRestoreResult, true)
    XCTAssertTrue(navigationController.topViewController === firstCallScreen)
    XCTAssertEqual(
      navigationController.viewControllers.compactMap { $0 as? E2ECallViewController }.count,
      1
    )
  }

  @MainActor
  func testChatsCoordinatorPictureInPictureRestoreDoesNotRestartRetainedSession() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let navigationController = UINavigationController()
    let coordinator = ChatsCoordinator(navigationController: navigationController, container: fixture.container)
    let callId = "call-restore-no-restart-1"
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: callId)
    let restoreExpectation = expectation(description: "production PiP restore completed")
    var restoreResult: Bool?

    coordinator.start()
    fixture.container.e2eCallSessionStore.retain(viewModel)

    NotificationCenter.default.post(
      name: .didRequestActiveCallInterfaceRestore,
      object: nil,
      userInfo: [
        "call_id": callId,
        "completion": { restored in
          restoreResult = restored
          restoreExpectation.fulfill()
        } as (Bool) -> Void,
      ]
    )

    await fulfillment(of: [restoreExpectation], timeout: 1)
    let callScreen = try XCTUnwrap(navigationController.topViewController as? E2ECallViewController)
    callScreen.loadViewIfNeeded()

    XCTAssertEqual(restoreResult, true)
    XCTAssertFalse(viewModel.hasSessionTaskForTesting)
  }

  @MainActor
  func testPictureInPictureRendererAttachesForPiPStartAndDetachesOnStop() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-renderer-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    var didStartCount: Int = 0
    var didStopCount: Int = 0
    let sourceView = UIView()
    let contentController = AVPictureInPictureVideoCallViewController()
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: sourceView,
      contentViewController: contentController
    )
    let avPictureInPictureController = AVPictureInPictureController(contentSource: contentSource)

    viewModel.onPictureInPictureDidStart = {
      didStartCount += 1
    }
    viewModel.onPictureInPictureDidStop = {
      didStopCount += 1
    }

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertFalse(pictureInPictureController.isRendererAttachedForTesting)

    pictureInPictureController.pictureInPictureControllerWillStartPictureInPicture(avPictureInPictureController)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    XCTAssertEqual(didStartCount, 0)

    pictureInPictureController.pictureInPictureControllerWillStartPictureInPicture(avPictureInPictureController)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)

    pictureInPictureController.pictureInPictureControllerDidStartPictureInPicture(avPictureInPictureController)
    XCTAssertEqual(didStartCount, 1)

    pictureInPictureController.pictureInPictureControllerDidStopPictureInPicture(avPictureInPictureController)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    XCTAssertEqual(didStopCount, 1)

    pictureInPictureController.pictureInPictureControllerWillStartPictureInPicture(avPictureInPictureController)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    pictureInPictureController.stopAndRelease()
    XCTAssertFalse(pictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureRendererAttachedBeforeEngineCreationIsRetainedForLaterEngine() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-pre-engine-renderer-1")
    let localRenderer = RTCMTLVideoView()
    let inlineRemoteRenderer = RTCMTLVideoView()
    let pictureInPictureRenderer = RTCMTLVideoView()

    viewModel.attachVideoRenderers(local: localRenderer, remote: inlineRemoteRenderer)
    viewModel.attachAdditionalRemoteVideoRenderer(pictureInPictureRenderer)
    viewModel.attachAdditionalRemoteVideoRenderer(pictureInPictureRenderer)

    XCTAssertEqual(viewModel.additionalRemoteVideoRendererCountForTesting, 1)

    let rendererManager = SpyCallVideoRendererManager()
    viewModel.attachStoredVideoRenderersForTesting(to: rendererManager)

    XCTAssertEqual(rendererManager.localAttachCount(for: localRenderer), 1)
    XCTAssertEqual(rendererManager.remoteAttachCount(for: inlineRemoteRenderer), 1)
    XCTAssertEqual(rendererManager.remoteAttachCount(for: pictureInPictureRenderer), 1)

    viewModel.detachRemoteVideoRenderer(pictureInPictureRenderer)
    XCTAssertEqual(viewModel.additionalRemoteVideoRendererCountForTesting, 0)

    let rendererManagerAfterDetach = SpyCallVideoRendererManager()
    viewModel.attachStoredVideoRenderersForTesting(to: rendererManagerAfterDetach)

    XCTAssertEqual(rendererManagerAfterDetach.remoteAttachCount(for: inlineRemoteRenderer), 1)
    XCTAssertEqual(rendererManagerAfterDetach.remoteAttachCount(for: pictureInPictureRenderer), 0)
  }

  @MainActor
  func testPictureInPictureStartRequestIsIdempotentUntilDelegateCallback() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-start-race-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let sourceView = UIView()
    let contentController = AVPictureInPictureVideoCallViewController()
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: sourceView,
      contentViewController: contentController
    )
    let avPictureInPictureController = AVPictureInPictureController(contentSource: contentSource)

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertTrue(pictureInPictureController.beginStartRequestForTesting(isActive: false, isPossible: true))
    XCTAssertTrue(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertFalse(pictureInPictureController.beginStartRequestForTesting(isActive: false, isPossible: true))
    XCTAssertFalse(pictureInPictureController.beginStartRequestForTesting(isActive: true, isPossible: true))

    pictureInPictureController.pictureInPictureControllerWillStartPictureInPicture(avPictureInPictureController)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    pictureInPictureController.pictureInPictureControllerDidStartPictureInPicture(avPictureInPictureController)
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)

    XCTAssertTrue(pictureInPictureController.beginStartRequestForTesting(isActive: false, isPossible: true))
    pictureInPictureController.pictureInPictureController(
      avPictureInPictureController,
      failedToStartPictureInPictureWithError: NSError(domain: "PiPStartRaceTest", code: 1)
    )
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureStartIfPossibleDefersWhenControllerIsTemporarilyImpossible() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-deferred-start-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    var startCount = 0

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertFalse(
      pictureInPictureController.startIfPossibleForTesting(isActive: false, isPossible: false)
    )
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)

    XCTAssertTrue(
      pictureInPictureController.startDeferredRequestIfPossibleForTesting(
        isActive: false,
        isPossible: true,
        startPictureInPicture: {
          startCount += 1
        }
      )
    )
    XCTAssertEqual(startCount, 1)
    XCTAssertFalse(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureDiagnosticsRetainEventHistoryForPhysicalValidation() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-diagnostics-history-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertFalse(
      pictureInPictureController.startIfPossibleForTesting(isActive: false, isPossible: false)
    )
    XCTAssertTrue(
      pictureInPictureController.startDeferredRequestIfPossibleForTesting(
        isActive: false,
        isPossible: true
      )
    )
    pictureInPictureController.pictureInPictureControllerDidStartPictureInPicture(
      AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: UIView(),
        contentViewController: AVPictureInPictureVideoCallViewController()
      ))
    )

    let summary = viewModel.pictureInPictureDiagnosticsSummary
    XCTAssertTrue(summary.contains("events="))
    XCTAssertTrue(summary.contains("call_pip_start_deferred"))
    XCTAssertTrue(summary.contains("call_pip_start_begin"))
    XCTAssertTrue(summary.contains("call_pip_did_start"))
  }

  @MainActor
  func testPictureInPictureStartIfPossibleStartsImmediatelyWhenPossible() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-start-immediate-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    var startCount = 0

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true,
        startPictureInPicture: {
          startCount += 1
        }
      )
    )
    XCTAssertEqual(startCount, 1)
    XCTAssertFalse(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)

    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true,
        startPictureInPicture: {
          startCount += 1
        }
      )
    )
    XCTAssertEqual(startCount, 1)
    XCTAssertTrue(pictureInPictureController.hasStartRequestInFlightForTesting)
  }

  @MainActor
  func testPictureInPictureConfigureSkipsContentSourceMutationWhileStartIsInFlight() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("System Picture in Picture support is unavailable in this test environment.")
    }

    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-skip-reconfigure-inflight-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

    pictureInPictureController.configure(sourceView: sourceView)
    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true
      )
    )

    pictureInPictureController.configure(sourceView: sourceView)

    XCTAssertTrue(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_reconfigure_skipped"))
  }

  @MainActor
  func testPictureInPictureConfigureReusesContentSourceForStableVideoCallSource() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("System Picture in Picture support is unavailable in this test environment.")
    }

    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-reuse-source-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    let rootViewController = UIViewController()
    let sourceView = UIView(frame: window.bounds)

    rootViewController.view.addSubview(sourceView)
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
    }

    pictureInPictureController.configure(sourceView: sourceView)
    pictureInPictureController.configure(sourceView: sourceView)

    XCTAssertTrue(viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_reconfigure_reused"))
    XCTAssertFalse(viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_reconfigured"))
  }

  @MainActor
  func testPictureInPictureStartWatchdogFailsClosedAfterSilentAVKitStart() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-watchdog-retry-1")
    let pictureInPictureController = E2ECallPictureInPictureController(
      session: viewModel,
      startRequestWatchdogDelayNanoseconds: 20_000_000
    )
    let failedExpectation = expectation(description: "PiP silent start failed closed")
    var startCount = 0

    viewModel.onPictureInPictureStartFailed = {
      failedExpectation.fulfill()
    }
    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true,
        startPictureInPicture: {
          startCount += 1
        }
      )
    )
    XCTAssertEqual(startCount, 1)

    pictureInPictureController.fireStartRequestWatchdogForTesting(
      isActive: false,
      isPossible: true
    )

    await fulfillment(of: [failedExpectation], timeout: 1)
    XCTAssertEqual(startCount, 1)
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertFalse(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    let summary = viewModel.pictureInPictureDiagnosticsSummary
    XCTAssertTrue(summary.contains("call_pip_start_timed_out"))
    XCTAssertTrue(summary.contains("source=test"))
    XCTAssertTrue(summary.contains("manual_watchdog_timeout"))
  }

  @MainActor
  func testPictureInPictureStartWatchdogFailsClosedAfterTimeout() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-watchdog-failed-1")
    let pictureInPictureController = E2ECallPictureInPictureController(
      session: viewModel,
      startRequestWatchdogDelayNanoseconds: 10_000_000
    )
    let failedExpectation = expectation(description: "PiP silent start failed closed")

    viewModel.onPictureInPictureStartFailed = {
      failedExpectation.fulfill()
    }
    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())

    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true
      )
    )

    pictureInPictureController.fireStartRequestWatchdogForTesting()
    await fulfillment(of: [failedExpectation], timeout: 1)
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertFalse(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    XCTAssertTrue(viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_start_timed_out"))
  }

  @MainActor
  func testPictureInPictureDiagnosticsExposeRuntimeBlockerContextWhenConfigured() throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("System Picture in Picture support is unavailable in this test environment.")
    }

    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-diagnostics-context-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

    pictureInPictureController.configure(sourceView: sourceView)
    XCTAssertTrue(
      pictureInPictureController.startIfPossibleForTesting(
        isActive: false,
        isPossible: true,
        source: "diagnostic_test"
      )
    )
    pictureInPictureController.fireStartRequestWatchdogForTesting()

    let summary = pictureInPictureController.diagnosticsSummary
    XCTAssertTrue(summary.contains("lastFailure="))
    XCTAssertTrue(summary.contains("manual_watchdog_timeout"))
    XCTAssertTrue(summary.contains("inferred=manual_start_no_avkit_delegate_callback"))
    XCTAssertTrue(summary.contains("system="))
    XCTAssertTrue(summary.contains("callkit="))
    XCTAssertTrue(summary.contains("content="))
  }

  @MainActor
  func testPictureInPictureDeferredStartDoesNotRunUntilPossible() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-deferred-not-possible-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    var startCount = 0

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertFalse(pictureInPictureController.startIfPossibleForTesting(isActive: false, isPossible: false))
    XCTAssertFalse(
      pictureInPictureController.startDeferredRequestIfPossibleForTesting(
        isActive: false,
        isPossible: false,
        startPictureInPicture: {
          startCount += 1
        }
      )
    )

    XCTAssertEqual(startCount, 0)
    XCTAssertTrue(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureStopAndReleaseClearsDeferredStartAndRendererState() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-release-clears-deferred-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertFalse(pictureInPictureController.startIfPossibleForTesting(isActive: false, isPossible: false))
    XCTAssertTrue(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)

    pictureInPictureController.stopAndRelease()

    XCTAssertFalse(pictureInPictureController.hasDeferredStartRequestForTesting)
    XCTAssertFalse(pictureInPictureController.hasStartRequestInFlightForTesting)
    XCTAssertFalse(pictureInPictureController.isRendererAttachedForTesting)
    XCTAssertFalse(
      pictureInPictureController.startDeferredRequestIfPossibleForTesting(isActive: false, isPossible: true)
    )
  }

  @MainActor
  func testPictureInPictureStartRepairsRendererForActiveOrInflightSession() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let activeViewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-active-repair-1")
    let activePictureInPictureController = E2ECallPictureInPictureController(session: activeViewModel)

    activePictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertTrue(
      activePictureInPictureController.startIfPossibleForTesting(isActive: true, isPossible: false)
    )
    XCTAssertTrue(activePictureInPictureController.isRendererAttachedForTesting)

    let inflightViewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-inflight-repair-1")
    let inflightPictureInPictureController = E2ECallPictureInPictureController(session: inflightViewModel)

    inflightPictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertTrue(inflightPictureInPictureController.beginStartRequestForTesting(isActive: false, isPossible: true))
    XCTAssertFalse(inflightPictureInPictureController.isRendererAttachedForTesting)
    XCTAssertTrue(
      inflightPictureInPictureController.startIfPossibleForTesting(isActive: false, isPossible: true)
    )
    XCTAssertTrue(inflightPictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureDidStartRepairsRendererWhenWillStartWasMissed() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-did-start-repair-1")
    let pictureInPictureController = E2ECallPictureInPictureController(session: viewModel)
    let sourceView = UIView()
    let contentController = AVPictureInPictureVideoCallViewController()
    let contentSource = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: sourceView,
      contentViewController: contentController
    )
    let avPictureInPictureController = AVPictureInPictureController(contentSource: contentSource)

    pictureInPictureController.installRemoteVideoRendererForTesting(RTCMTLVideoView())
    XCTAssertFalse(pictureInPictureController.isRendererAttachedForTesting)

    pictureInPictureController.pictureInPictureControllerDidStartPictureInPicture(avPictureInPictureController)

    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
  }

  @MainActor
  func testPictureInPictureConfigureUsesSampleBufferVideoRenderer() async throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("System Picture in Picture support is unavailable in this test environment.")
    }

    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-sample-buffer-config-1")
    let pictureInPictureController = E2ECallPictureInPictureController(
      session: viewModel,
      contentSourceModeOverride: "video_call"
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    let rootViewController = UIViewController()
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    rootViewController.view.addSubview(sourceView)
    window.rootViewController = rootViewController
    window.isHidden = false

    pictureInPictureController.configure(sourceView: sourceView)

    let renderer = try XCTUnwrap(pictureInPictureController.sampleBufferVideoRendererForTesting)
    let sampleBufferSuperview = try XCTUnwrap(pictureInPictureController.sampleBufferDisplaySuperviewForTesting)
    XCTAssertFalse(sampleBufferSuperview === sourceView)
    XCTAssertTrue(renderer.displayView.superview === sampleBufferSuperview)
    XCTAssertEqual(renderer.displayView.sampleBufferDisplayLayer.videoGravity, .resizeAspect)
    XCTAssertNil(renderer.displayView.sampleBufferDisplayLayer.controlTimebase)
    XCTAssertTrue(pictureInPictureController.isRendererAttachedForTesting)
    XCTAssertEqual(pictureInPictureController.contentSourceKindForTesting, "video_call")
    XCTAssertEqual(pictureInPictureController.sampleBufferDisplayHostForTesting, "content")
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("sampleBuffer=true"))
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("source=video_call"))
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("host=content"))
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("preferred=180x320"))
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("layer=status="))

    let didSeedPlaceholderFrame = await waitUntil {
      await MainActor.run {
        renderer.sampleBufferFrameCountForTesting > 0
      }
    }
    XCTAssertTrue(didSeedPlaceholderFrame)
  }

  @MainActor
  func testPictureInPictureConfigureCanUseDirectSampleBufferLayerSource() async throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("System Picture in Picture support is unavailable in this test environment.")
    }

    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-sample-buffer-layer-config-1")
    let pictureInPictureController = E2ECallPictureInPictureController(
      session: viewModel,
      contentSourceModeOverride: "sample_buffer_layer"
    )
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

    pictureInPictureController.configure(sourceView: sourceView)

    let renderer = try XCTUnwrap(pictureInPictureController.sampleBufferVideoRendererForTesting)
    XCTAssertTrue(renderer.displayView.superview === sourceView)
    XCTAssertEqual(renderer.displayView.sampleBufferDisplayLayer.videoGravity, .resizeAspect)
    XCTAssertEqual(pictureInPictureController.contentSourceKindForTesting, "sample_buffer_layer")
    XCTAssertEqual(pictureInPictureController.sampleBufferDisplayHostForTesting, "source")
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("source=sample_buffer_layer"))
    XCTAssertTrue(pictureInPictureController.diagnosticsSummary.contains("host=source"))

    let didSeedPlaceholderFrame = await waitUntil {
      await MainActor.run {
        renderer.sampleBufferFrameCountForTesting > 0
      }
    }
    XCTAssertTrue(didSeedPlaceholderFrame)
  }

  @MainActor
  func testPictureInPictureSampleBufferRendererAcceptsSyntheticWebRTCFrame() async throws {
    let renderer = E2ECallSampleBufferVideoRenderer()
    XCTAssertEqual(renderer.displayView.sampleBufferDisplayLayer.videoGravity, .resizeAspect)
    let pixelBuffer = try makeVideoCallPixelBufferForTesting(width: 48, height: 64)
    let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let rotation = try XCTUnwrap(RTCVideoRotation(rawValue: 0))
    let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: rotation, timeStampNs: 1)

    renderer.setSize(CGSize(width: 48, height: 64))
    renderer.renderFrame(frame)

    let didCreateSampleBuffer = await waitUntil {
      renderer.sampleBufferFrameCountForTesting > 0
    }
    XCTAssertTrue(didCreateSampleBuffer)
    XCTAssertEqual(renderer.droppedFrameCountForTesting, 0)
  }

  @MainActor
  func testVideoCallScreenKeepsInlineRendererUntilPictureInPictureDidStartAfterDisappear() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-disappear-1")
    let controller = E2ECallViewController(viewModel: viewModel)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      true
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertTrue(controller.isDurationTimerActiveForTesting)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()

    XCTAssertEqual(pictureInPictureStartRequests, 1)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)

    viewModel.notifyPictureInPictureDidStart()

    XCTAssertFalse(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)

    controller.beginAppearanceTransition(true, animated: false)
    controller.endAppearanceTransition()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertTrue(controller.isDurationTimerActiveForTesting)
  }

  @MainActor
  func testVideoCallScreenUsesVisibleRootViewAsPictureInPictureSource() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-source-view-1")
    let controller = E2ECallViewController(viewModel: viewModel, shouldAutoStart: false)
    let rootController = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

    window.rootViewController = rootController
    window.makeKeyAndVisible()
    rootController.loadViewIfNeeded()
    controller.loadViewIfNeeded()
    rootController.addChild(controller)
    controller.view.frame = rootController.view.bounds
    rootController.view.addSubview(controller.view)
    controller.didMove(toParent: rootController)
    defer {
      controller.willMove(toParent: nil)
      controller.view.removeFromSuperview()
      controller.removeFromParent()
      window.isHidden = true
    }

    XCTAssertTrue(controller.view.accessibilityIdentifier == MessengerAccessibility.Screen.activeCall)
    let remoteVideoView = controller.remoteVideoViewForTesting
    XCTAssertTrue(remoteVideoView.superview === controller.view)
    let remoteVideoIndex = try XCTUnwrap(controller.view.subviews.firstIndex { $0 === remoteVideoView })
    XCTAssertEqual(remoteVideoIndex, 0)

    viewModel.configurePictureInPicture(sourceView: controller.view)

    XCTAssertTrue(viewModel.pictureInPictureSourceViewForTesting === controller.view)
    XCTAssertFalse(viewModel.pictureInPictureSourceViewForTesting === rootController.view)
    if AVPictureInPictureController.isPictureInPictureSupported() {
      XCTAssertTrue(
        viewModel.pictureInPictureDiagnosticsSummary.contains("identifier=\(MessengerAccessibility.Screen.activeCall)")
      )
    }
  }

  @MainActor
  func testVideoCallScreenPreparesAutomaticPictureInPictureWhenApplicationResignsActive() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-background-1")
    let controller = E2ECallViewController(viewModel: viewModel, shouldAutoStart: false)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    NotificationCenter.default.post(
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    let didPrepareAutomaticStart: Bool = await waitUntil {
      await MainActor.run {
        viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_auto_background_wait")
      }
    }
    XCTAssertTrue(didPrepareAutomaticStart)
    XCTAssertEqual(pictureInPictureStartRequests, 0)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    viewModel.notifyPictureInPictureDidStart()
    XCTAssertFalse(controller.isInlineVideoRendererAttachedForTesting)

    NotificationCenter.default.post(
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    let didReattachInlineRenderer: Bool = await waitUntil {
      await MainActor.run {
        controller.isInlineVideoRendererAttachedForTesting
      }
    }
    XCTAssertTrue(didReattachInlineRenderer)
  }

  @MainActor
  func testVideoCallScreenKeepsInlineRendererWhileWaitingForAutomaticBackgroundPictureInPicture() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-background-unavailable-1")
    let controller = E2ECallViewController(viewModel: viewModel, shouldAutoStart: false)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    NotificationCenter.default.post(
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    let didPrepareAutomaticStart: Bool = await waitUntil {
      await MainActor.run {
        viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_auto_background_wait")
      }
    }
    XCTAssertTrue(didPrepareAutomaticStart)
    XCTAssertEqual(pictureInPictureStartRequests, 0)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
  }

  @MainActor
  func testVideoCallScreenDoesNotRetryPictureInPictureWhenApplicationReturnsActiveAfterBackgroundStartMiss() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-background-retry-1")
    let controller = E2ECallViewController(viewModel: viewModel, shouldAutoStart: false)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    NotificationCenter.default.post(
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    let didPrepareAutomaticStart: Bool = await waitUntil {
      await MainActor.run {
        viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_auto_background_wait")
      }
    }
    XCTAssertTrue(didPrepareAutomaticStart)
    XCTAssertEqual(pictureInPictureStartRequests, 0)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
  }

  @MainActor
  func testVideoCallScreenKeepsInlineRendererWhenAutomaticBackgroundPictureInPictureStartFails() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-background-failed-1")
    let controller = E2ECallViewController(viewModel: viewModel, shouldAutoStart: false)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    NotificationCenter.default.post(
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    let didPrepareAutomaticStart: Bool = await waitUntil {
      await MainActor.run {
        viewModel.pictureInPictureDiagnosticsSummary.contains("call_pip_auto_background_wait")
      }
    }
    XCTAssertTrue(didPrepareAutomaticStart)
    XCTAssertEqual(pictureInPictureStartRequests, 0)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    viewModel.notifyPictureInPictureStartFailed()

    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
  }

  @MainActor
  func testVideoCallScreenKeepsInlineRendererWhenPictureInPictureStartFailsAfterDisappear() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-failed-disappear-1")
    let controller = E2ECallViewController(viewModel: viewModel)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      true
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()

    XCTAssertEqual(pictureInPictureStartRequests, 1)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    viewModel.notifyPictureInPictureStartFailed()

    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)
  }

  @MainActor
  func testVideoCallScreenReattachesInlineRendererWhenPictureInPictureStopsOffscreen() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-stop-offscreen-1")
    let controller = E2ECallViewController(viewModel: viewModel)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      true
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()

    XCTAssertEqual(pictureInPictureStartRequests, 1)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)

    viewModel.notifyPictureInPictureDidStart()
    XCTAssertFalse(controller.isInlineVideoRendererAttachedForTesting)

    viewModel.notifyPictureInPictureDidStop()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)
  }

  @MainActor
  func testVideoCallScreenKeepsInlineRendererWhenPictureInPictureCannotStart() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-pip-unavailable-1")
    let controller = E2ECallViewController(viewModel: viewModel)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      false
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertTrue(controller.isDurationTimerActiveForTesting)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()

    XCTAssertEqual(pictureInPictureStartRequests, 1)
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)

    controller.beginAppearanceTransition(true, animated: false)
    controller.endAppearanceTransition()
    XCTAssertTrue(controller.isInlineVideoRendererAttachedForTesting)
    XCTAssertTrue(controller.isDurationTimerActiveForTesting)
  }

  @MainActor
  func testVideoCallScreenDoesNotStartPictureInPictureAfterSessionFinished() throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let viewModel = makeCallSessionViewModel(fixture: fixture, callId: "call-finished-no-pip-1")
    let controller = E2ECallViewController(viewModel: viewModel)
    var pictureInPictureStartRequests: Int = 0

    viewModel.onPictureInPictureStartRequested = {
      pictureInPictureStartRequests += 1
    }
    viewModel.pictureInPictureStartOverrideForTesting = {
      true
    }

    controller.loadViewIfNeeded()
    XCTAssertTrue(controller.isDurationTimerActiveForTesting)

    viewModel.finishForLocalSessionClear()

    XCTAssertEqual(viewModel.state, .ended)
    XCTAssertFalse(controller.isDurationTimerActiveForTesting)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()

    XCTAssertEqual(pictureInPictureStartRequests, 0)
  }

  @MainActor
  func testFirstInterUserMessageBootstrapsReceiverSessionAndHydratesMessage() async throws {
    let sender = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@alice:example.org",
      peerUserId: "@bob:example.org"
    )
    let senderDeviceIdentity = try XCTUnwrap(
      sender.container.keyMaterialStore.deviceIdentity(for: sender.localUserId)
    )
    let senderBundle = try makePublishedBundle(
      container: sender.container,
      userHandle: sender.localUserId,
      identity: sender.localIdentity,
      deviceIdentity: senderDeviceIdentity
    )
    let receiver = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@bob:example.org",
      peerUserId: "@alice:example.org",
      peekBundleResolver: { requestedUser, requestedDeviceId in
        guard requestedUser == sender.localUserId, requestedDeviceId == sender.localDeviceId else {
          return nil
        }

        return senderBundle
      }
    )
    let receiverDeviceIdentity = try XCTUnwrap(
      receiver.container.keyMaterialStore.deviceIdentity(for: receiver.localUserId)
    )
    let receiverBundle = try makePublishedBundle(
      container: receiver.container,
      userHandle: receiver.localUserId,
      identity: receiver.localIdentity,
      deviceIdentity: receiverDeviceIdentity
    )

    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([receiverBundle]))
    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([receiverBundle]))
    sender.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let sent = try await sender.viewModel.sendText(plaintext: "hello from alice")
    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sender.networkClient.requests.count, 4)

    let sendPayload = try requestJSONBody(sender.networkClient.requests[3])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    let receiverDelivery = try XCTUnwrap(deliveries.first { delivery in
      (delivery["to_user"] as? String) == receiver.localUserId
    })
    let ciphertextBlob = try XCTUnwrap(receiverDelivery["ciphertext_blob"] as? String)
    let messageId = try XCTUnwrap(receiverDelivery["message_id"] as? String)
    let deliveryId = try XCTUnwrap(receiverDelivery["delivery_id"] as? String)
    let rawEnvelopeData = try XCTUnwrap(Data(base64Encoded: ciphertextBlob))
    let rawEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: rawEnvelopeData) as? [String: Any])

    XCTAssertEqual(rawEnvelope["sender_device_dh_pub"] as? String, senderDeviceIdentity.dkDhPublic)
    XCTAssertNotNil(rawEnvelope["bootstrap_dh_pub"] as? String)

    let envelope = try sender.container.envelopeService.decodeEnvelope(ciphertextBlob: ciphertextBlob)
    XCTAssertEqual(envelope.kind, .prekeyInit)
    XCTAssertEqual(
      envelope.senderDeviceDhPub,
      senderDeviceIdentity.dkDhPublic
    )
    XCTAssertEqual(envelope.ephemeralPub, rawEnvelope["bootstrap_dh_pub"] as? String)

    receiver.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-receiver",
      ownerDeviceId: receiver.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: deliveryId,
      ciphertextBlob: ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
    let receiverPrekeyStore = try XCTUnwrap(receiver.container.prekeyPrivateStore as? InMemoryPrekeyPrivateStore)

    XCTAssertEqual(receiverPrekeyStore.oneTimePrekeysCount(deviceId: receiver.localDeviceId), 1)

    let firstInspection = try await ConversationViewModel.inspectMailboxBlob(container: receiver.container, blob: blob)
    XCTAssertEqual(firstInspection?.header.senderUserHandle, sender.localUserId)
    XCTAssertEqual(receiverPrekeyStore.oneTimePrekeysCount(deviceId: receiver.localDeviceId), 1)

    let secondInspection = try await ConversationViewModel.inspectMailboxBlob(container: receiver.container, blob: blob)
    XCTAssertEqual(secondInspection?.header.senderDeviceId, sender.localDeviceId)
    XCTAssertEqual(receiverPrekeyStore.oneTimePrekeysCount(deviceId: receiver.localDeviceId), 1)

    let ackedIds = try await receiver.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([messageId.lowercased()]))
    XCTAssertEqual(receiver.viewModel.messages.count, 1)
    XCTAssertEqual(receiver.viewModel.messages[0].content, "hello from alice")
    XCTAssertEqual(receiver.viewModel.messages[0].senderId, sender.localUserId)
    XCTAssertEqual(receiverPrekeyStore.oneTimePrekeysCount(deviceId: receiver.localDeviceId), 0)

    let prekeyRequests = receiver.networkClient.requests.filter { request in
      request.url?.absoluteString.contains("/api/prekeys/get") == true
    }
    XCTAssertEqual(prekeyRequests.count, 3)
    XCTAssertTrue(prekeyRequests.allSatisfy { $0.url?.absoluteString.contains("peek=true") == true })
    XCTAssertEqual(
      receiver.networkClient.requests.filter { request in
        request.url?.absoluteString.contains("/api/messages/ack") == true
      }.count,
      1
    )
  }

  @MainActor
  func testCallSignalDeliveryPayloadIsBoundToTargetDeviceBeforeEncryption() async throws {
    let sender = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@alice:example.org",
      peerUserId: "@bob:example.org"
    )
    let senderDeviceIdentity = try XCTUnwrap(
      sender.container.keyMaterialStore.deviceIdentity(for: sender.localUserId)
    )
    let senderBundle = try makePublishedBundle(
      container: sender.container,
      userHandle: sender.localUserId,
      identity: sender.localIdentity,
      deviceIdentity: senderDeviceIdentity
    )
    let receiver = try makeFixture(
      manualReadReceipts: false,
      localUserId: "@bob:example.org",
      peerUserId: "@alice:example.org",
      peekBundleResolver: { requestedUser, requestedDeviceId in
        guard requestedUser == sender.localUserId, requestedDeviceId == sender.localDeviceId else {
          return nil
        }

        return senderBundle
      }
    )
    let receiverDeviceIdentity = try XCTUnwrap(
      receiver.container.keyMaterialStore.deviceIdentity(for: receiver.localUserId)
    )
    let receiverBundle = try makePublishedBundle(
      container: receiver.container,
      userHandle: receiver.localUserId,
      identity: receiver.localIdentity,
      deviceIdentity: receiverDeviceIdentity
    )

    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([receiverBundle]))
    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    sender.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([receiverBundle]))
    sender.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }

    let runtimeOfferPayload: [String: Any] = CallSignalEnvelope.payload(
      callId: "call-target-binding-1",
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": "initial",
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
    XCTAssertNil(CallSignalParser.senderDeviceId(from: runtimeOfferPayload))
    XCTAssertNil(CallSignalParser.targetDeviceId(from: runtimeOfferPayload))

    let sent = try await sender.viewModel.sendSignalingPayload(
      msgType: Message.MessageType.callOffer.rawValue,
      payloadObject: runtimeOfferPayload
    )

    XCTAssertEqual(sent.transportState, .accepted)
    XCTAssertEqual(sender.networkClient.requests.count, 4)

    let sendPayload = try requestJSONBody(sender.networkClient.requests[3])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    let receiverDelivery = try XCTUnwrap(deliveries.first { delivery in
      (delivery["to_user"] as? String) == receiver.localUserId
    })
    let ciphertextBlob = try XCTUnwrap(receiverDelivery["ciphertext_blob"] as? String)
    let messageId = try XCTUnwrap(receiverDelivery["message_id"] as? String)
    let deliveryId = try XCTUnwrap(receiverDelivery["delivery_id"] as? String)
    let blob = FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-receiver",
      ownerDeviceId: receiver.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: deliveryId,
      ciphertextBlob: ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )

    let inspectedBlob = try await ConversationViewModel.inspectMailboxBlob(container: receiver.container, blob: blob)
    let inspection = try XCTUnwrap(inspectedBlob)
    let deliveredPayload: [String: Any] = try jsonObject(from: inspection.payload.body)

    XCTAssertEqual(inspection.payload.msgType, Message.MessageType.callOffer.rawValue)
    XCTAssertTrue(CallSignalParser.hasValidEnvelope(deliveredPayload))
    XCTAssertEqual(CallSignalParser.senderDeviceId(from: deliveredPayload), sender.localDeviceId)
    XCTAssertEqual(CallSignalParser.targetDeviceId(from: deliveredPayload), receiver.localDeviceId)
    XCTAssertTrue(CallSignalParser.isTargeted(to: receiver.localDeviceId, payload: deliveredPayload))
    XCTAssertEqual(deliveredPayload["dtls_fingerprint"] as? String, testDTLSFingerprint())
    XCTAssertEqual((deliveredPayload["seq"] as? NSNumber)?.intValue, 1)
    XCTAssertEqual(deliveredPayload["prev_event_hash"] as? String, CallSignalEnvelope.initialTranscriptHash)
    XCTAssertEqual(
      deliveredPayload["transcript_hash"] as? String,
      CallSignalEnvelope.transcriptHash(for: deliveredPayload)
    )
  }

  @MainActor
  func testMailboxIngestionDropsCallSignalTargetedToDifferentDevice() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingCallBlob(
      fixture: fixture,
      callId: "call-wrong-target-1",
      targetDeviceId: "other-device-1"
    )

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([blob.messageId.lowercased()]))
    XCTAssertTrue(fixture.viewModel.messages.isEmpty)
  }

  @MainActor
  func testMailboxIngestionDropsCallSignalWithoutCallId() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingCallBlob(
      fixture: fixture,
      callId: "call-missing-id-drop-1",
      targetDeviceId: fixture.localDeviceId,
      transformPayload: { payload in
        var mutatedPayload = payload
        mutatedPayload.removeValue(forKey: "call_id")
        mutatedPayload["transcript_hash"] = CallSignalEnvelope.transcriptHash(for: mutatedPayload)
        return mutatedPayload
      }
    )

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([blob.messageId.lowercased()]))
    XCTAssertTrue(fixture.viewModel.messages.isEmpty)
  }

  @MainActor
  func testMailboxIngestionKeepsIncomingCallSignalOutOfVisibleMessages() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let blob = try makeIncomingCallBlob(
      fixture: fixture,
      callId: "call-visible-filter-1",
      targetDeviceId: fixture.localDeviceId
    )

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([blob.messageId.lowercased()]))
    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertEqual(fixture.viewModel.messages[0].type, .callOffer)
    XCTAssertTrue(fixture.viewModel.visibleMessages().isEmpty)
    XCTAssertNil(fixture.viewModel.replyPreviewText(messageId: fixture.viewModel.messages[0].id))
  }

  @MainActor
  func testIncomingReadControlMarksOutgoingMessageRead() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    try enqueueSuccessfulLocalSendResponses(fixture: fixture, bootstrapNewSession: true)

    let sent = try await fixture.viewModel.sendText(plaintext: "awaiting read receipt")
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(fixture: fixture, targetMessageIds: [sent.id])

    _ = try await fixture.viewModel.ingestMailboxBlobs([readBlob], source: .realtime)

    let updated = try XCTUnwrap(fixture.viewModel.messages.first(where: { $0.id == sent.id }))
    XCTAssertNotNil(updated.readAt)
    XCTAssertEqual(fixture.viewModel.statusSymbol(for: updated), "✓✓")
    XCTAssertEqual(fixture.networkClient.requests.count, 5)
    XCTAssertTrue(fixture.networkClient.requests[4].url?.absoluteString.contains("/api/messages/ack") == true)
  }

  @MainActor
  func testIncomingReadControlMatchesLegacyUppercaseOutgoingMessageIds() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    let legacyMessageId = UUID().uuidString.uppercased()
    let legacyMessage = Message(
      id: legacyMessageId,
      conversationId: fixture.conversation.id,
      senderId: fixture.localUserId,
      content: "legacy outgoing",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: Date(),
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: .accepted,
      transportErrorDetail: nil
    )
    try persistMessages(
      [legacyMessage],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let reloadedViewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(
      fixture: fixture,
      targetMessageIds: [legacyMessageId.lowercased()]
    )

    _ = try await reloadedViewModel.ingestMailboxBlobs([readBlob], source: .realtime)

    let updated = try XCTUnwrap(
      reloadedViewModel.messages.first(where: { $0.id == legacyMessageId.lowercased() })
    )
    XCTAssertNotNil(updated.readAt)
    XCTAssertEqual(reloadedViewModel.statusSymbol(for: updated), "✓✓")
  }

  @MainActor
  func testReloadAppliesPersistedDeferredReadReceiptsForLegacyUppercaseMessageIds() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    let legacyMessageId = UUID().uuidString.uppercased()

    let firstPushProcessor = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(
      fixture: fixture,
      targetMessageIds: [legacyMessageId.lowercased()]
    )
    _ = try await firstPushProcessor.ingestMailboxBlobs([readBlob], source: .backgroundPush)

    let legacyMessage = Message(
      id: legacyMessageId,
      conversationId: fixture.conversation.id,
      senderId: fixture.localUserId,
      content: "legacy outgoing",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: Date(),
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: .accepted,
      transportErrorDetail: nil
    )
    try persistMessages(
      [legacyMessage],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let reloadedViewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )

    let updated = try XCTUnwrap(
      reloadedViewModel.messages.first(where: { $0.id == legacyMessageId.lowercased() })
    )
    XCTAssertNotNil(updated.readAt)
    XCTAssertEqual(reloadedViewModel.statusSymbol(for: updated), "✓✓")
  }

  @MainActor
  func testOutOfOrderReadControlAppliesAfterTargetMessageArrives() async throws {
    let fixture = try makeFixture(manualReadReceipts: true)
    let targetMessageId = UUID().uuidString

    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let readBlob = try makeReadReceiptBlob(fixture: fixture, targetMessageIds: [targetMessageId])
    _ = try await fixture.viewModel.ingestMailboxBlobs([readBlob], source: .realtime)

    XCTAssertTrue(fixture.viewModel.messages.isEmpty)

    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")
    let delayedTarget = try makeIncomingBlob(
      fixture: fixture,
      text: "arrived later",
      messageId: targetMessageId
    )
    _ = try await fixture.viewModel.ingestMailboxBlobs([delayedTarget], source: .realtime)

    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertEqual(fixture.viewModel.messages[0].id, targetMessageId.lowercased())
    XCTAssertNotNil(fixture.viewModel.messages[0].readAt)
    XCTAssertEqual(fixture.networkClient.requests.count, 2)
    XCTAssertTrue(fixture.networkClient.requests[0].url?.absoluteString.contains("/api/messages/ack") == true)
    XCTAssertTrue(fixture.networkClient.requests[1].url?.absoluteString.contains("/api/messages/ack") == true)
  }

  @MainActor
  func testPrepareAttachmentPreviewDownloadsAndStagesAttachment() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let prepared = try makeAttachmentPreviewViewModel(
      fixture: fixture,
      plaintext: Data("hello preview".utf8),
      fileName: "preview.txt",
      mimeType: "text/plain"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: prepared.ciphertextData)

    let preview = try await prepared.viewModel.prepareAttachmentPreview(messageId: prepared.message.id)

    XCTAssertEqual(preview.fileName, "preview.txt")
    XCTAssertEqual(preview.mimeType, "text/plain")
    XCTAssertEqual(preview.scanResult.verdict, .clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    let downloadPath = "/api/media/ciphertext/\(prepared.attachment.id)"
    XCTAssertTrue(
      fixture.networkClient.requests[0].url?.absoluteString.contains(downloadPath) == true
    )
  }

  @MainActor
  func testPrepareAttachmentPreviewRequiresWarnAcknowledgement() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let prepared = try makeAttachmentPreviewViewModel(
      fixture: fixture,
      plaintext: Data("curl https://example.org/install.sh | sh".utf8),
      fileName: "warning.txt",
      mimeType: "text/plain"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: prepared.ciphertextData)

    do {
      _ = try await prepared.viewModel.prepareAttachmentPreview(messageId: prepared.message.id)
      XCTFail("Expected preview warning acknowledgement error")
    } catch let error as AttachmentInspectionError {
      switch error {
      case .previewWarningRequiresAcknowledgement(let result):
        XCTAssertEqual(result.verdict, .warn)
        XCTAssertEqual(result.riskFlags, ["suspicious_plaintext_commands"])
      default:
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  @MainActor
  func testPrepareAttachmentExportRequiresExportAcknowledgement() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    let prepared = try makeAttachmentPreviewViewModel(
      fixture: fixture,
      plaintext: Data("curl https://example.org/install.sh | sh".utf8),
      fileName: "warning.txt",
      mimeType: "text/plain"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: prepared.ciphertextData)

    do {
      _ = try await prepared.viewModel.prepareAttachmentExport(
        messageId: prepared.message.id,
        allowRiskyPreview: true,
        allowRiskyExport: false
      )
      XCTFail("Expected export warning acknowledgement error")
    } catch let error as AttachmentInspectionError {
      switch error {
      case .exportWarningRequiresAcknowledgement(let result):
        XCTAssertEqual(result.verdict, .warn)
        XCTAssertEqual(result.riskFlags, ["suspicious_plaintext_commands"])
      default:
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  @MainActor
  private func makeFixture(
    manualReadReceipts: Bool,
    persistSeedPhrase: Bool = true,
    localUserId: String = "@alice:example.org",
    peerUserId: String = "@bob:example.org",
    peekBundleResolver: ((String, String) throws -> FederatedPrekeyBundle?)? = nil,
    initialCallOfferPeerDeliveryRetryDelaysSeconds: [TimeInterval] = []
  ) throws -> Fixture {
    let suiteName: String = "ConversationViewModelTests.\(UUID().uuidString)"
    let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(manualReadReceipts, forKey: "messaging.manual_read_receipts")

    let sessionStore: UserDefaultsSessionStore = UserDefaultsSessionStore(defaults: defaults)
    let user = User(
      id: localUserId,
      username: localUserId,
      email: localUserId,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
    sessionStore.save(user: SessionUser(user: user))

    let keyMaterialStore: InMemoryKeyMaterialStore = InMemoryKeyMaterialStore()
    keyMaterialStore.setCurrentUserId(localUserId)
    let networkClient = MockNetworkClient()
    let tokenStore = InMemoryTokenStore()
    tokenStore.saveTokens(accessToken: "access", refreshToken: "refresh")
    let prekeyPrivateStore = InMemoryPrekeyPrivateStore()

    let container = AppContainer(
      environment: .local,
      defaults: defaults,
      tokenStore: tokenStore,
      keyMaterialStore: keyMaterialStore,
      sessionStore: sessionStore,
      prekeyPrivateStore: prekeyPrivateStore,
      networkClient: networkClient
    )

    let localIdentity = try container.identityService.createIdentity(userHandle: localUserId)
    let peerIdentity = try container.identityService.createIdentity(userHandle: peerUserId)
    let localDeviceId = "local-device-1"
    let peerDeviceId = "peer-device-1"
    keyMaterialStore.saveDeviceId(localDeviceId, for: localUserId)
    let localDeviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: localUserId,
      seedPhrase: localIdentity.seedPhrase,
      deviceId: localDeviceId
    )
    keyMaterialStore.saveDeviceIdentity(localDeviceIdentity, for: localUserId)

    if persistSeedPhrase {
      keyMaterialStore.saveSeedPhrase(localIdentity.seedPhrase, for: localUserId)
      let storageKey = try container.identityService.deriveStorageKey(seedPhrase: localIdentity.seedPhrase)
      container.ratchetSessionStore.configure(storageKey: storageKey)
    }

    networkClient.registerFallbackResponder { [self] request in
      guard let url = request.url else {
        return nil
      }

      let path: String = url.path
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      let queryItems: [URLQueryItem] = components?.queryItems ?? []
      let requestedUser: String? = queryItems.first(where: { $0.name == "user" })?.value?.lowercased()
      let requestedDeviceId: String? = queryItems.first(where: { $0.name == "device_id" })?.value
      let isPeekRequest: Bool = queryItems.contains(where: { $0.name == "peek" && $0.value == "true" })

      if path.hasSuffix("/api/prekeys/get"),
        isPeekRequest,
        requestedDeviceId != nil
      {
        if let requestedUser,
          let requestedDeviceId,
          let resolvedBundle = try peekBundleResolver?(requestedUser, requestedDeviceId)
        {
          return MockNetworkClient.QueuedResponse(
            statusCode: 200,
            body: try self.prekeysResponseData([resolvedBundle])
          )
        }

        guard requestedUser == peerUserId else {
          return nil
        }

        let bundle = try self.makeBundle(
          container: container,
          userHandle: peerUserId,
          identity: peerIdentity,
          deviceId: requestedDeviceId ?? peerDeviceId
        )
        return MockNetworkClient.QueuedResponse(
          statusCode: 200,
          body: try self.prekeysResponseData([bundle])
        )
      }

      return nil
    }

    let conversation = Conversation(
      id: "conversation-1",
      type: .direct,
      name: peerUserId,
      createdAt: Date(),
      updatedAt: Date(),
      participants: [
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: "conversation-1",
          userId: localUserId,
          joinedAt: Date(),
          role: .member
        ),
        ConversationParticipant(
          id: UUID().uuidString,
          conversationId: "conversation-1",
          userId: peerUserId,
          joinedAt: Date(),
          role: .member
        ),
      ]
    )

    let viewModel = ConversationViewModel(
      container: container,
      conversation: conversation,
      defaults: defaults,
      initialCallOfferPeerDeliveryRetryDelaysSeconds: initialCallOfferPeerDeliveryRetryDelaysSeconds
    )

    return Fixture(
      defaults: defaults,
      networkClient: networkClient,
      container: container,
      conversation: conversation,
      viewModel: viewModel,
      localUserId: localUserId,
      peerUserId: peerUserId,
      localDeviceId: localDeviceId,
      peerDeviceId: peerDeviceId,
      localIdentity: localIdentity,
      peerIdentity: peerIdentity
    )
  }

  @MainActor
  func testHydrateMessageAcceptsEnvelopeWithDifferentConversationId() async throws {
    let fixture = try makeFixture(manualReadReceipts: false)
    fixture.networkClient.enqueue(statusCode: 200, json: "{\"acked\":1}")

    let envelopeConversationId = "envelope-conversation-\(UUID().uuidString)"
    let sessionId = "cross-conv-session-\(UUID().uuidString)"

    let senderState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.peerUserId,
      localDeviceId: fixture.peerDeviceId,
      peerUserHandle: fixture.localUserId,
      peerDeviceId: fixture.localDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: envelopeConversationId
    )

    let receiverState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.localUserId,
      localDeviceId: fixture.localDeviceId,
      peerUserHandle: fixture.peerUserId,
      peerDeviceId: fixture.peerDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: envelopeConversationId
    )
    try fixture.container.ratchetSessionStore.upsert(receiverState)

    let payload = E2EMessagePayload(
      conversationId: envelopeConversationId,
      msgType: Message.MessageType.text.rawValue,
      body: "cross-conversation message",
      attachments: [],
      padding: "00000000"
    )
    let sealed = try fixture.container.envelopeService.seal(payload: payload, state: senderState)

    let messageId = UUID().uuidString
    let blob = FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-local",
      ownerDeviceId: fixture.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: UUID().uuidString,
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )

    XCTAssertEqual(fixture.viewModel.conversation.id, "conversation-1")

    let ackedIds = try await fixture.viewModel.ingestMailboxBlobs([blob], source: .backgroundPush)

    XCTAssertEqual(Set(ackedIds), Set([blob.messageId.lowercased()]))
    XCTAssertEqual(fixture.viewModel.messages.count, 1)
    XCTAssertEqual(fixture.viewModel.messages[0].content, "cross-conversation message")
    XCTAssertEqual(
      fixture.viewModel.conversation.id,
      directConversationId(localUserHandle: fixture.localUserId, peerUserHandle: fixture.peerUserId)
    )
  }

  @MainActor
  private func makeAttachmentPreviewViewModel(
    fixture: Fixture,
    plaintext: Data,
    fileName: String,
    mimeType: String,
    type: Message.MessageType = .file,
    messageId: String = UUID().uuidString
  ) throws -> (viewModel: ConversationViewModel, message: Message, attachment: FileAttachment, ciphertextData: Data) {
    let keyData: Data = fixture.container.cryptoService.generateSeed(bytes: 32)
    let encryptedEnvelope: AEADCiphertextEnvelope = try fixture.container.cryptoService.encryptAEAD(
      plaintext: plaintext,
      key: SymmetricKey(data: keyData)
    )
    let ciphertextData: Data = try JSONCoding.encoder.encode(encryptedEnvelope)
    let attachmentId: String = "media-\(UUID().uuidString.lowercased())"
    let attachment = FileAttachment(
      id: attachmentId,
      messageId: messageId.lowercased(),
      storageUrl: "/api/media/ciphertext/\(attachmentId)",
      mimeType: mimeType,
      fileSize: plaintext.count,
      fileName: fileName,
      originServer: "example.org",
      downloadCapability: "capability-token",
      fileKey: keyData.base64EncodedString(),
      hashCipherFile: AttachmentSecurity.sha256Hex(ciphertextData),
      scanVerdict: nil,
      riskFlags: nil,
      scannerVersion: nil,
      rulesVersion: nil,
      createdAt: Date()
    )
    let message = Message(
      id: messageId,
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: fileName,
      type: type,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: attachment,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )

    try persistMessages(
      [message],
      defaults: fixture.defaults,
      container: fixture.container,
      owner: fixture.localUserId,
      conversationId: fixture.conversation.id
    )

    let viewModel = ConversationViewModel(
      container: fixture.container,
      conversation: fixture.conversation,
      defaults: fixture.defaults
    )
    return (viewModel, message, attachment, ciphertextData)
  }

  /// Creates a blob with matching sender/receiver sessions using localIdentity for both.
  /// This is needed because bootstrapSession derives chain keys from x25519(local_priv, peer_pub)
  /// which is asymmetric — different identities produce different shared secrets. The tests
  /// use a single fixture so we bootstrap both sides with localIdentity to get symmetric keys.
  @MainActor
  private func makeIncomingBlobAndSession(
    fixture: Fixture,
    text: String,
    messageId: String = UUID().uuidString
  ) throws -> (blob: FederatedMailboxBlob, receiverState: RatchetSessionState) {
    let sessionId = "incoming-session-\(messageId)"

    let senderState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.peerUserId,
      localDeviceId: fixture.peerDeviceId,
      peerUserHandle: fixture.localUserId,
      peerDeviceId: fixture.localDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )

    let receiverState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.localUserId,
      localDeviceId: fixture.localDeviceId,
      peerUserHandle: fixture.peerUserId,
      peerDeviceId: fixture.peerDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )
    try fixture.container.ratchetSessionStore.upsert(receiverState)

    let payloadData = try JSONSerialization.data(withJSONObject: ["text": text], options: [])
    let payload = E2EMessagePayload(
      conversationId: fixture.conversation.id,
      msgType: Message.MessageType.text.rawValue,
      body: String(data: payloadData, encoding: .utf8) ?? text,
      attachments: [],
      padding: "00000000"
    )
    let sealed = try fixture.container.envelopeService.seal(payload: payload, state: senderState)

    let blob = FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-local",
      ownerDeviceId: fixture.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: UUID().uuidString,
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
    return (blob, receiverState)
  }

  @MainActor
  private func makeIncomingBlob(
    fixture: Fixture,
    text: String,
    messageId: String = UUID().uuidString
  ) throws -> FederatedMailboxBlob {
    try makeIncomingBlobAndSession(fixture: fixture, text: text, messageId: messageId).blob
  }

  @MainActor
  private func makeIncomingCallBlob(
    fixture: Fixture,
    callId: String,
    targetDeviceId: String,
    messageId: String = UUID().uuidString,
    transformPayload: (([String: Any]) throws -> [String: Any])? = nil
  ) throws -> FederatedMailboxBlob {
    let sessionId = "incoming-call-session-\(messageId)"

    let senderState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.peerUserId,
      localDeviceId: fixture.peerDeviceId,
      peerUserHandle: fixture.localUserId,
      peerDeviceId: fixture.localDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )

    let receiverState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.localUserId,
      localDeviceId: fixture.localDeviceId,
      peerUserHandle: fixture.peerUserId,
      peerDeviceId: fixture.peerDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )
    try fixture.container.ratchetSessionStore.upsert(receiverState)

    let basePayloadObject: [String: Any] = CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: fixture.peerDeviceId,
      targetDeviceId: targetDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": "initial",
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
    let payloadObject: [String: Any] = try transformPayload?(basePayloadObject) ?? basePayloadObject
    let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
    let payload = E2EMessagePayload(
      conversationId: fixture.conversation.id,
      msgType: Message.MessageType.callOffer.rawValue,
      body: String(data: payloadData, encoding: .utf8) ?? "{}",
      attachments: [],
      padding: "00000000"
    )
    let sealed = try fixture.container.envelopeService.seal(payload: payload, state: senderState)

    return FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-local",
      ownerDeviceId: fixture.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: UUID().uuidString,
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
  }

  @MainActor
  private func makePeerBundle(
    fixture: Fixture,
    deviceId: String
  ) throws -> FederatedPrekeyBundle {
    try makeBundle(
      container: fixture.container,
      userHandle: fixture.peerUserId,
      identity: fixture.peerIdentity,
      deviceId: deviceId
    )
  }

  @MainActor
  private func makeSelfBundle(
    fixture: Fixture,
    deviceId: String
  ) throws -> FederatedPrekeyBundle {
    try makeBundle(
      container: fixture.container,
      userHandle: fixture.localUserId,
      identity: fixture.localIdentity,
      deviceId: deviceId
    )
  }

  @MainActor
  private func makeBundle(
    container: AppContainer,
    userHandle: String,
    identity: IdentityBundle,
    deviceId: String
  ) throws -> FederatedPrekeyBundle {
    let deviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: userHandle,
      seedPhrase: identity.seedPhrase,
      deviceId: deviceId
    )
    let deviceBundle = container.deviceKeysService.bundle(from: deviceIdentity)
    let signedPrekey = try container.prekeysService.generateSignedPrekey(deviceIdentity: deviceIdentity)
    let oneTimePrekey = container.prekeysService.generateOneTimePrekeys(count: 1).first

    return FederatedPrekeyBundle(
      protocolVersion: 2,
      userHandle: userHandle,
      deviceId: deviceId,
      accountSignPub: identity.ikSignPublic,
      deviceSignPub: deviceBundle.dkSignPublic,
      deviceDhPub: deviceBundle.dkDHPublic,
      deviceCertificateChain: deviceBundle.deviceCertificateChain,
      signedPrekey: FederatedPrekeySigned(
        prekeyId: signedPrekey.prekeyId,
        signedPrekeyPub: signedPrekey.signedPrekeyPub,
        signature: signedPrekey.signature,
        expiresAt: nil
      ),
      oneTimePrekey: oneTimePrekey.map {
        FederatedPrekeyOneTime(prekeyId: $0.prekeyId, prekeyPub: $0.prekeyPub)
      },
      pushMode: .privacyFirst
    )
  }

  @MainActor
  private func makePublishedBundle(
    container: AppContainer,
    userHandle: String,
    identity: IdentityBundle,
    deviceId: String
  ) throws -> FederatedPrekeyBundle {
    let deviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: userHandle,
      seedPhrase: identity.seedPhrase,
      deviceId: deviceId
    )
    return try makePublishedBundle(
      container: container,
      userHandle: userHandle,
      identity: identity,
      deviceIdentity: deviceIdentity
    )
  }

  @MainActor
  private func makePublishedBundle(
    container: AppContainer,
    userHandle: String,
    identity: IdentityBundle,
    deviceIdentity: PersistedDeviceIdentity
  ) throws -> FederatedPrekeyBundle {
    let deviceBundle = container.deviceKeysService.bundle(from: deviceIdentity)
    let signedPrekey = try container.prekeysService.generateAndStoreSignedPrekey(deviceIdentity: deviceIdentity)
    let oneTimePrekey = try container.prekeysService.generateAndStoreOneTimePrekeys(
      count: 1,
      deviceId: deviceIdentity.deviceId
    ).first

    return FederatedPrekeyBundle(
      protocolVersion: 2,
      userHandle: userHandle,
      deviceId: deviceIdentity.deviceId,
      accountSignPub: identity.ikSignPublic,
      deviceSignPub: deviceBundle.dkSignPublic,
      deviceDhPub: deviceBundle.dkDHPublic,
      deviceCertificateChain: deviceBundle.deviceCertificateChain,
      signedPrekey: FederatedPrekeySigned(
        prekeyId: signedPrekey.prekeyId,
        signedPrekeyPub: signedPrekey.signedPrekeyPub,
        signature: signedPrekey.signature,
        expiresAt: nil
      ),
      oneTimePrekey: oneTimePrekey.map {
        FederatedPrekeyOneTime(prekeyId: $0.prekeyId, prekeyPub: $0.prekeyPub)
      },
      pushMode: .privacyFirst
    )
  }

  @MainActor
  private func makeReadReceiptBlob(
    fixture: Fixture,
    targetMessageIds: [String],
    messageId: String = UUID().uuidString,
    readAt: Date = Date()
  ) throws -> FederatedMailboxBlob {
    let sessionId = "read-session-\(messageId)"

    let senderState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.peerUserId,
      localDeviceId: fixture.peerDeviceId,
      peerUserHandle: fixture.localUserId,
      peerDeviceId: fixture.localDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )

    let receiverState = try fixture.container.x3dhService.bootstrapSession(
      seedPhrase: fixture.localIdentity.seedPhrase,
      localUserHandle: fixture.localUserId,
      localDeviceId: fixture.localDeviceId,
      peerUserHandle: fixture.peerUserId,
      peerDeviceId: fixture.peerDeviceId,
      peerIkDhPublic: fixture.localIdentity.ikDHPublic,
      sessionId: sessionId,
      conversationId: fixture.conversation.id
    )
    try fixture.container.ratchetSessionStore.upsert(receiverState)

    let payloadData = try JSONSerialization.data(withJSONObject: [
      "action": "read",
      "message_ids": targetMessageIds,
      "actor_user_id": fixture.peerUserId,
      "at": makeISODateString(readAt),
    ], options: [])
    let payload = E2EMessagePayload(
      conversationId: fixture.conversation.id,
      msgType: "msg_read",
      body: String(data: payloadData, encoding: .utf8) ?? "{}",
      attachments: [],
      padding: "00000000"
    )
    let sealed = try fixture.container.envelopeService.seal(payload: payload, state: senderState)

    return FederatedMailboxBlob(
      id: messageId.lowercased(),
      ownerAccountId: "acc-local",
      ownerDeviceId: fixture.localDeviceId,
      senderServer: "example.org",
      messageId: messageId,
      deliveryId: UUID().uuidString,
      ciphertextBlob: sealed.ciphertextBlob,
      ttlSec: 600,
      expiresAt: Date().addingTimeInterval(600),
      ackedAt: nil,
      createdAt: Date()
    )
  }

  @MainActor
  private func enqueueSuccessfulLocalSendResponses(
    fixture: Fixture,
    bootstrapNewSession: Bool
  ) throws {
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    if bootstrapNewSession {
      fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    }
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }
  }

  @MainActor
  private func enqueueSuccessfulExistingSessionSendResponses(fixture: Fixture) throws {
    let peerBundle = try makePeerBundle(fixture: fixture, deviceId: fixture.peerDeviceId)
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([peerBundle]))
    fixture.networkClient.enqueue(statusCode: 200, data: try prekeysResponseData([]))
    fixture.networkClient.enqueueResponder { [self] request in
      let payload = try self.requestJSONBody(request)
      let deliveries: [[String: Any]] = payload["deliveries"] as? [[String: Any]] ?? []
      let results: [[String: String]] = deliveries.compactMap { delivery in
        guard let deliveryId: String = delivery["delivery_id"] as? String else {
          return nil
        }

        return [
          "delivery_id": deliveryId,
          "status": "queued_local",
        ]
      }
      let body = try JSONSerialization.data(withJSONObject: [
        "accepted": results.count,
        "results": results,
      ])
      return MockNetworkClient.QueuedResponse(statusCode: 202, body: body)
    }
  }

  private func prekeysResponseData(_ bundles: [FederatedPrekeyBundle]) throws -> Data {
    try JSONCoding.encoder.encode(FederatedPrekeysGetResponse(bundles: bundles))
  }

  private func requestJSONBody(_ request: URLRequest) throws -> [String: Any] {
    let body: Data = request.httpBody ?? Data()
    return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
  }

  private func jsonObject(from raw: String) throws -> [String: Any] {
    let data = try XCTUnwrap(raw.data(using: .utf8))
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
  }

  private func peerDeliveryPayload(fixture: Fixture, sendRequestIndex: Int) throws -> [String: Any] {
    let sendPayload = try requestJSONBody(fixture.networkClient.requests[sendRequestIndex])
    let deliveries: [[String: Any]] = sendPayload["deliveries"] as? [[String: Any]] ?? []
    return try XCTUnwrap(deliveries.first(where: { ($0["to_user"] as? String) == fixture.peerUserId }))
  }

  private func testDTLSFingerprint() -> String {
    "sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:10:20:30:40:50:60:70:80:90:A0:B0:C0:D0:E0:F0:01"
  }

  private func mismatchedTestDTLSFingerprint() -> String {
    "sha-256 01:F0:E0:D0:C0:B0:A0:90:80:70:60:50:40:30:20:10:00:FF:EE:DD:CC:BB:AA:99:88:77:66:55:44:33:22:11"
  }

  private func sdpWithDTLSFingerprint(
    _ fingerprint: String? = nil,
    candidate: String? = nil
  ) -> String {
    var sdp: String = "v=0\r\na=fingerprint:\(fingerprint ?? testDTLSFingerprint())\r\n"
    if let candidate {
      sdp += "a=\(candidate)\r\n"
    }

    return sdp
  }

  private func makeCallOfferPayload(
    callId: String,
    offerKind: String,
    senderDeviceId: String = "peer-device-1",
    targetDeviceId: String = "local-device-1"
  ) -> [String: Any] {
    CallSignalEnvelope.payload(
      callId: callId,
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetDeviceId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "call_type": Call.CallType.video.rawValue,
        "offer_kind": offerKind,
        "offer": [
          "type": "offer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
  }

  private func makeCallAnswerPayload(callId: String) -> [String: Any] {
    CallSignalEnvelope.payload(
      callId: callId,
      dtlsFingerprint: testDTLSFingerprint(),
      values: [
        "answer": [
          "type": "answer",
          "sdp": sdpWithDTLSFingerprint(),
        ],
      ]
    )
  }

  private func makeCallICECandidatePayload(callId: String) -> [String: Any] {
    CallSignalEnvelope.payload(
      callId: callId,
      values: [
        "candidate": [
          "candidate": "candidate:30 1 udp 1677729535 203.0.113.10 3478 typ relay generation 0",
          "sdpMLineIndex": 0,
          "sdpMid": "0",
        ],
      ]
    )
  }

  private func makeCallOfferMessage(
    fixture: Fixture,
    callId: String,
    offerKind: String
  ) throws -> Message {
    let payload = makeCallOfferPayload(callId: callId, offerKind: offerKind)
    return try makeCallOfferMessage(fixture: fixture, payload: payload)
  }

  private func makeCallOfferMessage(fixture: Fixture, payload: [String: Any]) throws -> Message {
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
    let content = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
    return Message(
      id: UUID().uuidString,
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: content,
      type: .callOffer,
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
  }

  private func makeCallSignalMessage(
    fixture: Fixture,
    id: String,
    type: Message.MessageType,
    payload: [String: Any],
    createdAt: Date
  ) -> Message {
    let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [])
    let content = payloadData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return Message(
      id: id,
      conversationId: fixture.conversation.id,
      senderId: fixture.peerUserId,
      content: content,
      type: type,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: nil,
      deliveredAt: nil,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: createdAt,
      attachment: nil,
      reactions: nil,
      transportState: nil,
      transportErrorDetail: nil
    )
  }

  private func makeIncomingCallDescriptor(
    fixture: Fixture,
    systemUUID: UUID,
    callId: String
  ) -> E2EIncomingCallDescriptor {
    E2EIncomingCallDescriptor(
      systemUUID: systemUUID,
      callId: callId,
      conversation: fixture.conversation,
      offer: CallSessionDescriptionSignal(
        callId: callId,
        fromUserId: fixture.peerUserId,
        type: "offer",
        sdp: sdpWithDTLSFingerprint(),
        dtlsFingerprint: testDTLSFingerprint()
      ),
      callType: .video,
      callerUserId: fixture.peerUserId
    )
  }

  @MainActor
  private func makeCallSessionViewModel(fixture: Fixture, callId: String) -> E2ECallSessionViewModel {
    E2ECallSessionViewModel(
      conversationViewModel: fixture.viewModel,
      role: .initiator,
      callId: callId,
      peerUserId: fixture.peerUserId,
      callType: .video
    )
  }

  @MainActor
  private func flushMainQueue() async {
    let expectation = expectation(description: "main queue flushed")
    OperationQueue.main.addOperation {
      expectation.fulfill()
    }
    await fulfillment(of: [expectation], timeout: 1.0)
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

  private func makeVideoCallPixelBufferForTesting(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    )
    XCTAssertEqual(status, kCVReturnSuccess)

    let resolvedPixelBuffer = try XCTUnwrap(pixelBuffer)
    CVPixelBufferLockBaseAddress(resolvedPixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(resolvedPixelBuffer) {
      let byteCount = CVPixelBufferGetBytesPerRow(resolvedPixelBuffer) * height
      memset(baseAddress, 0x64, byteCount)
    }
    CVPixelBufferUnlockBaseAddress(resolvedPixelBuffer, [])
    return resolvedPixelBuffer
  }

  @MainActor
  private func persistMessages(
    _ messages: [Message],
    defaults: UserDefaults,
    container: AppContainer? = nil,
    owner: String,
    conversationId: String
  ) throws {
    let key = persistedMessagesStorageKey(owner: owner, conversationId: conversationId)
    let encoded = try JSONCoding.encoder.encode(messages)
    if let container,
      let storageKey = resolvedStorageKey(container: container, owner: owner)
    {
      try container.secureStateStore.save(messages, for: key, storageKey: storageKey)
    }
    defaults.set(encoded, forKey: key)
  }

  @MainActor
  private func persistPinnedMessages(
    _ pinnedMessages: [PinnedMessage],
    defaults: UserDefaults,
    container: AppContainer? = nil,
    owner: String,
    conversationId: String
  ) throws {
    let key = conversationStorageKey(
      prefix: "federated.local.pins.v2",
      owner: owner,
      conversationId: conversationId
    )
    let encoded = try JSONCoding.encoder.encode(pinnedMessages)
    if let container,
      let storageKey = resolvedStorageKey(container: container, owner: owner)
    {
      try container.secureStateStore.save(pinnedMessages, for: key, storageKey: storageKey)
    }
    defaults.set(encoded, forKey: key)
  }

  @MainActor
  private func resolvedStorageKey(container: AppContainer, owner: String) -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: owner,
      sessionUser: container.sessionStore.currentUser,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )
  }

  private func persistedMessagesStorageKey(owner: String, conversationId: String) -> String {
    let rawKey: String = "\(owner.lowercased())|\(conversationId.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "federated.local.messages.v2.\(suffix)"
  }

  private func conversationStorageKey(prefix: String, owner: String, conversationId: String) -> String {
    let rawKey: String = "\(owner.lowercased())|\(conversationId.lowercased())"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(prefix).\(suffix)"
  }

  private func sourcePlist(at pathComponents: [String]) throws -> [String: Any] {
    let repositoryRootURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL = pathComponents.reduce(repositoryRootURL) { partialURL, component in
      partialURL.appendingPathComponent(component)
    }
    let data = try Data(contentsOf: plistURL)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try XCTUnwrap(object as? [String: Any])
  }

  private func directConversationId(localUserHandle: String, peerUserHandle: String) -> String {
    let participants: [String] = [
      localUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      peerUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].sorted()
    let digest = SHA256.hash(data: Data("direct|\(participants.joined(separator: "|"))".utf8))
    let hex: String = digest.map { String(format: "%02x", $0) }.joined()
    return "dm-\(String(hex.prefix(32)))"
  }

  private func makeMessage(
    senderId: String,
    deliveredAt: Date?,
    readAt: Date?,
    transportState: Message.OutboundTransportState? = nil
  ) -> Message {
    Message(
      id: UUID().uuidString,
      conversationId: "conversation-1",
      senderId: senderId,
      content: "text",
      type: .text,
      encryptionMode: .e2e,
      encryptionKeyNonce: nil,
      readAt: readAt,
      deliveredAt: deliveredAt,
      replyToMessageId: nil,
      forwardedFromMessageId: nil,
      deletedBy: nil,
      deletedAt: nil,
      createdAt: Date(),
      attachment: nil,
      reactions: nil,
      transportState: transportState,
      transportErrorDetail: nil
    )
  }
}

private struct Fixture {
  let defaults: UserDefaults
  let networkClient: MockNetworkClient
  let container: AppContainer
  let conversation: Conversation
  let viewModel: ConversationViewModel
  let localUserId: String
  let peerUserId: String
  let localDeviceId: String
  let peerDeviceId: String
  let localIdentity: IdentityBundle
  let peerIdentity: IdentityBundle
}

private final class SpyCallMediaRecoveryEngine: CallOfferRecoveryControlling {
  private let restartOffer: CallSessionDescriptionSignal
  private(set) var updatedRelayURLSets: [[String]] = []
  private(set) var restartCallIds: [String] = []
  private(set) var rollbackCallCount: Int = 0

  init(restartOffer: CallSessionDescriptionSignal) {
    self.restartOffer = restartOffer
  }

  func updateRelayIceServers(_ iceServers: [WebRTC.RTCIceServer]) throws {
    updatedRelayURLSets.append(contentsOf: iceServers.map(\.urlStrings))
  }

  func restartIceAndCreateOffer(callId: String) async throws -> CallSessionDescriptionSignal {
    restartCallIds.append(callId)
    return restartOffer
  }

  func rollbackLocalDescription() async throws {
    rollbackCallCount += 1
  }
}

private final class FlakyRemoteICECandidateEngine: CallRemoteICECandidateQueuing {
  private var remainingFailures: Int
  private(set) var queuedCandidates: [CallICECandidateSignal] = []

  init(failuresBeforeSuccess: Int) {
    self.remainingFailures = max(0, failuresBeforeSuccess)
  }

  func queueRemoteCandidate(_ candidate: CallICECandidateSignal) async throws {
    queuedCandidates.append(candidate)
    guard remainingFailures == 0 else {
      remainingFailures -= 1
      throw WebRTCAutomationEngineError.operationFailed("transient ICE apply failure")
    }
  }
}

private final class SpyCallVideoRendererManager: CallVideoRendererManaging {
  private(set) var attachedLocalRendererIds: [ObjectIdentifier] = []
  private(set) var attachedRemoteRendererIds: [ObjectIdentifier] = []
  private(set) var detachedLocalRendererIds: [ObjectIdentifier] = []
  private(set) var detachedRemoteRendererIds: [ObjectIdentifier] = []

  func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
    attachedLocalRendererIds.append(rendererId(renderer))
  }

  func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    attachedRemoteRendererIds.append(rendererId(renderer))
  }

  func detachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
    detachedLocalRendererIds.append(rendererId(renderer))
  }

  func detachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
    detachedRemoteRendererIds.append(rendererId(renderer))
  }

  func localAttachCount(for renderer: RTCVideoRenderer) -> Int {
    let id = rendererId(renderer)
    return attachedLocalRendererIds.filter { $0 == id }.count
  }

  func remoteAttachCount(for renderer: RTCVideoRenderer) -> Int {
    let id = rendererId(renderer)
    return attachedRemoteRendererIds.filter { $0 == id }.count
  }

  private func rendererId(_ renderer: RTCVideoRenderer) -> ObjectIdentifier {
    ObjectIdentifier(renderer as AnyObject)
  }
}

private final class SpyCallToneAudioPlayer: CallToneAudioPlaying {
  struct PlayedTone: Equatable {
    let frequency: Double
    let duration: TimeInterval
  }

  private(set) var playedTones: [PlayedTone] = []
  private(set) var stopCount: Int = 0

  func playTone(frequency: Double, duration: TimeInterval) {
    playedTones.append(PlayedTone(frequency: frequency, duration: duration))
  }

  func stop() {
    stopCount += 1
  }
}

private final class SpyCallToneRepeatingTimer: CallToneRepeatingTimer {
  let interval: TimeInterval
  private let handler: () -> Void
  private(set) var invalidateCount: Int = 0

  init(interval: TimeInterval, handler: @escaping () -> Void) {
    self.interval = interval
    self.handler = handler
  }

  func fire() {
    handler()
  }

  func invalidate() {
    invalidateCount += 1
  }
}

private final class SpyCallToneTimerScheduler: CallToneTimerScheduling {
  private(set) var scheduledTimers: [SpyCallToneRepeatingTimer] = []

  func scheduleRepeatingTimer(
    interval: TimeInterval,
    handler: @escaping () -> Void
  ) -> CallToneRepeatingTimer {
    let timer = SpyCallToneRepeatingTimer(interval: interval, handler: handler)
    scheduledTimers.append(timer)
    return timer
  }
}
