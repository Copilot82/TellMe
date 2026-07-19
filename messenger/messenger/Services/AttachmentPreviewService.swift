import CryptoKit
import Foundation
import OSLog

// Preview files are materialized outside the message store so decrypted bytes have a short UI lifetime.
struct AttachmentPreviewRequest: Equatable, Sendable {
  let mediaId: String
  let originServer: String
  let downloadCapability: String
  let fileKey: String
  let expectedCiphertextHash: String
  let fileName: String
  let mimeType: String
}

protocol AttachmentPreviewServiceProtocol: AnyObject {
  func resolvePreview(for request: AttachmentPreviewRequest) async throws -> PreparedAttachmentPreview
}

actor AttachmentPreviewService: AttachmentPreviewServiceProtocol {
  private let messageService: MessageServiceProtocol
  private let cryptoService: CryptoService
  private let attachmentInspectionService: AttachmentInspectionServiceProtocol
  private let logger: Logger

  init(
    messageService: MessageServiceProtocol,
    cryptoService: CryptoService = CryptoService(),
    attachmentInspectionService: AttachmentInspectionServiceProtocol = AttachmentInspectionService()
  ) {
    self.messageService = messageService
    self.cryptoService = cryptoService
    self.attachmentInspectionService = attachmentInspectionService
    self.logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "com.example.messenger",
      category: "AttachmentPreview"
    )
  }

  func resolvePreview(for request: AttachmentPreviewRequest) async throws -> PreparedAttachmentPreview {
    let downloadStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    let ciphertextData: Data = try await messageService.downloadCiphertext(
      mediaId: request.mediaId,
      originServer: request.originServer,
      downloadCapability: request.downloadCapability
    )
    let downloadElapsedMs: Int = elapsedMilliseconds(since: downloadStart)

    let processingStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    let ciphertextHash: String = AttachmentSecurity.sha256Hex(ciphertextData)
    guard ciphertextHash == request.expectedCiphertextHash.lowercased() else {
      throw AttachmentInspectionError.ciphertextIntegrityFailed
    }

    guard let keyData: Data = Data(base64Encoded: request.fileKey) else {
      throw AttachmentInspectionError.invalidAttachmentMetadata
    }

    let encryptedEnvelope: AEADCiphertextEnvelope = try JSONCoding.decoder.decode(
      AEADCiphertextEnvelope.self,
      from: ciphertextData
    )
    let plaintext: Data = try cryptoService.decryptAEAD(
      envelope: encryptedEnvelope,
      key: SymmetricKey(data: keyData)
    )

    let scanResult: AttachmentScanResult = try attachmentInspectionService.inspectForOpen(
      plaintext: plaintext,
      fileName: request.fileName,
      mimeType: request.mimeType
    )
    switch scanResult.verdict {
    case .blocked:
      throw AttachmentInspectionError.blocked(scanResult.summary)
    case .unscannable:
      throw AttachmentInspectionError.unscannable(scanResult.summary)
    case .clean, .warn:
      let previewURL: URL = try attachmentInspectionService.stagePreviewFile(
        data: plaintext,
        fileName: request.fileName
      )
      let processingElapsedMs: Int = elapsedMilliseconds(since: processingStart)
      logPreviewTimings(
        mediaId: request.mediaId,
        downloadElapsedMs: downloadElapsedMs,
        processingElapsedMs: processingElapsedMs
      )
      return PreparedAttachmentPreview(
        fileURL: previewURL,
        fileName: request.fileName,
        mimeType: request.mimeType,
        scanResult: scanResult
      )
    }
  }

  private func elapsedMilliseconds(since start: TimeInterval) -> Int {
    Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
  }

  private func logPreviewTimings(mediaId: String, downloadElapsedMs: Int, processingElapsedMs: Int) {
    #if DEBUG
    logger.debug(
      "attachment_preview media_id=\(mediaId, privacy: .public) download_ms=\(downloadElapsedMs) decrypt_scan_stage_ms=\(processingElapsedMs)"
    )
    #endif
  }
}
