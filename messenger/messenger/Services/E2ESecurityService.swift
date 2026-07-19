import CryptoKit
import Foundation

enum E2ESecurityValidationError: LocalizedError {
  case invalidBundle
  case invalidDeviceSignature
  case invalidSignedPrekeySignature
  case trustMismatch

  var errorDescription: String? {
    switch self {
    case .invalidBundle:
      return "Получен невалидный prekey bundle."
    case .invalidDeviceSignature:
      return "Подпись ключей устройства не прошла проверку."
    case .invalidSignedPrekeySignature:
      return "Подпись signed prekey не прошла проверку."
    case .trustMismatch:
      return "Обнаружена смена ключа контакта. Требуется повторная верификация."
    }
  }
}

protocol E2ESecurityServiceProtocol {
  func listTrustRecords() async throws -> E2ETrustRecordsResponse
  func getTrustStatus(peerUserId: String) async throws -> E2ETrustStatusResponse
  func verifyTrust(peerUserId: String, fingerprint: String, method: TrustVerificationMethod) async throws -> E2EVerifyTrustResponse
  func markMismatch(peerUserId: String, fingerprint: String) async throws -> E2EVerifyTrustResponse
  func setConsent(peerUserId: String, enabled: Bool, source: String?) async throws -> E2EConsentResponse
  func getConsent(peerUserId: String) async throws -> E2EConsentResponse
  func getPeerFingerprint(peerUserId: String) async throws -> PublicKeyFingerprintResponse
}

final class E2ESecurityService: E2ESecurityServiceProtocol {
  private struct StoredState: Codable {
    var trust: [String: TrustedPeerKeyRecord]
    var consent: [String: KeyExchangeConsent]
  }

  private enum StorageKeys {
    static let legacyState: String = "federated.trust.state"
    static let statePrefix: String = "federated.trust.state.v2"
  }

  private let apiClient: APIClient
  private let sessionStore: AppSessionStore
  private let defaults: UserDefaults
  private let keyMaterialStore: KeyMaterialStore?
  private let identityService: IdentityServiceProtocol?
  private let secureStateStore: SecureStateStoreProtocol?
  private let cryptoService: CryptoService

  init(
    apiClient: APIClient,
    sessionStore: AppSessionStore,
    defaults: UserDefaults = .standard,
    keyMaterialStore: KeyMaterialStore? = nil,
    identityService: IdentityServiceProtocol? = nil,
    secureStateStore: SecureStateStoreProtocol? = nil,
    cryptoService: CryptoService = CryptoService()
  ) {
    self.apiClient = apiClient
    self.sessionStore = sessionStore
    self.defaults = defaults
    self.keyMaterialStore = keyMaterialStore
    self.identityService = identityService
    self.secureStateStore = secureStateStore
    self.cryptoService = cryptoService
  }

  func listTrustRecords() async throws -> E2ETrustRecordsResponse {
    let state = loadState()
    return E2ETrustRecordsResponse(trustRecords: Array(state.trust.values))
  }

  func getTrustStatus(peerUserId: String) async throws -> E2ETrustStatusResponse {
    let state = loadState()
    let trustRecord = state.trust[peerUserId]
    let consent = state.consent[peerUserId]

    let effective: TrustState = trustRecord?.state ?? .unverified
    let mode: E2ETrustStatusResponse.E2EMode = {
      switch effective {
      case .verified:
        return .protected
      case .mismatch, .revoked:
        return .blocked
      case .unverified:
        return .unprotected
      }
    }()

    return E2ETrustStatusResponse(
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: trustRecord?.peerFingerprint ?? "",
      consent: consent,
      mutualConsent: consent?.consentGiven ?? false,
      trustRecord: trustRecord,
      effectiveState: effective,
      mode: mode
    )
  }

  func verifyTrust(peerUserId: String, fingerprint: String, method: TrustVerificationMethod) async throws -> E2EVerifyTrustResponse {
    var state = loadState()
    let now = Date()
    let record = TrustedPeerKeyRecord(
      id: existingRecordId(for: peerUserId, current: state.trust[peerUserId]),
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: fingerprint,
      verifiedMethod: method,
      state: .verified,
      peerPublicKeyHash: fingerprint,
      verifiedAt: now,
      createdAt: state.trust[peerUserId]?.createdAt ?? now,
      updatedAt: now
    )
    state.trust[peerUserId] = record
    saveState(state)

    return E2EVerifyTrustResponse(
      trustRecord: record,
      fingerprintMatchesServer: nil,
      mode: .protected
    )
  }

  func markMismatch(peerUserId: String, fingerprint: String) async throws -> E2EVerifyTrustResponse {
    var state = loadState()
    let now = Date()
    let record = TrustedPeerKeyRecord(
      id: existingRecordId(for: peerUserId, current: state.trust[peerUserId]),
      ownerUserId: "local",
      peerUserId: peerUserId,
      peerFingerprint: fingerprint,
      verifiedMethod: state.trust[peerUserId]?.verifiedMethod ?? .manual,
      state: .mismatch,
      peerPublicKeyHash: fingerprint,
      verifiedAt: state.trust[peerUserId]?.verifiedAt,
      createdAt: state.trust[peerUserId]?.createdAt ?? now,
      updatedAt: now
    )
    state.trust[peerUserId] = record
    saveState(state)

    return E2EVerifyTrustResponse(
      trustRecord: record,
      fingerprintMatchesServer: nil,
      mode: .blocked
    )
  }

  func setConsent(peerUserId: String, enabled: Bool, source: String?) async throws -> E2EConsentResponse {
    var state = loadState()
    let now = Date()
    let consent = KeyExchangeConsent(
      id: existingConsentId(for: peerUserId, current: state.consent[peerUserId]),
      ownerUserId: "local",
      peerUserId: peerUserId,
      consentGiven: enabled,
      consentSource: source ?? "local",
      createdAt: state.consent[peerUserId]?.createdAt ?? now,
      updatedAt: now
    )

    state.consent[peerUserId] = consent
    saveState(state)

    return E2EConsentResponse(consent: consent, mutualConsent: enabled)
  }

  func getConsent(peerUserId: String) async throws -> E2EConsentResponse {
    let consent = loadState().consent[peerUserId]
    return E2EConsentResponse(
      consent: consent,
      mutualConsent: consent?.consentGiven ?? false
    )
  }

  func getPeerFingerprint(peerUserId: String) async throws -> PublicKeyFingerprintResponse {
    let queryItems = [
      URLQueryItem(name: "user", value: peerUserId),
      URLQueryItem(name: "peek", value: "true"),
    ]
    let request = APIRequest(path: "prekeys/get", method: .get, queryItems: queryItems)
    let response: FederatedPrekeysGetResponse = try await apiClient.send(request, requiresAuth: false)

    guard let bundle = response.bundles.first else {
      throw APIError.server(statusCode: 404, message: "Unavailable")
    }

    let hash = SHA256.hash(data: Data(bundle.ikSignPub.utf8))
    let fingerprint = hash.map { String(format: "%02x", $0) }.joined()

    return PublicKeyFingerprintResponse(userId: bundle.userHandle, fingerprint: fingerprint)
  }

  func exportSnapshot(for ownerUserId: String) -> DeviceLinkTrustStateSnapshot {
    let normalizedOwnerUserId: String = normalizeOwnerUserId(ownerUserId)
    let state: StoredState = loadState(ownerUserId: normalizedOwnerUserId)
    return DeviceLinkTrustStateSnapshot(
      exportedAt: Date(),
      trustByPeerUserId: state.trust,
      consentByPeerUserId: state.consent
    )
  }

  func importSnapshot(_ snapshot: DeviceLinkTrustStateSnapshot, for ownerUserId: String) {
    let normalizedOwnerUserId: String = normalizeOwnerUserId(ownerUserId)
    let state = StoredState(
      trust: snapshot.trustByPeerUserId,
      consent: snapshot.consentByPeerUserId
    )
    saveState(state, ownerUserId: normalizedOwnerUserId)
  }

  private func loadState() -> StoredState {
    loadState(ownerUserId: currentOwnerUserId())
  }

  private func loadState(ownerUserId: String) -> StoredState {
    if let storageKey = resolvedStorageKey(ownerUserId: ownerUserId),
      let secureStateStore,
      let state = try? secureStateStore.load(StoredState.self, for: scopedStorageKey(ownerUserId: ownerUserId), storageKey: storageKey)
    {
      return state
    }

    if let legacyState = loadLegacyState(ownerUserId: ownerUserId) {
      migrateLegacyStateIfNeeded(legacyState, ownerUserId: ownerUserId)
      return legacyState
    }

    return StoredState(trust: [:], consent: [:])
  }

  private func saveState(_ state: StoredState) {
    saveState(state, ownerUserId: currentOwnerUserId())
  }

  private func saveState(_ state: StoredState, ownerUserId: String) {
    if let storageKey = resolvedStorageKey(ownerUserId: ownerUserId),
      let secureStateStore
    {
      do {
        try secureStateStore.save(state, for: scopedStorageKey(ownerUserId: ownerUserId), storageKey: storageKey)
        defaults.removeObject(forKey: scopedStorageKey(ownerUserId: ownerUserId))
        defaults.removeObject(forKey: StorageKeys.legacyState)
        return
      } catch {
        // Fallback to legacy storage to avoid dropping trust state.
      }
    }

    guard let data: Data = try? JSONCoding.encoder.encode(state) else {
      return
    }
    defaults.set(data, forKey: scopedStorageKey(ownerUserId: ownerUserId))
  }

  private func existingRecordId(for peerUserId: String, current: TrustedPeerKeyRecord?) -> String {
    current?.id ?? "trust-\(peerUserId)"
  }

  private func existingConsentId(for peerUserId: String, current: KeyExchangeConsent?) -> String {
    current?.id ?? "consent-\(peerUserId)"
  }

  private func currentOwnerUserId() -> String {
    normalizeOwnerUserId(sessionStore.currentUser?.id ?? "anonymous")
  }

  private func scopedStorageKey(ownerUserId: String) -> String {
    let owner: String = normalizeOwnerUserId(ownerUserId)
    let digest = SHA256.hash(data: Data(owner.utf8))
    let suffix: String = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(StorageKeys.statePrefix).\(suffix)"
  }

  private func normalizeOwnerUserId(_ ownerUserId: String) -> String {
    ownerUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func loadLegacyState(ownerUserId: String) -> StoredState? {
    if let data: Data = defaults.data(forKey: scopedStorageKey(ownerUserId: ownerUserId)),
      let state: StoredState = try? JSONCoding.decoder.decode(StoredState.self, from: data)
    {
      return state
    }

    if let data: Data = defaults.data(forKey: StorageKeys.legacyState),
      let state: StoredState = try? JSONCoding.decoder.decode(StoredState.self, from: data)
    {
      return state
    }

    return nil
  }

  private func migrateLegacyStateIfNeeded(_ state: StoredState, ownerUserId: String) {
    guard let storageKey = resolvedStorageKey(ownerUserId: ownerUserId),
      let secureStateStore
    else {
      return
    }

    do {
      try secureStateStore.save(state, for: scopedStorageKey(ownerUserId: ownerUserId), storageKey: storageKey)
      defaults.removeObject(forKey: scopedStorageKey(ownerUserId: ownerUserId))
      defaults.removeObject(forKey: StorageKeys.legacyState)
    } catch {
      // Keep plaintext fallback if secure migration fails.
    }
  }

  private func resolvedStorageKey(ownerUserId: String) -> SymmetricKey? {
    AccountScopedSecureStorage.storageKey(
      explicitUserId: ownerUserId,
      sessionUser: sessionStore.currentUser,
      keyMaterialStore: keyMaterialStore,
      identityService: identityService
    )
  }

  func validateBundle(
    _ bundle: FederatedPrekeyBundle,
    expectedPeerUserId: String
  ) async throws -> FederatedPrekeyBundle {
    let normalizedPeerUserId: String = normalizeOwnerUserId(expectedPeerUserId)
    let normalizedBundleUserId: String = normalizeOwnerUserId(bundle.userHandle)
    guard normalizedBundleUserId == normalizedPeerUserId,
      !bundle.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw E2ESecurityValidationError.invalidBundle
    }

    guard validateDeviceCertificateChain(bundle) else {
      throw E2ESecurityValidationError.invalidDeviceSignature
    }

    let signedPrekeyPayload: Data = Data(
      "signed_prekey|\(bundle.signedPrekey.prekeyId)|\(bundle.signedPrekey.signedPrekeyPub)".utf8
    )
    guard cryptoService.verifyEd25519(
      message: signedPrekeyPayload,
      signatureBase64: bundle.signedPrekey.signature,
      publicKeyBase64: bundle.deviceSignPub
    ) else {
      throw E2ESecurityValidationError.invalidSignedPrekeySignature
    }

    try await enforceTrustContinuity(
      peerUserId: normalizedPeerUserId,
      fingerprint: fingerprint(from: bundle.accountSignPub)
    )
    return bundle
  }

  func validateBundles(
    _ bundles: [FederatedPrekeyBundle],
    expectedPeerUserId: String
  ) async throws -> [FederatedPrekeyBundle] {
    try await bundles.asyncMap { bundle in
      try await validateBundle(bundle, expectedPeerUserId: expectedPeerUserId)
    }
  }

  private func enforceTrustContinuity(peerUserId: String, fingerprint: String) async throws {
    let state = loadState()
    guard let trustRecord: TrustedPeerKeyRecord = state.trust[peerUserId] else {
      return
    }

    switch trustRecord.state {
    case .verified:
      guard trustRecord.peerFingerprint == fingerprint else {
        _ = try await markMismatch(peerUserId: peerUserId, fingerprint: fingerprint)
        throw E2ESecurityValidationError.trustMismatch
      }
    case .mismatch, .revoked:
      throw E2ESecurityValidationError.trustMismatch
    case .unverified:
      break
    }
  }

  private func fingerprint(from publicKey: String) -> String {
    let hash = SHA256.hash(data: Data(publicKey.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  private func validateDeviceCertificateChain(_ bundle: FederatedPrekeyBundle) -> Bool {
    guard !bundle.deviceCertificateChain.isEmpty else {
      return false
    }

    var previous: DeviceCertificateV2?
    for certificate in bundle.deviceCertificateChain {
      guard certificate.deviceCertificateVersion == 2,
        certificate.accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == bundle.userHandle,
        !certificate.signature.isEmpty
      else {
        return false
      }

      let payload = deviceCertificateSigningPayload(certificate)
      if let previous {
        guard certificate.issuerKind == "device",
          certificate.issuerDeviceId == previous.deviceId,
          cryptoService.verifyEd25519(
            message: Data(payload.utf8),
            signatureBase64: certificate.signature,
            publicKeyBase64: previous.deviceSignPub
          )
        else {
          return false
        }
      } else {
        guard certificate.issuerKind == "account",
          cryptoService.verifyEd25519(
            message: Data(payload.utf8),
            signatureBase64: certificate.signature,
            publicKeyBase64: bundle.accountSignPub
          )
        else {
          return false
        }
      }

      previous = certificate
    }

    guard let leaf = previous else {
      return false
    }

    return leaf.deviceId == bundle.deviceId
      && leaf.deviceSignPub == bundle.deviceSignPub
      && leaf.deviceDhPub == bundle.deviceDhPub
  }

  private func deviceCertificateSigningPayload(_ certificate: DeviceCertificateV2) -> String {
    let issuedAt = ISO8601DateFormatter.withFractionalSeconds.string(from: certificate.issuedAt)
    let expiresAt = certificate.expiresAt.map(ISO8601DateFormatter.withFractionalSeconds.string(from:)) ?? ""
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
}

private extension Array {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
    var result: [T] = []
    result.reserveCapacity(count)
    for value in self {
      result.append(try await transform(value))
    }
    return result
  }
}
