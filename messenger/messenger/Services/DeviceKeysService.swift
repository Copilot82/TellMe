import CryptoKit
import Foundation

struct PersistedDeviceIdentity: Codable, Equatable {
  let deviceId: String
  let dkSignPrivate: String
  let dkSignPublic: String
  let dkDhPrivate: String
  let dkDhPublic: String
  let deviceCertificateChain: [DeviceCertificateV2]
  let createdAt: Date

  init(
    deviceId: String,
    dkSignPrivate: String,
    dkSignPublic: String,
    dkDhPrivate: String,
    dkDhPublic: String,
    deviceCertificateChain: [DeviceCertificateV2],
    createdAt: Date
  ) {
    self.deviceId = deviceId
    self.dkSignPrivate = dkSignPrivate
    self.dkSignPublic = dkSignPublic
    self.dkDhPrivate = dkDhPrivate
    self.dkDhPublic = dkDhPublic
    self.deviceCertificateChain = deviceCertificateChain
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
    deviceId = try container.decode(String.self, forKey: .deviceId)
    dkSignPrivate = try container.decode(String.self, forKey: .dkSignPrivate)
    dkSignPublic = try container.decode(String.self, forKey: .dkSignPublic)
    dkDhPrivate = try container.decode(String.self, forKey: .dkDhPrivate)
    dkDhPublic = try container.decode(String.self, forKey: .dkDhPublic)
    deviceCertificateChain = try container.decodeIfPresent([DeviceCertificateV2].self, forKey: .deviceCertificateChain) ?? []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }
}

struct DeviceBundle: Codable, Equatable {
  let deviceId: String
  let dkSignPublic: String
  let dkDHPublic: String
  let deviceCertificateChain: [DeviceCertificateV2]
}

protocol DeviceKeysServiceProtocol {
  func generateDeviceId() -> String
  func createUnsignedDeviceIdentity(deviceId: String?) throws -> PersistedDeviceIdentity
  func createDeviceIdentity(userHandle: String, seedPhrase: String, deviceId: String?) throws -> PersistedDeviceIdentity
  func attachAccountCertificateChain(
    userHandle: String,
    seedPhrase: String,
    identity: PersistedDeviceIdentity
  ) throws -> PersistedDeviceIdentity
  func appendApprovedCertificate(
    _ certificate: DeviceCertificateV2,
    to identity: PersistedDeviceIdentity
  ) -> PersistedDeviceIdentity
  func signChallenge(nonce: String, identity: PersistedDeviceIdentity) throws -> String
  func signMessage(message: String, identity: PersistedDeviceIdentity) throws -> String
  func bundle(from identity: PersistedDeviceIdentity) -> DeviceBundle
}

// Device keys are derived and signed locally before any public device bundle reaches the server.
final class DeviceKeysService: DeviceKeysServiceProtocol {
  private let seedService: SeedServiceProtocol
  private let cryptoService: CryptoService

  init(seedService: SeedServiceProtocol, cryptoService: CryptoService) {
    self.seedService = seedService
    self.cryptoService = cryptoService
  }

  func createUnsignedDeviceIdentity(deviceId: String? = nil) throws -> PersistedDeviceIdentity {
    let resolvedDeviceId: String = deviceId ?? generateDeviceId()
    let dkSignPrivate: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()
    let dkDHPrivate: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()

    return PersistedDeviceIdentity(
      deviceId: resolvedDeviceId,
      dkSignPrivate: dkSignPrivate.rawRepresentation.base64EncodedString(),
      dkSignPublic: dkSignPrivate.publicKey.rawRepresentation.base64EncodedString(),
      dkDhPrivate: dkDHPrivate.rawRepresentation.base64EncodedString(),
      dkDhPublic: dkDHPrivate.publicKey.rawRepresentation.base64EncodedString(),
      deviceCertificateChain: [],
      createdAt: Date()
    )
  }

  func createDeviceIdentity(userHandle: String, seedPhrase: String, deviceId: String? = nil) throws -> PersistedDeviceIdentity {
    let unsigned = try createUnsignedDeviceIdentity(deviceId: deviceId)
    return try attachAccountCertificateChain(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      identity: unsigned
    )
  }

  func attachAccountCertificateChain(
    userHandle: String,
    seedPhrase: String,
    identity: PersistedDeviceIdentity
  ) throws -> PersistedDeviceIdentity {
    guard let seed: Data = seedService.decodeSeedPhrase(seedPhrase) else {
      throw CryptoServiceError.keyImportFailed
    }

    let derived: DerivedIdentityKeys = try cryptoService.deriveIdentityKeys(seed: seed)
    let certificate = try makeAccountSignedCertificate(
      userHandle: userHandle,
      identity: identity,
      signer: derived.ikSignPrivate
    )

    return PersistedDeviceIdentity(
      deviceId: identity.deviceId,
      dkSignPrivate: identity.dkSignPrivate,
      dkSignPublic: identity.dkSignPublic,
      dkDhPrivate: identity.dkDhPrivate,
      dkDhPublic: identity.dkDhPublic,
      deviceCertificateChain: [certificate],
      createdAt: identity.createdAt
    )
  }

  func appendApprovedCertificate(
    _ certificate: DeviceCertificateV2,
    to identity: PersistedDeviceIdentity
  ) -> PersistedDeviceIdentity {
    PersistedDeviceIdentity(
      deviceId: identity.deviceId,
      dkSignPrivate: identity.dkSignPrivate,
      dkSignPublic: identity.dkSignPublic,
      dkDhPrivate: identity.dkDhPrivate,
      dkDhPublic: identity.dkDhPublic,
      deviceCertificateChain: identity.deviceCertificateChain + [certificate],
      createdAt: identity.createdAt
    )
  }

  func signChallenge(nonce: String, identity: PersistedDeviceIdentity) throws -> String {
    try signMessage(message: nonce, identity: identity)
  }

  func signMessage(message: String, identity: PersistedDeviceIdentity) throws -> String {
    let privateKey = try signingPrivateKey(fromBase64: identity.dkSignPrivate)
    return try cryptoService.signEd25519(message: Data(message.utf8), privateKey: privateKey)
  }

  func bundle(from identity: PersistedDeviceIdentity) -> DeviceBundle {
    DeviceBundle(
      deviceId: identity.deviceId,
      dkSignPublic: identity.dkSignPublic,
      dkDHPublic: identity.dkDhPublic,
      deviceCertificateChain: identity.deviceCertificateChain
    )
  }

  func generateDeviceId() -> String {
    let random: Data = cryptoService.generateSeed(bytes: 12)
    let suffix: String = random.map { String(format: "%02x", $0) }.joined()
    return "dev_\(suffix)"
  }

  private func signingPrivateKey(fromBase64 raw: String) throws -> Curve25519.Signing.PrivateKey {
    guard let data: Data = Data(base64Encoded: raw) else {
      throw CryptoServiceError.keyImportFailed
    }

    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
  }

  private func makeAccountSignedCertificate(
    userHandle: String,
    identity: PersistedDeviceIdentity,
    signer: Curve25519.Signing.PrivateKey
  ) throws -> DeviceCertificateV2 {
    let normalizedHandle = userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let issuedAt = Date()
    let unsigned = DeviceCertificateV2(
      deviceCertificateVersion: 2,
      accountHandle: normalizedHandle,
      deviceId: identity.deviceId,
      deviceSignPub: identity.dkSignPublic,
      deviceDhPub: identity.dkDhPublic,
      issuerKind: "account",
      issuerDeviceId: nil,
      parentCertificateId: nil,
      issuedAt: issuedAt,
      expiresAt: nil,
      signature: ""
    )
    let signature = try cryptoService.signEd25519(
      message: Data(deviceCertificateSigningPayload(for: unsigned).utf8),
      privateKey: signer
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

  private func deviceCertificateSigningPayload(for certificate: DeviceCertificateV2) -> String {
    let dateFormatter = ISO8601DateFormatter.withFractionalSeconds
    let issuedAt = dateFormatter.string(from: certificate.issuedAt)
    let expiresAt = certificate.expiresAt.map(dateFormatter.string(from:)) ?? ""

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
