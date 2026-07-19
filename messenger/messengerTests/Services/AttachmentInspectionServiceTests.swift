import Foundation
import XCTest
@testable import messenger

final class AttachmentInspectionServiceTests: XCTestCase {
  private let service = AttachmentInspectionService()

  func testPrepareForUploadBlocksExecutableAttachments() {
    XCTAssertThrowsError(
      try service.prepareForUpload(
        data: Data([0x01, 0x02]),
        fileName: "payload.exe",
        mimeType: "application/octet-stream"
      )
    ) { error in
      XCTAssertEqual(error as? AttachmentInspectionError, .blocked("Executable attachments are not allowed."))
    }
  }

  func testInspectForOpenWarnsOnPdfActiveContent() throws {
    let data = Data("%PDF-1.7\n1 0 obj << /JavaScript /OpenAction >>".utf8)

    let result = try service.inspectForOpen(
      plaintext: data,
      fileName: "report.pdf",
      mimeType: "application/pdf"
    )

    XCTAssertEqual(result.verdict, .warn)
    XCTAssertEqual(result.riskFlags, ["pdf_active_content"])
  }

  func testPrepareForUploadRejectsEncryptedArchives() {
    XCTAssertThrowsError(
      try service.prepareForUpload(
        data: zipArchive(entries: [
          zipEntry(name: "docs/readme.txt", encrypted: true),
        ]),
        fileName: "archive.zip",
        mimeType: "application/zip"
      )
    ) { error in
      XCTAssertEqual(error as? AttachmentInspectionError, .unscannable("Encrypted archives are not allowed."))
    }
  }

  func testPrepareForUploadBlocksOOXMLMacroPayloads() {
    XCTAssertThrowsError(
      try service.prepareForUpload(
        data: zipArchive(entries: [
          zipEntry(name: "word/vbaProject.bin"),
          zipEntry(name: "[Content_Types].xml"),
        ]),
        fileName: "invoice.docx",
        mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      )
    ) { error in
      XCTAssertEqual(error as? AttachmentInspectionError, .blocked("The Office document contains macro payloads."))
    }
  }

  private func zipArchive(entries: [Data]) -> Data {
    var archive = Data()
    for entry in entries {
      archive.append(entry)
    }
    return archive
  }

  private func zipEntry(name: String, encrypted: Bool = false) -> Data {
    let fileNameData = Data(name.lowercased().utf8)
    var data = Data()

    append(UInt32(0x02014b50), to: &data)
    append(UInt16(20), to: &data)
    append(UInt16(20), to: &data)
    append(UInt16(encrypted ? 0x1 : 0x0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt32(0), to: &data)
    append(UInt32(0), to: &data)
    append(UInt32(0), to: &data)
    append(UInt16(fileNameData.count), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt32(0), to: &data)
    append(UInt32(0), to: &data)
    data.append(fileNameData)

    return data
  }

  private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}
