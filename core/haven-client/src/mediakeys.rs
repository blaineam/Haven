//! Per-item media keys between devices of ONE account (docs/DECISIONS.md D27).
//!
//! WHY. A blob is never re-sealed, and the circle keys that open an old one are deleted
//! everywhere after a few rotations. A phone or computer still opens it with the account key; a
//! linked browser never holds that key, so everything posted before it was linked, past the last
//! few keys, would stay shut. What it CAN be given is that one blob's own content key. A device
//! with the account key unwraps it from the blob's last few kilobytes and sends it, signed by the
//! account and sealed to the browser alone. The browser then reads the blob from the relay like
//! any other. Nothing is uploaded again, and a blob posted after the link needs none of this: it
//! is sealed to the browser's own device key.
//!
//!   NEW device (target)                              OLD device (source, holds the account key)
//!   PUT  media-keys-req/<me>             ────▶       lists every blob its posts name, newest first,
//!   GET  media-keys-m/<me>/<source>      ◀────       reads the end of each from the relay and
//!   GET  media-keys/<me>/<source>/<run>/<n>          uploads the keys in sealed batches
//!
//! On the account lane (`haven/self/<account>/…`). A batch is opaque to the relay: it learns how
//! many keys it holds, which its size gives away.

use serde::{Deserialize, Serialize};

use super::*;

/// Blobs per batch.
pub const KEY_BATCH: usize = 40;
/// Batches a source works through per pass.
const BATCHES_PER_PASS: u32 = 5;
/// The closing bytes asked for first: the signature and the recipient entries of about fifty
/// accounts and devices.
pub const TAIL_BYTES: usize = 64 * 1024;
const RENUDGE_MS: u64 = 10 * 60 * 1000;
const SLOW_RENUDGE_MS: u64 = 6 * 3_600_000;
const SLOW_AFTER_MS: u64 = 3_600_000;
const ABANDONED_JOB_MS: u64 = 3 * 24 * 3_600_000;

fn lane(acct: &str) -> String {
    format!("haven/self/{}/", acct.to_lowercase())
}
pub fn request_prefix(acct: &str) -> String {
    format!("{}media-keys-req/", lane(acct))
}
pub fn request_key(acct: &str, target: &str) -> String {
    format!("{}{}", request_prefix(acct), target.to_lowercase())
}
pub fn manifest_prefix(acct: &str, target: &str) -> String {
    format!("{}media-keys-m/{}/", lane(acct), target.to_lowercase())
}
pub fn manifest_key(acct: &str, target: &str, source: &str) -> String {
    format!("{}{}", manifest_prefix(acct, target), source.to_lowercase())
}
pub fn batch_key(acct: &str, target: &str, source: &str, run: &str, n: u32) -> String {
    format!("{}media-keys/{}/{}/{run}/{n}", lane(acct), target.to_lowercase(), source.to_lowercase())
}

/// The ask.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Request {
    pub v: u32,
    pub device: String,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub done: Option<bool>,
}

/// A source's progress.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub v: u32,
    pub run: String,
    pub source: String,
    pub for_request: u64,
    pub batches: u32,
    pub complete: bool,
    pub updated_at: u64,
    /// Blobs the source's posts name, how many it has been through, and how many of those had
    /// no key to give (not on any relay, or sealed without the account).
    pub total: u32,
    pub done: u32,
    pub missing: u32,
}

impl Manifest {
    fn is_live(&self, now: u64) -> bool {
        self.complete || now.saturating_sub(self.updated_at) < historyhandoff::STALE_SOURCE_MS
    }
}

/// TARGET: the ask and how far its answer has been read. Persisted in the prefs.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct KeyWant {
    pub account: String,
    pub at: u64,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub run: String,
    #[serde(default)]
    pub next_batch: u32,
    #[serde(default)]
    pub total: u32,
    #[serde(default)]
    pub done: u32,
    #[serde(default)]
    pub complete: bool,
    #[serde(default)]
    pub last_nudge_at: u64,
}

/// SOURCE: one job for one of my devices. Persisted in the prefs.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct KeyJob {
    pub request_at: u64,
    pub run: String,
    /// `(circle, ref)` still to go, in reverse: the next one is at the end.
    #[serde(default)]
    pub left: Vec<(String, String)>,
    #[serde(default)]
    pub total: u32,
    #[serde(default)]
    pub missing: u32,
    #[serde(default)]
    pub batches: u32,
    #[serde(default)]
    pub complete: bool,
}

/// What looking for one blob's key came to.
enum Found {
    Key(Vec<u8>),
    /// Every destination answered and none gave a key for it.
    Missing,
    /// Something did not answer: try again later rather than give the blob up.
    Unreachable,
}

impl Engine {
    /// TARGET: make sure the ask exists. A browser linked before this existed gets one too.
    fn ensure_key_want(&self) -> Option<KeyWant> {
        if !self.wants_history_handoff() {
            return None;
        }
        let acct = self.node_id_hex().to_lowercase();
        if acct.is_empty() {
            return None;
        }
        let mut p = self.prefs.lock();
        if !p.media_key_want.as_ref().is_some_and(|w| w.account == acct) {
            p.media_key_want = Some(KeyWant { account: acct, at: now_ms(), ..Default::default() });
            let _ = p.save(&self.paths);
        }
        p.media_key_want.clone()
    }

    /// Write the cursor back, unless a newer ask has replaced this one.
    fn save_key_want(&self, w: &KeyWant) {
        let mut p = self.prefs.lock();
        if let Some(cur) = p.media_key_want.as_mut().filter(|c| c.at == w.at) {
            *cur = w.clone();
            let _ = p.save(&self.paths);
        }
    }

    async fn key_announce(self: &Arc<Self>, w: &mut KeyWant) {
        let now = now_ms();
        let every = if now.saturating_sub(w.at) > SLOW_AFTER_MS { SLOW_RENUDGE_MS } else { RENUDGE_MS };
        if w.last_nudge_at != 0 && now.saturating_sub(w.last_nudge_at) < every {
            return;
        }
        let me = self.social.my_device_node_hex().to_lowercase();
        let req = Request { v: 1, device: me.clone(), at: w.at, done: None };
        let Ok(body) = serde_json::to_vec(&req) else { return };
        if !self.lane_put(&request_key(&w.account, &me), &body).await {
            return;
        }
        w.last_nudge_at = now;
        self.save_key_want(w);
        for d in self.social.device_node_ids_for(w.account.clone()) {
            let d = d.to_lowercase();
            if d != me && d != w.account {
                self.send_frame_direct(wire::HISTORY_NUDGE, me.as_bytes(), &d);
            }
        }
    }

    /// TARGET: take in every batch that is up. All of them at once, not as the reader scrolls: a
    /// batch is a few kilobytes of keys, and the blobs themselves are still fetched on demand.
    /// True if any key was new.
    pub async fn media_keys_pull(self: &Arc<Self>) -> bool {
        let Some(mut w) = self.ensure_key_want() else { return false };
        if w.complete {
            return false;
        }
        if self.media_keys_pulling.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        let _guard = Busy(&self.media_keys_pulling);
        let me = self.social.my_device_node_hex().to_lowercase();
        let now = now_ms();
        let mut found: Vec<Manifest> = Vec::new();
        for key in self.lane_list(&manifest_prefix(&w.account, &me)).await {
            if let Some(m) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Manifest>(&b).ok()) {
                if m.for_request >= w.at {
                    found.push(m);
                }
            }
        }
        let current = found.iter().find(|m| m.source == w.source && m.run == w.run && m.is_live(now));
        let Some(m) = current
            .or_else(|| found.iter().filter(|m| m.is_live(now)).max_by_key(|m| (m.complete, m.batches)))
            .cloned()
        else {
            self.key_announce(&mut w).await;
            return false;
        };
        if w.run != m.run || w.source != m.source {
            w.run = m.run.clone();
            w.source = m.source.clone();
            w.next_batch = 0;
        }
        w.total = m.total;
        w.done = m.done;
        let mut added = 0u32;
        while w.next_batch < m.batches {
            let key = batch_key(&w.account, &me, &m.source, &m.run, w.next_batch);
            let Some(grant) = self.lane_get(&key).await else { break };
            let n = self.social.receive_item_keys(grant);
            if n > 0 {
                added += n;
                // The keys are on disk before the cursor that says they were read.
                self.persist();
            }
            w.next_batch += 1;
            self.save_key_want(&w);
        }
        if m.complete && w.next_batch >= m.batches {
            w.complete = true;
            let done = Request { v: 1, device: me.clone(), at: w.at, done: Some(true) };
            if let Ok(body) = serde_json::to_vec(&done) {
                self.lane_put(&request_key(&w.account, &me), &body).await;
            }
            log::info!("media keys: complete, {} blobs listed, {} without a key", m.total, m.missing);
        }
        self.save_key_want(&w);
        if added > 0 {
            self.retry_media_after_new_keys();
            self.emit_changed();
        }
        added > 0
    }

    /// SOURCE: answer open requests from my other devices. Only a device that holds the account
    /// key can: it is what opens a recipient entry and what signs a batch. True if anything was
    /// uploaded.
    pub async fn media_keys_serve(self: &Arc<Self>) -> bool {
        if self.is_seedless() {
            return false;
        }
        let acct = self.node_id_hex().to_lowercase();
        if acct.is_empty() || self.social.circles().is_empty() {
            return false;
        }
        if self.media_keys_serving.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        let _guard = Busy(&self.media_keys_serving);
        let me = self.social.my_device_node_hex().to_lowercase();
        let mine: Vec<String> =
            self.social.device_node_ids_for(acct.clone()).into_iter().map(|d| d.to_lowercase()).collect();
        let now = now_ms();
        {
            let mut p = self.prefs.lock();
            let before = p.media_key_jobs.len();
            p.media_key_jobs
                .retain(|_, j| j.run.parse::<u64>().unwrap_or(0) > now.saturating_sub(ABANDONED_JOB_MS));
            if p.media_key_jobs.len() != before {
                let _ = p.save(&self.paths);
            }
        }
        let mut did = false;
        for key in self.lane_list(&request_prefix(&acct)).await {
            let device = key.rsplit('/').next().unwrap_or("").to_lowercase();
            // Only a device the account's own signed roster lists (the core refuses to seal to
            // any other as well).
            if device.len() != 64 || device == me || !mine.contains(&device) {
                continue;
            }
            let Some(req) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Request>(&b).ok()) else {
                continue;
            };
            if req.done == Some(true) {
                let mut p = self.prefs.lock();
                if p.media_key_jobs.remove(&device).is_some() {
                    let _ = p.save(&self.paths);
                }
                continue;
            }
            let job = self.prefs.lock().media_key_jobs.get(&device).cloned().filter(|j| j.request_at == req.at);
            let mut job = match job {
                Some(j) => j,
                None => {
                    if self.another_source_sends_keys(&acct, &device, req.at, &me).await {
                        continue;
                    }
                    let mut left: Vec<(String, String)> = self
                        .social
                        .history_media_refs(now_ms())
                        .into_iter()
                        .map(|r| (r.circle_id, r.reference))
                        .collect();
                    left.reverse();
                    log::info!("media keys: one of my devices asked, {} blobs", left.len());
                    KeyJob {
                        request_at: req.at,
                        run: now_ms().to_string(),
                        total: left.len() as u32,
                        left,
                        ..Default::default()
                    }
                }
            };
            if job.complete {
                continue;
            }
            did |= self.run_key_job(&mut job, &acct, &device, &me).await;
            let mut p = self.prefs.lock();
            p.media_key_jobs.insert(device, job);
            let _ = p.save(&self.paths);
        }
        did
    }

    async fn another_source_sends_keys(self: &Arc<Self>, acct: &str, target: &str, request: u64, me: &str) -> bool {
        let now = now_ms();
        for key in self.lane_list(&manifest_prefix(acct, target)).await {
            let Some(m) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Manifest>(&b).ok()) else {
                continue;
            };
            if m.source.to_lowercase() != me && m.for_request >= request && m.is_live(now) {
                return true;
            }
        }
        false
    }

    async fn run_key_job(self: &Arc<Self>, job: &mut KeyJob, acct: &str, device: &str, me: &str) -> bool {
        let mut did = false;
        for _ in 0..BATCHES_PER_PASS {
            if job.left.is_empty() {
                break;
            }
            let take = KEY_BATCH.min(job.left.len());
            let mut entries = Vec::new();
            let mut missing = 0;
            for (circle, reference) in job.left[job.left.len() - take..].iter().rev() {
                match self.find_item_key(circle, reference).await {
                    Found::Key(k) => entries.push(k),
                    Found::Missing => missing += 1,
                    // Leave the whole batch for a pass that can reach the relay.
                    Found::Unreachable => {
                        self.put_key_manifest(job, acct, device, me).await;
                        return did;
                    }
                }
            }
            if !entries.is_empty() {
                let Some(grant) = self.social.seal_item_keys(device.to_string(), entries) else {
                    log::warn!("media keys: could not seal a batch to that device");
                    return did;
                };
                if !self.lane_put(&batch_key(acct, device, me, &job.run, job.batches), &grant).await {
                    return did;
                }
                job.batches += 1;
            }
            job.left.truncate(job.left.len() - take);
            job.missing += missing;
            did = true;
            self.put_key_manifest(job, acct, device, me).await;
        }
        if job.left.is_empty() && !job.complete {
            job.complete = true;
            self.put_key_manifest(job, acct, device, me).await;
            log::info!("media keys: sent, {} blobs, {} without a key", job.total, job.missing);
            did = true;
        }
        did
    }

    async fn put_key_manifest(self: &Arc<Self>, job: &KeyJob, acct: &str, device: &str, me: &str) {
        let m = Manifest {
            v: 1,
            run: job.run.clone(),
            source: me.to_string(),
            for_request: job.request_at,
            batches: job.batches,
            complete: job.complete,
            updated_at: now_ms(),
            total: job.total,
            done: job.total.saturating_sub(job.left.len() as u32),
            missing: job.missing,
        };
        if let Ok(body) = serde_json::to_vec(&m) {
            self.lane_put(&manifest_key(acct, device, me), &body).await;
        }
    }

    /// One blob's key, from whichever destination holds the blob, reading as little of it as the
    /// destination allows.
    async fn find_item_key(self: &Arc<Self>, circle_id: &str, reference: &str) -> Found {
        let mut unreachable = false;
        if let Some(s3) = self.s3_client().await {
            let key = Self::media_key(reference);
            match s3.get(&key).await {
                Ok(Some(head)) => {
                    let sealed = match Self::parse_manifest(&head) {
                        Some(count) => {
                            let last = s3.get(&Self::media_chunk_key(reference, count - 1)).await.ok().flatten();
                            let before = match count.checked_sub(2) {
                                Some(i) => s3.get(&Self::media_chunk_key(reference, i)).await.ok().flatten(),
                                None => None,
                            };
                            last.map(|l| join_tail(before, l))
                        }
                        None => Some(head),
                    };
                    if let Some(k) = sealed.and_then(|b| self.social.item_key_from_tail(b)) {
                        return Found::Key(k);
                    }
                }
                Ok(None) => {}
                Err(_) => unreachable = true,
            }
        }
        for node_hex in self.media_dests(circle_id) {
            if node_hex.starts_with("s3:") {
                continue;
            }
            let Some((urls, token)) = self.relay_http_reachable(&node_hex) else {
                // No HTTP front door: the iroh lane reads whole blobs.
                if let Some(client) = self.relay_client_for(&node_hex).await {
                    if let Some(k) = self.item_key_over_iroh(&client, reference).await {
                        return Found::Key(k);
                    }
                }
                continue;
            };
            let mut answered = false;
            for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                match self.item_key_over_http(base, &token, reference).await {
                    Ok(Some(k)) => return Found::Key(k),
                    Ok(None) => {
                        answered = true;
                        break;
                    }
                    Err(RelayErr::Forbidden) => {
                        self.note_refused(&node_hex, "media key read");
                    }
                    Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                }
            }
            unreachable |= !answered;
        }
        if unreachable {
            Found::Unreachable
        } else {
            Found::Missing
        }
    }

    async fn item_key_over_iroh(self: &Arc<Self>, client: &RelayClient, reference: &str) -> Option<Vec<u8>> {
        let head = client.get(Self::media_key(reference)).await?;
        let sealed = match Self::parse_manifest(&head) {
            Some(count) => {
                let last = client.get(Self::media_chunk_key(reference, count - 1)).await?;
                let before = match count.checked_sub(2) {
                    Some(i) => client.get(Self::media_chunk_key(reference, i)).await,
                    None => None,
                };
                join_tail(before, last)
            }
            None => head,
        };
        self.social.item_key_from_tail(sealed)
    }

    /// `Ok(None)`: the relay answered and has no key to give for this blob.
    async fn item_key_over_http(
        self: &Arc<Self>,
        base: &str,
        token: &str,
        reference: &str,
    ) -> Result<Option<Vec<u8>>, RelayErr> {
        let Some((head, mut partial)) = self.http_get_tail(base, token, &Self::media_key(reference)).await? else {
            return Ok(None);
        };
        let chunks = Self::parse_manifest(&head);
        let tail = match chunks {
            Some(count) => {
                let key = Self::media_chunk_key(reference, count - 1);
                let Some((last, cut)) = self.http_get_tail(base, token, &key).await? else { return Ok(None) };
                partial = cut;
                if last.len() >= TAIL_BYTES || count < 2 {
                    last
                } else {
                    // A short last chunk: the entries run back into the one before it.
                    let key = Self::media_chunk_key(reference, count - 2);
                    let Some((before, cut)) = self.http_get_tail(base, token, &key).await? else { return Ok(None) };
                    partial |= cut;
                    join_tail(Some(before), last)
                }
            }
            None => head,
        };
        if let Some(k) = self.social.item_key_from_tail(tail) {
            return Ok(Some(k));
        }
        if !partial {
            return Ok(None);
        }
        // More recipients than the tail holds, or an old JSON envelope: read it whole.
        let whole = match chunks {
            Some(count) => {
                let mut all = Vec::new();
                for i in 0..count {
                    let Some(c) = self.http_get(base, token, &Self::media_chunk_key(reference, i)).await? else {
                        return Ok(None);
                    };
                    all.extend_from_slice(&c);
                }
                all
            }
            None => match self.http_get(base, token, &Self::media_key(reference)).await? {
                Some(b) => b,
                None => return Ok(None),
            },
        };
        Ok(self.social.item_key_from_tail(whole))
    }
}

/// The end of a chunked blob: the end of the chunk before the last, then the last.
fn join_tail(before: Option<Vec<u8>>, last: Vec<u8>) -> Vec<u8> {
    match before {
        Some(b) if last.len() < TAIL_BYTES => {
            let from = b.len().saturating_sub(TAIL_BYTES - last.len());
            let mut out = b[from..].to_vec();
            out.extend_from_slice(&last);
            out
        }
        _ => last,
    }
}

/// Clears a "one pass at a time" flag however the pass ends.
struct Busy<'a>(&'a std::sync::atomic::AtomicBool);
impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tail_of_a_chunked_blob_spans_a_short_last_chunk() {
        let before = vec![1u8; TAIL_BYTES * 2];
        let joined = join_tail(Some(before), vec![2u8; 100]);
        assert_eq!(joined.len(), TAIL_BYTES);
        assert!(joined[..TAIL_BYTES - 100].iter().all(|b| *b == 1));
        assert!(joined[TAIL_BYTES - 100..].iter().all(|b| *b == 2));
        // A last chunk that already holds a whole tail needs nothing from the one before.
        assert_eq!(join_tail(Some(vec![1; 10]), vec![2; TAIL_BYTES]).len(), TAIL_BYTES);
        assert_eq!(join_tail(None, vec![2; 5]), vec![2; 5]);
    }

    #[test]
    fn the_keys_live_on_the_account_lane() {
        let a = "AB".repeat(32);
        for k in [request_key(&a, "CD"), manifest_key(&a, "CD", "EF"), batch_key(&a, "CD", "EF", "7", 3)] {
            assert!(k.starts_with(&format!("haven/self/{}/media-keys", "ab".repeat(32))), "{k}");
        }
    }
}
