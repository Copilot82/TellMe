import Foundation
@testable import messenger

final class InMemoryPrekeyPrivateStore: PrekeyPrivateStoreProtocol {
  private var signedPrekeys: [String: Data] = [:]
  private var signedPrekeyDates: [String: Date] = [:]
  private var oneTimePrekeys: [String: Data] = [:]
  private var opkIds: [String: [String]] = [:]

  func saveSignedPrekey(deviceId: String, prekeyId: String, privateKeyData: Data, createdAt: Date) throws {
    let key = "\(deviceId):\(prekeyId)"
    signedPrekeys[key] = privateKeyData
    signedPrekeyDates[key] = createdAt
  }

  func loadSignedPrekey(deviceId: String, prekeyId: String) -> Data? {
    signedPrekeys["\(deviceId):\(prekeyId)"]
  }

  func removeSignedPrekey(deviceId: String, prekeyId: String) {
    let key = "\(deviceId):\(prekeyId)"
    signedPrekeys.removeValue(forKey: key)
    signedPrekeyDates.removeValue(forKey: key)
  }

  func cleanupExpiredSignedPrekeys(deviceId: String, keepPrekeyId: String, gracePeriodDays: Int) {
    let cutoff = Date().addingTimeInterval(-Double(gracePeriodDays) * 86400)
    let keysToRemove = signedPrekeyDates
      .filter { k, date in
        let parts = k.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let kDeviceId = String(parts[0])
        let kPrekeyId = String(parts[1])
        return kDeviceId == deviceId && kPrekeyId != keepPrekeyId && date < cutoff
      }
      .map { $0.key }
    for key in keysToRemove {
      signedPrekeys.removeValue(forKey: key)
      signedPrekeyDates.removeValue(forKey: key)
    }
  }

  func saveOneTimePrekey(deviceId: String, prekeyId: String, privateKeyData: Data) throws {
    let key = "\(deviceId):\(prekeyId)"
    oneTimePrekeys[key] = privateKeyData
    var ids = opkIds[deviceId] ?? []
    if !ids.contains(prekeyId) {
      ids.append(prekeyId)
      opkIds[deviceId] = ids
    }
  }

  func loadOneTimePrekey(deviceId: String, prekeyId: String) -> Data? {
    oneTimePrekeys["\(deviceId):\(prekeyId)"]
  }

  func consumeOneTimePrekey(deviceId: String, prekeyId: String) {
    let key = "\(deviceId):\(prekeyId)"
    oneTimePrekeys.removeValue(forKey: key)
    opkIds[deviceId]?.removeAll { $0 == prekeyId }
  }

  func oneTimePrekeysCount(deviceId: String) -> Int {
    opkIds[deviceId]?.count ?? 0
  }
}
