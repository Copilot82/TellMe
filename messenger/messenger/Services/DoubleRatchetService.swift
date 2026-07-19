import CryptoKit
import Foundation

enum DoubleRatchetServiceError: Error {
  case invalidChainKey
  case messageIndexTooOld
  case skipWindowExceeded
  case missingRatchetKey
}

struct RatchetStepResult: Equatable {
  let messageKey: SymmetricKey
  let nextState: RatchetSessionState
  let messageIndex: Int
}

protocol DoubleRatchetServiceProtocol {
  func nextSendStep(state: RatchetSessionState) throws -> RatchetStepResult
  func nextReceiveStep(state: RatchetSessionState, messageIndex: Int) throws -> RatchetStepResult
  func nextReceiveStep(state: RatchetSessionState, messageIndex: Int, ratchetPub: String?) throws -> RatchetStepResult
  func performDHRatchetStep(state: RatchetSessionState, newRemoteRatchetPub: String) throws -> RatchetSessionState
}

/// Advances Double Ratchet state without mutating storage.
///
/// Returning a value lets callers persist decrypted content and the advanced state in one
/// transaction. Persisting either side alone can reuse a message key or make a message unreadable.
final class DoubleRatchetService: DoubleRatchetServiceProtocol {
  private let maxSkipWindow: Int

  init(maxSkipWindow: Int = 128) {
    self.maxSkipWindow = max(1, maxSkipWindow)
  }

  func nextSendStep(state: RatchetSessionState) throws -> RatchetStepResult {
    guard let chainData = Data(base64Encoded: state.sendChainKey), !state.sendChainKey.isEmpty else {
      throw DoubleRatchetServiceError.invalidChainKey
    }
    let counter = state.sendCounter + 1
    let material = kdfChainKey(chainKey: chainData)

    let nextState = state.advancing(
      rootKey: state.rootKey,
      sendChainKey: material.nextChainKey.base64EncodedString(),
      receiveChainKey: state.receiveChainKey,
      sendCounter: counter,
      receiveCounter: state.receiveCounter,
      previousChainLength: state.previousChainLength,
      skippedMessageKeys: state.skippedMessageKeys,
      localRatchetPriv: state.localRatchetPriv,
      localRatchetPub: state.localRatchetPub,
      remoteRatchetPub: state.remoteRatchetPub,
      bootstrapDhPub: nil,
      signedPrekeyId: nil,
      oneTimePrekeyId: nil
    )
    return RatchetStepResult(
      messageKey: SymmetricKey(data: material.messageKey),
      nextState: nextState,
      messageIndex: counter
    )
  }

  func nextReceiveStep(state: RatchetSessionState, messageIndex: Int) throws -> RatchetStepResult {
    try nextReceiveStep(state: state, messageIndex: messageIndex, ratchetPub: nil)
  }

  func nextReceiveStep(state: RatchetSessionState, messageIndex: Int, ratchetPub: String?) throws -> RatchetStepResult {
    // A cached key is single-use: removing it from nextState prevents replay decryption while
    // still allowing an out-of-order message that arrived behind the current receive counter.
    if let skipped = state.skippedMessageKeys.first(where: { $0.messageIndex == messageIndex }),
       let messageKeyData = Data(base64Encoded: skipped.key)
    {
      let nextState = state.advancing(
        rootKey: state.rootKey,
        sendChainKey: state.sendChainKey,
        receiveChainKey: state.receiveChainKey,
        sendCounter: state.sendCounter,
        receiveCounter: state.receiveCounter,
        previousChainLength: state.previousChainLength,
        skippedMessageKeys: state.skippedMessageKeys.filter { $0.messageIndex != messageIndex },
        localRatchetPriv: state.localRatchetPriv,
        localRatchetPub: state.localRatchetPub,
        remoteRatchetPub: state.remoteRatchetPub,
        bootstrapDhPub: nil,
        signedPrekeyId: nil,
        oneTimePrekeyId: nil
      )
      return RatchetStepResult(
        messageKey: SymmetricKey(data: messageKeyData),
        nextState: nextState,
        messageIndex: messageIndex
      )
    }

    // A changed authenticated ratchet public key starts a new receiving epoch before any
    // symmetric-chain keys are derived for that epoch.
    var workingState = state
    if let newRatchetPub = ratchetPub,
       !newRatchetPub.isEmpty,
       newRatchetPub != state.remoteRatchetPub,
       state.localRatchetPriv != nil
    {
      workingState = try performDHRatchetStep(state: state, newRemoteRatchetPub: newRatchetPub)
    }

    // The bound limits both attacker-controlled KDF work and retained skipped-key material.
    guard messageIndex > workingState.receiveCounter else {
      throw DoubleRatchetServiceError.messageIndexTooOld
    }
    guard messageIndex - workingState.receiveCounter <= maxSkipWindow else {
      throw DoubleRatchetServiceError.skipWindowExceeded
    }
    guard !workingState.receiveChainKey.isEmpty,
          let chainData = Data(base64Encoded: workingState.receiveChainKey)
    else {
      throw DoubleRatchetServiceError.invalidChainKey
    }

    var currentChainKey = chainData
    var currentCounter = workingState.receiveCounter
    var skippedMessageKeys = workingState.skippedMessageKeys

    while currentCounter < messageIndex {
      let nextCounter = currentCounter + 1
      let material = kdfChainKey(chainKey: currentChainKey)

      if nextCounter < messageIndex {
        skippedMessageKeys.append(
          SkippedMessageKey(messageIndex: nextCounter, key: material.messageKey.base64EncodedString())
        )
      }

      currentChainKey = material.nextChainKey
      currentCounter = nextCounter

      if currentCounter == messageIndex {
        let boundedSkipped = Array(
          skippedMessageKeys
            .sorted { $0.messageIndex < $1.messageIndex }
            .suffix(maxSkipWindow)
        )
        let nextState = workingState.advancing(
          rootKey: workingState.rootKey,
          sendChainKey: workingState.sendChainKey,
          receiveChainKey: currentChainKey.base64EncodedString(),
          sendCounter: workingState.sendCounter,
          receiveCounter: currentCounter,
          previousChainLength: workingState.previousChainLength,
          skippedMessageKeys: boundedSkipped,
          localRatchetPriv: workingState.localRatchetPriv,
          localRatchetPub: workingState.localRatchetPub,
          remoteRatchetPub: workingState.remoteRatchetPub,
          bootstrapDhPub: nil,
          signedPrekeyId: nil,
          oneTimePrekeyId: nil
        )
        return RatchetStepResult(
          messageKey: SymmetricKey(data: material.messageKey),
          nextState: nextState,
          messageIndex: messageIndex
        )
      }
    }

    throw DoubleRatchetServiceError.messageIndexTooOld
  }

  func performDHRatchetStep(state: RatchetSessionState, newRemoteRatchetPub: String) throws -> RatchetSessionState {
    guard let localPrivData = state.localRatchetPriv.flatMap({ Data(base64Encoded: $0) }) else {
      throw DoubleRatchetServiceError.missingRatchetKey
    }
    guard let rootKeyData = Data(base64Encoded: state.rootKey) else {
      throw DoubleRatchetServiceError.invalidChainKey
    }
    guard let remotePubData = Data(base64Encoded: newRemoteRatchetPub) else {
      throw DoubleRatchetServiceError.missingRatchetKey
    }

    let localPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localPrivData)
    let remotePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePubData)

    // Derive the receive epoch with the previous local key and the peer's new public key.
    let dh1 = try localPriv.sharedSecretFromKeyAgreement(with: remotePub)
    let dh1Data = dh1.withUnsafeBytes { Data($0) }
    let (rootKey2, recvChainKey) = kdfRootKey(rootKey: rootKeyData, dhOutput: dh1Data)

    // Rotate the local key before deriving the sending epoch; reusing localPriv would collapse
    // both directions onto the same DH output.
    let newLocalPriv = Curve25519.KeyAgreement.PrivateKey()
    let newLocalPub = newLocalPriv.publicKey

    // Chaining through rootKey2 binds the sending epoch to the receive transition above.
    let dh2 = try newLocalPriv.sharedSecretFromKeyAgreement(with: remotePub)
    let dh2Data = dh2.withUnsafeBytes { Data($0) }
    let (rootKey3, sendChainKey) = kdfRootKey(rootKey: rootKey2, dhOutput: dh2Data)

    return state.advancing(
      rootKey: rootKey3.base64EncodedString(),
      sendChainKey: sendChainKey.base64EncodedString(),
      receiveChainKey: recvChainKey.base64EncodedString(),
      sendCounter: 0,
      receiveCounter: state.receiveCounter,
      previousChainLength: state.receiveCounter,
      skippedMessageKeys: state.skippedMessageKeys,
      localRatchetPriv: newLocalPriv.rawRepresentation.base64EncodedString(),
      localRatchetPub: newLocalPub.rawRepresentation.base64EncodedString(),
      remoteRatchetPub: newRemoteRatchetPub,
      bootstrapDhPub: nil,
      signedPrekeyId: nil,
      oneTimePrekeyId: nil
    )
  }

  /// KDF_RK: HKDF-SHA256(IKM=dhOutput, salt=rootKey, info="DR_RATCHET") → 64 bytes
  private func kdfRootKey(rootKey: Data, dhOutput: Data) -> (newRootKey: Data, chainKey: Data) {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: dhOutput),
      salt: rootKey,
      info: Data("DR_RATCHET".utf8),
      outputByteCount: 64
    )
    let derivedData = derived.withUnsafeBytes { Data($0) }
    return (Data(derivedData.prefix(32)), Data(derivedData.suffix(32)))
  }

  /// KDF_CK: Signal-standard HMAC constants (0x01 → messageKey, 0x02 → nextChainKey)
  private func kdfChainKey(chainKey: Data) -> (messageKey: Data, nextChainKey: Data) {
    let key = SymmetricKey(data: chainKey)
    let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key)
    let ck = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key)
    return (Data(mk), Data(ck))
  }
}
