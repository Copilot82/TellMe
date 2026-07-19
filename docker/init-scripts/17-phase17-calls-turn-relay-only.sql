-- Phase 17: privacy-first calls transport routing.
-- Keep call wake routing opaque: backend/APNs may see the wake class, never call metadata.

ALTER TABLE device_push_tokens
  ADD COLUMN IF NOT EXISTS token_kind VARCHAR(32) NOT NULL DEFAULT 'alert';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'device_push_tokens_token_kind_check'
  ) THEN
    ALTER TABLE device_push_tokens
      ADD CONSTRAINT device_push_tokens_token_kind_check
      CHECK (token_kind IN ('alert', 'voip'));
  END IF;
END $$;

ALTER TABLE push_jobs
  ADD COLUMN IF NOT EXISTS wakeup_class VARCHAR(32) NOT NULL DEFAULT 'generic';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'push_jobs_wakeup_class_check'
  ) THEN
    ALTER TABLE push_jobs
      ADD CONSTRAINT push_jobs_wakeup_class_check
      CHECK (wakeup_class IN ('generic', 'voip_opaque'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_device_kind
  ON device_push_tokens(account_id, device_id, token_kind, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_push_jobs_wakeup_class
  ON push_jobs(wakeup_class, status, next_attempt_at, created_at);
