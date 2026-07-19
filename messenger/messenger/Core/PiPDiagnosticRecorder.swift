import Foundation

// Diagnostics are append-only JSON lines so physical-device runs can be compared after app relaunches.
final class PiPDiagnosticRecorder: @unchecked Sendable {
  static let shared = PiPDiagnosticRecorder()

  private struct Event: Encodable {
    let recordedAt: Date
    let launchId: String
    let processId: Int32
    let category: String
    let name: String
    let callId: String
    let detail: String?
  }

  private let queue = DispatchQueue(label: "com.surraund.messenger.pip-diagnostics")
  private let encoder: JSONEncoder
  private let launchId: String = UUID().uuidString
  private let directoryURL: URL
  private let eventsURL: URL
  private let latestURL: URL

  private init() {
    let baseURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    self.directoryURL = baseURL.appendingPathComponent("PiPDiagnostics", isDirectory: true)
    self.eventsURL = directoryURL.appendingPathComponent("pip-events.jsonl")
    self.latestURL = directoryURL.appendingPathComponent("latest-pip-diagnostics.txt")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    queue.async { [directoryURL, eventsURL, latestURL, launchId] in
      _ = try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

      if !FileManager.default.fileExists(atPath: eventsURL.path) {
        _ = try? Data().write(to: eventsURL, options: .atomic)
      }

      let latest = [
        "recordedAt=\(ISO8601DateFormatter().string(from: Date()))",
        "launchId=\(launchId)",
        "processId=\(ProcessInfo.processInfo.processIdentifier)",
        "category=recorder",
        "name=initialized",
        "callId=none",
        "detail=none",
      ].joined(separator: "\n")
      _ = try? latest.write(to: latestURL, atomically: true, encoding: .utf8)
    }
  }

  func record(category: String, name: String, callId: String, detail: String? = nil) {
    let event = Event(
      recordedAt: Date(),
      launchId: launchId,
      processId: ProcessInfo.processInfo.processIdentifier,
      category: category,
      name: sanitized(name, limit: 120),
      callId: sanitized(callId, limit: 160),
      detail: detail.map { sanitized($0, limit: 2_000) }
    )

    queue.async { [encoder, eventsURL, latestURL, directoryURL] in
      _ = try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

      guard let data = try? encoder.encode(event) else {
        return
      }

      append(data, to: eventsURL)
      append(Data("\n".utf8), to: eventsURL)

      let latest = [
        "recordedAt=\(ISO8601DateFormatter().string(from: event.recordedAt))",
        "launchId=\(event.launchId)",
        "processId=\(event.processId)",
        "category=\(event.category)",
        "name=\(event.name)",
        "callId=\(event.callId)",
        "detail=\(event.detail ?? "none")",
      ].joined(separator: "\n")
      _ = try? latest.write(to: latestURL, atomically: true, encoding: .utf8)
    }
  }

  private func sanitized(_ value: String, limit: Int) -> String {
    let normalized = value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard normalized.count > limit else {
      return normalized
    }

    return String(normalized.prefix(limit))
  }
}

private func append(_ data: Data, to url: URL) {
  if FileManager.default.fileExists(atPath: url.path) {
    guard let handle = try? FileHandle(forWritingTo: url) else {
      return
    }
    defer {
    _ = try? handle.close()
  }
    _ = try? handle.seekToEnd()
    _ = try? handle.write(contentsOf: data)
  } else {
    _ = try? data.write(to: url, options: .atomic)
  }
}
