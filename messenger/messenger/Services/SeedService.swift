import Foundation

protocol SeedServiceProtocol {
  func generateSeed() -> Data
  func encodeSeedPhrase(_ seed: Data) -> String
  func decodeSeedPhrase(_ phrase: String) -> Data?
}

final class SeedService: SeedServiceProtocol {
  private let cryptoService: CryptoService

  init(cryptoService: CryptoService) {
    self.cryptoService = cryptoService
  }

  func generateSeed() -> Data {
    cryptoService.generateSeed(bytes: 32)
  }

  func encodeSeedPhrase(_ seed: Data) -> String {
    seed.base64EncodedString()
  }

  func decodeSeedPhrase(_ phrase: String) -> Data? {
    Data(base64Encoded: phrase.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
