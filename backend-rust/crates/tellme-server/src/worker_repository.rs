//! `PostgreSQL` persistence adapter for background worker job queues.
//!
//! This module only claims and updates durable work. APNs delivery, federation HTTP transport, and object-store
//! ciphertext deletion remain explicit runtime boundaries owned by worker services.

use crate::devices::{PushMode, PushTokenKind};
use crate::messages::{DeliveryUnit, PushKind, WakeupClass};
use crate::worker_service::{
    ExpiredMediaObject, OutboxJobRecord, PushJobRecord, PushTokenRecord, WorkerError,
};
use crate::workers::{resolve_push_environment, PushEnvironment};
use serde::Deserialize;
use sqlx::postgres::PgRow;
use sqlx::{PgPool, Row};

const RESERVE_PUSH_JOBS_SQL: &str = r"
WITH claimable AS (
  SELECT id
  FROM push_jobs
  WHERE (
    status = 'pending'
    AND next_attempt_at <= CURRENT_TIMESTAMP
  ) OR (
    status = 'processing'
    AND (
      claimed_at IS NULL
      OR claimed_at <= CURRENT_TIMESTAMP - concat($2::text, ' seconds')::interval
    )
  )
  ORDER BY created_at ASC
  LIMIT $1
  FOR UPDATE SKIP LOCKED
)
UPDATE push_jobs
SET status = 'processing',
    claimed_at = CURRENT_TIMESTAMP,
    claim_token = $3::uuid,
    updated_at = CURRENT_TIMESTAMP
WHERE id IN (SELECT id FROM claimable)
RETURNING
  id::TEXT AS id,
  claim_token::TEXT AS claim_token,
  owner_account_id::TEXT AS owner_account_id,
  owner_device_id,
  from_device_id,
  message_id::TEXT AS message_id,
  delivery_id::TEXT AS delivery_id,
  push_kind,
  wakeup_class,
  attempts
";

const MARK_PUSH_SENT_SQL: &str = r"
UPDATE push_jobs
SET status = 'sent',
    last_error = $3,
    claimed_at = NULL,
    claim_token = NULL,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
  AND claim_token = $2::uuid
  AND status = 'processing'
";

const MARK_PUSH_FAILED_SQL: &str = r"
UPDATE push_jobs
SET attempts = attempts + 1,
    next_attempt_at = CURRENT_TIMESTAMP + concat($3::text, ' seconds')::interval,
    last_error = $4,
    claimed_at = NULL,
    claim_token = NULL,
    updated_at = CURRENT_TIMESTAMP,
    status = CASE WHEN attempts + 1 >= 10 THEN 'failed' ELSE 'pending' END
WHERE id = $1::uuid
  AND claim_token = $2::uuid
  AND status = 'processing'
";

const RESERVE_OUTBOX_JOBS_SQL: &str = r"
WITH claimable AS (
  SELECT id
  FROM outbox_jobs
  WHERE (
    status = 'pending'
    AND next_attempt_at <= CURRENT_TIMESTAMP
  ) OR (
    status = 'processing'
    AND (
      claimed_at IS NULL
      OR claimed_at <= CURRENT_TIMESTAMP - concat($2::text, ' seconds')::interval
    )
  )
  ORDER BY created_at ASC
  LIMIT $1
  FOR UPDATE SKIP LOCKED
)
UPDATE outbox_jobs
SET status = 'processing',
    claimed_at = CURRENT_TIMESTAMP,
    claim_token = $3::uuid,
    updated_at = CURRENT_TIMESTAMP
WHERE id IN (SELECT id FROM claimable)
RETURNING
  id::TEXT AS id,
  claim_token::TEXT AS claim_token,
  to_server,
  attempts,
  payload::TEXT AS payload
";

const MARK_OUTBOX_SENT_SQL: &str = r"
UPDATE outbox_jobs
SET status = 'sent',
    claimed_at = NULL,
    claim_token = NULL,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
  AND claim_token = $2::uuid
  AND status = 'processing'
";

const MARK_OUTBOX_FAILED_SQL: &str = r"
UPDATE outbox_jobs
SET attempts = attempts + 1,
    next_attempt_at = CURRENT_TIMESTAMP + concat($3::text, ' seconds')::interval,
    last_error = $4,
    claimed_at = NULL,
    claim_token = NULL,
    updated_at = CURRENT_TIMESTAMP,
    status = CASE WHEN attempts + 1 >= 10 THEN 'failed' ELSE 'pending' END
WHERE id = $1::uuid
  AND claim_token = $2::uuid
  AND status = 'processing'
";

const HAS_PENDING_DELIVERY_SQL: &str = r"
SELECT 1
FROM mailbox_blobs
WHERE owner_account_id = $1::uuid
  AND owner_device_id = $2
  AND delivery_id = $3::uuid
  AND acked_at IS NULL
  AND expires_at > CURRENT_TIMESTAMP
LIMIT 1
";

const LIST_ENABLED_PUSH_TOKENS_SQL: &str = r"
SELECT token, push_environment, push_mode, token_kind
FROM device_push_tokens
WHERE account_id = $1::uuid
  AND device_id = $2
  AND push_enabled = TRUE
ORDER BY updated_at DESC, created_at DESC
";

const UPDATE_PUSH_ENVIRONMENT_SQL: &str = r"
UPDATE device_push_tokens
SET push_environment = $3,
    updated_at = CURRENT_TIMESTAMP
WHERE account_id = $1::uuid
  AND token = $2
";

const DELETE_PUSH_TOKEN_SQL: &str = r"
DELETE FROM device_push_tokens
WHERE account_id = $1::uuid
  AND token = $2
";

const LIST_EXPIRED_MEDIA_SQL: &str = r"
SELECT id::TEXT AS id, status, storage_bucket, storage_key
FROM media_objects
WHERE (expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP)
   OR status IN ('rejected', 'deleted')
ORDER BY updated_at ASC
LIMIT $1
";

const DELETE_MEDIA_METADATA_SQL: &str = r"
DELETE FROM media_objects
WHERE id::TEXT = ANY($1)
";

const CLEANUP_EXPIRED_MAILBOX_SQL: &str = r"
DELETE FROM mailbox_blobs
WHERE expires_at <= CURRENT_TIMESTAMP OR acked_at IS NOT NULL
";

/// Async `PostgreSQL` repository for worker queues and cleanup metadata.
#[derive(Debug, Clone)]
pub struct PostgresWorkerRepository {
    pool: PgPool,
}

impl PostgresWorkerRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Claims pending or stale push jobs for one worker token.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot reserve jobs.
    pub async fn reserve_push_jobs(
        &self,
        limit: i64,
        claim_token: &str,
        claim_ttl_sec: i64,
    ) -> Result<Vec<PushJobRecord>, WorkerError> {
        let mut transaction = self.pool.begin().await.map_err(|_| WorkerError)?;
        let rows = sqlx::query(RESERVE_PUSH_JOBS_SQL)
            .bind(limit)
            .bind(claim_ttl_sec)
            .bind(claim_token)
            .fetch_all(&mut *transaction)
            .await
            .map_err(|_| WorkerError)?;
        transaction.commit().await.map_err(|_| WorkerError)?;

        rows.iter().map(push_job_from_row).collect()
    }

    /// Marks a claimed push job sent.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    pub async fn mark_push_sent(
        &self,
        job_id: &str,
        claim_token: &str,
        outcome: Option<&str>,
    ) -> Result<(), WorkerError> {
        sqlx::query(MARK_PUSH_SENT_SQL)
            .bind(job_id)
            .bind(claim_token)
            .bind(outcome.map(|value| truncate_chars(value, 4_000)))
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Marks a claimed push job failed with retry state.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    pub async fn mark_push_failed(
        &self,
        job_id: &str,
        claim_token: &str,
        retry_delay_sec: u64,
        error: &str,
    ) -> Result<(), WorkerError> {
        sqlx::query(MARK_PUSH_FAILED_SQL)
            .bind(job_id)
            .bind(claim_token)
            .bind(delay_for_sql(retry_delay_sec)?)
            .bind(truncate_chars(error, 4_000))
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Claims pending or stale federation outbox jobs for one worker token.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot reserve jobs.
    pub async fn reserve_outbox_jobs(
        &self,
        limit: i64,
        claim_token: &str,
        claim_ttl_sec: i64,
    ) -> Result<Vec<OutboxJobRecord>, WorkerError> {
        let mut transaction = self.pool.begin().await.map_err(|_| WorkerError)?;
        let rows = sqlx::query(RESERVE_OUTBOX_JOBS_SQL)
            .bind(limit)
            .bind(claim_ttl_sec)
            .bind(claim_token)
            .fetch_all(&mut *transaction)
            .await
            .map_err(|_| WorkerError)?;
        transaction.commit().await.map_err(|_| WorkerError)?;

        rows.iter().map(outbox_job_from_row).collect()
    }

    /// Marks a claimed outbox job sent.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    pub async fn mark_outbox_sent(
        &self,
        job_id: &str,
        claim_token: &str,
    ) -> Result<(), WorkerError> {
        sqlx::query(MARK_OUTBOX_SENT_SQL)
            .bind(job_id)
            .bind(claim_token)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Marks a claimed outbox job failed with retry state.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    pub async fn mark_outbox_failed(
        &self,
        job_id: &str,
        claim_token: &str,
        retry_delay_sec: u64,
        error: &str,
    ) -> Result<(), WorkerError> {
        sqlx::query(MARK_OUTBOX_FAILED_SQL)
            .bind(job_id)
            .bind(claim_token)
            .bind(delay_for_sql(retry_delay_sec)?)
            .bind(truncate_chars(error, 4_000))
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Checks whether a mailbox delivery still needs a push wake.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    pub async fn has_pending_delivery(
        &self,
        account_id: &str,
        device_id: &str,
        delivery_id: &str,
    ) -> Result<bool, WorkerError> {
        sqlx::query(HAS_PENDING_DELIVERY_SQL)
            .bind(account_id)
            .bind(device_id)
            .bind(delivery_id)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.is_some())
            .map_err(|_| WorkerError)
    }

    /// Lists enabled push tokens for one device.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    pub async fn list_enabled_push_tokens(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Vec<PushTokenRecord>, WorkerError> {
        let rows = sqlx::query(LIST_ENABLED_PUSH_TOKENS_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| WorkerError)?;

        rows.iter().map(push_token_from_row).collect()
    }

    /// Persists a discovered APNs environment for a token.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the token.
    pub async fn update_push_environment(
        &self,
        account_id: &str,
        token: &str,
        environment: PushEnvironment,
    ) -> Result<(), WorkerError> {
        sqlx::query(UPDATE_PUSH_ENVIRONMENT_SQL)
            .bind(account_id)
            .bind(token)
            .bind(environment.as_wire())
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Deletes an invalid push token.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot delete the token.
    pub async fn delete_push_token(
        &self,
        account_id: &str,
        token: &str,
    ) -> Result<(), WorkerError> {
        sqlx::query(DELETE_PUSH_TOKEN_SQL)
            .bind(account_id)
            .bind(token)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| WorkerError)
    }

    /// Lists expired media metadata rows that need cleanup.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    pub async fn list_expired_media(
        &self,
        limit: i64,
    ) -> Result<Vec<ExpiredMediaObject>, WorkerError> {
        let rows = sqlx::query(LIST_EXPIRED_MEDIA_SQL)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| WorkerError)?;

        rows.iter().map(expired_media_from_row).collect()
    }

    /// Deletes media metadata rows after the object-store boundary has succeeded or was not required.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot delete metadata.
    pub async fn delete_media_metadata(&self, ids: &[String]) -> Result<usize, WorkerError> {
        if ids.is_empty() {
            return Ok(0);
        }

        let result = sqlx::query(DELETE_MEDIA_METADATA_SQL)
            .bind(ids)
            .execute(&self.pool)
            .await
            .map_err(|_| WorkerError)?;
        usize::try_from(result.rows_affected()).map_err(|_| WorkerError)
    }

    /// Deletes expired or already acknowledged mailbox blobs.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot delete rows.
    pub async fn cleanup_expired_mailbox(&self) -> Result<usize, WorkerError> {
        let result = sqlx::query(CLEANUP_EXPIRED_MAILBOX_SQL)
            .execute(&self.pool)
            .await
            .map_err(|_| WorkerError)?;
        usize::try_from(result.rows_affected()).map_err(|_| WorkerError)
    }
}

#[derive(Debug, Clone, Deserialize)]
struct OutboxPayload {
    #[serde(default)]
    deliveries: Vec<DeliveryUnit>,
}

fn push_job_from_row(row: &PgRow) -> Result<PushJobRecord, WorkerError> {
    Ok(PushJobRecord {
        id: row.try_get("id").map_err(|_| WorkerError)?,
        claim_token: row.try_get("claim_token").map_err(|_| WorkerError)?,
        owner_account_id: row.try_get("owner_account_id").map_err(|_| WorkerError)?,
        owner_device_id: row.try_get("owner_device_id").map_err(|_| WorkerError)?,
        from_device_id: row.try_get("from_device_id").map_err(|_| WorkerError)?,
        message_id: row.try_get("message_id").map_err(|_| WorkerError)?,
        delivery_id: row.try_get("delivery_id").map_err(|_| WorkerError)?,
        push_kind: push_kind_from_wire(
            row.try_get::<Option<String>, _>("push_kind")
                .map_err(|_| WorkerError)?
                .as_deref(),
        )?,
        wakeup_class: wakeup_class_from_wire(
            row.try_get::<String, _>("wakeup_class")
                .map_err(|_| WorkerError)?
                .as_str(),
        )?,
        attempts: row
            .try_get::<i32, _>("attempts")
            .map_err(|_| WorkerError)?
            .try_into()
            .map_err(|_| WorkerError)?,
    })
}

fn outbox_job_from_row(row: &PgRow) -> Result<OutboxJobRecord, WorkerError> {
    let payload = row
        .try_get::<String, _>("payload")
        .map_err(|_| WorkerError)?;
    let parsed = serde_json::from_str::<OutboxPayload>(&payload).map_err(|_| WorkerError)?;

    Ok(OutboxJobRecord {
        id: row.try_get("id").map_err(|_| WorkerError)?,
        claim_token: row.try_get("claim_token").map_err(|_| WorkerError)?,
        to_server: row.try_get("to_server").map_err(|_| WorkerError)?,
        attempts: row
            .try_get::<i32, _>("attempts")
            .map_err(|_| WorkerError)?
            .try_into()
            .map_err(|_| WorkerError)?,
        deliveries: parsed.deliveries,
    })
}

fn push_token_from_row(row: &PgRow) -> Result<PushTokenRecord, WorkerError> {
    let environment = row
        .try_get::<String, _>("push_environment")
        .map_err(|_| WorkerError)?;
    let mode = row
        .try_get::<String, _>("push_mode")
        .map_err(|_| WorkerError)?;
    let token_kind = row
        .try_get::<String, _>("token_kind")
        .map_err(|_| WorkerError)?;

    Ok(PushTokenRecord {
        token: row.try_get("token").map_err(|_| WorkerError)?,
        push_environment: resolve_push_environment(Some(&environment)),
        push_mode: push_mode_from_wire(&mode),
        token_kind: push_token_kind_from_wire(&token_kind),
    })
}

fn expired_media_from_row(row: &PgRow) -> Result<ExpiredMediaObject, WorkerError> {
    Ok(ExpiredMediaObject {
        id: row.try_get("id").map_err(|_| WorkerError)?,
        status: row.try_get("status").map_err(|_| WorkerError)?,
        storage_bucket: row.try_get("storage_bucket").map_err(|_| WorkerError)?,
        storage_key: row.try_get("storage_key").map_err(|_| WorkerError)?,
    })
}

const fn push_mode_from_wire(value: &str) -> PushMode {
    match value.as_bytes() {
        b"fast_notify" => PushMode::FastNotify,
        _ => PushMode::PrivacyFirst,
    }
}

const fn push_token_kind_from_wire(value: &str) -> PushTokenKind {
    match value.as_bytes() {
        b"voip" => PushTokenKind::Voip,
        _ => PushTokenKind::Alert,
    }
}

const fn push_kind_from_wire(value: Option<&str>) -> Result<Option<PushKind>, WorkerError> {
    let Some(value) = value else {
        return Ok(None);
    };
    match value.as_bytes() {
        b"message" => Ok(Some(PushKind::Message)),
        b"call" => Ok(Some(PushKind::Call)),
        b"call_missed" => Ok(Some(PushKind::CallMissed)),
        b"other" => Ok(Some(PushKind::Other)),
        _ => Err(WorkerError),
    }
}

const fn wakeup_class_from_wire(value: &str) -> Result<WakeupClass, WorkerError> {
    match value.as_bytes() {
        b"generic" => Ok(WakeupClass::Generic),
        b"voip_opaque" => Ok(WakeupClass::VoipOpaque),
        _ => Err(WorkerError),
    }
}

fn delay_for_sql(delay_sec: u64) -> Result<i64, WorkerError> {
    i64::try_from(delay_sec).map_err(|_| WorkerError)
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[must_use]
pub const fn worker_repository_query_contract() -> &'static [&'static str] {
    &[
        RESERVE_PUSH_JOBS_SQL,
        MARK_PUSH_SENT_SQL,
        MARK_PUSH_FAILED_SQL,
        RESERVE_OUTBOX_JOBS_SQL,
        MARK_OUTBOX_SENT_SQL,
        MARK_OUTBOX_FAILED_SQL,
        HAS_PENDING_DELIVERY_SQL,
        LIST_ENABLED_PUSH_TOKENS_SQL,
        UPDATE_PUSH_ENVIRONMENT_SQL,
        DELETE_PUSH_TOKEN_SQL,
        LIST_EXPIRED_MEDIA_SQL,
        DELETE_MEDIA_METADATA_SQL,
        CLEANUP_EXPIRED_MAILBOX_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        push_kind_from_wire, push_mode_from_wire, push_token_kind_from_wire, truncate_chars,
        wakeup_class_from_wire, worker_repository_query_contract, CLEANUP_EXPIRED_MAILBOX_SQL,
        DELETE_MEDIA_METADATA_SQL, HAS_PENDING_DELIVERY_SQL, LIST_ENABLED_PUSH_TOKENS_SQL,
        MARK_OUTBOX_FAILED_SQL, MARK_PUSH_FAILED_SQL, RESERVE_OUTBOX_JOBS_SQL,
        RESERVE_PUSH_JOBS_SQL,
    };
    use crate::devices::{PushMode, PushTokenKind};
    use crate::messages::{PushKind, WakeupClass};

    #[test]
    fn worker_queries_are_parameterized_and_claim_with_skip_locked() {
        for query in worker_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(RESERVE_PUSH_JOBS_SQL.contains("FOR UPDATE SKIP LOCKED"));
        assert!(RESERVE_OUTBOX_JOBS_SQL.contains("FOR UPDATE SKIP LOCKED"));
        assert!(RESERVE_PUSH_JOBS_SQL.contains("claim_token = $3::uuid"));
        assert!(RESERVE_OUTBOX_JOBS_SQL.contains("claim_token = $3::uuid"));
        assert!(MARK_PUSH_FAILED_SQL.contains("attempts + 1 >= 10"));
        assert!(MARK_OUTBOX_FAILED_SQL.contains("attempts + 1 >= 10"));
        assert!(HAS_PENDING_DELIVERY_SQL.contains("acked_at IS NULL"));
        assert!(CLEANUP_EXPIRED_MAILBOX_SQL.contains("acked_at IS NOT NULL"));
        assert!(LIST_ENABLED_PUSH_TOKENS_SQL.contains("push_enabled = TRUE"));
        assert!(DELETE_MEDIA_METADATA_SQL.contains("id::TEXT = ANY($1)"));
    }

    #[test]
    fn parses_worker_wire_enums_and_truncates_errors_on_char_boundary() {
        assert_eq!(push_mode_from_wire("fast_notify"), PushMode::FastNotify);
        assert_eq!(push_mode_from_wire("privacy_first"), PushMode::PrivacyFirst);
        assert_eq!(push_token_kind_from_wire("voip"), PushTokenKind::Voip);
        assert_eq!(push_token_kind_from_wire("alert"), PushTokenKind::Alert);
        assert_eq!(push_kind_from_wire(None), Ok(None));
        assert_eq!(
            push_kind_from_wire(Some("call_missed")),
            Ok(Some(PushKind::CallMissed))
        );
        assert_eq!(
            wakeup_class_from_wire("voip_opaque"),
            Ok(WakeupClass::VoipOpaque)
        );
        assert_eq!(push_kind_from_wire(Some("bad")), Err(super::WorkerError));
        assert_eq!(wakeup_class_from_wire("bad"), Err(super::WorkerError));
        assert_eq!(truncate_chars("абвг", 3), "абв");
    }
}
