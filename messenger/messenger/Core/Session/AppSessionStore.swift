import CryptoKit
import Foundation

struct SessionUser: Codable, Equatable {
  let id: String
  let username: String
  let email: String

  init(user: User) {
    self.id = user.id
    self.username = user.username
    self.email = user.email
  }
}

protocol AppSessionStore: AnyObject {
  var currentUser: SessionUser? { get }

  func save(user: SessionUser)
  func clear()
}

final class UserDefaultsSessionStore: AppSessionStore {
  private enum Keys {
    static let currentUser: String = "session.currentUser"
  }

  private let defaults: UserDefaults
  private let secureStateStore: SecureStateStoreProtocol?
  private let keyMaterialStore: KeyMaterialStore?
  private let identityService: IdentityServiceProtocol?

  init(
    defaults: UserDefaults = .standard,
    secureStateStore: SecureStateStoreProtocol? = nil,
    keyMaterialStore: KeyMaterialStore? = nil,
    identityService: IdentityServiceProtocol? = nil
  ) {
    self.defaults = defaults
    self.secureStateStore = secureStateStore
    self.keyMaterialStore = keyMaterialStore
    self.identityService = identityService
  }

  var currentUser: SessionUser? {
    if let storageKey = resolvedStorageKey(),
      let secureStateStore,
      let user = try? secureStateStore.load(SessionUser.self, for: Keys.currentUser, storageKey: storageKey)
    {
      return user
    }

    guard let data: Data = defaults.data(forKey: Keys.currentUser),
      let user = try? JSONCoding.decoder.decode(SessionUser.self, from: data)
    else {
      return nil
    }

    migrateLegacyCurrentUserIfNeeded(user)
    return user
  }

  func save(user: SessionUser) {
    if let storageKey = resolvedStorageKey(explicitUserId: user.id),
      let secureStateStore
    {
      do {
        try secureStateStore.save(user, for: Keys.currentUser, storageKey: storageKey)
        defaults.removeObject(forKey: Keys.currentUser)
        return
      } catch {
        // Fallback to legacy storage to avoid breaking auth/session restore.
      }
    }

    guard let data: Data = try? JSONCoding.encoder.encode(user) else {
      return
    }

    defaults.set(data, forKey: Keys.currentUser)
  }

  func clear() {
    secureStateStore?.removeValue(for: Keys.currentUser)
    defaults.removeObject(forKey: Keys.currentUser)
  }

  private func resolvedStorageKey(explicitUserId: String? = nil) -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: explicitUserId,
      sessionUser: nil,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )
  }

  private func migrateLegacyCurrentUserIfNeeded(_ user: SessionUser) {
    guard let storageKey = resolvedStorageKey(explicitUserId: user.id),
      let secureStateStore
    else {
      return
    }

    do {
      try secureStateStore.save(user, for: Keys.currentUser, storageKey: storageKey)
      defaults.removeObject(forKey: Keys.currentUser)
    } catch {
      // Keep legacy state if secure migration fails.
    }
  }
}
