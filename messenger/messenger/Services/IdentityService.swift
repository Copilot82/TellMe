import CryptoKit
import Foundation

struct IdentityBundle: Codable, Equatable {
  let userHandle: String
  let ikSignPublic: String
  let ikDHPublic: String
  let seedPhrase: String
}

protocol IdentityServiceProtocol {
  func createIdentity(userHandle: String) throws -> IdentityBundle
  func restoreIdentity(userHandle: String, seedPhrase: String) throws -> IdentityBundle
  func signRegistrationProof(
    seedPhrase: String,
    userHandle: String,
    ikSignPublic: String,
    ikDHPublic: String,
    timestampISO8601: String
  ) throws -> String
  func signChallenge(seedPhrase: String, nonce: String) throws -> String
  func signMessage(seedPhrase: String, message: String) throws -> String
  func deriveStorageKey(seedPhrase: String) throws -> SymmetricKey
}

final class IdentityService: IdentityServiceProtocol {
  private let seedService: SeedServiceProtocol
  private let cryptoService: CryptoService

  init(seedService: SeedServiceProtocol, cryptoService: CryptoService) {
    self.seedService = seedService
    self.cryptoService = cryptoService
  }

  func createIdentity(userHandle: String) throws -> IdentityBundle {
    let seed: Data = seedService.generateSeed()
    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)

    return IdentityBundle(
      userHandle: userHandle,
      ikSignPublic: derived.ikSignPublicBase64,
      ikDHPublic: derived.ikDHPublicBase64,
      seedPhrase: seedService.encodeSeedPhrase(seed)
    )
  }

  func restoreIdentity(userHandle: String, seedPhrase: String) throws -> IdentityBundle {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.keyImportFailed
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    return IdentityBundle(
      userHandle: userHandle,
      ikSignPublic: derived.ikSignPublicBase64,
      ikDHPublic: derived.ikDHPublicBase64,
      seedPhrase: seedPhrase
    )
  }

  func signRegistrationProof(
    seedPhrase: String,
    userHandle: String,
    ikSignPublic: String,
    ikDHPublic: String,
    timestampISO8601: String
  ) throws -> String {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.invalidPayload
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    let payload: String = "register|\(userHandle)|\(ikSignPublic)|\(ikDHPublic)|\(timestampISO8601)"
    return try cryptoService.signEd25519(message: Data(payload.utf8), privateKey: derived.ikSignPrivate)
  }

  func signChallenge(seedPhrase: String, nonce: String) throws -> String {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.invalidPayload
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    return try cryptoService.signEd25519(message: Data(nonce.utf8), privateKey: derived.ikSignPrivate)
  }

  func signMessage(seedPhrase: String, message: String) throws -> String {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.invalidPayload
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    return try cryptoService.signEd25519(message: Data(message.utf8), privateKey: derived.ikSignPrivate)
  }

  func deriveStorageKey(seedPhrase: String) throws -> SymmetricKey {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.invalidPayload
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    return derived.storageKey
  }
}
