//! `PostgreSQL` persistence adapter for encrypted message send and ack routes.
//!
//! This adapter stores ciphertext blobs and routing metadata only. Push jobs deliberately suppress call-oriented
//! `push_kind` values so the server never persists plaintext call state as notification metadata.

use crate::auth_service::{ApiError, AuthenticatedSession};
use crate::message_service::{
    MessageAccountRecord, MessageAckRequest, MessageAckResponse, MessageSendContext,
    MessageSendRequest, MessageSendResponse, MessageSendResult, MessageSender,
};
use crate::messages::{
    normalized_delivery, push_kind_for_job, resolve_delivery_routing, sender_server_from_handle,
    validate_ack_ids, validate_send_batch, DeliveryRoutingInput, DeliveryUnit, PushKind,
    WakeupClass,
};
use crate::realtime::RealtimeHub;
use serde::Serialize;
use sqlx::{PgPool, Row};
use std::convert::TryFrom;

const FIND_MESSAGE_ACCOUNT_SQL: &str = r"
SELECT id::TEXT AS id
FROM accounts
WHERE user_handle = $1
";

const LIST_ACTIVE_DEVICE_IDS_SQL: &str = r"
SELECT device_id
FROM devices
WHERE account_id = $1::uuid
  AND state = 'active'
ORDER BY created_at DESC
";

const DEVICE_FAST_NOTIFY_SQL: &str = r"
SELECT EXISTS (
  SELECT 1
  FROM device_push_tokens
  WHERE account_id = $1::uuid
    AND device_id = $2
    AND push_enabled = TRUE
    AND push_mode = 'fast_notify'
) AS allowed
";

const INSERT_LOCAL_DELIVERY_SQL: &str = r"
INSERT INTO mailbox_blobs (
  owner_account_id,
  owner_device_id,
  sender_server,
  message_id,
  delivery_id,
  ciphertext_blob,
  envelope,
  ttl_sec,
  expires_at
)
VALUES ($1::uuid, $2, $3, $4::uuid, $5::uuid, $6, $7::jsonb, $8, to_timestamp($9::double precision / 1000.0))
ON CONFLICT (owner_account_id, owner_device_id, delivery_id) DO NOTHING
";

const INSERT_PUSH_JOB_SQL: &str = r"
INSERT INTO push_jobs (
  owner_account_id,
  owner_device_id,
  from_device_id,
  push_kind,
  wakeup_class,
  message_id,
  delivery_id,
  dedupe_key
)
VALUES ($1::uuid, $2, $3, $4, $5, $6::uuid, $7::uuid, $8)
ON CONFLICT (owner_account_id, owner_device_id, delivery_id) DO NOTHING
";

const INSERT_OUTBOX_JOB_SQL: &str = r"
INSERT INTO outbox_jobs (to_server, payload)
VALUES ($1, $2::jsonb)
";

const ACK_MESSAGES_SQL: &str = r"
UPDATE mailbox_blobs
SET acked_at = CURRENT_TIMESTAMP
WHERE owner_account_id = $1::uuid
  AND owner_device_id = $2
  AND message_id::TEXT = ANY($3)
  AND acked_at IS NULL
";

const LOCAL_RELAY_ENVELOPE_JSON: &str = r#"{"relay_type":"local"}"#;

/// Async `PostgreSQL` repository for message route boundaries.
#[derive(Debug, Clone)]
pub struct PostgresMessageRepository {
    pool: PgPool,
    realtime: Option<RealtimeHub>,
}

impl PostgresMessageRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            realtime: None,
        }
    }

    #[must_use]
    pub const fn with_realtime(pool: PgPool, realtime: RealtimeHub) -> Self {
        Self {
            pool,
            realtime: Some(realtime),
        }
    }

    /// Routes encrypted message deliveries to local mailboxes or federation outbox jobs.
    ///
    /// # Errors
    ///
    /// Returns `ApiError` when validation, routing lookup, or durable storage fails.
    pub async fn send(
        &self,
        auth: &AuthenticatedSession,
        context: &MessageSendContext,
        request: &MessageSendRequest,
        now_ms: u64,
    ) -> Result<MessageSendResponse, ApiError> {
        validate_send_batch(&request.deliveries)
            .map_err(|_| ApiError::bad_request("Invalid message delivery payload"))?;
        let sender = MessageSender {
            account_id: auth.account_id.clone(),
            user_handle: auth.user_handle.clone(),
            device_id: auth.device_id.clone(),
        };
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
            let local_account = self.find_account_by_handle(&delivery.to_user).await?;

            if routing.is_local || local_account.is_some() {
                let status = self
                    .route_local_delivery(&sender, local_account.as_ref(), &routed_delivery, now_ms)
                    .await?;
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
            self.create_outbox_job(&sender.device_id, &batch.to_server, &batch.deliveries)
                .await?;
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
    /// Returns `ApiError` when validation or durable storage update fails.
    pub async fn ack(
        &self,
        auth: &AuthenticatedSession,
        request: &MessageAckRequest,
    ) -> Result<MessageAckResponse, ApiError> {
        validate_ack_ids(&request.msg_ids)
            .map_err(|_| ApiError::bad_request("Invalid message ack payload"))?;
        if request.msg_ids.is_empty() {
            return Ok(MessageAckResponse { acked: 0 });
        }
        let result = sqlx::query(ACK_MESSAGES_SQL)
            .bind(&auth.account_id)
            .bind(&auth.device_id)
            .bind(&request.msg_ids)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        let acked = usize::try_from(result.rows_affected()).map_err(|_| ApiError::internal())?;

        Ok(MessageAckResponse { acked })
    }

    async fn find_account_by_handle(
        &self,
        user_handle: &str,
    ) -> Result<Option<MessageAccountRecord>, ApiError> {
        sqlx::query(FIND_MESSAGE_ACCOUNT_SQL)
            .bind(user_handle)
            .fetch_optional(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?
            .map(|row| {
                Ok(MessageAccountRecord::new(
                    row.try_get("id").map_err(|_| ApiError::internal())?,
                ))
            })
            .transpose()
    }

    async fn list_active_device_ids(&self, account_id: &str) -> Result<Vec<String>, ApiError> {
        let rows = sqlx::query(LIST_ACTIVE_DEVICE_IDS_SQL)
            .bind(account_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;
        rows.iter()
            .map(|row| row.try_get("device_id").map_err(|_| ApiError::internal()))
            .collect()
    }

    async fn device_allows_fast_notify(
        &self,
        account_id: &str,
        device_id: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar::<_, bool>(DEVICE_FAST_NOTIFY_SQL)
            .bind(account_id)
            .bind(device_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|_| ApiError::internal())
    }

    async fn route_local_delivery(
        &self,
        sender: &MessageSender,
        local_account: Option<&MessageAccountRecord>,
        delivery: &DeliveryUnit,
        now_ms: u64,
    ) -> Result<&'static str, ApiError> {
        let Some(account) = local_account else {
            return Ok("unavailable");
        };
        let devices = self.list_active_device_ids(account.id()).await?;
        let target_devices = target_device_ids(&devices, &delivery.to_device_id);
        if target_devices.is_empty() {
            return Ok("unavailable");
        }

        for device_id in &target_devices {
            let inserted = self
                .insert_local_delivery(account.id(), device_id, sender, delivery, now_ms)
                .await?;
            if inserted {
                let push_created = self
                    .create_push_job(account.id(), device_id, sender, delivery)
                    .await?;
                if push_created {
                    self.notify_sync_blob_available(
                        account.id(),
                        &delivery.message_id,
                        &delivery.delivery_id,
                        device_id,
                    );
                }
            }
        }

        Ok("queued_local")
    }

    async fn insert_local_delivery(
        &self,
        owner_account_id: &str,
        owner_device_id: &str,
        sender: &MessageSender,
        delivery: &DeliveryUnit,
        now_ms: u64,
    ) -> Result<bool, ApiError> {
        let expires_at_ms = now_ms.saturating_add(delivery.ttl_sec.saturating_mul(1_000));
        let result = sqlx::query(INSERT_LOCAL_DELIVERY_SQL)
            .bind(owner_account_id)
            .bind(owner_device_id)
            .bind(sender_server_from_handle(&sender.user_handle))
            .bind(&delivery.message_id)
            .bind(&delivery.delivery_id)
            .bind(&delivery.ciphertext_blob)
            .bind(LOCAL_RELAY_ENVELOPE_JSON)
            .bind(i64::try_from(delivery.ttl_sec).map_err(|_| ApiError::internal())?)
            .bind(i64::try_from(expires_at_ms).map_err(|_| ApiError::internal())?)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(result.rows_affected() > 0)
    }

    async fn create_push_job(
        &self,
        owner_account_id: &str,
        owner_device_id: &str,
        sender: &MessageSender,
        delivery: &DeliveryUnit,
    ) -> Result<bool, ApiError> {
        let allowed_fast_notify = self
            .device_allows_fast_notify(owner_account_id, owner_device_id)
            .await?;
        let push_kind = push_kind_wire(push_kind_for_job(allowed_fast_notify, delivery.push_kind));
        let wakeup_class = wakeup_class_wire(delivery.wakeup_class.unwrap_or(WakeupClass::Generic));
        let result = sqlx::query(INSERT_PUSH_JOB_SQL)
            .bind(owner_account_id)
            .bind(owner_device_id)
            .bind(&sender.device_id)
            .bind(push_kind)
            .bind(wakeup_class)
            .bind(&delivery.message_id)
            .bind(&delivery.delivery_id)
            .bind(&delivery.delivery_id)
            .execute(&self.pool)
            .await
            .map_err(|_| ApiError::internal())?;

        Ok(result.rows_affected() > 0)
    }

    fn notify_sync_blob_available(
        &self,
        account_id: &str,
        message_id: &str,
        delivery_id: &str,
        device_id: &str,
    ) {
        if let Some(realtime) = self.realtime.as_ref() {
            realtime.notify_sync_blob_available(account_id, message_id, delivery_id, device_id);
        }
    }

    async fn create_outbox_job(
        &self,
        from_device_id: &str,
        to_server: &str,
        deliveries: &[DeliveryUnit],
    ) -> Result<(), ApiError> {
        let payload = serde_json::to_string(&OutboxPayload {
            from_device: from_device_id,
            deliveries,
        })
        .map_err(|_| ApiError::internal())?;
        sqlx::query(INSERT_OUTBOX_JOB_SQL)
            .bind(to_server)
            .bind(payload)
            .execute(&self.pool)
            .await
            .map(|_result| ())
            .map_err(|_| ApiError::internal())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteBatch {
    to_server: String,
    deliveries: Vec<DeliveryUnit>,
}

#[derive(Debug, Clone, Copy, Serialize)]
struct OutboxPayload<'a> {
    from_device: &'a str,
    deliveries: &'a [DeliveryUnit],
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

const fn push_kind_wire(push_kind: Option<PushKind>) -> Option<&'static str> {
    match push_kind {
        Some(kind) => Some(kind.as_wire()),
        None => None,
    }
}

const fn wakeup_class_wire(wakeup_class: WakeupClass) -> &'static str {
    match wakeup_class {
        WakeupClass::Generic => "generic",
        WakeupClass::VoipOpaque => "voip_opaque",
    }
}

#[must_use]
pub const fn message_repository_query_contract() -> &'static [&'static str] {
    &[
        FIND_MESSAGE_ACCOUNT_SQL,
        LIST_ACTIVE_DEVICE_IDS_SQL,
        DEVICE_FAST_NOTIFY_SQL,
        INSERT_LOCAL_DELIVERY_SQL,
        INSERT_PUSH_JOB_SQL,
        INSERT_OUTBOX_JOB_SQL,
        ACK_MESSAGES_SQL,
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        message_repository_query_contract, push_kind_wire, wakeup_class_wire, ACK_MESSAGES_SQL,
        DEVICE_FAST_NOTIFY_SQL, INSERT_LOCAL_DELIVERY_SQL, INSERT_OUTBOX_JOB_SQL,
        INSERT_PUSH_JOB_SQL,
    };
    use crate::messages::{PushKind, WakeupClass};

    #[test]
    fn message_queries_are_parameterized_and_ciphertext_only() {
        for query in message_repository_query_contract() {
            assert!(!query.contains("{}"));
            assert!(!query.contains("format!("));
        }

        assert!(INSERT_LOCAL_DELIVERY_SQL.contains("ciphertext_blob"));
        assert!(INSERT_LOCAL_DELIVERY_SQL.contains("ON CONFLICT"));
        assert!(INSERT_PUSH_JOB_SQL.contains("push_kind"));
        assert!(INSERT_PUSH_JOB_SQL.contains("wakeup_class"));
        assert!(INSERT_PUSH_JOB_SQL.contains("ON CONFLICT"));
        assert!(INSERT_OUTBOX_JOB_SQL.contains("payload"));
        assert!(ACK_MESSAGES_SQL.contains("message_id::TEXT = ANY($3)"));
        assert!(DEVICE_FAST_NOTIFY_SQL.contains("push_mode = 'fast_notify'"));
    }

    #[test]
    fn push_kind_wire_keeps_call_metadata_suppressed_by_caller_policy() {
        assert_eq!(push_kind_wire(None), None);
        assert_eq!(push_kind_wire(Some(PushKind::Message)), Some("message"));
        assert_eq!(push_kind_wire(Some(PushKind::Other)), Some("other"));
        assert_eq!(wakeup_class_wire(WakeupClass::Generic), "generic");
        assert_eq!(wakeup_class_wire(WakeupClass::VoipOpaque), "voip_opaque");
    }
}
