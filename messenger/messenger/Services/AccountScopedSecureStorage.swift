import CryptoKit
import Foundation

enum AccountScopedSecureStorage {
  static func storageKey(
    explicitUserId: String? = nil,
    sessionUser: SessionUser? = nil,
    keyMaterialStore: KeyMaterialStore?,
    identityService: IdentityServiceProtocol?
  ) -> SymmetricKey? {
    guard let keyMaterialStore, let identityService else {
      return nil
    }

    let lookupIds: [String] = keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: normalizedUserId(explicitUserId),
      sessionUser: sessionUser
    )
    for lookupId in lookupIds {
      if let data = keyMaterialStore.accountStorageKeyData(for: lookupId), !data.isEmpty {
        return SymmetricKey(data: data)
      }
    }

    guard let resolvedSeed = keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds) else {
      return nil
    }

    return try? identityService.deriveStorageKey(seedPhrase: resolvedSeed.seedPhrase)
  }

  static func normalizedUserId(_ value: String?) -> String? {
    guard let value else {
      return nil
    }

    let normalized: String = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }
}
