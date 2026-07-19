import CryptoKit
import Foundation

@MainActor
final class LocalConversationArchiveService {
  private enum StorageKeys {
    static let localConversationsPrefix: String = "federated.local.conversations.v2"
    static let messageHistoryPrefix: String = "federated.local.messages.v2"
    static let editHistoryPrefix: String = "federated.local.message.edits.v2"
    static let replyPreviewPrefix: String = "federated.local.message.reply-previews.v2"
    static let pinnedMessagesPrefix: String = "federated.local.pins.v2"
    static let hiddenPinnedMessagesPrefix: String = "federated.local.hidden-pins.v2"
    static let hiddenMessagesPrefix: String = "federated.local.hidden-messages.v2"
    static let sentReadReceiptsPrefix: String = "federated.local.sent-read-receipts.v2"
    static let pendingReadReceiptsPrefix: String = "federated.local.pending-read-receipts.v2"
    static let deferredControlsPrefix: String = "federated.local.deferred-controls.v2"
  }

  private let defaults: UserDefaults
  private let secureStateStore: SecureStateStoreProtocol?
  private let keyMaterialStore: KeyMaterialStore?
  private let identityService: IdentityServiceProtocol?

  init(
    defaults: UserDefaults,
    secureStateStore: SecureStateStoreProtocol? = nil,
    keyMaterialStore: KeyMaterialStore? = nil,
    identityService: IdentityServiceProtocol? = nil
  ) {
    self.defaults = defaults
    self.secureStateStore = secureStateStore
    self.keyMaterialStore = keyMaterialStore
    self.identityService = identityService
  }

  func exportSnapshot(for userHandle: String) -> DeviceLinkLocalStateSnapshot {
    let normalizedUserHandle: String = normalize(userHandle)
    let conversations: [Conversation] = loadConversations(owner: normalizedUserHandle)
    let archives: [DeviceLinkConversationArchive] = conversations.map { conversation in
      DeviceLinkConversationArchive(
        conversation: conversation,
        messages: loadValue(
          [Message].self,
          key: conversationStorageKey(
            prefix: StorageKeys.messageHistoryPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        editsByMessageId: loadValue(
          [String: [MessageEdit]].self,
          key: conversationStorageKey(
            prefix: StorageKeys.editHistoryPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [:],
        replyPreviewByReplyMessageId: loadValue(
          [String: String].self,
          key: conversationStorageKey(
            prefix: StorageKeys.replyPreviewPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [:],
        pinnedMessages: loadValue(
          [PinnedMessage].self,
          key: conversationStorageKey(
            prefix: StorageKeys.pinnedMessagesPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        hiddenPinnedMessageIds: loadValue(
          [String].self,
          key: conversationStorageKey(
            prefix: StorageKeys.hiddenPinnedMessagesPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        hiddenMessageIds: loadValue(
          [String].self,
          key: conversationStorageKey(
            prefix: StorageKeys.hiddenMessagesPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        sentReadReceiptMessageIds: loadValue(
          [String].self,
          key: conversationStorageKey(
            prefix: StorageKeys.sentReadReceiptsPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        pendingReadReceiptMessageIds: loadValue(
          [String].self,
          key: conversationStorageKey(
            prefix: StorageKeys.pendingReadReceiptsPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? [],
        deferredControlMessages: loadValue(
          [Message].self,
          key: conversationStorageKey(
            prefix: StorageKeys.deferredControlsPrefix,
            owner: normalizedUserHandle,
            conversationId: conversation.id
          )
        ) ?? []
      )
    }

    return DeviceLinkLocalStateSnapshot(
      exportedAt: Date(),
      conversations: archives
    )
  }

  func importSnapshot(_ snapshot: DeviceLinkLocalStateSnapshot, for userHandle: String) {
    let normalizedUserHandle: String = normalize(userHandle)
    let existingConversationIds: Set<String> = Set(loadConversations(owner: normalizedUserHandle).map(\.id))
    let incomingConversationIds: Set<String> = Set(snapshot.conversations.map(\.conversation.id))

    for conversationId in existingConversationIds.union(incomingConversationIds) {
      removeConversationState(owner: normalizedUserHandle, conversationId: conversationId)
    }

    saveConversations(snapshot.conversations.map(\.conversation), owner: normalizedUserHandle)

    for archive in snapshot.conversations {
      saveValue(
        archive.messages,
        key: conversationStorageKey(
          prefix: StorageKeys.messageHistoryPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.editsByMessageId,
        key: conversationStorageKey(
          prefix: StorageKeys.editHistoryPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.replyPreviewByReplyMessageId,
        key: conversationStorageKey(
          prefix: StorageKeys.replyPreviewPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.pinnedMessages,
        key: conversationStorageKey(
          prefix: StorageKeys.pinnedMessagesPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.hiddenPinnedMessageIds ?? [],
        key: conversationStorageKey(
          prefix: StorageKeys.hiddenPinnedMessagesPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.hiddenMessageIds,
        key: conversationStorageKey(
          prefix: StorageKeys.hiddenMessagesPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.sentReadReceiptMessageIds,
        key: conversationStorageKey(
          prefix: StorageKeys.sentReadReceiptsPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.pendingReadReceiptMessageIds,
        key: conversationStorageKey(
          prefix: StorageKeys.pendingReadReceiptsPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
      saveValue(
        archive.deferredControlMessages,
        key: conversationStorageKey(
          prefix: StorageKeys.deferredControlsPrefix,
          owner: normalizedUserHandle,
          conversationId: archive.conversation.id
        )
      )
    }
  }

  private func removeConversationState(owner: String, conversationId: String) {
    let prefixes: [String] = [
      StorageKeys.messageHistoryPrefix,
      StorageKeys.editHistoryPrefix,
      StorageKeys.replyPreviewPrefix,
      StorageKeys.pinnedMessagesPrefix,
      StorageKeys.hiddenPinnedMessagesPrefix,
      StorageKeys.hiddenMessagesPrefix,
      StorageKeys.sentReadReceiptsPrefix,
      StorageKeys.pendingReadReceiptsPrefix,
      StorageKeys.deferredControlsPrefix,
    ]

    for prefix in prefixes {
      let key: String = conversationStorageKey(
        prefix: prefix,
        owner: owner,
        conversationId: conversationId
      )
      defaults.removeObject(forKey: key)
      secureStateStore?.removeValue(for: key)
    }
  }

  private func loadConversations(owner: String) -> [Conversation] {
    loadValue([Conversation].self, key: conversationsStorageKey(owner: owner)) ?? []
  }

  private func saveConversations(_ conversations: [Conversation], owner: String) {
    saveValue(conversations, key: conversationsStorageKey(owner: owner))
  }

  private func loadValue<T: Codable>(_ type: T.Type, key: String) -> T? {
    if let storageKey = resolvedStorageKey(),
      let secureStateStore,
      let value = try? secureStateStore.load(type, for: key, storageKey: storageKey)
    {
      return value
    }

    guard let data: Data = defaults.data(forKey: key),
      let value: T = try? JSONCoding.decoder.decode(type, from: data)
    else {
      return nil
    }

    migrateLegacyValueIfNeeded(value, key: key)
    return value
  }

  private func saveValue<T: Codable>(_ value: T, key: String) {
    if let storageKey = resolvedStorageKey(),
      let secureStateStore
    {
      do {
        try secureStateStore.save(value, for: key, storageKey: storageKey)
        defaults.removeObject(forKey: key)
        return
      } catch {
        // Fallback to legacy storage to avoid dropping the archive snapshot.
      }
    }

    guard let data: Data = try? JSONCoding.encoder.encode(value) else {
      defaults.removeObject(forKey: key)
      secureStateStore?.removeValue(for: key)
      return
    }

    defaults.set(data, forKey: key)
  }

  private func conversationsStorageKey(owner: String) -> String {
    let digest = SHA256.hash(data: Data(owner.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.localConversationsPrefix).\(suffix)"
  }

  private func conversationStorageKey(prefix: String, owner: String, conversationId: String) -> String {
    let rawKey: String = "\(owner)|\(normalize(conversationId))"
    let digest = SHA256.hash(data: Data(rawKey.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(prefix).\(suffix)"
  }

  private func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func resolvedStorageKey() -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: keyMaterialStore?.currentUserId,
      sessionUser: nil,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )
  }

  private func migrateLegacyValueIfNeeded<T: Codable>(_ value: T, key: String) {
    guard let storageKey = resolvedStorageKey(),
      let secureStateStore
    else {
      return
    }

    do {
      try secureStateStore.save(value, for: key, storageKey: storageKey)
      defaults.removeObject(forKey: key)
    } catch {
      // Keep plaintext fallback if secure migration fails.
    }
  }
}
