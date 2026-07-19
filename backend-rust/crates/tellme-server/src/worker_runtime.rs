//! One-shot async runtime runners for durable background jobs.
//!
//! The long-lived scheduler is intentionally separate from these functions. Keeping this layer one-shot makes rollout
//! and tests explicit while the Rust backend is still being ported domain by domain.

use crate::federation_transport::FederationHttpTransport;
use crate::media_storage::MinioMediaObjectStore;
use crate::worker_repository::PostgresWorkerRepository;
use crate::worker_service::{
    AsyncPushProvider, ExpiredMediaObject, OutboxJobRecord, ProviderPushRequest,
    ProviderPushResult, PushJobRecord, PushTokenRecord, WorkerError,
};
use crate::workers::{
    is_hard_apns_failure, is_likely_wrong_push_environment, missing_push_tokens_decision,
    opposite_push_environment, outbox_decision, push_completion_decision, push_send_request,
    push_token_accepts_wakeup, retry_delay_sec, should_delete_media_metadata,
    should_remove_ciphertext_for_cleanup, should_skip_sender_device, JobDecision,
};
use getrandom::getrandom;

const DEFAULT_JOB_LIMIT: i64 = 50;
const DEFAULT_CLAIM_TTL_SEC: i64 = 300;

/// Processes one claimed batch of federation outbox jobs.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage or outgoing transport side effects fail.
pub async fn run_federation_outbox_once(
    repository: &PostgresWorkerRepository,
    transport: &FederationHttpTransport,
) -> Result<usize, WorkerError> {
    run_federation_outbox_once_with_limits(
        repository,
        transport,
        DEFAULT_JOB_LIMIT,
        DEFAULT_CLAIM_TTL_SEC,
    )
    .await
}

/// Processes one claimed batch of federation outbox jobs with explicit worker limits.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage or outgoing transport side effects fail.
pub async fn run_federation_outbox_once_with_limits(
    repository: &PostgresWorkerRepository,
    transport: &FederationHttpTransport,
    limit: i64,
    claim_ttl_sec: i64,
) -> Result<usize, WorkerError> {
    if limit <= 0 || claim_ttl_sec <= 0 {
        return Err(WorkerError);
    }

    let claim_token = worker_claim_token()?;
    let jobs = repository
        .reserve_outbox_jobs(limit, &claim_token, claim_ttl_sec)
        .await?;
    let count = jobs.len();
    for job in &jobs {
        process_outbox_job(repository, transport, job).await?;
    }

    Ok(count)
}

/// Processes one claimed batch of APNs push jobs.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage or the provider boundary fails.
pub async fn run_push_once_with_provider<P: AsyncPushProvider>(
    repository: &PostgresWorkerRepository,
    provider: &mut P,
) -> Result<usize, WorkerError> {
    run_push_once_with_provider_and_limits(
        repository,
        provider,
        DEFAULT_JOB_LIMIT,
        DEFAULT_CLAIM_TTL_SEC,
    )
    .await
}

/// Processes one claimed batch of APNs push jobs with explicit worker limits.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage or the provider boundary fails.
pub async fn run_push_once_with_provider_and_limits<P: AsyncPushProvider>(
    repository: &PostgresWorkerRepository,
    provider: &mut P,
    limit: i64,
    claim_ttl_sec: i64,
) -> Result<usize, WorkerError> {
    if limit <= 0 || claim_ttl_sec <= 0 {
        return Err(WorkerError);
    }

    let claim_token = worker_claim_token()?;
    let jobs = repository
        .reserve_push_jobs(limit, &claim_token, claim_ttl_sec)
        .await?;
    let count = jobs.len();
    for job in &jobs {
        process_push_job(repository, provider, job).await?;
    }

    Ok(count)
}

/// Cleans one batch of expired media ciphertext and metadata.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage fails. Object-store delete failures leave metadata rows for retry.
pub async fn run_media_cleanup_once(
    repository: &PostgresWorkerRepository,
    object_store: &MinioMediaObjectStore,
) -> Result<usize, WorkerError> {
    run_media_cleanup_once_with_limit(repository, object_store, DEFAULT_JOB_LIMIT).await
}

/// Cleans one batch of expired media ciphertext and metadata with an explicit limit.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage fails. Object-store delete failures leave metadata rows for retry.
pub async fn run_media_cleanup_once_with_limit(
    repository: &PostgresWorkerRepository,
    object_store: &MinioMediaObjectStore,
    limit: i64,
) -> Result<usize, WorkerError> {
    if limit <= 0 {
        return Err(WorkerError);
    }

    let candidates = repository.list_expired_media(limit).await?;
    let mut delete_ids = Vec::new();
    for media in &candidates {
        let ciphertext_required = should_remove_ciphertext_for_cleanup(
            &media.status,
            media.storage_bucket.as_deref(),
            media.storage_key.as_deref(),
        );
        let ciphertext_ok = if ciphertext_required {
            remove_media_ciphertext(object_store, media).await
        } else {
            true
        };

        if should_delete_media_metadata(ciphertext_required, ciphertext_ok) {
            delete_ids.push(media.id.clone());
        }
    }

    repository.delete_media_metadata(&delete_ids).await
}

/// Cleans expired or acknowledged mailbox blobs once.
///
/// # Errors
///
/// Returns `WorkerError` when durable storage fails.
pub async fn run_mailbox_cleanup_once(
    repository: &PostgresWorkerRepository,
) -> Result<usize, WorkerError> {
    repository.cleanup_expired_mailbox().await
}

async fn process_outbox_job(
    repository: &PostgresWorkerRepository,
    transport: &FederationHttpTransport,
    job: &OutboxJobRecord,
) -> Result<(), WorkerError> {
    if job.deliveries.is_empty() {
        return repository.mark_outbox_sent(&job.id, &job.claim_token).await;
    }

    let result = transport.deliver(&job.to_server, &job.deliveries).await?;
    match outbox_decision(job.deliveries.len(), result.ok, result.status, &result.body) {
        JobDecision::MarkSent { .. } => {
            repository.mark_outbox_sent(&job.id, &job.claim_token).await
        }
        JobDecision::MarkFailed { error } => {
            repository
                .mark_outbox_failed(
                    &job.id,
                    &job.claim_token,
                    retry_delay_sec(job.attempts),
                    &error,
                )
                .await
        }
    }
}

async fn process_push_job<P: AsyncPushProvider>(
    repository: &PostgresWorkerRepository,
    provider: &mut P,
    job: &PushJobRecord,
) -> Result<(), WorkerError> {
    if should_skip_sender_device(job.from_device_id.as_deref(), &job.owner_device_id) {
        return repository
            .mark_push_sent(&job.id, &job.claim_token, Some("skipped_sender_device"))
            .await;
    }

    if let Some(delivery_id) = job.delivery_id.as_deref() {
        let pending = repository
            .has_pending_delivery(&job.owner_account_id, &job.owner_device_id, delivery_id)
            .await?;
        if !pending {
            return repository
                .mark_push_sent(&job.id, &job.claim_token, Some("already_synced"))
                .await;
        }
    }

    let token_rows = repository
        .list_enabled_push_tokens(&job.owner_account_id, &job.owner_device_id)
        .await?;
    let matching_tokens = token_rows
        .into_iter()
        .filter(|token_row| push_token_accepts_wakeup(token_row.token_kind, job.wakeup_class))
        .collect::<Vec<_>>();
    if matching_tokens.is_empty() {
        return match missing_push_tokens_decision(job.wakeup_class) {
            JobDecision::MarkSent { outcome } => {
                repository
                    .mark_push_sent(&job.id, &job.claim_token, outcome)
                    .await
            }
            JobDecision::MarkFailed { error } => {
                repository
                    .mark_push_failed(
                        &job.id,
                        &job.claim_token,
                        retry_delay_sec(job.attempts),
                        &error,
                    )
                    .await
            }
        };
    }

    let mut delivered = false;
    let mut transient_error: Option<String> = None;
    for token_row in &matching_tokens {
        let result = send_to_token(repository, provider, job, token_row).await?;
        if result.delivered {
            delivered = true;
        }
        if transient_error.is_none() {
            transient_error = result.transient_error;
        }
    }

    match push_completion_decision(delivered, transient_error.as_deref()) {
        JobDecision::MarkSent { outcome } => {
            repository
                .mark_push_sent(&job.id, &job.claim_token, outcome)
                .await
        }
        JobDecision::MarkFailed { error } => {
            repository
                .mark_push_failed(
                    &job.id,
                    &job.claim_token,
                    retry_delay_sec(job.attempts),
                    &error,
                )
                .await
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TokenSendOutcome {
    delivered: bool,
    transient_error: Option<String>,
}

async fn send_to_token<P: AsyncPushProvider>(
    repository: &PostgresWorkerRepository,
    provider: &mut P,
    job: &PushJobRecord,
    token_row: &PushTokenRecord,
) -> Result<TokenSendOutcome, WorkerError> {
    let result =
        send_provider_request(provider, job, token_row, token_row.push_environment).await?;
    if result.ok {
        return Ok(TokenSendOutcome {
            delivered: true,
            transient_error: None,
        });
    }

    if is_likely_wrong_push_environment(result.hard_failure_reason.as_deref()) {
        return retry_token_with_alternate_environment(repository, provider, job, token_row).await;
    }

    if is_hard_apns_failure(result.hard_failure_reason.as_deref()) {
        repository
            .delete_push_token(&job.owner_account_id, &token_row.token)
            .await?;
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

async fn retry_token_with_alternate_environment<P: AsyncPushProvider>(
    repository: &PostgresWorkerRepository,
    provider: &mut P,
    job: &PushJobRecord,
    token_row: &PushTokenRecord,
) -> Result<TokenSendOutcome, WorkerError> {
    let alternate = opposite_push_environment(token_row.push_environment);
    let result = send_provider_request(provider, job, token_row, alternate).await?;
    if result.ok {
        repository
            .update_push_environment(&job.owner_account_id, &token_row.token, alternate)
            .await?;
        return Ok(TokenSendOutcome {
            delivered: true,
            transient_error: None,
        });
    }

    if is_hard_apns_failure(result.hard_failure_reason.as_deref()) {
        repository
            .delete_push_token(&job.owner_account_id, &token_row.token)
            .await?;
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

async fn send_provider_request<P: AsyncPushProvider>(
    provider: &mut P,
    job: &PushJobRecord,
    token_row: &PushTokenRecord,
    environment: crate::workers::PushEnvironment,
) -> Result<ProviderPushResult, WorkerError> {
    let push_request = push_send_request(
        environment,
        token_row.push_mode,
        job.push_kind,
        job.wakeup_class,
    );

    provider
        .send_async(ProviderPushRequest {
            token: token_row.token.clone(),
            push_environment: push_request.push_environment,
            message_id: job.message_id.clone(),
            device_id: job.owner_device_id.clone(),
            push_mode: push_request.push_mode,
            push_kind: push_request.push_kind,
            wakeup_class: push_request.wakeup_class,
        })
        .await
}

fn push_error_message(result: &ProviderPushResult) -> String {
    result
        .transient_failure_reason
        .as_ref()
        .or(result.hard_failure_reason.as_ref())
        .cloned()
        .unwrap_or_else(|| "Unknown push delivery error".to_owned())
}

async fn remove_media_ciphertext(
    object_store: &MinioMediaObjectStore,
    media: &ExpiredMediaObject,
) -> bool {
    let (Some(bucket), Some(key)) = (
        media.storage_bucket.as_deref(),
        media.storage_key.as_deref(),
    ) else {
        return true;
    };

    object_store.remove_ciphertext(bucket, key).await.is_ok()
}

fn worker_claim_token() -> Result<String, WorkerError> {
    let mut bytes = [0_u8; 16];
    getrandom(&mut bytes).map_err(|_| WorkerError)?;
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
    output.push(hex_digit(byte >> 4));
    output.push(hex_digit(byte & 0x0f));
}

fn hex_digit(nibble: u8) -> char {
    match nibble {
        0..=9 => char::from(b'0' + nibble),
        _ => char::from(b'a' + (nibble - 10)),
    }
}

#[cfg(test)]
mod tests {
    use super::{worker_claim_token, DEFAULT_CLAIM_TTL_SEC, DEFAULT_JOB_LIMIT};

    #[test]
    fn defaults_match_current_worker_contract() {
        assert_eq!(DEFAULT_JOB_LIMIT, 50);
        assert_eq!(DEFAULT_CLAIM_TTL_SEC, 300);
    }

    #[test]
    fn push_error_message_prefers_transient_then_hard_failure() {
        let transient = super::ProviderPushResult {
            ok: false,
            hard_failure_reason: Some("BadDeviceToken".to_owned()),
            transient_failure_reason: Some("InternalServerError".to_owned()),
        };
        assert_eq!(super::push_error_message(&transient), "InternalServerError");

        let hard = super::ProviderPushResult {
            ok: false,
            hard_failure_reason: Some("Unregistered".to_owned()),
            transient_failure_reason: None,
        };
        assert_eq!(super::push_error_message(&hard), "Unregistered");
    }

    #[test]
    fn worker_claim_token_is_uuid_v4_shaped() {
        let token = worker_claim_token();

        assert!(token.is_ok());
        let Ok(token) = token else {
            return;
        };
        assert_eq!(token.len(), 36);
        assert_eq!(token.as_bytes().get(14), Some(&b'4'));
        assert!(matches!(
            token.as_bytes().get(19),
            Some(b'8' | b'9' | b'a' | b'b')
        ));
        assert_eq!(token.matches('-').count(), 4);
    }
}
