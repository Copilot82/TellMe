//! Service-level sync stream and realtime presence contract.

use crate::auth_service::{ApiError, AuthenticatedSession, StoreError};
use crate::sync::{
    socket_pull_limit, stream_query, ClientEvent, ServerEvent, DEFAULT_OFFLINE_OVERRIDE_TTL_SEC,
    DEFAULT_SYNC_LIMIT,
};
use serde::Serialize;

/// Mailbox row exposed by sync routes. Ciphertext remains opaque to the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncBlobRecord {
    pub id: String,
    pub owner_account_id: String,
    pub owner_device_id: String,
    pub sender_server: String,
    pub message_id: String,
    pub delivery_id: String,
    pub device_id: String,
    pub ciphertext_blob: String,
    pub ttl_sec: i64,
    pub expires_at: String,
    pub acked_at: Option<String>,
    pub created_at: String,
}

/// Sync response payload for REST and Socket.IO.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SyncBlobsResponse {
    pub device_id: String,
    pub blobs: Vec<SyncBlobRecord>,
}

/// Query input for REST `/api/sync/stream`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncStreamRequest {
    pub limit: Option<u64>,
    pub device_id: Option<String>,
}

/// Socket event runtime context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SocketPresenceContext {
    pub socket_id: String,
    pub timestamp: String,
}

/// Emitted Socket.IO payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SocketEmit {
    pub event: ServerEvent,
    pub payload: SyncBlobsResponse,
}

/// Storage and presence side-effect boundary for sync.
// Sync storage exposes mailbox envelopes only; decrypted conversation state is client-owned.
pub trait SyncStore {
    /// Lists pending encrypted mailbox blobs.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_pending(
        &mut self,
        account_id: &str,
        device_id: &str,
        limit: u64,
    ) -> Result<Vec<SyncBlobRecord>, StoreError>;

    /// Touches socket presence for an account/device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when presence storage cannot be updated.
    fn touch_presence(
        &mut self,
        account_id: &str,
        device_id: &str,
        socket_id: &str,
        timestamp: &str,
    ) -> Result<(), StoreError>;

    /// Clears socket presence for an account/device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when presence storage cannot be updated.
    fn clear_presence(
        &mut self,
        account_id: &str,
        device_id: &str,
        socket_id: &str,
    ) -> Result<(), StoreError>;

    /// Sets the short offline override used when a device explicitly disconnects.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when presence storage cannot be updated.
    fn set_offline_override(
        &mut self,
        account_id: &str,
        device_id: &str,
        timestamp: &str,
        ttl_sec: u64,
    ) -> Result<(), StoreError>;
}

/// Service implementation for sync and presence events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyncService;

impl SyncService {
    /// Handles REST `/api/sync/stream`.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when query validation or mailbox lookup fails.
    pub fn stream<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        request: &SyncStreamRequest,
    ) -> Result<SyncBlobsResponse, ApiError> {
        let query = stream_query(request.limit, request.device_id.as_deref(), &auth.device_id)
            .map_err(|_| ApiError::bad_request("Invalid sync stream query"))?;
        let blobs = store
            .list_pending(&auth.account_id, &query.device_id, query.limit)
            .map_err(|_| ApiError::internal())?;

        Ok(SyncBlobsResponse {
            device_id: query.device_id,
            blobs,
        })
    }

    /// Handles `sync_subscribe`.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when presence update or mailbox lookup fails.
    pub fn socket_subscribe<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<SocketEmit, ApiError> {
        Self::touch_presence(store, auth, context)?;
        let blobs = store
            .list_pending(&auth.account_id, &auth.device_id, DEFAULT_SYNC_LIMIT)
            .map_err(|_| ApiError::internal())?;

        Ok(SocketEmit {
            event: ServerEvent::SyncBlobs,
            payload: SyncBlobsResponse {
                device_id: auth.device_id.clone(),
                blobs,
            },
        })
    }

    /// Handles `sync_pull`.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when presence update or mailbox lookup fails.
    pub fn socket_pull<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
        limit: Option<i64>,
    ) -> Result<SocketEmit, ApiError> {
        Self::touch_presence(store, auth, context)?;
        let blobs = store
            .list_pending(&auth.account_id, &auth.device_id, socket_pull_limit(limit))
            .map_err(|_| ApiError::internal())?;

        Ok(SocketEmit {
            event: ServerEvent::SyncBlobs,
            payload: SyncBlobsResponse {
                device_id: auth.device_id.clone(),
                blobs,
            },
        })
    }

    /// Handles presence-only socket events.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when presence storage cannot be updated.
    pub fn socket_presence_event<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
        event: ClientEvent,
    ) -> Result<(), ApiError> {
        match event {
            ClientEvent::PresenceTouch
            | ClientEvent::JoinConversation
            | ClientEvent::LeaveConversation => Self::touch_presence(store, auth, context),
            ClientEvent::PresenceOffline => {
                store
                    .set_offline_override(
                        &auth.account_id,
                        &auth.device_id,
                        &context.timestamp,
                        DEFAULT_OFFLINE_OVERRIDE_TTL_SEC,
                    )
                    .map_err(|_| ApiError::internal())?;
                Self::clear_presence(store, auth, context)
            }
            ClientEvent::Disconnect => Self::clear_presence(store, auth, context),
            ClientEvent::SyncSubscribe | ClientEvent::SyncPull => Ok(()),
        }
    }

    fn touch_presence<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), ApiError> {
        store
            .touch_presence(
                &auth.account_id,
                &auth.device_id,
                &context.socket_id,
                &context.timestamp,
            )
            .map_err(|_| ApiError::internal())
    }

    fn clear_presence<S: SyncStore>(
        store: &mut S,
        auth: &AuthenticatedSession,
        context: &SocketPresenceContext,
    ) -> Result<(), ApiError> {
        store
            .clear_presence(&auth.account_id, &auth.device_id, &context.socket_id)
            .map_err(|_| ApiError::internal())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        SocketPresenceContext, SyncBlobRecord, SyncBlobsResponse, SyncService, SyncStore,
        SyncStreamRequest,
    };
    use crate::auth_service::{ApiError, ApiStatus, AuthenticatedSession, StoreError};
    use crate::sync::{ClientEvent, ServerEvent, DEFAULT_OFFLINE_OVERRIDE_TTL_SEC};

    const ACCOUNT_ID: &str = "acc-1";
    const DEVICE_ID: &str = "ios-primary";
    const SOCKET_ID: &str = "socket-1";
    const TIMESTAMP: &str = "2026-02-26T12:00:00.000Z";

    #[test]
    fn stream_uses_current_device_and_default_limit() {
        let mut store = FakeSyncStore::with_blob();
        let request = SyncStreamRequest {
            limit: None,
            device_id: None,
        };

        let response = SyncService::stream(&mut store, &auth(), &request);

        assert_blob_response(response, DEVICE_ID);
        assert_eq!(
            store.pending_requests.first().map(PendingRequest::limit),
            Some(200)
        );
    }

    #[test]
    fn stream_rejects_invalid_limit() {
        let mut store = FakeSyncStore::default();
        let request = SyncStreamRequest {
            limit: Some(1_001),
            device_id: None,
        };

        assert_eq!(
            SyncService::stream(&mut store, &auth(), &request).err(),
            Some(ApiError::new(
                ApiStatus::BadRequest,
                "Invalid sync stream query",
                None
            ))
        );
    }

    #[test]
    fn socket_subscribe_touches_presence_and_emits_sync_blobs() {
        let mut store = FakeSyncStore::with_blob();

        let response = SyncService::socket_subscribe(&mut store, &auth(), &context());

        assert!(response.is_ok());
        let Ok(emit) = response else {
            return;
        };
        assert_eq!(emit.event, ServerEvent::SyncBlobs);
        assert_eq!(emit.payload.device_id, DEVICE_ID);
        assert_eq!(store.touches.len(), 1);
        assert_eq!(
            store.pending_requests.first().map(PendingRequest::limit),
            Some(200)
        );
    }

    #[test]
    fn socket_pull_clamps_limit_and_keeps_payload_encrypted() {
        let mut store = FakeSyncStore::with_blob();

        let response = SyncService::socket_pull(&mut store, &auth(), &context(), Some(5_000));

        assert!(response.is_ok());
        let Ok(emit) = response else {
            return;
        };
        assert_eq!(
            emit.payload
                .blobs
                .first()
                .map(|blob| blob.ciphertext_blob.as_str()),
            Some("ciphertext")
        );
        assert_eq!(
            store.pending_requests.first().map(PendingRequest::limit),
            Some(1_000)
        );
    }

    #[test]
    fn presence_only_events_do_not_persist_conversation_state() {
        let mut store = FakeSyncStore::default();

        let joined = SyncService::socket_presence_event(
            &mut store,
            &auth(),
            &context(),
            ClientEvent::JoinConversation,
        );
        let left = SyncService::socket_presence_event(
            &mut store,
            &auth(),
            &context(),
            ClientEvent::LeaveConversation,
        );

        assert_eq!(joined, Ok(()));
        assert_eq!(left, Ok(()));
        assert_eq!(store.touches.len(), 2);
        assert!(store.offline_overrides.is_empty());
        assert!(store.clears.is_empty());
    }

    #[test]
    fn offline_and_disconnect_clear_presence() {
        let mut store = FakeSyncStore::default();

        let offline = SyncService::socket_presence_event(
            &mut store,
            &auth(),
            &context(),
            ClientEvent::PresenceOffline,
        );
        let disconnect = SyncService::socket_presence_event(
            &mut store,
            &auth(),
            &context(),
            ClientEvent::Disconnect,
        );

        assert_eq!(offline, Ok(()));
        assert_eq!(disconnect, Ok(()));
        assert_eq!(
            store.offline_overrides.first().map(OfflineOverride::ttl),
            Some(DEFAULT_OFFLINE_OVERRIDE_TTL_SEC)
        );
        assert_eq!(store.clears.len(), 2);
    }

    fn assert_blob_response(response: Result<SyncBlobsResponse, ApiError>, device_id: &str) {
        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.device_id, device_id);
        assert_eq!(body.blobs.len(), 1);
        assert_eq!(
            body.blobs.first().map(|blob| blob.ciphertext_blob.as_str()),
            Some("ciphertext")
        );
    }

    fn auth() -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: ACCOUNT_ID.to_owned(),
            user_handle: "@alice:example.com".to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: "sess-1".to_owned(),
        }
    }

    fn context() -> SocketPresenceContext {
        SocketPresenceContext {
            socket_id: SOCKET_ID.to_owned(),
            timestamp: TIMESTAMP.to_owned(),
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeSyncStore {
        blobs: Vec<SyncBlobRecord>,
        pending_requests: Vec<PendingRequest>,
        touches: Vec<PresenceTouch>,
        clears: Vec<PresenceClear>,
        offline_overrides: Vec<OfflineOverride>,
    }

    impl FakeSyncStore {
        fn with_blob() -> Self {
            Self {
                blobs: vec![SyncBlobRecord {
                    id: "mailbox-row-1".to_owned(),
                    owner_account_id: ACCOUNT_ID.to_owned(),
                    owner_device_id: DEVICE_ID.to_owned(),
                    sender_server: "sender.test".to_owned(),
                    message_id: "message-1".to_owned(),
                    delivery_id: "delivery-1".to_owned(),
                    device_id: DEVICE_ID.to_owned(),
                    ciphertext_blob: "ciphertext".to_owned(),
                    ttl_sec: 3_600,
                    expires_at: "2026-01-01T00:00:00.000Z".to_owned(),
                    acked_at: None,
                    created_at: "2026-01-01T00:00:00.000Z".to_owned(),
                }],
                pending_requests: Vec::new(),
                touches: Vec::new(),
                clears: Vec::new(),
                offline_overrides: Vec::new(),
            }
        }
    }

    impl SyncStore for FakeSyncStore {
        fn list_pending(
            &mut self,
            account_id: &str,
            device_id: &str,
            limit: u64,
        ) -> Result<Vec<SyncBlobRecord>, StoreError> {
            self.pending_requests.push(PendingRequest {
                account_id: account_id.to_owned(),
                device_id: device_id.to_owned(),
                limit,
            });
            Ok(self.blobs.clone())
        }

        fn touch_presence(
            &mut self,
            account_id: &str,
            device_id: &str,
            socket_id: &str,
            timestamp: &str,
        ) -> Result<(), StoreError> {
            self.touches.push(PresenceTouch {
                account_id: account_id.to_owned(),
                device_id: device_id.to_owned(),
                socket_id: socket_id.to_owned(),
                timestamp: timestamp.to_owned(),
            });
            Ok(())
        }

        fn clear_presence(
            &mut self,
            account_id: &str,
            device_id: &str,
            socket_id: &str,
        ) -> Result<(), StoreError> {
            self.clears.push(PresenceClear {
                account: account_id.to_owned(),
                device: device_id.to_owned(),
                socket: socket_id.to_owned(),
            });
            Ok(())
        }

        fn set_offline_override(
            &mut self,
            account_id: &str,
            device_id: &str,
            timestamp: &str,
            ttl_sec: u64,
        ) -> Result<(), StoreError> {
            self.offline_overrides.push(OfflineOverride {
                account_id: account_id.to_owned(),
                device_id: device_id.to_owned(),
                timestamp: timestamp.to_owned(),
                ttl_sec,
            });
            Ok(())
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct PendingRequest {
        account_id: String,
        device_id: String,
        limit: u64,
    }

    impl PendingRequest {
        const fn limit(&self) -> u64 {
            self.limit
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct PresenceTouch {
        account_id: String,
        device_id: String,
        socket_id: String,
        timestamp: String,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct PresenceClear {
        account: String,
        device: String,
        socket: String,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct OfflineOverride {
        account_id: String,
        device_id: String,
        timestamp: String,
        ttl_sec: u64,
    }

    impl OfflineOverride {
        const fn ttl(&self) -> u64 {
            self.ttl_sec
        }
    }
}
