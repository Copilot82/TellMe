import CryptoKit
import Foundation

enum X3DHServiceError: Error {
  case invalidDeviceIdentity
  case invalidPeerBundle
  case missingSignedPrekeyPrivate
  case missingOneTimePrekeyPrivate
}

struct X3DHInitiationResult: Codable, Equatable {
  let rootKey: String
  let sendChainKey: String
  let receiveChainKey: String
  let ephemeralPub: String
}

protocol X3DHServiceProtocol {
  func initiateSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    peerBundle: FederatedPrekeyBundle,
    conversationId: String
  ) throws -> RatchetSessionState

  func receiveSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    prekeyPrivateStore: PrekeyPrivateStoreProtocol,
    ephemeralPub: String,
    senderDeviceDhPub: String,
    signedPrekeyId: String,
    oneTimePrekeyId: String?,
    sessionId: String,
    conversationId: String,
    peerUserHandle: String,
    peerDeviceId: String
  ) throws -> RatchetSessionState

  func initiate(deviceIdentity: PersistedDeviceIdentity, peerBundle: FederatedPrekeyBundle) throws -> X3DHInitiationResult

  func bootstrapSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    localDeviceId: String,
    peerUserHandle: String,
    peerDeviceId: String,
    peerIkDhPublic: String,
    sessionId: String?,
    conversationId: String,
    isInitiator: Bool
  ) throws -> RatchetSessionState

  func bootstrapSession(
    seedPhrase: String,
    localUserHandle: String,
    localDeviceId: String,
    peerUserHandle: String,
    peerDeviceId: String,
    peerIkDhPublic: String,
    sessionId: String?,
    conversationId: String
  ) throws -> RatchetSessionState
}

/// Establishes per-device session material and returns ratchet state without persisting it.
/// Callers must commit the state only after the corresponding envelope transition succeeds.
final class X3DHService: X3DHServiceProtocol {
  private let cryptoService: CryptoService
  private let seedService: SeedServiceProtocol

  init(seedService: SeedServiceProtocol, cryptoService: CryptoService) {
    self.seedService = seedService
    self.cryptoService = cryptoService
  }

  // MARK: - Real X3DH (Initiator: Alice → Bob)

  func initiateSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    peerBundle: FederatedPrekeyBundle,
    conversationId: String
  ) throws -> RatchetSessionState {
    guard let ikPrivData = Data(base64Encoded: deviceIdentity.dkDhPrivate) else {
      throw X3DHServiceError.invalidDeviceIdentity
    }
    let ikPriv_A = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ikPrivData)

    guard let ikDhPubData_B = Data(base64Encoded: peerBundle.deviceDhPub),
          let spkPubData_B = Data(base64Encoded: peerBundle.signedPrekey.signedPrekeyPub)
    else {
      throw X3DHServiceError.invalidPeerBundle
    }
    let ikDhPub_B = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ikDhPubData_B)
    let spkPub_B = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: spkPubData_B)

    let ek_A = Curve25519.KeyAgreement.PrivateKey()
    let ekPub_A = ek_A.publicKey

    let dh1 = try ikPriv_A.sharedSecretFromKeyAgreement(with: spkPub_B)
    let dh2 = try ek_A.sharedSecretFromKeyAgreement(with: ikDhPub_B)
    let dh3 = try ek_A.sharedSecretFromKeyAgreement(with: spkPub_B)

    // Both peers must concatenate the DH outputs in protocol order. Sorting or using a
    // dictionary here would derive different session keys even though every DH value matches.
    var ikm = Data()
    ikm.append(dh1.withUnsafeBytes { Data($0) })
    ikm.append(dh2.withUnsafeBytes { Data($0) })
    ikm.append(dh3.withUnsafeBytes { Data($0) })

    var oneTimePrekeyId: String? = nil
    if let opk = peerBundle.oneTimePrekey,
       let opkPubData = Data(base64Encoded: opk.prekeyPub),
       let opkPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: opkPubData)
    {
      let dh4 = try ek_A.sharedSecretFromKeyAgreement(with: opkPub)
      ikm.append(dh4.withUnsafeBytes { Data($0) })
      oneTimePrekeyId = opk.prekeyId
    }

    // The context label separates protocol v2 session material from every other HKDF use.
    let salt = Data(repeating: 0x00, count: 32)
    let masterSecret = hkdfExpand(ikm: ikm, salt: salt, info: Data("x3dh_v2".utf8), length: 64)
    let rootKey = masterSecret.prefix(32)
    let sendChainKey = masterSecret.suffix(32)

    let sessionId = UUID().uuidString.lowercased()

    return RatchetSessionState(
      sessionStateVersion: 2,
      sessionId: sessionId,
      conversationId: conversationId,
      localUserHandle: normalized(localUserHandle),
      localDeviceId: deviceIdentity.deviceId,
      localIkDhPublic: deviceIdentity.dkDhPublic,
      peerUserHandle: normalized(peerBundle.userHandle),
      peerDeviceId: peerBundle.deviceId,
      peerIkDhPublic: peerBundle.deviceDhPub,
      rootKey: Data(rootKey).base64EncodedString(),
      sendChainKey: Data(sendChainKey).base64EncodedString(),
      receiveChainKey: Data(sendChainKey).base64EncodedString(),
      sendCounter: 0,
      receiveCounter: 0,
      previousChainLength: 0,
      bootstrapDhPub: ekPub_A.rawRepresentation.base64EncodedString(),
      localRatchetPriv: ek_A.rawRepresentation.base64EncodedString(),
      localRatchetPub: ekPub_A.rawRepresentation.base64EncodedString(),
      remoteRatchetPub: peerBundle.signedPrekey.signedPrekeyPub,
      signedPrekeyId: peerBundle.signedPrekey.prekeyId,
      oneTimePrekeyId: oneTimePrekeyId,
      skippedMessageKeys: [],
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  func receiveSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    prekeyPrivateStore: PrekeyPrivateStoreProtocol,
    ephemeralPub: String,
    senderDeviceDhPub: String,
    signedPrekeyId: String,
    oneTimePrekeyId: String?,
    sessionId: String,
    conversationId: String,
    peerUserHandle: String,
    peerDeviceId: String
  ) throws -> RatchetSessionState {
    guard let ikPrivData = Data(base64Encoded: deviceIdentity.dkDhPrivate) else {
      throw X3DHServiceError.invalidDeviceIdentity
    }
    let ikPriv_B = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ikPrivData)

    guard let spkPrivData = prekeyPrivateStore.loadSignedPrekey(
      deviceId: deviceIdentity.deviceId,
      prekeyId: signedPrekeyId
    ) else {
      throw X3DHServiceError.missingSignedPrekeyPrivate
    }
    let spkPriv_B = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: spkPrivData)

    guard let ekPubData_A = Data(base64Encoded: ephemeralPub),
          let ikDhPubData_A = Data(base64Encoded: senderDeviceDhPub)
    else {
      throw X3DHServiceError.invalidPeerBundle
    }
    let ekPub_A = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ekPubData_A)
    let ikDhPub_A = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ikDhPubData_A)

    let dh1 = try spkPriv_B.sharedSecretFromKeyAgreement(with: ikDhPub_A)
    let dh2 = try ikPriv_B.sharedSecretFromKeyAgreement(with: ekPub_A)
    let dh3 = try spkPriv_B.sharedSecretFromKeyAgreement(with: ekPub_A)

    // This mirrors the initiator's DH1...DH4 order, not the receiver's local call order.
    var ikm = Data()
    ikm.append(dh1.withUnsafeBytes { Data($0) })
    ikm.append(dh2.withUnsafeBytes { Data($0) })
    ikm.append(dh3.withUnsafeBytes { Data($0) })

    if let opkId = oneTimePrekeyId {
      guard let opkPrivData = prekeyPrivateStore.loadOneTimePrekey(
        deviceId: deviceIdentity.deviceId,
        prekeyId: opkId
      ) else {
        throw X3DHServiceError.missingOneTimePrekeyPrivate
      }
      let opkPriv_B = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: opkPrivData)
      let dh4 = try opkPriv_B.sharedSecretFromKeyAgreement(with: ekPub_A)
      ikm.append(dh4.withUnsafeBytes { Data($0) })
    }

    let salt = Data(repeating: 0x00, count: 32)
    let masterSecret = hkdfExpand(ikm: ikm, salt: salt, info: Data("x3dh_v2".utf8), length: 64)
    let initialRootKey = Data(masterSecret.prefix(32))
    let receiveChainKey = Data(masterSecret.suffix(32))
    let localRatchet_B = Curve25519.KeyAgreement.PrivateKey()
    // The receiver opens the initial message on the X3DH-derived chain, then creates a
    // distinct sending epoch so its first reply advances the DH ratchet immediately.
    let dhRatchet = try localRatchet_B.sharedSecretFromKeyAgreement(with: ekPub_A)
    let dhRatchetData = dhRatchet.withUnsafeBytes { Data($0) }
    let (postReceiveRootKey, sendChainKey) = kdfRootKey(rootKey: initialRootKey, dhOutput: dhRatchetData)

    return RatchetSessionState(
      sessionStateVersion: 2,
      sessionId: sessionId,
      conversationId: conversationId,
      localUserHandle: normalized(localUserHandle),
      localDeviceId: deviceIdentity.deviceId,
      localIkDhPublic: deviceIdentity.dkDhPublic,
      peerUserHandle: normalized(peerUserHandle),
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: senderDeviceDhPub,
      rootKey: postReceiveRootKey.base64EncodedString(),
      sendChainKey: sendChainKey.base64EncodedString(),
      receiveChainKey: receiveChainKey.base64EncodedString(),
      sendCounter: 0,
      receiveCounter: 0,
      previousChainLength: 0,
      bootstrapDhPub: nil,
      localRatchetPriv: localRatchet_B.rawRepresentation.base64EncodedString(),
      localRatchetPub: localRatchet_B.publicKey.rawRepresentation.base64EncodedString(),
      remoteRatchetPub: ephemeralPub,
      signedPrekeyId: signedPrekeyId,
      oneTimePrekeyId: oneTimePrekeyId,
      skippedMessageKeys: [],
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  // MARK: - Legacy compatibility

  func initiate(deviceIdentity: PersistedDeviceIdentity, peerBundle: FederatedPrekeyBundle) throws -> X3DHInitiationResult {
    let state = try bootstrapSession(
      deviceIdentity: deviceIdentity,
      localUserHandle: "@local:local",
      localDeviceId: deviceIdentity.deviceId,
      peerUserHandle: peerBundle.userHandle,
      peerDeviceId: peerBundle.deviceId,
      peerIkDhPublic: peerBundle.deviceDhPub,
      sessionId: nil,
      conversationId: "local-conversation",
      isInitiator: true
    )
    return X3DHInitiationResult(
      rootKey: state.rootKey,
      sendChainKey: state.sendChainKey,
      receiveChainKey: state.receiveChainKey,
      ephemeralPub: state.localRatchetPub ?? ""
    )
  }

  func bootstrapSession(
    seedPhrase: String,
    localUserHandle: String,
    localDeviceId: String,
    peerUserHandle: String,
    peerDeviceId: String,
    peerIkDhPublic: String,
    sessionId: String? = nil,
    conversationId: String
  ) throws -> RatchetSessionState {
    guard let seed = seedService.decodeSeedPhrase(seedPhrase) else {
      throw X3DHServiceError.invalidDeviceIdentity
    }
    let derived = try cryptoService.deriveIdentityKeys(seed: seed)
    let deviceIdentity = PersistedDeviceIdentity(
      deviceId: localDeviceId,
      dkSignPrivate: derived.ikSignPrivate.rawRepresentation.base64EncodedString(),
      dkSignPublic: derived.ikSignPublicBase64,
      dkDhPrivate: derived.ikDHPrivate.rawRepresentation.base64EncodedString(),
      dkDhPublic: derived.ikDHPublicBase64,
      deviceCertificateChain: [],
      createdAt: Date()
    )
    let normalizedLocal = normalized(localUserHandle)
    let normalizedPeer = normalized(peerUserHandle)
    // Legacy sessions have no explicit initiator bit. Stable account/device ordering prevents
    // both peers from selecting the same directional chain after restoring old state.
    let isInitiator = normalizedLocal < normalizedPeer
      || (normalizedLocal == normalizedPeer && localDeviceId < peerDeviceId)

    return try bootstrapSession(
      deviceIdentity: deviceIdentity,
      localUserHandle: localUserHandle,
      localDeviceId: localDeviceId,
      peerUserHandle: peerUserHandle,
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: peerIkDhPublic,
      sessionId: sessionId,
      conversationId: conversationId,
      isInitiator: isInitiator
    )
  }

  func bootstrapSession(
    deviceIdentity: PersistedDeviceIdentity,
    localUserHandle: String,
    localDeviceId: String,
    peerUserHandle: String,
    peerDeviceId: String,
    peerIkDhPublic: String,
    sessionId: String? = nil,
    conversationId: String,
    isInitiator: Bool
  ) throws -> RatchetSessionState {
    guard let privateKeyData = Data(base64Encoded: deviceIdentity.dkDhPrivate) else {
      throw X3DHServiceError.invalidDeviceIdentity
    }
    let identityPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
    let shared = try cryptoService.x25519SharedSecret(
      privateKey: identityPrivate,
      peerPublicBase64: peerIkDhPublic
    )
    let sharedData = shared.withUnsafeBytes { Data($0) }

    let resolvedSessionId = sessionId ?? UUID().uuidString.lowercased()
    let rootKey = cryptoService.hkdfSHA256(
      inputKeyMaterial: sharedData,
      info: Data("session_root|\(resolvedSessionId)".utf8),
      outputLength: 32
    )
    let sendLabel = isInitiator ? "chain_a" : "chain_b"
    let receiveLabel = isInitiator ? "chain_b" : "chain_a"
    let sendChain = cryptoService.hkdfSHA256(
      inputKeyMaterial: rootKey,
      info: Data("dr_\(sendLabel)".utf8),
      outputLength: 32
    )
    let receiveChain = cryptoService.hkdfSHA256(
      inputKeyMaterial: rootKey,
      info: Data("dr_\(receiveLabel)".utf8),
      outputLength: 32
    )

    return RatchetSessionState(
      sessionStateVersion: 2,
      sessionId: resolvedSessionId,
      conversationId: conversationId,
      localUserHandle: normalized(localUserHandle),
      localDeviceId: localDeviceId,
      localIkDhPublic: deviceIdentity.dkDhPublic,
      peerUserHandle: normalized(peerUserHandle),
      peerDeviceId: peerDeviceId,
      peerIkDhPublic: peerIkDhPublic,
      rootKey: rootKey.base64EncodedString(),
      sendChainKey: sendChain.base64EncodedString(),
      receiveChainKey: receiveChain.base64EncodedString(),
      sendCounter: 0,
      receiveCounter: 0,
      previousChainLength: 0,
      bootstrapDhPub: isInitiator ? deviceIdentity.dkDhPublic : peerIkDhPublic,
      localRatchetPriv: nil,
      localRatchetPub: nil,
      remoteRatchetPub: nil,
      signedPrekeyId: nil,
      oneTimePrekeyId: nil,
      skippedMessageKeys: [],
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

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

  private func hkdfExpand(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ikm),
      salt: salt,
      info: info,
      outputByteCount: length
    )
    return derived.withUnsafeBytes { Data($0) }
  }
}
