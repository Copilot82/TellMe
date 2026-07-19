import CryptoKit
import Foundation

@MainActor
final class DeviceLinkViewModel {
  enum DeviceLinkViewModelError: LocalizedError {
    case noActiveAccount
    case missingSeedPhrase
    case invalidProvisioningBlob
    case linkNotApproved
    case linkDeviceMismatch

    var errorDescription: String? {
      switch self {
      case .noActiveAccount:
        return "Нет активного аккаунта для привязки устройства."
      case .missingSeedPhrase:
        return "На текущем устройстве отсутствует recovery phrase."
      case .invalidProvisioningBlob:
        return "Не удалось расшифровать provisioning blob нового устройства."
      case .linkNotApproved:
        return "Запрос привязки ещё не подтверждён."
      case .linkDeviceMismatch:
        return "Сервер вернул другой device_id, чем был запрошен для привязки."
      }
    }
  }

  struct HostSession: Equatable {
    let sessionId: String
    let userHandle: String
    let linkCode: String
    let lDhPrivate: String
    let qrPayload: String
    let textCode: String
    let expiresAt: Date
  }

  struct JoinSession: Equatable {
    let linkPayload: DeviceLinkCodePayload
    let requestId: String
    let pollToken: String
    let reservedDeviceId: String
    let nDhPrivate: String
    let deviceIdentity: PersistedDeviceIdentity
  }

  private let container: AppContainer
  private lazy var localConversationArchiveService: LocalConversationArchiveService = {
    LocalConversationArchiveService(
      defaults: container.defaults,
      secureStateStore: container.secureStateStore,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )
  }()

  init(container: AppContainer) {
    self.container = container
  }

  func startHostingLink(expiresInSec: Int? = 300) async throws -> HostSession {
    let userHandle: String = try currentUserHandle()

    let linkCode: String = generateLinkCode()
    let lDhPrivate: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    let lDhPub: String = lDhPrivate.publicKey.rawRepresentation.base64EncodedString()
    let response: FederatedDeviceLinkStartResponse = try await container.deviceLinkService.startLink(
      linkCode: linkCode,
      lDhPub: lDhPub,
      expiresInSec: expiresInSec
    )

    let payload = DeviceLinkCodePayload(
      userHandle: userHandle,
      linkCode: linkCode,
      lDhPub: lDhPub
    )

    return HostSession(
      sessionId: response.linkSessionId,
      userHandle: userHandle,
      linkCode: linkCode,
      lDhPrivate: lDhPrivate.rawRepresentation.base64EncodedString(),
      qrPayload: try DeviceLinkCodeCodec.encodeJSON(payload),
      textCode: try DeviceLinkCodeCodec.encodeTextCode(payload),
      expiresAt: response.expiresAt
    )
  }

  func fetchPendingRequests(sessionId: String) async throws -> [FederatedDeviceLinkSessionRequest] {
    let response: FederatedDeviceLinkSessionRequestsResponse = try await container.deviceLinkService.listLinkRequests(
      sessionId: sessionId
    )
    return response.requests
  }

  func approve(hostSession: HostSession, request: FederatedDeviceLinkSessionRequest) async throws {
    try await container.localAuthenticationService.authenticate(
      reason: "Подтвердите привязку нового устройства TellMe."
    )
    let hostDeviceIdentity = try resolvedDeviceIdentity(for: hostSession.userHandle)
    let accountSignPub = try await resolveAccountSignPublicKey(for: hostSession.userHandle)
    let approvedDeviceCertificate = try buildApprovedDeviceCertificate(
      userHandle: hostSession.userHandle,
      hostIdentity: hostDeviceIdentity,
      request: request
    )
    let payload = DeviceLinkProvisioningPayload(
      userHandle: hostSession.userHandle,
      accountSignPub: accountSignPub,
      generatedAt: Date(),
      localState: localConversationArchiveService.exportSnapshot(for: hostSession.userHandle),
      trustState: container.e2eSecurityService.exportSnapshot(for: hostSession.userHandle)
    )
    let shared: SharedSecret = try container.cryptoService.x25519SharedSecret(
      privateKey: try keyAgreementPrivateKey(fromBase64: hostSession.lDhPrivate),
      peerPublicBase64: request.nDhPub
    )
    let key: SymmetricKey = container.cryptoService.deriveSymmetricKey(
      sharedSecret: shared,
      context: "device_link|\(request.requestId)"
    )
    let plaintext: Data = try JSONCoding.encoder.encode(payload)
    let envelope: AEADCiphertextEnvelope = try container.cryptoService.encryptAEAD(
      plaintext: plaintext,
      key: key,
      aad: Data(request.requestId.utf8)
    )
    let envelopeData: Data = try JSONCoding.encoder.encode(envelope)
    guard let serialized: String = String(data: envelopeData, encoding: .utf8) else {
      throw DeviceLinkViewModelError.invalidProvisioningBlob
    }

    _ = try await container.deviceLinkService.approveLink(
      linkCode: hostSession.linkCode,
      requestId: request.requestId,
      approvedDeviceCertificate: approvedDeviceCertificate,
      encryptedProvisioningBlob: serialized
    )
  }

  func requestLink(using payload: DeviceLinkCodePayload) async throws -> JoinSession {
    let deviceIdentity = try container.deviceKeysService.createUnsignedDeviceIdentity(deviceId: nil)
    let reservedDeviceId: String = deviceIdentity.deviceId
    let nDhPrivate: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    let response: FederatedDeviceLinkRequestResponse = try await container.deviceLinkService.requestLink(
      userHandle: payload.userHandle,
      linkCode: payload.linkCode,
      nDhPub: nDhPrivate.publicKey.rawRepresentation.base64EncodedString(),
      deviceBundle: container.deviceKeysService.bundle(from: deviceIdentity)
    )

    return JoinSession(
      linkPayload: payload,
      requestId: response.requestId,
      pollToken: response.pollToken,
      reservedDeviceId: reservedDeviceId,
      nDhPrivate: nDhPrivate.rawRepresentation.base64EncodedString(),
      deviceIdentity: deviceIdentity
    )
  }

  func poll(joinSession: JoinSession) async throws -> FederatedDeviceLinkPollResponse {
    try await container.deviceLinkService.pollLinkRequest(
      requestId: joinSession.requestId,
      pollToken: joinSession.pollToken
    )
  }

  func complete(
    joinSession: JoinSession,
    approvedDeviceCertificate: DeviceCertificateV2,
    encryptedProvisioningBlob: String
  ) async throws -> User {
    let provisioning: DeviceLinkProvisioningPayload = try decryptProvisioningBlob(
      encryptedProvisioningBlob,
      requestId: joinSession.requestId,
      peerPublicBase64: joinSession.linkPayload.lDhPub,
      privateKeyBase64: joinSession.nDhPrivate
    )

    guard approvedDeviceCertificate.deviceId == joinSession.reservedDeviceId,
      approvedDeviceCertificate.deviceSignPub == joinSession.deviceIdentity.dkSignPublic,
      approvedDeviceCertificate.deviceDhPub == joinSession.deviceIdentity.dkDhPublic
    else {
      throw DeviceLinkViewModelError.linkDeviceMismatch
    }

    let deviceIdentity = container.deviceKeysService.appendApprovedCertificate(
      approvedDeviceCertificate,
      to: joinSession.deviceIdentity
    )
    let signedPrekey: SignedPrekeyBundle = try container.prekeysService.generateAndStoreSignedPrekey(
      deviceIdentity: deviceIdentity
    )
    let oneTimePrekeys: [OneTimePrekeyBundle] = try container.prekeysService.generateAndStoreOneTimePrekeys(
      count: 100,
      deviceId: deviceIdentity.deviceId
    )

    let response: FederatedDeviceLinkCompleteResponse = try await container.deviceLinkService.completeLink(
      FederatedDeviceLinkCompleteRequest(
        requestId: joinSession.requestId,
        pollToken: joinSession.pollToken,
        devicePubKeys: FederatedDevicePublicKeys(
          deviceId: deviceIdentity.deviceId,
          dkSignPub: deviceIdentity.dkSignPublic,
          dkDhPub: deviceIdentity.dkDhPublic
        ),
        signedPrekey: FederatedPrekeySigned(
          prekeyId: signedPrekey.prekeyId,
          signedPrekeyPub: signedPrekey.signedPrekeyPub,
          signature: signedPrekey.signature,
          expiresAt: nil
        ),
        oneTimePrekeys: oneTimePrekeys.map {
          FederatedPrekeyOneTime(prekeyId: $0.prekeyId, prekeyPub: $0.prekeyPub)
        }
      )
    )

    guard response.deviceId == joinSession.reservedDeviceId else {
      throw DeviceLinkViewModelError.linkDeviceMismatch
    }

    container.tokenStore.saveTokens(
      accessToken: response.sessionToken,
      refreshToken: response.refreshToken
    )

    let storageKeyData: Data = container.cryptoService.generateSeed(bytes: 32)
    container.keyMaterialStore.saveAccountStorageKeyData(storageKeyData, for: provisioning.userHandle)
    container.ratchetSessionStore.configure(storageKey: SymmetricKey(data: storageKeyData))

    container.keyMaterialStore.saveDeviceIdentity(deviceIdentity, for: provisioning.userHandle)
    container.keyMaterialStore.saveDeviceId(deviceIdentity.deviceId, for: provisioning.userHandle)
    container.keyMaterialStore.setCurrentUserId(provisioning.userHandle)
    if let localState: DeviceLinkLocalStateSnapshot = provisioning.localState {
      localConversationArchiveService.importSnapshot(localState, for: provisioning.userHandle)
    }
    if let trustState: DeviceLinkTrustStateSnapshot = provisioning.trustState {
      container.e2eSecurityService.importSnapshot(trustState, for: provisioning.userHandle)
    }

    let user: User = syntheticUser(from: provisioning.userHandle)
    container.sessionStore.save(user: SessionUser(user: user))
    return user
  }

  private func decryptProvisioningBlob(
    _ encryptedProvisioningBlob: String,
    requestId: String,
    peerPublicBase64: String,
    privateKeyBase64: String
  ) throws -> DeviceLinkProvisioningPayload {
    guard let envelopeData: Data = encryptedProvisioningBlob.data(using: .utf8) else {
      throw DeviceLinkViewModelError.invalidProvisioningBlob
    }

    let envelope: AEADCiphertextEnvelope = try JSONCoding.decoder.decode(AEADCiphertextEnvelope.self, from: envelopeData)
    let shared: SharedSecret = try container.cryptoService.x25519SharedSecret(
      privateKey: try keyAgreementPrivateKey(fromBase64: privateKeyBase64),
      peerPublicBase64: peerPublicBase64
    )
    let key: SymmetricKey = container.cryptoService.deriveSymmetricKey(
      sharedSecret: shared,
      context: "device_link|\(requestId)"
    )
    let plaintext: Data = try container.cryptoService.decryptAEAD(envelope: envelope, key: key)
    return try JSONCoding.decoder.decode(DeviceLinkProvisioningPayload.self, from: plaintext)
  }

  private func currentUserHandle() throws -> String {
    if let userHandle: String = container.sessionStore.currentUser?.id.trimmingCharacters(in: .whitespacesAndNewlines),
      !userHandle.isEmpty
    {
      return userHandle.lowercased()
    }

    if let userHandle: String = container.keyMaterialStore.currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !userHandle.isEmpty
    {
      return userHandle.lowercased()
    }

    throw DeviceLinkViewModelError.noActiveAccount
  }

  private func resolvedSeedPhrase(for userHandle: String) throws -> String {
    let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: userHandle,
      sessionUser: container.sessionStore.currentUser
    )

    if let resolvedSeed = container.keyMaterialStore.firstAvailableSeedPhrase(lookupIds: lookupIds) {
      return resolvedSeed.seedPhrase
    }

    throw DeviceLinkViewModelError.missingSeedPhrase
  }

  private func resolveAccountSignPublicKey(for userHandle: String) async throws -> String {
    if let resolvedSeed = try? resolvedSeedPhrase(for: userHandle) {
      let identity = try container.identityService.restoreIdentity(
        userHandle: userHandle,
        seedPhrase: resolvedSeed
      )
      return identity.ikSignPublic
    }

    let response = try await container.authService.fetchPublicKey(userHandle: userHandle)
    return response.publicKey
  }

  private func resolvedDeviceIdentity(for userHandle: String) throws -> PersistedDeviceIdentity {
    let lookupIds: [String] = container.keyMaterialStore.keyMaterialLookupOrder(
      explicitUserId: userHandle,
      sessionUser: container.sessionStore.currentUser
    )

    for lookupId in lookupIds {
      if let identity = container.keyMaterialStore.deviceIdentity(for: lookupId) {
        return identity
      }
    }

    throw DeviceLinkViewModelError.linkNotApproved
  }

  private func syntheticUser(from handle: String) -> User {
    User(
      id: handle,
      username: handle,
      email: handle,
      publicKey: "",
      createdAt: nil,
      updatedAt: nil
    )
  }

  private func keyAgreementPrivateKey(fromBase64 raw: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    guard let data: Data = Data(base64Encoded: raw) else {
      throw CryptoServiceError.keyImportFailed
    }

    return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
  }

  private func generateLinkCode() -> String {
    let data: Data = container.cryptoService.generateSeed(bytes: 16)
    return data.map { String(format: "%02x", $0) }.joined()
  }

  private func buildApprovedDeviceCertificate(
    userHandle: String,
    hostIdentity: PersistedDeviceIdentity,
    request: FederatedDeviceLinkSessionRequest
  ) throws -> DeviceCertificateV2 {
    guard let parent = hostIdentity.deviceCertificateChain.last else {
      throw DeviceLinkViewModelError.linkNotApproved
    }

    let unsigned = DeviceCertificateV2(
      deviceCertificateVersion: 2,
      accountHandle: userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      deviceId: request.newDeviceId,
      deviceSignPub: request.dkSignPub,
      deviceDhPub: request.dkDhPub,
      issuerKind: "device",
      issuerDeviceId: hostIdentity.deviceId,
      parentCertificateId: deviceCertificateId(parent),
      issuedAt: Date(),
      expiresAt: nil,
      signature: ""
    )
    let signature = try container.deviceKeysService.signMessage(
      message: deviceCertificateSigningPayload(unsigned),
      identity: hostIdentity
    )

    return DeviceCertificateV2(
      deviceCertificateVersion: unsigned.deviceCertificateVersion,
      accountHandle: unsigned.accountHandle,
      deviceId: unsigned.deviceId,
      deviceSignPub: unsigned.deviceSignPub,
      deviceDhPub: unsigned.deviceDhPub,
      issuerKind: unsigned.issuerKind,
      issuerDeviceId: unsigned.issuerDeviceId,
      parentCertificateId: unsigned.parentCertificateId,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      signature: signature
    )
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

  private func deviceCertificateId(_ certificate: DeviceCertificateV2) -> String {
    let payload = deviceCertificateSigningPayload(
      DeviceCertificateV2(
        deviceCertificateVersion: certificate.deviceCertificateVersion,
        accountHandle: certificate.accountHandle,
        deviceId: certificate.deviceId,
        deviceSignPub: certificate.deviceSignPub,
        deviceDhPub: certificate.deviceDhPub,
        issuerKind: certificate.issuerKind,
        issuerDeviceId: certificate.issuerDeviceId,
        parentCertificateId: certificate.parentCertificateId,
        issuedAt: certificate.issuedAt,
        expiresAt: certificate.expiresAt,
        signature: ""
      )
    )
    let hash = SHA256.hash(data: Data(payload.replacingOccurrences(of: "device_certificate|", with: "").utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
  }
}
