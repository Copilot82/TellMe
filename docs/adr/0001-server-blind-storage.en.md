# ADR-0001: Server-blind storage

Status: accepted

Date: 2026-07-02

## Context

The messenger backend must support offline delivery, device fan-out, media upload, and push wake.
Storing plaintext history would simplify server-side features, but a backend compromise would then
expose every conversation.

## Decision

The backend stores the routing envelope separately from the encrypted payload. Clients encrypt the
message body, internal conversation metadata, attachment key, and call signaling. Server-side
storage contains only public key material, per-device mailbox ciphertext, media ciphertext, and
the minimum routing fields.

## Consequences

Positive:

- reading PostgreSQL or MinIO does not reveal message or file plaintext;
- a federation server does not receive another domain's keys;
- server backups do not contain decrypted conversation history.

Negative:

- content-based server search and moderation are unavailable;
- some metadata remains visible for routing;
- deletion of an already delivered message depends on the client;
- key and history recovery are more complex.

## Verification

- repository tests assert that mailbox and push queries contain no plaintext fields;
- the wire contract has no legacy plaintext call routes;
- media downloads return ciphertext only;
- the threat model enumerates the permitted server-visible fields.
