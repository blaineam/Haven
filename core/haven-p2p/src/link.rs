//! Reach-me links & QR tickets.
//!
//! A link is a permanent, server-free pointer to a person. It carries only:
//!   * the 32-byte routable id (Ed25519 public key) — used to *find* the peer's
//!     current network address via decentralized discovery (signed DHT record), and
//!   * a 16-byte verification hash of the peer's full hybrid key bundle, kept in the
//!     URL **fragment** so it is never sent to any web server.
//!
//! The bulky ML-KEM public key is intentionally *not* in the link — it is fetched
//! from discovery, then checked against this verification hash to detect tampering.
//!
//! Two surface forms, same payload (always carried in the URL **fragment**, so the web link
//! loads `index.html` on any static host and the id/verify never reach a server):
//!   * `haven://invite#<base32-id>.<base32-verify>`        (deep link / QR)
//!   * `https://<domain>/#<base32-id>.<base32-verify>`     (a link on your website,
//!     opens the app via the haven:// scheme, else the static web client)
//!
//! Security note: a link shared over the internet is a weaker trust anchor than an
//! in-person QR scan, so using one only ever creates a *pending* request that the
//! owner must approve — and the verification hash lets both sides confirm the keys
//! match before trusting them.

use data_encoding::BASE32_NOPAD;

use crate::identity::HavenId;
use crate::{CoreError, Result};

/// The decoded contents of a reach-me link.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct HavenLink {
    /// 32-byte Ed25519 routable id.
    pub id: [u8; 32],
    /// 16-byte tamper-check over the full hybrid identity bundle.
    pub verification: [u8; 16],
}

impl HavenLink {
    /// Build a link from a peer's public identity.
    pub fn from_identity(id: &HavenId) -> Self {
        Self {
            id: id.node_id_bytes(),
            verification: id.verification(),
        }
    }

    /// `haven://invite#<id>.<verify>` — the deep-link / QR form (payload in the fragment).
    pub fn to_uri(&self) -> String {
        format!(
            "haven://invite#{}.{}",
            BASE32_NOPAD.encode(&self.id),
            BASE32_NOPAD.encode(&self.verification),
        )
    }

    /// `https://<domain>/#<id>.<verify>` — the website form. The whole payload rides in the
    /// URL fragment, so the link loads `index.html` on any static host (the path stays the base
    /// directory) and neither the id nor the verify ever reaches a server.
    pub fn to_web(&self, domain: &str) -> String {
        format!(
            "https://{}/#{}.{}",
            domain.trim_end_matches('/'),
            BASE32_NOPAD.encode(&self.id),
            BASE32_NOPAD.encode(&self.verification),
        )
    }

    /// Parse either form. The payload `<id>.<verify>` lives in the fragment (everything after
    /// the last `#`); both parts are required so the keys can be tamper-checked against discovery.
    pub fn parse(s: &str) -> Result<Self> {
        let s = s.trim();
        let payload = s
            .rsplit('#')
            .next()
            .filter(|p| !p.is_empty())
            .ok_or(CoreError::BadLink("missing #<id>.<verify> payload"))?;
        let (id_b32, verify_b32) = payload
            .split_once('.')
            .ok_or(CoreError::BadLink("payload must be <id>.<verify>"))?;

        let id_bytes = BASE32_NOPAD
            .decode(id_b32.as_bytes())
            .map_err(|_| CoreError::BadLink("id is not valid base32"))?;
        if id_bytes.len() != 32 {
            return Err(CoreError::BadLink("id must be 32 bytes"));
        }
        let verify_bytes = BASE32_NOPAD
            .decode(verify_b32.as_bytes())
            .map_err(|_| CoreError::BadLink("verification is not valid base32"))?;
        if verify_bytes.len() != 16 {
            return Err(CoreError::BadLink("verification must be 16 bytes"));
        }

        let mut id = [0u8; 32];
        id.copy_from_slice(&id_bytes);
        let mut verification = [0u8; 16];
        verification.copy_from_slice(&verify_bytes);
        Ok(Self { id, verification })
    }

    /// Confirm a full identity fetched from discovery matches what this link promised.
    /// This is the MITM / tamper check.
    pub fn matches(&self, fetched: &HavenId) -> bool {
        fetched.node_id_bytes() == self.id && fetched.verification() == self.verification
    }
}
