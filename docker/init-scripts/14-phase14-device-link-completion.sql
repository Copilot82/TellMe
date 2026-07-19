ALTER TABLE device_link_requests
  ADD COLUMN IF NOT EXISTS poll_token_hash VARCHAR(128),
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_link_requests_poll_token_hash
  ON device_link_requests(poll_token_hash)
  WHERE poll_token_hash IS NOT NULL;
