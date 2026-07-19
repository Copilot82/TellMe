import Foundation

struct OnboardingStateStore {
  private static let initialAuthCompletedKey: String = "onboarding.initialAuthCompleted.v1"

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  var hasCompletedInitialAuth: Bool {
    defaults.bool(forKey: Self.initialAuthCompletedKey)
  }

  func markInitialAuthCompleted() {
    defaults.set(true, forKey: Self.initialAuthCompletedKey)
  }
}
