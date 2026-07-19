//! `PostgreSQL` persistence adapter for auth routes.
//!
//! This starts with `/api/auth/start`, which is intentionally account-probing resistant: the response shape is the same
//! whether the handle exists or not, and storage only receives the nullable account id plus opaque challenge nonce.

use crate::auth::{
    normalize_handle, parse_handle, registration_signature_valid, registration_timestamp_fresh,
    verify_ed25519, DeviceCertificate,
};
use crate::auth_service::{
    ApiError, ApiStatus, AuthFinishRequest, AuthStartRequest, AuthStartResponse, DeviceRecord,
    DeviceState, IdentityRecord, InitialDeviceRegistration, IssuedTokens, LogoutRequest,
    LogoutResponse, RefreshRequest, RegisterRequest, RegisterResponse, AUTH_CHALLENGE_TTL_MS,
};
use crate::devices::{validate_device_registration, DevicePublicKeys, DeviceRegistrationInput};
use crate::session::{
    bearer_token, sign_refresh_token, sign_session_token, token_hash, verify_refresh_token,
    verify_session_token, TokenConfig, TokenKind, TokenSubject,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const FIND_ACCOUNT_ID_BY_HANDLE_SQL: &str = r"
SELECT id::TEXT
FROM accounts
WHERE user_handle = $1
";

const CREATE_AUTH_CHALLENGE_SQL: &str = r#"
INSERT INTO auth_challenges (account_id, device_id, nonce, expires_at)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0))
RETURNING
  challenge_id::TEXT AS challenge_id,
  nonce,
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at
"#;

const FIND_ACCOUNT_BY_HANDLE_SQL: &str = r"
SELECT id::TEXT, user_handle
FROM accounts
WHERE user_handle = $1
";

const FIND_IDENTITY_FOR_REGISTER_SQL: &str = r"
SELECT ik_sign_pub, ik_dh_pub
FROM identity_keys
WHERE account_id = $1::uuid
";

const FIND_DEVICE_FOR_REGISTER_SQL: &str = r"
SELECT
  device_id,
  dk_sign_pub,
  dk_dh_pub,
  state,
  device_certificate_chain::TEXT AS device_certificate_chain
FROM devices
WHERE account_id = $1::uuid
  AND device_id = $2
";

const INSERT_ACCOUNT_SQL: &str = r"
INSERT INTO accounts (user_handle, home_server)
VALUES ($1, $2)
RETURNING id::TEXT AS id, user_handle
";

const INSERT_ACCOUNT_SETTINGS_SQL: &str = r"
INSERT INTO account_settings (account_id)
VALUES ($1::uuid)
ON CONFLICT (account_id) DO NOTHING
";

const INSERT_IDENTITY_KEYS_SQL: &str = r"
INSERT INTO identity_keys (account_id, ik_sign_pub, ik_dh_pub, proof_signature, proof_timestamp)
VALUES ($1::uuid, $2, $3, $4, $5::timestamptz)
";

const INSERT_INITIAL_DEVICE_SQL: &str = r"
INSERT INTO devices (
  account_id,
  device_id,
  dk_sign_pub,
  dk_dh_pub,
  ik_device_signature,
  device_certificate_version,
  device_certificate_chain
)
VALUES ($1::uuid, $2, $3, $4, $5, 2, $6::jsonb)
";

const FIND_ACCOUNT_BY_ID_SQL: &str = r"
SELECT id::TEXT, user_handle
FROM accounts
WHERE id = $1::uuid
";

const FIND_ACTIVE_CHALLENGE_SQL: &str = r"
SELECT nonce
FROM auth_challenges
WHERE challenge_id = $1::uuid
  AND account_id = $2::uuid
  AND used_at IS NULL
  AND expires_at > to_timestamp($3::double precision / 1000.0)
";

const FIND_DEVICE_FOR_AUTH_SQL: &str = r"
SELECT
  dk_sign_pub,
  state,
  device_certificate_chain::TEXT AS device_certificate_chain
FROM devices
WHERE account_id = $1::uuid
  AND device_id = $2
";

const MARK_CHALLENGE_USED_SQL: &str = r"
UPDATE auth_challenges
SET used_at = CURRENT_TIMESTAMP
WHERE challenge_id = $1::uuid
";

const INSERT_SESSION_SQL: &str = r"
INSERT INTO sessions (account_id, device_id, token_hash, expires_at)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0))
";

const INSERT_REFRESH_SESSION_SQL: &str = r"
INSERT INTO refresh_sessions (account_id, device_id, token_hash, expires_at)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0))
";

const FIND_ACTIVE_REFRESH_FOR_UPDATE_SQL: &str = r"
SELECT refresh_id::TEXT AS refresh_id, account_id::TEXT AS account_id, device_id
FROM refresh_sessions
WHERE token_hash = $1
  AND revoked_at IS NULL
  AND expires_at > to_timestamp($2::double precision / 1000.0)
FOR UPDATE
";

const ROTATE_REFRESH_SQL: &str = r"
UPDATE refresh_sessions
SET revoked_at = CURRENT_TIMESTAMP,
    replaced_by_hash = $2
WHERE refresh_id = $1::uuid
";

const REVOKE_SESSION_SQL: &str = r"
UPDATE sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE token_hash = $1
  AND revoked_at IS NULL
";

const REVOKE_REFRESH_SQL: &str = r"
UPDATE refresh_sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE token_hash = $1
  AND revoked_at IS NULL
";

/// Async `PostgreSQL` repository for auth route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresAuthRepository {
    pool: PgPool,
    token_config: TokenConfig,
}

impl PostgresAuthRepository {
    #[must_use]
    pub const fn new(pool: PgPool, token_config: TokenConfig) -> Self {
        Self { pool, token_config }
    }

    /// Registers the first account device and preserves idempotent re-registration semantics.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for invalid handles, stale signatures, invalid certificates, conflicts, or storage failures.
    pub async fn register(
        &self,
        request: &RegisterRequest,
        server_domain: &str,
        now_ms: u64,
    ) -> Result<RegisterResponse, ApiError> {
        let parsed = parse_handle(&request.user_handle)
            .map_err(|_| ApiError::bad_request("Invalid user_handle format"))?;
        if parsed.domain() != server_domain {
            return Err(ApiError::bad_request(
                "user_handle domain must match home server",
            ));
        }

        let timestamp_ms = parse_timestamp_ms(&request.timestamp)?;
        if !registration_timestamp_fresh(now_ms, timestamp_ms) {
            return Err(ApiError::bad_request(
                "Registration timestamp is out of allowed range",
            ));
        }
        if !registration_signature_valid(
            parsed.normalized(),
            &request.ik_sign_pub,
            &request.ik_dh_pub,
            &request.timestamp,
            &request.signature,
        ) {
            return Err(ApiError::unauthorized("Invalid registration signature"));
        }
        validate_initial_device(parsed.normalized(), request, now_ms)?;

        if let Some(account) = self.find_account_by_handle(parsed.normalized()).await? {
            return self.register_existing(request, &account, now_ms).await;
        }

        let created = self
            .create_account_with_identity_and_device(parsed.normalized(), parsed.domain(), request)
            .await?;
        let tokens = self
            .issue_tokens(&created, &request.initial_device.device_id, now_ms)
            .await?;

        Ok(RegisterResponse {
            status: ApiStatus::Created,
            user_handle: created.user_handle,
            device_id: request.initial_device.device_id.clone(),
            tokens,
        })
    }

    /// Starts a challenge-response auth flow without exposing account existence.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is invalid, randomness fails, or storage cannot create the challenge.
    pub async fn start(
        &self,
        request: &AuthStartRequest,
        now_ms: u64,
    ) -> Result<AuthStartResponse, ApiError> {
        if request.user_handle.trim().is_empty() {
            return Err(ApiError::bad_request("user_handle is required"));
        }

        let handle = normalize_handle(&request.user_handle);
        let account_id = self.find_account_id_by_handle(&handle).await?;
        let nonce = random_base64_url(24)?;
        let expires_at_ms = now_ms.saturating_add(AUTH_CHALLENGE_TTL_MS);
        let expires_at_ms = i64::try_from(expires_at_ms).map_err(|_| ApiError::internal())?;
        let row = sqlx::query(CREATE_AUTH_CHALLENGE_SQL)
            .bind(account_id.as_deref())
            .bind(request.device_id.as_deref())
            .bind(&nonce)
            .bind(expires_at_ms)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(AuthStartResponse {
            challenge_id: row
                .try_get("challenge_id")
                .map_err(|_| ApiError::internal())?,
            nonce: row.try_get("nonce").map_err(|_| ApiError::internal())?,
            expires_at: row
                .try_get("expires_at")
                .map_err(|_| ApiError::internal())?,
        })
    }

    async fn find_account_id_by_handle(&self, handle: &str) -> Result<Option<String>, ApiError> {
        sqlx::query_scalar::<_, String>(FIND_ACCOUNT_ID_BY_HANDLE_SQL)
            .bind(handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
    }

    /// Finishes a challenge-response auth flow and issues session/refresh tokens.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for invalid challenges, device-link-required state, invalid signatures, or storage failures.
    pub async fn finish(
        &self,
        request: &AuthFinishRequest,
        now_ms: u64,
    ) -> Result<IssuedTokens, ApiError> {
        let handle = normalize_handle(&request.user_handle);
        let account = self
            .find_account_by_handle(&handle)
            .await?
            .ok_or_else(|| ApiError::unauthorized("Invalid challenge or signature"))?;
        let challenge_nonce = self
            .find_active_challenge(&request.challenge_id, account.id(), now_ms)
            .await?
            .ok_or_else(|| ApiError::unauthorized("Invalid challenge or signature"))?;
        let device = self
            .find_device(account.id(), &request.device_id)
            .await?
            .filter(AuthDeviceRecord::is_challenge_capable);

        let Some(device) = device else {
            self.mark_challenge_used(&request.challenge_id).await?;
            return Err(ApiError::conflict(
                "Device link required",
                Some("device_link_required"),
            ));
        };

        if !verify_ed25519(&challenge_nonce, &request.signature, device.dk_sign_pub())
            .unwrap_or(false)
        {
            return Err(ApiError::unauthorized("Invalid challenge or signature"));
        }

        self.mark_challenge_used(&request.challenge_id).await?;
        self.issue_tokens(&account, &request.device_id, now_ms)
            .await
    }

    /// Rotates a refresh token and issues a fresh session token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the refresh token is invalid, inactive, mismatched, or storage cannot rotate it.
    pub async fn refresh(
        &self,
        request: &RefreshRequest,
        now_ms: u64,
    ) -> Result<IssuedTokens, ApiError> {
        let issued_at_sec = now_ms / 1_000;
        let Some(claims) =
            verify_refresh_token(&request.refresh_token, &self.token_config, issued_at_sec)
        else {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        };
        if claims.token_type() != TokenKind::Refresh {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        }
        let account = self
            .find_account_by_id(claims.account_id())
            .await?
            .ok_or_else(|| ApiError::unauthorized("Invalid refresh token"))?;
        let old_hash = token_hash(&request.refresh_token);
        let signed = self.sign_tokens(&account, claims.device_id(), now_ms)?;
        self.rotate_refresh_transaction(
            &old_hash,
            &signed,
            claims.account_id(),
            claims.device_id(),
            now_ms,
        )
        .await?;

        Ok(signed.issued)
    }

    /// Revokes the authenticated session token and any explicitly supplied session/refresh tokens.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when revocation storage updates fail.
    pub async fn logout(
        &self,
        authorization_header: Option<&str>,
        request: &LogoutRequest,
        now_ms: u64,
    ) -> Result<LogoutResponse, ApiError> {
        if let Some(header_token) = authorization_header.and_then(bearer_token) {
            if verify_session_token(header_token, &self.token_config, now_ms / 1_000).is_some() {
                self.revoke_session_hash(&token_hash(header_token)).await?;
            }
        }

        if let Some(session_token) = request.session_token.as_deref() {
            self.revoke_session_hash(&token_hash(session_token)).await?;
        }

        if let Some(refresh_token) = request.refresh_token.as_deref() {
            self.revoke_refresh_hash(&token_hash(refresh_token)).await?;
        }

        Ok(LogoutResponse { success: true })
    }

    async fn find_account_by_handle(
        &self,
        handle: &str,
    ) -> Result<Option<AuthAccountRecord>, ApiError> {
        sqlx::query(FIND_ACCOUNT_BY_HANDLE_SQL)
            .bind(handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(AuthAccountRecord {
                    id: row.try_get("id").map_err(|_| ApiError::internal())?,
                    user_handle: row
                        .try_get("user_handle")
                        .map_err(|_| ApiError::internal())?,
                })
            })
            .transpose()
    }

    async fn find_account_by_id(
        &self,
        account_id: &str,
    ) -> Result<Option<AuthAccountRecord>, ApiError> {
        sqlx::query(FIND_ACCOUNT_BY_ID_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(AuthAccountRecord {
                    id: row.try_get("id").map_err(|_| ApiError::internal())?,
                    user_handle: row
                        .try_get("user_handle")
                        .map_err(|_| ApiError::internal())?,
                })
            })
            .transpose()
    }

    async fn find_identity_keys(
        &self,
        account_id: &str,
    ) -> Result<Option<IdentityRecord>, ApiError> {
        sqlx::query(FIND_IDENTITY_FOR_REGISTER_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(IdentityRecord::new(
                    row.try_get("ik_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                    row.try_get("ik_dh_pub").map_err(|_| ApiError::internal())?,
                ))
            })
            .transpose()
    }

    async fn find_registration_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<DeviceRecord>, ApiError> {
        sqlx::query(FIND_DEVICE_FOR_REGISTER_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                let chain_raw = row
                    .try_get::<String, _>("device_certificate_chain")
                    .map_err(|_| ApiError::internal())?;
                let certificate_chain = parse_certificate_chain(&chain_raw)?;
                let state = parse_device_state(
                    &row.try_get::<String, _>("state")
                        .map_err(|_| ApiError::internal())?,
                );
                Ok(DeviceRecord::new(
                    account_id.to_owned(),
                    row.try_get("device_id").map_err(|_| ApiError::internal())?,
                    row.try_get("dk_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                    row.try_get("dk_dh_pub").map_err(|_| ApiError::internal())?,
                    state,
                    certificate_chain,
                ))
            })
            .transpose()
    }

    async fn create_account_with_identity_and_device(
        &self,
        handle: &str,
        home_server: &str,
        request: &RegisterRequest,
    ) -> Result<AuthAccountRecord, ApiError> {
        let certificate_chain_json = certificate_chain_json(&request.initial_device)?;
        let mut transaction = self.pool.begin().await.map_err(|_| ApiError::internal())?;
        let account_row = sqlx::query(INSERT_ACCOUNT_SQL)
            .bind(handle)
            .bind(home_server)
            .fetch_one(&mut *transaction)
            .await
            .map_err(|error| map_create_account_error(&error))?;
        let account = AuthAccountRecord {
            id: account_row
                .try_get("id")
                .map_err(|_| ApiError::internal())?,
            user_handle: account_row
                .try_get("user_handle")
                .map_err(|_| ApiError::internal())?,
        };

        sqlx::query(INSERT_ACCOUNT_SETTINGS_SQL)
            .bind(account.id())
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(INSERT_IDENTITY_KEYS_SQL)
            .bind(account.id())
            .bind(&request.ik_sign_pub)
            .bind(&request.ik_dh_pub)
            .bind(&request.signature)
            .bind(&request.timestamp)
            .execute(&mut *transaction)
            .await
            .map_err(|error| map_create_account_error(&error))?;
        sqlx::query(INSERT_INITIAL_DEVICE_SQL)
            .bind(account.id())
            .bind(&request.initial_device.device_id)
            .bind(&request.initial_device.dk_sign_pub)
            .bind(&request.initial_device.dk_dh_pub)
            .bind(&request.signature)
            .bind(&certificate_chain_json)
            .execute(&mut *transaction)
            .await
            .map_err(|error| map_create_account_error(&error))?;
        transaction
            .commit()
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(account)
    }

    async fn register_existing(
        &self,
        request: &RegisterRequest,
        account: &AuthAccountRecord,
        now_ms: u64,
    ) -> Result<RegisterResponse, ApiError> {
        let identity = self.find_identity_keys(account.id()).await?;
        let device = self
            .find_registration_device(account.id(), &request.initial_device.device_id)
            .await?;
        if registration_matches_existing(identity.as_ref(), device.as_ref(), request) {
            let tokens = self
                .issue_tokens(account, &request.initial_device.device_id, now_ms)
                .await?;
            return Ok(RegisterResponse {
                status: ApiStatus::Ok,
                user_handle: account.user_handle.clone(),
                device_id: request.initial_device.device_id.clone(),
                tokens,
            });
        }

        Err(ApiError::conflict("Account already exists", None))
    }

    async fn find_active_challenge(
        &self,
        challenge_id: &str,
        account_id: &str,
        now_ms: u64,
    ) -> Result<Option<String>, ApiError> {
        let now_ms = i64::try_from(now_ms).map_err(|_| ApiError::internal())?;
        sqlx::query_scalar::<_, String>(FIND_ACTIVE_CHALLENGE_SQL)
            .bind(challenge_id)
            .bind(account_id)
            .bind(now_ms)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
    }

    async fn find_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<AuthDeviceRecord>, ApiError> {
        sqlx::query(FIND_DEVICE_FOR_AUTH_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                let chain_raw = row
                    .try_get::<String, _>("device_certificate_chain")
                    .map_err(|_| ApiError::internal())?;
                let certificate_chain = parse_certificate_chain(&chain_raw)?;
                Ok(AuthDeviceRecord {
                    dk_sign_pub: row
                        .try_get("dk_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                    state: row.try_get("state").map_err(|_| ApiError::internal())?,
                    device_certificate_chain: certificate_chain,
                })
            })
            .transpose()
    }

    async fn mark_challenge_used(&self, challenge_id: &str) -> Result<(), ApiError> {
        sqlx::query(MARK_CHALLENGE_USED_SQL)
            .bind(challenge_id)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }

    async fn issue_tokens(
        &self,
        account: &AuthAccountRecord,
        device_id: &str,
        now_ms: u64,
    ) -> Result<IssuedTokens, ApiError> {
        let signed = self.sign_tokens(account, device_id, now_ms)?;

        sqlx::query(INSERT_SESSION_SQL)
            .bind(account.id())
            .bind(device_id)
            .bind(&signed.session_hash)
            .bind(i64::try_from(signed.session_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(INSERT_REFRESH_SESSION_SQL)
            .bind(account.id())
            .bind(device_id)
            .bind(&signed.refresh_hash)
            .bind(i64::try_from(signed.refresh_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(signed.issued)
    }

    fn sign_tokens(
        &self,
        account: &AuthAccountRecord,
        device_id: &str,
        now_ms: u64,
    ) -> Result<SignedTokenPair, ApiError> {
        let issued_at_sec = now_ms / 1_000;
        let session_id = random_uuid_v4()?;
        let subject = TokenSubject::new(
            account.id.clone(),
            account.user_handle.clone(),
            device_id.to_owned(),
            session_id,
        );
        let session_token = sign_session_token(&subject, &self.token_config, issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let refresh_token = sign_refresh_token(&subject, &self.token_config, issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let session_expires_at_ms =
            token_expires_at_ms(issued_at_sec, self.token_config.session_ttl_sec());
        let refresh_expires_at_ms =
            token_expires_at_ms(issued_at_sec, self.token_config.refresh_ttl_sec());

        Ok(SignedTokenPair {
            session_hash: token_hash(&session_token),
            refresh_hash: token_hash(&refresh_token),
            session_expires_at_ms,
            refresh_expires_at_ms,
            issued: IssuedTokens {
                session_token,
                refresh_token,
                expires_in: self.token_config.session_ttl_sec(),
            },
        })
    }

    async fn rotate_refresh_transaction(
        &self,
        old_hash: &str,
        signed: &SignedTokenPair,
        claims_account_id: &str,
        claims_device_id: &str,
        now_ms: u64,
    ) -> Result<(), ApiError> {
        let now_ms =
            i64::try_from(now_ms).map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        let row = sqlx::query(FIND_ACTIVE_REFRESH_FOR_UPDATE_SQL)
            .bind(old_hash)
            .bind(now_ms)
            .fetch_optional(&mut *transaction)
            .await
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        let Some(row) = row else {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        };
        let refresh_id = row
            .try_get::<String, _>("refresh_id")
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        let account_id = row
            .try_get::<String, _>("account_id")
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        let device_id = row
            .try_get::<String, _>("device_id")
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        if account_id != claims_account_id || device_id != claims_device_id {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        }

        sqlx::query(INSERT_SESSION_SQL)
            .bind(&account_id)
            .bind(&device_id)
            .bind(&signed.session_hash)
            .bind(i64::try_from(signed.session_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(ROTATE_REFRESH_SQL)
            .bind(&refresh_id)
            .bind(&signed.refresh_hash)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(INSERT_REFRESH_SESSION_SQL)
            .bind(&account_id)
            .bind(&device_id)
            .bind(&signed.refresh_hash)
            .bind(i64::try_from(signed.refresh_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        transaction.commit().await.map_err(|_| ApiError::internal())
    }

    async fn revoke_session_hash(&self, session_hash: &str) -> Result<(), ApiError> {
        sqlx::query(REVOKE_SESSION_SQL)
            .bind(session_hash)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }

    async fn revoke_refresh_hash(&self, refresh_hash: &str) -> Result<(), ApiError> {
        sqlx::query(REVOKE_REFRESH_SQL)
            .bind(refresh_hash)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }
}

fn random_base64_url(byte_len: usize) -> Result<String, ApiError> {
    let mut bytes = vec![0_u8; byte_len];
    getrandom::getrandom(&mut bytes).map_err(|_| ApiError::internal())?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn random_uuid_v4() -> Result<String, ApiError> {
    let mut bytes = [0_u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| ApiError::internal())?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(uuid_string(&bytes))
}

fn uuid_string(bytes: &[u8; 16]) -> String {
    let mut output = String::with_capacity(36);
    for (index, byte) in bytes.iter().enumerate() {
        if matches!(index, 4 | 6 | 8 | 10) {
            output.push('-');
        }
        push_hex_byte(&mut output, *byte);
    }
    output
}

fn push_hex_byte(output: &mut String, byte: u8) {
    output.push(hex_char(byte >> 4));
    output.push(hex_char(byte & 0x0f));
}

const fn hex_char(value: u8) -> char {
    match value {
        0 => '0',
        1 => '1',
        2 => '2',
        3 => '3',
        4 => '4',
        5 => '5',
        6 => '6',
        7 => '7',
        8 => '8',
        9 => '9',
        10 => 'a',
        11 => 'b',
        12 => 'c',
        13 => 'd',
        14 => 'e',
        15 => 'f',
        _ => '?',
    }
}

const fn token_expires_at_ms(issued_at_sec: u64, ttl_sec: u64) -> u64 {
    issued_at_sec.saturating_add(ttl_sec).saturating_mul(1_000)
}

fn parse_timestamp_ms(timestamp: &str) -> Result<u64, ApiError> {
    let parsed = OffsetDateTime::parse(timestamp, &Rfc3339)
        .map_err(|_| ApiError::bad_request("Registration timestamp is out of allowed range"))?;
    let epoch_ms = parsed.unix_timestamp_nanos() / 1_000_000;
    u64::try_from(epoch_ms)
        .map_err(|_| ApiError::bad_request("Registration timestamp is out of allowed range"))
}

fn validate_initial_device(
    handle: &str,
    request: &RegisterRequest,
    now_ms: u64,
) -> Result<(), ApiError> {
    let device_keys = DevicePublicKeys::new(
        request.initial_device.device_id.clone(),
        request.initial_device.dk_sign_pub.clone(),
        request.initial_device.dk_dh_pub.clone(),
    );
    let input = DeviceRegistrationInput {
        account_handle: handle,
        account_sign_pub: &request.ik_sign_pub,
        device_keys: &device_keys,
        certificate_chain: &request.initial_device.device_certificate_chain,
        now_ms,
    };
    validate_device_registration(&input)
        .map(|_validated| ())
        .map_err(|_| ApiError::unauthorized("Invalid initial device certificate chain"))
}

fn registration_matches_existing(
    identity: Option<&IdentityRecord>,
    device: Option<&DeviceRecord>,
    request: &RegisterRequest,
) -> bool {
    let Some(identity) = identity else {
        return false;
    };
    let Some(device) = device else {
        return false;
    };

    identity.ik_sign_pub() == request.ik_sign_pub
        && identity.ik_dh_pub() == request.ik_dh_pub
        && device.device_id() == request.initial_device.device_id
        && device.dk_sign_pub() == request.initial_device.dk_sign_pub
        && device.dk_dh_pub() == request.initial_device.dk_dh_pub
        && device.device_certificate_chain() == request.initial_device.device_certificate_chain
}

fn certificate_chain_json(initial_device: &InitialDeviceRegistration) -> Result<String, ApiError> {
    serde_json::to_string(&initial_device.device_certificate_chain)
        .map_err(|_| ApiError::internal())
}

fn parse_device_state(raw: &str) -> DeviceState {
    if raw == "active" {
        DeviceState::Active
    } else {
        DeviceState::Revoked
    }
}

fn map_create_account_error(error: &sqlx::Error) -> ApiError {
    if is_unique_violation(error) {
        ApiError::conflict("Account already exists", None)
    } else {
        ApiError::internal()
    }
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    matches!(
        error,
        sqlx::Error::Database(database_error) if database_error.code().as_deref() == Some("23505")
    )
}

fn parse_certificate_chain(raw: &str) -> Result<Vec<DeviceCertificate>, ApiError> {
    serde_json::from_str(raw).map_err(|_| ApiError::internal())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AuthAccountRecord {
    id: String,
    user_handle: String,
}

impl AuthAccountRecord {
    fn id(&self) -> &str {
        &self.id
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SignedTokenPair {
    issued: IssuedTokens,
    session_hash: String,
    refresh_hash: String,
    session_expires_at_ms: u64,
    refresh_expires_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct AuthDeviceRecord {
    dk_sign_pub: String,
    state: String,
    device_certificate_chain: Vec<DeviceCertificate>,
}

impl AuthDeviceRecord {
    fn dk_sign_pub(&self) -> &str {
        &self.dk_sign_pub
    }

    fn is_challenge_capable(&self) -> bool {
        self.state == "active" && !self.device_certificate_chain.is_empty()
    }
}

#[must_use]
pub const fn auth_repository_query_contract() -> &'static [&'static str] {
    &[
        FIND_ACCOUNT_ID_BY_HANDLE_SQL,
        CREATE_AUTH_CHALLENGE_SQL,
        FIND_ACCOUNT_BY_HANDLE_SQL,
        FIND_ACCOUNT_BY_ID_SQL,
        FIND_IDENTITY_FOR_REGISTER_SQL,
        FIND_DEVICE_FOR_REGISTER_SQL,
        INSERT_ACCOUNT_SQL,
        INSERT_ACCOUNT_SETTINGS_SQL,
        INSERT_IDENTITY_KEYS_SQL,
        INSERT_INITIAL_DEVICE_SQL,
        FIND_ACTIVE_CHALLENGE_SQL,
        FIND_DEVICE_FOR_AUTH_SQL,
        MARK_CHALLENGE_USED_SQL,
        INSERT_SESSION_SQL,
        INSERT_REFRESH_SESSION_SQL,
        FIND_ACTIVE_REFRESH_FOR_UPDATE_SQL,
        ROTATE_REFRESH_SQL,
        REVOKE_SESSION_SQL,
        REVOKE_REFRESH_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        auth_repository_query_contract, random_base64_url, random_uuid_v4, uuid_string,
        CREATE_AUTH_CHALLENGE_SQL, FIND_ACTIVE_CHALLENGE_SQL, FIND_DEVICE_FOR_AUTH_SQL,
        FIND_DEVICE_FOR_REGISTER_SQL, FIND_IDENTITY_FOR_REGISTER_SQL, INSERT_ACCOUNT_SETTINGS_SQL,
        INSERT_ACCOUNT_SQL, INSERT_IDENTITY_KEYS_SQL, INSERT_INITIAL_DEVICE_SQL,
        INSERT_REFRESH_SESSION_SQL, INSERT_SESSION_SQL, MARK_CHALLENGE_USED_SQL,
        REVOKE_REFRESH_SQL, REVOKE_SESSION_SQL, ROTATE_REFRESH_SQL,
    };

    #[test]
    fn auth_start_queries_are_parameterized_and_account_probe_resistant() {
        for query in auth_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(CREATE_AUTH_CHALLENGE_SQL.contains("$1::uuid"));
        assert!(CREATE_AUTH_CHALLENGE_SQL.contains("to_timestamp($4::double precision / 1000.0)"));
        assert!(CREATE_AUTH_CHALLENGE_SQL.contains("AT TIME ZONE 'UTC'"));
        assert!(FIND_ACTIVE_CHALLENGE_SQL.contains("used_at IS NULL"));
        assert!(FIND_ACTIVE_CHALLENGE_SQL.contains("expires_at > to_timestamp($3"));
        assert!(FIND_DEVICE_FOR_AUTH_SQL.contains("device_certificate_chain::TEXT"));
        assert!(FIND_IDENTITY_FOR_REGISTER_SQL.contains("$1::uuid"));
        assert!(FIND_DEVICE_FOR_REGISTER_SQL.contains("device_certificate_chain::TEXT"));
        assert!(INSERT_ACCOUNT_SQL.contains("RETURNING id::TEXT AS id"));
        assert!(INSERT_ACCOUNT_SETTINGS_SQL.contains("ON CONFLICT (account_id) DO NOTHING"));
        assert!(INSERT_IDENTITY_KEYS_SQL.contains("$5::timestamptz"));
        assert!(INSERT_INITIAL_DEVICE_SQL.contains("$6::jsonb"));
        assert!(MARK_CHALLENGE_USED_SQL.contains("used_at = CURRENT_TIMESTAMP"));
        assert!(INSERT_SESSION_SQL.contains("token_hash"));
        assert!(INSERT_REFRESH_SESSION_SQL.contains("token_hash"));
        assert!(ROTATE_REFRESH_SQL.contains("replaced_by_hash = $2"));
        assert!(REVOKE_SESSION_SQL.contains("token_hash = $1"));
        assert!(REVOKE_REFRESH_SQL.contains("token_hash = $1"));
    }

    #[test]
    fn auth_nonce_is_url_safe_without_padding() {
        let nonce = random_base64_url(24);

        assert!(nonce.is_ok());
        let Ok(nonce) = nonce else {
            return;
        };
        assert_eq!(nonce.len(), 32);
        assert!(!nonce.contains('='));
        assert!(nonce
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')));
    }

    #[test]
    fn auth_session_id_is_uuid_v4_shaped() {
        let session_id = random_uuid_v4();

        assert!(session_id.is_ok());
        let Ok(session_id) = session_id else {
            return;
        };
        assert_eq!(session_id.len(), 36);
        assert_eq!(session_id.as_bytes().get(14), Some(&b'4'));
        assert!(matches!(
            session_id.as_bytes().get(19),
            Some(b'8' | b'9' | b'a' | b'b')
        ));
    }

    #[test]
    fn uuid_formatter_uses_expected_hyphen_positions() {
        let formatted = uuid_string(&[
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ]);

        assert_eq!(formatted, "00112233-4455-4677-8899-aabbccddeeff");
    }
}
