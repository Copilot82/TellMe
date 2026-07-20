# HTTP and WebSocket API

## 1. General rules

- Client base URL: `/api`.
- Body format: JSON, except for binary media-ciphertext upload.
- JSON field names: `snake_case`.
- Error format: `{ "error": "message" }`.
- Session authentication: `Authorization: Bearer <session_token>`.
- Federation authentication: signed `X-TellMe-*` headers.
- Query, body-size, and batch bounds are validated before a repository call.

This document is a surface overview. Rust types and XCTest contract tests define the exact request
schema. Changing an endpoint without updating `contract.rs` is an error.

## 2. System endpoints

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `GET` | `/health` | none | process health |
| `GET` | `/ready` | none | implementation readiness |
| `GET` | `/api/config` | none | public protocol and server limits |

## 3. Authentication

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/auth/register` | registration proof | account and first device |
| `POST` | `/api/auth/start` | none | single-use challenge |
| `POST` | `/api/auth/finish` | device signature | session/refresh pair |
| `POST` | `/api/auth/refresh` | refresh token | session-pair rotation |
| `POST` | `/api/auth/logout` | session/refresh | session revocation |

`auth/start` must not distinguish an existing account from an absent one in a way that creates a
public account-enumeration oracle.

## 4. Devices and linking

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/devices/register` | register a device certificate |
| `POST` | `/api/devices/revoke` | revoke a device with signed proof |
| `POST` | `/api/devices/link/start` | create a trusted-device link session |
| `POST` | `/api/devices/link/request` | submit a new-device request |
| `GET` | `/api/devices/link/session/:sessionId/requests` | list pending requests for a trusted device |
| `GET` | `/api/devices/link/request/:requestId` | poll status with a poll token |
| `POST` | `/api/devices/link/approve` | submit certificate and encrypted provisioning data |
| `POST` | `/api/devices/link/complete` | complete linking and issue tokens to the new device |
| `GET` | `/api/devices/push/tokens` | list token metadata for the current device |
| `POST` | `/api/devices/push/tokens` | upsert an alert or VoIP token |
| `PUT` | `/api/devices/push/tokens/:token` | change push mode or state |
| `DELETE` | `/api/devices/push/tokens/:token` | delete a token |

A raw APNs token is never returned to another account or device and must not appear in application
logs.

## 5. Prekeys

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/prekeys/publish` | session | signed and one-time prekeys for the current device |
| `GET` | `/api/prekeys/get?user=...&peek=...` | optional/session | public recipient bundle |
| `GET` | `/api/prekeys/self?peek=...` | session | bundles for the current account |

`peek=false` may atomically consume a one-time prekey. After a successful consume, a repeated bundle
must not return the same available OPK.

## 6. Messages and synchronization

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/messages/send` | batch of per-device ciphertext deliveries |
| `POST` | `/api/messages/ack` | acknowledge delivery IDs for the current device |
| `GET` | `/api/sync/stream?device_id=...&limit=...` | pending mailbox blobs |

`limit` is in `1...1000`; the default is `200`. The backend neither interprets `ciphertext_blob`
content nor generates plaintext call or message fields.

## 7. Media

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/media/upload/init` | session | create media ID and download capability |
| `PUT` | `/api/media/upload/:id` | capability and attestation | upload ciphertext |
| `GET` | `/api/media/ciphertext/:id` | capability | download ciphertext |

Upload validates the capability, declared size, ciphertext hash, scanner and rules versions, and
attestation. Download never returns the media key.

## 8. TURN

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/turn/credentials` | session | ephemeral TURN username, password, and URLs |

The request accepts no user handle, peer ID, conversation ID, or call ID. The TTL for a new
allocation is bounded to `60...900` seconds.

## 9. Federation

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `GET` | `/federation/v1/server-keys` | none/transport policy | public server-key metadata |
| `GET` | `/federation/v1/prekeys/:userHandle` | signed request | remote prekey lookup |
| `POST` | `/federation/v1/deliver` | signed request | remote ciphertext delivery |
| `POST` | `/federation/v1/receipts` | signed request | delivery receipts |

The canonical signature binds the HTTP method, path, timestamp, and SHA-256 body hash. An unknown,
blocked, expired, or incorrectly signed server request is rejected before domain processing.

## 10. WebSocket

Transport endpoint: `/socket.io/?EIO=4&transport=websocket`.

The session token is passed through Socket.IO connect auth, never through the query string.
Realtime notifies and accelerates synchronization; the PostgreSQL mailbox remains the source of
truth for pending delivery.

### Client events

| Event | Purpose |
| --- | --- |
| `sync_subscribe` | subscribe to the current device mailbox |
| `sync_pull` | request blobs with an optional bounded limit |
| `presence_touch` | refresh short-lived presence |
| `join_conversation` | active-conversation hint without server chat membership |
| `leave_conversation` | remove the active hint |
| `presence_offline` | explicit offline override |

### Server events

| Event | Payload |
| --- | --- |
| `sync_blobs` | batch of pending ciphertext blobs |
| `sync_blob_available` | message, delivery, and device IDs without ciphertext |
| `device_link_request` | request ID and new device ID |
| `device_link_approved` | request ID |

Protocol v2 prohibits plaintext call-signaling events.

## 11. Rate limits

Separate fixed-window limits apply at minimum to authentication, public directory and prekeys,
federation pre-auth, authenticated federation, media, and TURN credentials. A retry response uses
HTTP `429` and must not disclose account existence through policy differences.
