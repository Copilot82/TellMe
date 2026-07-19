import CryptoKit
import Foundation

protocol NetworkClient {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionNetworkClient: NSObject, NetworkClient, URLSessionDelegate {
  private lazy var session: URLSession = {
    if let suppliedSession {
      return suppliedSession
    }

    let configuration: URLSessionConfiguration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = max(requestTimeout, 180)
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()
  private let suppliedSession: URLSession?
  private let requestTimeout: TimeInterval
  private let pinnedLeafCertificateHashes: [String: Set<String>]

  init(session: URLSession? = nil, requestTimeout: TimeInterval = 180) {
    self.suppliedSession = session
    self.requestTimeout = requestTimeout
    self.pinnedLeafCertificateHashes = Self.pinnedLeafCertificateHashes()
    super.init()
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      var preparedRequest: URLRequest = request
      preparedRequest.timeoutInterval = requestTimeout

      let (data, response): (Data, URLResponse) = try await session.data(for: preparedRequest)

      guard let httpResponse: HTTPURLResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      return (data, httpResponse)
    } catch let error as APIError {
      throw error
    } catch {
      throw APIError.transport(Self.describeTransportError(error))
    }
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust: SecTrust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    let host: String = challenge.protectionSpace.host.lowercased()
    guard let allowedPins: Set<String> = pinnedLeafCertificateHashes[host], !allowedPins.isEmpty else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    guard SecTrustEvaluateWithError(trust, nil),
      let certificateChain: [SecCertificate] = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate: SecCertificate = certificateChain.first
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    let certificateData: Data = SecCertificateCopyData(certificate) as Data
    let leafHash: String = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
    guard allowedPins.contains(leafHash) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  static func pinnedLeafCertificateHashes(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: Set<String>] {
    let appEnv: String = environment["MESSENGER_APP_ENV"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if appEnv == "local" {
      return [:]
    }

    let primaryHost: String = environment["E2E_API_PIN_HOST"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      ?? (Bundle.main.object(forInfoDictionaryKey: "TellMeAPIPinHost") as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      ?? AppEnvironment.current.apiBaseURL.host?.lowercased()
      ?? ""
    let configuredPins: [String] = [
      environment["E2E_API_PRIMARY_CERT_SHA256"]
        ?? Bundle.main.object(forInfoDictionaryKey: "TellMeAPIPrimaryCertSHA256") as? String,
      environment["E2E_API_BACKUP_CERT_SHA256"]
        ?? Bundle.main.object(forInfoDictionaryKey: "TellMeAPIBackupCertSHA256") as? String,
    ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && !$0.contains("$(") }

    guard !primaryHost.isEmpty, !primaryHost.contains("$("), !configuredPins.isEmpty else {
      return [:]
    }

    return [primaryHost: Set(configuredPins)]
  }

  static func describeTransportError(_ error: Error) -> String {
    if let urlError: URLError = error as? URLError,
      urlError.code == .cancelled
    {
      return "TLS trust validation failed or the request was cancelled. Check the server certificate and network connection."
    }

    let message: String = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "Network request failed" : message
  }
}
