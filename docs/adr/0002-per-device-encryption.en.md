# ADR-0002: Per-device encryption

Status: accepted

Date: 2026-07-02

## Context

Encryption to an account-level public key cannot revoke one device independently and does not
provide separate ratchet state for each endpoint. Adding a second device must not give the backend
the account's shared private key.

## Decision

Each device owns distinct signing and DH keys, a device certificate, prekeys, and ratchet sessions.
The sender retrieves the active device bundles and creates a separate delivery for every target
device. An existing trusted device approves device linking.

## Consequences

Positive:

- revocation removes a device from subsequent deliveries;
- compromise of one device key does not expose another device's private material;
- self-sync uses the same encrypted delivery mechanism.

Negative:

- fan-out increases the number of ciphertext deliveries;
- the client stores multiple sessions for one user;
- linking and revocation require a dedicated trust UX;
- a missing device bundle causes incomplete synchronization until the bundle list is refreshed.

## Verification

- the device service validates certificate chain and state;
- prekey lookup returns a bundle per device;
- message-service fan-out excludes revoked devices;
- XCTest covers linking, revocation, and session bootstrap.
