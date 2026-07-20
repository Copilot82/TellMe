# Code and comment style

## 1. General principle

Code should expose invariants through types, module boundaries, and tests. Use a comment for a
reason or constraint that cannot be expressed by the language construct itself.

## 2. Rust

- formatting is enforced by rustfmt;
- `unsafe_code = forbid`;
- Clippy `all`, `pedantic`, `nursery`, and `cargo` groups are denied;
- `unwrap`, `expect`, `panic`, `todo`, `unimplemented`, `dbg!`, and stdout/stderr debugging are prohibited;
- public types and functions receive rustdoc when their contract is not evident from the name;
- error types must not contain secrets or unbounded provider responses;
- repositories accept normalized values and use parameterized SQL.

## 3. Swift

- two-space indentation and one responsibility per type;
- explicit types for nontrivial local values and public signatures;
- dependency injection through initializers and protocols;
- UI state changes at the main actor/thread boundary;
- Keychain, storage, and network abstractions are not replaced with global singletons in tests;
- wire coding strategy is centralized and is not changed locally without a contract test.

## 4. Comments

A useful comment answers at least one of these questions:

- which security or privacy invariant does the code protect;
- why is an obvious simplification incorrect;
- which external compatibility constraint requires the current form;
- why was a particular bound, timeout, or ordering selected;
- what must remain atomic relative to persistence.

Example rationale comment:

```swift
// Ratchet operations return a new state instead of mutating storage so callers decide
// whether decrypted content and the advanced state are persisted atomically.
```

Unhelpful comment:

```swift
// Increment counter by one.
counter += 1
```

## 5. Public contract documentation

A Rustdoc or Swift documentation comment should state:

- purpose;
- important preconditions;
- security-sensitive side effects;
- failure mode when it is not obvious;
- a protocol or ADR reference only when the contract would otherwise be incomplete.

## 6. Review checklist

- Has any comment diverged from the implementation?
- Can a comment be replaced with a more precise name or type?
- Is ordering explained for cryptographic and storage transitions?
- Does an example contain a live domain credential, token, or seed?
- Is the stated invariant covered by a test?
