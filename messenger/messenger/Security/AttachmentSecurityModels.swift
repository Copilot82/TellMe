import Foundation

enum AttachmentScanVerdict: String, Codable, Equatable, Sendable {
  case clean
  case warn
  case blocked
  case unscannable
}

struct AttachmentScanResult: Codable, Equatable, Sendable {
  let verdict: AttachmentScanVerdict
  let riskFlags: [String]
  let scannerVersion: Int
  let rulesVersion: Int
  let summary: String
}

struct MediaUploadAttestationPayload: Codable, Equatable, Sendable {
  let capabilityToken: String
  let ciphertextSha256: String
  let scanVerdict: AttachmentScanVerdict
  let riskFlags: [String]
  let scannerVersion: Int
  let rulesVersion: Int
  let attestationSignature: String
}

enum AttachmentInspectionError: LocalizedError, Equatable, Sendable {
  case unsupportedFileType
  case unscannable(String)
  case blocked(String)
  case warningRequiresAcknowledgement(AttachmentScanResult)
  case previewWarningRequiresAcknowledgement(AttachmentScanResult)
  case exportWarningRequiresAcknowledgement(AttachmentScanResult)
  case invalidAttachmentMetadata
  case ciphertextIntegrityFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedFileType:
      return "This attachment type is not allowed."
    case .unscannable(let detail):
      return detail
    case .blocked(let detail):
      return detail
    case .warningRequiresAcknowledgement(let result):
      return result.summary
    case .previewWarningRequiresAcknowledgement(let result):
      return result.summary
    case .exportWarningRequiresAcknowledgement(let result):
      return result.summary
    case .invalidAttachmentMetadata:
      return "Attachment metadata is invalid."
    case .ciphertextIntegrityFailed:
      return "Ciphertext integrity verification failed."
    }
  }
}
