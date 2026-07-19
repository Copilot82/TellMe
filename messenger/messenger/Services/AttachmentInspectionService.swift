import Foundation

struct PreparedAttachmentUpload: Equatable, Sendable {
  let stagedFileURL: URL
  let fileName: String
  let mimeType: String
  let data: Data
  let scanResult: AttachmentScanResult
}

struct PreparedAttachmentPreview: Equatable, Sendable {
  let fileURL: URL
  let fileName: String
  let mimeType: String
  let scanResult: AttachmentScanResult
}

protocol AttachmentInspectionServiceProtocol {
  func prepareForUpload(data: Data, fileName: String, mimeType: String) throws -> PreparedAttachmentUpload
  func inspectForOpen(plaintext: Data, fileName: String, mimeType: String) throws -> AttachmentScanResult
  func stagePreviewFile(data: Data, fileName: String) throws -> URL
}

// Inspection decisions are conservative because encrypted attachments may not have trustworthy filename metadata.
final class AttachmentInspectionService: AttachmentInspectionServiceProtocol {
  private enum Constants {
    static let scannerVersion: Int = 1
    static let rulesVersion: Int = 1
  }

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func prepareForUpload(data: Data, fileName: String, mimeType: String) throws -> PreparedAttachmentUpload {
    let stagedFileURL: URL = try stageFile(data: data, fileName: fileName, directoryName: "staging")
    let result: AttachmentScanResult = try inspect(data: data, fileName: fileName, mimeType: mimeType)

    switch result.verdict {
    case .clean, .warn:
      return PreparedAttachmentUpload(
        stagedFileURL: stagedFileURL,
        fileName: sanitizedFileName(fileName),
        mimeType: mimeType,
        data: data,
        scanResult: result
      )
    case .blocked:
      throw AttachmentInspectionError.blocked(result.summary)
    case .unscannable:
      throw AttachmentInspectionError.unscannable(result.summary)
    }
  }

  func inspectForOpen(plaintext: Data, fileName: String, mimeType: String) throws -> AttachmentScanResult {
    try inspect(data: plaintext, fileName: fileName, mimeType: mimeType)
  }

  func stagePreviewFile(data: Data, fileName: String) throws -> URL {
    try stageFile(data: data, fileName: fileName, directoryName: "preview")
  }

  private func inspect(data: Data, fileName: String, mimeType: String) throws -> AttachmentScanResult {
    let normalizedFileName = sanitizedFileName(fileName)
    let lowercasedName = normalizedFileName.lowercased()
    let fileExtension = URL(fileURLWithPath: lowercasedName).pathExtension
    var riskFlags: [String] = []

    if data.isEmpty {
      return AttachmentScanResult(
        verdict: .unscannable,
        riskFlags: ["empty_attachment"],
        scannerVersion: Constants.scannerVersion,
        rulesVersion: Constants.rulesVersion,
        summary: "The attachment is empty and cannot be securely scanned."
      )
    }

    if isBlockedExecutableExtension(fileExtension) {
      return blockedResult(flags: ["blocked_executable"], summary: "Executable attachments are not allowed.")
    }

    if isBlockedWebActiveContent(fileExtension, mimeType: mimeType) {
      return blockedResult(flags: ["blocked_active_web_content"], summary: "HTML, SVG, and scriptable web content are blocked.")
    }

    if isLegacyOrOpaqueArchive(fileExtension) {
      return unscannableResult(flags: ["unsupported_archive"], summary: "This archive format cannot be securely scanned.")
    }

    if isBlockedScriptExtension(fileExtension) {
      return blockedResult(flags: ["blocked_script_extension"], summary: "Script attachments are not allowed.")
    }

    if isImageLike(mimeType: mimeType) || isVideoLike(mimeType: mimeType) || isAudioLike(mimeType: mimeType) {
      return cleanResult(flags: [])
    }

    if mimeType == "text/plain" || fileExtension == "txt" {
      let text = String(decoding: data.prefix(16_384), as: UTF8.self).lowercased()
      if containsSuspiciousPlaintext(text) {
        riskFlags.append("suspicious_plaintext_commands")
      }

      if riskFlags.isEmpty {
        return cleanResult(flags: [])
      }

      return warnResult(flags: riskFlags, summary: "The attachment contains suspicious command or script markers.")
    }

    if mimeType == "application/pdf" || fileExtension == "pdf" {
      let text = String(decoding: data.prefix(512_000), as: UTF8.self)
      if text.range(of: "/launch", options: .caseInsensitive) != nil
        || text.range(of: "/embeddedfile", options: .caseInsensitive) != nil
      {
        return blockedResult(flags: ["pdf_embedded_payload"], summary: "The PDF contains embedded launch or file payloads.")
      }

      if text.range(of: "/javascript", options: .caseInsensitive) != nil
        || text.range(of: "/js", options: .caseInsensitive) != nil
        || text.range(of: "/openaction", options: .caseInsensitive) != nil
        || text.range(of: "/submitform", options: .caseInsensitive) != nil
        || text.range(of: "/richmedia", options: .caseInsensitive) != nil
      {
        return warnResult(flags: ["pdf_active_content"], summary: "The PDF contains active content markers.")
      }

      return cleanResult(flags: [])
    }

    if isZipContainer(mimeType: mimeType, fileExtension: fileExtension) {
      let zipEntries: [ZipEntry]
      do {
        zipEntries = try parseZipEntries(data: data)
      } catch {
        return unscannableResult(flags: ["zip_parse_failed"], summary: "The archive could not be securely scanned.")
      }

      if zipEntries.isEmpty {
        return unscannableResult(flags: ["empty_archive"], summary: "The archive does not contain any readable entries.")
      }

      if zipEntries.contains(where: { $0.isEncrypted }) {
        return unscannableResult(flags: ["encrypted_archive"], summary: "Encrypted archives are not allowed.")
      }

      let entryNames: [String] = zipEntries.map(\.normalizedName)
      if isOOXMLDocument(fileExtension: fileExtension, mimeType: mimeType) {
        if entryNames.contains(where: { $0.hasSuffix("vbaproject.bin") || $0.contains("/macros/") }) {
          return blockedResult(flags: ["ooxml_macro_payload"], summary: "The Office document contains macro payloads.")
        }

        if entryNames.contains(where: { $0.contains("/embeddings/") || $0.contains("oleobject") }) {
          return warnResult(flags: ["ooxml_embedded_object"], summary: "The Office document contains embedded objects.")
        }
      }

      if entryNames.contains(where: isBlockedArchiveEntryName(_:)) {
        return blockedResult(flags: ["archive_contains_blocked_payload"], summary: "The archive contains blocked executable or script payloads.")
      }

      if entryNames.contains(where: isNestedContainerEntryName(_:)) {
        return warnResult(flags: ["nested_container"], summary: "The archive contains nested containers and requires caution.")
      }

      return cleanResult(flags: [])
    }

    return unscannableResult(flags: ["unsupported_attachment_type"], summary: "This attachment type cannot be securely scanned.")
  }

  private func stageFile(data: Data, fileName: String, directoryName: String) throws -> URL {
    let root: URL = try secureAttachmentsRoot()
    let directory: URL = root.appendingPathComponent(directoryName, isDirectory: true)
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let uniqueName = "\(UUID().uuidString)-\(sanitizedFileName(fileName))"
    let targetURL = directory.appendingPathComponent(uniqueName)
    try data.write(to: targetURL, options: [.atomic])
    return targetURL
  }

  private func secureAttachmentsRoot() throws -> URL {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let root = base.appendingPathComponent("secure-attachments", isDirectory: true)
    if !fileManager.fileExists(atPath: root.path) {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
    return root
  }

  private func sanitizedFileName(_ fileName: String) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.isEmpty ? "attachment.bin" : trimmed
    return candidate.replacingOccurrences(of: "/", with: "-")
  }

  private func cleanResult(flags: [String]) -> AttachmentScanResult {
    AttachmentScanResult(
      verdict: .clean,
      riskFlags: flags,
      scannerVersion: Constants.scannerVersion,
      rulesVersion: Constants.rulesVersion,
      summary: "Attachment scan completed without risk indicators."
    )
  }

  private func warnResult(flags: [String], summary: String) -> AttachmentScanResult {
    AttachmentScanResult(
      verdict: .warn,
      riskFlags: flags.sorted(),
      scannerVersion: Constants.scannerVersion,
      rulesVersion: Constants.rulesVersion,
      summary: summary
    )
  }

  private func blockedResult(flags: [String], summary: String) -> AttachmentScanResult {
    AttachmentScanResult(
      verdict: .blocked,
      riskFlags: flags.sorted(),
      scannerVersion: Constants.scannerVersion,
      rulesVersion: Constants.rulesVersion,
      summary: summary
    )
  }

  private func unscannableResult(flags: [String], summary: String) -> AttachmentScanResult {
    AttachmentScanResult(
      verdict: .unscannable,
      riskFlags: flags.sorted(),
      scannerVersion: Constants.scannerVersion,
      rulesVersion: Constants.rulesVersion,
      summary: summary
    )
  }
}

private struct ZipEntry: Equatable {
  let normalizedName: String
  let isEncrypted: Bool
}

private extension AttachmentInspectionService {
  func isBlockedExecutableExtension(_ fileExtension: String) -> Bool {
    let blocked: Set<String> = [
      "app", "apk", "bat", "bin", "cmd", "com", "cpl", "dmg", "exe", "gadget", "hta",
      "ipa", "jar", "msi", "pkg", "ps1", "scr", "vbs", "workflow"
    ]
    return blocked.contains(fileExtension)
  }

  func isBlockedScriptExtension(_ fileExtension: String) -> Bool {
    let blocked: Set<String> = ["command", "js", "jse", "php", "py", "rb", "sh", "svgz"]
    return blocked.contains(fileExtension)
  }

  func isBlockedWebActiveContent(_ fileExtension: String, mimeType: String) -> Bool {
    let blockedExtensions: Set<String> = ["htm", "html", "mhtml", "shtml", "svg", "xhtml", "xml"]
    if blockedExtensions.contains(fileExtension) {
      return true
    }

    return mimeType == "image/svg+xml" || mimeType == "text/html" || mimeType == "application/xhtml+xml"
  }

  func isLegacyOrOpaqueArchive(_ fileExtension: String) -> Bool {
    let blocked: Set<String> = ["7z", "bz2", "cab", "doc", "docm", "ppt", "pptm", "rar", "tar", "xls", "xlsm"]
    return blocked.contains(fileExtension)
  }

  func isImageLike(mimeType: String) -> Bool {
    mimeType.hasPrefix("image/")
  }

  func isVideoLike(mimeType: String) -> Bool {
    mimeType.hasPrefix("video/")
  }

  func isAudioLike(mimeType: String) -> Bool {
    mimeType.hasPrefix("audio/")
  }

  func isZipContainer(mimeType: String, fileExtension: String) -> Bool {
    if fileExtension == "zip" || ["docx", "pptx", "xlsx"].contains(fileExtension) {
      return true
    }

    return mimeType == "application/zip"
      || mimeType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      || mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      || mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  }

  func isOOXMLDocument(fileExtension: String, mimeType: String) -> Bool {
    ["docx", "pptx", "xlsx"].contains(fileExtension)
      || mimeType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      || mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      || mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  }

  func containsSuspiciousPlaintext(_ text: String) -> Bool {
    let needles: [String] = [
      "#!/bin/", "#!/usr/bin/", "<script", "javascript:", "powershell", "osascript", "curl http", "wget http"
    ]
    return needles.contains(where: { text.contains($0) })
  }

  func isBlockedArchiveEntryName(_ fileName: String) -> Bool {
    let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    return isBlockedExecutableExtension(pathExtension) || isBlockedScriptExtension(pathExtension)
  }

  func isNestedContainerEntryName(_ fileName: String) -> Bool {
    let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    return ["7z", "docx", "pptx", "rar", "tar", "xlsx", "zip"].contains(pathExtension)
  }

  func parseZipEntries(data: Data) throws -> [ZipEntry] {
    var entries: [ZipEntry] = []
    var offset: Int = 0

    while offset + 46 <= data.count {
      if readUInt32LE(data: data, offset: offset) != 0x02014b50 {
        offset += 1
        continue
      }

      let generalPurposeBitFlag = Int(readUInt16LE(data: data, offset: offset + 8))
      let fileNameLength = Int(readUInt16LE(data: data, offset: offset + 28))
      let extraFieldLength = Int(readUInt16LE(data: data, offset: offset + 30))
      let fileCommentLength = Int(readUInt16LE(data: data, offset: offset + 32))
      let recordEnd = offset + 46 + fileNameLength + extraFieldLength + fileCommentLength

      guard recordEnd <= data.count else {
        break
      }

      let fileNameData = data.subdata(in: (offset + 46)..<(offset + 46 + fileNameLength))
      let fileName = String(decoding: fileNameData, as: UTF8.self).lowercased()
      entries.append(
        ZipEntry(
          normalizedName: fileName,
          isEncrypted: (generalPurposeBitFlag & 0x1) != 0
        )
      )

      offset = recordEnd
    }

    return entries
  }

  func readUInt16LE(data: Data, offset: Int) -> UInt16 {
    let lower = UInt16(data[offset])
    let upper = UInt16(data[offset + 1]) << 8
    return lower | upper
  }

  func readUInt32LE(data: Data, offset: Int) -> UInt32 {
    let a = UInt32(data[offset])
    let b = UInt32(data[offset + 1]) << 8
    let c = UInt32(data[offset + 2]) << 16
    let d = UInt32(data[offset + 3]) << 24
    return a | b | c | d
  }
}
