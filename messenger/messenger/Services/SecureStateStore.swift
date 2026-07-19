import CryptoKit
import Foundation

enum SecureStateStoreError: Error {
  case encodingFailed
  case decodingFailed
  case encryptionFailed
  case decryptionFailed
}

protocol SecureStateStoreProtocol {
  func save<T: Codable>(_ value: T, for key: String, storageKey: SymmetricKey) throws
  func load<T: Codable>(_ type: T.Type, for key: String, storageKey: SymmetricKey) throws -> T?
  func removeValue(for key: String)
}

final class SecureStateStore: SecureStateStoreProtocol {
  private let defaults: UserDefaults
  private let cryptoService: CryptoService
  private let namespace: String

  init(
    defaults: UserDefaults = .standard,
    cryptoService: CryptoService,
    namespace: String = "secure_state"
  ) {
    self.defaults = defaults
    self.cryptoService = cryptoService
    self.namespace = namespace
  }

  func save<T: Codable>(_ value: T, for key: String, storageKey: SymmetricKey) throws {
    let encoded: Data
    do {
      encoded = try JSONCoding.encoder.encode(value)
    } catch {
      throw SecureStateStoreError.encodingFailed
    }

    let encrypted: AEADCiphertextEnvelope
    do {
      encrypted = try cryptoService.encryptAEAD(plaintext: encoded, key: storageKey)
    } catch {
      throw SecureStateStoreError.encryptionFailed
    }

    let payload: Data
    do {
      payload = try JSONCoding.encoder.encode(encrypted)
    } catch {
      throw SecureStateStoreError.encodingFailed
    }

    defaults.set(payload, forKey: scoped(key))
  }

  func load<T: Codable>(_ type: T.Type, for key: String, storageKey: SymmetricKey) throws -> T? {
    guard let payload: Data = defaults.data(forKey: scoped(key)) else {
      return nil
    }

    let encrypted: AEADCiphertextEnvelope
    do {
      encrypted = try JSONCoding.decoder.decode(AEADCiphertextEnvelope.self, from: payload)
    } catch {
      throw SecureStateStoreError.decodingFailed
    }

    let decrypted: Data
    do {
      decrypted = try cryptoService.decryptAEAD(envelope: encrypted, key: storageKey)
    } catch {
      throw SecureStateStoreError.decryptionFailed
    }

    do {
      return try JSONCoding.decoder.decode(type, from: decrypted)
    } catch {
      throw SecureStateStoreError.decodingFailed
    }
  }

  func removeValue(for key: String) {
    defaults.removeObject(forKey: scoped(key))
  }

  private func scoped(_ key: String) -> String {
    "\(namespace).\(key)"
  }
}
