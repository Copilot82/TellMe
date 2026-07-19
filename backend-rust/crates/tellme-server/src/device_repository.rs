//! `PostgreSQL` persistence adapter for session-authenticated device routes.

use crate::auth::DeviceCertificate;
use crate::auth_service::{ApiError, AuthenticatedSession};
use crate::device_service::{
    validate_push_token_update, validate_push_token_upsert, CurrentDeviceRecord,
    DeviceAccountRecord, DeviceRegisterRequest, DeviceRevokeRequest, DeviceRouteRecord,
    PushTokenListResponse, PushTokenRecord, PushTokenUpdate, PushTokenUpsert,
};
use crate::devices::{
    effective_push_mode, effective_push_token_kind, revoke_signature_valid,
    validate_device_registration, DeviceRegistrationInput, PushMode, PushTokenKind,
};
use sqlx::{PgPool, Row};

const FIND_ACCOUNT_IDENTITY_SQL: &str = r"
SELECT a.user_handle, i.ik_sign_pub AS account_sign_pub
FROM accounts a
JOIN identity_keys i ON i.account_id = a.id
WHERE a.id = $1::uuid
";

const UPSERT_DEVICE_SQL: &str = r"
INSERT INTO devices (
  account_id,
  device_id,
  dk_sign_pub,
  dk_dh_pub,
  device_certificate_version,
  device_certificate_chain
)
VALUES ($1::uuid, $2, $3, $4, 2, $5::jsonb)
ON CONFLICT (account_id, device_id)
DO UPDATE SET
  dk_sign_pub = EXCLUDED.dk_sign_pub,
  dk_dh_pub = EXCLUDED.dk_dh_pub,
  device_certificate_version = EXCLUDED.device_certificate_version,
  device_certificate_chain = EXCLUDED.device_certificate_chain,
  state = 'active',
  revoked_at = NULL
RETURNING device_id, dk_sign_pub, dk_dh_pub, state, device_certificate_chain::TEXT AS device_certificate_chain
";

const FIND_CURRENT_DEVICE_SQL: &str = r"
SELECT dk_sign_pub, state
FROM devices
WHERE account_id = $1::uuid
  AND device_id = $2
";

const REVOKE_DEVICE_SQL: &str = r"
UPDATE devices
SET state = 'revoked',
    revoked_at = CURRENT_TIMESTAMP
WHERE account_id = $1::uuid
  AND device_id = $2
  AND state != 'revoked'
RETURNING device_id, dk_sign_pub, dk_dh_pub, state, device_certificate_chain::TEXT AS device_certificate_chain
";

const PUSH_TOKEN_RETURNING_SQL: &str = r#"
id::TEXT AS id,
account_id::TEXT AS user_id,
device_type,
token,
device_name,
os_version,
app_version,
push_enabled,
push_environment,
push_mode,
token_kind,
to_char(last_used_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS last_used_at,
to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
"#;

const UPSERT_PUSH_TOKEN_SQL: &str = r"
INSERT INTO device_push_tokens (
  account_id,
  device_id,
  device_type,
  token,
  device_name,
  os_version,
  app_version,
  push_enabled,
  push_environment,
  push_mode,
  token_kind,
  last_used_at
)
VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, CURRENT_TIMESTAMP)
ON CONFLICT (token)
DO UPDATE SET
  account_id = EXCLUDED.account_id,
  device_id = EXCLUDED.device_id,
  device_type = EXCLUDED.device_type,
  device_name = EXCLUDED.device_name,
  os_version = EXCLUDED.os_version,
  app_version = EXCLUDED.app_version,
  push_enabled = EXCLUDED.push_enabled,
  push_environment = EXCLUDED.push_environment,
  push_mode = EXCLUDED.push_mode,
  token_kind = EXCLUDED.token_kind,
  last_used_at = CURRENT_TIMESTAMP
RETURNING
";

const LIST_PUSH_TOKENS_SQL: &str = r"
SELECT
";

const LIST_PUSH_TOKENS_FROM_SQL: &str = r"
FROM device_push_tokens
WHERE account_id = $1::uuid
ORDER BY updated_at DESC, created_at DESC
";

const UPDATE_PUSH_ENABLED_SQL: &str = r"
UPDATE device_push_tokens
SET push_enabled = $3,
    last_used_at = CURRENT_TIMESTAMP
WHERE account_id = $1::uuid
  AND token = $2
RETURNING
";

const UPDATE_PUSH_MODE_SQL: &str = r"
UPDATE device_push_tokens
SET push_mode = $3,
    last_used_at = CURRENT_TIMESTAMP
WHERE account_id = $1::uuid
  AND token = $2
RETURNING
";

const UPDATE_PUSH_TOKEN_KIND_SQL: &str = r"
UPDATE device_push_tokens
SET token_kind = $3,
    last_used_at = CURRENT_TIMESTAMP
WHERE account_id = $1::uuid
  AND token = $2
RETURNING
";

const DELETE_PUSH_TOKEN_SQL: &str = r"
DELETE FROM device_push_tokens
WHERE account_id = $1::uuid
  AND token = $2
";

/// Async `PostgreSQL` repository for device route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresDeviceRepository {
    pool: PgPool,
}

impl PostgresDeviceRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Registers or reactivates an additional account device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the authenticated account is missing, the certificate chain is invalid, or storage fails.
    pub async fn register(
        &self,
        auth: &AuthenticatedSession,
        request: &DeviceRegisterRequest,
        now_ms: u64,
    ) -> Result<DeviceRouteRecord, ApiError> {
        let account = self
            .find_account_identity(&auth.account_id)
            .await?
            .ok_or_else(|| ApiError::not_found("Account not found"))?;

        validate_device_registration(&DeviceRegistrationInput {
            account_handle: account.user_handle(),
            account_sign_pub: account.account_sign_pub(),
            device_keys: &request.device_pub_keys,
            certificate_chain: &request.device_certificate_chain,
            now_ms,
        })
        .map_err(|_| ApiError::unauthorized("Invalid device certificate chain"))?;

        self.upsert_device(&auth.account_id, request).await
    }

    /// Revokes one device after current-device signature verification.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when signature verification, device lookup, or storage update fails.
    pub async fn revoke(
        &self,
        auth: &AuthenticatedSession,
        request: &DeviceRevokeRequest,
    ) -> Result<DeviceRouteRecord, ApiError> {
        let current = self
            .find_current_device(&auth.account_id, &auth.device_id)
            .await?;
        let Some(current) = current.filter(CurrentDeviceRecord::active) else {
            return Err(ApiError::unauthorized("Invalid revoke signature"));
        };
        if !revoke_signature_valid(
            &request.device_id,
            request.timestamp.as_deref(),
            &request.signature,
            current.sign_pub(),
        ) {
            return Err(ApiError::unauthorized("Invalid revoke signature"));
        }

        self.revoke_device(&auth.account_id, &request.device_id)
            .await?
            .ok_or_else(|| ApiError::not_found("Device not found"))
    }

    /// Registers or updates a push token for the authenticated device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation or storage fails.
    pub async fn upsert_push_token(
        &self,
        auth: &AuthenticatedSession,
        request: &PushTokenUpsert,
    ) -> Result<PushTokenRecord, ApiError> {
        validate_push_token_upsert(request)?;
        let sql = push_token_query(UPSERT_PUSH_TOKEN_SQL, "");
        sqlx::query(&sql)
            .bind(&auth.account_id)
            .bind(&auth.device_id)
            .bind(&request.device_type)
            .bind(&request.token)
            .bind(nullable_string(request.device_name.as_deref()))
            .bind(nullable_string(request.os_version.as_deref()))
            .bind(nullable_string(request.app_version.as_deref()))
            .bind(request.push_enabled.unwrap_or(true))
            .bind(request.push_environment.as_deref().unwrap_or("sandbox"))
            .bind(effective_push_mode(request.push_mode.as_deref()).as_wire())
            .bind(effective_push_token_kind(request.token_kind.as_deref()).as_wire())
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
            .and_then(|row| row_to_push_token_record(&row))
    }

    /// Lists account push tokens.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when storage lookup fails.
    pub async fn list_push_tokens(
        &self,
        auth: &AuthenticatedSession,
    ) -> Result<PushTokenListResponse, ApiError> {
        let sql = push_token_query(LIST_PUSH_TOKENS_SQL, LIST_PUSH_TOKENS_FROM_SQL);
        let rows = sqlx::query(&sql)
            .bind(&auth.account_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        let tokens = rows
            .iter()
            .map(row_to_push_token_record)
            .collect::<Result<Vec<_>, _>>()?;

        Ok(PushTokenListResponse { tokens })
    }

    /// Updates push-enabled state and/or push privacy mode for one token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation, token lookup, or storage update fails.
    pub async fn update_push_token(
        &self,
        auth: &AuthenticatedSession,
        token: &str,
        request: &PushTokenUpdate,
    ) -> Result<PushTokenRecord, ApiError> {
        validate_push_token_update(request)?;
        let enabled_result = match request.push_enabled {
            Some(enabled) => {
                self.update_push_enabled(&auth.account_id, token, enabled)
                    .await?
            }
            None => None,
        };
        let mode_result = match request.push_mode.as_deref() {
            Some(mode) => {
                self.update_push_mode(&auth.account_id, token, effective_push_mode(Some(mode)))
                    .await?
            }
            None => None,
        };
        let kind_result = match request.token_kind.as_deref() {
            Some(kind) => {
                self.update_push_token_kind(
                    &auth.account_id,
                    token,
                    effective_push_token_kind(Some(kind)),
                )
                .await?
            }
            None => None,
        };

        kind_result
            .or(mode_result)
            .or(enabled_result)
            .ok_or_else(|| ApiError::not_found("Token not found"))
    }

    /// Deletes one push token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the token is missing or storage delete fails.
    pub async fn delete_push_token(
        &self,
        auth: &AuthenticatedSession,
        token: &str,
    ) -> Result<(), ApiError> {
        let result = sqlx::query(DELETE_PUSH_TOKEN_SQL)
            .bind(&auth.account_id)
            .bind(token)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        if result.rows_affected() == 0 {
            Err(ApiError::not_found("Token not found"))
        } else {
            Ok(())
        }
    }

    async fn find_account_identity(
        &self,
        account_id: &str,
    ) -> Result<Option<DeviceAccountRecord>, ApiError> {
        sqlx::query(FIND_ACCOUNT_IDENTITY_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(DeviceAccountRecord::new(
                    row.try_get("user_handle")
                        .map_err(|_| ApiError::internal())?,
                    row.try_get("account_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                ))
            })
            .transpose()
    }

    async fn upsert_device(
        &self,
        account_id: &str,
        request: &DeviceRegisterRequest,
    ) -> Result<DeviceRouteRecord, ApiError> {
        let certificate_chain_json = certificate_chain_json(&request.device_certificate_chain)?;
        sqlx::query(UPSERT_DEVICE_SQL)
            .bind(account_id)
            .bind(request.device_pub_keys.device_id())
            .bind(request.device_pub_keys.dk_sign_pub())
            .bind(request.device_pub_keys.dk_dh_pub())
            .bind(&certificate_chain_json)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
            .and_then(|row| row_to_device_record(&row))
    }

    async fn find_current_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<CurrentDeviceRecord>, ApiError> {
        sqlx::query(FIND_CURRENT_DEVICE_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                let state: String = row.try_get("state").map_err(|_| ApiError::internal())?;
                Ok(CurrentDeviceRecord::new(
                    row.try_get("dk_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                    state == "active",
                ))
            })
            .transpose()
    }

    async fn revoke_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<DeviceRouteRecord>, ApiError> {
        sqlx::query(REVOKE_DEVICE_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_device_record(&row))
            .transpose()
    }

    async fn update_push_enabled(
        &self,
        account_id: &str,
        token: &str,
        push_enabled: bool,
    ) -> Result<Option<PushTokenRecord>, ApiError> {
        let sql = push_token_query(UPDATE_PUSH_ENABLED_SQL, "");
        sqlx::query(&sql)
            .bind(account_id)
            .bind(token)
            .bind(push_enabled)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_push_token_record(&row))
            .transpose()
    }

    async fn update_push_mode(
        &self,
        account_id: &str,
        token: &str,
        push_mode: PushMode,
    ) -> Result<Option<PushTokenRecord>, ApiError> {
        let sql = push_token_query(UPDATE_PUSH_MODE_SQL, "");
        sqlx::query(&sql)
            .bind(account_id)
            .bind(token)
            .bind(push_mode.as_wire())
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_push_token_record(&row))
            .transpose()
    }

    async fn update_push_token_kind(
        &self,
        account_id: &str,
        token: &str,
        token_kind: PushTokenKind,
    ) -> Result<Option<PushTokenRecord>, ApiError> {
        let sql = push_token_query(UPDATE_PUSH_TOKEN_KIND_SQL, "");
        sqlx::query(&sql)
            .bind(account_id)
            .bind(token)
            .bind(token_kind.as_wire())
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_push_token_record(&row))
            .transpose()
    }
}

fn row_to_device_record(row: &sqlx::postgres::PgRow) -> Result<DeviceRouteRecord, ApiError> {
    let chain_raw = row
        .try_get::<String, _>("device_certificate_chain")
        .map_err(|_| ApiError::internal())?;
    Ok(DeviceRouteRecord {
        device_id: row.try_get("device_id").map_err(|_| ApiError::internal())?,
        dk_sign_pub: row
            .try_get("dk_sign_pub")
            .map_err(|_| ApiError::internal())?,
        dk_dh_pub: row.try_get("dk_dh_pub").map_err(|_| ApiError::internal())?,
        state: row.try_get("state").map_err(|_| ApiError::internal())?,
        device_certificate_chain: parse_certificate_chain(&chain_raw)?,
    })
}

fn row_to_push_token_record(row: &sqlx::postgres::PgRow) -> Result<PushTokenRecord, ApiError> {
    let push_mode: String = row.try_get("push_mode").map_err(|_| ApiError::internal())?;
    let token_kind: String = row
        .try_get("token_kind")
        .map_err(|_| ApiError::internal())?;
    Ok(PushTokenRecord {
        id: row.try_get("id").map_err(|_| ApiError::internal())?,
        user_id: row.try_get("user_id").map_err(|_| ApiError::internal())?,
        device_type: row
            .try_get("device_type")
            .map_err(|_| ApiError::internal())?,
        token: row.try_get("token").map_err(|_| ApiError::internal())?,
        device_name: row
            .try_get("device_name")
            .map_err(|_| ApiError::internal())?,
        os_version: row
            .try_get("os_version")
            .map_err(|_| ApiError::internal())?,
        app_version: row
            .try_get("app_version")
            .map_err(|_| ApiError::internal())?,
        push_enabled: row
            .try_get("push_enabled")
            .map_err(|_| ApiError::internal())?,
        push_environment: row
            .try_get("push_environment")
            .map_err(|_| ApiError::internal())?,
        push_mode: effective_push_mode(Some(&push_mode)),
        token_kind: effective_push_token_kind(Some(&token_kind)),
        last_used_at: row
            .try_get("last_used_at")
            .map_err(|_| ApiError::internal())?,
        created_at: row
            .try_get("created_at")
            .map_err(|_| ApiError::internal())?,
    })
}

fn push_token_query(prefix: &str, suffix: &str) -> String {
    let mut sql = String::with_capacity(
        prefix
            .len()
            .saturating_add(PUSH_TOKEN_RETURNING_SQL.len())
            .saturating_add(suffix.len()),
    );
    sql.push_str(prefix);
    sql.push_str(PUSH_TOKEN_RETURNING_SQL);
    sql.push_str(suffix);
    sql
}

fn nullable_string(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|inner| !inner.is_empty())
}

fn certificate_chain_json(chain: &[DeviceCertificate]) -> Result<String, ApiError> {
    serde_json::to_string(chain).map_err(|_| ApiError::internal())
}

fn parse_certificate_chain(raw: &str) -> Result<Vec<DeviceCertificate>, ApiError> {
    serde_json::from_str(raw).map_err(|_| ApiError::internal())
}

#[must_use]
pub const fn device_repository_query_contract() -> &'static [&'static str] {
    &[
        FIND_ACCOUNT_IDENTITY_SQL,
        UPSERT_DEVICE_SQL,
        FIND_CURRENT_DEVICE_SQL,
        REVOKE_DEVICE_SQL,
        PUSH_TOKEN_RETURNING_SQL,
        UPSERT_PUSH_TOKEN_SQL,
        LIST_PUSH_TOKENS_SQL,
        LIST_PUSH_TOKENS_FROM_SQL,
        UPDATE_PUSH_ENABLED_SQL,
        UPDATE_PUSH_MODE_SQL,
        UPDATE_PUSH_TOKEN_KIND_SQL,
        DELETE_PUSH_TOKEN_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        device_repository_query_contract, FIND_ACCOUNT_IDENTITY_SQL, FIND_CURRENT_DEVICE_SQL,
        LIST_PUSH_TOKENS_FROM_SQL, PUSH_TOKEN_RETURNING_SQL, REVOKE_DEVICE_SQL,
        UPDATE_PUSH_ENABLED_SQL, UPDATE_PUSH_MODE_SQL, UPDATE_PUSH_TOKEN_KIND_SQL,
        UPSERT_DEVICE_SQL, UPSERT_PUSH_TOKEN_SQL,
    };

    #[test]
    fn device_queries_are_parameterized_and_preserve_certificate_json() {
        for query in device_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(FIND_ACCOUNT_IDENTITY_SQL.contains("JOIN identity_keys"));
        assert!(UPSERT_DEVICE_SQL.contains("$1::uuid"));
        assert!(UPSERT_DEVICE_SQL.contains("$5::jsonb"));
        assert!(UPSERT_DEVICE_SQL.contains("state = 'active'"));
        assert!(UPSERT_DEVICE_SQL.contains("revoked_at = NULL"));
        assert!(FIND_CURRENT_DEVICE_SQL.contains("account_id = $1::uuid"));
        assert!(REVOKE_DEVICE_SQL.contains("state != 'revoked'"));
        assert!(REVOKE_DEVICE_SQL.contains("device_certificate_chain::TEXT"));
        assert!(PUSH_TOKEN_RETURNING_SQL.contains("account_id::TEXT AS user_id"));
        assert!(PUSH_TOKEN_RETURNING_SQL.contains("AT TIME ZONE 'UTC'"));
        assert!(UPSERT_PUSH_TOKEN_SQL.contains("ON CONFLICT (token)"));
        assert!(UPSERT_PUSH_TOKEN_SQL.contains("push_mode = EXCLUDED.push_mode"));
        assert!(UPSERT_PUSH_TOKEN_SQL.contains("token_kind = EXCLUDED.token_kind"));
        assert!(LIST_PUSH_TOKENS_FROM_SQL.contains("ORDER BY updated_at DESC, created_at DESC"));
        assert!(UPDATE_PUSH_ENABLED_SQL.contains("push_enabled = $3"));
        assert!(UPDATE_PUSH_MODE_SQL.contains("push_mode = $3"));
        assert!(UPDATE_PUSH_TOKEN_KIND_SQL.contains("token_kind = $3"));
    }

    #[test]
    fn push_token_query_builder_keeps_sql_parameterized() {
        let sql = super::push_token_query(UPSERT_PUSH_TOKEN_SQL, "");

        assert!(sql.contains("RETURNING"));
        assert!(sql.contains("id::TEXT AS id"));
        assert!(!sql.contains("{}"));
    }
}
