//! `PostgreSQL` session-token adapter for authenticated Rust routes.
//!
//! This is the Rust equivalent of the current Express `sessionAuth` middleware: verify the signed JWT locally, hash the
//! bearer token, and only then check the active session table. Raw tokens are never persisted or logged.

use crate::auth_service::{ApiError, AuthenticatedSession};
use crate::session::{bearer_token, token_hash, verify_session_token, TokenConfig, TokenKind};
use sqlx::PgPool;
use std::convert::TryFrom;

const SESSION_TOKEN_ACTIVE_SQL: &str = r"
SELECT EXISTS (
  SELECT 1
  FROM sessions
  WHERE token_hash = $1
    AND revoked_at IS NULL
    AND expires_at > to_timestamp($2::double precision / 1000.0)
) AS active
";

/// Authenticates session bearer tokens against the signed-token and active-token contracts.
#[derive(Debug, Clone)]
pub struct PostgresSessionRepository {
    pool: PgPool,
    token_config: TokenConfig,
}

impl PostgresSessionRepository {
    #[must_use]
    pub const fn new(pool: PgPool, token_config: TokenConfig) -> Self {
        Self { pool, token_config }
    }

    /// Authenticates a bearer token and returns the trusted session claims.
    ///
    /// # Errors
    ///
    /// Returns `401`-shaped `ApiError` when the header, token, or active session lookup is invalid.
    pub async fn authenticate_session(
        &self,
        authorization_header: Option<&str>,
        now_sec: u64,
        now_ms: u64,
    ) -> Result<AuthenticatedSession, ApiError> {
        let Some(token) = authorization_header.and_then(bearer_token) else {
            return Err(ApiError::unauthorized("Unauthorized"));
        };
        self.authenticate_raw_session_token(token, now_sec, now_ms)
            .await
    }

    /// Authenticates a raw Socket.IO handshake session token.
    ///
    /// # Errors
    ///
    /// Returns `401`-shaped `ApiError` when the token or active session lookup is invalid.
    // Socket handshakes reuse this path; durable storage still only receives a token hash.
    pub async fn authenticate_raw_session_token(
        &self,
        token: &str,
        now_sec: u64,
        now_ms: u64,
    ) -> Result<AuthenticatedSession, ApiError> {
        let Some(claims) = verify_session_token(token, &self.token_config, now_sec) else {
            return Err(ApiError::unauthorized("Unauthorized"));
        };
        if claims.token_type() != TokenKind::Session {
            return Err(ApiError::unauthorized("Unauthorized"));
        }
        let active = self
            .session_token_active(&token_hash(token), now_ms)
            .await?;
        if !active {
            return Err(ApiError::unauthorized("Unauthorized"));
        }

        Ok(AuthenticatedSession {
            account_id: claims.account_id().to_owned(),
            user_handle: claims.user_handle().to_owned(),
            device_id: claims.device_id().to_owned(),
            session_id: claims.session_id().to_owned(),
        })
    }

    async fn session_token_active(&self, token_hash: &str, now_ms: u64) -> Result<bool, ApiError> {
        let now_ms = i64::try_from(now_ms).map_err(|_| ApiError::unauthorized("Unauthorized"))?;
        sqlx::query_scalar::<_, bool>(SESSION_TOKEN_ACTIVE_SQL)
            .bind(token_hash)
            .bind(now_ms)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::unauthorized("Unauthorized"))
    }
}

#[must_use]
pub const fn session_repository_query_contract() -> &'static str {
    SESSION_TOKEN_ACTIVE_SQL
}

#[cfg(test)]
mod tests {
    use super::session_repository_query_contract;

    #[test]
    fn active_session_query_uses_token_hash_and_expiry_cutoff() {
        let query = session_repository_query_contract();

        assert!(query.contains("token_hash = $1"));
        assert!(query.contains("revoked_at IS NULL"));
        assert!(query.contains("expires_at > to_timestamp($2::double precision / 1000.0)"));
        assert!(!query.contains("Bearer "));
        assert!(!query.contains("{}"));
    }
}
