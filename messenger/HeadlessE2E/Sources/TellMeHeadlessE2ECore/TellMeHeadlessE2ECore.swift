import CryptoKit
import Foundation

public enum HeadlessE2EError: Error, Equatable, LocalizedError {
  case invalidSeedPhrase
  case invalidUserHandle(String)
  case invalidDeviceId(String)
  case invalidPrekeyCount(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidSeedPhrase:
      "Seed phrase must be base64-encoded 32-byte account seed material."
    case .invalidUserHandle(let handle):
      "Invalid TellMe v2 user handle: \(handle)"
    case .invalidDeviceId(let deviceId):
      "Invalid TellMe v2 device id: \(deviceId)"
    case .invalidPrekeyCount(let count):
      "Invalid one-time prekey count: \(count)"
    }
  }
}

public enum SeedCodec {
  public static func generateSeed(byteCount: Int = 32) -> Data {
    Data((0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
  }

  public static func encodeSeedPhrase(_ seed: Data) -> String {
    seed.base64EncodedString()
  }

  public static func decodeSeedPhrase(_ phrase: String) throws -> Data {
    guard let seed = Data(base64Encoded: phrase.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32
    else {
      throw HeadlessE2EError.invalidSeedPhrase
    }

    return seed
  }
}

public struct DerivedIdentityKeys {
  let ikSignPrivate: Curve25519.Signing.PrivateKey
  public let ikSignPublicBase64: String
  let ikDHPrivate: Curve25519.KeyAgreement.PrivateKey
  public let ikDHPublicBase64: String
  let storageKey: SymmetricKey
}

public enum IdentityCrypto {
  public static func hkdfSHA256(
    inputKeyMaterial: Data,
    salt: Data = Data(),
    info: Data,
    outputLength: Int = 32
  ) -> Data {
    let inputKey = SymmetricKey(data: inputKeyMaterial)
    let derivedKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: inputKey,
      salt: salt,
      info: info,
      outputByteCount: outputLength
    )
    return derivedKey.withUnsafeBytes { Data($0) }
  }

  public static func deriveIdentityKeys(seed: Data) throws -> DerivedIdentityKeys {
    let signSeed = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("ik_sign_seed".utf8),
      outputLength: 32
    )
    let dhSeed = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("ik_dh_seed".utf8),
      outputLength: 32
    )
    let storageSeed = hkdfSHA256(
      inputKeyMaterial: seed,
      info: Data("storage_key".utf8),
      outputLength: 32
    )

    let ikSignPrivate = try Curve25519.Signing.PrivateKey(rawRepresentation: signSeed)
    let ikDHPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSeed)
    let storageKey = SymmetricKey(data: storageSeed)

    return DerivedIdentityKeys(
      ikSignPrivate: ikSignPrivate,
      ikSignPublicBase64: ikSignPrivate.publicKey.rawRepresentation.base64EncodedString(),
      ikDHPrivate: ikDHPrivate,
      ikDHPublicBase64: ikDHPrivate.publicKey.rawRepresentation.base64EncodedString(),
      storageKey: storageKey
    )
  }

  public static func signEd25519(message: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
    try privateKey.signature(for: message).base64EncodedString()
  }

  public static func verifyEd25519(message: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
    guard let signature = Data(base64Encoded: signatureBase64),
      let publicKeyData = Data(base64Encoded: publicKeyBase64),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
      return false
    }

    return publicKey.isValidSignature(signature, for: message)
  }
}

public struct DeviceCertificateV2: Codable, Equatable {
  public let deviceCertificateVersion: Int
  public let accountHandle: String
  public let deviceId: String
  public let deviceSignPub: String
  public let deviceDhPub: String
  public let issuerKind: String
  public let issuerDeviceId: String?
  public let parentCertificateId: String?
  public let issuedAt: Date
  public let expiresAt: Date?
  public let signature: String

  public init(
    deviceCertificateVersion: Int,
    accountHandle: String,
    deviceId: String,
    deviceSignPub: String,
    deviceDhPub: String,
    issuerKind: String,
    issuerDeviceId: String?,
    parentCertificateId: String?,
    issuedAt: Date,
    expiresAt: Date?,
    signature: String
  ) {
    self.deviceCertificateVersion = deviceCertificateVersion
    self.accountHandle = accountHandle
    self.deviceId = deviceId
    self.deviceSignPub = deviceSignPub
    self.deviceDhPub = deviceDhPub
    self.issuerKind = issuerKind
    self.issuerDeviceId = issuerDeviceId
    self.parentCertificateId = parentCertificateId
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }
}

public struct FederatedInitialDevice: Codable, Equatable {
  public let deviceId: String
  public let dkSignPub: String
  public let dkDhPub: String
  public let deviceCertificateChain: [DeviceCertificateV2]
}

public struct FederatedDevicePublicKeys: Codable, Equatable {
  public let deviceId: String
  public let dkSignPub: String
  public let dkDhPub: String
}

public struct FederatedRegisterRequest: Codable, Equatable {
  public let userHandle: String
  public let ikSignPub: String
  public let ikDhPub: String
  public let signature: String
  public let timestamp: String
  public let initialDevice: FederatedInitialDevice
}

public struct FederatedPrekeySigned: Codable, Equatable {
  public let prekeyId: String
  public let signedPrekeyPub: String
  public let signature: String
  public let expiresAt: Date?
}

public struct FederatedPrekeyOneTime: Codable, Equatable {
  public let prekeyId: String
  public let prekeyPub: String
}

public struct FederatedPrekeysPublishRequest: Codable, Equatable {
  public let protocolVersion: Int
  public let deviceId: String
  public let signedPrekey: FederatedPrekeySigned
  public let oneTimePrekeys: [FederatedPrekeyOneTime]
}

public struct FederatedAuthFinishRequest: Codable, Equatable {
  public let userHandle: String
  public let deviceId: String
  public let challengeId: String
  public let signature: String
}

public struct FederatedDeviceRevokeRequest: Codable, Equatable {
  public let deviceId: String
  public let signature: String
  public let timestamp: String
}

public struct HeadlessMediaUploadAttestation: Codable, Equatable {
  public let capabilityToken: String
  public let ciphertextSha256: String
  public let scanVerdict: String
  public let riskFlags: [String]
  public let scannerVersion: Int
  public let rulesVersion: Int
  public let attestationSignature: String
}

public struct HeadlessDeviceIdentity {
  public let deviceId: String
  public let dkSignPublicBase64: String
  public let dkDHPublicBase64: String
  public let deviceCertificateChain: [DeviceCertificateV2]
  let dkSignPrivate: Curve25519.Signing.PrivateKey
  let dkDHPrivate: Curve25519.KeyAgreement.PrivateKey
}

public enum DeviceCertificateCodec {
  public static func canonicalFields(for certificate: DeviceCertificateV2) -> [String] {
    [
      String(certificate.deviceCertificateVersion),
      certificate.accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      certificate.deviceId,
      certificate.deviceSignPub,
      certificate.deviceDhPub,
      certificate.issuerKind,
      certificate.issuerDeviceId ?? "",
      certificate.parentCertificateId ?? "",
      TellMeDateFormat.fractionalString(from: certificate.issuedAt),
      certificate.expiresAt.map(TellMeDateFormat.fractionalString(from:)) ?? "",
    ]
  }

  public static func signingPayload(for certificate: DeviceCertificateV2) -> String {
    "device_certificate|\(canonicalFields(for: certificate).joined(separator: "|"))"
  }

  public static func certificateId(for certificate: DeviceCertificateV2) -> String {
    SHA256Hex.string(canonicalFields(for: certificate).joined(separator: "|"))
  }
}

public enum HeadlessIdentityFactory {
  public static func normalizeHandle(_ rawHandle: String) throws -> String {
    let normalized = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let pattern = #"^@[a-z0-9._-]+:[a-z0-9.-]+$"#
    guard normalized.range(of: pattern, options: .regularExpression) != nil else {
      throw HeadlessE2EError.invalidUserHandle(rawHandle)
    }
    return normalized
  }

  public static func makeDeviceId() -> String {
    let random = SeedCodec.generateSeed(byteCount: 12)
    return "dev_\(random.map { String(format: "%02x", $0) }.joined())"
  }

  public static func makeAccountIdentity(
    userHandle rawHandle: String,
    seedPhrase: String? = nil,
    deviceId rawDeviceId: String? = nil,
    issuedAt: Date = Date()
  ) throws -> HeadlessAccountIdentity {
    let userHandle = try normalizeHandle(rawHandle)
    let seed = try seedPhrase.map(SeedCodec.decodeSeedPhrase) ?? SeedCodec.generateSeed()
    let derived = try IdentityCrypto.deriveIdentityKeys(seed: seed)
    let deviceId = try resolveDeviceId(rawDeviceId)
    let deviceSalt = Data(deviceId.utf8)
    let deviceSignSeed = IdentityCrypto.hkdfSHA256(
      inputKeyMaterial: seed,
      salt: deviceSalt,
      info: Data("headless_device_sign_seed".utf8),
      outputLength: 32
    )
    let deviceDHSeed = IdentityCrypto.hkdfSHA256(
      inputKeyMaterial: seed,
      salt: deviceSalt,
      info: Data("headless_device_dh_seed".utf8),
      outputLength: 32
    )
    let deviceSignPrivate = try Curve25519.Signing.PrivateKey(rawRepresentation: deviceSignSeed)
    let deviceDHPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: deviceDHSeed)
    let unsignedCertificate = DeviceCertificateV2(
      deviceCertificateVersion: 2,
      accountHandle: userHandle,
      deviceId: deviceId,
      deviceSignPub: deviceSignPrivate.publicKey.rawRepresentation.base64EncodedString(),
      deviceDhPub: deviceDHPrivate.publicKey.rawRepresentation.base64EncodedString(),
      issuerKind: "account",
      issuerDeviceId: nil,
      parentCertificateId: nil,
      issuedAt: issuedAt,
      expiresAt: nil,
      signature: ""
    )
    let certificateSignature = try IdentityCrypto.signEd25519(
      message: Data(DeviceCertificateCodec.signingPayload(for: unsignedCertificate).utf8),
      privateKey: derived.ikSignPrivate
    )
    let certificate = DeviceCertificateV2(
      deviceCertificateVersion: unsignedCertificate.deviceCertificateVersion,
      accountHandle: unsignedCertificate.accountHandle,
      deviceId: unsignedCertificate.deviceId,
      deviceSignPub: unsignedCertificate.deviceSignPub,
      deviceDhPub: unsignedCertificate.deviceDhPub,
      issuerKind: unsignedCertificate.issuerKind,
      issuerDeviceId: unsignedCertificate.issuerDeviceId,
      parentCertificateId: unsignedCertificate.parentCertificateId,
      issuedAt: unsignedCertificate.issuedAt,
      expiresAt: unsignedCertificate.expiresAt,
      signature: certificateSignature
    )
    let deviceIdentity = HeadlessDeviceIdentity(
      deviceId: deviceId,
      dkSignPublicBase64: unsignedCertificate.deviceSignPub,
      dkDHPublicBase64: unsignedCertificate.deviceDhPub,
      deviceCertificateChain: [certificate],
      dkSignPrivate: deviceSignPrivate,
      dkDHPrivate: deviceDHPrivate
    )

    return HeadlessAccountIdentity(
      userHandle: userHandle,
      ikSignPublicBase64: derived.ikSignPublicBase64,
      ikDHPublicBase64: derived.ikDHPublicBase64,
      deviceIdentity: deviceIdentity,
      accountSignPrivate: derived.ikSignPrivate
    )
  }

  private static func resolveDeviceId(_ rawDeviceId: String?) throws -> String {
    guard let rawDeviceId else {
      return makeDeviceId()
    }

    let deviceId = rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard deviceId.count >= 3, deviceId.count <= 255 else {
      throw HeadlessE2EError.invalidDeviceId(rawDeviceId)
    }
    return deviceId
  }
}

public struct HeadlessAccountIdentity {
  public let userHandle: String
  public let ikSignPublicBase64: String
  public let ikDHPublicBase64: String
  public let deviceIdentity: HeadlessDeviceIdentity
  let accountSignPrivate: Curve25519.Signing.PrivateKey

  public func makeRegisterRequest(timestamp: Date = Date()) throws -> (FederatedRegisterRequest, String) {
    let timestampString = TellMeDateFormat.fractionalString(from: timestamp)
    let proofPayload = "register|\(userHandle)|\(ikSignPublicBase64)|\(ikDHPublicBase64)|\(timestampString)"
    let signature = try IdentityCrypto.signEd25519(
      message: Data(proofPayload.utf8),
      privateKey: accountSignPrivate
    )
    let request = FederatedRegisterRequest(
      userHandle: userHandle,
      ikSignPub: ikSignPublicBase64,
      ikDhPub: ikDHPublicBase64,
      signature: signature,
      timestamp: timestampString,
      initialDevice: FederatedInitialDevice(
        deviceId: deviceIdentity.deviceId,
        dkSignPub: deviceIdentity.dkSignPublicBase64,
        dkDhPub: deviceIdentity.dkDHPublicBase64,
        deviceCertificateChain: deviceIdentity.deviceCertificateChain
      )
    )
    return (request, proofPayload)
  }

  public func makeAuthFinishRequest(challengeId: String, nonce: String) throws -> FederatedAuthFinishRequest {
    let signature = try IdentityCrypto.signEd25519(
      message: Data(nonce.utf8),
      privateKey: deviceIdentity.dkSignPrivate
    )
    return FederatedAuthFinishRequest(
      userHandle: userHandle,
      deviceId: deviceIdentity.deviceId,
      challengeId: challengeId,
      signature: signature
    )
  }

  public func makeDeviceRevokeRequest(
    targetDeviceId: String,
    timestamp: Date = Date()
  ) throws -> (FederatedDeviceRevokeRequest, String) {
    let timestampString = TellMeDateFormat.fractionalString(from: timestamp)
    let payload = "revoke|\(targetDeviceId)|\(timestampString)"
    let signature = try IdentityCrypto.signEd25519(
      message: Data(payload.utf8),
      privateKey: deviceIdentity.dkSignPrivate
    )
    return (
      FederatedDeviceRevokeRequest(
        deviceId: targetDeviceId,
        signature: signature,
        timestamp: timestampString
      ),
      payload
    )
  }

  public func makeLinkedDeviceApprovalCertificate(
    linkedIdentity: HeadlessAccountIdentity,
    issuedAt: Date = Date()
  ) throws -> (DeviceCertificateV2, String, String) {
    let parentCertificate = deviceIdentity.deviceCertificateChain[0]
    let parentCertificateId = DeviceCertificateCodec.certificateId(for: parentCertificate)
    let unsignedCertificate = DeviceCertificateV2(
      deviceCertificateVersion: 2,
      accountHandle: userHandle,
      deviceId: linkedIdentity.deviceIdentity.deviceId,
      deviceSignPub: linkedIdentity.deviceIdentity.dkSignPublicBase64,
      deviceDhPub: linkedIdentity.deviceIdentity.dkDHPublicBase64,
      issuerKind: "device",
      issuerDeviceId: deviceIdentity.deviceId,
      parentCertificateId: parentCertificateId,
      issuedAt: issuedAt,
      expiresAt: nil,
      signature: ""
    )
    let payload = DeviceCertificateCodec.signingPayload(for: unsignedCertificate)
    let signature = try IdentityCrypto.signEd25519(
      message: Data(payload.utf8),
      privateKey: deviceIdentity.dkSignPrivate
    )
    let certificate = DeviceCertificateV2(
      deviceCertificateVersion: unsignedCertificate.deviceCertificateVersion,
      accountHandle: unsignedCertificate.accountHandle,
      deviceId: unsignedCertificate.deviceId,
      deviceSignPub: unsignedCertificate.deviceSignPub,
      deviceDhPub: unsignedCertificate.deviceDhPub,
      issuerKind: unsignedCertificate.issuerKind,
      issuerDeviceId: unsignedCertificate.issuerDeviceId,
      parentCertificateId: unsignedCertificate.parentCertificateId,
      issuedAt: unsignedCertificate.issuedAt,
      expiresAt: unsignedCertificate.expiresAt,
      signature: signature
    )
    return (certificate, payload, parentCertificateId)
  }

  public func makeMediaUploadAttestation(
    mediaId: String,
    capabilityToken: String,
    ciphertextSha256: String,
    ciphertextSize: Int,
    scanVerdict: String,
    riskFlags: [String],
    scannerVersion: Int,
    rulesVersion: Int
  ) throws -> (HeadlessMediaUploadAttestation, String) {
    let payload = MediaUploadAttestationCodec.payload(
      mediaId: mediaId,
      userHandle: userHandle,
      deviceId: deviceIdentity.deviceId,
      capabilityToken: capabilityToken,
      ciphertextSha256: ciphertextSha256,
      ciphertextSize: ciphertextSize,
      scanVerdict: scanVerdict,
      riskFlags: riskFlags,
      scannerVersion: scannerVersion,
      rulesVersion: rulesVersion
    )
    let signature = try IdentityCrypto.signEd25519(
      message: Data(payload.utf8),
      privateKey: accountSignPrivate
    )
    return (
      HeadlessMediaUploadAttestation(
        capabilityToken: capabilityToken,
        ciphertextSha256: ciphertextSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        scanVerdict: scanVerdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        riskFlags: MediaUploadAttestationCodec.canonicalizeRiskFlags(riskFlags),
        scannerVersion: scannerVersion,
        rulesVersion: rulesVersion,
        attestationSignature: signature
      ),
      payload
    )
  }
}

public enum MediaUploadAttestationCodec {
  public static func canonicalizeRiskFlags(_ flags: [String]) -> [String] {
    Array(
      Set(
        flags
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
          .filter { !$0.isEmpty }
      )
    ).sorted()
  }

  public static func hashCapabilityToken(_ token: String) -> String {
    SHA256Hex.string(token.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func payload(
    mediaId: String,
    userHandle: String,
    deviceId: String,
    capabilityToken: String,
    ciphertextSha256: String,
    ciphertextSize: Int,
    scanVerdict: String,
    riskFlags: [String],
    scannerVersion: Int,
    rulesVersion: Int
  ) -> String {
    [
      "media-upload-v1",
      mediaId,
      userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      deviceId.trimmingCharacters(in: .whitespacesAndNewlines),
      hashCapabilityToken(capabilityToken),
      ciphertextSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      String(ciphertextSize),
      scanVerdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      canonicalizeRiskFlags(riskFlags).joined(separator: ","),
      String(scannerVersion),
      String(rulesVersion),
    ].joined(separator: "|")
  }
}

public enum PrekeyFactory {
  public static func makeSignedPrekey(deviceIdentity: HeadlessDeviceIdentity) throws -> (FederatedPrekeySigned, String) {
    let prekey = Curve25519.KeyAgreement.PrivateKey()
    let prekeyPub = prekey.publicKey.rawRepresentation.base64EncodedString()
    let prekeyId = UUID().uuidString
    let payload = "signed_prekey|\(prekeyId)|\(prekeyPub)"
    let signature = try IdentityCrypto.signEd25519(
      message: Data(payload.utf8),
      privateKey: deviceIdentity.dkSignPrivate
    )
    return (
      FederatedPrekeySigned(
        prekeyId: prekeyId,
        signedPrekeyPub: prekeyPub,
        signature: signature,
        expiresAt: nil
      ),
      payload
    )
  }

  public static func makeOneTimePrekeys(count: Int) throws -> [FederatedPrekeyOneTime] {
    guard (0...1000).contains(count) else {
      throw HeadlessE2EError.invalidPrekeyCount(count)
    }

    return (0..<count).map { _ in
      let prekey = Curve25519.KeyAgreement.PrivateKey()
      return FederatedPrekeyOneTime(
        prekeyId: UUID().uuidString,
        prekeyPub: prekey.publicKey.rawRepresentation.base64EncodedString()
      )
    }
  }
}

public struct HeadlessContractFixture: Codable, Equatable {
  public let contractVersion: Int
  public let generatedAt: Date
  public let userHandle: String
  public let deviceId: String
  public let publicKeys: PublicKeySummary
  public let registrationProofPayloadSha256: String
  public let deviceCertificatePayloadSha256: String
  public let deviceCertificateId: String
  public let signedPrekeyPayloadSha256: String
  public let registerRequestJsonSha256: String
  public let prekeysPublishRequestJsonSha256: String
  public let registerRequest: FederatedRegisterRequest
  public let prekeysPublishRequest: FederatedPrekeysPublishRequest
  public let securityInvariants: SecurityInvariantSummary

  public struct PublicKeySummary: Codable, Equatable {
    public let ikSignPub: String
    public let ikDhPub: String
    public let dkSignPub: String
    public let dkDhPub: String
  }

  public struct SecurityInvariantSummary: Codable, Equatable {
    public let privateSeedMaterialSerialized: Bool
    public let privateDeviceKeysSerialized: Bool
    public let callSignalingTransport: String
    public let defaultMediaTransport: String
    public let directWebrtcMode: String
  }
}

public struct HeadlessAuthFinishProof: Codable, Equatable {
  public let contractVersion: Int
  public let generatedAt: Date
  public let userHandle: String
  public let deviceId: String
  public let challengeId: String
  public let nonceSha256: String
  public let authFinishRequest: FederatedAuthFinishRequest
  public let authFinishRequestJsonSha256: String
  public let securityInvariants: SecurityInvariantSummary

  public struct SecurityInvariantSummary: Codable, Equatable {
    public let challengeNonceSerialized: Bool
    public let privateSeedMaterialSerialized: Bool
    public let privateDeviceKeysSerialized: Bool
  }
}

public struct HeadlessDeviceRevokeProof: Codable, Equatable {
  public let contractVersion: Int
  public let generatedAt: Date
  public let userHandle: String
  public let signingDeviceId: String
  public let targetDeviceId: String
  public let revokePayloadSha256: String
  public let deviceRevokeRequest: FederatedDeviceRevokeRequest
  public let deviceRevokeRequestJsonSha256: String
  public let securityInvariants: SecurityInvariantSummary

  public struct SecurityInvariantSummary: Codable, Equatable {
    public let privateSeedMaterialSerialized: Bool
    public let privateDeviceKeysSerialized: Bool
  }
}

public struct HeadlessDeviceLinkApprovalProof: Codable, Equatable {
  public let contractVersion: Int
  public let generatedAt: Date
  public let userHandle: String
  public let hostDeviceId: String
  public let linkedDeviceId: String
  public let hostCertificateId: String
  public let approvalCertificatePayloadSha256: String
  public let approvedDeviceCertificate: DeviceCertificateV2
  public let devicePubKeys: FederatedDevicePublicKeys
  public let prekeysPublishRequest: FederatedPrekeysPublishRequest
  public let securityInvariants: SecurityInvariantSummary

  public struct SecurityInvariantSummary: Codable, Equatable {
    public let privateSeedMaterialSerialized: Bool
    public let privateHostDeviceKeysSerialized: Bool
    public let privateLinkedDeviceKeysSerialized: Bool
    public let provisioningPlaintextSerialized: Bool
  }
}

public struct HeadlessMediaUploadAttestationProof: Codable, Equatable {
  public let contractVersion: Int
  public let generatedAt: Date
  public let userHandle: String
  public let deviceId: String
  public let mediaId: String
  public let ciphertextSha256: String
  public let ciphertextSize: Int
  public let attestationPayloadSha256: String
  public let uploadHeaders: [String: String]
  public let attestation: HeadlessMediaUploadAttestation
  public let securityInvariants: SecurityInvariantSummary

  public struct SecurityInvariantSummary: Codable, Equatable {
    public let plaintextSerialized: Bool
    public let fileKeySerialized: Bool
    public let privateSeedMaterialSerialized: Bool
    public let privateIdentityKeysSerialized: Bool
  }
}

public enum HeadlessContractFixtureBuilder {
  public static func make(
    userHandle: String,
    seedPhrase: String? = nil,
    deviceId: String? = nil,
    oneTimePrekeysCount: Int = 3,
    issuedAt: Date = Date(),
    timestamp: Date = Date(),
    generatedAt: Date = Date()
  ) throws -> HeadlessContractFixture {
    let accountIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: deviceId,
      issuedAt: issuedAt
    )
    let (registerRequest, registrationProofPayload) = try accountIdentity.makeRegisterRequest(timestamp: timestamp)
    let (signedPrekey, signedPrekeyPayload) = try PrekeyFactory.makeSignedPrekey(
      deviceIdentity: accountIdentity.deviceIdentity
    )
    let oneTimePrekeys = try PrekeyFactory.makeOneTimePrekeys(count: oneTimePrekeysCount)
    let prekeysPublishRequest = FederatedPrekeysPublishRequest(
      protocolVersion: 2,
      deviceId: accountIdentity.deviceIdentity.deviceId,
      signedPrekey: signedPrekey,
      oneTimePrekeys: oneTimePrekeys
    )
    let registerRequestJSON = try JSONCoding.canonicalData(registerRequest)
    let prekeysPublishRequestJSON = try JSONCoding.canonicalData(prekeysPublishRequest)
    let certificate = accountIdentity.deviceIdentity.deviceCertificateChain[0]
    let certificatePayload = DeviceCertificateCodec.signingPayload(for: certificate)

    return HeadlessContractFixture(
      contractVersion: 1,
      generatedAt: generatedAt,
      userHandle: accountIdentity.userHandle,
      deviceId: accountIdentity.deviceIdentity.deviceId,
      publicKeys: HeadlessContractFixture.PublicKeySummary(
        ikSignPub: accountIdentity.ikSignPublicBase64,
        ikDhPub: accountIdentity.ikDHPublicBase64,
        dkSignPub: accountIdentity.deviceIdentity.dkSignPublicBase64,
        dkDhPub: accountIdentity.deviceIdentity.dkDHPublicBase64
      ),
      registrationProofPayloadSha256: SHA256Hex.string(registrationProofPayload),
      deviceCertificatePayloadSha256: SHA256Hex.string(certificatePayload),
      deviceCertificateId: DeviceCertificateCodec.certificateId(for: certificate),
      signedPrekeyPayloadSha256: SHA256Hex.string(signedPrekeyPayload),
      registerRequestJsonSha256: SHA256Hex.string(registerRequestJSON),
      prekeysPublishRequestJsonSha256: SHA256Hex.string(prekeysPublishRequestJSON),
      registerRequest: registerRequest,
      prekeysPublishRequest: prekeysPublishRequest,
      securityInvariants: HeadlessContractFixture.SecurityInvariantSummary(
        privateSeedMaterialSerialized: false,
        privateDeviceKeysSerialized: false,
        callSignalingTransport: "encrypted_e2e_message_payload_only",
        defaultMediaTransport: "webrtc_turn_relay_only",
        directWebrtcMode: "disabled_release_1"
      )
    )
  }
}

public enum HeadlessMediaUploadAttestationProofBuilder {
  public static func make(
    userHandle: String,
    seedPhrase: String? = nil,
    deviceId: String? = nil,
    mediaId: String,
    capabilityToken: String,
    ciphertextSha256: String,
    ciphertextSize: Int,
    scanVerdict: String = "clean",
    riskFlags: [String] = [],
    scannerVersion: Int = 1,
    rulesVersion: Int = 1,
    issuedAt: Date = Date(),
    generatedAt: Date = Date()
  ) throws -> HeadlessMediaUploadAttestationProof {
    let accountIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: deviceId,
      issuedAt: issuedAt
    )
    let (attestation, payload) = try accountIdentity.makeMediaUploadAttestation(
      mediaId: mediaId,
      capabilityToken: capabilityToken,
      ciphertextSha256: ciphertextSha256,
      ciphertextSize: ciphertextSize,
      scanVerdict: scanVerdict,
      riskFlags: riskFlags,
      scannerVersion: scannerVersion,
      rulesVersion: rulesVersion
    )

    return HeadlessMediaUploadAttestationProof(
      contractVersion: 1,
      generatedAt: generatedAt,
      userHandle: accountIdentity.userHandle,
      deviceId: accountIdentity.deviceIdentity.deviceId,
      mediaId: mediaId,
      ciphertextSha256: attestation.ciphertextSha256,
      ciphertextSize: ciphertextSize,
      attestationPayloadSha256: SHA256Hex.string(payload),
      uploadHeaders: [
        "x-media-download-capability": attestation.capabilityToken,
        "x-media-ciphertext-sha256": attestation.ciphertextSha256,
        "x-media-scan-verdict": attestation.scanVerdict,
        "x-media-risk-flags": attestation.riskFlags.joined(separator: ","),
        "x-media-scanner-version": String(attestation.scannerVersion),
        "x-media-rules-version": String(attestation.rulesVersion),
        "x-media-attestation-signature": attestation.attestationSignature,
      ],
      attestation: attestation,
      securityInvariants: HeadlessMediaUploadAttestationProof.SecurityInvariantSummary(
        plaintextSerialized: false,
        fileKeySerialized: false,
        privateSeedMaterialSerialized: false,
        privateIdentityKeysSerialized: false
      )
    )
  }
}

public enum HeadlessAuthFinishProofBuilder {
  public static func make(
    userHandle: String,
    seedPhrase: String? = nil,
    deviceId: String? = nil,
    challengeId: String,
    nonce: String,
    issuedAt: Date = Date(),
    generatedAt: Date = Date()
  ) throws -> HeadlessAuthFinishProof {
    let accountIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: deviceId,
      issuedAt: issuedAt
    )
    let request = try accountIdentity.makeAuthFinishRequest(challengeId: challengeId, nonce: nonce)
    let requestJSON = try JSONCoding.canonicalData(request)

    return HeadlessAuthFinishProof(
      contractVersion: 1,
      generatedAt: generatedAt,
      userHandle: accountIdentity.userHandle,
      deviceId: accountIdentity.deviceIdentity.deviceId,
      challengeId: challengeId,
      nonceSha256: SHA256Hex.string(nonce),
      authFinishRequest: request,
      authFinishRequestJsonSha256: SHA256Hex.string(requestJSON),
      securityInvariants: HeadlessAuthFinishProof.SecurityInvariantSummary(
        challengeNonceSerialized: false,
        privateSeedMaterialSerialized: false,
        privateDeviceKeysSerialized: false
      )
    )
  }
}

public enum HeadlessDeviceRevokeProofBuilder {
  public static func make(
    userHandle: String,
    seedPhrase: String? = nil,
    signingDeviceId: String? = nil,
    targetDeviceId: String,
    timestamp: Date = Date(),
    generatedAt: Date = Date()
  ) throws -> HeadlessDeviceRevokeProof {
    let accountIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: signingDeviceId,
      issuedAt: timestamp
    )
    let (request, payload) = try accountIdentity.makeDeviceRevokeRequest(
      targetDeviceId: targetDeviceId,
      timestamp: timestamp
    )
    let requestJSON = try JSONCoding.canonicalData(request)

    return HeadlessDeviceRevokeProof(
      contractVersion: 1,
      generatedAt: generatedAt,
      userHandle: accountIdentity.userHandle,
      signingDeviceId: accountIdentity.deviceIdentity.deviceId,
      targetDeviceId: targetDeviceId,
      revokePayloadSha256: SHA256Hex.string(payload),
      deviceRevokeRequest: request,
      deviceRevokeRequestJsonSha256: SHA256Hex.string(requestJSON),
      securityInvariants: HeadlessDeviceRevokeProof.SecurityInvariantSummary(
        privateSeedMaterialSerialized: false,
        privateDeviceKeysSerialized: false
      )
    )
  }
}

public enum HeadlessDeviceLinkApprovalProofBuilder {
  public static func make(
    userHandle: String,
    seedPhrase: String? = nil,
    hostDeviceId: String? = nil,
    linkedDeviceId: String,
    oneTimePrekeysCount: Int = 3,
    issuedAt: Date = Date(),
    generatedAt: Date = Date()
  ) throws -> HeadlessDeviceLinkApprovalProof {
    let hostIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: hostDeviceId,
      issuedAt: issuedAt
    )
    let linkedIdentity = try HeadlessIdentityFactory.makeAccountIdentity(
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: linkedDeviceId,
      issuedAt: issuedAt
    )
    let (approvedCertificate, certificatePayload, parentCertificateId) =
      try hostIdentity.makeLinkedDeviceApprovalCertificate(
        linkedIdentity: linkedIdentity,
        issuedAt: issuedAt
      )
    let (signedPrekey, _) = try PrekeyFactory.makeSignedPrekey(
      deviceIdentity: linkedIdentity.deviceIdentity
    )
    let oneTimePrekeys = try PrekeyFactory.makeOneTimePrekeys(count: oneTimePrekeysCount)
    let prekeysPublishRequest = FederatedPrekeysPublishRequest(
      protocolVersion: 2,
      deviceId: linkedIdentity.deviceIdentity.deviceId,
      signedPrekey: signedPrekey,
      oneTimePrekeys: oneTimePrekeys
    )

    return HeadlessDeviceLinkApprovalProof(
      contractVersion: 1,
      generatedAt: generatedAt,
      userHandle: hostIdentity.userHandle,
      hostDeviceId: hostIdentity.deviceIdentity.deviceId,
      linkedDeviceId: linkedIdentity.deviceIdentity.deviceId,
      hostCertificateId: parentCertificateId,
      approvalCertificatePayloadSha256: SHA256Hex.string(certificatePayload),
      approvedDeviceCertificate: approvedCertificate,
      devicePubKeys: FederatedDevicePublicKeys(
        deviceId: linkedIdentity.deviceIdentity.deviceId,
        dkSignPub: linkedIdentity.deviceIdentity.dkSignPublicBase64,
        dkDhPub: linkedIdentity.deviceIdentity.dkDHPublicBase64
      ),
      prekeysPublishRequest: prekeysPublishRequest,
      securityInvariants: HeadlessDeviceLinkApprovalProof.SecurityInvariantSummary(
        privateSeedMaterialSerialized: false,
        privateHostDeviceKeysSerialized: false,
        privateLinkedDeviceKeysSerialized: false,
        provisioningPlaintextSerialized: false
      )
    )
  }
}

public enum JSONCoding {
  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let stringValue = try container.decode(String.self)

      if let date = TellMeDateFormat.parse(stringValue) {
        return date
      }

      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
    }
    return decoder
  }()

  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(TellMeDateFormat.fractionalString(from: date))
    }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  public static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    try encoder.encode(value)
  }
}

public enum SHA256Hex {
  public static func string(_ value: String) -> String {
    string(Data(value.utf8))
  }

  public static func string(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
  }
}

public enum TellMeDateFormat {
  public static func fractionalString(from date: Date) -> String {
    fractionalFormatter().string(from: date)
  }

  public static func parse(_ rawValue: String) -> Date? {
    fractionalFormatter().date(from: rawValue) ?? standardFormatter().date(from: rawValue)
  }

  private static func fractionalFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  private static func standardFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}
