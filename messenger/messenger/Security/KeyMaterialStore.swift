import Foundation
import Security

protocol KeyMaterialStore: AnyObject {
  var currentUserId: String? { get }

  func setCurrentUserId(_ userId: String?)
  func hasPrivateKey(for userId: String) -> Bool
  func savePrivateKeyPEM(_ pem: String, for userId: String)
  func privateKeyPEM(for userId: String) -> String?
  func saveSeedPhrase(_ seedPhrase: String, for userId: String)
  func seedPhrase(for userId: String) -> String?
  func saveDeviceId(_ deviceId: String, for userId: String)
  func deviceId(for userId: String) -> String?
  func saveDeviceIdentity(_ identity: PersistedDeviceIdentity, for userId: String)
  func deviceIdentity(for userId: String) -> PersistedDeviceIdentity?
  func saveAccountStorageKeyData(_ data: Data, for userId: String)
  func accountStorageKeyData(for userId: String) -> Data?
  func removePrivateKey(for userId: String)
  func removeSeedPhrase(for userId: String)
  func removeDeviceId(for userId: String)
  func removeDeviceIdentity(for userId: String)
  func removeAccountStorageKey(for userId: String)
  func clearAll()
}

extension KeyMaterialStore {
  func keyMaterialLookupOrder(
    explicitUserId: String? = nil,
    sessionUser: SessionUser? = nil
  ) -> [String] {
    var result: [String] = []

    func addCandidate(_ raw: String?) {
      guard let raw else {
        return
      }

      let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return
      }

      if !result.contains(trimmed) {
        result.append(trimmed)
      }

      let lowered: String = trimmed.lowercased()
      if lowered != trimmed && !result.contains(lowered) {
        result.append(lowered)
      }
    }

    addCandidate(explicitUserId)
    addCandidate(sessionUser?.id)
    addCandidate(sessionUser?.username)
    addCandidate(sessionUser?.email)
    addCandidate(currentUserId)

    return result
  }

  func firstAvailableSeedPhrase(lookupIds: [String]) -> (userId: String, seedPhrase: String)? {
    for userId in lookupIds {
      if let seedPhrase: String = seedPhrase(for: userId), !seedPhrase.isEmpty {
        return (userId: userId, seedPhrase: seedPhrase)
      }
    }

    return nil
  }

  func firstAvailablePrivateKeyPEM(lookupIds: [String]) -> (userId: String, privateKey: String)? {
    for userId in lookupIds {
      if let privateKey: String = privateKeyPEM(for: userId), !privateKey.isEmpty {
        return (userId: userId, privateKey: privateKey)
      }
    }

    return nil
  }

  func hasAnyAccountKeyMaterial(lookupIds: [String]) -> Bool {
    firstAvailableSeedPhrase(lookupIds: lookupIds) != nil
      || firstAvailablePrivateKeyPEM(lookupIds: lookupIds) != nil
  }
}

final class KeychainKeyMaterialStore: KeyMaterialStore {
  private let service: String
  private let currentUserAccount: String = "current_user_id"

  init(service: String = "com.example.messenger.keys") {
    self.service = service
  }

  var currentUserId: String? {
    read(account: currentUserAccount)
  }

  func setCurrentUserId(_ userId: String?) {
    if let userId, !userId.isEmpty {
      save(value: userId, account: currentUserAccount)
    } else {
      delete(account: currentUserAccount)
    }
  }

  func hasPrivateKey(for userId: String) -> Bool {
    privateKeyPEM(for: userId) != nil
  }

  func savePrivateKeyPEM(_ pem: String, for userId: String) {
    save(value: pem, account: privateKeyAccount(for: userId))
  }

  func privateKeyPEM(for userId: String) -> String? {
    read(account: privateKeyAccount(for: userId))
  }

  func saveSeedPhrase(_ seedPhrase: String, for userId: String) {
    save(value: seedPhrase, account: seedPhraseAccount(for: userId))
  }

  func seedPhrase(for userId: String) -> String? {
    read(account: seedPhraseAccount(for: userId))
  }

  func saveDeviceId(_ deviceId: String, for userId: String) {
    save(value: deviceId, account: deviceIdAccount(for: userId))
  }

  func deviceId(for userId: String) -> String? {
    read(account: deviceIdAccount(for: userId)) ?? deviceIdentity(for: userId)?.deviceId
  }

  func saveDeviceIdentity(_ identity: PersistedDeviceIdentity, for userId: String) {
    guard let data: Data = try? JSONCoding.encoder.encode(identity) else {
      return
    }

    save(data: data, account: deviceIdentityAccount(for: userId))
    saveDeviceId(identity.deviceId, for: userId)
  }

  func deviceIdentity(for userId: String) -> PersistedDeviceIdentity? {
    guard let data: Data = readData(account: deviceIdentityAccount(for: userId)) else {
      return nil
    }

    return try? JSONCoding.decoder.decode(PersistedDeviceIdentity.self, from: data)
  }

  func saveAccountStorageKeyData(_ data: Data, for userId: String) {
    save(data: data, account: accountStorageKeyAccount(for: userId))
  }

  func accountStorageKeyData(for userId: String) -> Data? {
    readData(account: accountStorageKeyAccount(for: userId))
  }

  func removePrivateKey(for userId: String) {
    delete(account: privateKeyAccount(for: userId))

    if currentUserId == userId {
      delete(account: currentUserAccount)
    }
  }

  func removeSeedPhrase(for userId: String) {
    delete(account: seedPhraseAccount(for: userId))
  }

  func removeDeviceId(for userId: String) {
    delete(account: deviceIdAccount(for: userId))
  }

  func removeDeviceIdentity(for userId: String) {
    delete(account: deviceIdentityAccount(for: userId))
    delete(account: deviceIdAccount(for: userId))
  }

  func removeAccountStorageKey(for userId: String) {
    delete(account: accountStorageKeyAccount(for: userId))
  }

  func clearAll() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func privateKeyAccount(for userId: String) -> String {
    "private_key:\(userId)"
  }

  private func seedPhraseAccount(for userId: String) -> String {
    "seed_phrase:\(userId)"
  }

  private func deviceIdAccount(for userId: String) -> String {
    "device_id:\(userId)"
  }

  private func deviceIdentityAccount(for userId: String) -> String {
    "device_identity:\(userId)"
  }

  private func accountStorageKeyAccount(for userId: String) -> String {
    "account_storage_key:\(userId)"
  }

  private func save(value: String, account: String) {
    guard let data: Data = value.data(using: .utf8) else {
      return
    }

    save(data: data, account: account)
  }

  private func save(data: Data, account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    SecItemDelete(query as CFDictionary)

    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessControl as String: accessControl(for: account),
    ]

    SecItemAdd(attributes as CFDictionary, nil)
  }

  private func read(account: String) -> String? {
    guard let data: Data = readData(account: account),
      let value: String = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return value
  }

  private func readData(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)

    guard status == errSecSuccess,
      let data: Data = item as? Data
    else {
      return nil
    }

    return data
  }

  private func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    SecItemDelete(query as CFDictionary)
  }

  private func accessControl(for account: String) -> SecAccessControl {
    let accessibility: CFString
    if account == currentUserAccount || account.hasPrefix("device_id:") {
      accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    } else {
      accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    return SecAccessControlCreateWithFlags(nil, accessibility, [], nil)!
  }
}
