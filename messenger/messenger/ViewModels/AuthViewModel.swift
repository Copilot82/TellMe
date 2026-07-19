import CryptoKit
import Foundation

@MainActor
// The view model keeps onboarding state explicit so key generation and registration cannot interleave.
final class AuthViewModel {
  enum Mode: Int {
    case login
    case register
  }

  enum AuthViewModelError: LocalizedError, Equatable {
    case invalidUserHandle
    case seedRequired
    case invalidSeed
    case deviceLinkRequired

    var errorDescription: String? {
      switch self {
      case .invalidUserHandle:
        return "Используйте формат @user:domain"
      case .seedRequired:
        return "Seed phrase обязательна для входа"
      case .invalidSeed:
        return "Некорректная seed phrase"
      case .deviceLinkRequired:
        return "На этом устройстве нет локальной device identity. Используйте QR/link-code привязку нового устройства."
      }
    }
  }

  struct AuthResult {
    let user: User
    let requiresPrivateKeyImport: Bool
    let generatedSeedPhrase: String?
  }

  private let container: AppContainer

  init(container: AppContainer) {
    self.container = container
  }

  func submit(mode: Mode, userHandle: String, seedPhrase: String?) async throws -> AuthResult {
    switch mode {
    case .login:
      return try await login(userHandle: userHandle, seedPhrase: seedPhrase)
    case .register:
      return try await register(userHandle: userHandle)
    }
  }

  func register(userHandle: String) async throws -> AuthResult {
    let normalizedHandle = try normalizeHandle(userHandle)
    let identity: IdentityBundle = try resolvedRegistrationIdentity(userHandle: normalizedHandle)
    let deviceIdentity: PersistedDeviceIdentity = try ensureDeviceIdentity(
      userHandle: normalizedHandle,
      seedPhrase: identity.seedPhrase,
      allowLegacyDeviceIdMigration: false,
      createIfMissing: true,
      allowCrossLookupMigration: false
    )
    let deviceBundle: DeviceBundle = container.deviceKeysService.bundle(from: deviceIdentity)

    let timestamp = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
    let signature: String = try container.identityService.signRegistrationProof(
      seedPhrase: identity.seedPhrase,
      userHandle: normalizedHandle,
      ikSignPublic: identity.ikSignPublic,
      ikDHPublic: identity.ikDHPublic,
      timestampISO8601: timestamp
    )

    let registerRequest = FederatedRegisterRequest(
      userHandle: normalizedHandle,
      ikSignPub: identity.ikSignPublic,
      ikDhPub: identity.ikDHPublic,
      signature: signature,
      timestamp: timestamp,
      initialDevice: FederatedInitialDevice(
        deviceId: deviceBundle.deviceId,
        dkSignPub: deviceBundle.dkSignPublic,
        dkDhPub: deviceBundle.dkDHPublic,
        deviceCertificateChain: deviceBundle.deviceCertificateChain
      )
    )

    persistPendingRegistrationState(
      userHandle: normalizedHandle,
      deviceIdentity: deviceIdentity,
      seedPhrase: identity.seedPhrase
    )
    try configureSecureStorage(userHandle: normalizedHandle)

    do {
      _ = try await container.authService.registerFederated(registerRequest)
    } catch {
      guard shouldUseRegisterRecoveryFlow(error) else {
        throw error
      }

      // Registration may succeed server-side while client times out.
      try await performChallengeLogin(
        userHandle: normalizedHandle,
        deviceIdentity: deviceIdentity
      )
    }

    try await publishFreshPrekeysWithRetry(deviceIdentity: deviceIdentity)
    persistLocalAuthState(
      userHandle: normalizedHandle,
      deviceIdentity: deviceIdentity,
      seedPhrase: identity.seedPhrase
    )

    await container.pushNotificationService.warmAuthenticatedPushRegistration(timeout: 8)

    return AuthResult(
      user: syntheticUser(from: normalizedHandle, publicKey: identity.ikSignPublic),
      requiresPrivateKeyImport: false,
      generatedSeedPhrase: identity.seedPhrase
    )
  }

  func login(userHandle: String, seedPhrase: String?) async throws -> AuthResult {
    let normalizedHandle = try normalizeHandle(userHandle)
    let normalizedSeed: String? = seedPhrase?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty

    if let normalizedSeed {
      _ = try container.identityService.restoreIdentity(userHandle: normalizedHandle, seedPhrase: normalizedSeed)

      guard container.seedService.decodeSeedPhrase(normalizedSeed) != nil else {
        throw AuthViewModelError.invalidSeed
      }
    }

    let deviceIdentity: PersistedDeviceIdentity = try ensureDeviceIdentity(
      userHandle: normalizedHandle,
      seedPhrase: normalizedSeed,
      allowLegacyDeviceIdMigration: normalizedSeed != nil,
      createIfMissing: false
    )
    try await performChallengeLogin(userHandle: normalizedHandle, deviceIdentity: deviceIdentity)
    try await container.deviceLinkService.registerDevice(bundle: container.deviceKeysService.bundle(from: deviceIdentity))
    try await publishFreshPrekeysWithRetry(deviceIdentity: deviceIdentity)
    try configureSecureStorage(userHandle: normalizedHandle)
    persistLocalAuthState(
      userHandle: normalizedHandle,
      deviceIdentity: deviceIdentity,
      seedPhrase: normalizedSeed
    )

    await container.pushNotificationService.warmAuthenticatedPushRegistration(timeout: 8)

    return AuthResult(
      user: syntheticUser(from: normalizedHandle, publicKey: ""),
      requiresPrivateKeyImport: false,
      generatedSeedPhrase: nil
    )
  }

  func importPrivateKey(_ privateKeyPEM: String, for userId: String) throws {
    let trimmed = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
    guard container.seedService.decodeSeedPhrase(trimmed) != nil else {
      throw AuthViewModelError.invalidSeed
    }

    container.keyMaterialStore.saveSeedPhrase(trimmed, for: userId)
    container.keyMaterialStore.setCurrentUserId(userId)
  }

  private func publishFreshPrekeys(deviceIdentity: PersistedDeviceIdentity) async throws {
    let signedPrekey = try container.prekeysService.generateAndStoreSignedPrekey(deviceIdentity: deviceIdentity)
    let oneTime = try container.prekeysService.generateAndStoreOneTimePrekeys(
      count: 100,
      deviceId: deviceIdentity.deviceId
    )
    _ = try await container.authService.publishPrekeys(
      deviceId: deviceIdentity.deviceId,
      signedPrekey: signedPrekey,
      oneTimePrekeys: oneTime
    )
  }

  private func publishFreshPrekeysWithRetry(deviceIdentity: PersistedDeviceIdentity, maxAttempts: Int = 3) async throws {
    let attempts: Int = max(1, maxAttempts)
    var lastError: Error?

    for attempt in 1...attempts {
      do {
        try await publishFreshPrekeys(deviceIdentity: deviceIdentity)
        return
      } catch {
        lastError = error
        guard attempt < attempts, shouldRetryNetworkOperation(error) else {
          throw error
        }

        let backoffNanoseconds: UInt64 = UInt64(attempt) * 500_000_000
        try? await Task.sleep(nanoseconds: backoffNanoseconds)
      }
    }

    if let lastError {
      throw lastError
    }
  }

  private func performChallengeLogin(
    userHandle: String,
    deviceIdentity: PersistedDeviceIdentity
  ) async throws {
    do {
      guard !deviceIdentity.deviceCertificateChain.isEmpty else {
        throw AuthViewModelError.deviceLinkRequired
      }

      let challenge = try await container.authService.startChallenge(
        userHandle: userHandle,
        deviceId: deviceIdentity.deviceId
      )
      let challengeSignature = try container.deviceKeysService.signChallenge(
        nonce: challenge.nonce,
        identity: deviceIdentity
      )

      _ = try await container.authService.finishChallenge(
        FederatedAuthFinishRequest(
          userHandle: userHandle,
          deviceId: deviceIdentity.deviceId,
          challengeId: challenge.challengeId,
          signature: challengeSignature
        )
      )
    } catch let error as APIError {
      if case .server(let statusCode, let message) = error,
        statusCode == 409,
        message.lowercased().contains("device link required")
      {
        throw AuthViewModelError.deviceLinkRequired
      }
      throw error
    }
  }

  private func shouldUseRegisterRecoveryFlow(_ error: Error) -> Bool {
    shouldRetryNetworkOperation(error)
  }

  private func shouldRetryNetworkOperation(_ error: Error) -> Bool {
    guard let apiError: APIError = error as? APIError else {
      return false
    }

    switch apiError {
    case .server(let statusCode, let message):
      return statusCode == 409
        && message.lowercased().contains("account already exists")
    case .transport(let message):
      let normalized: String = message.lowercased()
      return normalized.contains("timed out")
        || normalized.contains("timeout")
        || normalized.contains("network connection was lost")
    default:
      return false
    }
  }

  private func configureSecureStorage(userHandle: String) throws {
    let normalizedUserHandle = userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let storageKeyData: Data
    if let existing: Data = container.keyMaterialStore.accountStorageKeyData(for: normalizedUserHandle), !existing.isEmpty {
      storageKeyData = existing
    } else {
      let generated = container.cryptoService.generateSeed(bytes: 32)
      container.keyMaterialStore.saveAccountStorageKeyData(generated, for: normalizedUserHandle)
      storageKeyData = generated
    }

    container.ratchetSessionStore.configure(storageKey: SymmetricKey(data: storageKeyData))
  }

  private func persistLocalAuthState(
    userHandle: String,
    deviceIdentity: PersistedDeviceIdentity,
    seedPhrase: String?
  ) {
    if let seedPhrase {
      container.keyMaterialStore.saveSeedPhrase(seedPhrase, for: userHandle)
    }
    container.keyMaterialStore.saveDeviceIdentity(deviceIdentity, for: userHandle)
    container.keyMaterialStore.saveDeviceId(deviceIdentity.deviceId, for: userHandle)
    container.keyMaterialStore.setCurrentUserId(userHandle)
    container.sessionStore.save(user: SessionUser(user: syntheticUser(from: userHandle, publicKey: "")))
  }

  private func persistPendingRegistrationState(
    userHandle: String,
    deviceIdentity: PersistedDeviceIdentity,
    seedPhrase: String
  ) {
    container.keyMaterialStore.saveSeedPhrase(seedPhrase, for: userHandle)
    container.keyMaterialStore.saveDeviceIdentity(deviceIdentity, for: userHandle)
    container.keyMaterialStore.saveDeviceId(deviceIdentity.deviceId, for: userHandle)
  }

  private func ensureDeviceIdentity(
    userHandle: String,
    seedPhrase: String?,
    allowLegacyDeviceIdMigration: Bool,
    createIfMissing: Bool,
    allowCrossLookupMigration: Bool = true
  ) throws -> PersistedDeviceIdentity {
    let lookupIds: [String] = allowCrossLookupMigration
      ? container.keyMaterialStore.keyMaterialLookupOrder(
        explicitUserId: userHandle,
        sessionUser: container.sessionStore.currentUser
      )
      : [userHandle]

    for lookupId in lookupIds {
      if let identity: PersistedDeviceIdentity = container.keyMaterialStore.deviceIdentity(for: lookupId) {
        let upgraded: PersistedDeviceIdentity
        if identity.deviceCertificateChain.isEmpty {
          guard let seedPhrase else {
            if lookupId == userHandle {
              throw AuthViewModelError.deviceLinkRequired
            }
            continue
          }
          upgraded = try container.deviceKeysService.attachAccountCertificateChain(
            userHandle: userHandle,
            seedPhrase: seedPhrase,
            identity: identity
          )
        } else if try isCompatibleDeviceIdentity(identity, userHandle: userHandle, seedPhrase: seedPhrase) {
          upgraded = identity
        } else {
          if lookupId == userHandle {
            container.keyMaterialStore.removeDeviceIdentity(for: lookupId)
          }
          continue
        }

        if lookupId != userHandle {
          container.keyMaterialStore.saveDeviceIdentity(upgraded, for: userHandle)
        }
        return upgraded
      }
    }

    if allowLegacyDeviceIdMigration {
      for lookupId in lookupIds {
        if let legacyDeviceId: String = container.keyMaterialStore.deviceId(for: lookupId),
          !legacyDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          guard let seedPhrase else {
            throw AuthViewModelError.deviceLinkRequired
          }
          let migrated: PersistedDeviceIdentity = try container.deviceKeysService.createDeviceIdentity(
            userHandle: userHandle,
            seedPhrase: seedPhrase,
            deviceId: legacyDeviceId
          )
          container.keyMaterialStore.saveDeviceIdentity(migrated, for: userHandle)
          return migrated
        }
      }
    }

    guard createIfMissing else {
      throw AuthViewModelError.deviceLinkRequired
    }
    guard let seedPhrase else {
      throw AuthViewModelError.seedRequired
    }

    let created: PersistedDeviceIdentity = try container.deviceKeysService.createDeviceIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: nil
    )
    container.keyMaterialStore.saveDeviceIdentity(created, for: userHandle)
    return created
  }

  private func isCompatibleDeviceIdentity(
    _ identity: PersistedDeviceIdentity,
    userHandle: String,
    seedPhrase: String?
  ) throws -> Bool {
    guard !identity.deviceCertificateChain.isEmpty else {
      return false
    }

    let normalizedHandle: String = userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let accountSignPub: String? = try seedPhrase.map {
      try container.identityService.restoreIdentity(userHandle: normalizedHandle, seedPhrase: $0).ikSignPublic
    }
    var previous: DeviceCertificateV2?
    var seenDeviceIds: Set<String> = []

    for certificate in identity.deviceCertificateChain {
      guard certificate.deviceCertificateVersion == 2,
        certificate.accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedHandle,
        !certificate.signature.isEmpty,
        !seenDeviceIds.contains(certificate.deviceId)
      else {
        return false
      }
      seenDeviceIds.insert(certificate.deviceId)

      if let expiresAt: Date = certificate.expiresAt, expiresAt <= Date() {
        return false
      }

      let payload: Data = Data(deviceCertificateSigningPayload(certificate).utf8)
      if let previous {
        guard certificate.issuerKind == "device",
          certificate.issuerDeviceId == previous.deviceId,
          certificate.parentCertificateId == deviceCertificateId(previous),
          container.cryptoService.verifyEd25519(
            message: payload,
            signatureBase64: certificate.signature,
            publicKeyBase64: previous.deviceSignPub
          )
        else {
          return false
        }
      } else {
        guard certificate.issuerKind == "account",
          (certificate.issuerDeviceId ?? "").isEmpty,
          (certificate.parentCertificateId ?? "").isEmpty
        else {
          return false
        }

        if let accountSignPub,
          !container.cryptoService.verifyEd25519(
            message: payload,
            signatureBase64: certificate.signature,
            publicKeyBase64: accountSignPub
          )
        {
          return false
        }
      }

      previous = certificate
    }

    guard let leaf: DeviceCertificateV2 = previous else {
      return false
    }

    return leaf.deviceId == identity.deviceId
      && leaf.deviceSignPub == identity.dkSignPublic
      && leaf.deviceDhPub == identity.dkDhPublic
  }

  private func deviceCertificateSigningPayload(_ certificate: DeviceCertificateV2) -> String {
    let issuedAt: String = ISO8601DateFormatter.withFractionalSeconds.string(from: certificate.issuedAt)
    let expiresAt: String = certificate.expiresAt.map(ISO8601DateFormatter.withFractionalSeconds.string(from:)) ?? ""
    let fields: [String] = [
      String(certificate.deviceCertificateVersion),
      certificate.accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      certificate.deviceId,
      certificate.deviceSignPub,
      certificate.deviceDhPub,
      certificate.issuerKind,
      certificate.issuerDeviceId ?? "",
      certificate.parentCertificateId ?? "",
      issuedAt,
      expiresAt,
    ]

    return "device_certificate|\(fields.joined(separator: "|"))"
  }

  private func deviceCertificateId(_ certificate: DeviceCertificateV2) -> String {
    let digest: SHA256Digest = SHA256.hash(data: Data(deviceCertificateSigningPayload(certificate).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func normalizeHandle(_ raw: String) throws -> String {
    let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard handle.range(of: "^@[a-z0-9._-]+:[a-z0-9.-]+$", options: .regularExpression) != nil else {
      throw AuthViewModelError.invalidUserHandle
    }

    return handle
  }

  private func resolvedRegistrationIdentity(userHandle: String) throws -> IdentityBundle {
    if let existingSeedPhrase: String = container.keyMaterialStore.seedPhrase(for: userHandle),
      !existingSeedPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return try container.identityService.restoreIdentity(
        userHandle: userHandle,
        seedPhrase: existingSeedPhrase
      )
    }

    return try container.identityService.createIdentity(userHandle: userHandle)
  }

  private func syntheticUser(from handle: String, publicKey: String) -> User {
    User(
      id: handle,
      username: handle,
      email: handle,
      publicKey: publicKey,
      createdAt: nil,
      updatedAt: nil
    )
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
