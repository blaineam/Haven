//! Mesh-relay routing for Haven Net.
//!
//! A **connection relay** forwards sealed frames toward circle members who can't be
//! reached directly (offline-at-the-same-time, or NAT-blocked). It is a *switchboard*,
//! not a content host: every frame carries an opaque, already-circle-sealed payload
//! that the relay can never open. All the relay reads is a small **cleartext routing
//! header** — exactly enough to decide where the bytes go and to drop loops/replays.
//!
//! ## What the relay sees vs. cannot see
//!
//! | Field | Relay can read? | Why it exists |
//! |---|---|---|
//! | `dest` (destination node ids) | **yes** (cleartext) | so it knows whom to forward to |
//! | `msg_id` (random 16 bytes) | **yes** (cleartext) | loop/replay dedup |
//! | `ttl` (hop budget) | **yes** (cleartext) | bound the forwarding fan-out |
//! | `payload` (sealed envelope) | **NO** — opaque ciphertext | the actual content, E2E to the circle |
//!
//! The destination node ids are *Ed25519 routable ids* (already public in reach-me
//! links), never names or circle ids, and the payload is a `haven-p2p` `SealedEnvelope`
//! the relay has no key for. So a relay learns only "ciphertext blob X is headed toward
//! node ids Y" — never who is in which circle, nor anything about the content.
//!
//! ## Wire format (the design's "mesh-relay frame", type 9)
//!
//! ```text
//!   magic   : b"HVR1"            (4)   — frame tag, distinguishes from a bare envelope
//!   ttl     : u8                 (1)   — remaining hops; relay drops at 0
//!   n_dest  : u8                 (1)   — number of destination node ids (1..=32)
//!   msg_id  : [u8; 16]          (16)   — random, for dedup
//!   dest    : n_dest * [u8; 32]        — destination Ed25519 node ids (cleartext)
//!   payload : remaining bytes          — opaque sealed envelope (E2E; relay-opaque)
//! ```
//!
//! A receiving *member* (not a relay) recognizes the magic, strips the header, and
//! hands the inner `payload` to the normal `receive()` path. A bare (un-prefixed)
//! payload is still accepted for direct peer-to-peer delivery, so this is additive.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use rand::rngs::OsRng;
use rand::RngCore;

pub const RELAY_MAGIC: &[u8; 4] = b"HVR1";
/// Default starting hop budget. One relay in the middle is the common case; a small
/// budget keeps fan-out bounded while tolerating a relay-to-relay hop.
pub const DEFAULT_TTL: u8 = 4;
const MAX_DEST: usize = 32;

/// Cap on a payload this relay will FORWARD (audit F10). Routed frames are messages — media moved
/// to the HTTP/S3 transports — so the 256 MB endpoint cap was 256 MB × 32 destinations of
/// third-party-directed amplification for anyone who learned a relay's node id. Local delivery to
/// ourselves is not affected by this.
pub const MAX_RELAY_PAYLOAD: usize = 4 * 1024 * 1024;

/// How long a `msg_id` stays remembered. See [`SeenSet`].
const SEEN_WINDOW: Duration = Duration::from_secs(600);

/// A parsed mesh-relay frame: a cleartext routing header wrapping an opaque payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutingFrame {
    /// Remaining hop budget. A relay forwards only while this is > 0.
    pub ttl: u8,
    /// Random per-message id for loop/replay dedup.
    pub msg_id: [u8; 16],
    /// Destination Ed25519 node ids the payload should reach (cleartext).
    pub dest: Vec<[u8; 32]>,
    /// The opaque, already-sealed payload. The relay never inspects this.
    pub payload: Vec<u8>,
}

impl RoutingFrame {
    /// Build a frame addressed to one or more destination node ids with a fresh msg_id.
    pub fn new(dest: Vec<[u8; 32]>, payload: Vec<u8>, ttl: u8) -> Self {
        let mut msg_id = [0u8; 16];
        OsRng.fill_bytes(&mut msg_id);
        Self { ttl, msg_id, dest, payload }
    }

    /// Serialize to the on-wire frame.
    pub fn to_bytes(&self) -> Vec<u8> {
        let n = self.dest.len().min(MAX_DEST);
        let mut out = Vec::with_capacity(4 + 1 + 1 + 16 + n * 32 + self.payload.len());
        out.extend_from_slice(RELAY_MAGIC);
        out.push(self.ttl);
        out.push(n as u8);
        out.extend_from_slice(&self.msg_id);
        for d in self.dest.iter().take(n) {
            out.extend_from_slice(d);
        }
        out.extend_from_slice(&self.payload);
        out
    }

    /// Parse a frame, or `None` if the bytes are not a relay frame (no magic / too
    /// short / inconsistent length). `None` simply means "treat as a bare payload".
    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() < 22 || &b[0..4] != RELAY_MAGIC {
            return None;
        }
        let ttl = b[4];
        let n = b[5] as usize;
        if n == 0 || n > MAX_DEST {
            return None;
        }
        let mut msg_id = [0u8; 16];
        msg_id.copy_from_slice(&b[6..22]);
        let dest_start = 22;
        let dest_end = dest_start + n * 32;
        if b.len() < dest_end {
            return None;
        }
        let mut dest = Vec::with_capacity(n);
        for i in 0..n {
            let mut id = [0u8; 32];
            id.copy_from_slice(&b[dest_start + i * 32..dest_start + (i + 1) * 32]);
            dest.push(id);
        }
        let payload = b[dest_end..].to_vec();
        Some(Self { ttl, msg_id, dest, payload })
    }

    /// Hex of a destination node id (for forwarding via `send_to_node`).
    pub fn dest_hex(d: &[u8; 32]) -> String {
        d.iter().map(|x| format!("{x:02x}")).collect()
    }
}

/// Loop/replay guard: remembers recently-seen `msg_id`s. RAM-only, no persistence — consistent
/// with the hardened no-log posture (nothing is written to disk and the set self-trims).
///
/// Primarily **time**-windowed ([`SEEN_WINDOW`]), because a count-only cap is attacker-controlled:
/// pushing `cap` distinct ids evicts the whole window and re-admits the id you were deduping
/// (audit F10). `cap` remains as a hard memory ceiling for the pathological case, but under a
/// flood the window — not the flooder — decides what is forgotten.
pub struct SeenSet {
    seen: HashMap<[u8; 16], Instant>,
    order: std::collections::VecDeque<[u8; 16]>,
    cap: usize,
    window: Duration,
}

impl SeenSet {
    pub fn new(cap: usize) -> Self {
        Self { seen: HashMap::new(), order: std::collections::VecDeque::new(), cap, window: SEEN_WINDOW }
    }

    /// Record a msg_id. Returns `true` the first time it's seen, `false` on a repeat
    /// (which the caller should drop to break loops / replays).
    pub fn insert(&mut self, id: [u8; 16]) -> bool {
        let now = Instant::now();
        // Retire whatever aged out, so the live window is what occupies the cap.
        while let Some(front) = self.order.front() {
            match self.seen.get(front) {
                Some(t) if now.duration_since(*t) > self.window => {
                    let old = self.order.pop_front().unwrap();
                    self.seen.remove(&old);
                }
                _ => break,
            }
        }
        if self.seen.contains_key(&id) {
            return false;
        }
        self.seen.insert(id, now);
        self.order.push_back(id);
        if self.order.len() > self.cap {
            if let Some(old) = self.order.pop_front() {
                self.seen.remove(&old);
            }
        }
        true
    }
}

impl Default for SeenSet {
    fn default() -> Self {
        Self::new(8192)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrips() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        let f = RoutingFrame::new(vec![a, b], b"sealed-bytes".to_vec(), DEFAULT_TTL);
        let bytes = f.to_bytes();
        let parsed = RoutingFrame::parse(&bytes).expect("parses");
        assert_eq!(parsed, f);
        assert_eq!(parsed.payload, b"sealed-bytes");
        assert_eq!(parsed.dest, vec![a, b]);
    }

    #[test]
    fn bare_payload_is_not_a_frame() {
        // A normal sealed envelope (JSON) must not be mistaken for a relay frame.
        assert!(RoutingFrame::parse(b"{\"sender\":[]}").is_none());
        assert!(RoutingFrame::parse(b"short").is_none());
    }

    #[test]
    fn seen_set_dedups_and_trims() {
        let mut s = SeenSet::new(2);
        let a = [1u8; 16];
        let b = [2u8; 16];
        let c = [3u8; 16];
        assert!(s.insert(a));
        assert!(!s.insert(a), "repeat is dropped");
        assert!(s.insert(b));
        assert!(s.insert(c)); // evicts `a`
        assert!(s.insert(a), "evicted id is seen-as-new again (bounded memory)");
    }
}
