import CryptoKit
import Foundation

struct DerivedIdentityKeys {
  let ikSignPrivate: Curve25519.Signing.PrivateKey
  let ikSignPublicBase64: String
  let ikDHPrivate: Curve25519.KeyAgreement.PrivateKey
  let ikDHPublicBase64: String
  let storageKey: SymmetricKey
}

struct AEADCiphertextEnvelope: Codable, Equatable {
  let nonce: String
  let ciphertext: String
  let tag: String
  let aad: String?
}

extension CryptoService {
  func generateSeed(bytes: Int = 32) -> Data {
    Data((0..<bytes).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
  }

  func hkdfSHA256(inputKeyMaterial: Data, salt: Data = Data(), info: Data, outputLength: Int = 32) -> Data {
    let ikm: SymmetricKey = SymmetricKey(data: inputKeyMaterial)
    let derived: SymmetricKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: ikm,
      salt: salt,
      info: info,
      outputByteCount: outputLength
    )
    return derived.withUnsafeBytes { Data($0) }
  }

  func deriveIdentityKeys(seed: Data) throws -> DerivedIdentityKeys {
    let signSeed: Data = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("ik_sign_seed".utf8),
      outputLength: 32
    )
    let dhSeed: Data = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("ik_dh_seed".utf8),
      outputLength: 32
    )
    let storageSeed: Data = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("storage_key".utf8),
      outputLength: 32
    )

    let ikSignPrivate: Curve25519.Signing.PrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signSeed)
    let ikDHPrivate: Curve25519.KeyAgreement.PrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSeed)
    let storageKey: SymmetricKey = SymmetricKey(data: storageSeed)

    return DerivedIdentityKeys(
      ikSignPrivate: ikSignPrivate,
      ikSignPublicBase64: ikSignPrivate.publicKey.rawRepresentation.base64EncodedString(),
      ikDHPrivate: ikDHPrivate,
      ikDHPublicBase64: ikDHPrivate.publicKey.rawRepresentation.base64EncodedString(),
      storageKey: storageKey
    )
  }

  func signEd25519(message: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
    let signature: Data = try privateKey.signature(for: message)
    return signature.base64EncodedString()
  }

  func verifyEd25519(message: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
    guard
      let signatureData: Data = Data(base64Encoded: signatureBase64),
      let publicKeyData: Data = Data(base64Encoded: publicKeyBase64),
      let publicKey: Curve25519.Signing.PublicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
      return false
    }

    return publicKey.isValidSignature(signatureData, for: message)
  }

  func x25519SharedSecret(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    peerPublicBase64: String
  ) throws -> SharedSecret {
    guard let peerData: Data = Data(base64Encoded: peerPublicBase64) else {
      throw CryptoServiceError.keyImportFailed
    }

    let peerKey: Curve25519.KeyAgreement.PublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
    return try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
  }

  func deriveSymmetricKey(sharedSecret: SharedSecret, context: String, outputLength: Int = 32) -> SymmetricKey {
    sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(),
      sharedInfo: Data(context.utf8),
      outputByteCount: outputLength
    )
  }

  func encryptAEAD(
    plaintext: Data,
    key: SymmetricKey,
    aad: Data? = nil
  ) throws -> AEADCiphertextEnvelope {
    let nonceData: Data = Data((0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: nonceData)
    let sealed: AES.GCM.SealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad ?? Data())

    return AEADCiphertextEnvelope(
      nonce: nonceData.base64EncodedString(),
      ciphertext: sealed.ciphertext.base64EncodedString(),
      tag: sealed.tag.base64EncodedString(),
      aad: aad?.base64EncodedString()
    )
  }

  func decryptAEAD(
    envelope: AEADCiphertextEnvelope,
    key: SymmetricKey
  ) throws -> Data {
    guard
      let nonceData: Data = Data(base64Encoded: envelope.nonce),
      let ciphertextData: Data = Data(base64Encoded: envelope.ciphertext),
      let tagData: Data = Data(base64Encoded: envelope.tag)
    else {
      throw CryptoServiceError.invalidPayload
    }

    let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: nonceData)
    let sealed: AES.GCM.SealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )

    let aad: Data = envelope.aad.flatMap { Data(base64Encoded: $0) } ?? Data()
    return try AES.GCM.open(sealed, using: key, authenticating: aad)
  }
}
