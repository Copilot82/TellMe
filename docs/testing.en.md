# Testing strategy

## 1. Objective

Tests must prove both the happy path and preservation of privacy and security invariants. Every
change starts with the smallest fast set and then runs the release gate for the affected platform.

## 2. Test matrix

| Layer | Tool | Scope | Frequency |
| --- | --- | --- | --- |
| Rust unit | `cargo test` | parsing, validation, services, SQL builders, protocol contract | every change |
| Rust lint | rustfmt/Clippy | style, prohibited constructs, public API | every change |
| Dependencies | audit/deny | advisories, licenses, sources | every change/Dependabot |
| iOS unit | XCTest | services, crypto state, view models, networking | every change |
| iOS UI smoke | XCUITest | critical screens and accessibility contract | main/release |
| Headless E2E | Swift Package | account, device, and message flows without UI | every change |
| Physical E2E | XCUITest and scripts | APNs, CallKit, camera, PiP, background | release candidate |
| Operational smoke | containers/health | migrations, startup, rollback boundary | release |
| Public install smoke | Docker Compose | clean published install, TLS, TURN TCP/UDP | deployment-contract change |

## 3. Rust tests

Backend unit tests live beside implementation modules. This layout tests private validation helpers
without expanding the production API.

Primary categories:

- authentication challenge, signature, and token rotation;
- device certificate, linking, and revocation;
- one-time-prekey consumption;
- ciphertext-only message and mailbox SQL;
- media capability, attestation, and object signing;
- canonical federation signature;
- Socket.IO codec and rejection of plaintext call events;
- worker claim, retry, and deduplication;
- migration ordering and schema contract;
- rate-limit bounds and enumeration resistance.

Commands:

```bash
cd backend-rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo audit
cargo deny check
```

`cargo deny` may warn about multiple transitive versions. A new duplicate is accepted only when the
dependency graph is understood and no advisory or license issue exists.

## 4. iOS unit tests

The `messengerTests` target uses protocol-based doubles and in-memory secure stores. Tests must not
depend on the production API or real Keychain access except at explicitly isolated integration
boundaries.

```bash
xcodebuild test \
  -project messenger/messenger.xcodeproj \
  -scheme messenger \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -only-testing:messengerTests
```

Keychain tests require normal Simulator code signing. `CODE_SIGNING_ALLOWED=NO` is valid for a
build smoke but not for the complete unit suite.

## 5. UI and physical-device tests

UI tests are divided into:

- deterministic smoke tests with synthetic state;
- physical regressions using a real backend, APNs, CallKit, and two devices.

Physical-test runtime configuration contains disposable handles and seed phrases, so
`dual_iphone_runtime_config.json` is always excluded from Git. Test sources read values only from
the environment or configuration file and skip a scenario when mandatory parameters are absent.

A physical run must retain:

- `.xcresult` from both devices;
- sanitized JSONL diagnostics;
- screenshots of critical phases;
- scenario identifier and final pass/fail summary;
- a server health and log window without credentials.

## 6. Security-oriented cases

Minimum negative coverage:

- invalid registration, device, or federation signature;
- expired or reused challenge;
- revoked device or session;
- modified certificate parent;
- repeated use of a consumed one-time prekey;
- message targeting another device or account;
- media upload with an invalid capability, hash, or attestation;
- plaintext call event over WebSocket;
- oversized batch, TTL, or ratchet skip window;
- push payload containing prohibited identity fields.

## 7. Coverage

Code coverage is a diagnostic signal, not a release gate by percentage alone. A negative case for a
security-critical branch is more valuable than a broad increase in line coverage.

iOS coverage is enabled in the shared `ProductionCalls.xctestplan`. CI preserves `.xcresult` after
a failed run so review is not limited to the console tail.

## 8. Release gates

A release candidate is validated when:

1. Rust fmt, Clippy, tests, audit, and deny pass;
2. the iOS unit suite passes on the pinned Xcode/iOS runtime;
3. the documentation site builds in strict mode, local links resolve, and the Russian and English
   structures remain synchronized;
4. secret scanning finds no credential in reachable history;
5. local Compose starts with clean volumes;
6. affected physical scenarios have fresh evidence;
7. limitations and skipped tests appear in release notes.

## 9. Published-instruction verification

`scripts/remote-public-install-smoke.sh` copies only the public installation contract into a new
temporary directory on a remote Linux server. It assigns a separate project name, ports, and
volumes, so it never reuses data from an existing installation. The script verifies:

- production-environment validation;
- backend-image build and startup of the complete Compose stack;
- automatic issuance of a local Caddy TLS certificate;
- `/health`, `/api/config`, and migration application;
- authenticated TURN relay over UDP and TCP;
- absence of unhealthy containers;
- removal of test containers, volumes, and the temporary directory.

Run only on a dedicated Linux host with Docker:

```bash
TELLME_REMOTE_SSH_HOST=<ssh-alias> \
  bash scripts/remote-public-install-smoke.sh
```

To validate the user path specifically, repeat the commands from **Local backend** in the root
`README.en.md` from a clean directory. Record the result and limitations in release notes. A passing
internal production health check does not replace this run.

## 10. Flaky-test policy

A flaky test is not disabled without recorded technical rationale. Classify the source first:

- race or leaked state;
- Simulator or Keychain signing;
- network or provider dependency;
- physical-device transport;
- incorrect timeout;
- test-data collision.

An acceptable fix removes the nondeterminism or moves an external dependency to an explicit
integration gate. Increasing a timeout without measuring the missing event is insufficient.
