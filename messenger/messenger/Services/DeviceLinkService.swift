import Foundation

protocol DeviceLinkServiceProtocol {
  func registerDevice(bundle: DeviceBundle) async throws
  func revokeDevice(deviceId: String, signature: String, timestamp: String?) async throws
  func startLink(linkCode: String, lDhPub: String, expiresInSec: Int?) async throws -> FederatedDeviceLinkStartResponse
  func requestLink(
    userHandle: String,
    linkCode: String,
    nDhPub: String,
    deviceBundle: DeviceBundle
  ) async throws -> FederatedDeviceLinkRequestResponse
  func listLinkRequests(sessionId: String) async throws -> FederatedDeviceLinkSessionRequestsResponse
  func approveLink(
    linkCode: String,
    requestId: String,
    approvedDeviceCertificate: DeviceCertificateV2,
    encryptedProvisioningBlob: String
  ) async throws -> FederatedDeviceLinkApproveResponse
  func pollLinkRequest(requestId: String, pollToken: String) async throws -> FederatedDeviceLinkPollResponse
  func completeLink(_ request: FederatedDeviceLinkCompleteRequest) async throws -> FederatedDeviceLinkCompleteResponse
}

final class DeviceLinkService: DeviceLinkServiceProtocol {
  private let apiClient: APIClient

  init(apiClient: APIClient) {
    self.apiClient = apiClient
  }

  func registerDevice(bundle: DeviceBundle) async throws {
    let payload = FederatedDeviceRegisterRequest(
      devicePubKeys: FederatedDevicePublicKeys(
        deviceId: bundle.deviceId,
        dkSignPub: bundle.dkSignPublic,
        dkDhPub: bundle.dkDHPublic
      ),
      deviceCertificateChain: bundle.deviceCertificateChain
    )
    let body: Data = try apiClient.makeJSONBody(payload)
    let request: APIRequest = APIRequest(path: "devices/register", method: .post, body: body)
    try await apiClient.sendVoid(request)
  }

  func revokeDevice(deviceId: String, signature: String, timestamp: String?) async throws {
    let body: Data = try apiClient.makeJSONBody(
      FederatedDeviceRevokeRequest(
        deviceId: deviceId,
        signature: signature,
        timestamp: timestamp
      )
    )
    let request: APIRequest = APIRequest(path: "devices/revoke", method: .post, body: body)
    try await apiClient.sendVoid(request)
  }

  func startLink(linkCode: String, lDhPub: String, expiresInSec: Int?) async throws -> FederatedDeviceLinkStartResponse {
    let body: Data = try apiClient.makeJSONBody(
      FederatedDeviceLinkStartRequest(
        linkCode: linkCode,
        lDhPub: lDhPub,
        expiresInSec: expiresInSec
      )
    )
    let request: APIRequest = APIRequest(path: "devices/link/start", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func requestLink(
    userHandle: String,
    linkCode: String,
    nDhPub: String,
    deviceBundle: DeviceBundle
  ) async throws -> FederatedDeviceLinkRequestResponse {
    let body: Data = try apiClient.makeJSONBody(
      FederatedDeviceLinkRequestRequest(
        userHandle: userHandle,
        linkCode: linkCode,
        nDhPub: nDhPub,
        devicePubKeys: FederatedDevicePublicKeys(
          deviceId: deviceBundle.deviceId,
          dkSignPub: deviceBundle.dkSignPublic,
          dkDhPub: deviceBundle.dkDHPublic
        )
      )
    )
    let request: APIRequest = APIRequest(path: "devices/link/request", method: .post, body: body)
    return try await apiClient.send(request, requiresAuth: false)
  }

  func approveLink(
    linkCode: String,
    requestId: String,
    approvedDeviceCertificate: DeviceCertificateV2,
    encryptedProvisioningBlob: String
  ) async throws -> FederatedDeviceLinkApproveResponse {
    let body: Data = try apiClient.makeJSONBody(
      FederatedDeviceLinkApproveRequest(
        linkCode: linkCode,
        requestId: requestId,
        approvedDeviceCertificate: approvedDeviceCertificate,
        encryptedProvisioningBlob: encryptedProvisioningBlob
      )
    )
    let request: APIRequest = APIRequest(path: "devices/link/approve", method: .post, body: body)
    return try await apiClient.send(request)
  }

  func listLinkRequests(sessionId: String) async throws -> FederatedDeviceLinkSessionRequestsResponse {
    let request: APIRequest = APIRequest(path: "devices/link/session/\(sessionId)/requests", method: .get)
    return try await apiClient.send(request)
  }

  func pollLinkRequest(requestId: String, pollToken: String) async throws -> FederatedDeviceLinkPollResponse {
    let request: APIRequest = APIRequest(
      path: "devices/link/request/\(requestId)",
      method: .get,
      queryItems: [URLQueryItem(name: "poll_token", value: pollToken)]
    )
    return try await apiClient.send(request, requiresAuth: false)
  }

  func completeLink(_ requestPayload: FederatedDeviceLinkCompleteRequest) async throws -> FederatedDeviceLinkCompleteResponse {
    let body: Data = try apiClient.makeJSONBody(requestPayload)
    let request: APIRequest = APIRequest(path: "devices/link/complete", method: .post, body: body)
    return try await apiClient.send(request, requiresAuth: false)
  }
}
