import XCTest
@testable import messenger

final class X3DHServiceTests: XCTestCase {
  func testBootstrapSessionIsSymmetricAndCanDecryptFirstMessage() throws {
    let cryptoService = CryptoService()
    let seedService = SeedService(cryptoService: cryptoService)
    let x3dhService = X3DHService(seedService: seedService, cryptoService: cryptoService)
    let ratchetService = DoubleRatchetService()
    let envelopeService = EnvelopeService(cryptoService: cryptoService, ratchetService: ratchetService)

    let aliceSeed: Data = seedService.generateSeed()
    let bobSeed: Data = seedService.generateSeed()
    let alicePhrase: String = seedService.encodeSeedPhrase(aliceSeed)
    let bobPhrase: String = seedService.encodeSeedPhrase(bobSeed)

    let aliceIdentity = try cryptoService.deriveIdentityKeys(seed: aliceSeed)
    let bobIdentity = try cryptoService.deriveIdentityKeys(seed: bobSeed)

    let conversationId: String = "conversation-qr-ab"
    let sessionId: String = "session-fixed-1"
    let aliceState: RatchetSessionState = try x3dhService.bootstrapSession(
      seedPhrase: alicePhrase,
      localUserHandle: "@alice:example.org",
      localDeviceId: "alice-device-1",
      peerUserHandle: "@bob:example.org",
      peerDeviceId: "bob-device-1",
      peerIkDhPublic: bobIdentity.ikDHPublicBase64,
      sessionId: sessionId,
      conversationId: conversationId
    )

    let bobState: RatchetSessionState = try x3dhService.bootstrapSession(
      seedPhrase: bobPhrase,
      localUserHandle: "@bob:example.org",
      localDeviceId: "bob-device-1",
      peerUserHandle: "@alice:example.org",
      peerDeviceId: "alice-device-1",
      peerIkDhPublic: aliceIdentity.ikDHPublicBase64,
      sessionId: sessionId,
      conversationId: conversationId
    )

    XCTAssertEqual(aliceState.sessionId, bobState.sessionId)
    XCTAssertEqual(aliceState.sendChainKey, bobState.receiveChainKey)
    XCTAssertEqual(aliceState.receiveChainKey, bobState.sendChainKey)

    let payload = E2EMessagePayload(
      conversationId: conversationId,
      msgType: "text",
      body: "hello-from-alice",
      attachments: [],
      padding: "00000000"
    )

    let sealed: EnvelopeSealResult = try envelopeService.seal(payload: payload, state: aliceState)
    let opened: EnvelopeOpenResult = try envelopeService.open(
      ciphertextBlob: sealed.ciphertextBlob,
      state: bobState
    )

    XCTAssertEqual(opened.payload, payload)
  }

  func testReceiveStepUsesMessageIndexAndCachedSkippedKeys() throws {
    let cryptoService = CryptoService()
    let seedService = SeedService(cryptoService: cryptoService)
    let x3dhService = X3DHService(seedService: seedService, cryptoService: cryptoService)
    let ratchetService = DoubleRatchetService()
    let envelopeService = EnvelopeService(cryptoService: cryptoService, ratchetService: ratchetService)

    let aliceSeed: Data = seedService.generateSeed()
    let bobSeed: Data = seedService.generateSeed()
    let alicePhrase: String = seedService.encodeSeedPhrase(aliceSeed)
    let bobPhrase: String = seedService.encodeSeedPhrase(bobSeed)

    let aliceIdentity = try cryptoService.deriveIdentityKeys(seed: aliceSeed)
    let bobIdentity = try cryptoService.deriveIdentityKeys(seed: bobSeed)
    let conversationId: String = "conversation-qr-skipped"
    let sessionId: String = "session-fixed-2"

    var aliceState: RatchetSessionState = try x3dhService.bootstrapSession(
      seedPhrase: alicePhrase,
      localUserHandle: "@alice:example.org",
      localDeviceId: "alice-device-1",
      peerUserHandle: "@bob:example.org",
      peerDeviceId: "bob-device-1",
      peerIkDhPublic: bobIdentity.ikDHPublicBase64,
      sessionId: sessionId,
      conversationId: conversationId
    )
    var bobState: RatchetSessionState = try x3dhService.bootstrapSession(
      seedPhrase: bobPhrase,
      localUserHandle: "@bob:example.org",
      localDeviceId: "bob-device-1",
      peerUserHandle: "@alice:example.org",
      peerDeviceId: "alice-device-1",
      peerIkDhPublic: aliceIdentity.ikDHPublicBase64,
      sessionId: sessionId,
      conversationId: conversationId
    )

    // Verify symmetric chain keys (Alice send == Bob receive)
    XCTAssertEqual(aliceState.sendChainKey, bobState.receiveChainKey, "Send/receive chain keys must be symmetric")

    let firstPayload = E2EMessagePayload(
      conversationId: conversationId,
      msgType: "text",
      body: "first",
      attachments: [],
      padding: "00000000"
    )
    let secondPayload = E2EMessagePayload(
      conversationId: conversationId,
      msgType: "text",
      body: "second",
      attachments: [],
      padding: "00000000"
    )

    let firstSealed: EnvelopeSealResult = try envelopeService.seal(payload: firstPayload, state: aliceState)
    aliceState = firstSealed.nextState
    let secondSealed: EnvelopeSealResult = try envelopeService.seal(payload: secondPayload, state: aliceState)

    // Open out-of-order: second first, then first (should use skipped key cache)
    let secondOpened: EnvelopeOpenResult = try envelopeService.open(
      ciphertextBlob: secondSealed.ciphertextBlob,
      state: bobState
    )
    bobState = secondOpened.nextState

    let firstOpened: EnvelopeOpenResult = try envelopeService.open(
      ciphertextBlob: firstSealed.ciphertextBlob,
      state: bobState
    )

    XCTAssertEqual(secondOpened.payload.body, "second")
    XCTAssertEqual(firstOpened.payload.body, "first")
  }
}
