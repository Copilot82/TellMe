//! Service-level auth contract that sits between HTTP routes and durable storage.
//!
//! The functions here mirror the current TypeScript route semantics while keeping the storage backend abstract. A
//! `Postgres` implementation can be added behind `AuthStore` without changing the protocol decisions tested here.

use crate::auth::{
    normalize_handle, parse_handle, registration_signature_valid, registration_timestamp_fresh,
    verify_ed25519, ContractError, DeviceCertificate,
};
use crate::devices::{validate_device_registration, DevicePublicKeys, DeviceRegistrationInput};
use crate::session::{
    bearer_token, sign_refresh_token, sign_session_token, token_hash, verify_refresh_token,
    verify_session_token, SessionClaims, TokenConfig, TokenKind, TokenSubject,
};
use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

/// Auth challenge lifetime used by `/api/auth/start`.
// Keep challenge windows short because nonce signatures are valid until the challenge expires.
pub const AUTH_CHALLENGE_TTL_MS: u64 = 5 * 60 * 1_000;

/// Stable API error status values used by auth routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiStatus {
    Ok,
    Created,
    Accepted,
    NoContent,
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    Gone,
    Conflict,
    UnprocessableEntity,
    InternalServerError,
}

impl ApiStatus {
    #[must_use]
    pub const fn code(self) -> u16 {
        match self {
            Self::Ok => 200,
            Self::Created => 201,
            Self::Accepted => 202,
            Self::NoContent => 204,
            Self::BadRequest => 400,
            Self::Unauthorized => 401,
            Self::Forbidden => 403,
            Self::NotFound => 404,
            Self::Gone => 410,
            Self::Conflict => 409,
            Self::UnprocessableEntity => 422,
            Self::InternalServerError => 500,
        }
    }
}

/// JSON-shaped API error payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApiError {
    #[serde(skip)]
    status: ApiStatus,
    error: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'static str>,
}

impl ApiError {
    #[must_use]
    pub const fn new(status: ApiStatus, error: &'static str, code: Option<&'static str>) -> Self {
        Self {
            status,
            error,
            code,
        }
    }

    #[must_use]
    pub const fn bad_request(error: &'static str) -> Self {
        Self::new(ApiStatus::BadRequest, error, None)
    }

    #[must_use]
    pub const fn unauthorized(error: &'static str) -> Self {
        Self::new(ApiStatus::Unauthorized, error, None)
    }

    #[must_use]
    pub const fn forbidden(error: &'static str) -> Self {
        Self::new(ApiStatus::Forbidden, error, None)
    }

    #[must_use]
    pub const fn not_found(error: &'static str) -> Self {
        Self::new(ApiStatus::NotFound, error, None)
    }

    #[must_use]
    pub const fn gone(error: &'static str) -> Self {
        Self::new(ApiStatus::Gone, error, None)
    }

    #[must_use]
    pub const fn conflict(error: &'static str, code: Option<&'static str>) -> Self {
        Self::new(ApiStatus::Conflict, error, code)
    }

    #[must_use]
    pub const fn unprocessable(error: &'static str) -> Self {
        Self::new(ApiStatus::UnprocessableEntity, error, None)
    }

    #[must_use]
    pub const fn internal() -> Self {
        Self::new(
            ApiStatus::InternalServerError,
            "Internal server error",
            None,
        )
    }

    #[must_use]
    pub const fn status(&self) -> ApiStatus {
        self.status
    }

    #[must_use]
    pub const fn error(&self) -> &'static str {
        self.error
    }

    #[must_use]
    pub const fn code(&self) -> Option<&'static str> {
        self.code
    }
}

impl Display for ApiError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.error)
    }
}

impl Error for ApiError {}

/// Storage-layer failure. The route layer intentionally maps this to a generic `500`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoreError;

impl Display for StoreError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("auth storage error")
    }
}

impl Error for StoreError {}

/// Minimal account row required by auth flows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountRecord {
    id: String,
    user_handle: String,
}

impl AccountRecord {
    #[must_use]
    pub const fn new(id: String, user_handle: String) -> Self {
        Self { id, user_handle }
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    #[must_use]
    pub fn user_handle(&self) -> &str {
        &self.user_handle
    }
}

/// Identity keys row required by idempotent registration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityRecord {
    ik_sign_pub: String,
    ik_dh_pub: String,
}

impl IdentityRecord {
    #[must_use]
    pub const fn new(ik_sign_pub: String, ik_dh_pub: String) -> Self {
        Self {
            ik_sign_pub,
            ik_dh_pub,
        }
    }

    #[must_use]
    pub fn ik_sign_pub(&self) -> &str {
        &self.ik_sign_pub
    }

    #[must_use]
    pub fn ik_dh_pub(&self) -> &str {
        &self.ik_dh_pub
    }
}

/// Device state relevant to challenge finish.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceState {
    Active,
    Revoked,
}

/// Minimal device row required by auth flows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    account_id: String,
    device_id: String,
    dk_sign_pub: String,
    dk_dh_pub: String,
    state: DeviceState,
    device_certificate_chain: Vec<DeviceCertificate>,
}

impl DeviceRecord {
    #[must_use]
    pub const fn new(
        account_id: String,
        device_id: String,
        dk_sign_pub: String,
        dk_dh_pub: String,
        state: DeviceState,
        device_certificate_chain: Vec<DeviceCertificate>,
    ) -> Self {
        Self {
            account_id,
            device_id,
            dk_sign_pub,
            dk_dh_pub,
            state,
            device_certificate_chain,
        }
    }

    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    #[must_use]
    pub fn dk_sign_pub(&self) -> &str {
        &self.dk_sign_pub
    }

    #[must_use]
    pub fn dk_dh_pub(&self) -> &str {
        &self.dk_dh_pub
    }

    #[must_use]
    pub fn device_certificate_chain(&self) -> &[DeviceCertificate] {
        &self.device_certificate_chain
    }

    #[must_use]
    pub const fn is_challenge_capable(&self) -> bool {
        matches!(self.state, DeviceState::Active) && !self.device_certificate_chain.is_empty()
    }
}

/// Auth challenge row returned by storage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthChallengeRecord {
    challenge_id: String,
    account_id: Option<String>,
    device_id: Option<String>,
    nonce: String,
    expires_at_ms: u64,
}

impl AuthChallengeRecord {
    #[must_use]
    pub const fn new(
        challenge_id: String,
        account_id: Option<String>,
        device_id: Option<String>,
        nonce: String,
        expires_at_ms: u64,
    ) -> Self {
        Self {
            challenge_id,
            account_id,
            device_id,
            nonce,
            expires_at_ms,
        }
    }

    #[must_use]
    pub fn challenge_id(&self) -> &str {
        &self.challenge_id
    }

    #[must_use]
    pub fn account_id(&self) -> Option<&str> {
        self.account_id.as_deref()
    }

    #[must_use]
    pub fn device_id(&self) -> Option<&str> {
        self.device_id.as_deref()
    }

    #[must_use]
    pub fn nonce(&self) -> &str {
        &self.nonce
    }

    #[must_use]
    pub const fn expires_at_ms(&self) -> u64 {
        self.expires_at_ms
    }
}

/// Storage input for creating one auth challenge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CreateAuthChallenge<'a> {
    pub account_id: Option<&'a str>,
    pub device_id: Option<&'a str>,
    pub nonce: &'a str,
    pub expires_at_ms: u64,
}

/// Storage input for persisted session tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PersistToken<'a> {
    pub account_id: &'a str,
    pub device_id: &'a str,
    pub token_hash: &'a str,
    pub expires_at_ms: u64,
}

/// Storage input for creating a complete first-device account registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CreateAccountWithDevice<'a> {
    pub user_handle: &'a str,
    pub home_server: &'a str,
    pub ik_sign_pub: &'a str,
    pub ik_dh_pub: &'a str,
    pub proof_signature: &'a str,
    pub proof_timestamp: &'a str,
    pub initial_device: &'a InitialDeviceRegistration,
}

/// Storage boundary used by auth service functions.
pub trait AuthStore {
    /// Finds an account by normalized user handle.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_by_handle(
        &mut self,
        user_handle: &str,
    ) -> Result<Option<AccountRecord>, StoreError>;

    /// Finds an account by internal id.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_by_id(&mut self, account_id: &str)
        -> Result<Option<AccountRecord>, StoreError>;

    /// Finds identity keys for an account.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_identity_keys(
        &mut self,
        account_id: &str,
    ) -> Result<Option<IdentityRecord>, StoreError>;

    /// Creates an account with its identity keys and initial device in one transaction.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot create the account/device tuple.
    fn create_account_with_identity_and_device(
        &mut self,
        input: CreateAccountWithDevice<'_>,
    ) -> Result<AccountRecord, StoreError>;

    /// Creates an auth challenge.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot create the challenge.
    fn create_auth_challenge(
        &mut self,
        input: CreateAuthChallenge<'_>,
    ) -> Result<AuthChallengeRecord, StoreError>;

    /// Finds an active unused challenge for the account.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_active_challenge(
        &mut self,
        challenge_id: &str,
        account_id: &str,
        now_ms: u64,
    ) -> Result<Option<AuthChallengeRecord>, StoreError>;

    /// Marks an auth challenge as used.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the challenge.
    fn mark_challenge_used(&mut self, challenge_id: &str) -> Result<(), StoreError>;

    /// Finds a device row for the account/device tuple.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_device(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<DeviceRecord>, StoreError>;

    /// Persists a session token hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the session.
    fn insert_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError>;

    /// Persists a refresh token hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the refresh session.
    fn insert_refresh_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError>;

    /// Checks whether a session token hash is active.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn session_token_active(&mut self, token_hash: &str, now_ms: u64) -> Result<bool, StoreError>;

    /// Checks whether a refresh token hash is active.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn refresh_token_active(&mut self, token_hash: &str, now_ms: u64) -> Result<bool, StoreError>;

    /// Rotates one refresh token hash to a new one.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot rotate the refresh token.
    fn rotate_refresh_token(
        &mut self,
        old_hash: &str,
        new_hash: &str,
        new_expires_at_ms: u64,
    ) -> Result<(), StoreError>;

    /// Revokes one session token hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the session.
    fn revoke_session_token(&mut self, token_hash: &str) -> Result<(), StoreError>;

    /// Revokes one refresh token hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the refresh session.
    fn revoke_refresh_token(&mut self, token_hash: &str) -> Result<(), StoreError>;
}

/// Request body for `/api/auth/start`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct AuthStartRequest {
    pub user_handle: String,
    pub device_id: Option<String>,
}

/// Deterministic runtime inputs for `/api/auth/start`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthStartContext {
    pub nonce: String,
    pub now_ms: u64,
}

/// Response body for `/api/auth/start`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AuthStartResponse {
    pub challenge_id: String,
    pub nonce: String,
    pub expires_at: String,
}

/// Initial-device registration payload for `/api/auth/register`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct InitialDeviceRegistration {
    pub device_id: String,
    pub dk_sign_pub: String,
    pub dk_dh_pub: String,
    pub device_certificate_chain: Vec<DeviceCertificate>,
}

impl InitialDeviceRegistration {
    #[must_use]
    pub fn device_keys(&self) -> DevicePublicKeys {
        DevicePublicKeys::new(
            self.device_id.clone(),
            self.dk_sign_pub.clone(),
            self.dk_dh_pub.clone(),
        )
    }
}

/// Request body for `/api/auth/register`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RegisterRequest {
    pub user_handle: String,
    pub ik_sign_pub: String,
    pub ik_dh_pub: String,
    pub signature: String,
    pub timestamp: String,
    pub initial_device: InitialDeviceRegistration,
}

/// Deterministic runtime inputs for `/api/auth/register`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegisterContext {
    pub server_domain: String,
    pub token_context: IssueTokenContext,
}

/// Response body for `/api/auth/register`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RegisterResponse {
    #[serde(skip)]
    pub status: ApiStatus,
    pub user_handle: String,
    pub device_id: String,
    #[serde(flatten)]
    pub tokens: IssuedTokens,
}

/// Request body for `/api/auth/finish`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct AuthFinishRequest {
    pub user_handle: String,
    pub device_id: String,
    pub challenge_id: String,
    pub signature: String,
}

/// Deterministic runtime inputs for token issuance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssueTokenContext {
    pub session_id: String,
    pub issued_at_sec: u64,
    pub now_ms: u64,
}

/// Request body for `/api/auth/refresh`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

/// Request body for `/api/auth/logout`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LogoutRequest {
    pub session_token: Option<String>,
    pub refresh_token: Option<String>,
}

/// Token issuance response used by auth register, finish, and refresh.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IssuedTokens {
    pub session_token: String,
    pub refresh_token: String,
    pub expires_in: u64,
}

/// Successful logout response.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct LogoutResponse {
    pub success: bool,
}

/// Authenticated session extracted by session middleware.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedSession {
    pub account_id: String,
    pub user_handle: String,
    pub device_id: String,
    pub session_id: String,
}

/// Service implementation for auth route semantics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthService {
    token_config: TokenConfig,
}

impl AuthService {
    #[must_use]
    pub const fn new(token_config: TokenConfig) -> Self {
        Self { token_config }
    }

    /// Registers a first device and issues tokens, preserving current idempotent re-registration semantics.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for invalid handle/domain, stale or bad signatures, account conflicts, token signing failures,
    /// or storage failures.
    pub fn register<S: AuthStore>(
        &self,
        store: &mut S,
        request: &RegisterRequest,
        context: &RegisterContext,
    ) -> Result<RegisterResponse, ApiError> {
        let parsed = parse_handle(&request.user_handle)
            .map_err(|_| ApiError::bad_request("Invalid user_handle format"))?;
        if parsed.domain() != context.server_domain {
            return Err(ApiError::bad_request(
                "user_handle domain must match home server",
            ));
        }
        let timestamp_ms = parse_timestamp_ms(&request.timestamp)
            .map_err(|_| ApiError::bad_request("Registration timestamp is out of allowed range"))?;
        if !registration_timestamp_fresh(context.token_context.now_ms, timestamp_ms) {
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
        validate_initial_device(parsed.normalized(), request, context.token_context.now_ms)?;

        let existing = store
            .find_account_by_handle(parsed.normalized())
            .map_err(|_| ApiError::internal())?;
        if let Some(account) = existing {
            return self.register_existing(store, request, &account, &context.token_context);
        }

        let created = store
            .create_account_with_identity_and_device(CreateAccountWithDevice {
                user_handle: parsed.normalized(),
                home_server: parsed.domain(),
                ik_sign_pub: &request.ik_sign_pub,
                ik_dh_pub: &request.ik_dh_pub,
                proof_signature: &request.signature,
                proof_timestamp: &request.timestamp,
                initial_device: &request.initial_device,
            })
            .map_err(|_| ApiError::conflict("Account already exists", None))?;
        let tokens = self.issue_tokens(
            store,
            &created,
            &request.initial_device.device_id,
            &context.token_context,
        )?;

        Ok(RegisterResponse {
            status: ApiStatus::Created,
            user_handle: created.user_handle().to_owned(),
            device_id: request.initial_device.device_id.clone(),
            tokens,
        })
    }

    /// Starts an auth challenge with the same anonymous account-probing semantics as TypeScript.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` for validation errors or storage failures.
    pub fn start<S: AuthStore>(
        &self,
        store: &mut S,
        request: &AuthStartRequest,
        context: &AuthStartContext,
    ) -> Result<AuthStartResponse, ApiError> {
        if request.user_handle.trim().is_empty() {
            return Err(ApiError::bad_request("user_handle is required"));
        }

        let handle = normalize_handle(&request.user_handle);
        let account = store
            .find_account_by_handle(&handle)
            .map_err(|_| ApiError::internal())?;
        let account_id = account.as_ref().map(AccountRecord::id);
        let expires_at_ms = context.now_ms.saturating_add(AUTH_CHALLENGE_TTL_MS);
        let challenge = store
            .create_auth_challenge(CreateAuthChallenge {
                account_id,
                device_id: request.device_id.as_deref(),
                nonce: &context.nonce,
                expires_at_ms,
            })
            .map_err(|_| ApiError::internal())?;

        Ok(AuthStartResponse {
            challenge_id: challenge.challenge_id().to_owned(),
            nonce: challenge.nonce().to_owned(),
            expires_at: iso_millis(challenge.expires_at_ms())?,
        })
    }

    /// Finishes an auth challenge and issues session/refresh tokens.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the account, challenge, device, signature, token signing, or storage step fails.
    pub fn finish<S: AuthStore>(
        &self,
        store: &mut S,
        request: &AuthFinishRequest,
        context: &IssueTokenContext,
    ) -> Result<IssuedTokens, ApiError> {
        let handle = normalize_handle(&request.user_handle);
        let account = find_account_for_finish(store, &handle)?;
        let challenge =
            find_challenge_for_finish(store, &request.challenge_id, account.id(), context.now_ms)?;
        let device = store
            .find_device(account.id(), &request.device_id)
            .map_err(|_| ApiError::internal())?;

        let Some(active_device) = device.filter(DeviceRecord::is_challenge_capable) else {
            store
                .mark_challenge_used(&request.challenge_id)
                .map_err(|_| ApiError::internal())?;
            return Err(ApiError::conflict(
                "Device link required",
                Some("device_link_required"),
            ));
        };

        if !verify_ed25519(
            challenge.nonce(),
            &request.signature,
            active_device.dk_sign_pub(),
        )
        .unwrap_or(false)
        {
            return Err(ApiError::unauthorized("Invalid challenge or signature"));
        }

        store
            .mark_challenge_used(&request.challenge_id)
            .map_err(|_| ApiError::internal())?;

        self.issue_tokens(store, &account, &request.device_id, context)
    }

    /// Authenticates a session bearer token using signed claims and active-token storage state.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` with `401` semantics when the header, token, or active-token lookup is invalid.
    pub fn authenticate_session<S: AuthStore>(
        &self,
        store: &mut S,
        authorization_header: Option<&str>,
        now_sec: u64,
        now_ms: u64,
    ) -> Result<AuthenticatedSession, ApiError> {
        let Some(token) = authorization_header.and_then(bearer_token) else {
            return Err(ApiError::unauthorized("Unauthorized"));
        };
        let Some(claims) = verify_session_token(token, &self.token_config, now_sec) else {
            return Err(ApiError::unauthorized("Unauthorized"));
        };
        if claims.token_type() != TokenKind::Session {
            return Err(ApiError::unauthorized("Unauthorized"));
        }
        let hash = token_hash(token);
        let active = store
            .session_token_active(&hash, now_ms)
            .map_err(|_| ApiError::unauthorized("Unauthorized"))?;
        if !active {
            return Err(ApiError::unauthorized("Unauthorized"));
        }

        Ok(session_from_claims(&claims))
    }

    /// Rotates a refresh token and issues a new session token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the refresh token is invalid, inactive, or cannot be rotated.
    pub fn refresh<S: AuthStore>(
        &self,
        store: &mut S,
        request: &RefreshRequest,
        context: &IssueTokenContext,
    ) -> Result<IssuedTokens, ApiError> {
        let Some(claims) = verify_refresh_token(
            &request.refresh_token,
            &self.token_config,
            context.issued_at_sec,
        ) else {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        };
        if claims.token_type() != TokenKind::Refresh {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        }

        let old_hash = token_hash(&request.refresh_token);
        let active = store
            .refresh_token_active(&old_hash, context.now_ms)
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;
        if !active {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        }

        let Some(account) = store
            .find_account_by_id(claims.account_id())
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?
        else {
            return Err(ApiError::unauthorized("Invalid refresh token"));
        };

        self.rotate_tokens(store, &account, claims.device_id(), &old_hash, context)
    }

    /// Revokes supplied tokens. Invalid authorization headers are ignored here because session middleware authenticates
    /// the route before this service method runs.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when token revocation storage updates fail.
    pub fn logout<S: AuthStore>(
        &self,
        store: &mut S,
        authorization_header: Option<&str>,
        request: &LogoutRequest,
        now_sec: u64,
    ) -> Result<LogoutResponse, ApiError> {
        if let Some(header_token) = authorization_header.and_then(bearer_token) {
            if verify_session_token(header_token, &self.token_config, now_sec).is_some() {
                let hash = token_hash(header_token);
                store
                    .revoke_session_token(&hash)
                    .map_err(|_| ApiError::internal())?;
            }
        }

        if let Some(session_token) = request.session_token.as_deref() {
            let hash = token_hash(session_token);
            store
                .revoke_session_token(&hash)
                .map_err(|_| ApiError::internal())?;
        }

        if let Some(refresh_token) = request.refresh_token.as_deref() {
            let hash = token_hash(refresh_token);
            store
                .revoke_refresh_token(&hash)
                .map_err(|_| ApiError::internal())?;
        }

        Ok(LogoutResponse { success: true })
    }

    fn issue_tokens<S: AuthStore>(
        &self,
        store: &mut S,
        account: &AccountRecord,
        device_id: &str,
        context: &IssueTokenContext,
    ) -> Result<IssuedTokens, ApiError> {
        let (issued, session_hash, refresh_hash) = self.sign_tokens(account, device_id, context)?;
        store
            .insert_session(PersistToken {
                account_id: account.id(),
                device_id,
                token_hash: &session_hash,
                expires_at_ms: token_expires_at_ms(
                    context.issued_at_sec,
                    self.token_config.session_ttl_sec(),
                ),
            })
            .map_err(|_| ApiError::internal())?;
        store
            .insert_refresh_session(PersistToken {
                account_id: account.id(),
                device_id,
                token_hash: &refresh_hash,
                expires_at_ms: token_expires_at_ms(
                    context.issued_at_sec,
                    self.token_config.refresh_ttl_sec(),
                ),
            })
            .map_err(|_| ApiError::internal())?;

        Ok(issued)
    }

    fn register_existing<S: AuthStore>(
        &self,
        store: &mut S,
        request: &RegisterRequest,
        account: &AccountRecord,
        context: &IssueTokenContext,
    ) -> Result<RegisterResponse, ApiError> {
        let identity = store
            .find_identity_keys(account.id())
            .map_err(|_| ApiError::internal())?;
        let device = store
            .find_device(account.id(), &request.initial_device.device_id)
            .map_err(|_| ApiError::internal())?;
        if registration_matches_existing(identity.as_ref(), device.as_ref(), request) {
            let tokens =
                self.issue_tokens(store, account, &request.initial_device.device_id, context)?;
            return Ok(RegisterResponse {
                status: ApiStatus::Ok,
                user_handle: account.user_handle().to_owned(),
                device_id: request.initial_device.device_id.clone(),
                tokens,
            });
        }

        Err(ApiError::conflict("Account already exists", None))
    }

    fn rotate_tokens<S: AuthStore>(
        &self,
        store: &mut S,
        account: &AccountRecord,
        device_id: &str,
        old_refresh_hash: &str,
        context: &IssueTokenContext,
    ) -> Result<IssuedTokens, ApiError> {
        let (issued, session_hash, refresh_hash) = self.sign_tokens(account, device_id, context)?;
        store
            .insert_session(PersistToken {
                account_id: account.id(),
                device_id,
                token_hash: &session_hash,
                expires_at_ms: token_expires_at_ms(
                    context.issued_at_sec,
                    self.token_config.session_ttl_sec(),
                ),
            })
            .map_err(|_| ApiError::internal())?;
        store
            .rotate_refresh_token(
                old_refresh_hash,
                &refresh_hash,
                token_expires_at_ms(context.issued_at_sec, self.token_config.refresh_ttl_sec()),
            )
            .map_err(|_| ApiError::unauthorized("Invalid refresh token"))?;

        Ok(issued)
    }

    fn sign_tokens(
        &self,
        account: &AccountRecord,
        device_id: &str,
        context: &IssueTokenContext,
    ) -> Result<(IssuedTokens, String, String), ApiError> {
        let subject = TokenSubject::new(
            account.id().to_owned(),
            account.user_handle().to_owned(),
            device_id.to_owned(),
            context.session_id.clone(),
        );
        let session_token = sign_session_token(&subject, &self.token_config, context.issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let refresh_token = sign_refresh_token(&subject, &self.token_config, context.issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let session_hash = token_hash(&session_token);
        let refresh_hash = token_hash(&refresh_token);

        Ok((
            IssuedTokens {
                session_token,
                refresh_token,
                expires_in: self.token_config.session_ttl_sec(),
            },
            session_hash,
            refresh_hash,
        ))
    }
}

fn find_account_for_finish<S: AuthStore>(
    store: &mut S,
    handle: &str,
) -> Result<AccountRecord, ApiError> {
    let account = store
        .find_account_by_handle(handle)
        .map_err(|_| ApiError::internal())?;
    account.ok_or_else(|| ApiError::unauthorized("Invalid challenge or signature"))
}

fn find_challenge_for_finish<S: AuthStore>(
    store: &mut S,
    challenge_id: &str,
    account_id: &str,
    now_ms: u64,
) -> Result<AuthChallengeRecord, ApiError> {
    let challenge = store
        .find_active_challenge(challenge_id, account_id, now_ms)
        .map_err(|_| ApiError::internal())?;
    challenge.ok_or_else(|| ApiError::unauthorized("Invalid challenge or signature"))
}

fn session_from_claims(claims: &SessionClaims) -> AuthenticatedSession {
    AuthenticatedSession {
        account_id: claims.account_id().to_owned(),
        user_handle: claims.user_handle().to_owned(),
        device_id: claims.device_id().to_owned(),
        session_id: claims.session_id().to_owned(),
    }
}

const fn token_expires_at_ms(issued_at_sec: u64, ttl_sec: u64) -> u64 {
    issued_at_sec.saturating_add(ttl_sec).saturating_mul(1_000)
}

fn parse_timestamp_ms(timestamp: &str) -> Result<u64, ContractError> {
    let parsed =
        OffsetDateTime::parse(timestamp, &Rfc3339).map_err(|_| ContractError::InvalidTimestamp)?;
    let epoch_ms = parsed.unix_timestamp_nanos() / 1_000_000;
    u64::try_from(epoch_ms).map_err(|_| ContractError::InvalidTimestamp)
}

fn validate_initial_device(
    handle: &str,
    request: &RegisterRequest,
    now_ms: u64,
) -> Result<(), ApiError> {
    let device_keys = request.initial_device.device_keys();
    let input = DeviceRegistrationInput {
        account_handle: handle,
        account_sign_pub: &request.ik_sign_pub,
        device_keys: &device_keys,
        certificate_chain: &request.initial_device.device_certificate_chain,
        now_ms,
    };
    validate_device_registration(&input)
        .map(|_| ())
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

fn iso_millis(unix_ms: u64) -> Result<String, ApiError> {
    let seconds_u64 = unix_ms / 1_000;
    let seconds = i64::try_from(seconds_u64).map_err(|_| ApiError::internal())?;
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

#[cfg(test)]
mod tests {
    use super::{
        AccountRecord, ApiError, ApiStatus, AuthChallengeRecord, AuthFinishRequest, AuthService,
        AuthStartContext, AuthStartRequest, AuthStore, CreateAuthChallenge, DeviceRecord,
        DeviceState, IdentityRecord, InitialDeviceRegistration, IssueTokenContext, LogoutRequest,
        PersistToken, RefreshRequest, RegisterContext, RegisterRequest, StoreError,
    };
    use crate::auth::{
        device_certificate_signing_payload, registration_proof_payload, CertificateIssuerKind,
        DeviceCertificate,
    };
    use crate::session::{
        sign_refresh_token, sign_session_token, token_hash, verify_session_token, TokenConfig,
        TokenSubject,
    };
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use ed25519_dalek::{Signer, SigningKey};
    use std::collections::BTreeSet;

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:example.com";
    const DEVICE_ID: &str = "ios-primary";
    const NONCE: &str = "challenge-nonce";
    const CHALLENGE_ID: &str = "challenge-1";
    const SESSION_ID: &str = "sess-1";
    const NOW_MS: u64 = 1_700_000_000_000;
    const NOW_SEC: u64 = 1_700_000_000;
    const NOW_ISO: &str = "2023-11-14T22:13:20.000Z";

    #[test]
    fn register_creates_new_account_with_valid_proofs() {
        let (account_key, account_pub) = signing_material(8);
        let (device_key, device_pub) = signing_material(9);
        let request = register_request(&account_key, &account_pub, &device_key, &device_pub);
        let mut store = FakeStore::default();
        let service = service();

        let response = service.register(&mut store, &request, &register_context());

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.status, ApiStatus::Created);
        assert_eq!(body.user_handle, HANDLE);
        assert_eq!(body.device_id, DEVICE_ID);
        assert_eq!(body.tokens.expires_in, 900);
        assert_eq!(
            store
                .created_accounts
                .first()
                .map(CreatedAccount::user_handle),
            Some(HANDLE)
        );
        assert_eq!(store.inserted_sessions.len(), 1);
        assert_eq!(store.inserted_refresh_sessions.len(), 1);
    }

    #[test]
    fn register_is_idempotent_for_same_existing_device_contract() {
        let (account_key, account_pub) = signing_material(8);
        let (device_key, device_pub) = signing_material(9);
        let request = register_request(&account_key, &account_pub, &device_key, &device_pub);
        let mut store = FakeStore::default();
        store.accounts.push(account());
        store.identities.push(StoredIdentity {
            account_id: ACCOUNT_ID.to_owned(),
            identity: IdentityRecord::new(account_pub, "ik-dh".to_owned()),
        });
        store.devices.push(DeviceRecord::new(
            ACCOUNT_ID.to_owned(),
            DEVICE_ID.to_owned(),
            device_pub,
            "dk-dh".to_owned(),
            DeviceState::Active,
            request.initial_device.device_certificate_chain.clone(),
        ));
        let service = service();

        let response = service.register(&mut store, &request, &register_context());

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.status, ApiStatus::Ok);
        assert!(store.created_accounts.is_empty());
        assert_eq!(store.inserted_sessions.len(), 1);
    }

    #[test]
    fn register_rejects_existing_account_with_changed_keys() {
        let (account_key, account_pub) = signing_material(8);
        let (device_key, device_pub) = signing_material(9);
        let request = register_request(&account_key, &account_pub, &device_key, &device_pub);
        let mut store = FakeStore::default();
        store.accounts.push(account());
        store.identities.push(StoredIdentity {
            account_id: ACCOUNT_ID.to_owned(),
            identity: IdentityRecord::new(account_pub, "different-dh".to_owned()),
        });
        let service = service();

        let response = service.register(&mut store, &request, &register_context());

        assert_eq!(
            response.err(),
            Some(ApiError::new(
                ApiStatus::Conflict,
                "Account already exists",
                None
            ))
        );
    }

    #[test]
    fn start_creates_challenge_without_account_probe() {
        let mut store = FakeStore::default();
        store.accounts.push(account());
        let service = service();
        let request = AuthStartRequest {
            user_handle: " @Alice:Example.COM ".to_owned(),
            device_id: Some(DEVICE_ID.to_owned()),
        };
        let context = AuthStartContext {
            nonce: NONCE.to_owned(),
            now_ms: NOW_MS,
        };

        let response = service.start(&mut store, &request, &context);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.challenge_id, CHALLENGE_ID);
        assert_eq!(body.nonce, NONCE);
        assert_eq!(body.expires_at, "2023-11-14T22:18:20.000Z");
        assert_eq!(
            store
                .created_challenges
                .first()
                .and_then(CreateAuthChallengeSnapshot::account_id),
            Some(ACCOUNT_ID)
        );
    }

    #[test]
    fn finish_issues_tokens_and_persists_hashes() {
        let (signing_key, public_key) = signing_material(7);
        let mut store = FakeStore::default();
        store.accounts.push(account());
        store.devices.push(DeviceRecord::new(
            ACCOUNT_ID.to_owned(),
            DEVICE_ID.to_owned(),
            public_key,
            "dk-dh".to_owned(),
            DeviceState::Active,
            vec![test_certificate()],
        ));
        store.challenges.push(challenge());
        let service = service();
        let request = AuthFinishRequest {
            user_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            challenge_id: CHALLENGE_ID.to_owned(),
            signature: sign(&signing_key, NONCE),
        };

        let response = service.finish(&mut store, &request, &issue_context());

        assert!(response.is_ok());
        let Ok(tokens) = response else {
            return;
        };
        assert_eq!(tokens.expires_in, 900);
        let claims = verify_session_token(&tokens.session_token, &token_config(), NOW_SEC + 1);
        assert!(claims.is_some());
        assert_eq!(
            store.used_challenges.first().map(String::as_str),
            Some(CHALLENGE_ID)
        );
        assert_eq!(store.inserted_sessions.len(), 1);
        assert_eq!(store.inserted_refresh_sessions.len(), 1);
        assert_eq!(
            store.inserted_sessions.first().map(StoredToken::token_hash),
            Some(token_hash(&tokens.session_token).as_str())
        );
    }

    #[test]
    fn finish_requires_linked_active_device_and_consumes_challenge() {
        let mut store = FakeStore::default();
        store.accounts.push(account());
        store.devices.push(DeviceRecord::new(
            ACCOUNT_ID.to_owned(),
            DEVICE_ID.to_owned(),
            "not-a-key".to_owned(),
            "dk-dh".to_owned(),
            DeviceState::Active,
            Vec::new(),
        ));
        store.challenges.push(challenge());
        let service = service();
        let request = AuthFinishRequest {
            user_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            challenge_id: CHALLENGE_ID.to_owned(),
            signature: "irrelevant".to_owned(),
        };

        let response = service.finish(&mut store, &request, &issue_context());

        assert_eq!(
            response.err(),
            Some(ApiError::new(
                ApiStatus::Conflict,
                "Device link required",
                Some("device_link_required")
            ))
        );
        assert_eq!(
            store.used_challenges.first().map(String::as_str),
            Some(CHALLENGE_ID)
        );
    }

    #[test]
    fn authenticates_only_active_session_tokens() {
        let mut store = FakeStore::default();
        let token = signed_session();
        store.active_sessions.insert(token_hash(&token));
        let service = service();

        let authenticated = service.authenticate_session(
            &mut store,
            Some(&format!("Bearer {token}")),
            NOW_SEC + 1,
            NOW_MS,
        );

        assert!(authenticated.is_ok());
        let Ok(session) = authenticated else {
            return;
        };
        assert_eq!(session.account_id, ACCOUNT_ID);
        assert_eq!(session.device_id, DEVICE_ID);

        let inactive = service.authenticate_session(
            &mut FakeStore::default(),
            Some(&format!("Bearer {token}")),
            NOW_SEC + 1,
            NOW_MS,
        );
        assert_eq!(
            inactive.err(),
            Some(ApiError::new(ApiStatus::Unauthorized, "Unauthorized", None))
        );
    }

    #[test]
    fn refresh_rotates_active_refresh_token() {
        let refresh_token = signed_refresh();
        let old_hash = token_hash(&refresh_token);
        let mut store = FakeStore::default();
        store.accounts.push(account());
        store.active_refresh_tokens.insert(old_hash.clone());
        let service = service();
        let request = RefreshRequest { refresh_token };

        let response = service.refresh(
            &mut store,
            &request,
            &IssueTokenContext {
                session_id: "sess-rotated".to_owned(),
                issued_at_sec: NOW_SEC + 60,
                now_ms: NOW_MS + 60_000,
            },
        );

        assert!(response.is_ok());
        let Ok(tokens) = response else {
            return;
        };
        assert_eq!(tokens.expires_in, 900);
        assert_eq!(
            store.rotated_refresh.first().map(RotatedRefresh::old_hash),
            Some(old_hash.as_str())
        );
        assert_eq!(store.inserted_sessions.len(), 1);
    }

    #[test]
    fn logout_revokes_authorization_and_body_tokens() {
        let session_token = signed_session();
        let refresh_token = signed_refresh();
        let mut store = FakeStore::default();
        let service = service();
        let request = LogoutRequest {
            session_token: Some("body-session".to_owned()),
            refresh_token: Some(refresh_token.clone()),
        };

        let response = service.logout(
            &mut store,
            Some(&format!("Bearer {session_token}")),
            &request,
            NOW_SEC + 1,
        );

        assert!(response.is_ok());
        assert!(store.revoked_sessions.contains(&token_hash(&session_token)));
        assert!(store.revoked_sessions.contains(&token_hash("body-session")));
        assert!(store
            .revoked_refresh_tokens
            .contains(&token_hash(&refresh_token)));
    }

    fn service() -> AuthService {
        AuthService::new(token_config())
    }

    fn token_config() -> TokenConfig {
        TokenConfig::new(
            "unit-test-session-secret".to_owned(),
            "unit-test-refresh-secret".to_owned(),
            900,
            86_400,
        )
    }

    fn issue_context() -> IssueTokenContext {
        IssueTokenContext {
            session_id: SESSION_ID.to_owned(),
            issued_at_sec: NOW_SEC,
            now_ms: NOW_MS,
        }
    }

    fn account() -> AccountRecord {
        AccountRecord::new(ACCOUNT_ID.to_owned(), HANDLE.to_owned())
    }

    fn challenge() -> AuthChallengeRecord {
        AuthChallengeRecord::new(
            CHALLENGE_ID.to_owned(),
            Some(ACCOUNT_ID.to_owned()),
            Some(DEVICE_ID.to_owned()),
            NONCE.to_owned(),
            NOW_MS + 300_000,
        )
    }

    fn signed_session() -> String {
        let token = sign_session_token(&subject(SESSION_ID), &token_config(), NOW_SEC);
        match token {
            Ok(value) => value,
            Err(error) => error.to_string(),
        }
    }

    fn signed_refresh() -> String {
        let token = sign_refresh_token(&subject(SESSION_ID), &token_config(), NOW_SEC);
        match token {
            Ok(value) => value,
            Err(error) => error.to_string(),
        }
    }

    fn subject(session_id: &str) -> TokenSubject {
        TokenSubject::new(
            ACCOUNT_ID.to_owned(),
            HANDLE.to_owned(),
            DEVICE_ID.to_owned(),
            session_id.to_owned(),
        )
    }

    fn register_context() -> RegisterContext {
        RegisterContext {
            server_domain: "example.com".to_owned(),
            token_context: issue_context(),
        }
    }

    fn register_request(
        account_key: &SigningKey,
        account_pub: &str,
        _device_key: &SigningKey,
        device_pub: &str,
    ) -> RegisterRequest {
        let mut certificate = DeviceCertificate {
            device_certificate_version: 2,
            account_handle: HANDLE.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            device_sign_pub: device_pub.to_owned(),
            device_dh_pub: "dk-dh".to_owned(),
            issuer_kind: CertificateIssuerKind::Account,
            issuer_device_id: None,
            parent_certificate_id: None,
            issued_at: NOW_ISO.to_owned(),
            expires_at: None,
            signature: String::new(),
        };
        certificate.signature = sign(
            account_key,
            &device_certificate_signing_payload(&certificate),
        );
        let proof = registration_proof_payload(HANDLE, account_pub, "ik-dh", NOW_ISO);

        RegisterRequest {
            user_handle: HANDLE.to_owned(),
            ik_sign_pub: account_pub.to_owned(),
            ik_dh_pub: "ik-dh".to_owned(),
            signature: sign(account_key, &proof),
            timestamp: NOW_ISO.to_owned(),
            initial_device: InitialDeviceRegistration {
                device_id: DEVICE_ID.to_owned(),
                dk_sign_pub: device_pub.to_owned(),
                dk_dh_pub: "dk-dh".to_owned(),
                device_certificate_chain: vec![certificate],
            },
        }
    }

    fn test_certificate() -> DeviceCertificate {
        let (account_key, account_pub) = signing_material(8);
        let (device_key, device_pub) = signing_material(7);
        let request = register_request(&account_key, &account_pub, &device_key, &device_pub);
        request
            .initial_device
            .device_certificate_chain
            .into_iter()
            .next()
            .unwrap_or_else(|| DeviceCertificate {
                device_certificate_version: 2,
                account_handle: HANDLE.to_owned(),
                device_id: DEVICE_ID.to_owned(),
                device_sign_pub: String::new(),
                device_dh_pub: String::new(),
                issuer_kind: CertificateIssuerKind::Account,
                issuer_device_id: None,
                parent_certificate_id: None,
                issued_at: NOW_ISO.to_owned(),
                expires_at: None,
                signature: String::new(),
            })
    }

    fn signing_material(seed: u8) -> (SigningKey, String) {
        let signing_key = SigningKey::from_bytes(&[seed; 32]);
        let public_key = STANDARD.encode(signing_key.verifying_key().to_bytes());
        (signing_key, public_key)
    }

    fn sign(signing_key: &SigningKey, message: &str) -> String {
        STANDARD.encode(signing_key.sign(message.as_bytes()).to_bytes())
    }

    #[derive(Debug, Clone, Default)]
    struct FakeStore {
        accounts: Vec<AccountRecord>,
        identities: Vec<StoredIdentity>,
        devices: Vec<DeviceRecord>,
        challenges: Vec<AuthChallengeRecord>,
        created_accounts: Vec<CreatedAccount>,
        created_challenges: Vec<CreateAuthChallengeSnapshot>,
        used_challenges: Vec<String>,
        inserted_sessions: Vec<StoredToken>,
        inserted_refresh_sessions: Vec<StoredToken>,
        active_sessions: BTreeSet<String>,
        active_refresh_tokens: BTreeSet<String>,
        revoked_sessions: BTreeSet<String>,
        revoked_refresh_tokens: BTreeSet<String>,
        rotated_refresh: Vec<RotatedRefresh>,
    }

    impl AuthStore for FakeStore {
        fn find_account_by_handle(
            &mut self,
            user_handle: &str,
        ) -> Result<Option<AccountRecord>, StoreError> {
            Ok(self
                .accounts
                .iter()
                .find(|account| account.user_handle() == user_handle)
                .cloned())
        }

        fn find_account_by_id(
            &mut self,
            account_id: &str,
        ) -> Result<Option<AccountRecord>, StoreError> {
            Ok(self
                .accounts
                .iter()
                .find(|account| account.id() == account_id)
                .cloned())
        }

        fn find_identity_keys(
            &mut self,
            account_id: &str,
        ) -> Result<Option<IdentityRecord>, StoreError> {
            Ok(self
                .identities
                .iter()
                .find(|stored| stored.account_id == account_id)
                .map(|stored| stored.identity.clone()))
        }

        fn create_account_with_identity_and_device(
            &mut self,
            input: super::CreateAccountWithDevice<'_>,
        ) -> Result<AccountRecord, StoreError> {
            self.created_accounts.push(CreatedAccount {
                user_handle: input.user_handle.to_owned(),
                home_server: input.home_server.to_owned(),
                ik_sign_pub: input.ik_sign_pub.to_owned(),
                ik_dh_pub: input.ik_dh_pub.to_owned(),
                proof_signature: input.proof_signature.to_owned(),
                proof_timestamp: input.proof_timestamp.to_owned(),
                device_id: input.initial_device.device_id.clone(),
            });
            let account = AccountRecord::new(ACCOUNT_ID.to_owned(), input.user_handle.to_owned());
            self.accounts.push(account.clone());
            self.identities.push(StoredIdentity {
                account_id: account.id().to_owned(),
                identity: IdentityRecord::new(
                    input.ik_sign_pub.to_owned(),
                    input.ik_dh_pub.to_owned(),
                ),
            });
            self.devices.push(DeviceRecord::new(
                account.id().to_owned(),
                input.initial_device.device_id.clone(),
                input.initial_device.dk_sign_pub.clone(),
                input.initial_device.dk_dh_pub.clone(),
                DeviceState::Active,
                input.initial_device.device_certificate_chain.clone(),
            ));
            Ok(account)
        }

        fn create_auth_challenge(
            &mut self,
            input: CreateAuthChallenge<'_>,
        ) -> Result<AuthChallengeRecord, StoreError> {
            self.created_challenges
                .push(CreateAuthChallengeSnapshot::from(input));
            let record = AuthChallengeRecord::new(
                CHALLENGE_ID.to_owned(),
                input.account_id.map(str::to_owned),
                input.device_id.map(str::to_owned),
                input.nonce.to_owned(),
                input.expires_at_ms,
            );
            self.challenges.push(record.clone());
            Ok(record)
        }

        fn find_active_challenge(
            &mut self,
            challenge_id: &str,
            account_id: &str,
            now_ms: u64,
        ) -> Result<Option<AuthChallengeRecord>, StoreError> {
            Ok(self
                .challenges
                .iter()
                .find(|challenge| {
                    challenge.challenge_id() == challenge_id
                        && challenge.account_id() == Some(account_id)
                        && challenge.expires_at_ms() > now_ms
                        && !self
                            .used_challenges
                            .iter()
                            .any(|used_id| used_id == challenge_id)
                })
                .cloned())
        }

        fn mark_challenge_used(&mut self, challenge_id: &str) -> Result<(), StoreError> {
            self.used_challenges.push(challenge_id.to_owned());
            Ok(())
        }

        fn find_device(
            &mut self,
            account_id: &str,
            device_id: &str,
        ) -> Result<Option<DeviceRecord>, StoreError> {
            Ok(self
                .devices
                .iter()
                .find(|device| device.account_id() == account_id && device.device_id() == device_id)
                .cloned())
        }

        fn insert_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError> {
            self.inserted_sessions.push(StoredToken::from(input));
            Ok(())
        }

        fn insert_refresh_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError> {
            self.inserted_refresh_sessions
                .push(StoredToken::from(input));
            Ok(())
        }

        fn session_token_active(
            &mut self,
            token_hash: &str,
            _now_ms: u64,
        ) -> Result<bool, StoreError> {
            Ok(self.active_sessions.contains(token_hash))
        }

        fn refresh_token_active(
            &mut self,
            token_hash: &str,
            _now_ms: u64,
        ) -> Result<bool, StoreError> {
            Ok(self.active_refresh_tokens.contains(token_hash))
        }

        fn rotate_refresh_token(
            &mut self,
            old_hash: &str,
            new_hash: &str,
            new_expires_at_ms: u64,
        ) -> Result<(), StoreError> {
            if !self.active_refresh_tokens.remove(old_hash) {
                return Err(StoreError);
            }
            self.active_refresh_tokens.insert(new_hash.to_owned());
            self.rotated_refresh.push(RotatedRefresh {
                old_hash: old_hash.to_owned(),
                new_hash: new_hash.to_owned(),
                new_expires_at_ms,
            });
            Ok(())
        }

        fn revoke_session_token(&mut self, token_hash: &str) -> Result<(), StoreError> {
            self.revoked_sessions.insert(token_hash.to_owned());
            Ok(())
        }

        fn revoke_refresh_token(&mut self, token_hash: &str) -> Result<(), StoreError> {
            self.revoked_refresh_tokens.insert(token_hash.to_owned());
            Ok(())
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct CreateAuthChallengeSnapshot {
        account_id: Option<String>,
        device_id: Option<String>,
        nonce: String,
        expires_at_ms: u64,
    }

    impl CreateAuthChallengeSnapshot {
        fn account_id(&self) -> Option<&str> {
            self.account_id.as_deref()
        }
    }

    impl From<CreateAuthChallenge<'_>> for CreateAuthChallengeSnapshot {
        fn from(value: CreateAuthChallenge<'_>) -> Self {
            Self {
                account_id: value.account_id.map(str::to_owned),
                device_id: value.device_id.map(str::to_owned),
                nonce: value.nonce.to_owned(),
                expires_at_ms: value.expires_at_ms,
            }
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredIdentity {
        account_id: String,
        identity: IdentityRecord,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct CreatedAccount {
        user_handle: String,
        home_server: String,
        ik_sign_pub: String,
        ik_dh_pub: String,
        proof_signature: String,
        proof_timestamp: String,
        device_id: String,
    }

    impl CreatedAccount {
        fn user_handle(&self) -> &str {
            &self.user_handle
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredToken {
        account_id: String,
        device_id: String,
        token_hash: String,
        expires_at_ms: u64,
    }

    impl StoredToken {
        fn token_hash(&self) -> &str {
            &self.token_hash
        }
    }

    impl From<PersistToken<'_>> for StoredToken {
        fn from(value: PersistToken<'_>) -> Self {
            Self {
                account_id: value.account_id.to_owned(),
                device_id: value.device_id.to_owned(),
                token_hash: value.token_hash.to_owned(),
                expires_at_ms: value.expires_at_ms,
            }
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct RotatedRefresh {
        old_hash: String,
        new_hash: String,
        new_expires_at_ms: u64,
    }

    impl RotatedRefresh {
        fn old_hash(&self) -> &str {
            &self.old_hash
        }
    }
}
