//! Redis-backed realtime presence boundary for the Socket.IO-compatible sync runtime.
//!
//! This adapter mirrors the current TypeScript Redis key contract while keeping message payloads in `PostgreSQL` as
//! opaque ciphertext. It does not persist conversation membership or plaintext call state.

use crate::auth_service::{AuthenticatedSession, StoreError};
use crate::sync::{
    account_sessions_key, device_active_chat_key, device_offline_override_key, device_sessions_key,
    DEFAULT_OFFLINE_OVERRIDE_TTL_SEC, DEFAULT_SYNC_LIMIT,
};
use crate::sync_service::{SocketPresenceContext, SyncBlobRecord, SyncBlobsResponse};
use redis::aio::MultiplexedConnection;
use redis::AsyncCommands;
use sqlx::{PgPool, Row};
use std::env;

const DEFAULT_REDIS_URL: &str = "redis://localhost:6379";
const ONLINE_ACCOUNTS_KEY: &str = "online_accounts";
const DEPRECATED_ACTIVE_CHAT_PATTERN: &str = "device_active_chat:*";
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

/// Redis realtime configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedisSyncConfig {
    redis_url: String,
}

impl RedisSyncConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            redis_url: env::var("REDIS_URL").unwrap_or_else(|_| DEFAULT_REDIS_URL.to_owned()),
        }
    }

    #[must_use]
    pub const fn new(redis_url: String) -> Self {
        Self { redis_url }
    }

    #[must_use]
    pub fn redis_url(&self) -> &str {
        &self.redis_url
    }
}

/// Async Redis/PostgreSQL repository for realtime sync state.
#[derive(Debug)]
pub struct RedisSyncRepository {
    pool: PgPool,
    redis: MultiplexedConnection,
}

impl RedisSyncRepository {
    /// Connects to Redis using the current runtime config.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis URL parsing or connection establishment fails.
    pub async fn connect(pool: PgPool, config: &RedisSyncConfig) -> Result<Self, StoreError> {
        let client = redis::Client::open(config.redis_url()).map_err(|_| StoreError)?;
        let redis = client
            .get_multiplexed_async_connection()
            .await
            .map_err(|_| StoreError)?;

        Ok(Self { pool, redis })
    }

    #[must_use]
    pub const fn new(pool: PgPool, redis: MultiplexedConnection) -> Self {
        Self { pool, redis }
    }

    /// Handles connect-time presence side effects.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis cannot persist the presence state.
    pub async fn open_connection(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), StoreError> {
        let active_chat = device_active_chat_key(&auth.account_id, &auth.device_id);

        let _: usize = self.redis.del(&active_chat).await.map_err(|_| StoreError)?;
        self.touch_presence(auth, context).await
    }

    /// Lists pending encrypted mailbox blobs for a device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when `PostgreSQL` cannot be queried.
    pub async fn list_pending(
        &self,
        account_id: &str,
        device_id: &str,
        limit: u64,
    ) -> Result<Vec<SyncBlobRecord>, StoreError> {
        let limit = i64::try_from(limit).map_err(|_| StoreError)?;
        let rows = sqlx::query(LIST_PENDING_SYNC_BLOBS_SQL)
            .bind(account_id)
            .bind(device_id)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| StoreError)?;

        rows.iter().map(sync_blob_from_row).collect()
    }

    /// Handles the connect-time presence side effects and returns pending blobs for `sync_subscribe`.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis or `PostgreSQL` side effects fail.
    pub async fn subscribe(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<SyncBlobsResponse, StoreError> {
        self.touch_presence(auth, context).await?;
        let blobs = self
            .list_pending(&auth.account_id, &auth.device_id, DEFAULT_SYNC_LIMIT)
            .await?;

        Ok(SyncBlobsResponse {
            device_id: auth.device_id.clone(),
            blobs,
        })
    }

    /// Handles `sync_pull` and returns pending encrypted blobs.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis or `PostgreSQL` side effects fail.
    pub async fn pull(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
        limit: u64,
    ) -> Result<SyncBlobsResponse, StoreError> {
        self.touch_presence(auth, context).await?;
        let blobs = self
            .list_pending(&auth.account_id, &auth.device_id, limit)
            .await?;

        Ok(SyncBlobsResponse {
            device_id: auth.device_id.clone(),
            blobs,
        })
    }

    /// Touches Socket.IO presence with the same Redis keys as the TypeScript backend.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis cannot persist the presence state.
    pub async fn touch_presence(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), StoreError> {
        let account_sessions = account_sessions_key(&auth.account_id);
        let device_sessions = device_sessions_key(&auth.account_id, &auth.device_id);
        let offline_override = device_offline_override_key(&auth.account_id, &auth.device_id);

        let _: usize = self
            .redis
            .del(&offline_override)
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self
            .redis
            .sadd(ONLINE_ACCOUNTS_KEY, &auth.account_id)
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self
            .redis
            .hset(&account_sessions, &context.socket_id, &context.timestamp)
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self
            .redis
            .hset(&device_sessions, &context.socket_id, &context.timestamp)
            .await
            .map_err(|_| StoreError)?;

        Ok(())
    }

    /// Sets the short offline override and clears active presence.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis cannot persist the offline state.
    pub async fn set_offline_override_and_clear(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), StoreError> {
        let offline_override = device_offline_override_key(&auth.account_id, &auth.device_id);
        let active_chat = device_active_chat_key(&auth.account_id, &auth.device_id);

        let _: () = self
            .redis
            .set_ex(
                &offline_override,
                &context.timestamp,
                DEFAULT_OFFLINE_OVERRIDE_TTL_SEC,
            )
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self.redis.del(&active_chat).await.map_err(|_| StoreError)?;
        self.clear_presence(auth, context).await
    }

    /// Clears Socket.IO presence and prunes empty account/device session keys.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when Redis cannot clear the presence state.
    pub async fn clear_presence(
        &mut self,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), StoreError> {
        let account_sessions = account_sessions_key(&auth.account_id);
        let device_sessions = device_sessions_key(&auth.account_id, &auth.device_id);
        let active_chat = device_active_chat_key(&auth.account_id, &auth.device_id);

        let _: usize = self
            .redis
            .hdel(&account_sessions, &context.socket_id)
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self
            .redis
            .hdel(&device_sessions, &context.socket_id)
            .await
            .map_err(|_| StoreError)?;
        let _: usize = self.redis.del(&active_chat).await.map_err(|_| StoreError)?;

        let account_remaining: usize = self
            .redis
            .hlen(&account_sessions)
            .await
            .map_err(|_| StoreError)?;
        if account_remaining == 0 {
            let _: usize = self
                .redis
                .srem(ONLINE_ACCOUNTS_KEY, &auth.account_id)
                .await
                .map_err(|_| StoreError)?;
            let _: usize = self
                .redis
                .del(&account_sessions)
                .await
                .map_err(|_| StoreError)?;
        }

        let device_remaining: usize = self
            .redis
            .hlen(&device_sessions)
            .await
            .map_err(|_| StoreError)?;
        if device_remaining == 0 {
            let _: usize = self
                .redis
                .del(&device_sessions)
                .await
                .map_err(|_| StoreError)?;
        }

        Ok(())
    }
}

fn sync_blob_from_row(row: &sqlx::postgres::PgRow) -> Result<SyncBlobRecord, StoreError> {
    Ok(SyncBlobRecord {
        id: row.try_get("id").map_err(|_| StoreError)?,
        owner_account_id: row.try_get("owner_account_id").map_err(|_| StoreError)?,
        owner_device_id: row.try_get("owner_device_id").map_err(|_| StoreError)?,
        sender_server: row.try_get("sender_server").map_err(|_| StoreError)?,
        message_id: row.try_get("message_id").map_err(|_| StoreError)?,
        delivery_id: row.try_get("delivery_id").map_err(|_| StoreError)?,
        device_id: row.try_get("device_id").map_err(|_| StoreError)?,
        ciphertext_blob: row.try_get("ciphertext_blob").map_err(|_| StoreError)?,
        ttl_sec: row.try_get("ttl_sec").map_err(|_| StoreError)?,
        expires_at: row.try_get("expires_at").map_err(|_| StoreError)?,
        acked_at: row.try_get("acked_at").map_err(|_| StoreError)?,
        created_at: row.try_get("created_at").map_err(|_| StoreError)?,
    })
}

#[must_use]
pub const fn redis_sync_repository_query_contract() -> &'static str {
    LIST_PENDING_SYNC_BLOBS_SQL
}

#[must_use]
pub const fn online_accounts_key() -> &'static str {
    ONLINE_ACCOUNTS_KEY
}

#[must_use]
pub const fn deprecated_active_chat_pattern() -> &'static str {
    DEPRECATED_ACTIVE_CHAT_PATTERN
}

#[cfg(test)]
mod tests {
    use super::{
        deprecated_active_chat_pattern, online_accounts_key, redis_sync_repository_query_contract,
        RedisSyncConfig, DEFAULT_REDIS_URL,
    };
    use crate::sync::{
        account_sessions_key, device_active_chat_key, device_offline_override_key,
        device_sessions_key,
    };

    #[test]
    fn redis_config_defaults_to_current_compose_contract() {
        let config = RedisSyncConfig::new(DEFAULT_REDIS_URL.to_owned());

        assert_eq!(config.redis_url(), "redis://localhost:6379");
    }

    #[test]
    fn presence_keys_match_typescript_socket_contract() {
        assert_eq!(online_accounts_key(), "online_accounts");
        assert_eq!(deprecated_active_chat_pattern(), "device_active_chat:*");
        assert_eq!(account_sessions_key("acc-a"), "account_sessions:acc-a");
        assert_eq!(
            device_sessions_key("acc-a", "dev-a"),
            "device_sessions:acc-a:dev-a"
        );
        assert_eq!(
            device_active_chat_key("acc-a", "dev-a"),
            "device_active_chat:acc-a:dev-a"
        );
        assert_eq!(
            device_offline_override_key("acc-a", "dev-a"),
            "device_offline:acc-a:dev-a"
        );
    }

    #[test]
    fn pending_blob_query_is_parameterized_and_ciphertext_only() {
        let query = redis_sync_repository_query_contract();

        assert!(query.contains("owner_account_id = $1::uuid"));
        assert!(query.contains("owner_device_id = $2"));
        assert!(query.contains("LIMIT $3"));
        assert!(query.contains("ciphertext_blob"));
        assert!(query.contains("created_at"));
        assert!(!query.contains("{}"));
        assert!(!query.contains("format!("));
    }
}
