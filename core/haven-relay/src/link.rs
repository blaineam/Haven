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

/// One circle's grant: the circle tag and the member node ids allowed to use it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CircleGrant {
    #[serde(rename = "c")]
    pub circle: String,
    #[serde(rename = "m")]
    pub members: Vec<String>,
}

/// A parsed relay link: which circle(s), and which member node ids to forward toward.
///
/// ## Why v2 carries MANY circles
///
/// A relay authorizes exactly what its link grants. v1 carried ONE circle, but the apps let you
/// pick a relay as the default for EVERY circle — so a user would set their relay once, watch it
/// serve one circle, and get `ERR forbidden` on all the others forever. Republishing a device
/// roster could not fix it: roster expansion only adds DEVICE ids to circles whose ACCOUNT the
/// relay already knows, so a circle it was never granted has nothing to expand into. The symptom
/// was media that "isn't on any relay" while sitting on a relay that refused to serve it.
///
/// v2 grants a set of circles in one link, so one paste authorizes everything. `circle`/`members`
/// stay populated with the FIRST grant, so a v2 link pasted into an older relay binary still
/// authorizes that circle instead of failing outright.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayLink {
    /// Schema version.
    #[serde(rename = "v")]
    pub version: u8,
    /// Opaque circle tag (a label, not a key). Keeps multi-circle dedup state separate.
    /// v2: the first grant, kept for older readers.
    #[serde(rename = "c")]
    pub circle: String,
    /// Member node ids (hex Ed25519) the relay forwards sealed frames toward.
    /// v2: the first grant's members, kept for older readers.
    #[serde(rename = "m")]
    pub members: Vec<String>,
    /// v2: every circle this link grants. Absent in v1 links.
    #[serde(rename = "g", default, skip_serializing_if = "Vec::is_empty")]
    pub grants: Vec<CircleGrant>,
}

impl RelayLink {
    pub fn new(circle: impl Into<String>, members: Vec<String>) -> Self {
        Self { version: 1, circle: circle.into(), members, grants: Vec::new() }
    }

    /// A v2 link granting several circles at once. Empty input yields an empty v1-shaped link.
    pub fn new_multi(grants: Vec<CircleGrant>) -> Self {
        let Some(first) = grants.first().cloned() else {
            return Self { version: 2, circle: String::new(), members: Vec::new(), grants: Vec::new() };
        };
        Self { version: 2, circle: first.circle, members: first.members, grants }
    }

    /// Every circle this link authorizes — the ONE place callers should read, so v1 and v2 links
    /// are handled identically and no site can accidentally honour only the first grant.
    pub fn all_grants(&self) -> Vec<CircleGrant> {
        if self.grants.is_empty() {
            if self.circle.is_empty() { return Vec::new(); }
            return vec![CircleGrant { circle: self.circle.clone(), members: self.members.clone() }];
        }
        self.grants.clone()
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
        if link.version != 1 && link.version != 2 {
            anyhow::bail!("unsupported relay link version {}", link.version);
        }
        // Validate EVERY grant, not just the top-level pair — a v2 link's later circles carry the
        // members that matter, and an unchecked id there would be authorized sight-unseen.
        let grants = link.all_grants();
        if grants.is_empty() {
            anyhow::bail!("relay link grants no circles");
        }
        for g in &grants {
            if g.circle.is_empty() {
                anyhow::bail!("relay link has a grant with no circle tag");
            }
            if g.members.is_empty() {
                anyhow::bail!("relay link grant '{}' has no member node ids", g.circle);
            }
            for m in &g.members {
                if m.len() != 64 || !m.bytes().all(|b| b.is_ascii_hexdigit()) {
                    anyhow::bail!("member node id must be 64 hex chars: {m}");
                }
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

    /// A v2 link must authorize EVERY circle it grants. Honouring only the first is precisely the
    /// bug this version exists to fix — a relay that served one circle and answered `ERR forbidden`
    /// on all the others, permanently and with no way to self-heal.
    #[test]
    fn v2_link_grants_every_circle() {
        let a = "11".repeat(32);
        let b = "22".repeat(32);
        let link = RelayLink::new_multi(vec![
            CircleGrant { circle: "default".into(), members: vec![a.clone()] },
            CircleGrant { circle: "c1ABC".into(), members: vec![a.clone(), b.clone()] },
            CircleGrant { circle: "dm:a-b".into(), members: vec![b.clone()] },
        ]);
        let parsed = RelayLink::parse(&link.to_uri()).unwrap();
        let grants = parsed.all_grants();
        assert_eq!(grants.len(), 3, "every granted circle must survive the round trip");
        assert_eq!(grants[1].circle, "c1ABC");
        assert_eq!(grants[1].members.len(), 2);
        // An OLDER relay binary reads only c/m — it must still get a usable first circle rather
        // than choking, so a v2 link degrades instead of failing.
        assert_eq!(parsed.circle, "default");
        assert_eq!(parsed.members, vec![a]);
    }

    /// v1 links keep working untouched — existing relays must not need re-pasting to keep serving.
    #[test]
    fn v1_link_still_parses_as_one_grant() {
        let a = "33".repeat(32);
        let v1 = RelayLink::new("fam", vec![a.clone()]);
        let parsed = RelayLink::parse(&v1.to_uri()).unwrap();
        assert_eq!(parsed.version, 1);
        let grants = parsed.all_grants();
        assert_eq!(grants.len(), 1);
        assert_eq!(grants[0].circle, "fam");
        assert_eq!(grants[0].members, vec![a]);
    }

    /// A bad node id in a LATER grant must be rejected too — otherwise v2 would be a hole in the
    /// validation that v1 enforced.
    #[test]
    fn rejects_bad_member_id_in_a_later_grant() {
        let good = "44".repeat(32);
        let link = RelayLink::new_multi(vec![
            CircleGrant { circle: "ok".into(), members: vec![good] },
            CircleGrant { circle: "bad".into(), members: vec!["nothex".into()] },
        ]);
        assert!(RelayLink::parse(&link.to_uri()).is_err());
    }

    #[test]
    fn rejects_bad_member_ids() {
        assert!(RelayLink::parse("haven-relay://circle#").is_err());
        let bad = RelayLink { version: 1, circle: "x".into(), members: vec!["zz".into()], grants: Vec::new() };
        let uri = bad.to_uri();
        assert!(RelayLink::parse(&uri).is_err());
    }
}
