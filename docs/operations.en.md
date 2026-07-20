# Operations model

## 1. Purpose

This document defines the runtime contract without production IP addresses, SSH aliases, or
credentials. `compose.production.yml` provides the reproducible single-node topology; the
[deployment guide](deployment.md) contains the installation procedure. Deployment-specific
addresses and secrets remain outside Git.

## 2. Runtime components

| Component | Responsibility | Persistent data |
| --- | --- | --- |
| Rust server | HTTP/WebSocket, migrations, workers | no local state |
| PostgreSQL | account, device, mailbox, and job metadata | yes |
| Redis | presence and realtime coordination | limited |
| MinIO/S3 | media ciphertext | yes |
| TLS proxy | TLS termination and HTTP routing | certificates outside the repository |
| coturn | STUN/TURN relay | ephemeral allocations |
| APNs | remote wake provider | external service |

## 3. Configuration

Production configuration is supplied only through environment or secret files outside Git.
Required secrets have no production-safe fallback:

- session and refresh signing secrets;
- federation-signing private key;
- TURN shared secret;
- MinIO credentials;
- APNs `.p8` or base64-encoded key material.

`SERVER_DOMAIN`, public URLs, and limits belong to the runtime contract but are not secrets.

## 4. Startup sequence

1. Infrastructure dependencies reach healthy state.
2. The server loads and validates the environment.
3. The PostgreSQL pool connects with bounded retry.
4. Pending migrations run from the fixed list.
5. The HTTP listener starts accepting traffic.
6. The worker scheduler starts only when `TELLME_RUST_WORKERS_ENABLED=true`.

Missing mandatory configuration must produce an explicit startup failure, never a partially
protected runtime.

## 5. Health and readiness

- `/health` confirms process operation and a stable wire response;
- `/ready` is the current runtime readiness endpoint;
- an external monitor additionally checks the TLS route and a dependency-backed smoke path.

Process health does not prove that every protocol domain is ready. Release validation must include
database migration and at least one authenticated contract smoke.

## 6. Workers

Outbox, push, and cleanup jobs are reserved with a claim token and timestamp. Another worker must
not process an active claim before its TTL expires. Provider failures are classified as retryable
or terminal; error details are bounded and contain no payload or credential.

Media cleanup deletes object ciphertext before metadata. If object-storage deletion fails,
metadata remains available for retry so the orphan object is not lost from tracking.

## 7. Deployment and rollback

Production deployment should be atomic at the application-image boundary:

1. build a candidate from a specific commit;
2. start the candidate against current external state;
3. run health, readiness, and contract smoke checks;
4. switch the active service;
5. promote the image only after successful validation;
6. restore the previous image after failure.

A database migration must remain backward-compatible with the previous application image or have
a separately documented irreversible gate. A destructive migration must not run implicitly during
an ordinary restart.

## 8. Observability

Recommended metrics:

- HTTP requests by route, status, and latency without a user handle;
- active WebSocket sessions and reconnect rate;
- pending, expired, and acknowledged mailbox counts;
- outbox/push queue age and retry count;
- media-upload verdict and rejection category;
- database-pool saturation;
- worker-cycle duration;
- federation request status by domain without payload.

Logs use correlation, job, and delivery IDs but do not include complete message ciphertext. The
security logging policy is defined in `threat-model.md`.

## 9. Backup and recovery

Backup scope includes PostgreSQL and media-ciphertext storage. Redis presence may be reconstructed
as ephemeral state. A backup does not improve confidentiality: it contains the same routing
metadata and ciphertext, so encryption at rest, access control, and retention remain mandatory.

A recovery exercise must verify:

- restoration of schema migrations;
- consistency between media metadata and objects;
- no replay of terminal jobs;
- continued client sync using existing session and device records.

## 10. Incident priorities

1. Leaked provider or server-signing private key: rotate and revoke immediately.
2. Plaintext exposure: stop the affected route and begin coordinated disclosure.
3. Device trust or authentication failure: revoke sessions and devices, then analyze the protocol.
4. Ciphertext or availability loss: stop destructive workers and begin recovery.
5. Metadata exposure: restrict access, review retention, and notify under the applicable policy.
