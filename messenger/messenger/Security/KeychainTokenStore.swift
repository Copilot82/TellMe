import Foundation
import Security

// Tokens stay behind the keychain abstraction so logout and protocol cutovers can clear them uniformly.
final class KeychainTokenStore: TokenStore {
  private let service: String
  private let accessAccount: String = "access_token"
  private let refreshAccount: String = "refresh_token"

  init(service: String = Bundle.main.bundleIdentifier ?? "com.example.messenger") {
    self.service = service
  }

  var accessToken: String? {
    read(account: accessAccount)
  }

  var refreshToken: String? {
    read(account: refreshAccount)
  }

  func saveTokens(accessToken: String, refreshToken: String) {
    save(value: accessToken, account: accessAccount)
    save(value: refreshToken, account: refreshAccount)
  }

  func clear() {
    delete(account: accessAccount)
    delete(account: refreshAccount)
  }

  private func save(value: String, account: String) {
    guard let data: Data = value.data(using: .utf8) else {
      return
    }

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
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    SecItemAdd(attributes as CFDictionary, nil)
  }

  private func read(account: String) -> String? {
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
      let data: Data = item as? Data,
      let value: String = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return value
  }

  private func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    SecItemDelete(query as CFDictionary)
  }
}
