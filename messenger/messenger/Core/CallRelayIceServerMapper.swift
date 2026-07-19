import Foundation
import WebRTC

enum CallRelayIceServerMapper {
  static func map(_ rtcConfig: RTCConfig) -> [WebRTC.RTCIceServer] {
    rtcConfig.iceServers.compactMap { server in
      let urls: [String] = server.urlStrings
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { url in
          let lowercasedURL: String = url.lowercased()
          return lowercasedURL.hasPrefix("turn:") || lowercasedURL.hasPrefix("turns:")
        }

      guard !urls.isEmpty else {
        return nil
      }

      let username: String? = server.username ?? rtcConfig.turnCredentials.username
      let credential: String? = server.credential
        ?? rtcConfig.turnCredentials.credential
        ?? rtcConfig.turnCredentials.password
      return WebRTC.RTCIceServer(urlStrings: urls, username: username, credential: credential)
    }
  }
}
