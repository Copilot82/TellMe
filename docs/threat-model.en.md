# Threat model

## 1. Purpose

This document records the security claims of TellMe protocol v2. It describes intended system
properties and does not replace an independent implementation audit.

## 2. Protected assets

| Asset | Required property |
| --- | --- |
| Message plaintext | confidentiality and integrity between devices |
| Attachment plaintext and media key | confidentiality outside the device |
| Account/device private keys | never leave a trusted device in plaintext |
| Ratchet state | confidentiality and rollback resistance within the local-storage model |
| Call signaling | end-to-end confidentiality and integrity |
| Session/refresh token | protected from database disclosure and reuse after revocation |
| Device trust graph | a device cannot be added silently without trusted approval |
| Federation identity | a trusted server request cannot be forged |

## 3. Adversary capabilities

The model includes an adversary who can:

1. passively observe traffic outside the TLS endpoint;
2. read the database, object storage, and application logs;
3. fully control the backend after compromise;
4. send arbitrary HTTP, WebSocket, and federation requests;
5. control one revoked or compromised device;
6. attempt to substitute a public key during discovery;
7. replay, delay, delete, or reorder ciphertext deliveries.

The following are not treated as fully solved:

- compromise of an unlocked device with access to process memory;
- an operating-system, CryptoKit, or WebRTC vulnerability;
- global network-traffic analysis;
- coercing a user to approve malicious device linking;
- denial of service by a backend under adversarial control.

## 4. Security invariants

### SI-1. Server-blind content

The backend never receives a key capable of decrypting a message body, attachment, or call
signaling. Any new server field containing plaintext or an E2E symmetric key violates this
invariant.

### SI-2. Per-device encryption

A delivery targets one device. A revoked device is excluded from subsequent fan-out. A shared
payload key is acceptable only when each device receives an independently protected wrapper.

### SI-3. Authentication without a password-equivalent server secret

Login uses a challenge-response signature from an active device key. Session and refresh tokens
are stored as hashes with expiry and revocation state.

### SI-4. Key continuity

A device certificate is verified against the account identity or a trusted certificate chain. An
identity change must not be accepted as a routine update without a visible user signal.

### SI-5. Ciphertext-only media

Object storage receives ciphertext. The capability is stored only as a hash, while the media key
remains inside an encrypted payload.

### SI-6. Privacy-first push

An APNs payload may state that synchronization is required, but contains no sender, conversation,
message text, or plaintext call identifier.

## 5. Threats and mitigations

| Threat | Potential impact | Implemented control | Residual risk |
| --- | --- | --- | --- |
| PostgreSQL disclosure | metadata and ciphertext disclosure | no private keys; token hashes only | traffic graph and timestamps remain visible |
| MinIO disclosure | attachment copying | client-side encryption | size and timing metadata |
| Server MITM during key discovery | substitute a future device | device signatures, certificates, verification UI | no key-transparency log |
| Delivery replay | duplicate message | delivery ID, ratchet counter, acknowledgement state | DoS and delay remain possible |
| Stolen refresh token | session takeover | rotation, hashes, revocation, expiry | an active token remains valid until detected |
| Malicious federation peer | spam or forged delivery | request signatures, trust state, rate limits | trust onboarding requires operator policy |
| Push-payload disclosure | provider metadata leak | opaque payload | device token and wake timing remain visible |
| TURN operator | IP metadata | ephemeral credentials, E2E signaling | relay observes endpoints and traffic volume |
| Oversized or out-of-order message | resource exhaustion | validation bounds, skip window, rate limits | distributed DoS is not fully eliminated |
| Malicious attachment | local viewer exploitation | inspection, blocked types, ciphertext hash | viewer or OS zero-day |

## 6. Backend compromise

A backend under adversarial control can:

- stop, delay, delete, or duplicate deliveries;
- collect routing metadata;
- return stale or substituted public bundles;
- block revocation and linking requests;
- control availability events and push timing.

Server state must not provide:

- message, file, or call plaintext;
- account or device private keys;
- ratchet root, chain, or message keys;
- media keys;
- the ability to create a valid account or device signature.

Protection against active substitution during key discovery is incomplete without key
transparency. Verified peer state and an identity-change warning are therefore mandatory user
boundaries rather than optional convenience features.

## 7. Logging policy

Production logs must not contain:

- an Authorization header or session/refresh token;
- a registration/link code or poll token;
- a complete private or public key bundle;
- a ciphertext blob or media capability;
- an APNs token or provider key;
- a decrypted payload or seed phrase.

Bounded error categories, routes, statuses, durations, worker job IDs, and aggregated counters are
permitted. User handles and IP addresses are logged only for a justified operational requirement
and with limited retention.

## 8. Model verification

Every security invariant must have at least one negative test. CI also runs dependency audits and
prohibitive lints. Independent protocol review and external penetration testing remain separate
gates for production-grade use.
