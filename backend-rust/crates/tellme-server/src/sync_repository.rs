//! `PostgreSQL` persistence adapter for REST sync stream.

use crate::auth_service::{ApiError, AuthenticatedSession};
use crate::sync::stream_query;
use crate::sync_service::{SyncBlobRecord, SyncBlobsResponse, SyncStreamRequest};
use sqlx::{PgPool, Row};
use std::convert::TryFrom;

const LIST_PENDING_SYNC_BLOBS_SQL: &str = r#"
SELECT
  id::TEXT AS id,
  owner_account_id::TEXT AS owner_account_id,
  owner_device_id,
  sender_server,
  message_id::TEXT AS message_id,
  delivery_id::TEXT AS delivery_id,
  owner_device_id AS device_id,
  ciphertext_blob,
  ttl_sec::BIGINT AS ttl_sec,
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at,
  CASE
    WHEN acked_at IS NULL THEN NULL
    ELSE to_char(acked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  END AS acked_at,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
FROM mailbox_blobs
WHERE owner_account_id = $1::uuid
  AND owner_device_id = $2
  AND acked_at IS NULL
  AND expires_at > CURRENT_TIMESTAMP
ORDER BY created_at ASC
LIMIT $3
"#;

/// Async `PostgreSQL` repository for REST sync route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresSyncRepository {
    pool: PgPool,
}

impl PostgresSyncRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Lists pending encrypted mailbox blobs for the requested or current device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when query validation or durable storage lookup fails.
    pub async fn stream(
        &self,
        auth: &AuthenticatedSession,
        request: &SyncStreamRequest,
    ) -> Result<SyncBlobsResponse, ApiError> {
        let query = stream_query(request.limit, request.device_id.as_deref(), &auth.device_id)
            .map_err(|_| ApiError::bad_request("Invalid sync stream query"))?;
        let limit = i64::try_from(query.limit).map_err(|_| ApiError::internal())?;
        let rows = sqlx::query(LIST_PENDING_SYNC_BLOBS_SQL)
            .bind(&auth.account_id)
            .bind(&query.device_id)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        let blobs = rows
            .iter()
            .map(|row| {
                Ok(SyncBlobRecord {
                    id: row.try_get("id").map_err(|_| ApiError::internal())?,
                    owner_account_id: row
                        .try_get("owner_account_id")
                        .map_err(|_| ApiError::internal())?,
                    owner_device_id: row
                        .try_get("owner_device_id")
                        .map_err(|_| ApiError::internal())?,
                    sender_server: row
                        .try_get("sender_server")
                        .map_err(|_| ApiError::internal())?,
                    message_id: row
                        .try_get("message_id")
                        .map_err(|_| ApiError::internal())?,
                    delivery_id: row
                        .try_get("delivery_id")
                        .map_err(|_| ApiError::internal())?,
                    device_id: row.try_get("device_id").map_err(|_| ApiError::internal())?,
                    ciphertext_blob: row
                        .try_get("ciphertext_blob")
                        .map_err(|_| ApiError::internal())?,
                    ttl_sec: row.try_get("ttl_sec").map_err(|_| ApiError::internal())?,
                    expires_at: row
                        .try_get("expires_at")
                        .map_err(|_| ApiError::internal())?,
                    acked_at: row.try_get("acked_at").map_err(|_| ApiError::internal())?,
                    created_at: row
                        .try_get("created_at")
                        .map_err(|_| ApiError::internal())?,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;

        Ok(SyncBlobsResponse {
            device_id: query.device_id,
            blobs,
        })
    }
}

#[must_use]
pub const fn sync_repository_query_contract() -> &'static str {
    LIST_PENDING_SYNC_BLOBS_SQL
}

#[cfg(test)]
mod tests {
    use super::sync_repository_query_contract;

    #[test]
    fn stream_query_is_parameterized_and_ciphertext_only() {
        let query = sync_repository_query_contract();

        assert!(query.contains("owner_account_id = $1::uuid"));
        assert!(query.contains("owner_device_id = $2"));
        assert!(query.contains("LIMIT $3"));
        assert!(query.contains("ciphertext_blob"));
        assert!(query.contains("created_at"));
        assert!(!query.contains("{}"));
        assert!(!query.contains("format!("));
    }
}
