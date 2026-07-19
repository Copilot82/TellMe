import Foundation

enum TestServerConfiguration {
  static let domain: String = "messenger.surraund.com"

  static var handleTemplate: String {
    "@<login>:\(domain)"
  }

  static func userHandle(fromRegistrationInput rawValue: String) -> String? {
    let normalizedInput: String = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    guard !normalizedInput.isEmpty else {
      return nil
    }

    if normalizedInput.hasPrefix("@"), normalizedInput.contains(":") {
      guard normalizedInput.range(
        of: "^@[a-z0-9._-]+:\(NSRegularExpression.escapedPattern(for: domain))$",
        options: .regularExpression
      ) != nil else {
        return nil
      }

      return normalizedInput
    }

    let login: String = normalizedInput.hasPrefix("@")
      ? String(normalizedInput.dropFirst())
      : normalizedInput

    guard login.range(of: "^[a-z0-9._-]+$", options: .regularExpression) != nil else {
      return nil
    }

    return "@\(login):\(domain)"
  }
}
