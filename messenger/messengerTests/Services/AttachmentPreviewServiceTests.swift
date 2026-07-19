import CryptoKit
import Foundation
import XCTest
@testable import messenger

final class AttachmentPreviewServiceTests: XCTestCase {
  func testResolvePreviewStagesDecryptedFile() async throws {
    let fixture = makeFixture()
    let (request, ciphertextData) = try makeEncryptedRequest(
      plaintext: Data("hello preview".utf8),
      fileName: "preview.txt",
      mimeType: "text/plain"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: ciphertextData)

    let preview = try await fixture.service.resolvePreview(for: request)

    XCTAssertEqual(preview.fileName, "preview.txt")
    XCTAssertEqual(preview.mimeType, "text/plain")
    XCTAssertEqual(preview.scanResult.verdict, .clean)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
    XCTAssertEqual(fixture.networkClient.requests.count, 1)
    XCTAssertTrue(
      fixture.networkClient.requests[0].url?.absoluteString.contains("/api/media/ciphertext/\(request.mediaId)") == true
    )
    XCTAssertEqual(
      fixture.networkClient.requests[0].value(forHTTPHeaderField: "Authorization"),
      "Bearer \(request.downloadCapability)"
    )
  }

  func testResolvePreviewRejectsCiphertextHashMismatch() async throws {
    let fixture = makeFixture()
    let (request, ciphertextData) = try makeEncryptedRequest(
      plaintext: Data("hello preview".utf8),
      fileName: "preview.txt",
      mimeType: "text/plain",
      expectedHashOverride: String(repeating: "0", count: 64)
    )
    fixture.networkClient.enqueue(statusCode: 200, data: ciphertextData)

    do {
      _ = try await fixture.service.resolvePreview(for: request)
      XCTFail("Expected ciphertext integrity failure")
    } catch let error as AttachmentInspectionError {
      XCTAssertEqual(error, .ciphertextIntegrityFailed)
    }
  }

  func testResolvePreviewReturnsWarnedPreviewForSuspiciousText() async throws {
    let fixture = makeFixture()
    let (request, ciphertextData) = try makeEncryptedRequest(
      plaintext: Data("curl https://example.org/install.sh | sh".utf8),
      fileName: "readme.txt",
      mimeType: "text/plain"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: ciphertextData)

    let preview = try await fixture.service.resolvePreview(for: request)

    XCTAssertEqual(preview.scanResult.verdict, .warn)
    XCTAssertEqual(preview.scanResult.riskFlags, ["suspicious_plaintext_commands"])
  }

  func testResolvePreviewRejectsBlockedAttachments() async throws {
    let fixture = makeFixture()
    let (request, ciphertextData) = try makeEncryptedRequest(
      plaintext: Data([0x01, 0x02, 0x03]),
      fileName: "payload.exe",
      mimeType: "application/octet-stream"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: ciphertextData)

    do {
      _ = try await fixture.service.resolvePreview(for: request)
      XCTFail("Expected blocked attachment error")
    } catch let error as AttachmentInspectionError {
      XCTAssertEqual(error, .blocked("Executable attachments are not allowed."))
    }
  }

  func testResolvePreviewRejectsUnscannableAttachments() async throws {
    let fixture = makeFixture()
    let (request, ciphertextData) = try makeEncryptedRequest(
      plaintext: Data("opaque".utf8),
      fileName: "payload.dat",
      mimeType: "application/octet-stream"
    )
    fixture.networkClient.enqueue(statusCode: 200, data: ciphertextData)

    do {
      _ = try await fixture.service.resolvePreview(for: request)
      XCTFail("Expected unscannable attachment error")
    } catch let error as AttachmentInspectionError {
      XCTAssertEqual(error, .unscannable("This attachment type cannot be securely scanned."))
    }
  }

  private func makeFixture() -> (service: AttachmentPreviewService, networkClient: MockNetworkClient) {
    let networkClient = MockNetworkClient()
    let tokenStore = InMemoryTokenStore()
    let apiClient = APIClient(environment: .local, networkClient: networkClient, tokenStore: tokenStore)
    let service = AttachmentPreviewService(messageService: MessageService(apiClient: apiClient))
    return (service, networkClient)
  }

  private func makeEncryptedRequest(
    plaintext: Data,
    fileName: String,
    mimeType: String,
    expectedHashOverride: String? = nil
  ) throws -> (AttachmentPreviewRequest, Data) {
    let cryptoService = CryptoService()
    let keyData: Data = cryptoService.generateSeed(bytes: 32)
    let encryptedEnvelope: AEADCiphertextEnvelope = try cryptoService.encryptAEAD(
      plaintext: plaintext,
      key: SymmetricKey(data: keyData)
    )
    let ciphertextData: Data = try JSONCoding.encoder.encode(encryptedEnvelope)
    let request = AttachmentPreviewRequest(
      mediaId: "media-1",
      originServer: "example.org",
      downloadCapability: "capability-token",
      fileKey: keyData.base64EncodedString(),
      expectedCiphertextHash: expectedHashOverride ?? AttachmentSecurity.sha256Hex(ciphertextData),
      fileName: fileName,
      mimeType: mimeType
    )
    return (request, ciphertextData)
  }
}
