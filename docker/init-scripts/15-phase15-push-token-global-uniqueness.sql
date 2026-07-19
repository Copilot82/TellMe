-- Phase 15 extension: a single APNS token must belong to only one active account/device

WITH ranked_tokens AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY token
      ORDER BY updated_at DESC, last_used_at DESC, created_at DESC, id DESC
    ) AS row_number
  FROM device_push_tokens
)
DELETE FROM device_push_tokens
WHERE id IN (
  SELECT id
  FROM ranked_tokens
  WHERE row_number > 1
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'device_push_tokens_account_id_token_key'
  ) THEN
    ALTER TABLE device_push_tokens
      DROP CONSTRAINT device_push_tokens_account_id_token_key;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'device_push_tokens_token_key'
  ) THEN
    ALTER TABLE device_push_tokens
      ADD CONSTRAINT device_push_tokens_token_key UNIQUE (token);
  END IF;
END $$;
