//! Sync and realtime event contract for the Rust backend.

use serde::Serialize;
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Default pending mailbox page size.
pub const DEFAULT_SYNC_LIMIT: u64 = 200;

/// Maximum pending mailbox page size.
pub const MAX_SYNC_LIMIT: u64 = 1_000;

/// Default offline override TTL used by WebSocket presence.
pub const DEFAULT_OFFLINE_OVERRIDE_TTL_SEC: u64 = 20;

/// Client-to-server Socket.IO events accepted by the current backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientEvent {
    SyncSubscribe,
    SyncPull,
    PresenceTouch,
    JoinConversation,
    LeaveConversation,
    PresenceOffline,
    Disconnect,
}

impl ClientEvent {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::SyncSubscribe => "sync_subscribe",
            Self::SyncPull => "sync_pull",
            Self::PresenceTouch => "presence_touch",
            Self::JoinConversation => "join_conversation",
            Self::LeaveConversation => "leave_conversation",
            Self::PresenceOffline => "presence_offline",
            Self::Disconnect => "disconnect",
        }
    }
}

/// Server-to-client Socket.IO events emitted by current v2 routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerEvent {
    SyncBlobs,
    SyncBlobAvailable,
    DeviceLinkRequest,
    DeviceLinkApproved,
}

impl ServerEvent {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::SyncBlobs => "sync_blobs",
            Self::SyncBlobAvailable => "sync_blob_available",
            Self::DeviceLinkRequest => "device_link_request",
            Self::DeviceLinkApproved => "device_link_approved",
        }
    }
}

/// Validated `/sync/stream` request parameters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncStreamQuery {
    pub limit: u64,
    pub device_id: String,
}

/// Sync blob notification payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncBlobAvailablePayload {
    pub message_id: String,
    pub delivery_id: String,
    pub device_id: String,
}

/// Device-link request notification payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeviceLinkRequestPayload {
    pub request_id: String,
    pub new_device_id: String,
}

/// Device-link approval notification payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeviceLinkApprovedPayload {
    pub request_id: String,
}

/// Sync/WebSocket contract error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncError {
    InvalidLimit,
    MissingAuthToken,
}

impl Display for SyncError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidLimit => formatter.write_str("invalid sync limit"),
            Self::MissingAuthToken => formatter.write_str("missing websocket auth token"),
        }
    }
}

impl Error for SyncError {}

/// Validates REST `/sync/stream` query behavior.
///
/// # Errors
///
/// Returns an error when `limit` is outside `1..=1000`.
pub fn stream_query(
    limit: Option<u64>,
    requested_device_id: Option<&str>,
    current_device_id: &str,
) -> Result<SyncStreamQuery, SyncError> {
    let resolved_limit = limit.unwrap_or(DEFAULT_SYNC_LIMIT);
    if resolved_limit == 0 || resolved_limit > MAX_SYNC_LIMIT {
        return Err(SyncError::InvalidLimit);
    }

    Ok(SyncStreamQuery {
        limit: resolved_limit,
        device_id: requested_device_id.unwrap_or(current_device_id).to_owned(),
    })
}

#[must_use]
pub fn socket_pull_limit(limit: Option<i64>) -> u64 {
    let Some(value) = limit else {
        return DEFAULT_SYNC_LIMIT;
    };
    if value == 0 {
        return DEFAULT_SYNC_LIMIT;
    }
    let Ok(unsigned) = u64::try_from(value) else {
        return 1;
    };

    unsigned.clamp(1, MAX_SYNC_LIMIT)
}

/// Extracts a Socket.IO auth token value.
///
/// # Errors
///
/// Returns an error when the token is missing or blank.
pub const fn socket_auth_token(token: Option<&str>) -> Result<&str, SyncError> {
    let Some(value) = token else {
        return Err(SyncError::MissingAuthToken);
    };
    if value.is_empty() {
        return Err(SyncError::MissingAuthToken);
    }

    Ok(value)
}

#[must_use]
pub fn account_room(account_id: &str) -> String {
    format!("account:{account_id}")
}

#[must_use]
pub fn device_room(account_id: &str, device_id: &str) -> String {
    format!("device:{account_id}:{device_id}")
}

#[must_use]
pub fn link_request_room(request_id: &str) -> String {
    format!("link-request:{request_id}")
}

#[must_use]
pub fn account_sessions_key(account_id: &str) -> String {
    format!("account_sessions:{account_id}")
}

#[must_use]
pub fn device_sessions_key(account_id: &str, device_id: &str) -> String {
    format!("device_sessions:{account_id}:{device_id}")
}

#[must_use]
pub fn device_active_chat_key(account_id: &str, device_id: &str) -> String {
    format!("device_active_chat:{account_id}:{device_id}")
}

#[must_use]
pub fn device_offline_override_key(account_id: &str, device_id: &str) -> String {
    format!("device_offline:{account_id}:{device_id}")
}

#[must_use]
pub const fn plaintext_call_signaling_events_enabled() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::{
        account_room, account_sessions_key, device_active_chat_key, device_offline_override_key,
        device_room, device_sessions_key, link_request_room,
        plaintext_call_signaling_events_enabled, socket_auth_token, socket_pull_limit,
        stream_query, ClientEvent, ServerEvent, SyncError,
    };

    #[test]
    fn validates_rest_stream_query_like_route() {
        assert_eq!(
            stream_query(None, None, "dev-a"),
            Ok(super::SyncStreamQuery {
                limit: 200,
                device_id: "dev-a".to_owned(),
            })
        );
        assert_eq!(
            stream_query(Some(500), Some("dev-b"), "dev-a"),
            Ok(super::SyncStreamQuery {
                limit: 500,
                device_id: "dev-b".to_owned(),
            })
        );
        assert_eq!(
            stream_query(Some(0), None, "dev-a"),
            Err(SyncError::InvalidLimit)
        );
        assert_eq!(
            stream_query(Some(1_001), None, "dev-a"),
            Err(SyncError::InvalidLimit)
        );
    }

    #[test]
    fn clamps_socket_pull_limit_like_socket_handler() {
        assert_eq!(socket_pull_limit(None), 200);
        assert_eq!(socket_pull_limit(Some(0)), 200);
        assert_eq!(socket_pull_limit(Some(-10)), 1);
        assert_eq!(socket_pull_limit(Some(1_500)), 1_000);
        assert_eq!(socket_pull_limit(Some(50)), 50);
    }

    #[test]
    fn defines_required_socket_event_names() {
        assert_eq!(ClientEvent::SyncSubscribe.as_wire(), "sync_subscribe");
        assert_eq!(ClientEvent::SyncPull.as_wire(), "sync_pull");
        assert_eq!(ClientEvent::PresenceOffline.as_wire(), "presence_offline");
        assert_eq!(ServerEvent::SyncBlobs.as_wire(), "sync_blobs");
        assert_eq!(
            ServerEvent::SyncBlobAvailable.as_wire(),
            "sync_blob_available"
        );
        assert_eq!(
            ServerEvent::DeviceLinkRequest.as_wire(),
            "device_link_request"
        );
        assert_eq!(
            ServerEvent::DeviceLinkApproved.as_wire(),
            "device_link_approved"
        );
    }

    #[test]
    fn derives_socket_rooms_and_presence_keys() {
        assert_eq!(account_room("acc-a"), "account:acc-a");
        assert_eq!(device_room("acc-a", "dev-a"), "device:acc-a:dev-a");
        assert_eq!(link_request_room("req-1"), "link-request:req-1");
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
    fn requires_socket_auth_token() {
        assert_eq!(socket_auth_token(Some("token")), Ok("token"));
        assert_eq!(socket_auth_token(None), Err(SyncError::MissingAuthToken));
        assert_eq!(
            socket_auth_token(Some("")),
            Err(SyncError::MissingAuthToken)
        );
    }

    #[test]
    fn keeps_plaintext_call_signaling_disabled_for_websocket_contract() {
        assert!(!plaintext_call_signaling_events_enabled());
    }
}
