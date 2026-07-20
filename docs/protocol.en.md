# TellMe protocol v2

## 1. Terminology

| Term | Meaning |
| --- | --- |
| Account identity | long-lived Ed25519/X25519 account identity |
| Device identity | independent signing/DH identity for one device |
| Device certificate | signed binding between device keys and the account identity or a trusted device |
| Signed prekey | medium-lived X25519 public key signed by the device |
| One-time prekey | single-use X25519 public key for initial agreement |
| Ratchet session | local root, chain, and counter state for a device pair |
| Routing envelope | delivery fields visible to the server |
| Encrypted payload | header and body available only to participants |

Wire fields use `snake_case`. A user handle is normalized to `@login:domain`.

## 2. Key material

On the first device, the client creates a seed and derives account and device key material. Private
values are never sent to the backend. The server receives:

- `ik_sign_pub`, `ik_dh_pub`;
- `dk_sign_pub`, `dk_dh_pub`;
- registration proof;
- device certificate chain;
- a signed prekey and one-time prekeys.

Private values are stored in account-scoped Keychain storage. Ratchet state and the local archive
are likewise never synchronized as plaintext server state.

## 3. Registration and login

### Registration

1. The client creates a canonical registration payload containing the user handle, public identity
   keys, and timestamp.
2. The account signing key signs the payload.
3. The backend verifies timestamp skew, signature, and identity uniqueness.
4. The first device certificate is verified against the account identity.
5. The backend creates account and device records and issues a session/refresh pair.

A repeated registration is valid only for the same account and device contract. Changing keys for
an existing account is not treated as an ordinary retry.

### Login

```text
client -> POST /api/auth/start  { user_handle, device_id }
server -> challenge_id, nonce, expires_at
client -> POST /api/auth/finish { challenge_id, device_id, signature }
server -> session_token, refresh_token
```

The nonce is single-use and time-bounded. Only an active registered device may finish login. The
refresh token rotates; logout or revocation marks the corresponding server session inactive.

## 4. Prekeys and initial E2E agreement

A device publishes one signed prekey and a set of one-time prekeys. Unless the request is a `peek`,
the backend atomically returns and consumes a one-time prekey.

For the initial message, the initiator calculates X25519 shared secrets:

```text
DH1 = DH(IK_A, SPK_B)
DH2 = DH(EK_A, IK_B)
DH3 = DH(EK_A, SPK_B)
DH4 = DH(EK_A, OPK_B)  // when an OPK is present
```

The combined material is passed to HKDF-SHA256 with protocol-specific `info`. The output creates
the initial root and chain state. The first message contains only the public bootstrap fields
required for the recipient to derive the same secret.

The design follows the structure of X3DH but does not claim formal Signal Protocol compatibility
and has not undergone independent review.

## 5. Double Ratchet

Each device pair stores independent state:

- `root_key`;
- sending and receiving chain keys;
- sending and receiving counters;
- local and remote ratchet public keys;
- a bounded cache of skipped message keys.

For every message, the chain KDF produces a message key and the next chain key. An old chain key is
never reused. A changed remote ratchet public key triggers a DH ratchet and creates new receiving
and sending chains.

The skip window is limited to 128 messages. This prevents an attacker-controlled index from causing
unbounded skipped-key allocation in client memory. A reused or excessively old index is rejected.

## 6. Message format

The backend receives a delivery with these field categories:

```text
message_id, delivery_id
target user/server/device
ttl
ciphertext_blob
opaque push routing class
```

`ciphertext_blob` contains the protocol version, envelope kind, session ID, public ratchet or
bootstrap fields, and two AEAD ciphertext values: encrypted header and encrypted body. Body
authenticated data binds the protocol version, kind, session ID, and header to prevent envelope
component substitution.

Message content, conversation semantics, attachment keys, and call signaling are inside the
encrypted body.

## 7. Per-device fan-out

The sender retrieves bundles for all active recipient devices and creates a separate delivery for
each one. Secondary devices belonging to the sender receive a self-sync copy through the same
mechanism.

The backend does not construct a plaintext membership list. It resolves target devices from account
and device records while excluding revoked state.

## 8. Synchronization and acknowledgement

The mailbox is a queue of encrypted blobs, not message history:

1. REST `GET /api/sync/stream` or `sync_pull` returns pending blobs;
2. realtime `sync_blob_available` reports only that a new record exists;
3. the client decrypts the blob and persists local state;
4. `POST /api/messages/ack` acknowledges delivery for the current device;
5. TTL and cleanup remove expired server records.

Acknowledgement is sent after successful local processing. A WebSocket event does not replace REST
sync and may be lost without losing data.

## 9. Device linking

1. A trusted device creates a short-lived link session and QR payload.
2. The new device submits an ephemeral DH public key and its device public keys.
3. The trusted device receives the request through REST/realtime, verifies the user, and signs a
   device certificate.
4. Provisioning data is encrypted to the ephemeral shared secret.
5. The new device completes linking with a one-time poll token.

The backend stores only hashes of the link code and poll token. Approval never sends the account
private key in plaintext.

## 10. Attachments

The client generates a random media key, encrypts the file locally, and computes a ciphertext hash.
The backend issues a media ID and capability, accepts ciphertext with device attestation, and stores
only a hash of the capability.

The encrypted message payload carries the media ID, origin server, media key, hashes, and required
metadata. The recipient verifies the ciphertext hash before decryption and applies local inspection
policy before opening the file.

## 11. Calls

Offer, answer, ICE candidates, and call state are encoded as E2E message payloads. Legacy plaintext
Socket.IO events `call_offer`, `call_ice_candidate`, and `call_media_state` are explicitly rejected.

The backend issues short-lived TURN credentials without user, peer, conversation, or call
identifiers. An opaque VoIP wake asks the device to synchronize its mailbox without exposing call
metadata in the APNs payload.

## 12. Federation

A server-to-server request contains a key ID, timestamp, body hash, and signature over the canonical
request. The recipient verifies the known server key and trust state, timestamp, and signature
before domain processing.

Remote delivery does not authorize the sending server to read a mailbox or perform user-session
operations. Rate limits are separated for pre-auth discovery and authenticated federation traffic.

## 13. Versioning

A protocol-breaking change requires:

- a new version field or an explicitly documented hard cutover;
- updated iOS/backend contract tests;
- a migration plan for local ratchet state and server schema;
- a dedicated ADR;
- an updated threat model.
