//! Service-level message send and ack contract.
//!
//! Message bodies remain opaque ciphertext. This layer only handles the same routing metadata the TypeScript backend is
//! allowed to see and explicitly suppresses plaintext call push hints.

use crate::auth_service::{ApiError, StoreError};
use crate::messages::{
    normalized_delivery, push_kind_for_job, resolve_delivery_routing, sender_server_from_handle,
    validate_ack_ids, validate_send_batch, DeliveryRoutingInput, DeliveryUnit, PushKind,
    WakeupClass,
};
use serde::{Deserialize, Serialize};

/// Account row needed for local delivery routing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageAccountRecord {
    id: String,
}

impl MessageAccountRecord {
    #[must_use]
    pub const fn new(id: String) -> Self {
        Self { id }
    }

    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }
}

/// Storage and side-effect boundary for message routes.
// The store boundary handles routing metadata while treating every message body as opaque ciphertext.
pub trait MessageStore {
    /// Finds an account by normalized handle.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn find_account_by_handle(
        &mut self,
        user_handle: &str,
    ) -> Result<Option<MessageAccountRecord>, StoreError>;

    /// Lists active device ids for an account.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn list_active_device_ids(&mut self, account_id: &str) -> Result<Vec<String>, StoreError>;

    /// Checks whether a target device has opted into fast notification metadata.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot be queried.
    fn device_allows_fast_notify(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<bool, StoreError>;

    /// Inserts a local mailbox delivery. Returns `false` for duplicate delivery ids.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot insert the mailbox blob.
    fn insert_local_delivery(&mut self, input: LocalDeliveryInsert<'_>)
        -> Result<bool, StoreError>;

    /// Creates a push job for a newly inserted local mailbox delivery.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot create the push job.
    fn create_push_job(&mut self, input: PushJobInsert<'_>) -> Result<bool, StoreError>;

    /// Emits a sync notification to currently connected devices.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when the side-effect boundary fails.
    fn notify_sync_blob_available(
        &mut self,
        account_id: &str,
        message_id: &str,
        delivery_id: &str,
        device_id: &str,
    ) -> Result<(), StoreError>;

    /// Creates one federation outbox job.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot create the outbox job.
    fn create_outbox_job(&mut self, input: OutboxJobInsert<'_>) -> Result<(), StoreError>;

    /// Acks pending mailbox messages for the authenticated device.
    ///
    /// # Errors
    ///
    /// Returns `StoreError` when durable storage cannot update mailbox rows.
    fn ack_messages(
        &mut self,
        account_id: &str,
        device_id: &str,
        message_ids: &[String],
    ) -> Result<usize, StoreError>;
}

/// Local mailbox insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalDeliveryInsert<'a> {
    pub owner_account_id: &'a str,
    pub owner_device_id: &'a str,
    pub sender_server: &'a str,
    pub delivery: &'a DeliveryUnit,
    pub relay_type: &'static str,
}

/// Push job insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PushJobInsert<'a> {
    pub owner_account_id: &'a str,
    pub owner_device_id: &'a str,
    pub from_device_id: &'a str,
    pub message_id: &'a str,
    pub delivery_id: &'a str,
    pub push_kind: Option<PushKind>,
    pub wakeup_class: WakeupClass,
}

/// Federation outbox insert input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutboxJobInsert<'a> {
    pub to_server: &'a str,
    pub from_device_id: &'a str,
    pub deliveries: &'a [DeliveryUnit],
}

/// Authenticated sender context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSender {
    pub account_id: String,
    pub user_handle: String,
    pub device_id: String,
}

/// Runtime routing context.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSendContext {
    pub server_domain: Option<String>,
    pub aliases_raw: Option<String>,
}

/// Request body for `/api/messages/send`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MessageSendRequest {
    pub deliveries: Vec<DeliveryUnit>,
}

/// One send result row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MessageSendResult {
    pub delivery_id: String,
    pub status: &'static str,
}

/// Response body for `/api/messages/send`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MessageSendResponse {
    pub accepted: usize,
    pub results: Vec<MessageSendResult>,
}

/// Request body for `/api/messages/ack`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MessageAckRequest {
    pub msg_ids: Vec<String>,
}

/// Response body for `/api/messages/ack`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct MessageAckResponse {
    pub acked: usize,
}

/// Service implementation for message routes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MessageService;

impl MessageService {
    /// Routes encrypted delivery units locally or to federation outbox jobs.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation or storage side effects fail.
    pub fn send<S: MessageStore>(
        store: &mut S,
        sender: &MessageSender,
        context: &MessageSendContext,
        request: &MessageSendRequest,
    ) -> Result<MessageSendResponse, ApiError> {
        validate_send_batch(&request.deliveries)
            .map_err(|_| ApiError::bad_request("Invalid message delivery payload"))?;

        let mut results = Vec::with_capacity(request.deliveries.len());
        let mut remote_batches: Vec<RemoteBatch> = Vec::new();
        for raw in &request.deliveries {
            let delivery = normalized_delivery(raw);
            let routing = resolve_delivery_routing(&DeliveryRoutingInput {
                to_server: &delivery.to_server,
                to_user: &delivery.to_user,
                server_domain: context.server_domain.as_deref(),
                sender_handle: Some(&sender.user_handle),
                aliases_raw: context.aliases_raw.as_deref(),
            });
            let target_server = if routing.target_server.is_empty() {
                delivery.to_server.clone()
            } else {
                routing.target_server
            };
            let routed_delivery = delivery_with_target_server(&delivery, &target_server);
            let local_account = store
                .find_account_by_handle(&delivery.to_user)
                .map_err(|_| ApiError::internal())?;

            if routing.is_local || local_account.is_some() {
                let status =
                    route_local_delivery(store, sender, local_account.as_ref(), &routed_delivery)?;
                results.push(MessageSendResult {
                    delivery_id: delivery.delivery_id,
                    status,
                });
            } else {
                push_remote_delivery(&mut remote_batches, target_server, routed_delivery);
                results.push(MessageSendResult {
                    delivery_id: delivery.delivery_id,
                    status: "queued_federation",
                });
            }
        }

        for batch in &remote_batches {
            store
                .create_outbox_job(OutboxJobInsert {
                    to_server: &batch.to_server,
                    from_device_id: &sender.device_id,
                    deliveries: &batch.deliveries,
                })
                .map_err(|_| ApiError::internal())?;
        }

        Ok(MessageSendResponse {
            accepted: results.len(),
            results,
        })
    }

    /// Acks pending encrypted mailbox messages for the authenticated device.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation or storage update fails.
    pub fn ack<S: MessageStore>(
        store: &mut S,
        sender: &MessageSender,
        request: &MessageAckRequest,
    ) -> Result<MessageAckResponse, ApiError> {
        validate_ack_ids(&request.msg_ids)
            .map_err(|_| ApiError::bad_request("Invalid message ack payload"))?;
        let acked = store
            .ack_messages(&sender.account_id, &sender.device_id, &request.msg_ids)
            .map_err(|_| ApiError::internal())?;

        Ok(MessageAckResponse { acked })
    }
}

fn route_local_delivery<S: MessageStore>(
    store: &mut S,
    sender: &MessageSender,
    local_account: Option<&MessageAccountRecord>,
    delivery: &DeliveryUnit,
) -> Result<&'static str, ApiError> {
    let Some(account) = local_account else {
        return Ok("unavailable");
    };
    let devices = store
        .list_active_device_ids(account.id())
        .map_err(|_| ApiError::internal())?;
    let target_devices = target_device_ids(&devices, &delivery.to_device_id);
    if target_devices.is_empty() {
        return Ok("unavailable");
    }

    for device_id in &target_devices {
        let inserted = store
            .insert_local_delivery(LocalDeliveryInsert {
                owner_account_id: account.id(),
                owner_device_id: device_id,
                sender_server: &sender_server_from_handle(&sender.user_handle),
                delivery,
                relay_type: "local",
            })
            .map_err(|_| ApiError::internal())?;
        if inserted {
            create_push_and_notify(store, sender, account.id(), device_id, delivery)?;
        }
    }

    Ok("queued_local")
}

fn create_push_and_notify<S: MessageStore>(
    store: &mut S,
    sender: &MessageSender,
    owner_account_id: &str,
    owner_device_id: &str,
    delivery: &DeliveryUnit,
) -> Result<(), ApiError> {
    let allowed_fast_notify = store
        .device_allows_fast_notify(owner_account_id, owner_device_id)
        .map_err(|_| ApiError::internal())?;
    let push_kind = push_kind_for_job(allowed_fast_notify, delivery.push_kind);
    let push_job_created = store
        .create_push_job(PushJobInsert {
            owner_account_id,
            owner_device_id,
            from_device_id: &sender.device_id,
            message_id: &delivery.message_id,
            delivery_id: &delivery.delivery_id,
            push_kind,
            wakeup_class: delivery.wakeup_class.unwrap_or(WakeupClass::Generic),
        })
        .map_err(|_| ApiError::internal())?;
    if push_job_created {
        store
            .notify_sync_blob_available(
                owner_account_id,
                &delivery.message_id,
                &delivery.delivery_id,
                owner_device_id,
            )
            .map_err(|_| ApiError::internal())?;
    }

    Ok(())
}

fn target_device_ids(devices: &[String], requested: &str) -> Vec<String> {
    if requested == "*" {
        return devices.to_vec();
    }

    devices
        .iter()
        .filter(|device_id| device_id.as_str() == requested)
        .cloned()
        .collect()
}

fn delivery_with_target_server(delivery: &DeliveryUnit, target_server: &str) -> DeliveryUnit {
    let mut routed = delivery.clone();
    target_server.clone_into(&mut routed.to_server);
    routed
}

fn push_remote_delivery(
    batches: &mut Vec<RemoteBatch>,
    target_server: String,
    delivery: DeliveryUnit,
) {
    if let Some(batch) = batches
        .iter_mut()
        .find(|batch| batch.to_server == target_server)
    {
        batch.deliveries.push(delivery);
        return;
    }

    batches.push(RemoteBatch {
        to_server: target_server,
        deliveries: vec![delivery],
    });
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteBatch {
    to_server: String,
    deliveries: Vec<DeliveryUnit>,
}

#[cfg(test)]
mod tests {
    use super::{
        LocalDeliveryInsert, MessageAccountRecord, MessageAckRequest, MessageSendContext,
        MessageSendRequest, MessageSender, MessageService, MessageStore, OutboxJobInsert,
        PushJobInsert,
    };
    use crate::auth_service::{ApiError, ApiStatus, StoreError};
    use crate::messages::{DeliveryUnit, PushKind, WakeupClass};
    use std::collections::{BTreeMap, BTreeSet};

    const ACCOUNT_ID: &str = "acc-bob";
    const SENDER_ACCOUNT_ID: &str = "acc-alice";
    const DEVICE_ID: &str = "ios-primary";
    const OTHER_DEVICE_ID: &str = "ios-secondary";
    const MESSAGE_ID: &str = "11111111-1111-4111-8111-111111111111";
    const DELIVERY_ID: &str = "22222222-2222-4222-8222-222222222222";

    #[test]
    fn sends_local_delivery_to_all_devices_and_suppresses_call_push_kind() {
        let mut store = FakeMessageStore::default();
        store.accounts.insert(
            "@bob:example.com".to_owned(),
            MessageAccountRecord::new(ACCOUNT_ID.to_owned()),
        );
        store.devices.insert(
            ACCOUNT_ID.to_owned(),
            vec![DEVICE_ID.to_owned(), OTHER_DEVICE_ID.to_owned()],
        );
        store
            .fast_notify_devices
            .insert(device_key(ACCOUNT_ID, DEVICE_ID));
        store
            .fast_notify_devices
            .insert(device_key(ACCOUNT_ID, OTHER_DEVICE_ID));
        let mut delivery = delivery("@bob:example.com", "*", "example.com");
        delivery.push_kind = Some(PushKind::Call);
        let request = MessageSendRequest {
            deliveries: vec![delivery],
        };

        let response = MessageService::send(&mut store, &sender(), &context(), &request);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.accepted, 1);
        assert_eq!(
            body.results.first().map(|result| result.status),
            Some("queued_local")
        );
        assert_eq!(store.local_deliveries.len(), 2);
        assert_eq!(store.push_jobs.len(), 2);
        assert!(store.push_jobs.iter().all(|job| job.push_kind.is_none()));
        assert_eq!(store.sync_notifications.len(), 2);
    }

    #[test]
    fn sends_remote_deliveries_grouped_by_target_server() {
        let mut store = FakeMessageStore::default();
        let request = MessageSendRequest {
            deliveries: vec![
                delivery("@carol:remote.example", DEVICE_ID, "remote.example"),
                delivery_with_ids(
                    "@dave:remote.example",
                    DEVICE_ID,
                    "remote.example",
                    "33333333-3333-4333-8333-333333333333",
                    "44444444-4444-4444-8444-444444444444",
                ),
            ],
        };

        let response = MessageService::send(&mut store, &sender(), &context(), &request);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.accepted, 2);
        assert_eq!(store.outbox_jobs.len(), 1);
        assert_eq!(
            store
                .outbox_jobs
                .first()
                .map(|job| (job.to_server.as_str(), job.deliveries.len())),
            Some(("remote.example", 2))
        );
    }

    #[test]
    fn local_domain_without_account_is_unavailable() {
        let mut store = FakeMessageStore::default();
        let request = MessageSendRequest {
            deliveries: vec![delivery("@missing:example.com", DEVICE_ID, "example.com")],
        };

        let response = MessageService::send(&mut store, &sender(), &context(), &request);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(
            body.results.first().map(|result| result.status),
            Some("unavailable")
        );
        assert!(store.local_deliveries.is_empty());
        assert!(store.outbox_jobs.is_empty());
    }

    #[test]
    fn rejects_invalid_send_or_ack_payloads() {
        let mut store = FakeMessageStore::default();
        let invalid_send = MessageSendRequest {
            deliveries: Vec::new(),
        };
        assert_eq!(
            MessageService::send(&mut store, &sender(), &context(), &invalid_send).err(),
            Some(ApiError::new(
                ApiStatus::BadRequest,
                "Invalid message delivery payload",
                None
            ))
        );

        let invalid_ack = MessageAckRequest {
            msg_ids: vec!["not-a-uuid".to_owned()],
        };
        assert_eq!(
            MessageService::ack(&mut store, &sender(), &invalid_ack).err(),
            Some(ApiError::new(
                ApiStatus::BadRequest,
                "Invalid message ack payload",
                None
            ))
        );
    }

    #[test]
    fn acks_for_authenticated_device_only() {
        let mut store = FakeMessageStore {
            ack_count: 3,
            ..FakeMessageStore::default()
        };
        let request = MessageAckRequest {
            msg_ids: vec![MESSAGE_ID.to_owned()],
        };

        let response = MessageService::ack(&mut store, &sender(), &request);

        assert!(response.is_ok());
        let Ok(body) = response else {
            return;
        };
        assert_eq!(body.acked, 3);
        assert_eq!(
            store.ack_requests.first().map(|request| {
                (
                    request.account_id.as_str(),
                    request.device_id.as_str(),
                    request.message_ids.len(),
                )
            }),
            Some((SENDER_ACCOUNT_ID, DEVICE_ID, 1))
        );
    }

    fn sender() -> MessageSender {
        MessageSender {
            account_id: SENDER_ACCOUNT_ID.to_owned(),
            user_handle: "@alice:example.com".to_owned(),
            device_id: DEVICE_ID.to_owned(),
        }
    }

    fn context() -> MessageSendContext {
        MessageSendContext {
            server_domain: Some("example.com".to_owned()),
            aliases_raw: Some("lan.example".to_owned()),
        }
    }

    fn delivery(to_user: &str, to_device_id: &str, to_server: &str) -> DeliveryUnit {
        delivery_with_ids(to_user, to_device_id, to_server, MESSAGE_ID, DELIVERY_ID)
    }

    fn delivery_with_ids(
        to_user: &str,
        to_device_id: &str,
        to_server: &str,
        message_id: &str,
        delivery_id: &str,
    ) -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: delivery_id.to_owned(),
            to_server: to_server.to_owned(),
            to_user: to_user.to_owned(),
            to_device_id: to_device_id.to_owned(),
            message_id: message_id.to_owned(),
            timestamp: "2026-02-26T12:00:00.000Z".to_owned(),
            ttl_sec: 60,
            ciphertext_blob: "opaque-ciphertext".to_owned(),
            push_kind: Some(PushKind::Message),
            wakeup_class: None,
        }
    }

    fn device_key(account_id: &str, device_id: &str) -> String {
        format!("{account_id}:{device_id}")
    }

    #[derive(Debug, Clone, Default)]
    struct FakeMessageStore {
        accounts: BTreeMap<String, MessageAccountRecord>,
        devices: BTreeMap<String, Vec<String>>,
        fast_notify_devices: BTreeSet<String>,
        local_deliveries: Vec<StoredLocalDelivery>,
        push_jobs: Vec<StoredPushJob>,
        sync_notifications: Vec<SyncNotification>,
        outbox_jobs: Vec<StoredOutboxJob>,
        ack_requests: Vec<AckRequest>,
        ack_count: usize,
    }

    impl MessageStore for FakeMessageStore {
        fn find_account_by_handle(
            &mut self,
            user_handle: &str,
        ) -> Result<Option<MessageAccountRecord>, StoreError> {
            Ok(self.accounts.get(user_handle).cloned())
        }

        fn list_active_device_ids(&mut self, account_id: &str) -> Result<Vec<String>, StoreError> {
            Ok(self.devices.get(account_id).cloned().unwrap_or_default())
        }

        fn device_allows_fast_notify(
            &mut self,
            account_id: &str,
            device_id: &str,
        ) -> Result<bool, StoreError> {
            Ok(self
                .fast_notify_devices
                .contains(&device_key(account_id, device_id)))
        }

        fn insert_local_delivery(
            &mut self,
            input: LocalDeliveryInsert<'_>,
        ) -> Result<bool, StoreError> {
            self.local_deliveries.push(StoredLocalDelivery {
                owner_account_id: input.owner_account_id.to_owned(),
                owner_device_id: input.owner_device_id.to_owned(),
                sender_server: input.sender_server.to_owned(),
                message_id: input.delivery.message_id.clone(),
                delivery_id: input.delivery.delivery_id.clone(),
                ciphertext_blob: input.delivery.ciphertext_blob.clone(),
                relay_type: input.relay_type,
            });
            Ok(true)
        }

        fn create_push_job(&mut self, input: PushJobInsert<'_>) -> Result<bool, StoreError> {
            self.push_jobs.push(StoredPushJob {
                owner_account_id: input.owner_account_id.to_owned(),
                owner_device_id: input.owner_device_id.to_owned(),
                from_device_id: input.from_device_id.to_owned(),
                message_id: input.message_id.to_owned(),
                delivery_id: input.delivery_id.to_owned(),
                push_kind: input.push_kind,
                wakeup_class: input.wakeup_class,
            });
            Ok(true)
        }

        fn notify_sync_blob_available(
            &mut self,
            account_id: &str,
            message_id: &str,
            delivery_id: &str,
            device_id: &str,
        ) -> Result<(), StoreError> {
            self.sync_notifications.push(SyncNotification {
                account: account_id.to_owned(),
                message: message_id.to_owned(),
                delivery: delivery_id.to_owned(),
                device: device_id.to_owned(),
            });
            Ok(())
        }

        fn create_outbox_job(&mut self, input: OutboxJobInsert<'_>) -> Result<(), StoreError> {
            self.outbox_jobs.push(StoredOutboxJob {
                to_server: input.to_server.to_owned(),
                from_device_id: input.from_device_id.to_owned(),
                deliveries: input.deliveries.to_vec(),
            });
            Ok(())
        }

        fn ack_messages(
            &mut self,
            account_id: &str,
            device_id: &str,
            message_ids: &[String],
        ) -> Result<usize, StoreError> {
            self.ack_requests.push(AckRequest {
                account_id: account_id.to_owned(),
                device_id: device_id.to_owned(),
                message_ids: message_ids.to_vec(),
            });
            Ok(self.ack_count)
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredLocalDelivery {
        owner_account_id: String,
        owner_device_id: String,
        sender_server: String,
        message_id: String,
        delivery_id: String,
        ciphertext_blob: String,
        relay_type: &'static str,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredPushJob {
        owner_account_id: String,
        owner_device_id: String,
        from_device_id: String,
        message_id: String,
        delivery_id: String,
        push_kind: Option<PushKind>,
        wakeup_class: WakeupClass,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct SyncNotification {
        account: String,
        message: String,
        delivery: String,
        device: String,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct StoredOutboxJob {
        to_server: String,
        from_device_id: String,
        deliveries: Vec<DeliveryUnit>,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct AckRequest {
        account_id: String,
        device_id: String,
        message_ids: Vec<String>,
    }
}
