//! `PostgreSQL` persistence adapter for device-link session creation through completion.

use crate::auth::{normalize_handle, parse_handle, DeviceCertificate};
use crate::auth_service::{ApiError, AuthenticatedSession, IssuedTokens};
use crate::device_link_service::{
    request_view, token_expires_at_ms, validate_complete_request, HostDeviceRecord,
    LinkAccountIdentity, LinkApproveRequest, LinkApproveResponse, LinkCompleteRequest,
    LinkCompleteResponse, LinkRequestCreateRequest, LinkRequestCreateResponse,
    LinkRequestListResponse, LinkRequestPollResponse, LinkRequestRecord, LinkRequestStatus,
    LinkStartRequest, LinkStartResponse,
};
use crate::devices::{
    effective_link_expires_sec, link_secret_hash, validate_device_link_approval, DeviceError,
    DeviceLinkApprovalInput, DevicePublicKeys,
};
use crate::prekeys::{validate_publish_request, PrekeyPublishRequest};
use crate::realtime::RealtimeHub;
use crate::session::{
    sign_refresh_token, sign_session_token, token_hash, TokenConfig, TokenSubject,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sqlx::postgres::PgRow;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;
use time::OffsetDateTime;

const POLL_TOKEN_BYTES: usize = 12;

const INSERT_LINK_SESSION_SQL: &str = r#"
INSERT INTO device_link_sessions (account_id, old_device_id, link_code_hash, l_dh_pub, expires_at)
VALUES ($1::uuid, $2, $3, $4, to_timestamp($5::double precision / 1000.0))
RETURNING
  id::TEXT AS id,
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at
"#;

const FIND_ACTIVE_LINK_SESSION_SQL: &str = r"
SELECT
  ls.id::TEXT AS id,
  ls.account_id::TEXT AS account_id,
  a.user_handle,
  ls.old_device_id,
  ls.l_dh_pub,
  FLOOR(EXTRACT(EPOCH FROM ls.expires_at) * 1000)::BIGINT AS expires_at_ms
FROM device_link_sessions ls
JOIN accounts a ON a.id = ls.account_id
WHERE ls.link_code_hash = $1
  AND ls.expires_at > to_timestamp($2::double precision / 1000.0)
";

const INSERT_LINK_REQUEST_SQL: &str = r"
INSERT INTO device_link_requests (
  session_id,
  user_handle,
  new_device_id,
  n_dh_pub,
  dk_sign_pub,
  dk_dh_pub,
  poll_token_hash
)
VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)
RETURNING id::TEXT AS id, status
";

const LIST_LINK_REQUESTS_SQL: &str = r#"
SELECT
  lr.id::TEXT AS id,
  lr.session_id::TEXT AS session_id,
  ls.account_id::TEXT AS account_id,
  ls.old_device_id,
  lr.user_handle,
  lr.new_device_id,
  lr.n_dh_pub,
  lr.dk_sign_pub,
  lr.dk_dh_pub,
  lr.status,
  lr.approved_device_certificate::TEXT AS approved_device_certificate,
  lr.encrypted_provisioning_blob,
  FLOOR(EXTRACT(EPOCH FROM ls.expires_at) * 1000)::BIGINT AS expires_at_ms,
  FLOOR(EXTRACT(EPOCH FROM lr.completed_at) * 1000)::BIGINT AS completed_at_ms,
  to_char(lr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
FROM device_link_requests lr
JOIN device_link_sessions ls ON ls.id = lr.session_id
WHERE lr.session_id = $1::uuid
  AND ls.account_id = $2::uuid
ORDER BY lr.created_at DESC
"#;

const FIND_LINK_REQUEST_BY_POLL_TOKEN_SQL: &str = r#"
SELECT
  lr.id::TEXT AS id,
  lr.session_id::TEXT AS session_id,
  ls.account_id::TEXT AS account_id,
  ls.old_device_id,
  lr.user_handle,
  lr.new_device_id,
  lr.n_dh_pub,
  lr.dk_sign_pub,
  lr.dk_dh_pub,
  lr.status,
  lr.approved_device_certificate::TEXT AS approved_device_certificate,
  lr.encrypted_provisioning_blob,
  FLOOR(EXTRACT(EPOCH FROM ls.expires_at) * 1000)::BIGINT AS expires_at_ms,
  FLOOR(EXTRACT(EPOCH FROM lr.completed_at) * 1000)::BIGINT AS completed_at_ms,
  to_char(lr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
FROM device_link_requests lr
JOIN device_link_sessions ls ON ls.id = lr.session_id
WHERE lr.id = $1::uuid
  AND lr.poll_token_hash = $2
"#;

const GET_LINK_REQUEST_BY_ID_SQL: &str = r#"
SELECT
  lr.id::TEXT AS id,
  lr.session_id::TEXT AS session_id,
  ls.account_id::TEXT AS account_id,
  ls.old_device_id,
  lr.user_handle,
  lr.new_device_id,
  lr.n_dh_pub,
  lr.dk_sign_pub,
  lr.dk_dh_pub,
  lr.status,
  lr.approved_device_certificate::TEXT AS approved_device_certificate,
  lr.encrypted_provisioning_blob,
  FLOOR(EXTRACT(EPOCH FROM ls.expires_at) * 1000)::BIGINT AS expires_at_ms,
  FLOOR(EXTRACT(EPOCH FROM lr.completed_at) * 1000)::BIGINT AS completed_at_ms,
  to_char(lr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
FROM device_link_requests lr
JOIN device_link_sessions ls ON ls.id = lr.session_id
WHERE lr.id = $1::uuid
"#;

const FIND_LINK_ACCOUNT_IDENTITY_SQL: &str = r"
SELECT a.user_handle, i.ik_sign_pub AS account_sign_pub
FROM accounts a
JOIN identity_keys i ON i.account_id = a.id
WHERE a.id = $1::uuid
";

const FIND_HOST_DEVICE_SQL: &str = r"
SELECT device_id, device_certificate_chain::TEXT AS device_certificate_chain
FROM devices
WHERE account_id = $1::uuid
  AND device_id = $2
";

const APPROVE_LINK_SESSION_SQL: &str = r"
UPDATE device_link_sessions
SET approved_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
";

const APPROVE_LINK_REQUEST_SQL: &str = r"
UPDATE device_link_requests
SET approved_device_certificate = $3::jsonb,
    encrypted_provisioning_blob = $4,
    status = 'approved',
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
  AND session_id = $2::uuid
RETURNING id::TEXT AS id, status
";

const UPSERT_LINKED_DEVICE_SQL: &str = r"
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
";

const UPSERT_LINKED_SIGNED_PREKEY_SQL: &str = r"
INSERT INTO signed_prekeys (account_id, device_id, prekey_id, signed_prekey_pub, signature, expires_at)
VALUES ($1::uuid, $2, $3, $4, $5, $6::timestamptz)
ON CONFLICT (account_id, device_id)
DO UPDATE SET
  prekey_id = EXCLUDED.prekey_id,
  signed_prekey_pub = EXCLUDED.signed_prekey_pub,
  signature = EXCLUDED.signature,
  expires_at = EXCLUDED.expires_at,
  created_at = CURRENT_TIMESTAMP
";

const INSERT_LINKED_ONE_TIME_PREKEY_SQL: &str = r"
INSERT INTO one_time_prekeys (account_id, device_id, prekey_id, prekey_pub)
VALUES ($1::uuid, $2, $3, $4)
ON CONFLICT (account_id, device_id, prekey_id) DO NOTHING
";

const INSERT_LINK_SESSION_TOKEN_SQL: &str = r"
INSERT INTO sessions (account_id, device_id, token_hash, expires_at)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0))
";

const INSERT_LINK_REFRESH_TOKEN_SQL: &str = r"
INSERT INTO refresh_sessions (account_id, device_id, token_hash, expires_at)
VALUES ($1::uuid, $2, $3, to_timestamp($4::double precision / 1000.0))
";

const MARK_LINK_COMPLETED_SQL: &str = r"
UPDATE device_link_requests
SET completed_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1::uuid
";

/// Async `PostgreSQL` repository for device-link start/request route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresDeviceLinkRepository {
    pool: PgPool,
    token_config: TokenConfig,
    realtime: Option<RealtimeHub>,
}

impl PostgresDeviceLinkRepository {
    #[must_use]
    pub const fn new(pool: PgPool, token_config: TokenConfig) -> Self {
        Self {
            pool,
            token_config,
            realtime: None,
        }
    }

    #[must_use]
    pub const fn with_realtime(
        pool: PgPool,
        token_config: TokenConfig,
        realtime: RealtimeHub,
    ) -> Self {
        Self {
            pool,
            token_config,
            realtime: Some(realtime),
        }
    }

    /// Starts a device-link session from an authenticated host device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the expiry request is invalid, time overflows, or storage fails.
    pub async fn start(
        &self,
        auth: &AuthenticatedSession,
        request: &LinkStartRequest,
        now_ms: u64,
    ) -> Result<LinkStartResponse, ApiError> {
        let expires_in = effective_link_expires_sec(request.expires_in_sec)
            .map_err(|_| ApiError::bad_request("Invalid link session payload"))?;
        let expires_at_ms = now_ms.saturating_add(expires_in.saturating_mul(1_000));
        let expires_at = iso_millis(expires_at_ms)?;
        let expires_at_ms = i64::try_from(expires_at_ms).map_err(|_| ApiError::internal())?;
        let row = sqlx::query(INSERT_LINK_SESSION_SQL)
            .bind(&auth.account_id)
            .bind(&auth.device_id)
            .bind(link_secret_hash(&request.link_code))
            .bind(&request.l_dh_pub)
            .bind(expires_at_ms)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(LinkStartResponse {
            link_session_id: row.try_get("id").map_err(|_| ApiError::internal())?,
            expires_at,
        })
    }

    /// Creates a public new-device link request and returns an opaque poll token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the handle is invalid, the session is unavailable, randomness fails, or storage fails.
    pub async fn request(
        &self,
        request: &LinkRequestCreateRequest,
        now_ms: u64,
    ) -> Result<LinkRequestCreateResponse, ApiError> {
        let handle = normalize_handle(&request.user_handle);
        parse_handle(&handle).map_err(|_| ApiError::bad_request("Invalid user_handle"))?;
        let session = self
            .find_active_session_by_code_hash(&link_secret_hash(&request.link_code), now_ms)
            .await?;
        let Some(session) = session.filter(|session| session.user_handle == handle) else {
            return Err(ApiError::not_found("Link session not found"));
        };
        let poll_token = random_base64_url(POLL_TOKEN_BYTES)?;
        let row = sqlx::query(INSERT_LINK_REQUEST_SQL)
            .bind(&session.id)
            .bind(&handle)
            .bind(request.device_pub_keys.device_id())
            .bind(&request.n_dh_pub)
            .bind(request.device_pub_keys.dk_sign_pub())
            .bind(request.device_pub_keys.dk_dh_pub())
            .bind(link_secret_hash(&poll_token))
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        let request_id: String = row.try_get("id").map_err(|_| ApiError::internal())?;
        let status = parse_link_status(
            &row.try_get::<String, _>("status")
                .map_err(|_| ApiError::internal())?,
        )?;
        self.notify_link_request(
            &session.account_id,
            &request_id,
            request.device_pub_keys.device_id(),
        );

        Ok(LinkRequestCreateResponse {
            request_id,
            status,
            poll_token,
        })
    }

    /// Lists link requests for a host-owned link session.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when durable storage cannot be queried.
    pub async fn list_requests(
        &self,
        auth: &AuthenticatedSession,
        session_id: &str,
    ) -> Result<LinkRequestListResponse, ApiError> {
        let rows = sqlx::query(LIST_LINK_REQUESTS_SQL)
            .bind(session_id)
            .bind(&auth.account_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        let requests = rows
            .iter()
            .map(row_to_link_request_record)
            .map(|request| request.map(request_view))
            .collect::<Result<Vec<_>, _>>()?;

        Ok(LinkRequestListResponse { requests })
    }

    /// Polls one link request using the opaque poll token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the poll token is missing, invalid, or storage lookup fails.
    pub async fn poll(
        &self,
        request_id: &str,
        poll_token: &str,
    ) -> Result<LinkRequestPollResponse, ApiError> {
        let poll_token = poll_token.trim();
        if poll_token.is_empty() {
            return Err(ApiError::bad_request("poll_token is required"));
        }
        let request = self
            .find_request_by_poll_token(request_id, &link_secret_hash(poll_token))
            .await?;
        let Some(request) = request else {
            return Err(ApiError::not_found("Link request not found"));
        };

        Ok(LinkRequestPollResponse {
            request_id: request.id,
            status: request.status,
            approved_device_certificate: request.approved_device_certificate,
            encrypted_provisioning_blob: request.encrypted_provisioning_blob,
        })
    }

    /// Approves one link request from the authenticated host device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when lookup, approval validation, notification, or storage update fails.
    pub async fn approve(
        &self,
        auth: &AuthenticatedSession,
        request: &LinkApproveRequest,
        now_ms: u64,
    ) -> Result<LinkApproveResponse, ApiError> {
        let session = self
            .find_active_session_by_code_hash(&link_secret_hash(&request.link_code), now_ms)
            .await?;
        let Some(session) = session.filter(|session| session.account_id == auth.account_id) else {
            return Err(ApiError::not_found("Link session not found"));
        };
        let link_request = self.get_request_by_id(&request.request_id).await?;
        let identity = self.find_account_identity(&session.account_id).await?;
        let host_device = self
            .find_host_device(&session.account_id, &session.old_device_id)
            .await?;
        let (Some(link_request), Some(identity), Some(host_device)) =
            (link_request, identity, host_device)
        else {
            return Err(ApiError::not_found("Link request not found"));
        };
        if link_request.session_id != session.id {
            return Err(ApiError::not_found("Link request not found"));
        }
        if host_device.certificate_chain.is_empty() {
            return Err(ApiError::conflict(
                "Host device must re-register before approving links",
                None,
            ));
        }
        let new_device_keys = DevicePublicKeys::new(
            link_request.new_device_id.clone(),
            link_request.dk_sign_pub.clone(),
            link_request.dk_dh_pub.clone(),
        );
        validate_device_link_approval(&DeviceLinkApprovalInput {
            account_handle: &identity.user_handle,
            account_sign_pub: &identity.account_sign_pub,
            host_device_id: &host_device.device_id,
            host_certificate_chain: &host_device.certificate_chain,
            approved_certificate: &request.approved_device_certificate,
            new_device_keys: &new_device_keys,
            now_ms,
        })
        .map_err(|error| approval_error(&error))?;

        let approved = self
            .approve_request(
                &session.id,
                &request.request_id,
                &request.approved_device_certificate,
                &request.encrypted_provisioning_blob,
            )
            .await?;
        let Some(approved) = approved else {
            return Err(ApiError::not_found("Link request not found"));
        };
        self.notify_link_approved(&approved.id);

        Ok(LinkApproveResponse {
            request_id: approved.id,
            status: approved.status,
        })
    }

    /// Completes an approved link request and issues tokens for the new device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is missing, invalid, expired, or storage fails.
    pub async fn complete(
        &self,
        request: &LinkCompleteRequest,
        now_ms: u64,
    ) -> Result<LinkCompleteResponse, ApiError> {
        let poll_token = request.poll_token.trim();
        if poll_token.is_empty() {
            return Err(ApiError::bad_request("poll_token is required"));
        }
        let link_request = self
            .find_request_by_poll_token(&request.request_id, &link_secret_hash(poll_token))
            .await?;
        let Some(link_request) = link_request else {
            return Err(ApiError::not_found("Link request not found"));
        };
        validate_complete_request(&link_request, request, now_ms)?;
        let identity = self.find_account_identity(&link_request.account_id).await?;
        let Some(identity) = identity else {
            return Err(ApiError::not_found("Account not found"));
        };
        let host_device = self
            .find_host_device(&link_request.account_id, &link_request.old_device_id)
            .await?;
        let Some(host_device) = host_device else {
            return Err(ApiError::conflict(
                "Link request is missing approval chain",
                None,
            ));
        };
        let Some(approved_certificate) = link_request.approved_device_certificate.as_ref() else {
            return Err(ApiError::conflict(
                "Link request is missing approval chain",
                None,
            ));
        };
        let full_chain = validate_device_link_approval(&DeviceLinkApprovalInput {
            account_handle: &identity.user_handle,
            account_sign_pub: &identity.account_sign_pub,
            host_device_id: &host_device.device_id,
            host_certificate_chain: &host_device.certificate_chain,
            approved_certificate,
            new_device_keys: &request.device_pub_keys,
            now_ms,
        })
        .map_err(|_| ApiError::unauthorized("Invalid device certificate chain"))?;
        validate_publish_request(
            &PrekeyPublishRequest {
                protocol_version: Some(2),
                device_id: request.device_pub_keys.device_id().to_owned(),
                signed_prekey: request.signed_prekey.clone(),
                one_time_prekeys: request.one_time_prekeys.clone(),
            },
            request.device_pub_keys.device_id(),
            true,
        )
        .map_err(|_| ApiError::bad_request("Invalid prekey payload"))?;

        let signed = self.sign_tokens(
            &link_request.account_id,
            &identity.user_handle,
            request.device_pub_keys.device_id(),
            now_ms,
        )?;
        self.complete_transaction(
            &link_request.account_id,
            request,
            &full_chain,
            &signed,
            &link_request.id,
        )
        .await?;

        Ok(LinkCompleteResponse {
            user_handle: identity.user_handle,
            device_id: request.device_pub_keys.device_id().to_owned(),
            tokens: signed.issued,
        })
    }

    async fn find_active_session_by_code_hash(
        &self,
        link_code_hash: &str,
        now_ms: u64,
    ) -> Result<Option<LinkSessionLookup>, ApiError> {
        let now_ms = i64::try_from(now_ms).map_err(|_| ApiError::internal())?;
        sqlx::query(FIND_ACTIVE_LINK_SESSION_SQL)
            .bind(link_code_hash)
            .bind(now_ms)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(LinkSessionLookup {
                    id: row.try_get("id").map_err(|_| ApiError::internal())?,
                    account_id: row
                        .try_get("account_id")
                        .map_err(|_| ApiError::internal())?,
                    user_handle: row
                        .try_get("user_handle")
                        .map_err(|_| ApiError::internal())?,
                    old_device_id: row
                        .try_get("old_device_id")
                        .map_err(|_| ApiError::internal())?,
                })
            })
            .transpose()
    }

    async fn find_request_by_poll_token(
        &self,
        request_id: &str,
        poll_token_hash: &str,
    ) -> Result<Option<LinkRequestRecord>, ApiError> {
        sqlx::query(FIND_LINK_REQUEST_BY_POLL_TOKEN_SQL)
            .bind(request_id)
            .bind(poll_token_hash)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_link_request_record(&row))
            .transpose()
    }

    async fn get_request_by_id(
        &self,
        request_id: &str,
    ) -> Result<Option<LinkRequestRecord>, ApiError> {
        sqlx::query(GET_LINK_REQUEST_BY_ID_SQL)
            .bind(request_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| row_to_link_request_record(&row))
            .transpose()
    }

    async fn find_account_identity(
        &self,
        account_id: &str,
    ) -> Result<Option<LinkAccountIdentity>, ApiError> {
        sqlx::query(FIND_LINK_ACCOUNT_IDENTITY_SQL)
            .bind(account_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(LinkAccountIdentity {
                    user_handle: row
                        .try_get("user_handle")
                        .map_err(|_| ApiError::internal())?,
                    account_sign_pub: row
                        .try_get("account_sign_pub")
                        .map_err(|_| ApiError::internal())?,
                })
            })
            .transpose()
    }

    async fn find_host_device(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<HostDeviceRecord>, ApiError> {
        sqlx::query(FIND_HOST_DEVICE_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                let raw_chain = row
                    .try_get::<String, _>("device_certificate_chain")
                    .map_err(|_| ApiError::internal())?;
                Ok(HostDeviceRecord {
                    device_id: row.try_get("device_id").map_err(|_| ApiError::internal())?,
                    certificate_chain: parse_certificate_chain(&raw_chain)?,
                })
            })
            .transpose()
    }

    async fn approve_request(
        &self,
        session_id: &str,
        request_id: &str,
        approved_device_certificate: &DeviceCertificate,
        encrypted_provisioning_blob: &str,
    ) -> Result<Option<LinkApprovalUpdate>, ApiError> {
        let certificate_json = certificate_json(approved_device_certificate)?;
        let mut transaction = self.pool.begin().await.map_err(|_| ApiError::internal())?;
        sqlx::query(APPROVE_LINK_SESSION_SQL)
            .bind(session_id)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        let row = sqlx::query(APPROVE_LINK_REQUEST_SQL)
            .bind(request_id)
            .bind(session_id)
            .bind(&certificate_json)
            .bind(encrypted_provisioning_blob)
            .fetch_optional(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        transaction
            .commit()
            .await
            .map_err(|_| ApiError::internal())?;

        row.map(|row| {
            Ok(LinkApprovalUpdate {
                id: row.try_get("id").map_err(|_| ApiError::internal())?,
                status: parse_link_status(
                    &row.try_get::<String, _>("status")
                        .map_err(|_| ApiError::internal())?,
                )?,
            })
        })
        .transpose()
    }

    fn sign_tokens(
        &self,
        account_id: &str,
        user_handle: &str,
        device_id: &str,
        now_ms: u64,
    ) -> Result<SignedLinkTokens, ApiError> {
        let issued_at_sec = now_ms / 1_000;
        let session_id = random_uuid_v4()?;
        let subject = TokenSubject::new(
            account_id.to_owned(),
            user_handle.to_owned(),
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

        Ok(SignedLinkTokens {
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

    fn notify_link_request(&self, account_id: &str, request_id: &str, new_device_id: &str) {
        if let Some(realtime) = self.realtime.as_ref() {
            realtime.notify_link_request(account_id, request_id, new_device_id);
        }
    }

    fn notify_link_approved(&self, request_id: &str) {
        if let Some(realtime) = self.realtime.as_ref() {
            realtime.notify_link_approved(request_id);
        }
    }

    async fn complete_transaction(
        &self,
        account_id: &str,
        request: &LinkCompleteRequest,
        certificate_chain: &[DeviceCertificate],
        signed: &SignedLinkTokens,
        request_id: &str,
    ) -> Result<(), ApiError> {
        let certificate_chain_json = certificate_chain_json(certificate_chain)?;
        let mut transaction = self.pool.begin().await.map_err(|_| ApiError::internal())?;
        sqlx::query(UPSERT_LINKED_DEVICE_SQL)
            .bind(account_id)
            .bind(request.device_pub_keys.device_id())
            .bind(request.device_pub_keys.dk_sign_pub())
            .bind(request.device_pub_keys.dk_dh_pub())
            .bind(&certificate_chain_json)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(UPSERT_LINKED_SIGNED_PREKEY_SQL)
            .bind(account_id)
            .bind(request.device_pub_keys.device_id())
            .bind(&request.signed_prekey.prekey_id)
            .bind(&request.signed_prekey.signed_prekey_pub)
            .bind(&request.signed_prekey.signature)
            .bind(request.signed_prekey.expires_at.as_deref())
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        for prekey in &request.one_time_prekeys {
            sqlx::query(INSERT_LINKED_ONE_TIME_PREKEY_SQL)
                .bind(account_id)
                .bind(request.device_pub_keys.device_id())
                .bind(&prekey.prekey_id)
                .bind(&prekey.prekey_pub)
                .execute(&mut *transaction)
                .await
                .map_err(|_| ApiError::internal())?;
        }
        sqlx::query(INSERT_LINK_SESSION_TOKEN_SQL)
            .bind(account_id)
            .bind(request.device_pub_keys.device_id())
            .bind(&signed.session_hash)
            .bind(i64::try_from(signed.session_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(INSERT_LINK_REFRESH_TOKEN_SQL)
            .bind(account_id)
            .bind(request.device_pub_keys.device_id())
            .bind(&signed.refresh_hash)
            .bind(i64::try_from(signed.refresh_expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        sqlx::query(MARK_LINK_COMPLETED_SQL)
            .bind(request_id)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::internal())?;
        transaction.commit().await.map_err(|_| ApiError::internal())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LinkSessionLookup {
    id: String,
    account_id: String,
    user_handle: String,
    old_device_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LinkApprovalUpdate {
    id: String,
    status: LinkRequestStatus,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SignedLinkTokens {
    session_hash: String,
    refresh_hash: String,
    session_expires_at_ms: u64,
    refresh_expires_at_ms: u64,
    issued: IssuedTokens,
}

fn row_to_link_request_record(row: &PgRow) -> Result<LinkRequestRecord, ApiError> {
    let status = parse_link_status(
        &row.try_get::<String, _>("status")
            .map_err(|_| ApiError::internal())?,
    )?;
    Ok(LinkRequestRecord {
        id: row.try_get("id").map_err(|_| ApiError::internal())?,
        session_id: row
            .try_get("session_id")
            .map_err(|_| ApiError::internal())?,
        account_id: row
            .try_get("account_id")
            .map_err(|_| ApiError::internal())?,
        old_device_id: row
            .try_get("old_device_id")
            .map_err(|_| ApiError::internal())?,
        user_handle: row
            .try_get("user_handle")
            .map_err(|_| ApiError::internal())?,
        new_device_id: row
            .try_get("new_device_id")
            .map_err(|_| ApiError::internal())?,
        n_dh_pub: row.try_get("n_dh_pub").map_err(|_| ApiError::internal())?,
        dk_sign_pub: row
            .try_get("dk_sign_pub")
            .map_err(|_| ApiError::internal())?,
        dk_dh_pub: row.try_get("dk_dh_pub").map_err(|_| ApiError::internal())?,
        status,
        approved_device_certificate: optional_certificate(row, "approved_device_certificate")?,
        encrypted_provisioning_blob: row
            .try_get("encrypted_provisioning_blob")
            .map_err(|_| ApiError::internal())?,
        expires_at_ms: non_negative_millis(
            row.try_get("expires_at_ms")
                .map_err(|_| ApiError::internal())?,
        )?,
        completed_at_ms: optional_millis(
            row.try_get("completed_at_ms")
                .map_err(|_| ApiError::internal())?,
        )?,
        created_at: row
            .try_get("created_at")
            .map_err(|_| ApiError::internal())?,
    })
}

fn optional_certificate(row: &PgRow, column: &str) -> Result<Option<DeviceCertificate>, ApiError> {
    row.try_get::<Option<String>, _>(column)
        .map_err(|_| ApiError::internal())?
        .map(|raw| serde_json::from_str(&raw).map_err(|_| ApiError::internal()))
        .transpose()
}

fn non_negative_millis(value: i64) -> Result<u64, ApiError> {
    u64::try_from(value).map_err(|_| ApiError::internal())
}

fn optional_millis(value: Option<i64>) -> Result<Option<u64>, ApiError> {
    value.map(non_negative_millis).transpose()
}

fn parse_certificate_chain(raw: &str) -> Result<Vec<DeviceCertificate>, ApiError> {
    serde_json::from_str(raw).map_err(|_| ApiError::internal())
}

fn certificate_json(certificate: &DeviceCertificate) -> Result<String, ApiError> {
    serde_json::to_string(certificate).map_err(|_| ApiError::internal())
}

fn certificate_chain_json(certificates: &[DeviceCertificate]) -> Result<String, ApiError> {
    serde_json::to_string(certificates).map_err(|_| ApiError::internal())
}

fn parse_link_status(raw: &str) -> Result<LinkRequestStatus, ApiError> {
    match raw {
        "pending" => Ok(LinkRequestStatus::Pending),
        "approved" => Ok(LinkRequestStatus::Approved),
        _ => Err(ApiError::internal()),
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
        0..=9 => (b'0' + value) as char,
        _ => (b'a' + (value - 10)) as char,
    }
}

const fn approval_error(error: &DeviceError) -> ApiError {
    match error {
        DeviceError::EmptyHostCertificateChain => {
            ApiError::conflict("Host device must re-register before approving links", None)
        }
        DeviceError::InvalidApprovedDeviceCertificate | DeviceError::AuthContract(_) => {
            ApiError::unauthorized("Invalid approved device certificate")
        }
        DeviceError::LinkExpiryOutOfRange => ApiError::bad_request("Invalid link session payload"),
    }
}

fn iso_millis(unix_ms: u64) -> Result<String, ApiError> {
    let seconds = i64::try_from(unix_ms / 1_000).map_err(|_| ApiError::internal())?;
    let millis = unix_ms % 1_000;
    let datetime =
        OffsetDateTime::from_unix_timestamp(seconds).map_err(|_| ApiError::internal())?;
    Ok(format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        datetime.year(),
        u8::from(datetime.month()),
        datetime.day(),
        datetime.hour(),
        datetime.minute(),
        datetime.second(),
        millis
    ))
}

#[must_use]
pub const fn device_link_repository_query_contract() -> &'static [&'static str] {
    &[
        INSERT_LINK_SESSION_SQL,
        FIND_ACTIVE_LINK_SESSION_SQL,
        INSERT_LINK_REQUEST_SQL,
        LIST_LINK_REQUESTS_SQL,
        FIND_LINK_REQUEST_BY_POLL_TOKEN_SQL,
        GET_LINK_REQUEST_BY_ID_SQL,
        FIND_LINK_ACCOUNT_IDENTITY_SQL,
        FIND_HOST_DEVICE_SQL,
        APPROVE_LINK_SESSION_SQL,
        APPROVE_LINK_REQUEST_SQL,
        UPSERT_LINKED_DEVICE_SQL,
        UPSERT_LINKED_SIGNED_PREKEY_SQL,
        INSERT_LINKED_ONE_TIME_PREKEY_SQL,
        INSERT_LINK_SESSION_TOKEN_SQL,
        INSERT_LINK_REFRESH_TOKEN_SQL,
        MARK_LINK_COMPLETED_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        device_link_repository_query_contract, parse_link_status, random_base64_url,
        random_uuid_v4, APPROVE_LINK_REQUEST_SQL, FIND_ACTIVE_LINK_SESSION_SQL,
        FIND_LINK_REQUEST_BY_POLL_TOKEN_SQL, INSERT_LINK_REFRESH_TOKEN_SQL,
        INSERT_LINK_REQUEST_SQL, INSERT_LINK_SESSION_SQL, INSERT_LINK_SESSION_TOKEN_SQL,
        LIST_LINK_REQUESTS_SQL, MARK_LINK_COMPLETED_SQL, UPSERT_LINKED_DEVICE_SQL,
    };
    use crate::device_link_service::LinkRequestStatus;

    #[test]
    fn link_start_and_request_queries_are_parameterized() {
        for query in device_link_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(INSERT_LINK_SESSION_SQL.contains("$1::uuid"));
        assert!(INSERT_LINK_SESSION_SQL.contains("to_timestamp($5::double precision / 1000.0)"));
        assert!(INSERT_LINK_SESSION_SQL.contains("id::TEXT AS id"));
        assert!(FIND_ACTIVE_LINK_SESSION_SQL.contains("link_code_hash = $1"));
        assert!(FIND_ACTIVE_LINK_SESSION_SQL.contains("expires_at > to_timestamp($2"));
        assert!(INSERT_LINK_REQUEST_SQL.contains("poll_token_hash"));
        assert!(INSERT_LINK_REQUEST_SQL.contains("RETURNING id::TEXT AS id"));
        assert!(LIST_LINK_REQUESTS_SQL.contains("ls.account_id = $2::uuid"));
        assert!(FIND_LINK_REQUEST_BY_POLL_TOKEN_SQL.contains("lr.poll_token_hash = $2"));
        assert!(APPROVE_LINK_REQUEST_SQL.contains("approved_device_certificate = $3::jsonb"));
        assert!(UPSERT_LINKED_DEVICE_SQL.contains("ON CONFLICT (account_id, device_id)"));
        assert!(INSERT_LINK_SESSION_TOKEN_SQL.contains("token_hash"));
        assert!(INSERT_LINK_REFRESH_TOKEN_SQL.contains("refresh_sessions"));
        assert!(MARK_LINK_COMPLETED_SQL.contains("completed_at = CURRENT_TIMESTAMP"));
    }

    #[test]
    fn poll_tokens_are_url_safe_without_padding() {
        let token = random_base64_url(super::POLL_TOKEN_BYTES);

        assert!(token.is_ok());
        let Ok(token) = token else {
            return;
        };
        assert_eq!(token.len(), 16);
        assert!(!token.contains('='));
        assert!(token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')));
    }

    #[test]
    fn link_completion_session_ids_are_uuid_v4_shaped() {
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
    fn link_status_parser_rejects_unknown_values() {
        assert_eq!(
            parse_link_status("approved"),
            Ok(LinkRequestStatus::Approved)
        );
        assert_eq!(parse_link_status("pending"), Ok(LinkRequestStatus::Pending));
        assert_eq!(
            parse_link_status("expired"),
            Err(crate::auth_service::ApiError::internal())
        );
    }
}
