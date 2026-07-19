import Foundation
import LocalAuthentication

enum BiometricError: Error {
  case unavailable
  case failed
  case canceled
}

protocol BiometricAuthenticating {
  func canUseBiometrics() -> Bool
  func authenticate(reason: String) async throws -> Bool
}

final class BiometricAuthenticator: BiometricAuthenticating {
  func canUseBiometrics() -> Bool {
    let context: LAContext = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
  }

  func authenticate(reason: String) async throws -> Bool {
    let context: LAContext = LAContext()
    var error: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      throw BiometricError.unavailable
    }

    return try await withCheckedThrowingContinuation { continuation in
      context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evaluationError in
        if success {
          continuation.resume(returning: true)
          return
        }

        if let laError: LAError = evaluationError as? LAError,
          laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel
        {
          continuation.resume(throwing: BiometricError.canceled)
          return
        }

        continuation.resume(throwing: BiometricError.failed)
      }
    }
  }
}
