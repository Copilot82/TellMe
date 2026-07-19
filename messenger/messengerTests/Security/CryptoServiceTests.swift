import XCTest
@testable import messenger

final class CryptoServiceTests: XCTestCase {
  func testHybridEncryptionRoundTripWithSignature() throws {
    let crypto: CryptoService = CryptoService()

    let recipient: (privateKey: SecKey, publicKey: SecKey) = try crypto.generateRSAKeyPair()
    let sender: (privateKey: SecKey, publicKey: SecKey) = try crypto.generateRSAKeyPair()

    let recipientPublicPEM: String = try crypto.exportPublicKeyPEM(recipient.publicKey)
    let senderPublicPEM: String = try crypto.exportPublicKeyPEM(sender.publicKey)

    let payload: EncryptedPayload = try crypto.hybridEncrypt(
      plaintext: "secret-message",
      recipientPublicKeyPEM: recipientPublicPEM,
      signingPrivateKey: sender.privateKey,
      senderPublicKeyPEM: senderPublicPEM
    )

    let plaintext: String = try crypto.hybridDecrypt(
      payload: payload,
      recipientPrivateKey: recipient.privateKey,
      senderPublicKeyPEM: senderPublicPEM
    )

    XCTAssertEqual(plaintext, "secret-message")
  }

  func testPublicKeyPEMImportExport() throws {
    let crypto: CryptoService = CryptoService()

    let pair: (privateKey: SecKey, publicKey: SecKey) = try crypto.generateRSAKeyPair()
    let pem: String = try crypto.exportPublicKeyPEM(pair.publicKey)
    let imported: SecKey = try crypto.importPublicKeyPEM(pem)

    let reExported: String = try crypto.exportPublicKeyPEM(imported)

    XCTAssertTrue(pem.contains("BEGIN PUBLIC KEY"))
    XCTAssertEqual(reExported, pem)
  }
}
