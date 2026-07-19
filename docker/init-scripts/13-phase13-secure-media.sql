ALTER TABLE media_objects
  ADD COLUMN IF NOT EXISTS download_capability_hash VARCHAR(128),
  ADD COLUMN IF NOT EXISTS origin_server VARCHAR(255),
  ADD COLUMN IF NOT EXISTS signer_user_handle VARCHAR(255),
  ADD COLUMN IF NOT EXISTS signer_device_id VARCHAR(255),
  ADD COLUMN IF NOT EXISTS attestation_signature TEXT,
  ADD COLUMN IF NOT EXISTS ciphertext_size BIGINT,
  ADD COLUMN IF NOT EXISTS uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS scan_verdict VARCHAR(20),
  ADD COLUMN IF NOT EXISTS risk_flags JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS scanner_version INTEGER,
  ADD COLUMN IF NOT EXISTS rules_version INTEGER,
  ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

UPDATE media_objects
SET origin_server = COALESCE(origin_server, '')
WHERE origin_server IS NULL;

UPDATE media_objects
SET status = 'rejected',
    rejection_reason = COALESCE(rejection_reason, 'legacy_media_requires_secure_rescan'),
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'uploaded';

ALTER TABLE media_objects
  DROP CONSTRAINT IF EXISTS media_objects_status_check;

ALTER TABLE media_objects
  ADD CONSTRAINT media_objects_status_check
  CHECK (status IN ('pending', 'uploaded_verified', 'rejected', 'deleted'));

CREATE INDEX IF NOT EXISTS idx_media_capability_lookup
  ON media_objects(id, download_capability_hash, status, expires_at);

CREATE INDEX IF NOT EXISTS idx_media_expiry_cleanup
  ON media_objects(status, expires_at, updated_at DESC);
