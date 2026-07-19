import CryptoKit
import Foundation

// Attachment policy is checked before preview/export so risky file handling is never hidden in UI code.
enum AttachmentSecurity {
  static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func hashCapabilityToken(_ token: String) -> String {
    sha256Hex(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
  }

  static func canonicalizeRiskFlags(_ flags: [String]) -> [String] {
    Array(Set(flags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
  }

  static func buildUploadAttestationPayload(
    mediaId: String,
    userHandle: String,
    deviceId: String,
    capabilityToken: String,
    ciphertextSha256: String,
    ciphertextSize: Int,
    scanResult: AttachmentScanResult
  ) -> String {
    let riskFlags: String = canonicalizeRiskFlags(scanResult.riskFlags).joined(separator: ",")
    return [
      "media-upload-v1",
      mediaId,
      userHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      deviceId.trimmingCharacters(in: .whitespacesAndNewlines),
      hashCapabilityToken(capabilityToken),
      ciphertextSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      String(ciphertextSize),
      scanResult.verdict.rawValue,
      riskFlags,
      String(scanResult.scannerVersion),
      String(scanResult.rulesVersion),
    ].joined(separator: "|")
  }
}
