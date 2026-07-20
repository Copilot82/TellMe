# ADR-0004: Realtime is not the source of truth

Status: accepted

Date: 2026-07-06

## Context

A mobile WebSocket disconnects during background transitions, network changes, and power saving.
If message delivery depends on a successful realtime event, a disconnect causes data loss or
requires complex replay logic.

## Decision

The PostgreSQL mailbox is the source of truth for pending ciphertext. WebSocket sends availability
events and may return a sync batch, but the client can always restore state through REST sync. APNs
also communicates only that synchronization is required.

## Consequences

Positive:

- disconnects do not lose deliveries;
- REST and realtime share one mailbox contract;
- push payloads contain no message plaintext;
- acknowledgement remains explicit and idempotent.

Negative:

- a reconnect or push may cause an extra REST pull;
- presence is eventually consistent;
- the UI must deduplicate deliveries by ID.

## Verification

- realtime events contain no ciphertext or body;
- the reconnect controller starts mailbox synchronization;
- every target mailbox has unique delivery IDs;
- offline and presence tests do not create server-side conversation state.
