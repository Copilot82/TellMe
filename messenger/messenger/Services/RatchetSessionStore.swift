import CryptoKit
import Foundation

struct SkippedMessageKey: Codable, Equatable {
  let messageIndex: Int
  let key: String
}

struct RatchetSessionState: Codable, Equatable {
  let sessionStateVersion: Int
  let sessionId: String
  let conversationId: String
  let localUserHandle: String?
  let localDeviceId: String?
  let localIkDhPublic: String?
  let peerUserHandle: String
  let peerDeviceId: String
  let peerIkDhPublic: String?
  let rootKey: String
  let sendChainKey: String
  let receiveChainKey: String
  let sendCounter: Int
  let receiveCounter: Int
  let previousChainLength: Int
  let bootstrapDhPub: String?
  // DH Ratchet fields (v2: real Double Ratchet)
  let localRatchetPriv: String?
  let localRatchetPub: String?
  let remoteRatchetPub: String?
  let signedPrekeyId: String?
  let oneTimePrekeyId: String?
  let skippedMessageKeys: [SkippedMessageKey]
  let createdAt: Date
  let updatedAt: Date
}

extension RatchetSessionState {
  func advancing(
    rootKey: String,
    sendChainKey: String,
    receiveChainKey: String,
    sendCounter: Int,
    receiveCounter: Int,
    previousChainLength: Int,
    skippedMessageKeys: [SkippedMessageKey],
    localRatchetPriv: String?,
    localRatchetPub: String?,
    remoteRatchetPub: String?,
    bootstrapDhPub: String?,
    signedPrekeyId: String?,
    oneTimePrekeyId: String?
  ) -> RatchetSessionState {
    RatchetSessionState(
      sessionStateVersion: sessionStateVersion,
      sessionId: sessionId,
      conversationId: conversationId,
      localUserHandle: localUserHandle,
      localDeviceId: localDeviceId,
      localIkDhPublic: localIkDhPublic,
      peerUserHandle: peerUserHandle,
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: peerIkDhPublic,
      rootKey: rootKey,
      sendChainKey: sendChainKey,
      receiveChainKey: receiveChainKey,
      sendCounter: sendCounter,
      receiveCounter: receiveCounter,
      previousChainLength: previousChainLength,
      bootstrapDhPub: bootstrapDhPub,
      localRatchetPriv: localRatchetPriv,
      localRatchetPub: localRatchetPub,
      remoteRatchetPub: remoteRatchetPub,
      signedPrekeyId: signedPrekeyId,
      oneTimePrekeyId: oneTimePrekeyId,
      skippedMessageKeys: skippedMessageKeys,
      createdAt: createdAt,
      updatedAt: Date()
    )
  }
}

protocol RatchetSessionStoreProtocol {
  func configure(storageKey: SymmetricKey)
  func upsert(_ state: RatchetSessionState) throws
  func session(sessionId: String) throws -> RatchetSessionState?
  func sessions(conversationId: String) throws -> [RatchetSessionState]
  func remove(sessionId: String) throws
  func clear() throws
}

final class RatchetSessionStore: RatchetSessionStoreProtocol {
  private struct RatchetSessionsIndex: Codable {
    var sessions: [RatchetSessionState]
  }

  private let stateStore: SecureStateStoreProtocol
  private let storageKeyName: String
  private var storageKey: SymmetricKey?

  init(
    stateStore: SecureStateStoreProtocol,
    storageKeyName: String = "ratchet_sessions"
  ) {
    self.stateStore = stateStore
    self.storageKeyName = storageKeyName
  }

  func configure(storageKey: SymmetricKey) {
    self.storageKey = storageKey
    do {
      _ = try readIndex()
    } catch {
      stateStore.removeValue(for: storageKeyName)
    }
  }

  func upsert(_ state: RatchetSessionState) throws {
    var index: RatchetSessionsIndex = try readIndex()
    if let existingIndex: Int = index.sessions.firstIndex(where: { $0.sessionId == state.sessionId }) {
      index.sessions[existingIndex] = state
    } else {
      index.sessions.append(state)
    }
    try writeIndex(index)
  }

  func session(sessionId: String) throws -> RatchetSessionState? {
    let index: RatchetSessionsIndex = try readIndex()
    return index.sessions.first(where: { $0.sessionId == sessionId })
  }

  func sessions(conversationId: String) throws -> [RatchetSessionState] {
    let index: RatchetSessionsIndex = try readIndex()
    return index.sessions
      .filter { $0.conversationId == conversationId }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func remove(sessionId: String) throws {
    var index: RatchetSessionsIndex = try readIndex()
    index.sessions.removeAll(where: { $0.sessionId == sessionId })
    try writeIndex(index)
  }

  func clear() throws {
    stateStore.removeValue(for: storageKeyName)
  }

  private func readIndex() throws -> RatchetSessionsIndex {
    guard let storageKey else {
      return RatchetSessionsIndex(sessions: [])
    }
    return try stateStore.load(RatchetSessionsIndex.self, for: storageKeyName, storageKey: storageKey)
      ?? RatchetSessionsIndex(sessions: [])
  }

  private func writeIndex(_ index: RatchetSessionsIndex) throws {
    guard let storageKey else { return }
    try stateStore.save(index, for: storageKeyName, storageKey: storageKey)
  }
}
