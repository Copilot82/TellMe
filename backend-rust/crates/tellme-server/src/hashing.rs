//! Shared hashing helpers for `TellMe` protocol identifiers.

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use sha2::{Digest, Sha256};

#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        output.push(hex_char(byte >> 4));
        output.push(hex_char(byte & 0x0f));
    }
    output
}

#[must_use]
pub fn sha256_base64(bytes: &[u8]) -> String {
    STANDARD.encode(Sha256::digest(bytes))
}

fn hex_char(value: u8) -> char {
    match value {
        0..=9 => char::from(b'0' + value),
        10..=15 => char::from(b'a' + (value - 10)),
        _ => '?',
    }
}

#[cfg(test)]
mod tests {
    use super::{sha256_base64, sha256_hex};

    #[test]
    fn hashes_sha256_as_lower_hex() {
        assert_eq!(
            sha256_hex(b"hello-federated-world"),
            "a11afedb1625b39187e336790affa1e8c2efd0c68be9ca4dea4281983e7712b4"
        );
    }

    #[test]
    fn hashes_sha256_as_base64() {
        assert_eq!(
            sha256_base64(br#"{"deliveries":[]}"#),
            "cmMWKqmB5Y6wuP1LoFihsX/2IsHoeEgguOwfQH6b04Q="
        );
    }
}
