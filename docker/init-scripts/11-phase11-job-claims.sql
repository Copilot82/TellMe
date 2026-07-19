CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

ALTER TABLE push_jobs
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS claim_token UUID;

ALTER TABLE outbox_jobs
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS claim_token UUID;

ALTER TABLE push_jobs
  DROP CONSTRAINT IF EXISTS push_jobs_status_check;

ALTER TABLE push_jobs
  ADD CONSTRAINT push_jobs_status_check
  CHECK (status IN ('pending', 'processing', 'sent', 'failed'));

ALTER TABLE outbox_jobs
  DROP CONSTRAINT IF EXISTS outbox_jobs_status_check;

ALTER TABLE outbox_jobs
  ADD CONSTRAINT outbox_jobs_status_check
  CHECK (status IN ('pending', 'processing', 'sent', 'failed'));

CREATE INDEX IF NOT EXISTS idx_push_jobs_claimable
  ON push_jobs(status, next_attempt_at, claimed_at, created_at);

CREATE INDEX IF NOT EXISTS idx_outbox_jobs_claimable
  ON outbox_jobs(status, next_attempt_at, claimed_at, created_at);
