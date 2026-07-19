-- Phase 8: Federated server-blind E2E (hard cutover)

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TABLE IF NOT EXISTS accounts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_handle VARCHAR(255) NOT NULL UNIQUE,
  home_server VARCHAR(255) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS account_settings (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  allow_search BOOLEAN NOT NULL DEFAULT TRUE,
  allow_requests BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS identity_keys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  ik_sign_pub TEXT NOT NULL,
  ik_dh_pub TEXT NOT NULL,
  proof_signature TEXT NOT NULL,
  proof_timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS devices (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  dk_sign_pub TEXT NOT NULL,
  dk_dh_pub TEXT NOT NULL,
  ik_device_signature TEXT NOT NULL,
  state VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'revoked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  revoked_at TIMESTAMPTZ,
  UNIQUE(account_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_devices_account_state ON devices(account_id, state, created_at DESC);

CREATE TABLE IF NOT EXISTS signed_prekeys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  prekey_id VARCHAR(255) NOT NULL,
  signed_prekey_pub TEXT NOT NULL,
  signature TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMPTZ,
  UNIQUE(account_id, device_id)
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  prekey_id VARCHAR(255) NOT NULL,
  prekey_pub TEXT NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(account_id, device_id, prekey_id)
);

CREATE INDEX IF NOT EXISTS idx_one_time_prekeys_available ON one_time_prekeys(account_id, device_id, created_at)
WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS auth_challenges (
  challenge_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255),
  nonce TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_auth_challenges_lookup ON auth_challenges(account_id, challenge_id, expires_at);

CREATE TABLE IF NOT EXISTS sessions (
  session_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  token_hash VARCHAR(128) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sessions_active ON sessions(account_id, device_id, expires_at)
WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS refresh_sessions (
  refresh_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id VARCHAR(255) NOT NULL,
  token_hash VARCHAR(128) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  replaced_by_hash VARCHAR(128),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_refresh_sessions_active ON refresh_sessions(account_id, device_id, expires_at)
WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS mailbox_blobs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  owner_device_id VARCHAR(255) NOT NULL,
  sender_server VARCHAR(255) NOT NULL,
  message_id UUID NOT NULL,
  delivery_id UUID NOT NULL,
  ciphertext_blob TEXT NOT NULL,
  envelope JSONB NOT NULL DEFAULT '{}'::jsonb,
  ttl_sec INTEGER NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  acked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(owner_account_id, owner_device_id, delivery_id)
);

CREATE INDEX IF NOT EXISTS idx_mailbox_pending ON mailbox_blobs(owner_account_id, owner_device_id, created_at)
WHERE acked_at IS NULL;

CREATE TABLE IF NOT EXISTS outbox_jobs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  to_server VARCHAR(255) NOT NULL,
  payload JSONB NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_outbox_dispatch ON outbox_jobs(status, next_attempt_at, created_at);

CREATE TABLE IF NOT EXISTS federation_servers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  domain VARCHAR(255) NOT NULL UNIQUE,
  key_id VARCHAR(255) NOT NULL,
  server_sign_pub TEXT NOT NULL,
  trust_state VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (trust_state IN ('active', 'blocked')),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS federation_receipts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_server VARCHAR(255) NOT NULL,
  message_id UUID NOT NULL,
  delivery_id UUID NOT NULL,
  status VARCHAR(20) NOT NULL CHECK (status IN ('accepted', 'acked', 'rejected')),
  detail TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(from_server, delivery_id, status)
);

CREATE INDEX IF NOT EXISTS idx_federation_receipts_delivery ON federation_receipts(from_server, delivery_id, created_at DESC);

CREATE TABLE IF NOT EXISTS device_link_sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  old_device_id VARCHAR(255) NOT NULL,
  link_code_hash VARCHAR(128) NOT NULL UNIQUE,
  l_dh_pub TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_link_sessions_active ON device_link_sessions(account_id, old_device_id, expires_at)
WHERE approved_at IS NULL;

CREATE TABLE IF NOT EXISTS device_link_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id UUID NOT NULL REFERENCES device_link_sessions(id) ON DELETE CASCADE,
  user_handle VARCHAR(255) NOT NULL,
  new_device_id VARCHAR(255) NOT NULL,
  n_dh_pub TEXT NOT NULL,
  encrypted_provisioning_blob TEXT,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'expired', 'rejected')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_link_requests_session_status ON device_link_requests(session_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS media_objects (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  mime_hint VARCHAR(255),
  size_hint BIGINT,
  storage_bucket VARCHAR(255) NOT NULL,
  storage_key TEXT NOT NULL,
  hash_ciphertext VARCHAR(128),
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'uploaded', 'deleted')),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(storage_bucket, storage_key)
);

CREATE INDEX IF NOT EXISTS idx_media_owner_status ON media_objects(owner_account_id, status, created_at DESC);

DROP TRIGGER IF EXISTS update_accounts_updated_at ON accounts;
CREATE TRIGGER update_accounts_updated_at
  BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_account_settings_updated_at ON account_settings;
CREATE TRIGGER update_account_settings_updated_at
  BEFORE UPDATE ON account_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_outbox_jobs_updated_at ON outbox_jobs;
CREATE TRIGGER update_outbox_jobs_updated_at
  BEFORE UPDATE ON outbox_jobs
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_federation_servers_updated_at ON federation_servers;
CREATE TRIGGER update_federation_servers_updated_at
  BEFORE UPDATE ON federation_servers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_link_requests_updated_at ON device_link_requests;
CREATE TRIGGER update_link_requests_updated_at
  BEFORE UPDATE ON device_link_requests
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_media_objects_updated_at ON media_objects;
CREATE TRIGGER update_media_objects_updated_at
  BEFORE UPDATE ON media_objects
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
