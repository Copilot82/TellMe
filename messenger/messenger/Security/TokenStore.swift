import Foundation

protocol TokenStore: AnyObject {
  var accessToken: String? { get }
  var refreshToken: String? { get }

  func saveTokens(accessToken: String, refreshToken: String)
  func clear()
}

final class InMemoryTokenStore: TokenStore {
  private var storedAccessToken: String?
  private var storedRefreshToken: String?

  var accessToken: String? {
    storedAccessToken
  }

  var refreshToken: String? {
    storedRefreshToken
  }

  func saveTokens(accessToken: String, refreshToken: String) {
    storedAccessToken = accessToken
    storedRefreshToken = refreshToken
  }

  func clear() {
    storedAccessToken = nil
    storedRefreshToken = nil
  }
}
