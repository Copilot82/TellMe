import CryptoKit
import Foundation
@testable import TellMeHeadlessE2ECore
import XCTest

final class TellMeHeadlessE2ECoreTests: XCTestCase {
  func testSeedCodecMatchesIOSBase64SeedPhraseContract() throws {
    let seed = Data((0..<32).map { UInt8($0) })
    let phrase = SeedCodec.encodeSeedPhrase(seed)

    XCTAssertEqual(try SeedCodec.decodeSeedPhrase(phrase), seed)
    XCTAssertThrowsError(try SeedCodec.decodeSeedPhrase("not-a-seed"))
  }

  func testFixtureSignsRegistrationDeviceCertificateAndPrekey() throws {
    let seed = SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))
    let issuedAt = try XCTUnwrap(TellMeDateFormat.parse("2026-05-29T12:00:00.000Z"))
    let fixture = try HeadlessContractFixtureBuilder.make(
      userHandle: " @Alice:Surraund.com ",
      seedPhrase: seed,
      deviceId: "dev_headless_contract",
      oneTimePrekeysCount: 2,
      issuedAt: issuedAt,
      timestamp: issuedAt,
      generatedAt: issuedAt
    )

    XCTAssertEqual(fixture.userHandle, "@alice:surraund.com")
    XCTAssertEqual(fixture.deviceId, "dev_headless_contract")
    XCTAssertEqual(fixture.registerRequest.initialDevice.deviceCertificateChain.count, 1)
    XCTAssertEqual(fixture.prekeysPublishRequest.protocolVersion, 2)
    XCTAssertEqual(fixture.prekeysPublishRequest.oneTimePrekeys.count, 2)

    let registerProof = [
      "register",
      fixture.userHandle,
      fixture.registerRequest.ikSignPub,
      fixture.registerRequest.ikDhPub,
      fixture.registerRequest.timestamp,
    ].joined(separator: "|")
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(registerProof.utf8),
        signatureBase64: fixture.registerRequest.signature,
        publicKeyBase64: fixture.registerRequest.ikSignPub
      )
    )

    let certificate = fixture.registerRequest.initialDevice.deviceCertificateChain[0]
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(DeviceCertificateCodec.signingPayload(for: certificate).utf8),
        signatureBase64: certificate.signature,
        publicKeyBase64: fixture.registerRequest.ikSignPub
      )
    )

    let signedPrekey = fixture.prekeysPublishRequest.signedPrekey
    let signedPrekeyPayload = "signed_prekey|\(signedPrekey.prekeyId)|\(signedPrekey.signedPrekeyPub)"
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(signedPrekeyPayload.utf8),
        signatureBase64: signedPrekey.signature,
        publicKeyBase64: fixture.registerRequest.initialDevice.dkSignPub
      )
    )
  }

  func testFixtureSerializationDoesNotContainPrivateMaterial() throws {
    let fixture = try HeadlessContractFixtureBuilder.make(
      userHandle: "@privacy:surraund.com",
      seedPhrase: SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) })),
      deviceId: "dev_privacy_contract",
      oneTimePrekeysCount: 1,
      issuedAt: Date(timeIntervalSince1970: 1_779_999_999),
      timestamp: Date(timeIntervalSince1970: 1_779_999_999),
      generatedAt: Date(timeIntervalSince1970: 1_779_999_999)
    )
    let json = String(data: try JSONCoding.encoder.encode(fixture), encoding: .utf8) ?? ""

    XCTAssertFalse(json.localizedCaseInsensitiveContains("seed_phrase"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("dk_sign_private"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("dk_dh_private"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("account_sign_private"))
    XCTAssertFalse(json.contains(SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))))
  }

  func testAuthFinishProofSignsChallengeWithDeviceKeyAndHidesNonce() throws {
    let seed = SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))
    let issuedAt = try XCTUnwrap(TellMeDateFormat.parse("2026-05-29T12:00:00.000Z"))
    let proof = try HeadlessAuthFinishProofBuilder.make(
      userHandle: " @Login:Surraund.com ",
      seedPhrase: seed,
      deviceId: "dev_login_contract",
      challengeId: "11111111-1111-4111-8111-111111111111",
      nonce: "server-challenge-nonce",
      issuedAt: issuedAt,
      generatedAt: issuedAt
    )
    let fixture = try HeadlessContractFixtureBuilder.make(
      userHandle: "@login:surraund.com",
      seedPhrase: seed,
      deviceId: "dev_login_contract",
      oneTimePrekeysCount: 1,
      issuedAt: issuedAt,
      timestamp: issuedAt,
      generatedAt: issuedAt
    )

    XCTAssertEqual(proof.userHandle, "@login:surraund.com")
    XCTAssertEqual(proof.deviceId, "dev_login_contract")
    XCTAssertEqual(proof.authFinishRequest.challengeId, "11111111-1111-4111-8111-111111111111")
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data("server-challenge-nonce".utf8),
        signatureBase64: proof.authFinishRequest.signature,
        publicKeyBase64: fixture.registerRequest.initialDevice.dkSignPub
      )
    )

    let json = String(data: try JSONCoding.encoder.encode(proof), encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("server-challenge-nonce"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("seed_phrase"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("dk_sign_private"))
  }

  func testDeviceRevokeProofSignsTargetWithCurrentDeviceKeyAndHidesPrivateMaterial() throws {
    let seed = SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))
    let issuedAt = try XCTUnwrap(TellMeDateFormat.parse("2026-05-29T12:00:00.000Z"))
    let proof = try HeadlessDeviceRevokeProofBuilder.make(
      userHandle: " @Devices:Surraund.com ",
      seedPhrase: seed,
      signingDeviceId: "dev_primary_contract",
      targetDeviceId: "dev_secondary_contract",
      timestamp: issuedAt,
      generatedAt: issuedAt
    )
    let fixture = try HeadlessContractFixtureBuilder.make(
      userHandle: "@devices:surraund.com",
      seedPhrase: seed,
      deviceId: "dev_primary_contract",
      oneTimePrekeysCount: 1,
      issuedAt: issuedAt,
      timestamp: issuedAt,
      generatedAt: issuedAt
    )
    let expectedPayload = "revoke|dev_secondary_contract|2026-05-29T12:00:00.000Z"

    XCTAssertEqual(proof.userHandle, "@devices:surraund.com")
    XCTAssertEqual(proof.signingDeviceId, "dev_primary_contract")
    XCTAssertEqual(proof.targetDeviceId, "dev_secondary_contract")
    XCTAssertEqual(proof.revokePayloadSha256, SHA256Hex.string(expectedPayload))
    XCTAssertEqual(proof.deviceRevokeRequest.deviceId, "dev_secondary_contract")
    XCTAssertEqual(proof.deviceRevokeRequest.timestamp, "2026-05-29T12:00:00.000Z")
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(expectedPayload.utf8),
        signatureBase64: proof.deviceRevokeRequest.signature,
        publicKeyBase64: fixture.registerRequest.initialDevice.dkSignPub
      )
    )

    let json = String(data: try JSONCoding.encoder.encode(proof), encoding: .utf8) ?? ""
    XCTAssertFalse(json.localizedCaseInsensitiveContains("seed_phrase"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("dk_sign_private"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("account_sign_private"))
  }

  func testDeviceLinkApprovalSignsLinkedDeviceCertificateWithHostDeviceKey() throws {
    let seed = SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))
    let issuedAt = try XCTUnwrap(TellMeDateFormat.parse("2026-05-29T12:00:00.000Z"))
    let proof = try HeadlessDeviceLinkApprovalProofBuilder.make(
      userHandle: " @Link:Surraund.com ",
      seedPhrase: seed,
      hostDeviceId: "dev_host_contract",
      linkedDeviceId: "dev_linked_contract",
      oneTimePrekeysCount: 2,
      issuedAt: issuedAt,
      generatedAt: issuedAt
    )
    let hostFixture = try HeadlessContractFixtureBuilder.make(
      userHandle: "@link:surraund.com",
      seedPhrase: seed,
      deviceId: "dev_host_contract",
      oneTimePrekeysCount: 1,
      issuedAt: issuedAt,
      timestamp: issuedAt,
      generatedAt: issuedAt
    )
    let certificate = proof.approvedDeviceCertificate
    let expectedPayload = DeviceCertificateCodec.signingPayload(for: certificate)

    XCTAssertEqual(proof.userHandle, "@link:surraund.com")
    XCTAssertEqual(proof.hostDeviceId, "dev_host_contract")
    XCTAssertEqual(proof.linkedDeviceId, "dev_linked_contract")
    XCTAssertEqual(certificate.issuerKind, "device")
    XCTAssertEqual(certificate.issuerDeviceId, "dev_host_contract")
    XCTAssertEqual(certificate.parentCertificateId, proof.hostCertificateId)
    XCTAssertEqual(certificate.deviceId, "dev_linked_contract")
    XCTAssertEqual(proof.devicePubKeys.deviceId, "dev_linked_contract")
    XCTAssertEqual(proof.prekeysPublishRequest.deviceId, "dev_linked_contract")
    XCTAssertEqual(proof.prekeysPublishRequest.oneTimePrekeys.count, 2)
    XCTAssertEqual(proof.approvalCertificatePayloadSha256, SHA256Hex.string(expectedPayload))
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(expectedPayload.utf8),
        signatureBase64: certificate.signature,
        publicKeyBase64: hostFixture.registerRequest.initialDevice.dkSignPub
      )
    )

    let json = String(data: try JSONCoding.encoder.encode(proof), encoding: .utf8) ?? ""
    XCTAssertFalse(json.localizedCaseInsensitiveContains("seed_phrase"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("dk_sign_private"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("provisioning_plaintext_sentinel"))
  }

  func testMediaUploadAttestationSignsCanonicalPayloadWithoutFileSecrets() throws {
    let seed = SeedCodec.encodeSeedPhrase(Data((0..<32).map { UInt8($0) }))
    let issuedAt = try XCTUnwrap(TellMeDateFormat.parse("2026-05-29T12:00:00.000Z"))
    let proof = try HeadlessMediaUploadAttestationProofBuilder.make(
      userHandle: " @Media:Surraund.com ",
      seedPhrase: seed,
      deviceId: "dev_media_contract",
      mediaId: "media-1",
      capabilityToken: "capability-token-1234567890abcdef",
      ciphertextSha256: "1423D4E5BC2D4BC05052A8730017FE1430EACEA29D957DFB3BDA299FA1587064",
      ciphertextSize: 15,
      scanVerdict: "WARN",
      riskFlags: [" pdf_active_content ", "OOXML_MACRO_PAYLOAD", "pdf_active_content"],
      scannerVersion: 1,
      rulesVersion: 2,
      issuedAt: issuedAt,
      generatedAt: issuedAt
    )
    let fixture = try HeadlessContractFixtureBuilder.make(
      userHandle: "@media:surraund.com",
      seedPhrase: seed,
      deviceId: "dev_media_contract",
      oneTimePrekeysCount: 1,
      issuedAt: issuedAt,
      timestamp: issuedAt,
      generatedAt: issuedAt
    )
    let expectedPayload = [
      "media-upload-v1",
      "media-1",
      "@media:surraund.com",
      "dev_media_contract",
      MediaUploadAttestationCodec.hashCapabilityToken("capability-token-1234567890abcdef"),
      "1423d4e5bc2d4bc05052a8730017fe1430eacea29d957dfb3bda299fa1587064",
      "15",
      "warn",
      "ooxml_macro_payload,pdf_active_content",
      "1",
      "2",
    ].joined(separator: "|")

    XCTAssertEqual(proof.userHandle, "@media:surraund.com")
    XCTAssertEqual(proof.attestation.riskFlags, ["ooxml_macro_payload", "pdf_active_content"])
    XCTAssertEqual(proof.attestationPayloadSha256, SHA256Hex.string(expectedPayload))
    XCTAssertEqual(proof.uploadHeaders["x-media-scan-verdict"], "warn")
    XCTAssertTrue(
      IdentityCrypto.verifyEd25519(
        message: Data(expectedPayload.utf8),
        signatureBase64: proof.attestation.attestationSignature,
        publicKeyBase64: fixture.registerRequest.ikSignPub
      )
    )

    let json = String(data: try JSONCoding.encoder.encode(proof), encoding: .utf8) ?? ""
    XCTAssertFalse(proof.securityInvariants.fileKeySerialized)
    XCTAssertFalse(json.localizedCaseInsensitiveContains("raw_file_key_sentinel"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("live_plaintext_sentinel"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("ik_sign_private"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("seed_phrase"))
  }
}
