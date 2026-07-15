//! The **relay link** — what a user pastes into `haven-relay run --link <code>` to
//! attach a relay to their circle.
//!
//! ## Why this is a *separate* code from a reach-me link
//!
//! A reach-me link (`haven://invite#…`) points at one *person* and carries a
//! verification hash of that person's full hybrid key bundle. A relay does **not** need
//! — and must never hold — any key material that would let it read circle content. So a
//! relay link carries strictly the **public routing data** a switchboard needs:
//!
//!   * a `circle` tag — an opaque label so one relay binary can serve several circles
//!     and keep their dedup state separate. It is *not* the circle's content key and
//!     reveals nothing decryptable.
//!   * the circle's **member node ids** (32-byte Ed25519 routable ids) — already public
//!     (they appear in every member's reach-me link). The relay forwards sealed frames
//!     *toward* these ids. Knowing a node id lets you route to a peer; it does not let
//!     you read anything sealed to them.
//!
//! That's the whole payload. There is deliberately **no** content key, no KEM key, no
//! circle roster secret — so linking a relay can never turn it into a content reader or
//! a bypass target. (Security mandate #1.)
//!
//! ## Wire form
//!
//! ```text
//!   haven-relay://circle#<base32(json)>
//! ```
//!
//! where the JSON is `{ "v":1, "c":"<circle tag>", "m":["<node-id-hex>", …] }`. The
//! payload rides in the URL **fragment** (after `#`) so, like reach-me links, if it is
//! ever shared as an `https://` form the routing data never reaches a web server.

use data_encoding::BASE32_NOPAD;
use serde::{Deserialize, Serialize};

/// A parsed relay link: which circle, and which member node ids to forward toward.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayLink {
    /// Schema version.
    #[serde(rename = "v")]
    pub version: u8,
    /// Opaque circle tag (a label, not a key). Keeps multi-circle dedup state separate.
    #[serde(rename = "c")]
    pub circle: String,
    /// Member node ids (hex Ed25519) the relay forwards sealed frames toward.
    #[serde(rename = "m")]
    pub members: Vec<String>,
}

impl RelayLink {
    pub fn new(circle: impl Into<String>, members: Vec<String>) -> Self {
        Self { version: 1, circle: circle.into(), members }
    }

    /// `haven-relay://circle#<base32(json)>`
    pub fn to_uri(&self) -> String {
        let json = serde_json::to_vec(self).expect("relay link serializes");
        format!("haven-relay://circle#{}", BASE32_NOPAD.encode(&json))
    }

    /// Parse a relay link. Accepts the `haven-relay://` form or a bare base32 payload
    /// (everything after the last `#`, or the whole string if there is no `#`).
    pub fn parse(s: &str) -> anyhow::Result<Self> {
        let s = s.trim();
        let payload = match s.rsplit_once('#') {
            Some((_, frag)) => frag,
            None => s,
        };
        if payload.is_empty() {
            anyhow::bail!("empty relay link");
        }
        let json = BASE32_NOPAD
            .decode(payload.as_bytes())
            .map_err(|_| anyhow::anyhow!("relay link is not valid base32"))?;
        let link: RelayLink =
            serde_json::from_slice(&json).map_err(|_| anyhow::anyhow!("relay link JSON malformed"))?;
        if link.version != 1 {
            anyhow::bail!("unsupported relay link version {}", link.version);
        }
        if link.members.is_empty() {
            anyhow::bail!("relay link has no member node ids");
        }
        for m in &link.members {
            if m.len() != 64 || !m.bytes().all(|b| b.is_ascii_hexdigit()) {
                anyhow::bail!("member node id must be 64 hex chars: {m}");
            }
        }
        Ok(link)
    }

    /// Member node ids as 32-byte arrays (for building routing frames).
    // Forwarding authorization takes the hex form (`RelayNode::authorize_forwarding`), so nothing
    // in the daemon needs the decoded bytes today. Kept as the link's canonical decoder.
    #[allow(dead_code)]
    pub fn member_bytes(&self) -> Vec<[u8; 32]> {
        self.members
            .iter()
            .filter_map(|h| {
                let mut out = [0u8; 32];
                for i in 0..32 {
                    out[i] = u8::from_str_radix(h.get(i * 2..i * 2 + 2)?, 16).ok()?;
                }
                Some(out)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_link_roundtrips() {
        let a = "11".repeat(32);
        let b = "22".repeat(32);
        let link = RelayLink::new("fam", vec![a.clone(), b.clone()]);
        let uri = link.to_uri();
        assert!(uri.starts_with("haven-relay://circle#"));
        let parsed = RelayLink::parse(&uri).unwrap();
        assert_eq!(parsed, link);
        assert_eq!(parsed.member_bytes().len(), 2);
        // also parses a bare payload
        let bare = uri.rsplit_once('#').unwrap().1;
        assert_eq!(RelayLink::parse(bare).unwrap(), link);
    }

    #[test]
    fn rejects_bad_member_ids() {
        assert!(RelayLink::parse("haven-relay://circle#").is_err());
        let bad = RelayLink { version: 1, circle: "x".into(), members: vec!["zz".into()] };
        let uri = bad.to_uri();
        assert!(RelayLink::parse(&uri).is_err());
    }
}
