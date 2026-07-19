-- Phase 16: protocol v2 cutover, device certificates, push privacy modes, and legacy session cleanup

ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS device_certificate_version INTEGER NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS device_certificate_chain JSONB NOT NULL DEFAULT '[]'::jsonb,
  ALTER COLUMN ik_device_signature DROP NOT NULL;

ALTER TABLE device_push_tokens
  ADD COLUMN IF NOT EXISTS push_mode VARCHAR(32) NOT NULL DEFAULT 'privacy_first';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'device_push_tokens_push_mode_check'
  ) THEN
    ALTER TABLE device_push_tokens
      ADD CONSTRAINT device_push_tokens_push_mode_check
      CHECK (push_mode IN ('privacy_first', 'fast_notify'));
  END IF;
END $$;

ALTER TABLE device_link_requests
  ADD COLUMN IF NOT EXISTS dk_sign_pub TEXT,
  ADD COLUMN IF NOT EXISTS dk_dh_pub TEXT,
  ADD COLUMN IF NOT EXISTS approved_device_certificate JSONB;

ALTER TABLE push_jobs
  ADD COLUMN IF NOT EXISTS push_kind VARCHAR(32);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'push_jobs'
      AND column_name = 'sender_user_handle'
  ) THEN
    ALTER TABLE push_jobs
      DROP COLUMN sender_user_handle;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'push_jobs'
      AND column_name = 'notification_hint'
  ) THEN
    ALTER TABLE push_jobs
      DROP COLUMN notification_hint;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'push_jobs_notification_hint_check'
  ) THEN
    ALTER TABLE push_jobs
      DROP CONSTRAINT push_jobs_notification_hint_check;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'push_jobs_push_kind_check'
  ) THEN
    ALTER TABLE push_jobs
      ADD CONSTRAINT push_jobs_push_kind_check
      CHECK (push_kind IS NULL OR push_kind IN ('message', 'call', 'call_missed', 'other'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_device_mode
  ON device_push_tokens(account_id, device_id, push_mode, updated_at DESC);

DELETE FROM sessions;
DELETE FROM refresh_sessions;
DELETE FROM auth_challenges;
DELETE FROM mailbox_blobs;
DELETE FROM outbox_jobs;
DELETE FROM push_jobs;
DELETE FROM device_link_requests;
DELETE FROM device_link_sessions;
