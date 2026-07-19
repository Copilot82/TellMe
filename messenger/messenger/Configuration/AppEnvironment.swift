import Foundation

// Environment resolution is centralized so tests and production builds share the same endpoint contract.
struct AppEnvironment: Equatable {
  let apiBaseURL: URL
  let webSocketBaseURL: URL
  let turnURL: String
  let stunURL: String

  private static let productionDefaults: AppEnvironment = AppEnvironment(
    apiBaseURL: URL(string: "https://messenger.surraund.com/api")!,
    webSocketBaseURL: URL(string: "wss://messenger.surraund.com/socket.io")!,
    turnURL: "turn:turn.surraund.com:3478",
    stunURL: ""
  )

  private static let localDefaults: AppEnvironment = AppEnvironment(
    // Keep the client default aligned with compose.dev.yml so a fresh clone does not require
    // an Xcode scheme override for the basic simulator-to-backend path.
    apiBaseURL: URL(string: "http://localhost:3100/api")!,
    webSocketBaseURL: URL(string: "ws://localhost:3100/socket.io")!,
    turnURL: "turn:turn.example.invalid:3478",
    stunURL: ""
  )

  static var current: AppEnvironment {
    let environment: [String: String] = ProcessInfo.processInfo.environment
    if let rawSelection: String = environment["MESSENGER_APP_ENV"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      switch rawSelection {
      case "local":
        return local
      case "production", "prod":
        return production
      default:
        break
      }
    }

    return production
  }

  static let production: AppEnvironment = {
    resolve(defaults: productionDefaults)
  }()

  static let local: AppEnvironment = {
    resolve(defaults: localDefaults)
  }()

  private static func resolve(defaults: AppEnvironment) -> AppEnvironment {
    let environment: [String: String] = ProcessInfo.processInfo.environment

    let apiBaseURL: URL = {
      let rawValue: String? = configurationValue(
        environment: environment,
        environmentKey: "E2E_API_BASE_URL",
        infoKey: "TellMeAPIBaseURL"
      )
      if let rawValue, let url: URL = URL(string: rawValue) {
        return url
      }
      return defaults.apiBaseURL
    }()

    let webSocketBaseURL: URL = {
      let rawValue: String? = configurationValue(
        environment: environment,
        environmentKey: "E2E_WS_BASE_URL",
        infoKey: "TellMeWebSocketBaseURL"
      )
      if let rawValue, let url: URL = URL(string: rawValue) {
        return url
      }

      if let derived: URL = deriveWebSocketBaseURL(from: apiBaseURL) {
        return derived
      }

      return defaults.webSocketBaseURL
    }()

    let turnURL: String = configurationValue(
      environment: environment,
      environmentKey: "E2E_TURN_URL",
      infoKey: "TellMeTURNURL"
    ) ?? defaults.turnURL
    let stunURL: String = configurationValue(
      environment: environment,
      environmentKey: "E2E_STUN_URL",
      infoKey: "TellMeSTUNURL"
    ) ?? defaults.stunURL

    return AppEnvironment(
      apiBaseURL: apiBaseURL,
      webSocketBaseURL: webSocketBaseURL,
      turnURL: turnURL,
      stunURL: stunURL
    )
  }

  private static func configurationValue(
    environment: [String: String],
    environmentKey: String,
    infoKey: String
  ) -> String? {
    let candidates: [String?] = [
      environment[environmentKey],
      Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
    ]

    return candidates.compactMap { (value: String?) -> String? in
      guard let trimmed: String = value?.trimmingCharacters(in: .whitespacesAndNewlines),
        !trimmed.isEmpty,
        !trimmed.contains("$(")
      else {
        return nil
      }
      return trimmed
    }.first
  }

  private static func deriveWebSocketBaseURL(from apiBaseURL: URL) -> URL? {
    guard var components: URLComponents = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }

    switch components.scheme?.lowercased() {
    case "https":
      components.scheme = "wss"
    case "http":
      components.scheme = "ws"
    default:
      break
    }

    let apiPath: String = components.path
    if apiPath.hasSuffix("/api") {
      components.path = String(apiPath.dropLast(4)) + "/socket.io"
    } else {
      components.path = "/socket.io"
    }
    components.query = nil

    return components.url
  }

  func mediaOriginAPIBaseURL(serverDomain: String) -> URL {
    guard var components: URLComponents = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
      return apiBaseURL
    }

    components.host = serverDomain
    components.path = "/api"
    components.query = nil
    components.fragment = nil
    return components.url ?? apiBaseURL
  }
}

struct JSONCoding {
  static let decoder: JSONDecoder = {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
      let stringValue: String = try container.decode(String.self)

      if let date: Date = ISO8601DateFormatter.withFractionalSeconds.date(from: stringValue) {
        return date
      }

      if let date: Date = ISO8601DateFormatter.standard.date(from: stringValue) {
        return date
      }

      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
    }
    return decoder
  }()

  static let encoder: JSONEncoder = {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container: SingleValueEncodingContainer = encoder.singleValueContainer()
      let stringValue: String = ISO8601DateFormatter.withFractionalSeconds.string(from: date)
      try container.encode(stringValue)
    }
    return encoder
  }()
}

extension ISO8601DateFormatter {
  static let withFractionalSeconds: ISO8601DateFormatter = {
    let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static let standard: ISO8601DateFormatter = {
    let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}
