import Foundation
@testable import messenger

final class InMemoryKeyMaterialStore: KeyMaterialStore {
  private var privateKeys: [String: String] = [:]
  private var seedPhrases: [String: String] = [:]
  private var deviceIds: [String: String] = [:]
  private var deviceIdentities: [String: PersistedDeviceIdentity] = [:]
  private var accountStorageKeys: [String: Data] = [:]
  private(set) var currentUserId: String?

  func setCurrentUserId(_ userId: String?) {
    currentUserId = userId
  }

  func hasPrivateKey(for userId: String) -> Bool {
    privateKeys[userId] != nil
  }

  func savePrivateKeyPEM(_ pem: String, for userId: String) {
    privateKeys[userId] = pem
  }

  func privateKeyPEM(for userId: String) -> String? {
    privateKeys[userId]
  }

  func saveSeedPhrase(_ seedPhrase: String, for userId: String) {
    seedPhrases[userId] = seedPhrase
  }

  func seedPhrase(for userId: String) -> String? {
    seedPhrases[userId]
  }

  func saveDeviceId(_ deviceId: String, for userId: String) {
    deviceIds[userId] = deviceId
  }

  func deviceId(for userId: String) -> String? {
    deviceIds[userId] ?? deviceIdentities[userId]?.deviceId
  }

  func saveDeviceIdentity(_ identity: PersistedDeviceIdentity, for userId: String) {
    deviceIdentities[userId] = identity
    deviceIds[userId] = identity.deviceId
  }

  func deviceIdentity(for userId: String) -> PersistedDeviceIdentity? {
    deviceIdentities[userId]
  }

  func saveAccountStorageKeyData(_ data: Data, for userId: String) {
    accountStorageKeys[userId] = data
  }

  func accountStorageKeyData(for userId: String) -> Data? {
    accountStorageKeys[userId]
  }

  func removePrivateKey(for userId: String) {
    privateKeys.removeValue(forKey: userId)
  }

  func removeSeedPhrase(for userId: String) {
    seedPhrases.removeValue(forKey: userId)
  }

  func removeDeviceId(for userId: String) {
    deviceIds.removeValue(forKey: userId)
  }

  func removeDeviceIdentity(for userId: String) {
    deviceIdentities.removeValue(forKey: userId)
    deviceIds.removeValue(forKey: userId)
  }

  func removeAccountStorageKey(for userId: String) {
    accountStorageKeys.removeValue(forKey: userId)
  }

  func clearAll() {
    privateKeys.removeAll()
    seedPhrases.removeAll()
    deviceIds.removeAll()
    deviceIdentities.removeAll()
    accountStorageKeys.removeAll()
    currentUserId = nil
  }
}
