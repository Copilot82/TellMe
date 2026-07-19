import CryptoKit
import Foundation
import Security

enum PrekeyPrivateStoreError: Error {
  case saveFailed(OSStatus)
}

protocol PrekeyPrivateStoreProtocol {
  func saveSignedPrekey(deviceId: String, prekeyId: String, privateKeyData: Data, createdAt: Date) throws
  func loadSignedPrekey(deviceId: String, prekeyId: String) -> Data?
  func removeSignedPrekey(deviceId: String, prekeyId: String)
  func cleanupExpiredSignedPrekeys(deviceId: String, keepPrekeyId: String, gracePeriodDays: Int)

  func saveOneTimePrekey(deviceId: String, prekeyId: String, privateKeyData: Data) throws
  func loadOneTimePrekey(deviceId: String, prekeyId: String) -> Data?
  func consumeOneTimePrekey(deviceId: String, prekeyId: String)
  func oneTimePrekeysCount(deviceId: String) -> Int
}

final class KeychainPrekeyPrivateStore: PrekeyPrivateStoreProtocol {
  private struct SignedPrekeyRecord: Codable {
    let privateKeyData: Data
    let createdAt: Date
  }

  private let service: String

  init(service: String = "com.tellme.prekey-private-store") {
    self.service = service
  }

  func saveSignedPrekey(deviceId: String, prekeyId: String, privateKeyData: Data, createdAt: Date) throws {
    let payload = SignedPrekeyRecord(privateKeyData: privateKeyData, createdAt: createdAt)
    let encoded = try JSONCoding.encoder.encode(payload)
    try keychainSave(account: "spk_priv:\(deviceId):\(prekeyId)", data: encoded)
  }

  func loadSignedPrekey(deviceId: String, prekeyId: String) -> Data? {
    guard let stored = keychainLoad(account: "spk_priv:\(deviceId):\(prekeyId)") else {
      return nil
    }

    if let record = try? JSONCoding.decoder.decode(SignedPrekeyRecord.self, from: stored) {
      return record.privateKeyData
    }

    return stored
  }

  func removeSignedPrekey(deviceId: String, prekeyId: String) {
    keychainDelete(account: "spk_priv:\(deviceId):\(prekeyId)")
  }

  func cleanupExpiredSignedPrekeys(deviceId: String, keepPrekeyId: String, gracePeriodDays: Int) {
    let cutoff = Date().addingTimeInterval(-Double(max(0, gracePeriodDays)) * 86_400)
    let prefix = "spk_priv:\(deviceId):"

    for account in keychainAccounts(withPrefix: prefix) {
      let prekeyId = String(account.dropFirst(prefix.count))
      guard prekeyId != keepPrekeyId,
        let stored = keychainLoad(account: account),
        let record = try? JSONCoding.decoder.decode(SignedPrekeyRecord.self, from: stored),
        record.createdAt < cutoff
      else {
        continue
      }

      keychainDelete(account: account)
    }
  }

  func saveOneTimePrekey(deviceId: String, prekeyId: String, privateKeyData: Data) throws {
    try keychainSave(account: "opk_priv:\(deviceId):\(prekeyId)", data: privateKeyData)
  }

  func loadOneTimePrekey(deviceId: String, prekeyId: String) -> Data? {
    keychainLoad(account: "opk_priv:\(deviceId):\(prekeyId)")
  }

  func consumeOneTimePrekey(deviceId: String, prekeyId: String) {
    let account = "opk_priv:\(deviceId):\(prekeyId)"
    keychainDelete(account: account)
  }

  func oneTimePrekeysCount(deviceId: String) -> Int {
    keychainAccounts(withPrefix: "opk_priv:\(deviceId):").count
  }

  private func keychainSave(account: String, data: Data) throws {
    let deleteQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw PrekeyPrivateStoreError.saveFailed(status)
    }
  }

  private func keychainLoad(account: String) -> Data? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private func keychainDelete(account: String) {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func keychainAccounts(withPrefix prefix: String) -> [String] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]

    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return []
    }

    let items = result as? [[CFString: Any]] ?? []
    return items.compactMap { $0[kSecAttrAccount] as? String }
      .filter { $0.hasPrefix(prefix) }
  }
}
