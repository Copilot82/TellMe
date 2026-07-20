# ADR-0003: Rust/Axum as the primary backend runtime

Status: accepted

Date: 2026-07-06

## Context

The backend handles boundary-sensitive parsing, signatures, token and session state, worker claims,
and media and federation transports. Type errors, unchecked optionals, or uncontrolled panics make
protocol invariants harder to preserve.

## Decision

The primary server runtime uses Rust 2021 with Axum, Tokio, SQLx, and Serde. The workspace forbids
unsafe code and enables strict Clippy groups. Types and an executable route checklist define the
wire contract.

## Consequences

Positive:

- compile-time ownership and concurrency checks;
- typed request/response and repository boundaries;
- one binary artifact;
- strict error policy without a runtime dependency manager.

Negative:

- changes cost more for developers without Rust experience;
- `lib.rs` temporarily remains a large composition and adapter layer;
- some ecosystem integrations require a project-owned implementation.

## Verification

- CI runs `cargo fmt`, Clippy, and 220 unit tests;
- `cargo audit` and `cargo deny` validate dependencies and licenses;
- contract tests cover migrations and routes required by iOS.
