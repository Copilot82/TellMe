//! Service-level background worker contracts.
//!
//! Worker jobs stay behind storage and provider traits so retry, APNs fallback, and media cleanup behavior can be
//! verified without coupling the Rust port to a specific database or push-provider client.

use crate::auth_service::StoreError;
use crate::devices::{PushMode, PushTokenKind};
use crate::messages::{DeliveryUnit, PushKind, WakeupClass};
use crate::workers::{
    is_hard_apns_failure, is_likely_wrong_push_environment, missing_push_tokens_decision,
    opposite_push_environment, outbox_decision, push_completion_decision, push_send_request,
    push_token_accepts_wakeup, retry_delay_sec, should_delete_media_metadata,
    should_remove_ciphertext_for_cleanup, should_skip_sender_device, JobDecision, PushEnvironment,
};
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::future::Future;
use std::pin::Pin;

/// Worker storage/provider failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerError;

impl Display for WorkerError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("worker boundary error")
    }
}

impl Error for WorkerError {}

impl From<StoreError> for WorkerError {
    fn from(_value: StoreError) -> Self {
        Self
    }
}

/// Reserved outbox job record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxJobRecord {
    pub id: String,
    pub claim_token: String,
    pub to_server: String,
    pub attempts: u32,
    pub deliveries: Vec<DeliveryUnit>,
}

/// Reserved push job record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushJobRecord {
    pub id: String,
    pub claim_token: String,
    pub owner_account_id: String,
    pub owner_device_id: String,
    pub from_device_id: Option<String>,
    pub message_id: String,
    pub delivery_id: Option<String>,
    pub push_kind: Option<PushKind>,
    pub wakeup_class: WakeupClass,
    pub attempts: u32,
}

/// Enabled push token row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushTokenRecord {
    pub token: String,
    pub push_environment: PushEnvironment,
    pub push_mode: PushMode,
    pub token_kind: PushTokenKind,
}

/// Outbox delivery transport result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxDeliveryResult {
    pub ok: bool,
    pub status: i32,
    pub body: String,
}

/// Push provider send request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderPushRequest {
    pub token: String,
    pub push_environment: PushEnvironment,
    pub message_id: String,
    pub device_id: String,
    pub push_mode: PushMode,
    pub push_kind: Option<PushKind>,
    pub wakeup_class: WakeupClass,
}

/// Push provider send result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderPushResult {
    pub ok: bool,
    pub hard_failure_reason: Option<String>,
    pub transient_failure_reason: Option<String>,
}

/// Expired media cleanup candidate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpiredMediaObject {
    pub id: String,
    pub status: String,
    pub storage_bucket: Option<String>,
    pub storage_key: Option<String>,
}

/// Outbox worker storage boundary.
// Workers claim small batches so retries can be idempotent across process restarts.
pub trait OutboxWorkerStore {
    /// Marks a claimed outbox job sent.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    fn mark_outbox_sent(&mut self, job_id: &str, claim_token: &str) -> Result<(), WorkerError>;

    /// Marks a claimed outbox job failed with retry state.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    fn mark_outbox_failed(
        &mut self,
        job_id: &str,
        claim_token: &str,
        attempts: u32,
        retry_delay_sec: u64,
        error: &str,
    ) -> Result<(), WorkerError>;
}

/// Outbox federation transport boundary.
pub trait OutboxTransport {
    /// Sends encrypted delivery units to a remote home server.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when the transport boundary fails before an HTTP-like result exists.
    fn deliver(
        &mut self,
        to_server: &str,
        deliveries: &[DeliveryUnit],
    ) -> Result<OutboxDeliveryResult, WorkerError>;
}

/// Push worker storage boundary.
pub trait PushWorkerStore {
    /// Checks whether the mailbox delivery is still pending.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    fn has_pending_delivery(
        &mut self,
        account_id: &str,
        device_id: &str,
        delivery_id: &str,
    ) -> Result<bool, WorkerError>;

    /// Lists enabled push tokens for a target device.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    fn list_enabled_push_tokens(
        &mut self,
        account_id: &str,
        device_id: &str,
    ) -> Result<Vec<PushTokenRecord>, WorkerError>;

    /// Updates a push token's discovered APNs environment.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the token.
    fn update_push_environment(
        &mut self,
        account_id: &str,
        token: &str,
        environment: PushEnvironment,
    ) -> Result<(), WorkerError>;

    /// Deletes an invalid push token.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot delete the token.
    fn delete_push_token(&mut self, account_id: &str, token: &str) -> Result<(), WorkerError>;

    /// Marks a claimed push job sent.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    fn mark_push_sent(
        &mut self,
        job_id: &str,
        claim_token: &str,
        outcome: Option<&'static str>,
    ) -> Result<(), WorkerError>;

    /// Marks a claimed push job failed with retry state.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot update the job.
    fn mark_push_failed(
        &mut self,
        job_id: &str,
        claim_token: &str,
        attempts: u32,
        retry_delay_sec: u64,
        error: &str,
    ) -> Result<(), WorkerError>;
}

/// Push provider boundary.
pub trait PushProvider {
    /// Sends one privacy-safe APNs wake.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when the provider cannot be called.
    fn send(&mut self, request: ProviderPushRequest) -> Result<ProviderPushResult, WorkerError>;
}

/// Async push provider future.
pub type PushProviderFuture<'a> =
    Pin<Box<dyn Future<Output = Result<ProviderPushResult, WorkerError>> + Send + 'a>>;

/// Async push provider boundary for runtime implementations that perform network I/O.
pub trait AsyncPushProvider {
    /// Sends one privacy-safe APNs wake.
    fn send_async(&mut self, request: ProviderPushRequest) -> PushProviderFuture<'_>;
}

impl<T> AsyncPushProvider for T
where
    T: PushProvider + Send,
{
    fn send_async(&mut self, request: ProviderPushRequest) -> PushProviderFuture<'_> {
        Box::pin(async move { self.send(request) })
    }
}

/// Media cleanup storage and object-store boundary.
pub trait MediaCleanupStore {
    /// Lists expired media objects that may be removed.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot be queried.
    fn list_expired_media(&mut self, limit: usize) -> Result<Vec<ExpiredMediaObject>, WorkerError>;

    /// Deletes one ciphertext object from durable object storage.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when object deletion fails.
    fn delete_ciphertext(&mut self, bucket: &str, key: &str) -> Result<(), WorkerError>;

    /// Deletes media metadata rows.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when durable storage cannot delete metadata.
    fn delete_media_metadata(&mut self, ids: &[String]) -> Result<usize, WorkerError>;
}

/// Worker service implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerService;

impl WorkerService {
    /// Processes one claimed federation outbox job.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when storage or transport side effects fail.
    pub fn process_outbox_job<S: OutboxWorkerStore, T: OutboxTransport>(
        store: &mut S,
        transport: &mut T,
        job: &OutboxJobRecord,
    ) -> Result<(), WorkerError> {
        if job.deliveries.is_empty() {
            return store.mark_outbox_sent(&job.id, &job.claim_token);
        }

        let result = transport.deliver(&job.to_server, &job.deliveries)?;
        match outbox_decision(job.deliveries.len(), result.ok, result.status, &result.body) {
            JobDecision::MarkSent { .. } => store.mark_outbox_sent(&job.id, &job.claim_token),
            JobDecision::MarkFailed { error } => store.mark_outbox_failed(
                &job.id,
                &job.claim_token,
                job.attempts,
                retry_delay_sec(job.attempts),
                &error,
            ),
        }
    }

    /// Processes one claimed APNs push job.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when storage or push-provider side effects fail.
    pub fn process_push_job<S: PushWorkerStore, P: PushProvider>(
        store: &mut S,
        provider: &mut P,
        job: &PushJobRecord,
    ) -> Result<(), WorkerError> {
        if should_skip_sender_device(job.from_device_id.as_deref(), &job.owner_device_id) {
            return store.mark_push_sent(&job.id, &job.claim_token, Some("skipped_sender_device"));
        }

        if let Some(delivery_id) = job.delivery_id.as_deref() {
            let pending = store.has_pending_delivery(
                &job.owner_account_id,
                &job.owner_device_id,
                delivery_id,
            )?;
            if !pending {
                return store.mark_push_sent(&job.id, &job.claim_token, Some("already_synced"));
            }
        }

        let token_rows =
            store.list_enabled_push_tokens(&job.owner_account_id, &job.owner_device_id)?;
        let matching_tokens = token_rows
            .into_iter()
            .filter(|token_row| push_token_accepts_wakeup(token_row.token_kind, job.wakeup_class))
            .collect::<Vec<_>>();
        if matching_tokens.is_empty() {
            return match missing_push_tokens_decision(job.wakeup_class) {
                JobDecision::MarkSent { outcome } => {
                    store.mark_push_sent(&job.id, &job.claim_token, outcome)
                }
                JobDecision::MarkFailed { error } => store.mark_push_failed(
                    &job.id,
                    &job.claim_token,
                    job.attempts,
                    retry_delay_sec(job.attempts),
                    &error,
                ),
            };
        }

        let mut delivered = false;
        let mut transient_error: Option<String> = None;
        for token_row in matching_tokens {
            let result = send_to_token(store, provider, job, &token_row)?;
            if result.delivered {
                delivered = true;
            }
            if transient_error.is_none() {
                transient_error = result.transient_error;
            }
        }

        match push_completion_decision(delivered, transient_error.as_deref()) {
            JobDecision::MarkSent { outcome } => {
                store.mark_push_sent(&job.id, &job.claim_token, outcome)
            }
            JobDecision::MarkFailed { error } => store.mark_push_failed(
                &job.id,
                &job.claim_token,
                job.attempts,
                retry_delay_sec(job.attempts),
                &error,
            ),
        }
    }

    /// Cleans up expired media metadata and ciphertext objects.
    ///
    /// # Errors
    ///
    /// Returns `WorkerError` when listing candidates or deleting metadata fails. Ciphertext delete failures keep the
    /// metadata row so the next cleanup pass can retry without losing object-storage state.
    pub fn cleanup_expired_media<S: MediaCleanupStore>(
        store: &mut S,
        limit: usize,
    ) -> Result<usize, WorkerError> {
        let candidates = store.list_expired_media(limit)?;
        let mut deleted_ids = Vec::new();
        for media in candidates {
            let ciphertext_required = should_remove_ciphertext_for_cleanup(
                &media.status,
                media.storage_bucket.as_deref(),
                media.storage_key.as_deref(),
            );
            let ciphertext_ok = if ciphertext_required {
                delete_media_ciphertext(store, &media)
            } else {
                true
            };

            if should_delete_media_metadata(ciphertext_required, ciphertext_ok) {
                deleted_ids.push(media.id);
            }
        }

        if deleted_ids.is_empty() {
            return Ok(0);
        }

        store.delete_media_metadata(&deleted_ids)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TokenSendOutcome {
    delivered: bool,
    transient_error: Option<String>,
}

fn send_to_token<S: PushWorkerStore, P: PushProvider>(
    store: &mut S,
    provider: &mut P,
    job: &PushJobRecord,
    token_row: &PushTokenRecord,
) -> Result<TokenSendOutcome, WorkerError> {
    let push_request = push_send_request(
        token_row.push_environment,
        token_row.push_mode,
        job.push_kind,
        job.wakeup_class,
    );
    let result = provider.send(ProviderPushRequest {
        token: token_row.token.clone(),
        push_environment: push_request.push_environment,
        message_id: job.message_id.clone(),
        device_id: job.owner_device_id.clone(),
        push_mode: push_request.push_mode,
        push_kind: push_request.push_kind,
        wakeup_class: push_request.wakeup_class,
    })?;
    if result.ok {
        return Ok(TokenSendOutcome {
            delivered: true,
            transient_error: None,
        });
    }

    if is_likely_wrong_push_environment(result.hard_failure_reason.as_deref()) {
        return retry_token_with_alternate_environment(store, provider, job, token_row);
    }

    if is_hard_apns_failure(result.hard_failure_reason.as_deref()) {
        store.delete_push_token(&job.owner_account_id, &token_row.token)?;
        return Ok(TokenSendOutcome {
            delivered: false,
            transient_error: None,
        });
    }

    Ok(TokenSendOutcome {
        delivered: false,
        transient_error: Some(push_error_message(&result)),
    })
}

fn retry_token_with_alternate_environment<S: PushWorkerStore, P: PushProvider>(
    store: &mut S,
    provider: &mut P,
    job: &PushJobRecord,
    token_row: &PushTokenRecord,
) -> Result<TokenSendOutcome, WorkerError> {
    let alternate = opposite_push_environment(token_row.push_environment);
    let push_request = push_send_request(
        alternate,
        token_row.push_mode,
        job.push_kind,
        job.wakeup_class,
    );
    let result = provider.send(ProviderPushRequest {
        token: token_row.token.clone(),
        push_environment: push_request.push_environment,
        message_id: job.message_id.clone(),
        device_id: job.owner_device_id.clone(),
        push_mode: push_request.push_mode,
        push_kind: push_request.push_kind,
        wakeup_class: push_request.wakeup_class,
    })?;

    if result.ok {
        store.update_push_environment(&job.owner_account_id, &token_row.token, alternate)?;
        return Ok(TokenSendOutcome {
            delivered: true,
            transient_error: None,
        });
    }

    if is_hard_apns_failure(result.hard_failure_reason.as_deref()) {
        store.delete_push_token(&job.owner_account_id, &token_row.token)?;
        return Ok(TokenSendOutcome {
            delivered: false,
            transient_error: None,
        });
    }

    Ok(TokenSendOutcome {
        delivered: false,
        transient_error: Some(push_error_message(&result)),
    })
}

fn push_error_message(result: &ProviderPushResult) -> String {
    result
        .transient_failure_reason
        .as_ref()
        .or(result.hard_failure_reason.as_ref())
        .cloned()
        .unwrap_or_else(|| "Unknown push delivery error".to_owned())
}

fn delete_media_ciphertext<S: MediaCleanupStore>(
    store: &mut S,
    media: &ExpiredMediaObject,
) -> bool {
    let (Some(bucket), Some(key)) = (
        media.storage_bucket.as_deref(),
        media.storage_key.as_deref(),
    ) else {
        return true;
    };
    store.delete_ciphertext(bucket, key).is_ok()
}

#[cfg(test)]
mod tests {
    use super::{
        ExpiredMediaObject, MediaCleanupStore, OutboxDeliveryResult, OutboxJobRecord,
        OutboxTransport, OutboxWorkerStore, ProviderPushRequest, ProviderPushResult, PushJobRecord,
        PushProvider, PushTokenRecord, PushWorkerStore, WorkerError, WorkerService,
    };
    use crate::devices::{PushMode, PushTokenKind};
    use crate::messages::{DeliveryUnit, PushKind, WakeupClass};
    use crate::workers::PushEnvironment;

    #[test]
    fn outbox_marks_empty_or_successful_jobs_sent_and_retries_failures() {
        let mut store = FakeOutboxStore::default();
        let mut transport = FakeOutboxTransport::default();
        let empty = outbox_job(Vec::new());

        let empty_result = WorkerService::process_outbox_job(&mut store, &mut transport, &empty);
        assert_eq!(empty_result, Ok(()));
        assert_eq!(
            store.sent_jobs.first().map(String::as_str),
            Some("outbox-1")
        );

        let mut failed_store = FakeOutboxStore::default();
        let mut failed_transport = FakeOutboxTransport {
            result: Some(OutboxDeliveryResult {
                ok: false,
                status: 503,
                body: "unavailable".to_owned(),
            }),
        };
        let failed_result = WorkerService::process_outbox_job(
            &mut failed_store,
            &mut failed_transport,
            &outbox_job(vec![delivery()]),
        );
        assert_eq!(failed_result, Ok(()));
        assert_eq!(
            failed_store.failed_jobs.first().map(FailedJob::error),
            Some("HTTP 503: unavailable")
        );
        assert_eq!(
            failed_store.failed_jobs.first().map(FailedJob::delay),
            Some(5)
        );
    }

    #[test]
    fn push_worker_skips_sender_device_and_already_synced_delivery() {
        let mut store = FakePushStore {
            pending_delivery: true,
            ..FakePushStore::default()
        };
        let mut provider = FakePushProvider::default();
        let mut sender_job = push_job();
        sender_job.from_device_id = Some("dev-a".to_owned());

        let result = WorkerService::process_push_job(&mut store, &mut provider, &sender_job);

        assert_eq!(result, Ok(()));
        assert_eq!(
            store.sent_jobs.first().map(SentJob::outcome),
            Some(Some("skipped_sender_device"))
        );

        let mut synced_store = FakePushStore::default();
        let synced_result =
            WorkerService::process_push_job(&mut synced_store, &mut provider, &push_job());
        assert_eq!(synced_result, Ok(()));
        assert_eq!(
            synced_store.sent_jobs.first().map(SentJob::outcome),
            Some(Some("already_synced"))
        );
    }

    #[test]
    fn push_worker_uses_alternate_environment_and_suppresses_call_kind() {
        let mut store = FakePushStore {
            pending_delivery: true,
            tokens: vec![PushTokenRecord {
                token: "push-token".to_owned(),
                push_environment: PushEnvironment::Sandbox,
                push_mode: PushMode::FastNotify,
                token_kind: PushTokenKind::Alert,
            }],
            ..FakePushStore::default()
        };
        let mut provider = FakePushProvider {
            results: vec![
                ProviderPushResult {
                    ok: false,
                    hard_failure_reason: Some("BadDeviceToken".to_owned()),
                    transient_failure_reason: None,
                },
                ProviderPushResult {
                    ok: true,
                    hard_failure_reason: None,
                    transient_failure_reason: None,
                },
            ],
            requests: Vec::new(),
        };
        let mut job = push_job();
        job.push_kind = Some(PushKind::Call);

        let result = WorkerService::process_push_job(&mut store, &mut provider, &job);

        assert_eq!(result, Ok(()));
        assert_eq!(
            store.updated_environments.first().map(|update| update.1),
            Some(PushEnvironment::Production)
        );
        assert_eq!(store.sent_jobs.first().map(SentJob::outcome), Some(None));
        assert_eq!(provider.requests.len(), 2);
        assert!(provider
            .requests
            .iter()
            .all(|request| request.push_kind.is_none()));
    }

    #[test]
    fn push_worker_retries_voip_jobs_when_voip_token_is_missing() {
        let mut store = FakePushStore {
            pending_delivery: true,
            tokens: vec![PushTokenRecord {
                token: "alert-token".to_owned(),
                push_environment: PushEnvironment::Production,
                push_mode: PushMode::PrivacyFirst,
                token_kind: PushTokenKind::Alert,
            }],
            ..FakePushStore::default()
        };
        let mut provider = FakePushProvider::default();
        let mut job = push_job();
        job.wakeup_class = WakeupClass::VoipOpaque;

        let result = WorkerService::process_push_job(&mut store, &mut provider, &job);

        assert_eq!(result, Ok(()));
        assert!(store.sent_jobs.is_empty());
        assert_eq!(
            store.failed_jobs.first().map(FailedJob::error),
            Some("missing_voip_token")
        );
        assert!(provider.requests.is_empty());
    }

    #[test]
    fn push_worker_retries_transient_provider_failure() {
        let mut store = FakePushStore {
            pending_delivery: true,
            tokens: vec![PushTokenRecord {
                token: "push-token".to_owned(),
                push_environment: PushEnvironment::Production,
                push_mode: PushMode::PrivacyFirst,
                token_kind: PushTokenKind::Alert,
            }],
            ..FakePushStore::default()
        };
        let mut provider = FakePushProvider {
            results: vec![ProviderPushResult {
                ok: false,
                hard_failure_reason: None,
                transient_failure_reason: Some("InternalServerError".to_owned()),
            }],
            requests: Vec::new(),
        };

        let result = WorkerService::process_push_job(&mut store, &mut provider, &push_job());

        assert_eq!(result, Ok(()));
        assert_eq!(
            store.failed_jobs.first().map(FailedJob::error),
            Some("InternalServerError")
        );
    }

    #[test]
    fn media_cleanup_keeps_metadata_when_ciphertext_delete_fails() {
        let mut store = FakeMediaStore {
            candidates: vec![
                ExpiredMediaObject {
                    id: "media-1".to_owned(),
                    status: "uploaded_verified".to_owned(),
                    storage_bucket: Some("bucket".to_owned()),
                    storage_key: Some("key-1".to_owned()),
                },
                ExpiredMediaObject {
                    id: "media-2".to_owned(),
                    status: "rejected".to_owned(),
                    storage_bucket: None,
                    storage_key: None,
                },
            ],
            fail_ciphertext_delete: true,
            ..FakeMediaStore::default()
        };

        let deleted = WorkerService::cleanup_expired_media(&mut store, 100);

        assert_eq!(deleted, Ok(1));
        assert_eq!(
            store.deleted_metadata.first().map(String::as_str),
            Some("media-2")
        );
    }

    fn outbox_job(deliveries: Vec<DeliveryUnit>) -> OutboxJobRecord {
        OutboxJobRecord {
            id: "outbox-1".to_owned(),
            claim_token: "claim-1".to_owned(),
            to_server: "remote.example".to_owned(),
            attempts: 0,
            deliveries,
        }
    }

    fn push_job() -> PushJobRecord {
        PushJobRecord {
            id: "push-1".to_owned(),
            claim_token: "claim-1".to_owned(),
            owner_account_id: "acc-1".to_owned(),
            owner_device_id: "dev-a".to_owned(),
            from_device_id: None,
            message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            delivery_id: Some("11111111-1111-4111-8111-111111111111".to_owned()),
            push_kind: Some(PushKind::Message),
            wakeup_class: WakeupClass::Generic,
            attempts: 0,
        }
    }

    fn delivery() -> DeliveryUnit {
        DeliveryUnit {
            wire_version: 2,
            delivery_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            to_server: "remote.example".to_owned(),
            to_user: "@bob:remote.example".to_owned(),
            to_device_id: "dev-b".to_owned(),
            message_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            timestamp: "2026-03-01T00:00:00.000Z".to_owned(),
            ttl_sec: 600,
            ciphertext_blob: "ciphertext".to_owned(),
            push_kind: None,
            wakeup_class: None,
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeOutboxStore {
        sent_jobs: Vec<String>,
        failed_jobs: Vec<FailedJob>,
    }

    impl OutboxWorkerStore for FakeOutboxStore {
        fn mark_outbox_sent(
            &mut self,
            job_id: &str,
            _claim_token: &str,
        ) -> Result<(), WorkerError> {
            self.sent_jobs.push(job_id.to_owned());
            Ok(())
        }

        fn mark_outbox_failed(
            &mut self,
            job_id: &str,
            _claim_token: &str,
            _attempts: u32,
            retry_delay_sec: u64,
            error: &str,
        ) -> Result<(), WorkerError> {
            self.failed_jobs.push(FailedJob {
                job_id: job_id.to_owned(),
                delay: retry_delay_sec,
                error: error.to_owned(),
            });
            Ok(())
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeOutboxTransport {
        result: Option<OutboxDeliveryResult>,
    }

    impl OutboxTransport for FakeOutboxTransport {
        fn deliver(
            &mut self,
            _to_server: &str,
            _deliveries: &[DeliveryUnit],
        ) -> Result<OutboxDeliveryResult, WorkerError> {
            Ok(self.result.clone().unwrap_or_else(|| OutboxDeliveryResult {
                ok: true,
                status: 200,
                body: "ok".to_owned(),
            }))
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakePushStore {
        pending_delivery: bool,
        tokens: Vec<PushTokenRecord>,
        sent_jobs: Vec<SentJob>,
        failed_jobs: Vec<FailedJob>,
        updated_environments: Vec<(String, PushEnvironment)>,
        deleted_tokens: Vec<String>,
    }

    impl PushWorkerStore for FakePushStore {
        fn has_pending_delivery(
            &mut self,
            _account_id: &str,
            _device_id: &str,
            _delivery_id: &str,
        ) -> Result<bool, WorkerError> {
            Ok(self.pending_delivery)
        }

        fn list_enabled_push_tokens(
            &mut self,
            _account_id: &str,
            _device_id: &str,
        ) -> Result<Vec<PushTokenRecord>, WorkerError> {
            Ok(self.tokens.clone())
        }

        fn update_push_environment(
            &mut self,
            _account_id: &str,
            token: &str,
            environment: PushEnvironment,
        ) -> Result<(), WorkerError> {
            self.updated_environments
                .push((token.to_owned(), environment));
            Ok(())
        }

        fn delete_push_token(&mut self, _account_id: &str, token: &str) -> Result<(), WorkerError> {
            self.deleted_tokens.push(token.to_owned());
            Ok(())
        }

        fn mark_push_sent(
            &mut self,
            job_id: &str,
            _claim_token: &str,
            outcome: Option<&'static str>,
        ) -> Result<(), WorkerError> {
            self.sent_jobs.push(SentJob {
                job_id: job_id.to_owned(),
                outcome,
            });
            Ok(())
        }

        fn mark_push_failed(
            &mut self,
            job_id: &str,
            _claim_token: &str,
            _attempts: u32,
            retry_delay_sec: u64,
            error: &str,
        ) -> Result<(), WorkerError> {
            self.failed_jobs.push(FailedJob {
                job_id: job_id.to_owned(),
                delay: retry_delay_sec,
                error: error.to_owned(),
            });
            Ok(())
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakePushProvider {
        results: Vec<ProviderPushResult>,
        requests: Vec<ProviderPushRequest>,
    }

    impl PushProvider for FakePushProvider {
        fn send(
            &mut self,
            request: ProviderPushRequest,
        ) -> Result<ProviderPushResult, WorkerError> {
            self.requests.push(request);
            if self.results.is_empty() {
                return Ok(ProviderPushResult {
                    ok: true,
                    hard_failure_reason: None,
                    transient_failure_reason: None,
                });
            }
            Ok(self.results.remove(0))
        }
    }

    #[derive(Debug, Clone, Default)]
    struct FakeMediaStore {
        candidates: Vec<ExpiredMediaObject>,
        fail_ciphertext_delete: bool,
        deleted_metadata: Vec<String>,
    }

    impl MediaCleanupStore for FakeMediaStore {
        fn list_expired_media(
            &mut self,
            _limit: usize,
        ) -> Result<Vec<ExpiredMediaObject>, WorkerError> {
            Ok(self.candidates.clone())
        }

        fn delete_ciphertext(&mut self, _bucket: &str, _key: &str) -> Result<(), WorkerError> {
            if self.fail_ciphertext_delete {
                return Err(WorkerError);
            }
            Ok(())
        }

        fn delete_media_metadata(&mut self, ids: &[String]) -> Result<usize, WorkerError> {
            self.deleted_metadata.extend(ids.iter().cloned());
            Ok(ids.len())
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct SentJob {
        job_id: String,
        outcome: Option<&'static str>,
    }

    impl SentJob {
        const fn outcome(&self) -> Option<&'static str> {
            self.outcome
        }
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct FailedJob {
        job_id: String,
        delay: u64,
        error: String,
    }

    impl FailedJob {
        fn error(&self) -> &str {
            &self.error
        }

        const fn delay(&self) -> u64 {
            self.delay
        }
    }
}
