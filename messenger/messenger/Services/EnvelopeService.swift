import CryptoKit
import Foundation

enum EnvelopeServiceError: Error {
  case invalidBlob
  case encodingFailed
  case decodingFailed
}

struct EnvelopeSealResult {
  let ciphertextBlob: String
  let nextState: RatchetSessionState
}

struct EnvelopeOpenResult {
  let header: EncryptedMessageHeader
  let payload: E2EMessagePayload
  let nextState: RatchetSessionState
}

protocol EnvelopeServiceProtocol {
  func seal(payload: E2EMessagePayload, state: RatchetSessionState) throws -> EnvelopeSealResult
  func open(ciphertextBlob: String, state: RatchetSessionState) throws -> EnvelopeOpenResult
}

/// Defines the client boundary between server-visible routing data and encrypted message content.
/// Ratchet state is returned to the caller and is never persisted as a side effect of sealing or opening.
final class EnvelopeService: EnvelopeServiceProtocol {
  // The outer envelope uses protocol-defined field names such as
  // `bootstrap_dh_pub` and `sender_device_dh_pub`. Decoding it through the
  // global snake-case converter drops these fields, which breaks inbound
  // prekey_init bootstrap for brand-new sessions.
  private static let wireEnvelopeEncoder: JSONEncoder = JSONEncoder()
  private static let wireEnvelopeDecoder: JSONDecoder = JSONDecoder()

  private let cryptoService: CryptoService
  private let ratchetService: DoubleRatchetServiceProtocol

  init(cryptoService: CryptoService, ratchetService: DoubleRatchetServiceProtocol) {
    self.cryptoService = cryptoService
    self.ratchetService = ratchetService
  }

  func seal(payload: E2EMessagePayload, state: RatchetSessionState) throws -> EnvelopeSealResult {
    let step = try ratchetService.nextSendStep(state: state)
    let header = EncryptedMessageHeader(
      conversationId: state.conversationId,
      senderUserHandle: state.localUserHandle ?? "",
      senderDeviceId: state.localDeviceId ?? "",
      messageIndex: step.messageIndex,
      previousChainLength: state.previousChainLength,
      ratchetPub: state.localRatchetPub,
      direction: "send",
      sentAt: Date()
    )
    let payloadData: Data
    let headerData: Data
    do {
      payloadData = try JSONCoding.encoder.encode(payload)
      headerData = try JSONCoding.encoder.encode(header)
    } catch {
      throw EnvelopeServiceError.encodingFailed
    }

    let kind: EncryptedMessageEnvelopeKind = step.messageIndex == 1 && state.bootstrapDhPub != nil
      ? .prekeyInit
      : .ratchetMessage
    // The independently encrypted header keeps sender and conversation metadata out of the
    // routing envelope while binding the protocol kind and session to its authentication tag.
    let outerAAD = Data("\(2)|\(kind.rawValue)|\(state.sessionId)".utf8)
    let encryptedHeader = try cryptoService.encryptAEAD(
      plaintext: headerData,
      key: step.messageKey,
      aad: outerAAD
    )
    let bodyAAD = bodyAADData(
      protocolVersion: 2,
      kind: kind,
      sessionId: state.sessionId,
      header: header
    )
    let encryptedBody = try cryptoService.encryptAEAD(
      plaintext: payloadData,
      key: step.messageKey,
      aad: bodyAAD
    )

    let envelope = EncryptedMessageEnvelope(
      protocolVersion: 2,
      kind: kind,
      sessionId: state.sessionId,
      ephemeralPub: kind == .prekeyInit ? (state.localRatchetPub ?? state.bootstrapDhPub) : nil,
      senderDeviceDhPub: kind == .prekeyInit ? state.localIkDhPublic : nil,
      ratchetPub: state.localRatchetPub,
      signedPrekeyId: kind == .prekeyInit ? state.signedPrekeyId : nil,
      oneTimePrekeyId: kind == .prekeyInit ? state.oneTimePrekeyId : nil,
      encryptedHeader: encryptedHeader,
      encryptedBody: encryptedBody
    )

    let encodedEnvelope: Data
    do {
      encodedEnvelope = try Self.wireEnvelopeEncoder.encode(envelope)
    } catch {
      throw EnvelopeServiceError.encodingFailed
    }

    return EnvelopeSealResult(
      ciphertextBlob: encodedEnvelope.base64EncodedString(),
      nextState: step.nextState
    )
  }

  func open(ciphertextBlob: String, state: RatchetSessionState) throws -> EnvelopeOpenResult {
    let envelope = try decodeEnvelope(ciphertextBlob: ciphertextBlob)
    let incomingRatchetPub = envelope.ratchetPub

    // The message index is encrypted with the header, so decryption cannot address a ratchet key
    // directly. Try retained single-use keys before advancing any current chain candidate.
    for skipped in state.skippedMessageKeys {
      let step: RatchetStepResult
      do {
        step = try ratchetService.nextReceiveStep(
          state: state,
          messageIndex: skipped.messageIndex,
          ratchetPub: incomingRatchetPub
        )
      } catch {
        continue
      }

      do {
        let header = try decryptHeader(envelope: envelope, messageKey: step.messageKey)
        let payload = try decryptBody(envelope: envelope, header: header, messageKey: step.messageKey)
        return EnvelopeOpenResult(header: header, payload: payload, nextState: step.nextState)
      } catch {
        continue
      }
    }

    // Limit speculative forward derivation to the same protocol skip window. This bounds CPU and
    // memory work for an unauthenticated blob whose header cannot yet be inspected.
    let maxSearchIndex = max(state.receiveCounter + 1, state.receiveCounter + 128)

    for candidateIndex in (state.receiveCounter + 1)...maxSearchIndex {
      let step: RatchetStepResult
      do {
        step = try ratchetService.nextReceiveStep(
          state: state,
          messageIndex: candidateIndex,
          ratchetPub: incomingRatchetPub
        )
      } catch {
        continue
      }

      do {
        let header = try decryptHeader(envelope: envelope, messageKey: step.messageKey)
        let payload = try decryptBody(envelope: envelope, header: header, messageKey: step.messageKey)
        return EnvelopeOpenResult(header: header, payload: payload, nextState: step.nextState)
      } catch {
        continue
      }
    }

    throw EnvelopeServiceError.decodingFailed
  }

  func decodeEnvelope(ciphertextBlob: String) throws -> EncryptedMessageEnvelope {
    guard let rawEnvelope: Data = Data(base64Encoded: ciphertextBlob) else {
      throw EnvelopeServiceError.invalidBlob
    }

    do {
      return try Self.wireEnvelopeDecoder.decode(EncryptedMessageEnvelope.self, from: rawEnvelope)
    } catch {
      throw EnvelopeServiceError.decodingFailed
    }
  }

  func openInitial(
    ciphertextBlob: String,
    state: RatchetSessionState
  ) throws -> EnvelopeOpenResult {
    let envelope = try decodeEnvelope(ciphertextBlob: ciphertextBlob)
    let step = try ratchetService.nextReceiveStep(state: state, messageIndex: 1)
    let header = try decryptHeader(envelope: envelope, messageKey: step.messageKey)
    let payload = try decryptBody(envelope: envelope, header: header, messageKey: step.messageKey)
    return EnvelopeOpenResult(header: header, payload: payload, nextState: step.nextState)
  }

  private func decryptHeader(
    envelope: EncryptedMessageEnvelope,
    messageKey: SymmetricKey
  ) throws -> EncryptedMessageHeader {
    let decrypted = try cryptoService.decryptAEAD(
      envelope: envelope.encryptedHeader,
      key: messageKey
    )

    do {
      return try JSONCoding.decoder.decode(EncryptedMessageHeader.self, from: decrypted)
    } catch {
      throw EnvelopeServiceError.decodingFailed
    }
  }

  private func decryptBody(
    envelope: EncryptedMessageEnvelope,
    header: EncryptedMessageHeader,
    messageKey: SymmetricKey
  ) throws -> E2EMessagePayload {
    let decrypted = try cryptoService.decryptAEAD(
      envelope: envelope.encryptedBody,
      key: messageKey
    )

    do {
      return try JSONCoding.decoder.decode(E2EMessagePayload.self, from: decrypted)
    } catch {
      throw EnvelopeServiceError.decodingFailed
    }
  }

  private func bodyAADData(
    protocolVersion: Int,
    kind: EncryptedMessageEnvelopeKind,
    sessionId: String,
    header: EncryptedMessageHeader
  ) -> Data {
    Data(
      "\(protocolVersion)|\(kind.rawValue)|\(sessionId)|\(header.messageIndex)|\(header.previousChainLength)|\(header.direction)"
        .utf8
    )
  }
}
