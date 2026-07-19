//! S3-compatible object storage for encrypted media ciphertext.
//!
//! The current production contract uses `MinIO`. This adapter signs path-style S3 requests with AWS `SigV4` and never
//! stores or logs object contents, download capabilities, or media decryption material.

use crate::hashing::sha256_hex;
use hmac::{Hmac, Mac};
use reqwest::{Client, Method, StatusCode};
use sha2::Sha256;
use std::collections::BTreeSet;
use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use time::OffsetDateTime;

const DEFAULT_MINIO_ENDPOINT: &str = "localhost";
const DEFAULT_MINIO_PORT: u16 = 9000;
const DEFAULT_MINIO_USE_SSL: bool = false;
const DEFAULT_MINIO_REGION: &str = "us-east-1";
const EMPTY_SHA256_HEX: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const S3_SERVICE: &str = "s3";
const AWS4_REQUEST: &str = "aws4_request";
const AWS4_ALGORITHM: &str = "AWS4-HMAC-SHA256";

type HmacSha256 = Hmac<Sha256>;

/// Opaque object-storage error. Public route handlers map it to the standard generic `500`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaStorageError;

impl Display for MediaStorageError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("media object storage error")
    }
}

impl Error for MediaStorageError {}

/// S3-compatible media object storage configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
// Object storage paths are derived server-side so callers cannot choose arbitrary filesystem locations.
pub struct MediaStorageConfig {
    endpoint: String,
    port: u16,
    use_ssl: bool,
    access_key: String,
    secret_key: String,
    region: String,
}

impl MediaStorageConfig {
    /// Builds object-store configuration from the current `MinIO` env contract.
    ///
    /// # Errors
    ///
    /// Returns `MediaStorageError` when required credentials or numeric env values are missing/invalid.
    pub fn from_env() -> Result<Self, MediaStorageError> {
        Ok(Self {
            endpoint: normalize_endpoint(
                &env::var("MINIO_ENDPOINT").unwrap_or_else(|_| DEFAULT_MINIO_ENDPOINT.to_owned()),
            )?,
            port: env::var("MINIO_PORT")
                .ok()
                .map(|value| value.parse::<u16>())
                .transpose()
                .map_err(|_| MediaStorageError)?
                .unwrap_or(DEFAULT_MINIO_PORT),
            use_ssl: env::var("MINIO_USE_SSL")
                .ok()
                .map_or(DEFAULT_MINIO_USE_SSL, |value| {
                    value.trim().eq_ignore_ascii_case("true")
                }),
            access_key: required_env("MINIO_ACCESS_KEY")?,
            secret_key: required_env("MINIO_SECRET_KEY")?,
            region: env::var("MINIO_REGION")
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| DEFAULT_MINIO_REGION.to_owned()),
        })
    }

    #[must_use]
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[must_use]
    pub const fn port(&self) -> u16 {
        self.port
    }

    #[must_use]
    pub const fn use_ssl(&self) -> bool {
        self.use_ssl
    }

    #[must_use]
    pub fn access_key(&self) -> &str {
        &self.access_key
    }

    #[must_use]
    pub fn secret_key(&self) -> &str {
        &self.secret_key
    }

    #[must_use]
    pub fn region(&self) -> &str {
        &self.region
    }

    #[must_use]
    pub fn host_header(&self) -> String {
        format!("{}:{}", self.endpoint, self.port)
    }

    #[must_use]
    pub fn object_url(&self, bucket: &str, key: &str) -> String {
        let scheme = if self.use_ssl { "https" } else { "http" };
        format!(
            "{scheme}://{}:{}{}",
            self.endpoint,
            self.port,
            canonical_uri(bucket, key)
        )
    }
}

/// MinIO/S3 media object storage client.
#[derive(Debug, Clone)]
pub struct MinioMediaObjectStore {
    config: Arc<MediaStorageConfig>,
    client: Client,
    ensured_buckets: Arc<Mutex<BTreeSet<String>>>,
}

impl MinioMediaObjectStore {
    /// Creates a storage client from explicit configuration.
    #[must_use]
    pub fn new(config: MediaStorageConfig) -> Self {
        Self {
            config: Arc::new(config),
            client: Client::new(),
            ensured_buckets: Arc::new(Mutex::new(BTreeSet::new())),
        }
    }

    /// Creates a storage client from env, returning `None` when required `MinIO` credentials are absent.
    #[must_use]
    pub fn from_env_optional() -> Option<Self> {
        MediaStorageConfig::from_env().ok().map(Self::new)
    }

    /// Stores ciphertext bytes in object storage.
    ///
    /// # Errors
    ///
    /// Returns `MediaStorageError` when the bucket cannot be ensured, the request cannot be signed/sent, or `MinIO`
    /// returns a non-success status.
    pub async fn put_ciphertext(
        &self,
        bucket: &str,
        key: &str,
        ciphertext: &[u8],
    ) -> Result<(), MediaStorageError> {
        self.ensure_bucket(bucket).await?;
        let payload_hash = sha256_hex(ciphertext);
        let request = self
            .signed_request(Method::PUT, bucket, key, &payload_hash)?
            .header("content-type", "application/octet-stream")
            .body(ciphertext.to_vec());
        let response = request.send().await.map_err(|_| MediaStorageError)?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(MediaStorageError)
        }
    }

    /// Reads ciphertext bytes from object storage.
    ///
    /// # Errors
    ///
    /// Returns `MediaStorageError` when the bucket cannot be ensured, the request cannot be signed/sent, or `MinIO`
    /// returns a non-success status.
    pub async fn get_ciphertext(
        &self,
        bucket: &str,
        key: &str,
    ) -> Result<Vec<u8>, MediaStorageError> {
        self.ensure_bucket(bucket).await?;
        let response = self
            .signed_request(Method::GET, bucket, key, EMPTY_SHA256_HEX)?
            .send()
            .await
            .map_err(|_| MediaStorageError)?;
        if !response.status().is_success() {
            return Err(MediaStorageError);
        }
        response
            .bytes()
            .await
            .map(|bytes| bytes.to_vec())
            .map_err(|_| MediaStorageError)
    }

    /// Removes ciphertext bytes from object storage.
    ///
    /// # Errors
    ///
    /// Returns `MediaStorageError` when the bucket cannot be ensured, the request cannot be signed/sent, or `MinIO`
    /// returns a non-success status.
    pub async fn remove_ciphertext(
        &self,
        bucket: &str,
        key: &str,
    ) -> Result<(), MediaStorageError> {
        self.ensure_bucket(bucket).await?;
        let response = self
            .signed_request(Method::DELETE, bucket, key, EMPTY_SHA256_HEX)?
            .send()
            .await
            .map_err(|_| MediaStorageError)?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(MediaStorageError)
        }
    }

    async fn ensure_bucket(&self, bucket: &str) -> Result<(), MediaStorageError> {
        if self.bucket_was_ensured(bucket)? {
            return Ok(());
        }

        let status = self.bucket_status(bucket).await?;
        if status == StatusCode::NOT_FOUND {
            self.create_bucket(bucket).await?;
        } else if !status.is_success() {
            return Err(MediaStorageError);
        }

        self.mark_bucket_ensured(bucket)
    }

    async fn bucket_status(&self, bucket: &str) -> Result<StatusCode, MediaStorageError> {
        self.signed_bucket_request(Method::HEAD, bucket, EMPTY_SHA256_HEX)?
            .send()
            .await
            .map(|response| response.status())
            .map_err(|_| MediaStorageError)
    }

    async fn create_bucket(&self, bucket: &str) -> Result<(), MediaStorageError> {
        let response = self
            .signed_bucket_request(Method::PUT, bucket, EMPTY_SHA256_HEX)?
            .send()
            .await
            .map_err(|_| MediaStorageError)?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(MediaStorageError)
        }
    }

    fn signed_request(
        &self,
        method: Method,
        bucket: &str,
        key: &str,
        payload_hash: &str,
    ) -> Result<reqwest::RequestBuilder, MediaStorageError> {
        let path = canonical_uri(bucket, key);
        let url = self.config.object_url(bucket, key);
        let headers = signed_headers(
            &method,
            &path,
            payload_hash,
            &self.config,
            current_s3_time()?,
        )?;

        Ok(self
            .client
            .request(method, url)
            .header("host", headers.host)
            .header("x-amz-date", headers.amz_date)
            .header("x-amz-content-sha256", headers.payload_hash)
            .header("authorization", headers.authorization))
    }

    fn signed_bucket_request(
        &self,
        method: Method,
        bucket: &str,
        payload_hash: &str,
    ) -> Result<reqwest::RequestBuilder, MediaStorageError> {
        self.signed_request(method, bucket, "", payload_hash)
    }

    fn bucket_was_ensured(&self, bucket: &str) -> Result<bool, MediaStorageError> {
        self.ensured_buckets
            .lock()
            .map(|buckets| buckets.contains(bucket))
            .map_err(|_| MediaStorageError)
    }

    fn mark_bucket_ensured(&self, bucket: &str) -> Result<(), MediaStorageError> {
        self.ensured_buckets
            .lock()
            .map(|mut buckets| {
                buckets.insert(bucket.to_owned());
            })
            .map_err(|_| MediaStorageError)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SignedHeaders {
    host: String,
    amz_date: String,
    payload_hash: String,
    authorization: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct S3Time {
    date: String,
    amz_date: String,
}

fn signed_headers(
    method: &Method,
    canonical_path: &str,
    payload_hash: &str,
    config: &MediaStorageConfig,
    time: S3Time,
) -> Result<SignedHeaders, MediaStorageError> {
    let host = config.host_header();
    let scope = credential_scope(&time.date, config.region());
    let signed_header_names = "host;x-amz-content-sha256;x-amz-date";
    let canonical_headers = format!(
        "host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{}\n",
        time.amz_date
    );
    let canonical_request = [
        method.as_str().to_owned(),
        canonical_path.to_owned(),
        String::new(),
        canonical_headers,
        signed_header_names.to_owned(),
        payload_hash.to_owned(),
    ]
    .join("\n");
    let canonical_hash = sha256_hex(canonical_request.as_bytes());
    let string_to_sign = [
        AWS4_ALGORITHM.to_owned(),
        time.amz_date.clone(),
        scope.clone(),
        canonical_hash,
    ]
    .join("\n");
    let signature = signature_hex(
        config.secret_key(),
        &time.date,
        config.region(),
        &string_to_sign,
    )?;
    let authorization = format!(
        "{AWS4_ALGORITHM} Credential={}/{scope}, SignedHeaders={signed_header_names}, Signature={signature}",
        config.access_key()
    );

    Ok(SignedHeaders {
        host,
        amz_date: time.amz_date,
        payload_hash: payload_hash.to_owned(),
        authorization,
    })
}

fn signature_hex(
    secret_key: &str,
    date: &str,
    region: &str,
    string_to_sign: &str,
) -> Result<String, MediaStorageError> {
    let date_key = hmac_sha256(format!("AWS4{secret_key}").as_bytes(), date.as_bytes())?;
    let region_key = hmac_sha256(&date_key, region.as_bytes())?;
    let service_key = hmac_sha256(&region_key, S3_SERVICE.as_bytes())?;
    let signing_key = hmac_sha256(&service_key, AWS4_REQUEST.as_bytes())?;
    let signature = hmac_sha256(&signing_key, string_to_sign.as_bytes())?;

    Ok(hex_lower(&signature))
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Result<Vec<u8>, MediaStorageError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| MediaStorageError)?;
    mac.update(data);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn credential_scope(date: &str, region: &str) -> String {
    format!("{date}/{region}/{S3_SERVICE}/{AWS4_REQUEST}")
}

fn current_s3_time() -> Result<S3Time, MediaStorageError> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| MediaStorageError)?;
    let seconds = i64::try_from(duration.as_secs()).map_err(|_| MediaStorageError)?;
    let datetime = OffsetDateTime::from_unix_timestamp(seconds).map_err(|_| MediaStorageError)?;
    Ok(s3_time(datetime))
}

fn s3_time(datetime: OffsetDateTime) -> S3Time {
    S3Time {
        date: format!(
            "{:04}{:02}{:02}",
            datetime.year(),
            u8::from(datetime.month()),
            datetime.day()
        ),
        amz_date: format!(
            "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
            datetime.year(),
            u8::from(datetime.month()),
            datetime.day(),
            datetime.hour(),
            datetime.minute(),
            datetime.second()
        ),
    }
}

fn canonical_uri(bucket: &str, key: &str) -> String {
    if key.is_empty() {
        return format!("/{}", percent_encode_path(bucket));
    }

    format!(
        "/{}/{}",
        percent_encode_path(bucket),
        percent_encode_path(key)
    )
}

fn percent_encode_path(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        if is_unreserved_path_byte(byte) {
            encoded.push(char::from(byte));
        } else {
            encoded.push('%');
            encoded.push(hex_digit(byte >> 4));
            encoded.push(hex_digit(byte & 0x0f));
        }
    }
    encoded
}

const fn is_unreserved_path_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/')
}

fn hex_digit(nibble: u8) -> char {
    match nibble {
        0..=9 => char::from(b'0' + nibble),
        _ => char::from(b'A' + (nibble - 10)),
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(hex_lower_digit(byte >> 4));
        output.push(hex_lower_digit(byte & 0x0f));
    }
    output
}

fn hex_lower_digit(nibble: u8) -> char {
    match nibble {
        0..=9 => char::from(b'0' + nibble),
        _ => char::from(b'a' + (nibble - 10)),
    }
}

fn normalize_endpoint(value: &str) -> Result<String, MediaStorageError> {
    let without_scheme = value
        .trim()
        .strip_prefix("http://")
        .or_else(|| value.trim().strip_prefix("https://"))
        .unwrap_or_else(|| value.trim());
    let host = without_scheme
        .split('/')
        .next()
        .unwrap_or_default()
        .split(':')
        .next()
        .unwrap_or_default()
        .trim();
    if host.is_empty() {
        return Err(MediaStorageError);
    }

    Ok(host.to_owned())
}

fn required_env(name: &str) -> Result<String, MediaStorageError> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .ok_or(MediaStorageError)
}

#[cfg(test)]
mod tests {
    use super::{
        canonical_uri, credential_scope, hex_lower, normalize_endpoint, percent_encode_path,
        s3_time, signed_headers, MediaStorageConfig, S3Time, EMPTY_SHA256_HEX,
    };
    use reqwest::Method;
    use time::OffsetDateTime;

    fn test_config() -> MediaStorageConfig {
        MediaStorageConfig {
            endpoint: "minio.local".to_owned(),
            port: 9000,
            use_ssl: false,
            access_key: "access".to_owned(),
            secret_key: "secret".to_owned(),
            region: "us-east-1".to_owned(),
        }
    }

    #[test]
    fn builds_path_style_urls_and_canonical_uris() {
        let config = test_config();

        assert_eq!(config.host_header(), "minio.local:9000");
        assert_eq!(
            config.object_url("messenger-cipher-media", "media/key 1"),
            "http://minio.local:9000/messenger-cipher-media/media/key%201"
        );
        assert_eq!(
            canonical_uri("messenger-cipher-media", "media/key 1"),
            "/messenger-cipher-media/media/key%201"
        );
        assert_eq!(
            percent_encode_path("media/ключ"),
            "media/%D0%BA%D0%BB%D1%8E%D1%87"
        );
    }

    #[test]
    fn signs_requests_without_leaking_secret_material() {
        let headers = signed_headers(
            &Method::PUT,
            "/bucket/media/key",
            EMPTY_SHA256_HEX,
            &test_config(),
            S3Time {
                date: "20260529".to_owned(),
                amz_date: "20260529T120000Z".to_owned(),
            },
        );

        assert!(headers.is_ok());
        let Ok(headers) = headers else {
            return;
        };
        assert_eq!(headers.host, "minio.local:9000");
        assert_eq!(headers.payload_hash, EMPTY_SHA256_HEX);
        assert!(headers
            .authorization
            .starts_with("AWS4-HMAC-SHA256 Credential=access/20260529/us-east-1/s3/aws4_request"));
        assert!(headers
            .authorization
            .contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"));
        assert!(!headers.authorization.contains("secret"));
    }

    #[test]
    fn formats_s3_dates_and_hex() {
        let timestamp = OffsetDateTime::from_unix_timestamp(0);
        assert!(timestamp.is_ok());
        let Ok(timestamp) = timestamp else {
            return;
        };
        assert_eq!(
            s3_time(timestamp),
            S3Time {
                date: "19700101".to_owned(),
                amz_date: "19700101T000000Z".to_owned()
            }
        );
        assert_eq!(
            credential_scope("20260529", "us-east-1"),
            "20260529/us-east-1/s3/aws4_request"
        );
        assert_eq!(hex_lower(&[0, 15, 16, 255]), "000f10ff");
    }

    #[test]
    fn normalizes_endpoint_like_minio_client_config() {
        assert_eq!(
            normalize_endpoint(" http://localhost:9000/path ").as_deref(),
            Ok("localhost")
        );
        assert_eq!(
            normalize_endpoint("minio.service.local").as_deref(),
            Ok("minio.service.local")
        );
        assert!(normalize_endpoint("https://").is_err());
    }
}
