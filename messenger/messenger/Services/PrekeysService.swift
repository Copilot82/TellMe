import CryptoKit
import Foundation

struct SignedPrekeyBundle: Codable, Equatable {
  let prekeyId: String
  let signedPrekeyPub: String
  let signature: String
}

struct OneTimePrekeyBundle: Codable, Equatable {
  let prekeyId: String
  let prekeyPub: String
}

protocol PrekeysServiceProtocol {
  func generateSignedPrekey(deviceIdentity: PersistedDeviceIdentity) throws -> SignedPrekeyBundle
  func generateOneTimePrekeys(count: Int) -> [OneTimePrekeyBundle]
  func generateAndStoreSignedPrekey(deviceIdentity: PersistedDeviceIdentity) throws -> SignedPrekeyBundle
  func generateAndStoreOneTimePrekeys(count: Int, deviceId: String) throws -> [OneTimePrekeyBundle]
  func topUpOneTimePrekeysIfNeeded(deviceId: String, target: Int, lowWaterMark: Int) throws -> [OneTimePrekeyBundle]?
}

final class PrekeysService: PrekeysServiceProtocol {
  private let cryptoService: CryptoService
  private let prekeyPrivateStore: PrekeyPrivateStoreProtocol?

  init(
    seedService: SeedServiceProtocol,
    cryptoService: CryptoService,
    prekeyPrivateStore: PrekeyPrivateStoreProtocol? = nil
  ) {
    _ = seedService
    self.cryptoService = cryptoService
    self.prekeyPrivateStore = prekeyPrivateStore
  }

  func generateSignedPrekey(deviceIdentity: PersistedDeviceIdentity) throws -> SignedPrekeyBundle {
    guard let signingKeyRaw: Data = Data(base64Encoded: deviceIdentity.dkSignPrivate) else {
      throw CryptoServiceError.keyImportFailed
    }
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw)
    let prekey = Curve25519.KeyAgreement.PrivateKey()
    let prekeyPub = prekey.publicKey.rawRepresentation.base64EncodedString()
    let prekeyId = UUID().uuidString
    let payload = "signed_prekey|\(prekeyId)|\(prekeyPub)"
    let signature = try cryptoService.signEd25519(message: Data(payload.utf8), privateKey: signingKey)
    return SignedPrekeyBundle(prekeyId: prekeyId, signedPrekeyPub: prekeyPub, signature: signature)
  }

  func generateAndStoreSignedPrekey(deviceIdentity: PersistedDeviceIdentity) throws -> SignedPrekeyBundle {
    guard let signingKeyRaw: Data = Data(base64Encoded: deviceIdentity.dkSignPrivate) else {
      throw CryptoServiceError.keyImportFailed
    }
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw)
    let prekey = Curve25519.KeyAgreement.PrivateKey()
    let prekeyPub = prekey.publicKey.rawRepresentation.base64EncodedString()
    let prekeyId = UUID().uuidString
    let payload = "signed_prekey|\(prekeyId)|\(prekeyPub)"
    let signature = try cryptoService.signEd25519(message: Data(payload.utf8), privateKey: signingKey)

    try prekeyPrivateStore?.saveSignedPrekey(
      deviceId: deviceIdentity.deviceId,
      prekeyId: prekeyId,
      privateKeyData: prekey.rawRepresentation,
      createdAt: Date()
    )

    return SignedPrekeyBundle(prekeyId: prekeyId, signedPrekeyPub: prekeyPub, signature: signature)
  }

  func generateOneTimePrekeys(count: Int) -> [OneTimePrekeyBundle] {
    let total = max(0, min(1000, count))
    return (0..<total).map { _ in
      let prekey = Curve25519.KeyAgreement.PrivateKey()
      return OneTimePrekeyBundle(
        prekeyId: UUID().uuidString,
        prekeyPub: prekey.publicKey.rawRepresentation.base64EncodedString()
      )
    }
  }

  func generateAndStoreOneTimePrekeys(count: Int, deviceId: String) throws -> [OneTimePrekeyBundle] {
    let total = max(0, min(1000, count))
    var bundles: [OneTimePrekeyBundle] = []
    for _ in 0..<total {
      let prekey = Curve25519.KeyAgreement.PrivateKey()
      let prekeyId = UUID().uuidString
      let prekeyPub = prekey.publicKey.rawRepresentation.base64EncodedString()
      try prekeyPrivateStore?.saveOneTimePrekey(
        deviceId: deviceId,
        prekeyId: prekeyId,
        privateKeyData: prekey.rawRepresentation
      )
      bundles.append(OneTimePrekeyBundle(prekeyId: prekeyId, prekeyPub: prekeyPub))
    }
    return bundles
  }

  func topUpOneTimePrekeysIfNeeded(deviceId: String, target: Int = 100, lowWaterMark: Int = 25) throws -> [OneTimePrekeyBundle]? {
    let count = prekeyPrivateStore?.oneTimePrekeysCount(deviceId: deviceId) ?? 0
    guard count < lowWaterMark else { return nil }
    return try generateAndStoreOneTimePrekeys(count: target - count, deviceId: deviceId)
  }
}
