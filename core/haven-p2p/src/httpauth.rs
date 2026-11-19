//! The **client half** of the relay's signed-HTTP request protocol — the transcript and the
//! `Authorization: Haven …` value — kept in the IO-free core so every client signs byte-identically
//! to what the relay verifies (`haven_net::httprelay`), including a browser build, which cannot
//! link the relay's server code at all.
//!
//! ```text
//!   Authorization: Haven <node-id-hex>.<unix-ts>.<nonce-hex>.<blake3(body)-hex>.<ed25519-sig-hex>
//! ```
//!
//! The signature covers [`REQUEST_DOMAIN`] ‖ token ‖ method ‖ key ‖ ts ‖ nonce ‖ blake3(body). See
//! `haven_net::httprelay` for why each field is bound and how the relay turns the verified node id
//! into a circle-membership decision. This module reads no clock: the caller supplies `ts`.

use ed25519_dalek::{Signer, SigningKey};

/// Domain tag on the request signature, so a node-key signature minted for Haven's HTTP relay can
/// never be lifted from (or replayed into) any other context that signs with the same key.
pub const REQUEST_DOMAIN: &str = "haven-httprelay-v1";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The exact bytes a request signature covers. Every field that decides what the request DOES is
/// in here — flip the verb, the key, or a byte of the body and the signature stops verifying.
pub fn transcript(token: &str, method: &str, key: &str, ts: u64, nonce: &str, body_hex: &str) -> Vec<u8> {
    format!("{REQUEST_DOMAIN}\n{token}\n{method}\n{key}\n{ts}\n{nonce}\n{body_hex}").into_bytes()
}

/// Lower-hex blake3 of a request body — the digest that travels in the header.
pub fn body_digest(body: &[u8]) -> String {
    hex(blake3::hash(body).as_bytes())
}

/// Build the `Authorization` value for one request made at unix time `ts`, signing with this
/// node's Ed25519 node secret (`Identity::node_secret_bytes`) and a fresh random nonce.
pub fn auth_header_at(node_secret: &[u8; 32], token: &str, method: &str, key: &str, body: &[u8], ts: u64) -> String {
    let sk = SigningKey::from_bytes(node_secret);
    let node = hex(sk.verifying_key().as_bytes());
    let mut n = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut n);
    let nonce = hex(&n);
    let digest = body_digest(body);
    let sig = sk.sign(&transcript(token, method, key, ts, &nonce, &digest));
    format!("Haven {node}.{ts}.{nonce}.{digest}.{}", hex(&sig.to_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signature, Verifier};

    #[test]
    fn header_carries_a_signature_over_the_transcript_of_its_own_fields() {
        let secret = [7u8; 32];
        let h = auth_header_at(&secret, "tok", "PUT", "haven/media/x", b"body", 1_700_000_000);
        let rest = h.strip_prefix("Haven ").unwrap();
        let p: Vec<&str> = rest.split('.').collect();
        assert_eq!(p.len(), 5);
        let vk = SigningKey::from_bytes(&secret).verifying_key();
        assert_eq!(p[0], hex(vk.as_bytes()));
        assert_eq!(p[1], "1700000000");
        assert_eq!(p[3], body_digest(b"body"));
        let sig: Vec<u8> = (0..p[4].len() / 2).map(|i| u8::from_str_radix(&p[4][i * 2..i * 2 + 2], 16).unwrap()).collect();
        let sig = Signature::from_slice(&sig).unwrap();
        vk.verify(&transcript("tok", "PUT", "haven/media/x", 1_700_000_000, p[2], p[3]), &sig).unwrap();
        // Any bound field changing breaks it.
        assert!(vk.verify(&transcript("tok", "GET", "haven/media/x", 1_700_000_000, p[2], p[3]), &sig).is_err());
    }

    #[test]
    fn two_headers_for_the_same_request_never_share_a_nonce() {
        let a = auth_header_at(&[1u8; 32], "t", "GET", "k", b"", 5);
        let b = auth_header_at(&[1u8; 32], "t", "GET", "k", b"", 5);
        assert_ne!(a, b);
    }
}
