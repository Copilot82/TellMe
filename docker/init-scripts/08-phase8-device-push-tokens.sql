-- Phase 8 extension: device push token registry for federated API

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS device_push_tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  device_type VARCHAR(32) NOT NULL DEFAULT 'ios',
  token VARCHAR(1024) NOT NULL,
  device_name TEXT,
  os_version VARCHAR(128),
  app_version VARCHAR(128),
  push_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(account_id, token)
);

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_account
  ON device_push_tokens(account_id, device_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_enabled
  ON device_push_tokens(account_id, push_enabled, updated_at DESC);

DROP TRIGGER IF EXISTS update_device_push_tokens_updated_at ON device_push_tokens;
CREATE TRIGGER update_device_push_tokens_updated_at
  BEFORE UPDATE ON device_push_tokens
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
