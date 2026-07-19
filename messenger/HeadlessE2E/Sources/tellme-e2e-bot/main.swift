import Darwin
import Foundation
import TellMeHeadlessE2ECore

@main
enum HeadlessE2EBot {
  static func main() {
    do {
      let config = try CLIConfig.parse(arguments: Array(CommandLine.arguments.dropFirst()))
      let outputData: Data
      switch config.mode {
      case .offlineContractFixture:
        let fixture = try HeadlessContractFixtureBuilder.make(
          userHandle: config.userHandle,
          seedPhrase: config.seedPhrase,
          deviceId: config.deviceId,
          oneTimePrekeysCount: config.oneTimePrekeys,
          issuedAt: config.issuedAt,
          timestamp: config.timestamp,
          generatedAt: config.generatedAt
        )
        outputData = try JSONCoding.encoder.encode(fixture)
      case .authFinishRequest:
        guard let challengeId = config.challengeId, let nonce = config.nonce else {
          throw CLIError.invalidArgument("--mode auth-finish-request requires --challenge-id and --nonce")
        }
        let proof = try HeadlessAuthFinishProofBuilder.make(
          userHandle: config.userHandle,
          seedPhrase: config.seedPhrase,
          deviceId: config.deviceId,
          challengeId: challengeId,
          nonce: nonce,
          issuedAt: config.issuedAt,
          generatedAt: config.generatedAt
        )
        outputData = try JSONCoding.encoder.encode(proof)
      case .deviceRevokeRequest:
        guard let targetDeviceId = config.targetDeviceId else {
          throw CLIError.invalidArgument("--mode device-revoke-request requires --target-device-id")
        }
        let proof = try HeadlessDeviceRevokeProofBuilder.make(
          userHandle: config.userHandle,
          seedPhrase: config.seedPhrase,
          signingDeviceId: config.deviceId,
          targetDeviceId: targetDeviceId,
          timestamp: config.timestamp,
          generatedAt: config.generatedAt
        )
        outputData = try JSONCoding.encoder.encode(proof)
      case .deviceLinkApproval:
        guard let targetDeviceId = config.targetDeviceId else {
          throw CLIError.invalidArgument("--mode device-link-approval requires --target-device-id")
        }
        let proof = try HeadlessDeviceLinkApprovalProofBuilder.make(
          userHandle: config.userHandle,
          seedPhrase: config.seedPhrase,
          hostDeviceId: config.deviceId,
          linkedDeviceId: targetDeviceId,
          oneTimePrekeysCount: config.oneTimePrekeys,
          issuedAt: config.issuedAt,
          generatedAt: config.generatedAt
        )
        outputData = try JSONCoding.encoder.encode(proof)
      case .mediaUploadAttestation:
        guard let mediaId = config.mediaId,
          let capabilityToken = config.capabilityToken,
          let ciphertextSha256 = config.ciphertextSha256,
          let ciphertextSize = config.ciphertextSize
        else {
          throw CLIError.invalidArgument(
            "--mode media-upload-attestation requires --media-id, --capability-token, --ciphertext-sha256, and --ciphertext-size"
          )
        }
        let proof = try HeadlessMediaUploadAttestationProofBuilder.make(
          userHandle: config.userHandle,
          seedPhrase: config.seedPhrase,
          deviceId: config.deviceId,
          mediaId: mediaId,
          capabilityToken: capabilityToken,
          ciphertextSha256: ciphertextSha256,
          ciphertextSize: ciphertextSize,
          scanVerdict: config.scanVerdict,
          riskFlags: config.riskFlags,
          scannerVersion: config.scannerVersion,
          rulesVersion: config.rulesVersion,
          issuedAt: config.issuedAt,
          generatedAt: config.generatedAt
        )
        outputData = try JSONCoding.encoder.encode(proof)
      }

      if let outputPath = config.outputPath {
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try outputData.write(to: outputURL, options: [.atomic])
      }

      if config.printToStdout || config.outputPath == nil {
        FileHandle.standardOutput.write(outputData)
        FileHandle.standardOutput.write(Data("\n".utf8))
      }
    } catch CLIError.help {
      FileHandle.standardOutput.write(Data("\(CLIError.help.localizedDescription)\n".utf8))
      exit(0)
    } catch {
      let message = "tellme-e2e-bot: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(2)
    }
  }
}

private struct CLIConfig {
  let mode: CLIMode
  let userHandle: String
  let seedPhrase: String?
  let deviceId: String?
  let challengeId: String?
  let nonce: String?
  let targetDeviceId: String?
  let mediaId: String?
  let capabilityToken: String?
  let ciphertextSha256: String?
  let ciphertextSize: Int?
  let scanVerdict: String
  let riskFlags: [String]
  let scannerVersion: Int
  let rulesVersion: Int
  let oneTimePrekeys: Int
  let outputPath: String?
  let issuedAt: Date
  let timestamp: Date
  let generatedAt: Date
  let printToStdout: Bool

  static func parse(arguments: [String]) throws -> CLIConfig {
    let environment = ProcessInfo.processInfo.environment
    var mode = try CLIMode(rawValue: environment["E2E_HEADLESS_MODE"] ?? "offline-contract-fixture")
    var userHandle = environment["E2E_HEADLESS_USER_HANDLE"] ?? "@headless-reference:messenger.surraund.com"
    var seedPhrase = environment["E2E_HEADLESS_SEED_BASE64"]
    var deviceId = environment["E2E_HEADLESS_DEVICE_ID"]
    var challengeId = environment["E2E_HEADLESS_CHALLENGE_ID"]
    var nonce = environment["E2E_HEADLESS_NONCE"]
    var targetDeviceId = environment["E2E_HEADLESS_TARGET_DEVICE_ID"]
    var mediaId = environment["E2E_HEADLESS_MEDIA_ID"]
    var capabilityToken = environment["E2E_HEADLESS_MEDIA_CAPABILITY_TOKEN"]
    var ciphertextSha256 = environment["E2E_HEADLESS_CIPHERTEXT_SHA256"]
    var ciphertextSize = Int(environment["E2E_HEADLESS_CIPHERTEXT_SIZE"] ?? "")
    var scanVerdict = environment["E2E_HEADLESS_MEDIA_SCAN_VERDICT"] ?? "clean"
    var riskFlags = parseRiskFlags(environment["E2E_HEADLESS_MEDIA_RISK_FLAGS"] ?? "")
    var scannerVersion = Int(environment["E2E_HEADLESS_MEDIA_SCANNER_VERSION"] ?? "") ?? 1
    var rulesVersion = Int(environment["E2E_HEADLESS_MEDIA_RULES_VERSION"] ?? "") ?? 1
    var oneTimePrekeys = Int(environment["E2E_HEADLESS_ONE_TIME_PREKEYS"] ?? "") ?? 3
    var outputPath = environment["E2E_HEADLESS_OUTPUT"]
    var issuedAt = try parseOptionalDate(environment["E2E_HEADLESS_ISSUED_AT"]) ?? Date()
    var timestamp = try parseOptionalDate(environment["E2E_HEADLESS_TIMESTAMP"]) ?? issuedAt
    var generatedAt = try parseOptionalDate(environment["E2E_HEADLESS_GENERATED_AT"]) ?? issuedAt
    var printToStdout = false

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--mode":
        mode = try CLIMode(rawValue: value(after: argument, in: arguments, index: &index))
      case "--user-handle":
        userHandle = try value(after: argument, in: arguments, index: &index)
      case "--seed-base64":
        seedPhrase = try value(after: argument, in: arguments, index: &index)
      case "--device-id":
        deviceId = try value(after: argument, in: arguments, index: &index)
      case "--challenge-id":
        challengeId = try value(after: argument, in: arguments, index: &index)
      case "--nonce":
        nonce = try value(after: argument, in: arguments, index: &index)
      case "--target-device-id":
        targetDeviceId = try value(after: argument, in: arguments, index: &index)
      case "--media-id":
        mediaId = try value(after: argument, in: arguments, index: &index)
      case "--capability-token":
        capabilityToken = try value(after: argument, in: arguments, index: &index)
      case "--ciphertext-sha256":
        ciphertextSha256 = try value(after: argument, in: arguments, index: &index)
      case "--ciphertext-size":
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let parsed = Int(rawValue), parsed >= 0 else {
          throw CLIError.invalidArgument("--ciphertext-size expects a non-negative integer")
        }
        ciphertextSize = parsed
      case "--scan-verdict":
        scanVerdict = try value(after: argument, in: arguments, index: &index)
      case "--risk-flags":
        riskFlags = parseRiskFlags(try value(after: argument, in: arguments, index: &index))
      case "--scanner-version":
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let parsed = Int(rawValue), parsed > 0 else {
          throw CLIError.invalidArgument("--scanner-version expects a positive integer")
        }
        scannerVersion = parsed
      case "--rules-version":
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let parsed = Int(rawValue), parsed > 0 else {
          throw CLIError.invalidArgument("--rules-version expects a positive integer")
        }
        rulesVersion = parsed
      case "--one-time-prekeys":
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let parsed = Int(rawValue) else {
          throw CLIError.invalidArgument("--one-time-prekeys expects an integer")
        }
        oneTimePrekeys = parsed
      case "--output":
        outputPath = try value(after: argument, in: arguments, index: &index)
      case "--issued-at":
        issuedAt = try parseDate(try value(after: argument, in: arguments, index: &index))
      case "--timestamp":
        timestamp = try parseDate(try value(after: argument, in: arguments, index: &index))
      case "--generated-at":
        generatedAt = try parseDate(try value(after: argument, in: arguments, index: &index))
      case "--print":
        printToStdout = true
      case "--help", "-h":
        throw CLIError.help
      default:
        throw CLIError.invalidArgument("Unknown argument: \(argument)")
      }
      index += 1
    }

    return CLIConfig(
      mode: mode,
      userHandle: userHandle,
      seedPhrase: seedPhrase,
      deviceId: deviceId,
      challengeId: challengeId,
      nonce: nonce,
      targetDeviceId: targetDeviceId,
      mediaId: mediaId,
      capabilityToken: capabilityToken,
      ciphertextSha256: ciphertextSha256,
      ciphertextSize: ciphertextSize,
      scanVerdict: scanVerdict,
      riskFlags: riskFlags,
      scannerVersion: scannerVersion,
      rulesVersion: rulesVersion,
      oneTimePrekeys: oneTimePrekeys,
      outputPath: outputPath,
      issuedAt: issuedAt,
      timestamp: timestamp,
      generatedAt: generatedAt,
      printToStdout: printToStdout
    )
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
      throw CLIError.invalidArgument("\(argument) requires a value")
    }
    index = valueIndex
    return arguments[valueIndex]
  }

  private static func parseDate(_ rawValue: String) throws -> Date {
    if let date = TellMeDateFormat.parse(rawValue) {
      return date
    }
    throw CLIError.invalidArgument("Invalid ISO8601 date: \(rawValue)")
  }

  private static func parseOptionalDate(_ rawValue: String?) throws -> Date? {
    guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return try parseDate(rawValue)
  }

  private static func parseRiskFlags(_ rawValue: String) -> [String] {
    rawValue.split(separator: ",").map { String($0) }
  }
}

private enum CLIMode {
  case offlineContractFixture
  case authFinishRequest
  case deviceRevokeRequest
  case deviceLinkApproval
  case mediaUploadAttestation

  init(rawValue: String) throws {
    switch rawValue {
    case "offline-contract-fixture":
      self = .offlineContractFixture
    case "auth-finish-request":
      self = .authFinishRequest
    case "device-revoke-request":
      self = .deviceRevokeRequest
    case "device-link-approval":
      self = .deviceLinkApproval
    case "media-upload-attestation":
      self = .mediaUploadAttestation
    default:
      throw CLIError.invalidArgument(
        "--mode supports offline-contract-fixture, auth-finish-request, device-revoke-request, device-link-approval, or media-upload-attestation"
      )
    }
  }
}

private enum CLIError: Error, LocalizedError {
  case help
  case invalidArgument(String)

  var errorDescription: String? {
    switch self {
    case .help:
      """
      Usage:
        tellme-e2e-bot --mode offline-contract-fixture --output /tmp/headless-fixture.json
        tellme-e2e-bot --mode auth-finish-request --challenge-id UUID --nonce NONCE --output /tmp/auth-finish.json
        tellme-e2e-bot --mode device-revoke-request --target-device-id DEVICE --output /tmp/revoke.json
        tellme-e2e-bot --mode device-link-approval --device-id HOST --target-device-id DEVICE --output /tmp/link.json
        tellme-e2e-bot --mode media-upload-attestation --media-id ID --capability-token TOKEN --ciphertext-sha256 SHA256 --ciphertext-size BYTES --output /tmp/media.json

      Options:
        --user-handle @user:domain
        --seed-base64 BASE64_32_BYTE_SEED
        --device-id DEVICE_ID
        --challenge-id UUID
        --nonce NONCE
        --target-device-id DEVICE_ID
        --media-id ID
        --capability-token TOKEN
        --ciphertext-sha256 SHA256
        --ciphertext-size BYTES
        --scan-verdict clean|warn
        --risk-flags comma,separated,flags
        --scanner-version VERSION
        --rules-version VERSION
        --one-time-prekeys COUNT
        --issued-at ISO8601
        --timestamp ISO8601
        --generated-at ISO8601
        --print
      """
    case .invalidArgument(let message):
      message
    }
  }
}
