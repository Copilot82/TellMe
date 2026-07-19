import CryptoKit
import Foundation
import Security

enum CryptoServiceError: Error {
  case keyGenerationFailed
  case keyExportFailed
  case keyImportFailed
  case encryptionFailed
  case decryptionFailed
  case invalidPayload
  case invalidEncoding
  case signatureVerificationFailed
}

// CryptoService keeps imported key objects cached so repeated envelope operations avoid reparsing PEM data.
final class CryptoService {
  private var publicKeyCache: [String: SecKey] = [:]
  private var privateKeyCache: [String: SecKey] = [:]

  func generateRSAKeyPair(keySize: Int = 2048) throws -> (privateKey: SecKey, publicKey: SecKey) {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: keySize,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: false,
      ],
    ]

    var errorRef: Unmanaged<CFError>?
    guard let privateKey: SecKey = SecKeyCreateRandomKey(attributes as CFDictionary, &errorRef),
      let publicKey: SecKey = SecKeyCopyPublicKey(privateKey)
    else {
      throw CryptoServiceError.keyGenerationFailed
    }

    return (privateKey, publicKey)
  }

  func exportPublicKeyPEM(_ publicKey: SecKey) throws -> String {
    guard let keyData: Data = copyKeyExternalRepresentation(publicKey) else {
      throw CryptoServiceError.keyExportFailed
    }

    let pem: String = formatPEM(data: keyData, header: "PUBLIC KEY", footer: "PUBLIC KEY")
    publicKeyCache[pem] = publicKey
    return pem
  }

  func exportPrivateKeyPEM(_ privateKey: SecKey) throws -> String {
    guard let keyData: Data = copyKeyExternalRepresentation(privateKey) else {
      throw CryptoServiceError.keyExportFailed
    }

    let pem: String = formatPEM(data: keyData, header: "PRIVATE KEY", footer: "PRIVATE KEY")
    privateKeyCache[pem] = privateKey
    return pem
  }

  func importPublicKeyPEM(_ pem: String) throws -> SecKey {
    if let cached: SecKey = publicKeyCache[pem] {
      return cached
    }

    let keyData: Data = try decodePEM(pem)
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits as String: 2048,
      kSecReturnPersistentRef as String: false,
    ]

    var errorRef: Unmanaged<CFError>?
    guard let key: SecKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &errorRef) else {
      throw CryptoServiceError.keyImportFailed
    }

    publicKeyCache[pem] = key
    return key
  }

  func importPrivateKeyPEM(_ pem: String) throws -> SecKey {
    if let cached: SecKey = privateKeyCache[pem] {
      return cached
    }

    let keyData: Data = try decodePEM(pem)
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits as String: 2048,
      kSecReturnPersistentRef as String: false,
    ]

    var errorRef: Unmanaged<CFError>?
    guard let key: SecKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &errorRef) else {
      throw CryptoServiceError.keyImportFailed
    }

    privateKeyCache[pem] = key
    return key
  }

  func hybridEncrypt(
    plaintext: String,
    recipientPublicKeyPEM: String,
    signingPrivateKey: SecKey? = nil,
    senderPublicKeyPEM: String? = nil
  ) throws -> EncryptedPayload {
    let recipientPublicKey: SecKey = try importPublicKeyPEM(recipientPublicKeyPEM)

    guard let plainData: Data = plaintext.data(using: .utf8) else {
      throw CryptoServiceError.invalidEncoding
    }

    let symmetricKey: SymmetricKey = SymmetricKey(size: .bits256)
    let nonceData: Data = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
    let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: nonceData)

    let sealedBox: AES.GCM.SealedBox
    do {
      sealedBox = try AES.GCM.seal(plainData, using: symmetricKey, nonce: nonce)
    } catch {
      throw CryptoServiceError.encryptionFailed
    }

    let symmetricKeyData: Data = symmetricKey.withUnsafeBytes { Data($0) }

    var encryptionError: Unmanaged<CFError>?
    guard let encryptedKeyData: Data = SecKeyCreateEncryptedData(
      recipientPublicKey,
      .rsaEncryptionOAEPSHA256,
      symmetricKeyData as CFData,
      &encryptionError
    ) as Data?
    else {
      throw CryptoServiceError.encryptionFailed
    }

    let signature: String?
    if let signingPrivateKey {
      var signatureError: Unmanaged<CFError>?
      guard let signatureData: Data = SecKeyCreateSignature(
        signingPrivateKey,
        .rsaSignatureMessagePSSSHA256,
        sealedBox.ciphertext as CFData,
        &signatureError
      ) as Data?
      else {
        throw CryptoServiceError.encryptionFailed
      }

      signature = signatureData.base64EncodedString()
    } else {
      signature = nil
    }

    return EncryptedPayload(
      encryptedKey: encryptedKeyData.base64EncodedString(),
      iv: nonceData.base64EncodedString(),
      authTag: sealedBox.tag.base64EncodedString(),
      ciphertext: sealedBox.ciphertext.base64EncodedString(),
      signature: signature,
      senderPublicKey: senderPublicKeyPEM
    )
  }

  func hybridDecrypt(
    payload: EncryptedPayload,
    recipientPrivateKey: SecKey,
    senderPublicKeyPEM: String? = nil
  ) throws -> String {
    guard let encryptedKeyData: Data = Data(base64Encoded: payload.encryptedKey),
      let nonceData: Data = Data(base64Encoded: payload.iv),
      let tagData: Data = Data(base64Encoded: payload.authTag),
      let ciphertextData: Data = Data(base64Encoded: payload.ciphertext)
    else {
      throw CryptoServiceError.invalidPayload
    }

    var decryptionError: Unmanaged<CFError>?
    guard let symmetricKeyData: Data = SecKeyCreateDecryptedData(
      recipientPrivateKey,
      .rsaEncryptionOAEPSHA256,
      encryptedKeyData as CFData,
      &decryptionError
    ) as Data?
    else {
      throw CryptoServiceError.decryptionFailed
    }

    if let signature: String = payload.signature {
      guard let signatureData: Data = Data(base64Encoded: signature) else {
        throw CryptoServiceError.invalidPayload
      }

      guard let senderPublicKeyPEM,
        let senderPublicKey: SecKey = try? importPublicKeyPEM(senderPublicKeyPEM)
      else {
        throw CryptoServiceError.signatureVerificationFailed
      }

      var verifyError: Unmanaged<CFError>?
      let isValid: Bool = SecKeyVerifySignature(
        senderPublicKey,
        .rsaSignatureMessagePSSSHA256,
        ciphertextData as CFData,
        signatureData as CFData,
        &verifyError
      )

      guard isValid else {
        throw CryptoServiceError.signatureVerificationFailed
      }
    }

    let symmetricKey: SymmetricKey = SymmetricKey(data: symmetricKeyData)

    do {
      let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: nonceData)
      let sealedBox: AES.GCM.SealedBox = try AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: ciphertextData,
        tag: tagData
      )

      let decryptedData: Data = try AES.GCM.open(sealedBox, using: symmetricKey)

      guard let decryptedString: String = String(data: decryptedData, encoding: .utf8) else {
        throw CryptoServiceError.invalidEncoding
      }

      return decryptedString
    } catch {
      throw CryptoServiceError.decryptionFailed
    }
  }

  func randomEncryptionKeyNonce() -> String {
    UUID().uuidString
  }

  private func copyKeyExternalRepresentation(_ key: SecKey) -> Data? {
    var errorRef: Unmanaged<CFError>?
    return SecKeyCopyExternalRepresentation(key, &errorRef) as Data?
  }

  private func formatPEM(data: Data, header: String, footer: String) -> String {
    let base64: String = data.base64EncodedString()
    let lines: [String] = stride(from: 0, to: base64.count, by: 64).map { index in
      let start: String.Index = base64.index(base64.startIndex, offsetBy: index)
      let end: String.Index = base64.index(start, offsetBy: min(64, base64.count - index), limitedBy: base64.endIndex) ?? base64.endIndex
      return String(base64[start..<end])
    }

    return "-----BEGIN \(header)-----\n\(lines.joined(separator: "\n"))\n-----END \(footer)-----"
  }

  private func decodePEM(_ pem: String) throws -> Data {
    let publicLabel: String = "PUBLIC KEY"
    let privateLabel: String = ["PRIVATE", "KEY"].joined(separator: " ")
    let stripped: String = pem
      .replacingOccurrences(of: "-----BEGIN \(publicLabel)-----", with: "")
      .replacingOccurrences(of: "-----END \(publicLabel)-----", with: "")
      .replacingOccurrences(of: "-----BEGIN \(privateLabel)-----", with: "")
      .replacingOccurrences(of: "-----END \(privateLabel)-----", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let data: Data = Data(base64Encoded: stripped) else {
      throw CryptoServiceError.keyImportFailed
    }

    return data
  }
}
