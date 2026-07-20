# Architecture Decision Records

An ADR records a decision that affects multiple components or changes a long-lived contract. An
accepted ADR is not rewritten retroactively: a later decision receives a new document and
explicitly supersedes the earlier one.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-server-blind-storage.md) | accepted | server-blind storage and routing envelope |
| [0002](0002-per-device-encryption.md) | accepted | independent encryption per device |
| [0003](0003-rust-backend.md) | accepted | Rust/Axum as the primary backend runtime |
| [0004](0004-realtime-is-not-source-of-truth.md) | accepted | realtime as a mailbox-sync accelerator |

## Template

```text
# ADR-NNNN: Short decision

Status: proposed | accepted | superseded | rejected
Date: YYYY-MM-DD

## Context
## Decision
## Consequences
## Verification
```
