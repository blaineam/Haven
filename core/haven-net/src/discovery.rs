//! **Relay-served peer discovery** — "where is node X", answered by Haven's own relays.
//!
//! Haven's transport currently bootstraps on iroh's `N0` preset (`lib.rs`), which means two
//! third-party dependencies sit under every connection:
//!
//!   * **n0's pkarr/DNS address lookup** (`dns.iroh.link`) — publishes and resolves "which relay
//!     is node X on".
//!   * **n0's default relay servers** — the DERP path used when hole punching fails.
//!
//! Both are free, run by Number Zero, and entirely outside our control. If they go away — funding,
//! policy, a blocked region — every Haven install that cannot hole-punch stops connecting. This
//! module removes the *first* dependency: a Haven relay, which the user already trusts enough to
//! store their sealed mailbox, also answers address lookups. n0 stays wired in as a **fallback**,
//! never removed; iroh queries every configured lookup concurrently and takes whatever answers.
//!
//! (The *second* dependency — the DERP relay itself — is not solved here. See
//! `docs/DECENTRALIZED-DISCOVERY.md`: the answer is `RelayMode::Custom` pointing at a self-hosted
//! `iroh-relay` server, which is config plumbing, not new protocol.)
//!
//! ## The record
//!
//! A discovery record is a node's own statement of where it can be reached, **signed by the node
//! key itself**. The relay is a dumb shelf: it stores bytes it cannot forge and hands them back.
//!
//! ```text
//!   magic    : b"HVD1"           (4)
//!   node     : [u8; 32]         (32)  — Ed25519 node id this record describes
//!   seq      : u64 LE            (8)  — monotonic; rollback defense
//!   expires  : u64 LE            (8)  — unix seconds; a stale shelf can't pin an old address
//!   n_addrs  : u16 LE            (2)  — 0..=MAX_ADDRS
//!   addrs    : [u16 LE len ‖ utf8]*   — "relay:<url>" or "ip:<socketaddr>"
//!   sig      : [u8; 64]         (64)  — Ed25519 over DOMAIN ‖ everything above
//! ```
//!
//! ## Why a malicious relay can only deny service
//!
//! | Attack | Why it fails |
//! |---|---|
//! | Serve a forged address for Bob | The record is signed by *Bob's node key*. `verify` refuses any record whose signature doesn't check, and refuses any record whose `node` field isn't the key that was asked for. A relay has no signing key for Bob. |
//! | Redirect a dial to the relay itself | Same. Addresses only take effect inside a signed record; and even if the address were honoured, QUIC's TLS handshake authenticates the *node id*, so a wrong endpoint fails the handshake. Discovery only ever supplies **hints**; identity is proven end-to-end. |
//! | Replay Bob's old address (pin him to a dead relay) | `seq` is monotonic and `expires` is absolute. A resolver drops expired records; the relay's write gate refuses a lower `seq` than it already holds. |
//! | Withhold Bob's record | **This works.** A relay can always deny service. That is the accepted floor — configure more than one, and n0's lookup stays as a fallback. |
//! | Harvest the social graph | Partly available already: the relay sees `dest` node ids on every routed frame (`relay.rs`) and every mailbox key. Discovery adds "A asked about B" to that. See the threat model in the design doc — the honest statement is that this is *no worse than* today's n0 DNS, where **anyone on the internet** can resolve any node id, and it is visible only to a relay the user chose. |
//!
//! The load-bearing sentence: **discovery answers are hints, never authority.** Nothing here can
//! make a connection succeed to the wrong peer, because nothing here participates in
//! authentication. The worst outcome is a connection that does not form.
//!
//! ## Landmines this module is written around
//!
//! * **Never resolve or publish for our own node id.** Dialing your own id sends iroh's path
//!   discovery into an unbounded loop (tens of GB; the build-98/181 leaks). `HavenRelayLookup`
//!   filters self on both `publish` and `resolve`.
//! * **Absence is not deletion.** A relay that has never seen node X returns 404. That means
//!   "I don't know", *not* "X has no address" — resolvers treat a miss as no-answer and let other
//!   lookups win. The same rule governs relay *lists* (`RelayBook` below): entries carry explicit
//!   presence + generation, and a missing entry never removes a known relay. This project has
//!   already been burned twice by absence-as-delete (resurrected rclone remotes; wiped circles).

use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};

/// Store-key namespace for discovery records: `haven/disc/<node-hex>`.
pub const DISCOVERY_PREFIX: &str = "haven/disc/";
/// Wire tag. Bump on any incompatible layout change.
pub const RECORD_MAGIC: &[u8; 4] = b"HVD1";
/// Signature domain separator, so a node-key signature minted here can never be lifted into
/// another context that signs with the same key (mirrors `httprelay::REQUEST_DOMAIN`).
pub const RECORD_DOMAIN: &[u8] = b"haven-discovery-record-v1";

/// Most addresses one record may carry. Bounds both the record size and how much a single
/// publisher can make every resolver try to dial.
pub const MAX_ADDRS: usize = 16;
/// Longest single address string (a relay URL).
pub const MAX_ADDR_LEN: usize = 256;
/// Hard cap on a whole encoded record — cheap DoS bound on the relay's write path.
pub const MAX_RECORD: usize = 4 * 1024;
/// How long a freshly published record stays valid. Short enough that a seized relay cannot pin a
/// peer to a dead address for long; long enough that a phone that sleeps overnight still resolves.
pub const DEFAULT_TTL_SECS: u64 = 60 * 60;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

/// A node's signed statement of where it can be reached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AddrRecord {
    /// The Ed25519 node id this record describes. MUST equal the key it is stored under.
    pub node: [u8; 32],
    /// Monotonic publish counter. A relay refuses a write whose `seq` is below what it holds.
    pub seq: u64,
    /// Absolute expiry, unix seconds. Resolvers drop anything at or past this.
    pub expires: u64,
    /// Addresses, most-preferred first. `"relay:<url>"` or `"ip:<addr>:<port>"`.
    pub addrs: Vec<String>,
}

impl AddrRecord {
    /// Build a record for `node` valid for [`DEFAULT_TTL_SECS`].
    pub fn new(node: [u8; 32], seq: u64, addrs: Vec<String>) -> Self {
        Self { node, seq, expires: now() + DEFAULT_TTL_SECS, addrs }
    }

    /// The node id as hex — this is the store key suffix.
    pub fn node_hex(&self) -> String {
        hex(&self.node)
    }

    /// True once `expires` has passed.
    pub fn is_expired(&self) -> bool {
        now() >= self.expires
    }

    /// Everything the signature covers: the whole record except the signature itself, prefixed
    /// with the domain tag.
    fn transcript(&self) -> Vec<u8> {
        let mut t = Vec::with_capacity(RECORD_DOMAIN.len() + 64);
        t.extend_from_slice(RECORD_DOMAIN);
        t.extend_from_slice(RECORD_MAGIC);
        t.extend_from_slice(&self.node);
        t.extend_from_slice(&self.seq.to_le_bytes());
        t.extend_from_slice(&self.expires.to_le_bytes());
        t.extend_from_slice(&(self.addrs.len() as u16).to_le_bytes());
        for a in &self.addrs {
            t.extend_from_slice(&(a.len() as u16).to_le_bytes());
            t.extend_from_slice(a.as_bytes());
        }
        t
    }

    /// Encode + sign with the node's Ed25519 secret. Refuses to sign a record whose `node` field
    /// isn't the public key of `node_secret` — signing a record *about someone else* is never a
    /// legitimate operation, and letting it happen would put a forgery one caller-bug away.
    pub fn sign(&self, node_secret: &[u8; 32]) -> Result<Vec<u8>> {
        use ed25519_dalek::{Signer, SigningKey};
        if self.addrs.len() > MAX_ADDRS {
            bail!("too many addrs ({} > {MAX_ADDRS})", self.addrs.len());
        }
        if let Some(a) = self.addrs.iter().find(|a| a.len() > MAX_ADDR_LEN || a.is_empty()) {
            bail!("bad addr length: {}", a.len());
        }
        let sk = SigningKey::from_bytes(node_secret);
        if sk.verifying_key().as_bytes() != &self.node {
            bail!("refusing to sign a record for a node id we do not hold the key for");
        }
        let t = self.transcript();
        let sig = sk.sign(&t);
        // Wire = transcript minus the domain prefix, plus the signature.
        let mut out = t[RECORD_DOMAIN.len()..].to_vec();
        out.extend_from_slice(&sig.to_bytes());
        if out.len() > MAX_RECORD {
            bail!("record too large ({} > {MAX_RECORD})", out.len());
        }
        Ok(out)
    }

    /// Parse + verify a record, requiring it to describe `expect_node_hex` (the key it was stored
    /// under). Fails **closed** on every anomaly: bad magic, truncation, oversize, wrong node,
    /// bad signature. Expiry is deliberately NOT checked here — the relay's write gate and the
    /// resolver want different policies (a relay may hold a record slightly past expiry so a
    /// re-publish can still be rollback-checked against it); callers check [`Self::is_expired`].
    pub fn verify(expect_node_hex: &str, body: &[u8]) -> Option<Self> {
        use ed25519_dalek::{Signature, Verifier, VerifyingKey};
        if body.len() > MAX_RECORD || body.len() < 4 + 32 + 8 + 8 + 2 + 64 {
            return None;
        }
        let (head, sig) = body.split_at(body.len() - 64);
        if &head[..4] != RECORD_MAGIC {
            return None;
        }
        let node: [u8; 32] = head[4..36].try_into().ok()?;
        // Bind the record to the key it lives under. Without this a relay could shelve Bob's
        // (validly signed) record under Carol's key and misdirect every lookup for Carol.
        if hex(&node) != expect_node_hex {
            return None;
        }
        let seq = u64::from_le_bytes(head[36..44].try_into().ok()?);
        let expires = u64::from_le_bytes(head[44..52].try_into().ok()?);
        let n = u16::from_le_bytes(head[52..54].try_into().ok()?) as usize;
        if n > MAX_ADDRS {
            return None;
        }
        let mut rest = &head[54..];
        let mut addrs = Vec::with_capacity(n);
        for _ in 0..n {
            if rest.len() < 2 {
                return None;
            }
            let len = u16::from_le_bytes([rest[0], rest[1]]) as usize;
            if len == 0 || len > MAX_ADDR_LEN || rest.len() < 2 + len {
                return None;
            }
            addrs.push(String::from_utf8(rest[2..2 + len].to_vec()).ok()?);
            rest = &rest[2 + len..];
        }
        if !rest.is_empty() {
            return None; // trailing garbage — a malleable encoding is a signature-bypass surface
        }
        let vk = VerifyingKey::from_bytes(&node).ok()?;
        let rec = Self { node, seq, expires, addrs };
        vk.verify(&rec.transcript(), &Signature::from_slice(sig).ok()?).ok()?;
        Some(rec)
    }
}

/// Gate a discovery PUT to `haven/disc/<node_hex>` **before** the bytes are stored — the write-side
/// twin of [`AddrRecord::verify`], and the reason the relay can leave this prefix un-gated by
/// circle membership: the body proves its own authorship, so an unauthenticated write injects
/// nothing. A node that no relay has heard of must be able to publish, or it can never be found.
///
/// Refuses (returns `None`) when the body doesn't verify, when it is already expired, or when its
/// `seq` is **below** a record we already hold — replaying yesterday's address is a real downgrade,
/// so rollback defense is mandatory here exactly as it is for device rosters.
///
/// Equal `seq` is ACCEPTED (idempotent re-publish of the same generation, e.g. after the relay lost
/// its disk); the signature makes that harmless.
pub fn verify_discovery_put(root: &Path, node_hex: &str, body: &[u8]) -> Option<AddrRecord> {
    let rec = AddrRecord::verify(node_hex, body)?;
    if rec.is_expired() {
        return None;
    }
    if let Ok(path) = crate::blobstore::safe_path(root, &format!("{DISCOVERY_PREFIX}{node_hex}")) {
        if let Ok(existing) = std::fs::read(&path) {
            if let Some(cur) = AddrRecord::verify(node_hex, &existing) {
                if rec.seq < cur.seq {
                    return None;
                }
            }
        }
    }
    Some(rec)
}

/// Is `key` a discovery record key, and if so which node does it name?
pub fn discovery_node(key: &str) -> Option<&str> {
    let node = key.strip_prefix(DISCOVERY_PREFIX)?;
    // Exactly one hex node id — no sub-paths, no enumeration prefixes.
    if node.len() == 64 && node.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(node)
    } else {
        None
    }
}

// ───────────────────────────── relay book (which relays do I know?) ─────────────────────────────

/// One known relay, with **explicit presence** rather than presence-by-existence.
///
/// This shape exists because absence-as-deletion has broken this project twice (rclone remotes
/// resurrecting on a generation tie; circles wiped on a fresh restore). A relay that is gone is
/// recorded as `present: false` with a higher `gen`, and is *kept*, so the removal can outlive one
/// sync round and beat a stale peer that still has the old entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayEntry {
    /// The relay's iroh node id, hex. The identity that matters; the URL is just how to reach it.
    pub node_hex: String,
    /// `host:port` for the plain-HTTP blob/discovery interface (default port 8674).
    pub http: String,
    /// Human label, for the settings UI only. Never trusted for anything.
    pub label: String,
    /// **Explicit** presence. `false` is a tombstone, not an omission.
    pub present: bool,
    /// Last-writer-wins generation. Higher wins; on a tie, `present == false` wins so a removal is
    /// never undone by a concurrent no-op re-add (the exact tie that resurrected rclone remotes).
    pub gen: u64,
}

/// A syncable set of known relays. Merge is per-entry LWW over `gen`, and **never** treats a
/// missing entry as a removal — a peer that simply hasn't heard of a relay must not delete it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RelayBook {
    pub entries: HashMap<String, RelayEntry>,
}

impl RelayBook {
    /// Merge `other` into `self`, per-entry, newest-generation-wins.
    ///
    /// Rules, in order:
    ///   1. An entry only in `other` is **added** (including tombstones — a removal must propagate).
    ///   2. An entry only in `self` is **kept untouched**. Absence carries no information.
    ///   3. On a `gen` tie, a tombstone (`present: false`) beats a live entry, so "remove" is
    ///      sticky and two devices cannot ping-pong a relay back into existence.
    pub fn merge(&mut self, other: &RelayBook) {
        for (id, theirs) in &other.entries {
            match self.entries.get(id) {
                None => {
                    self.entries.insert(id.clone(), theirs.clone());
                }
                Some(mine) => {
                    let take = theirs.gen > mine.gen || (theirs.gen == mine.gen && !theirs.present && mine.present);
                    if take {
                        self.entries.insert(id.clone(), theirs.clone());
                    }
                }
            }
        }
    }

    /// The relays currently usable for discovery (present entries only).
    pub fn live(&self) -> Vec<&RelayEntry> {
        let mut v: Vec<&RelayEntry> = self.entries.values().filter(|e| e.present).collect();
        v.sort_by(|a, b| a.node_hex.cmp(&b.node_hex));
        v
    }

    /// Record a removal as an explicit tombstone at a strictly higher generation. Removing an
    /// unknown relay still writes a tombstone, so the removal wins if the entry arrives later.
    pub fn remove(&mut self, node_hex: &str) {
        let gen = self.entries.get(node_hex).map(|e| e.gen + 1).unwrap_or(1);
        let e = self.entries.entry(node_hex.to_string()).or_insert_with(|| RelayEntry {
            node_hex: node_hex.to_string(),
            http: String::new(),
            label: String::new(),
            present: true,
            gen: 0,
        });
        e.present = false;
        e.gen = gen;
    }

    /// Add or update a relay, bumping its generation so the change wins over what peers hold.
    pub fn upsert(&mut self, node_hex: &str, http: &str, label: &str) {
        let gen = self.entries.get(node_hex).map(|e| e.gen + 1).unwrap_or(1);
        self.entries.insert(
            node_hex.to_string(),
            RelayEntry {
                node_hex: node_hex.to_string(),
                http: http.to_string(),
                label: label.to_string(),
                present: true,
                gen,
            },
        );
    }
}

// ───────────────────────────── client: publish / resolve over HTTP ─────────────────────────────

/// Configuration for relay-served discovery. **Default is OFF** — an all-default `HavenNode`
/// behaves exactly as it does today (n0 preset only), so this can merge to `main` without changing
/// a single shipped byte of behavior.
#[derive(Clone, Debug, Default)]
pub struct DiscoveryConfig {
    /// Master switch. Off = this module is inert.
    pub enabled: bool,
    /// Relays to publish to and resolve from, as `host:port` (plain-HTTP interface).
    pub relays: Vec<String>,
    /// The shared relay secret folded into request signatures (see `httprelay`). Empty = none.
    pub token: String,
    /// Node secret used to SIGN read requests. The relay authenticates every request, so a lookup
    /// needs one; it is `Option` because a caller may hold a config before an identity is loaded,
    /// and an unsigned lookup must degrade to "no answer", never to an unauthenticated read.
    pub read_key: Option<[u8; 32]>,
}

/// Minimal HTTP/1.1 request against a relay's plain-HTTP interface.
///
/// haven-net has no HTTP client dependency (platforms do their own HTTP and only borrow
/// `httprelay::auth_header` from Rust), and adding one for two verbs is not worth the supply-chain
/// surface. Bounded read, single request, no keep-alive, no redirects.
async fn http_req(
    base: &str,
    method: &str,
    path: &str,
    auth: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>)> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let stream = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::net::TcpStream::connect(base),
    )
    .await
    .map_err(|_| anyhow!("connect timeout to {base}"))??;
    let (r, mut w) = stream.into_split();
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {base}\r\nAuthorization: {auth}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    w.write_all(head.as_bytes()).await?;
    if !body.is_empty() {
        w.write_all(body).await?;
    }
    w.flush().await?;

    let mut buf = Vec::new();
    // Bounded: a discovery answer is a few hundred bytes; anything huge is a misbehaving peer.
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::io::AsyncReadExt::take(r, 64 * 1024).read_to_end(&mut buf),
    )
    .await
    .map_err(|_| anyhow!("read timeout from {base}"))??;

    let split = buf.windows(4).position(|w| w == b"\r\n\r\n").ok_or_else(|| anyhow!("no header end"))?;
    let head = String::from_utf8_lossy(&buf[..split]).to_string();
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| anyhow!("no status"))?;
    Ok((status, buf[split + 4..].to_vec()))
}

/// Publish `rec` (signed with `node_secret`) to every configured relay. Best-effort: returns how
/// many relays accepted it. A relay that refuses or is unreachable is simply not counted — a
/// discovery publish must never be able to fail a node's startup.
pub async fn publish(cfg: &DiscoveryConfig, node_secret: &[u8; 32], rec: &AddrRecord) -> usize {
    if !cfg.enabled {
        return 0;
    }
    let Ok(body) = rec.sign(node_secret) else { return 0 };
    let key = format!("{DISCOVERY_PREFIX}{}", rec.node_hex());
    let path = format!("/k/{key}");
    let mut ok = 0usize;
    for base in &cfg.relays {
        let auth = crate::httprelay::auth_header(node_secret, &cfg.token, "PUT", &key, &body);
        if let Ok((200, _)) = http_req(base, "PUT", &path, &auth, &body).await {
            ok += 1;
        }
    }
    ok
}

/// Ask every configured relay for `node_hex` and return the first record that **verifies** and is
/// not expired.
///
/// Every answer is checked against the node id we asked for, so it does not matter which relay
/// replied or whether it is honest: a wrong or forged body is indistinguishable from no answer.
/// A 404 means "this relay doesn't know" — never "this node has no address" (see module docs).
pub async fn resolve(cfg: &DiscoveryConfig, node_hex: &str) -> Option<AddrRecord> {
    if !cfg.enabled || unhex32(node_hex).is_none() {
        return None;
    }
    let key = format!("{DISCOVERY_PREFIX}{node_hex}");
    let path = format!("/k/{key}");
    for base in &cfg.relays {
        // Reads are signed too (the relay authenticates every request), but a resolver may not have
        // a node secret handy for a bare lookup; callers that do pass one via `resolve_signed`.
        let auth = cfg.read_auth(&key);
        let Ok((status, body)) = http_req(base, "GET", &path, &auth, b"").await else { continue };
        if status != 200 {
            continue;
        }
        if let Some(rec) = AddrRecord::verify(node_hex, &body) {
            if !rec.is_expired() {
                return Some(rec);
            }
        }
        // A relay that served a record failing verification is actively misbehaving. Keep going —
        // another relay, or n0's lookup, may still have the truth. Never adopt the bad answer.
    }
    None
}

impl DiscoveryConfig {
    /// Signing key used for read requests, if the caller installed one.
    fn read_auth(&self, key: &str) -> String {
        match &self.read_key {
            Some(sk) => crate::httprelay::auth_header(sk, &self.token, "GET", key, b""),
            None => String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;

    fn key(seed: u8) -> ([u8; 32], [u8; 32]) {
        let sk = SigningKey::from_bytes(&[seed; 32]);
        (sk.to_bytes(), *sk.verifying_key().as_bytes())
    }

    #[test]
    fn round_trips() {
        let (sec, pubk) = key(1);
        let rec = AddrRecord::new(pubk, 7, vec!["relay:https://r.example".into(), "ip:1.2.3.4:9".into()]);
        let wire = rec.sign(&sec).unwrap();
        let got = AddrRecord::verify(&hex(&pubk), &wire).expect("verifies");
        assert_eq!(got, rec);
    }

    #[test]
    fn refuses_signing_for_another_node() {
        let (sec, _) = key(1);
        let (_, other) = key(2);
        assert!(AddrRecord::new(other, 1, vec!["ip:1.2.3.4:9".into()]).sign(&sec).is_err());
    }

    /// The core impersonation defense: a relay serving Bob's valid record under Carol's key.
    #[test]
    fn refuses_record_shelved_under_the_wrong_key() {
        let (sec, bob) = key(1);
        let (_, carol) = key(2);
        let wire = AddrRecord::new(bob, 1, vec!["ip:1.2.3.4:9".into()]).sign(&sec).unwrap();
        assert!(AddrRecord::verify(&hex(&bob), &wire).is_some());
        assert!(AddrRecord::verify(&hex(&carol), &wire).is_none());
    }

    #[test]
    fn refuses_tampered_address() {
        let (sec, pubk) = key(3);
        let mut wire = AddrRecord::new(pubk, 1, vec!["ip:1.2.3.4:9999".into()]).sign(&sec).unwrap();
        // Flip a byte inside the address text; the signature must stop verifying.
        let pos = wire.windows(4).position(|w| w == b"1.2.").unwrap();
        wire[pos] = b'9';
        assert!(AddrRecord::verify(&hex(&pubk), &wire).is_none());
    }

    #[test]
    fn refuses_trailing_garbage() {
        let (sec, pubk) = key(4);
        let wire = AddrRecord::new(pubk, 1, vec!["ip:1.2.3.4:9".into()]).sign(&sec).unwrap();
        let mut padded = wire[..wire.len() - 64].to_vec();
        padded.push(0);
        padded.extend_from_slice(&wire[wire.len() - 64..]);
        assert!(AddrRecord::verify(&hex(&pubk), &padded).is_none());
    }

    #[test]
    fn refuses_truncated_and_oversize() {
        let (sec, pubk) = key(5);
        let wire = AddrRecord::new(pubk, 1, vec!["ip:1.2.3.4:9".into()]).sign(&sec).unwrap();
        assert!(AddrRecord::verify(&hex(&pubk), &wire[..wire.len() - 1]).is_none());
        assert!(AddrRecord::verify(&hex(&pubk), &vec![0u8; MAX_RECORD + 1]).is_none());
        assert!(AddrRecord::new(pubk, 1, vec!["x".repeat(MAX_ADDR_LEN + 1)]).sign(&sec).is_err());
        assert!(AddrRecord::new(pubk, 1, vec!["a".into(); MAX_ADDRS + 1]).sign(&sec).is_err());
    }

    #[test]
    fn expiry_is_observable() {
        let (_, pubk) = key(6);
        let mut rec = AddrRecord::new(pubk, 1, vec![]);
        assert!(!rec.is_expired());
        rec.expires = 1;
        assert!(rec.is_expired());
    }

    #[test]
    fn discovery_node_rejects_enumeration_and_traversal() {
        let n = "a".repeat(64);
        assert_eq!(discovery_node(&format!("{DISCOVERY_PREFIX}{n}")), Some(n.as_str()));
        assert!(discovery_node(DISCOVERY_PREFIX).is_none());
        assert!(discovery_node(&format!("{DISCOVERY_PREFIX}{n}/sub")).is_none());
        assert!(discovery_node(&format!("{DISCOVERY_PREFIX}../etc")).is_none());
        assert!(discovery_node("haven/mailbox/x").is_none());
        assert!(discovery_node(&format!("{DISCOVERY_PREFIX}zz{}", "a".repeat(62))).is_none());
    }

    // ---- RelayBook: the absence-is-not-deletion rules ----

    fn book(pairs: &[(&str, bool, u64)]) -> RelayBook {
        let mut b = RelayBook::default();
        for (id, present, gen) in pairs {
            b.entries.insert(
                (*id).into(),
                RelayEntry {
                    node_hex: (*id).into(),
                    http: "h:8674".into(),
                    label: String::new(),
                    present: *present,
                    gen: *gen,
                },
            );
        }
        b
    }

    #[test]
    fn merge_never_deletes_by_absence() {
        let mut mine = book(&[("a", true, 1), ("b", true, 1)]);
        mine.merge(&book(&[("a", true, 1)])); // peer has never heard of "b"
        assert!(mine.entries.contains_key("b"), "absence must not remove a known relay");
        assert_eq!(mine.live().len(), 2);
    }

    #[test]
    fn tombstone_propagates_and_beats_a_tie() {
        let mut mine = book(&[("a", true, 3)]);
        mine.merge(&book(&[("a", false, 3)])); // same generation, explicit removal
        assert!(!mine.entries["a"].present, "a tombstone must win a generation tie");

        // …and a stale live entry must not resurrect it.
        mine.merge(&book(&[("a", true, 2)]));
        assert!(!mine.entries["a"].present, "an older live entry must not resurrect a removal");
    }

    #[test]
    fn newer_generation_wins_both_ways() {
        let mut mine = book(&[("a", false, 1)]);
        mine.merge(&book(&[("a", true, 2)])); // deliberate re-add at a higher generation
        assert!(mine.entries["a"].present);
    }

    #[test]
    fn remove_of_unknown_relay_still_tombstones() {
        let mut b = RelayBook::default();
        b.remove("ghost");
        assert_eq!(b.entries["ghost"].present, false);
        // The entry arriving later at gen 1 must not win over our gen-1 tombstone.
        b.merge(&book(&[("ghost", true, 1)]));
        assert!(!b.entries["ghost"].present);
    }

    #[test]
    fn upsert_bumps_generation_so_the_change_wins() {
        let mut b = RelayBook::default();
        b.upsert("a", "h:8674", "home");
        let g1 = b.entries["a"].gen;
        b.upsert("a", "h2:8674", "home2");
        assert!(b.entries["a"].gen > g1);
        assert_eq!(b.entries["a"].http, "h2:8674");
    }

    #[test]
    fn disabled_config_is_inert() {
        let cfg = DiscoveryConfig::default();
        assert!(!cfg.enabled);
        let (sec, pubk) = key(9);
        let rec = AddrRecord::new(pubk, 1, vec![]);
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        assert_eq!(rt.block_on(publish(&cfg, &sec, &rec)), 0);
        assert!(rt.block_on(resolve(&cfg, &hex(&pubk))).is_none());
    }
}
