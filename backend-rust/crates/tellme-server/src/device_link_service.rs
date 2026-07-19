//! Service-level device-linking contract through host approval.

use crate::auth::{normalize_handle, parse_handle, DeviceCertificate};
use crate::auth_service::{ApiError, AuthenticatedSession, IssuedTokens, PersistToken, StoreError};
use crate::devices::{
    effective_link_expires_sec, link_secret_hash, validate_device_link_approval, DeviceError,
    DevicePublicKeys,
};
use crate::prekeys::{validate_publish_request, OneTimePrekey, PrekeyPublishRequest, SignedPrekey};
use crate::session::{
    sign_refresh_token, sign_session_token, token_hash, TokenConfig, TokenSubject,
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

/// Device-link request state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkRequestStatus {
    Pending,
    Approved,
}

impl LinkRequestStatus {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
        }
    }
}

/// Active link session joined with the account handle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkSessionRecord {
    pub id: String,
    pub account_id: String,
    pub user_handle: String,
    pub old_device_id: String,
    pub l_dh_pub: String,
    pub expires_at_ms: u64,
}

/// Link request joined with link session fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkRequestRecord {
    pub id: String,
    pub session_id: String,
    pub account_id: String,
    pub old_device_id: String,
    pub user_handle: String,
    pub new_device_id: String,
    pub n_dh_pub: String,
    pub dk_sign_pub: String,
    pub dk_dh_pub: String,
    pub status: LinkRequestStatus,
    pub approved_device_certificate: Option<DeviceCertificate>,
    pub encrypted_provisioning_blob: Option<String>,
    pub expires_at_ms: u64,
    pub completed_at_ms: Option<u64>,
    pub created_at: String,
}

/// Account identity needed for approval validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkAccountIdentity {
    pub user_handle: String,
    pub account_sign_pub: String,
}

/// Host device certificate chain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostDeviceRecord {
    pub device_id: String,
    pub certificate_chain: Vec<DeviceCertificate>,
}

/// Store input for starting a link session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateLinkSession {
    pub account_id: String,
    pub old_device_id: String,
    pub link_code_hash: String,
    pub l_dh_pub: String,
    pub expires_at: String,
    pub expires_at_ms: u64,
}

/// Store input for creating a new-device link request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateLinkRequest {
    pub session_id: String,
    pub user_handle: String,
    pub new_device_id: String,
    pub n_dh_pub: String,
    pub dk_sign_pub: String,
    pub dk_dh_pub: String,
    pub poll_token_hash: String,
}

/// Store input for approving a link request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApproveLinkRequest {
    pub session_id: String,
    pub request_id: String,
    pub approved_device_certificate: DeviceCertificate,
    pub encrypted_provisioning_blob: String,
}

/// Storage and realtime side-effect boundary for device-linking.
// Device-link state is transient trust scaffolding and must not become long-lived identity storage.
pub trait DeviceLinkStore {
    /// Starts a link session.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the session.
    fn start_session(&mut self, input: CreateLinkSession) -> Result<LinkSessionRecord, StoreError>;

    /// Finds an active link session by link-code hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_active_session_by_code_hash(
        &mut self,
        link_code_hash: &str,
        now_ms: u64,
    ) -> Result<Option<LinkSessionRecord>, StoreError>;

    /// Creates a link request.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the request.
    fn create_request(&mut self, input: CreateLinkRequest)
        -> Result<LinkRequestRecord, StoreError>;

    /// Emits a device-link request notification to the account room.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when the side effect fails.
    fn notify_link_request(
        &mut self,
        account_id: &str,
        request_id: &str,
        new_device_id: &str,
    ) -> Result<(), StoreError>;

    /// Lists requests for a session owned by the account.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_requests_by_session(
        &mut self,
        account_id: &str,
        session_id: &str,
    ) -> Result<Vec<LinkRequestRecord>, StoreError>;

    /// Finds one request by request id and poll-token hash.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_request_by_poll_token(
        &mut self,
        request_id: &str,
        poll_token_hash: &str,
    ) -> Result<Option<LinkRequestRecord>, StoreError>;

    /// Finds one request by id.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn get_request_by_id(
        &mut self,
        request_id: &str,
    ) -> Result<Option<LinkRequestRecord>, StoreError>;

    /// Finds account identity for approval validation.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_identity(
        &mut self,
        account_id: &str,
    ) -> Result<Option<LinkAccountIdentity>, StoreError>;

    /// Finds the host device certificate chain.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_host_device(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Option<HostDeviceRecord>, StoreError>;

    /// Approves one link request.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the request.
    fn approve_request(
        &mut self,
        input: ApproveLinkRequest,
    ) -> Result<Option<LinkRequestRecord>, StoreError>;

    /// Emits a device-link-approved notification to the request room.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when the side effect fails.
    fn notify_link_approved(&mut self, request_id: &str) -> Result<(), StoreError>;

    /// Registers the approved linked device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot upsert the device.
    fn register_linked_device(
        &mut self,
        account_id: &str,
        device_keys: &DevicePublicKeys,
        certificate_chain: &[DeviceCertificate],
    ) -> Result<(), StoreError>;

    /// Publishes prekeys for the linked device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot publish prekeys.
    fn publish_link_prekeys(
        &mut self,
        account_id: &str,
        device_id: &str,
        signed_prekey: &SignedPrekey,
        one_time_prekeys: &[OneTimePrekey],
    ) -> Result<(), StoreError>;

    /// Persists a session token hash for the linked device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the session.
    fn insert_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError>;

    /// Persists a refresh token hash for the linked device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the refresh session.
    fn insert_refresh_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError>;

    /// Marks a link request completed.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update the request.
    fn mark_completed(&mut self, request_id: &str) -> Result<(), StoreError>;
}

/// Request body for `/api/devices/link/start`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LinkStartRequest {
    pub link_code: String,
    pub l_dh_pub: String,
    pub expires_in_sec: Option<u64>,
}

/// Deterministic runtime context for link start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkStartContext {
    pub now_ms: u64,
}

/// Response body for `/api/devices/link/start`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkStartResponse {
    pub link_session_id: String,
    pub expires_at: String,
}

/// Request body for `/api/devices/link/request`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LinkRequestCreateRequest {
    pub user_handle: String,
    pub link_code: String,
    pub n_dh_pub: String,
    pub device_pub_keys: DevicePublicKeys,
}

/// Deterministic runtime values for link request creation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkRequestCreateContext {
    pub poll_token: String,
    pub now_ms: u64,
}

/// Response body for `/api/devices/link/request`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkRequestCreateResponse {
    pub request_id: String,
    pub status: LinkRequestStatus,
    pub poll_token: String,
}

/// Public poll response for `/api/devices/link/request/:requestId`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkRequestPollResponse {
    pub request_id: String,
    pub status: LinkRequestStatus,
    pub approved_device_certificate: Option<DeviceCertificate>,
    pub encrypted_provisioning_blob: Option<String>,
}

/// Host-device request list response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkRequestListResponse {
    pub requests: Vec<LinkRequestView>,
}

/// Host-device request view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkRequestView {
    pub request_id: String,
    pub status: LinkRequestStatus,
    pub new_device_id: String,
    pub n_dh_pub: String,
    pub dk_sign_pub: String,
    pub dk_dh_pub: String,
    pub approved_device_certificate: Option<DeviceCertificate>,
    pub encrypted_provisioning_blob: Option<String>,
    pub created_at: String,
}

/// Request body for `/api/devices/link/approve`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LinkApproveRequest {
    pub link_code: String,
    pub request_id: String,
    pub approved_device_certificate: DeviceCertificate,
    pub encrypted_provisioning_blob: String,
}

/// Response body for `/api/devices/link/approve`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkApproveResponse {
    pub request_id: String,
    pub status: LinkRequestStatus,
}

/// Request body for `/api/devices/link/complete`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LinkCompleteRequest {
    pub request_id: String,
    pub poll_token: String,
    pub device_pub_keys: DevicePublicKeys,
    pub signed_prekey: SignedPrekey,
    pub one_time_prekeys: Vec<OneTimePrekey>,
}

/// Deterministic runtime context for link completion token issuance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkCompleteContext {
    pub now_ms: u64,
    pub issued_at_sec: u64,
    pub session_id: String,
}

/// Response body for `/api/devices/link/complete`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LinkCompleteResponse {
    pub user_handle: String,
    pub device_id: String,
    #[serde(flatten)]
    pub tokens: IssuedTokens,
}

/// Service implementation for device-linking routes through approval.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceLinkService {
    token_config: TokenConfig,
}

impl DeviceLinkService {
    #[must_use]
    pub const fn new(token_config: TokenConfig) -> Self {
        Self { token_config }
    }

    /// Starts a device-link session.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when expiry bounds are invalid or storage fails.
    pub fn start<S: DeviceLinkStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &LinkStartRequest,
        context: &LinkStartContext,
    ) -> Result<LinkStartResponse, ApiError> {
        let expires_in = effective_link_expires_sec(request.expires_in_sec)
            .map_err(|_| ApiError::bad_request("Invalid link session payload"))?;
        let expires_at_ms = context
            .now_ms
            .saturating_add(expires_in.saturating_mul(1_000));
        let expires_at = iso_millis(expires_at_ms)?;
        let session = store
            .start_session(CreateLinkSession {
                account_id: auth.account_id.clone(),
                old_device_id: auth.device_id.clone(),
                link_code_hash: link_secret_hash(&request.link_code),
                l_dh_pub: request.l_dh_pub.clone(),
                expires_at: expires_at.clone(),
                expires_at_ms,
            })
            .map_err(|_| ApiError::internal())?;

        Ok(LinkStartResponse {
            link_session_id: session.id,
            expires_at,
        })
    }

    /// Creates a new-device link request.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the handle is invalid, session is unavailable, or storage fails.
    pub fn request<S: DeviceLinkStore>(
        store: &mut S,
        request: &LinkRequestCreateRequest,
        context: &LinkRequestCreateContext,
    ) -> Result<LinkRequestCreateResponse, ApiError> {
        let handle = normalize_handle(&request.user_handle);
        parse_handle(&handle).map_err(|_| ApiError::bad_request("Invalid user_handle"))?;
        let session = store
            .find_active_session_by_code_hash(&link_secret_hash(&request.link_code), context.now_ms)
            .map_err(|_| ApiError::internal())?;
        let Some(session) = session.filter(|session| session.user_handle == handle) else {
            return Err(ApiError::not_found("Link session not found"));
        };
        let created = store
            .create_request(CreateLinkRequest {
                session_id: session.id.clone(),
                user_handle: handle,
                new_device_id: request.device_pub_keys.device_id().to_owned(),
                n_dh_pub: request.n_dh_pub.clone(),
                dk_sign_pub: request.device_pub_keys.dk_sign_pub().to_owned(),
                dk_dh_pub: request.device_pub_keys.dk_dh_pub().to_owned(),
                poll_token_hash: link_secret_hash(&context.poll_token),
            })
            .map_err(|_| ApiError::internal())?;
        store
            .notify_link_request(&session.account_id, &created.id, &created.new_device_id)
            .map_err(|_| ApiError::internal())?;

        Ok(LinkRequestCreateResponse {
            request_id: created.id,
            status: created.status,
            poll_token: context.poll_token.clone(),
        })
    }

    /// Lists pending and approved requests for a host link session.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when storage lookup fails.
    pub fn list_requests<S: DeviceLinkStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        session_id: &str,
    ) -> Result<LinkRequestListResponse, ApiError> {
        let requests = store
            .list_requests_by_session(&auth.account_id, session_id)
            .map_err(|_| ApiError::internal())?
            .into_iter()
            .map(request_view)
            .collect();
        Ok(LinkRequestListResponse { requests })
    }

    /// Polls one link request using a poll token.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the poll token is missing, invalid, or storage lookup fails.
    pub fn poll<S: DeviceLinkStore>(
        store: &mut S,
        request_id: &str,
        poll_token: &str,
    ) -> Result<LinkRequestPollResponse, ApiError> {
        if poll_token.trim().is_empty() {
            return Err(ApiError::bad_request("poll_token is required"));
        }
        let request = store
            .find_request_by_poll_token(request_id, &link_secret_hash(poll_token.trim()))
            .map_err(|_| ApiError::internal())?;
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

    /// Approves a link request and validates the approved certificate extends the host chain.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when session/request lookup, certificate validation, or storage update fails.
    pub fn approve<S: DeviceLinkStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &LinkApproveRequest,
        now_ms: u64,
    ) -> Result<LinkApproveResponse, ApiError> {
        let session = store
            .find_active_session_by_code_hash(&link_secret_hash(&request.link_code), now_ms)
            .map_err(|_| ApiError::internal())?;
        let Some(session) = session.filter(|session| session.account_id == auth.account_id) else {
            return Err(ApiError::not_found("Link session not found"));
        };
        let link_request = store
            .get_request_by_id(&request.request_id)
            .map_err(|_| ApiError::internal())?;
        let identity = store
            .find_account_identity(&session.account_id)
            .map_err(|_| ApiError::internal())?;
        let host_device = store
            .find_host_device(&session.account_id, &session.old_device_id)
            .map_err(|_| ApiError::internal())?;
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
            link_request.dk_dh_pub,
        );
        validate_device_link_approval(&crate::devices::DeviceLinkApprovalInput {
            account_handle: &identity.user_handle,
            account_sign_pub: &identity.account_sign_pub,
            host_device_id: &host_device.device_id,
            host_certificate_chain: &host_device.certificate_chain,
            approved_certificate: &request.approved_device_certificate,
            new_device_keys: &new_device_keys,
            now_ms,
        })
        .map_err(|error| approval_error(&error))?;

        let approved = store
            .approve_request(ApproveLinkRequest {
                session_id: session.id,
                request_id: request.request_id.clone(),
                approved_device_certificate: request.approved_device_certificate.clone(),
                encrypted_provisioning_blob: request.encrypted_provisioning_blob.clone(),
            })
            .map_err(|_| ApiError::internal())?;
        let Some(approved) = approved else {
            return Err(ApiError::not_found("Link request not found"));
        };
        store
            .notify_link_approved(&approved.id)
            .map_err(|_| ApiError::internal())?;

        Ok(LinkApproveResponse {
            request_id: approved.id,
            status: approved.status,
        })
    }

    /// Completes a link request, registers the device, publishes prekeys, issues tokens, and marks completion.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when the request is missing, not approved, expired, mismatched, invalid, or storage fails.
    pub fn complete<S: DeviceLinkStore>(
        &self,
        store: &mut S,
        request: &LinkCompleteRequest,
        context: &LinkCompleteContext,
    ) -> Result<LinkCompleteResponse, ApiError> {
        if request.poll_token.trim().is_empty() {
            return Err(ApiError::bad_request("poll_token is required"));
        }
        let link_request = store
            .find_request_by_poll_token(
                &request.request_id,
                &link_secret_hash(request.poll_token.trim()),
            )
            .map_err(|_| ApiError::internal())?;
        let Some(link_request) = link_request else {
            return Err(ApiError::not_found("Link request not found"));
        };
        validate_complete_request(&link_request, request, context.now_ms)?;
        let identity = store
            .find_account_identity(&link_request.account_id)
            .map_err(|_| ApiError::internal())?;
        let Some(identity) = identity else {
            return Err(ApiError::not_found("Account not found"));
        };
        let host_device = store
            .find_host_device(&link_request.account_id, &link_request.old_device_id)
            .map_err(|_| ApiError::internal())?;
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
        let full_chain = validate_device_link_approval(&crate::devices::DeviceLinkApprovalInput {
            account_handle: &identity.user_handle,
            account_sign_pub: &identity.account_sign_pub,
            host_device_id: &host_device.device_id,
            host_certificate_chain: &host_device.certificate_chain,
            approved_certificate,
            new_device_keys: &request.device_pub_keys,
            now_ms: context.now_ms,
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

        store
            .register_linked_device(
                &link_request.account_id,
                &request.device_pub_keys,
                &full_chain,
            )
            .map_err(|_| ApiError::internal())?;
        store
            .publish_link_prekeys(
                &link_request.account_id,
                request.device_pub_keys.device_id(),
                &request.signed_prekey,
                &request.one_time_prekeys,
            )
            .map_err(|_| ApiError::internal())?;
        let tokens = self.issue_tokens(
            store,
            &link_request.account_id,
            &identity.user_handle,
            request.device_pub_keys.device_id(),
            context,
        )?;
        store
            .mark_completed(&link_request.id)
            .map_err(|_| ApiError::internal())?;

        Ok(LinkCompleteResponse {
            user_handle: identity.user_handle,
            device_id: request.device_pub_keys.device_id().to_owned(),
            tokens,
        })
    }

    fn issue_tokens<S: DeviceLinkStore>(
        &self,
        store: &mut S,
        account_id: &str,
        user_handle: &str,
        device_id: &str,
        context: &LinkCompleteContext,
    ) -> Result<IssuedTokens, ApiError> {
        let subject = TokenSubject::new(
            account_id.to_owned(),
            user_handle.to_owned(),
            device_id.to_owned(),
            context.session_id.clone(),
        );
        let session_token = sign_session_token(&subject, &self.token_config, context.issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let refresh_token = sign_refresh_token(&subject, &self.token_config, context.issued_at_sec)
            .map_err(|_| ApiError::internal())?;
        let session_hash = token_hash(&session_token);
        let refresh_hash = token_hash(&refresh_token);
        store
            .insert_session(PersistToken {
                account_id,
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
                account_id,
                device_id,
                token_hash: &refresh_hash,
                expires_at_ms: token_expires_at_ms(
                    context.issued_at_sec,
                    self.token_config.refresh_ttl_sec(),
                ),
            })
            .map_err(|_| ApiError::internal())?;

        Ok(IssuedTokens {
            session_token,
            refresh_token,
            expires_in: self.token_config.session_ttl_sec(),
        })
    }
}

pub(crate) fn validate_complete_request(
    link_request: &LinkRequestRecord,
    request: &LinkCompleteRequest,
    now_ms: u64,
) -> Result<(), ApiError> {
    if link_request.status != LinkRequestStatus::Approved
        || link_request.encrypted_provisioning_blob.is_none()
    {
        return Err(ApiError::conflict("Link request is not approved yet", None));
    }
    if link_request.completed_at_ms.is_some() {
        return Err(ApiError::conflict("Link request already completed", None));
    }
    if link_request.expires_at_ms <= now_ms {
        return Err(ApiError::gone("Link session expired"));
    }
    if request.device_pub_keys.device_id() != link_request.new_device_id {
        return Err(ApiError::conflict("Linked device_id mismatch", None));
    }
    if request.device_pub_keys.dk_sign_pub() != link_request.dk_sign_pub
        || request.device_pub_keys.dk_dh_pub() != link_request.dk_dh_pub
    {
        return Err(ApiError::conflict("Linked device keys mismatch", None));
    }

    Ok(())
}

pub(crate) const fn token_expires_at_ms(issued_at_sec: u64, ttl_sec: u64) -> u64 {
    issued_at_sec.saturating_add(ttl_sec).saturating_mul(1_000)
}

pub(crate) fn request_view(request: LinkRequestRecord) -> LinkRequestView {
    LinkRequestView {
        request_id: request.id,
        status: request.status,
        new_device_id: request.new_device_id,
        n_dh_pub: request.n_dh_pub,
        dk_sign_pub: request.dk_sign_pub,
        dk_dh_pub: request.dk_dh_pub,
        approved_device_certificate: request.approved_device_certificate,
        encrypted_provisioning_blob: request.encrypted_provisioning_blob,
        created_at: request.created_at,
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

#[cfg(test)]
mod tests {
    use super::{
        ApproveLinkRequest, CreateLinkRequest, CreateLinkSession, DeviceLinkService,
        DeviceLinkStore, HostDeviceRecord, LinkAccountIdentity, LinkApproveRequest,
        LinkCompleteContext, LinkCompleteRequest, LinkCompleteResponse, LinkRequestCreateContext,
        LinkRequestCreateRequest, LinkRequestRecord, LinkRequestStatus, LinkSessionRecord,
        LinkStartContext, LinkStartRequest,
    };
    use crate::auth::{
        device_certificate_id, device_certificate_signing_payload, CertificateIssuerKind,
        DeviceCertificate,
    };
    use crate::auth_service::{
        ApiError, ApiStatus, AuthenticatedSession, IssuedTokens, PersistToken, StoreError,
    };
    use crate::devices::DevicePublicKeys;
    use crate::prekeys::{OneTimePrekey, SignedPrekey};
    use crate::session::{verify_refresh_token, verify_session_token, TokenConfig, TokenKind};
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use ed25519_dalek::{Signer, SigningKey};
    use std::collections::BTreeMap;

    const ACCOUNT_ID: &str = "acc-1";
    const HANDLE: &str = "@alice:example.com";
    const HOST_DEVICE_ID: &str = "ios-primary";
    const NEW_DEVICE_ID: &str = "ios-linked";
    const SESSION_ID: &str = "link-session-1";
    const REQUEST_ID: &str = "request-1";
    const LINK_CODE: &str = "123456";
    const POLL_TOKEN: &str = "poll-token-123456";
    const NOW_MS: u64 = 1_772_106_000_000;
    const ISSUED_AT_SEC: u64 = 1_772_106_000;
    const NOW_ISO: &str = "2026-02-26T12:00:00.000Z";

    #[test]
    fn starts_link_session_with_hashed_code_and_expiry() {
        let mut store = FakeLinkStore::default();
        let request = LinkStartRequest {
            link_code: LINK_CODE.to_owned(),
            l_dh_pub: "host-link-dh".to_owned(),
            expires_in_sec: Some(60),
        };

        let response = DeviceLinkService::start(
            &mut store,
            &auth(),
            &request,
            &LinkStartContext { now_ms: NOW_MS },
        );

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.link_session_id, SESSION_ID);
        assert_eq!(
            store
                .started
                .first()
                .map(|started| started.link_code_hash.as_str()),
            Some(crate::devices::link_secret_hash(LINK_CODE).as_str())
        );
    }

    #[test]
    fn creates_request_and_notifies_host_account() {
        let mut store = FakeLinkStore::with_session();
        let request = create_request();

        let response = DeviceLinkService::request(
            &mut store,
            &request,
            &LinkRequestCreateContext {
                poll_token: POLL_TOKEN.to_owned(),
                now_ms: NOW_MS,
            },
        );

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.request_id, REQUEST_ID);
        assert_eq!(body.status, LinkRequestStatus::Pending);
        assert_eq!(body.poll_token, POLL_TOKEN);
        assert_eq!(
            store
                .created_requests
                .first()
                .map(|created| created.poll_token_hash.as_str()),
            Some(crate::devices::link_secret_hash(POLL_TOKEN).as_str())
        );
        assert_eq!(store.request_notifications.len(), 1);
    }

    #[test]
    fn poll_requires_token_and_returns_approved_payload() {
        let mut store = FakeLinkStore::with_approved_request();

        let missing = DeviceLinkService::poll(&mut store, REQUEST_ID, "");
        assert_eq!(
            missing.err(),
            Some(ApiError::new(
                ApiStatus::BadRequest,
                "poll_token is required",
                None
            ))
        );

        let response = DeviceLinkService::poll(&mut store, REQUEST_ID, POLL_TOKEN);
        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.status, LinkRequestStatus::Approved);
        assert!(body.approved_device_certificate.is_some());
        assert_eq!(
            body.encrypted_provisioning_blob.as_deref(),
            Some("encrypted-provisioning")
        );
    }

    #[test]
    fn lists_requests_for_host_session() {
        let mut store = FakeLinkStore::with_approved_request();

        let response = DeviceLinkService::list_requests(&mut store, &auth(), SESSION_ID);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.requests.len(), 1);
        assert_eq!(
            body.requests
                .first()
                .map(|request| request.request_id.as_str()),
            Some(REQUEST_ID)
        );
    }

    #[test]
    fn approves_request_after_certificate_validation() {
        let mut store = FakeLinkStore::with_pending_request();
        let approved_certificate = approved_certificate();
        let request = LinkApproveRequest {
            link_code: LINK_CODE.to_owned(),
            request_id: REQUEST_ID.to_owned(),
            approved_device_certificate: approved_certificate,
            encrypted_provisioning_blob: "encrypted-provisioning".to_owned(),
        };

        let response = DeviceLinkService::approve(&mut store, &auth(), &request, NOW_MS);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.request_id, REQUEST_ID);
        assert_eq!(body.status, LinkRequestStatus::Approved);
        assert_eq!(store.approvals.len(), 1);
        assert_eq!(
            store.approved_notifications.first().map(String::as_str),
            Some(REQUEST_ID)
        );
    }

    #[test]
    fn rejects_approval_with_invalid_certificate_parent() {
        let mut store = FakeLinkStore::with_pending_request();
        let mut certificate = approved_certificate();
        certificate.parent_certificate_id = Some("wrong-parent".to_owned());
        let request = LinkApproveRequest {
            link_code: LINK_CODE.to_owned(),
            request_id: REQUEST_ID.to_owned(),
            approved_device_certificate: certificate,
            encrypted_provisioning_blob: "encrypted-provisioning".to_owned(),
        };

        assert_eq!(
            DeviceLinkService::approve(&mut store, &auth(), &request, NOW_MS).err(),
            Some(ApiError::new(
                ApiStatus::Unauthorized,
                "Invalid approved device certificate",
                None
            ))
        );
    }

    #[test]
    fn completes_approved_request_with_prekeys_tokens_and_completion_marker() {
        let mut store = FakeLinkStore::with_approved_request();
        let service = DeviceLinkService::new(token_config());
        let request = complete_request();

        let response = service.complete(
            &mut store,
            &request,
            &LinkCompleteContext {
                now_ms: NOW_MS,
                issued_at_sec: ISSUED_AT_SEC,
                session_id: "sess-linked".to_owned(),
            },
        );

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.user_handle, HANDLE);
        assert_eq!(body.device_id, NEW_DEVICE_ID);
        assert_eq!(body.tokens.expires_in, 900);
        assert_eq!(
            store.registered_devices.first().map(String::as_str),
            Some(NEW_DEVICE_ID)
        );
        assert_eq!(
            store.published_prekeys.first().map(String::as_str),
            Some("ios-linked:signed-1:1")
        );
        assert_eq!(
            store.completed_requests.first().map(String::as_str),
            Some(REQUEST_ID)
        );
        assert_eq!(store.session_tokens.len(), 1);
        assert_eq!(store.refresh_tokens.len(), 1);
        assert_eq!(
            verify_session_token(&body.tokens.session_token, &token_config(), ISSUED_AT_SEC)
                .map(|claims| claims.token_type()),
            Some(TokenKind::Session)
        );
        assert_eq!(
            verify_refresh_token(&body.tokens.refresh_token, &token_config(), ISSUED_AT_SEC)
                .map(|claims| claims.token_type()),
            Some(TokenKind::Refresh)
        );
    }

    #[test]
    fn complete_response_serializes_tokens_flat_like_current_route() {
        let response = LinkCompleteResponse {
            user_handle: HANDLE.to_owned(),
            device_id: NEW_DEVICE_ID.to_owned(),
            tokens: IssuedTokens {
                session_token: "session-token".to_owned(),
                refresh_token: "refresh-token".to_owned(),
                expires_in: 900,
            },
        };

        let serialized = serde_json::to_string(&response);

        assert!(serialized.is_ok());
        let Ok(serialized) = serialized else {
            return;
        };
        assert!(serialized.contains(r#""session_token":"session-token""#));
        assert!(serialized.contains(r#""refresh_token":"refresh-token""#));
        assert!(!serialized.contains(r#""tokens""#));
    }

    fn auth() -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            device_id: HOST_DEVICE_ID.to_owned(),
            session_id: "sess-1".to_owned(),
        }
    }

    fn complete_request() -> LinkCompleteRequest {
        let (_device_key, device_pub) = signing_material(10);
        LinkCompleteRequest {
            request_id: REQUEST_ID.to_owned(),
            poll_token: POLL_TOKEN.to_owned(),
            device_pub_keys: DevicePublicKeys::new(
                NEW_DEVICE_ID.to_owned(),
                device_pub,
                "new-dh".to_owned(),
            ),
            signed_prekey: SignedPrekey {
                prekey_id: "signed-1".to_owned(),
                signed_prekey_pub: "signed-pub".to_owned(),
                signature: "signed-sig".to_owned(),
                expires_at: None,
            },
            one_time_prekeys: vec![OneTimePrekey {
                prekey_id: "otp-1".to_owned(),
                prekey_pub: "otp-pub".to_owned(),
            }],
        }
    }

    fn token_config() -> TokenConfig {
        TokenConfig::new(
            "unit-test-session-secret".to_owned(),
            "unit-test-refresh-secret".to_owned(),
            900,
            86_400,
        )
    }

    fn create_request() -> LinkRequestCreateRequest {
        let (_device_key, device_pub) = signing_material(10);
        LinkRequestCreateRequest {
            user_handle: HANDLE.to_owned(),
            link_code: LINK_CODE.to_owned(),
            n_dh_pub: "new-link-dh".to_owned(),
            device_pub_keys: DevicePublicKeys::new(
                NEW_DEVICE_ID.to_owned(),
                device_pub,
                "new-dh".to_owned(),
            ),
        }
    }

    fn root_certificate() -> DeviceCertificate {
        let (account_key, _account_pub) = signing_material(8);
        let (_host_key, host_pub) = signing_material(9);
        let mut certificate = DeviceCertificate {
            device_certificate_version: 2,
            account_handle: HANDLE.to_owned(),
            device_id: HOST_DEVICE_ID.to_owned(),
            device_sign_pub: host_pub,
            device_dh_pub: "host-dh".to_owned(),
            issuer_kind: CertificateIssuerKind::Account,
            issuer_device_id: None,
            parent_certificate_id: None,
            issued_at: NOW_ISO.to_owned(),
            expires_at: None,
            signature: String::new(),
        };
        certificate.signature = sign(
            &account_key,
            &device_certificate_signing_payload(&certificate),
        );
        certificate
    }

    fn approved_certificate() -> DeviceCertificate {
        let (host_key, _host_pub) = signing_material(9);
        let (_device_key, device_pub) = signing_material(10);
        let root = root_certificate();
        let mut certificate = DeviceCertificate {
            device_certificate_version: 2,
            account_handle: HANDLE.to_owned(),
            device_id: NEW_DEVICE_ID.to_owned(),
            device_sign_pub: device_pub,
            device_dh_pub: "new-dh".to_owned(),
            issuer_kind: CertificateIssuerKind::Device,
            issuer_device_id: Some(HOST_DEVICE_ID.to_owned()),
            parent_certificate_id: Some(device_certificate_id(&root)),
            issued_at: NOW_ISO.to_owned(),
            expires_at: None,
            signature: String::new(),
        };
        certificate.signature = sign(&host_key, &device_certificate_signing_payload(&certificate));
        certificate
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
    struct FakeLinkStore {
        sessions: BTreeMap<String, LinkSessionRecord>,
        requests: BTreeMap<String, LinkRequestRecord>,
        started: Vec<CreateLinkSession>,
        created_requests: Vec<CreateLinkRequest>,
        request_notifications: Vec<String>,
        approvals: Vec<ApproveLinkRequest>,
        approved_notifications: Vec<String>,
        registered_devices: Vec<String>,
        published_prekeys: Vec<String>,
        session_tokens: Vec<String>,
        refresh_tokens: Vec<String>,
        completed_requests: Vec<String>,
    }

    impl FakeLinkStore {
        fn with_session() -> Self {
            let mut store = Self::default();
            store.sessions.insert(
                crate::devices::link_secret_hash(LINK_CODE),
                session_record(),
            );
            store
        }

        fn with_pending_request() -> Self {
            let mut store = Self::with_session();
            store.requests.insert(
                REQUEST_ID.to_owned(),
                request_record(LinkRequestStatus::Pending),
            );
            store
        }

        fn with_approved_request() -> Self {
            let mut store = Self::with_session();
            let mut request = request_record(LinkRequestStatus::Approved);
            request.approved_device_certificate = Some(approved_certificate());
            request.encrypted_provisioning_blob = Some("encrypted-provisioning".to_owned());
            store.requests.insert(REQUEST_ID.to_owned(), request);
            store
        }
    }

    impl DeviceLinkStore for FakeLinkStore {
        fn start_session(
            &mut self,
            input: CreateLinkSession,
        ) -> Result<LinkSessionRecord, StoreError> {
            self.started.push(input.clone());
            let session = LinkSessionRecord {
                id: SESSION_ID.to_owned(),
                account_id: input.account_id,
                user_handle: HANDLE.to_owned(),
                old_device_id: input.old_device_id,
                l_dh_pub: input.l_dh_pub,
                expires_at_ms: input.expires_at_ms,
            };
            self.sessions.insert(input.link_code_hash, session.clone());
            Ok(session)
        }

        fn find_active_session_by_code_hash(
            &mut self,
            link_code_hash: &str,
            now_ms: u64,
        ) -> Result<Option<LinkSessionRecord>, StoreError> {
            Ok(self
                .sessions
                .get(link_code_hash)
                .filter(|session| session.expires_at_ms > now_ms)
                .cloned())
        }

        fn create_request(
            &mut self,
            input: CreateLinkRequest,
        ) -> Result<LinkRequestRecord, StoreError> {
            self.created_requests.push(input.clone());
            let request = LinkRequestRecord {
                id: REQUEST_ID.to_owned(),
                session_id: input.session_id,
                account_id: ACCOUNT_ID.to_owned(),
                old_device_id: HOST_DEVICE_ID.to_owned(),
                user_handle: input.user_handle,
                new_device_id: input.new_device_id,
                n_dh_pub: input.n_dh_pub,
                dk_sign_pub: input.dk_sign_pub,
                dk_dh_pub: input.dk_dh_pub,
                status: LinkRequestStatus::Pending,
                approved_device_certificate: None,
                encrypted_provisioning_blob: None,
                expires_at_ms: NOW_MS + 300_000,
                completed_at_ms: None,
                created_at: NOW_ISO.to_owned(),
            };
            self.requests.insert(request.id.clone(), request.clone());
            Ok(request)
        }

        fn notify_link_request(
            &mut self,
            _account_id: &str,
            request_id: &str,
            _new_device_id: &str,
        ) -> Result<(), StoreError> {
            self.request_notifications.push(request_id.to_owned());
            Ok(())
        }

        fn list_requests_by_session(
            &mut self,
            _account_id: &str,
            session_id: &str,
        ) -> Result<Vec<LinkRequestRecord>, StoreError> {
            Ok(self
                .requests
                .values()
                .filter(|request| request.session_id == session_id)
                .cloned()
                .collect())
        }

        fn find_request_by_poll_token(
            &mut self,
            request_id: &str,
            poll_token_hash: &str,
        ) -> Result<Option<LinkRequestRecord>, StoreError> {
            if poll_token_hash != crate::devices::link_secret_hash(POLL_TOKEN) {
                return Ok(None);
            }
            Ok(self.requests.get(request_id).cloned())
        }

        fn get_request_by_id(
            &mut self,
            request_id: &str,
        ) -> Result<Option<LinkRequestRecord>, StoreError> {
            Ok(self.requests.get(request_id).cloned())
        }

        fn find_account_identity(
            &mut self,
            _account_id: &str,
        ) -> Result<Option<LinkAccountIdentity>, StoreError> {
            let (_account_key, account_pub) = signing_material(8);
            Ok(Some(LinkAccountIdentity {
                user_handle: HANDLE.to_owned(),
                account_sign_pub: account_pub,
            }))
        }

        fn find_host_device(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Option<HostDeviceRecord>, StoreError> {
            Ok(Some(HostDeviceRecord {
                device_id: HOST_DEVICE_ID.to_owned(),
                certificate_chain: vec![root_certificate()],
            }))
        }

        fn approve_request(
            &mut self,
            input: ApproveLinkRequest,
        ) -> Result<Option<LinkRequestRecord>, StoreError> {
            self.approvals.push(input.clone());
            let Some(request) = self.requests.get_mut(&input.request_id) else {
                return Ok(None);
            };
            request.status = LinkRequestStatus::Approved;
            request.approved_device_certificate = Some(input.approved_device_certificate);
            request.encrypted_provisioning_blob = Some(input.encrypted_provisioning_blob);
            Ok(Some(request.clone()))
        }

        fn notify_link_approved(&mut self, request_id: &str) -> Result<(), StoreError> {
            self.approved_notifications.push(request_id.to_owned());
            Ok(())
        }

        fn register_linked_device(
            &mut self,
            _account_id: &str,
            device_keys: &DevicePublicKeys,
            _certificate_chain: &[DeviceCertificate],
        ) -> Result<(), StoreError> {
            self.registered_devices
                .push(device_keys.device_id().to_owned());
            Ok(())
        }

        fn publish_link_prekeys(
            &mut self,
            _account_id: &str,
            device_id: &str,
            signed_prekey: &SignedPrekey,
            one_time_prekeys: &[OneTimePrekey],
        ) -> Result<(), StoreError> {
            self.published_prekeys.push(format!(
                "{}:{}:{}",
                device_id,
                signed_prekey.prekey_id,
                one_time_prekeys.len()
            ));
            Ok(())
        }

        fn insert_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError> {
            self.session_tokens.push(input.token_hash.to_owned());
            Ok(())
        }

        fn insert_refresh_session(&mut self, input: PersistToken<'_>) -> Result<(), StoreError> {
            self.refresh_tokens.push(input.token_hash.to_owned());
            Ok(())
        }

        fn mark_completed(&mut self, request_id: &str) -> Result<(), StoreError> {
            self.completed_requests.push(request_id.to_owned());
            if let Some(request) = self.requests.get_mut(request_id) {
                request.completed_at_ms = Some(NOW_MS);
            }
            Ok(())
        }
    }

    fn session_record() -> LinkSessionRecord {
        LinkSessionRecord {
            id: SESSION_ID.to_owned(),
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            old_device_id: HOST_DEVICE_ID.to_owned(),
            l_dh_pub: "host-link-dh".to_owned(),
            expires_at_ms: NOW_MS + 300_000,
        }
    }

    fn request_record(status: LinkRequestStatus) -> LinkRequestRecord {
        let (_device_key, device_pub) = signing_material(10);
        LinkRequestRecord {
            id: REQUEST_ID.to_owned(),
            session_id: SESSION_ID.to_owned(),
            account_id: ACCOUNT_ID.to_owned(),
            old_device_id: HOST_DEVICE_ID.to_owned(),
            user_handle: HANDLE.to_owned(),
            new_device_id: NEW_DEVICE_ID.to_owned(),
            n_dh_pub: "new-link-dh".to_owned(),
            dk_sign_pub: device_pub,
            dk_dh_pub: "new-dh".to_owned(),
            status,
            approved_device_certificate: None,
            encrypted_provisioning_blob: None,
            expires_at_ms: NOW_MS + 300_000,
            completed_at_ms: None,
            created_at: NOW_ISO.to_owned(),
        }
    }
}
