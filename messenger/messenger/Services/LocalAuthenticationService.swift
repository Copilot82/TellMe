import Foundation
import LocalAuthentication

enum LocalAuthenticationError: LocalizedError {
  case unavailable
  case failed

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Локальная аутентификация недоступна на этом устройстве."
    case .failed:
      return "Локальная аутентификация не пройдена."
    }
  }
}

@MainActor
protocol LocalAuthenticationServiceProtocol {
  func authenticate(reason: String) async throws
}

@MainActor
final class LocalAuthenticationService: LocalAuthenticationServiceProtocol {
  func authenticate(reason: String) async throws {
    let environment: [String: String] = ProcessInfo.processInfo.environment
    if environment["UITEST_MODE"] == "1" || environment["E2E_AUTORUN"] == "1" {
      return
    }

    let context = LAContext()
    var error: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw LocalAuthenticationError.unavailable
    }

    do {
      let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
      if !success {
        throw LocalAuthenticationError.failed
      }
    } catch {
      throw LocalAuthenticationError.failed
    }
  }
}
