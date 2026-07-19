ALTER TABLE push_jobs
  ADD COLUMN IF NOT EXISTS sender_user_handle VARCHAR(255);

CREATE INDEX IF NOT EXISTS idx_push_jobs_sender_hint
  ON push_jobs(owner_account_id, owner_device_id, sender_user_handle, notification_hint, created_at DESC);
