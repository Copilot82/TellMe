import UserNotifications

// The extension avoids decrypting payloads; it only shapes notification delivery metadata.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

    guard let bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    let userInfo = bestAttemptContent.userInfo
    let pushMode = (userInfo["push_mode"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let pushKind = (userInfo["push_kind"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if pushMode == "fast_notify" {
      bestAttemptContent.title = "TellMe"
      bestAttemptContent.body = Self.genericBody(for: pushKind)
      bestAttemptContent.sound = .default
    } else {
      bestAttemptContent.title = ""
      bestAttemptContent.subtitle = ""
      bestAttemptContent.body = ""
      bestAttemptContent.sound = nil
      bestAttemptContent.badge = nil
    }

    contentHandler(bestAttemptContent)
  }

  override func serviceExtensionTimeWillExpire() {
    guard let contentHandler, let bestAttemptContent else {
      return
    }

    contentHandler(bestAttemptContent)
  }

  private static func genericBody(for pushKind: String) -> String {
    switch pushKind {
    case "call":
      return "Incoming secure call"
    case "call_missed":
      return "Missed secure call"
    case "other":
      return "New secure activity"
    default:
      return "New secure message"
    }
  }
}
