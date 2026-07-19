CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

ALTER TABLE device_push_tokens
  ADD COLUMN IF NOT EXISTS push_environment VARCHAR(16) NOT NULL DEFAULT 'sandbox';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.constraint_column_usage
    WHERE table_name = 'device_push_tokens'
      AND constraint_name = 'device_push_tokens_push_environment_check'
  ) THEN
    ALTER TABLE device_push_tokens
      ADD CONSTRAINT device_push_tokens_push_environment_check
      CHECK (push_environment IN ('sandbox', 'production'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_device_env
  ON device_push_tokens(account_id, device_id, push_enabled, push_environment, updated_at DESC);

CREATE TABLE IF NOT EXISTS push_jobs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  owner_device_id VARCHAR(255) NOT NULL,
  from_device_id VARCHAR(255),
  notification_hint VARCHAR(32) NOT NULL DEFAULT 'none',
  message_id UUID NOT NULL,
  delivery_id UUID NOT NULL,
  dedupe_key VARCHAR(255) NOT NULL,
  status VARCHAR(32) NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT push_jobs_notification_hint_check CHECK (notification_hint IN ('none', 'message', 'missed_call')),
  CONSTRAINT push_jobs_status_check CHECK (status IN ('pending', 'sent', 'failed')),
  CONSTRAINT push_jobs_delivery_unique UNIQUE (owner_account_id, owner_device_id, delivery_id)
);

CREATE INDEX IF NOT EXISTS idx_push_jobs_pending
  ON push_jobs(status, next_attempt_at, created_at);

CREATE INDEX IF NOT EXISTS idx_push_jobs_owner_device
  ON push_jobs(owner_account_id, owner_device_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_push_jobs_dedupe
  ON push_jobs(dedupe_key, created_at DESC);

DROP TRIGGER IF EXISTS update_push_jobs_updated_at ON push_jobs;
CREATE TRIGGER update_push_jobs_updated_at
  BEFORE UPDATE ON push_jobs
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
