//! In-process realtime notification hub for the Rust Socket.IO runtime.
//!
//! This hub carries only routing metadata already permitted by the frozen contract. It never carries message
//! plaintext, media plaintext, SDP, ICE candidates, or call state.

use crate::auth_service::AuthenticatedSession;
use crate::sync::{
    DeviceLinkApprovedPayload, DeviceLinkRequestPayload, ServerEvent, SyncBlobAvailablePayload,
};
use tokio::sync::broadcast;

const REALTIME_CHANNEL_CAPACITY: usize = 1_024;

/// Realtime room identifier matching the current Socket.IO room contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RealtimeRoom {
    Account(String),
    LinkRequest(String),
}

/// Metadata-only realtime payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RealtimePayload {
    SyncBlobAvailable(SyncBlobAvailablePayload),
    DeviceLinkRequest(DeviceLinkRequestPayload),
    DeviceLinkApproved(DeviceLinkApprovedPayload),
}

/// Metadata-only realtime envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealtimeEnvelope {
    room: RealtimeRoom,
    event: ServerEvent,
    payload: RealtimePayload,
}

impl RealtimeEnvelope {
    #[must_use]
    pub const fn new(room: RealtimeRoom, event: ServerEvent, payload: RealtimePayload) -> Self {
        Self {
            room,
            event,
            payload,
        }
    }

    #[must_use]
    pub const fn room(&self) -> &RealtimeRoom {
        &self.room
    }

    #[must_use]
    pub const fn event(&self) -> ServerEvent {
        self.event
    }

    #[must_use]
    pub const fn payload(&self) -> &RealtimePayload {
        &self.payload
    }

    #[must_use]
    pub fn is_visible_to(&self, auth: &AuthenticatedSession) -> bool {
        matches!(&self.room, RealtimeRoom::Account(account_id) if account_id == &auth.account_id)
    }
}

/// Broadcast hub shared by HTTP route adapters and Socket.IO connections.
#[derive(Debug, Clone)]
pub struct RealtimeHub {
    sender: broadcast::Sender<RealtimeEnvelope>,
}

impl RealtimeHub {
    #[must_use]
    pub fn new() -> Self {
        let (sender, _receiver) = broadcast::channel(REALTIME_CHANNEL_CAPACITY);
        Self { sender }
    }

    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<RealtimeEnvelope> {
        self.sender.subscribe()
    }

    pub fn publish(&self, envelope: RealtimeEnvelope) {
        let _receiver_count = self.sender.send(envelope);
    }

    pub fn notify_sync_blob_available(
        &self,
        account_id: &str,
        message_id: &str,
        delivery_id: &str,
        device_id: &str,
    ) {
        self.publish(RealtimeEnvelope::new(
            RealtimeRoom::Account(account_id.to_owned()),
            ServerEvent::SyncBlobAvailable,
            RealtimePayload::SyncBlobAvailable(SyncBlobAvailablePayload {
                message_id: message_id.to_owned(),
                delivery_id: delivery_id.to_owned(),
                device_id: device_id.to_owned(),
            }),
        ));
    }

    pub fn notify_link_request(&self, account_id: &str, request_id: &str, new_device_id: &str) {
        self.publish(RealtimeEnvelope::new(
            RealtimeRoom::Account(account_id.to_owned()),
            ServerEvent::DeviceLinkRequest,
            RealtimePayload::DeviceLinkRequest(DeviceLinkRequestPayload {
                request_id: request_id.to_owned(),
                new_device_id: new_device_id.to_owned(),
            }),
        ));
    }

    pub fn notify_link_approved(&self, request_id: &str) {
        self.publish(RealtimeEnvelope::new(
            RealtimeRoom::LinkRequest(request_id.to_owned()),
            ServerEvent::DeviceLinkApproved,
            RealtimePayload::DeviceLinkApproved(DeviceLinkApprovedPayload {
                request_id: request_id.to_owned(),
            }),
        ));
    }
}

impl Default for RealtimeHub {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::{RealtimeEnvelope, RealtimeHub, RealtimePayload, RealtimeRoom};
    use crate::auth_service::AuthenticatedSession;
    use crate::sync::{ServerEvent, SyncBlobAvailablePayload};

    #[tokio::test]
    async fn publishes_sync_blob_available_without_ciphertext_or_call_state() {
        let hub = RealtimeHub::new();
        let mut receiver = hub.subscribe();

        hub.notify_sync_blob_available("acc-1", "msg-1", "delivery-1", "ios-primary");
        let recv_result = receiver.recv().await;
        assert!(recv_result.is_ok());
        let Ok(envelope) = recv_result else {
            return;
        };

        assert_eq!(envelope.event(), ServerEvent::SyncBlobAvailable);
        assert!(envelope.is_visible_to(&auth("acc-1")));
        assert!(!envelope.is_visible_to(&auth("other")));
        let RealtimePayload::SyncBlobAvailable(payload) = envelope.payload() else {
            return;
        };
        assert_eq!(payload.message_id, "msg-1");
        assert_eq!(payload.delivery_id, "delivery-1");
        assert_eq!(payload.device_id, "ios-primary");
    }

    #[tokio::test]
    async fn link_approved_room_is_not_account_visible_without_explicit_join() {
        let hub = RealtimeHub::new();
        let mut receiver = hub.subscribe();

        hub.notify_link_approved("request-1");
        let recv_result = receiver.recv().await;
        assert!(recv_result.is_ok());
        let Ok(envelope) = recv_result else {
            return;
        };

        assert_eq!(
            envelope.room(),
            &RealtimeRoom::LinkRequest("request-1".to_owned())
        );
        assert!(!envelope.is_visible_to(&auth("acc-1")));
    }

    #[test]
    fn envelope_payload_shape_has_no_call_or_plaintext_fields() {
        let envelope = RealtimeEnvelope::new(
            RealtimeRoom::Account("acc-1".to_owned()),
            ServerEvent::SyncBlobAvailable,
            RealtimePayload::SyncBlobAvailable(SyncBlobAvailablePayload {
                message_id: "msg-1".to_owned(),
                delivery_id: "delivery-1".to_owned(),
                device_id: "ios-primary".to_owned(),
            }),
        );

        let RealtimePayload::SyncBlobAvailable(payload) = envelope.payload() else {
            return;
        };
        assert_eq!(payload.message_id, "msg-1");
    }

    fn auth(account_id: &str) -> AuthenticatedSession {
        AuthenticatedSession {
            account_id: account_id.to_owned(),
            user_handle: "@alice:example.com".to_owned(),
            device_id: "ios-primary".to_owned(),
            session_id: "session-1".to_owned(),
        }
    }
}
