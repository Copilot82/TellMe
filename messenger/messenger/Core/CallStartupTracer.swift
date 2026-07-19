import Foundation
import os

// Startup tracing uses sparse events so diagnostics do not capture call payloads or media data.
enum CallStartupTracer {
  private static let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.example.messenger",
    category: "CallStartup"
  )

  static func event(_ name: StaticString, callId: String) {
    os_signpost(.event, log: log, name: name, "%{public}@", callId)
    os_log("%{public}@ callId=%{public}@", log: log, type: .info, String(describing: name), callId)
    PiPDiagnosticRecorder.shared.record(
      category: "call_startup",
      name: String(describing: name),
      callId: callId
    )
  }

  static func event(_ name: StaticString, callId: String, detail: String) {
    os_signpost(.event, log: log, name: name, "%{public}@ %{public}@", callId, detail)
    os_log(
      "%{public}@ callId=%{public}@ detail=%{public}@",
      log: log,
      type: .info,
      String(describing: name),
      callId,
      detail
    )
    PiPDiagnosticRecorder.shared.record(
      category: "call_startup",
      name: String(describing: name),
      callId: callId,
      detail: detail
    )
  }
}
