//! "Load history from your relays" — the deep mailbox resync, shared by every client.
//!
//! The normal mailbox poll decides what to fetch from the persisted SEEN-set, and "seen" means
//! "processed once", not "in my feed". A key is marked seen when its envelope applied, but also when
//! it was a duplicate, when it only PARKED (waiting for a key commit or a roster), and — on some
//! paths — when it failed to open at all. Parked envelopes live in a 512-slot buffer that evicts the
//! oldest, unopenable fossils are GC'd from it, and older builds marked keys seen before the engine
//! state holding their events was saved. Every one of those leaves a post sitting on the relay that
//! this device will never look at again. The re-open after a key commit (a damped seen-wipe) is the
//! only way back, and the desktop has it switched off.
//!
//! This module is the planner for a user-triggered pass that ignores the seen-set:
//!
//! * [`RelayHistoryPlanner::plan`] — of a circle's FULL relay listing, the content keys this device
//!   has not provably ingested (its own journal, not the seen-set), minus the routed lanes (hellos,
//!   relay announces, live-call frames) that are not history.
//! * [`RelayHistoryPlanner::ingest`] — runs a fetched batch through the ordinary `receive`, control
//!   envelopes first (rosters, key commits, tree wires, then events), and classifies each with
//!   [`HavenSocial::receive_status`]. Applied / already-held / provably-unreadable keys are STAGED
//!   as ingested; parked and not-yet-applicable control keys come back as `retry` for a second pass
//!   once every circle's control plane has landed.
//! * [`RelayHistoryPlanner::commit_staged`] — the client calls it only after the engine state that
//!   holds those events is on disk (the mailbox's mark-after-persist invariant), which appends the
//!   staged keys to the journal. A kill before that re-fetches the batch next run; `receive` is
//!   idempotent, so nothing is lost or doubled.
//!
//! Nothing here seals, uploads, or notifies: the pass only READS relays and feeds `receive`. The
//! journal stores 16-byte BLAKE3 prefixes of keys (append-only), so a 100k-key account costs ~1.6 MB
//! on disk and a few MB in memory. Cancelling is just stopping between batches; re-running resumes
//! because every committed key is skipped.

use std::collections::HashSet;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::{
    with_recv_ctx, HavenSocial, TAG_ADMIN_GRANT, TAG_CIRCLE_UPGRADE, TAG_DEVICE_ROSTER, TAG_EPOCH_EVENT,
    TAG_KEY_COMMIT, TAG_MLS_COMMIT, TAG_MLS_JOIN, TAG_MLS_PROPOSAL, TAG_MLS_WELCOME,
};

thread_local! {
    /// Set by `receive_epoch_event` / `receive_legacy` when the envelope being received (NOT one a
    /// drain replays inside it) opened to an event this engine already holds.
    static PRIMARY_DUPLICATE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Called from the receive path at the "already have this event" return. Only the top-level
/// envelope counts: a drain inside the same `receive` replays parked envelopes, and their
/// duplicates say nothing about the one being classified. Outside a receive context (the test-only
/// in-place path) depth is unknown, so nothing is recorded.
pub(crate) fn note_primary_duplicate() {
    if with_recv_ctx(|c| c.in_drain == 0).unwrap_or(false) {
        PRIMARY_DUPLICATE.with(|f| f.set(true));
    }
}

/// What `receive` did with one envelope, finer than its bool.
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ReceiveStatus {
    /// Changed state: a new event, a newly learned key, a roster.
    Applied,
    /// An event this engine already holds (arrived live, from a sibling, or an earlier pass).
    Duplicate,
    /// Waiting in the durable pending buffer for its key commit / the sender's roster.
    Parked,
    /// A control envelope that did not change anything right now — a known key re-applied, or one
    /// that cannot be authorized YET. Retryable; never recorded as ingested.
    Unchanged,
    /// Opened to nothing and never will: a malformed envelope, a key that no longer opens it, a
    /// ratchet index past the horizon. Re-fetching the same bytes cannot help.
    Unreadable,
    /// The circle is not on this device (yet). Retryable.
    UnknownCircle,
}

impl HavenSocial {
    fn classify(&self, circle_id: &str, envelope: &[u8], result: Result<bool, crate::HavenError>) -> ReceiveStatus {
        match result {
            Ok(true) => ReceiveStatus::Applied,
            Err(_) => ReceiveStatus::Unreadable,
            Ok(false) => {
                let tag = envelope[0];
                if tag == TAG_EPOCH_EVENT {
                    if PRIMARY_DUPLICATE.with(|f| f.get()) {
                        return ReceiveStatus::Duplicate;
                    }
                    let digest = *blake3::hash(envelope).as_bytes();
                    let mut st = self.state.lock().unwrap();
                    let me_hex = crate::hex(&st.me().node_id_bytes());
                    let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) else {
                        return ReceiveStatus::Unreadable;
                    };
                    let Some(pos) = c.pending_epoch.iter().position(|p| match &p.parsed {
                        Some(q) => q.digest == digest,
                        None => p.raw.as_slice() == &envelope[1..],
                    }) else {
                        return ReceiveStatus::Unreadable;
                    };
                    // A FOSSIL — sealed more than KEEP_EPOCHS behind the newest key this circle holds
                    // for its author — can never open: the commit for its epoch was pruned
                    // everywhere. A deep resync walks a relay's whole backlog, so parking those
                    // would flood the 512-slot evict-oldest buffer and push out envelopes that ARE
                    // about to open (a fresh DM waiting on its commit). Same rule as the fossil GC
                    // in `drain_pending`; it just runs at the door instead of on the next drain.
                    if let Some(parsed) = &c.pending_epoch[pos].parsed {
                        let author = parsed.env.sender_hex();
                        let newest = if author == me_hex {
                            Some(c.my_epoch)
                        } else {
                            c.peer_epoch_keys.keys().filter(|(a, _)| *a == author).map(|(_, e)| *e).max()
                        };
                        if newest.is_some_and(|n| parsed.env.epoch + 4 < n) {
                            c.pending_epoch.remove(pos);
                            return ReceiveStatus::Unreadable;
                        }
                    }
                    return ReceiveStatus::Parked;
                }
                if is_legacy(tag) {
                    return if PRIMARY_DUPLICATE.with(|f| f.get()) {
                        ReceiveStatus::Duplicate
                    } else {
                        ReceiveStatus::Unreadable
                    };
                }
                if tag == TAG_KEY_COMMIT {
                    let st = self.state.lock().unwrap();
                    let parked = st
                        .circles
                        .iter()
                        .find(|c| c.id == circle_id)
                        .is_some_and(|c| c.pending_commit.iter().any(|raw| raw.as_slice() == &envelope[1..]));
                    if parked {
                        return ReceiveStatus::Parked;
                    }
                }
                ReceiveStatus::Unchanged
            }
        }
    }
}

/// Anything that is not one of the binary wire tags is the legacy per-recipient JSON container.
fn is_legacy(tag: u8) -> bool {
    !matches!(
        tag,
        TAG_EPOCH_EVENT
            | TAG_KEY_COMMIT
            | TAG_DEVICE_ROSTER
            | TAG_MLS_COMMIT
            | TAG_MLS_WELCOME
            | TAG_MLS_PROPOSAL
            | TAG_MLS_JOIN
            | TAG_ADMIN_GRANT
            | TAG_CIRCLE_UPGRADE
    )
}

#[uniffi::export]
impl HavenSocial {
    /// `receive`, classified (see [`ReceiveStatus`]). Bypasses the session re-delivery filter so the
    /// answer is about the envelope, not about whether these bytes passed by earlier. Same apply as
    /// `receive` — same parking, same drains — so it is safe to use anywhere `receive` is.
    pub fn receive_status(&self, circle_id: String, envelope: Vec<u8>) -> ReceiveStatus {
        if envelope.is_empty() {
            return ReceiveStatus::Unreadable;
        }
        if !self.state.lock().unwrap().circles.iter().any(|c| c.id == circle_id) {
            return ReceiveStatus::UnknownCircle;
        }
        PRIMARY_DUPLICATE.with(|f| f.set(false));
        let r = self.receive_impl_opts(circle_id.clone(), envelope.clone(), true, true);
        let status = self.classify(&circle_id, &envelope, r);
        PRIMARY_DUPLICATE.with(|f| f.set(false));
        status
    }
}

/// One fetched mailbox entry.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RelayHistoryItem {
    pub key: String,
    pub envelope: Vec<u8>,
}

/// What one [`RelayHistoryPlanner::ingest`] batch did.
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct RelayHistoryBatch {
    pub applied: u32,
    pub duplicate: u32,
    pub parked: u32,
    pub unchanged: u32,
    pub unreadable: u32,
    /// Keys worth one more try after every circle's control plane has landed (parked events,
    /// not-yet-applicable control envelopes, an unknown circle).
    pub retry: Vec<String>,
    /// Keys whose envelope was processed at all — the caller marks these in its mailbox seen-set
    /// (after persisting), exactly as a normal poll would have.
    pub processed: Vec<String>,
}

/// Routed lanes in a circle mailbox that are not history: hello slots, durable relay announces, and
/// live-call frames. A resync never fetches them (hellos belong to their addressee, and the normal
/// poll owns all three).
pub fn is_history_key(circle_id: &str, key: &str) -> bool {
    let prefix = format!("haven/mailbox/{circle_id}/");
    key.starts_with(&prefix)
        && key.len() > prefix.len()
        && !key.contains("/__hello__/")
        && !key.contains("/__relay__/")
        && !key.contains("/__live__/")
}

/// Ingest order: the control plane first — a roster names the devices, a key commit opens an
/// epoch, tree wires drive MLS keying — then events, then anything unrecognised. Stable within a
/// rank, so the caller's order breaks ties.
pub fn ingest_rank(envelope: &[u8]) -> u8 {
    match envelope.first().copied() {
        Some(TAG_DEVICE_ROSTER) => 0,
        Some(TAG_KEY_COMMIT) => 1,
        Some(TAG_MLS_COMMIT) => 2,
        Some(TAG_MLS_WELCOME) => 3,
        Some(TAG_MLS_JOIN) | Some(TAG_MLS_PROPOSAL) => 4,
        Some(TAG_ADMIN_GRANT) | Some(TAG_CIRCLE_UPGRADE) => 5,
        Some(TAG_EPOCH_EVENT) => 6,
        _ => 7,
    }
}

type KeyHash = [u8; 16];

fn key_hash(key: &str) -> KeyHash {
    let h = blake3::hash(key.as_bytes());
    let mut out = [0u8; 16];
    out.copy_from_slice(&h.as_bytes()[..16]);
    out
}

struct Journal {
    ingested: HashSet<KeyHash>,
    staged: Vec<KeyHash>,
}

/// The deep-resync planner + its ingested-key journal. One per account data directory.
#[derive(uniffi::Object)]
pub struct RelayHistoryPlanner {
    path: PathBuf,
    inner: Mutex<Journal>,
}

#[uniffi::export]
impl RelayHistoryPlanner {
    /// Open (or start) the journal at `journal_path`. A torn trailing record from a kill mid-append
    /// is ignored; it is re-learned on the next pass.
    #[uniffi::constructor]
    pub fn new(journal_path: String) -> Arc<Self> {
        let path = PathBuf::from(journal_path);
        let mut ingested = HashSet::new();
        if let Ok(bytes) = std::fs::read(&path) {
            ingested.reserve(bytes.len() / 16);
            for rec in bytes.chunks_exact(16) {
                let mut h = [0u8; 16];
                h.copy_from_slice(rec);
                ingested.insert(h);
            }
        }
        Arc::new(Self { path, inner: Mutex::new(Journal { ingested, staged: Vec::new() }) })
    }

    /// The keys of `listed` (one relay's full LIST of `circle_id`'s mailbox) still worth fetching:
    /// history keys this device has not committed as ingested, deduplicated, in a stable order.
    pub fn plan(&self, circle_id: String, listed: Vec<String>) -> Vec<String> {
        let j = self.inner.lock().unwrap();
        let mut seen = HashSet::new();
        let mut out: Vec<String> = listed
            .into_iter()
            .filter(|k| is_history_key(&circle_id, k))
            .filter(|k| !j.ingested.contains(&key_hash(k)))
            .filter(|k| seen.insert(k.clone()))
            .collect();
        out.sort();
        out
    }

    /// Feed one fetched batch through `receive`, control envelopes first, and classify each.
    /// Applied, duplicate and unreadable keys are STAGED as ingested (see `commit_staged`).
    pub fn ingest(&self, social: Arc<HavenSocial>, circle_id: String, items: Vec<RelayHistoryItem>) -> RelayHistoryBatch {
        let mut items = items;
        items.retain(|i| !i.envelope.is_empty());
        items.sort_by_key(|i| ingest_rank(&i.envelope));
        let mut out = RelayHistoryBatch::default();
        let mut staged = Vec::new();
        for item in items {
            let status = social.receive_status(circle_id.clone(), item.envelope);
            match status {
                ReceiveStatus::Applied => out.applied += 1,
                ReceiveStatus::Duplicate => out.duplicate += 1,
                ReceiveStatus::Parked => out.parked += 1,
                ReceiveStatus::Unchanged | ReceiveStatus::UnknownCircle => out.unchanged += 1,
                ReceiveStatus::Unreadable => out.unreadable += 1,
            }
            match status {
                ReceiveStatus::Applied | ReceiveStatus::Duplicate | ReceiveStatus::Unreadable => {
                    staged.push(key_hash(&item.key));
                }
                ReceiveStatus::Parked | ReceiveStatus::Unchanged | ReceiveStatus::UnknownCircle => {
                    out.retry.push(item.key.clone());
                }
            }
            if status != ReceiveStatus::UnknownCircle {
                out.processed.push(item.key);
            }
        }
        self.inner.lock().unwrap().staged.extend(staged);
        out
    }

    /// Make every staged key durable in the journal. Call ONLY after the engine state holding the
    /// staged batches is saved. Returns false if the append failed (the keys stay staged).
    pub fn commit_staged(&self) -> bool {
        let mut j = self.inner.lock().unwrap();
        if j.staged.is_empty() {
            return true;
        }
        let fresh: Vec<KeyHash> = {
            let mut dedupe = HashSet::new();
            j.staged.iter().copied().filter(|h| !j.ingested.contains(h) && dedupe.insert(*h)).collect()
        };
        if !fresh.is_empty() {
            let mut buf = Vec::with_capacity(fresh.len() * 16);
            for h in &fresh {
                buf.extend_from_slice(h);
            }
            if let Some(dir) = self.path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let ok = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.path)
                .and_then(|mut f| f.write_all(&buf).and_then(|_| f.flush()));
            if ok.is_err() {
                return false;
            }
            j.ingested.extend(fresh);
        }
        j.staged.clear();
        true
    }

    /// Drop staged keys without committing (the engine save failed, or the pass was abandoned).
    pub fn discard_staged(&self) {
        self.inner.lock().unwrap().staged.clear();
    }

    pub fn is_ingested(&self, key: String) -> bool {
        self.inner.lock().unwrap().ingested.contains(&key_hash(&key))
    }

    pub fn ingested_count(&self) -> u64 {
        self.inner.lock().unwrap().ingested.len() as u64
    }

    /// Forget the whole journal (identity reset / QA): the next pass re-checks every relay key.
    pub fn reset(&self) {
        let mut j = self.inner.lock().unwrap();
        j.ingested.clear();
        j.staged.clear();
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DEFAULT_CIRCLE;

    fn tmp(name: &str) -> String {
        let d = std::env::temp_dir().join(format!("haven-rh-{}-{name}", std::process::id()));
        let _ = std::fs::remove_file(&d);
        d.to_string_lossy().into_owned()
    }

    fn mailbox_key(cid: &str, env: &[u8]) -> String {
        format!("haven/mailbox/{cid}/{}", blake3::hash(env).to_hex())
    }

    /// author posts `n` across two epochs; returns (author, reader-knowing-author, envelopes).
    fn fixture(seed: u8, n: u64) -> (Arc<HavenSocial>, Arc<HavenSocial>, Vec<Vec<u8>>) {
        let author = HavenSocial::new(vec![seed; 32]).unwrap();
        let reader = HavenSocial::new(vec![seed.wrapping_add(1); 32]).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        author.add_contact_bundle(cid.clone(), reader.my_bundle()).unwrap();
        reader.add_contact_bundle(cid.clone(), author.my_bundle()).unwrap();
        for i in 0..n {
            if i == n / 2 {
                author.rotate_circle(cid.clone());
            }
            author
                .post(cid.clone(), format!("p{i}"), vec![], None, None, false, false, 1_000 + i)
                .unwrap();
        }
        let envs = author.sync_envelopes(cid);
        (author, reader, envs)
    }

    fn bodies(s: &HavenSocial) -> Vec<String> {
        let mut v: Vec<String> =
            s.feed(DEFAULT_CIRCLE.into(), 10_000, None).into_iter().map(|f| f.body).collect();
        v.sort();
        v
    }

    #[test]
    fn plan_skips_routed_lanes_foreign_prefixes_and_ingested_keys() {
        let p = RelayHistoryPlanner::new(tmp("plan"));
        let c = "circ";
        let listed = vec![
            "haven/mailbox/circ/bbb".to_string(),
            "haven/mailbox/circ/aaa".to_string(),
            "haven/mailbox/circ/aaa".to_string(),
            "haven/mailbox/circ/__hello__/x/y/z".to_string(),
            "haven/mailbox/circ/__relay__/n".to_string(),
            "haven/mailbox/circ/__live__/d/f".to_string(),
            "haven/mailbox/other/ccc".to_string(),
            "haven/mailbox/circ/".to_string(),
        ];
        assert_eq!(p.plan(c.into(), listed.clone()), vec!["haven/mailbox/circ/aaa", "haven/mailbox/circ/bbb"]);
        p.inner.lock().unwrap().staged.push(key_hash("haven/mailbox/circ/aaa"));
        assert!(p.commit_staged());
        assert_eq!(p.plan(c.into(), listed), vec!["haven/mailbox/circ/bbb"]);
    }

    #[test]
    fn control_envelopes_are_ingested_before_events_regardless_of_listing_order() {
        let (_author, reader, envs) = fixture(41, 6);
        let cid = DEFAULT_CIRCLE.to_string();
        // Mailbox order: events FIRST, commits last — the worst case for a naive drain.
        let mut items: Vec<RelayHistoryItem> = envs
            .iter()
            .map(|e| RelayHistoryItem { key: mailbox_key(&cid, e), envelope: e.clone() })
            .collect();
        items.sort_by_key(|i| std::cmp::Reverse(ingest_rank(&i.envelope)));
        let p = RelayHistoryPlanner::new(tmp("order"));
        let b = p.ingest(reader.clone(), cid, items);
        assert_eq!(b.parked, 0, "no event parks when its commit was ingested first: {b:?}");
        assert_eq!(b.applied as usize, envs.len() - b.unchanged as usize, "{b:?}");
        assert_eq!(bodies(&reader).len(), 6);
    }

    #[test]
    fn seen_but_never_ingested_keys_are_recovered_and_held_ones_classify_as_duplicates() {
        let (_author, reader, envs) = fixture(51, 4);
        let cid = DEFAULT_CIRCLE.to_string();
        let events: Vec<&Vec<u8>> = envs.iter().filter(|e| e[0] == TAG_EPOCH_EVENT).collect();
        let control: Vec<&Vec<u8>> = envs.iter().filter(|e| e[0] != TAG_EPOCH_EVENT).collect();
        // The live/normal path delivered events BEFORE their commit — they parked — and then the
        // parked copies were lost (eviction / fossil GC / a pre-fix mark-before-save kill). A normal
        // poll's seen-set now hides them; the commits arrive, but nothing re-offers the events.
        for e in &events {
            let _ = reader.receive(cid.clone(), (*e).clone());
        }
        reader.state.lock().unwrap().circles.iter_mut().for_each(|c| c.pending_epoch.clear());
        for e in &control {
            let _ = reader.receive(cid.clone(), (*e).clone());
        }
        assert!(bodies(&reader).is_empty(), "the gap: nothing opened");
        // Session re-delivery filter would answer `false` for every one of them; the resync must not.
        let p = RelayHistoryPlanner::new(tmp("gap"));
        let items: Vec<RelayHistoryItem> = envs
            .iter()
            .map(|e| RelayHistoryItem { key: mailbox_key(&cid, e), envelope: e.clone() })
            .collect();
        let b = p.ingest(reader.clone(), cid.clone(), items.clone());
        assert_eq!(b.applied as usize, events.len(), "{b:?}");
        assert_eq!(bodies(&reader).len(), 4);
        assert!(p.commit_staged());
        // A second run over the same listing: nothing left to fetch for the events.
        let left = p.plan(cid.clone(), items.iter().map(|i| i.key.clone()).collect());
        assert!(events.iter().all(|e| !left.contains(&mailbox_key(&cid, e))), "{left:?}");
        // And re-feeding an event that IS held reports Duplicate, not Unreadable.
        let again = p.ingest(reader.clone(), cid, vec![RelayHistoryItem { key: "k".into(), envelope: events[0].clone() }]);
        assert_eq!((again.duplicate, again.unreadable), (1, 0), "{again:?}");
    }

    #[test]
    fn events_without_their_commit_park_and_come_back_for_the_retry_pass() {
        let (_author, reader, envs) = fixture(61, 2);
        let cid = DEFAULT_CIRCLE.to_string();
        let p = RelayHistoryPlanner::new(tmp("retry"));
        let events: Vec<RelayHistoryItem> = envs
            .iter()
            .filter(|e| e[0] == TAG_EPOCH_EVENT)
            .map(|e| RelayHistoryItem { key: mailbox_key(&cid, e), envelope: e.clone() })
            .collect();
        let first = p.ingest(reader.clone(), cid.clone(), events.clone());
        assert_eq!(first.parked as usize, events.len(), "{first:?}");
        assert_eq!(first.retry.len(), events.len());
        assert!(p.commit_staged());
        // Parked keys were NOT recorded: the next plan still offers them.
        assert_eq!(p.plan(cid.clone(), first.retry.clone()).len(), events.len());
        // The control plane lands (a later batch / another circle) — the parked events drain on
        // their own, and the retry pass sees them as already held.
        let control: Vec<RelayHistoryItem> = envs
            .iter()
            .filter(|e| e[0] != TAG_EPOCH_EVENT)
            .map(|e| RelayHistoryItem { key: mailbox_key(&cid, e), envelope: e.clone() })
            .collect();
        p.ingest(reader.clone(), cid.clone(), control);
        assert_eq!(bodies(&reader).len(), 2);
        let retry: Vec<RelayHistoryItem> = events.into_iter().filter(|i| first.retry.contains(&i.key)).collect();
        let second = p.ingest(reader, cid.clone(), retry);
        assert_eq!((second.duplicate, second.parked), (2, 0), "{second:?}");
        assert!(p.commit_staged());
        assert!(p.plan(cid, first.retry).is_empty());
    }

    #[test]
    fn staged_keys_survive_only_a_commit_and_the_journal_resumes_across_restarts() {
        let path = tmp("resume");
        let p = RelayHistoryPlanner::new(path.clone());
        p.inner.lock().unwrap().staged.extend([key_hash("haven/mailbox/c/1"), key_hash("haven/mailbox/c/2")]);
        // Cancelled before the engine save: staged keys are dropped, nothing durable.
        p.discard_staged();
        assert_eq!(RelayHistoryPlanner::new(path.clone()).ingested_count(), 0);
        p.inner.lock().unwrap().staged.extend([key_hash("haven/mailbox/c/1"), key_hash("haven/mailbox/c/1")]);
        assert!(p.commit_staged());
        // A torn trailing record (kill mid-append) is ignored.
        std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(&[7u8; 5]).unwrap();
        let reopened = RelayHistoryPlanner::new(path.clone());
        assert_eq!(reopened.ingested_count(), 1);
        assert!(reopened.is_ingested("haven/mailbox/c/1".into()));
        assert_eq!(reopened.plan("c".into(), vec!["haven/mailbox/c/1".into(), "haven/mailbox/c/2".into()]), vec![
            "haven/mailbox/c/2"
        ]);
        reopened.reset();
        assert_eq!(RelayHistoryPlanner::new(path).ingested_count(), 0);
    }

    #[test]
    fn an_old_epoch_fossil_is_unreadable_and_never_floods_the_pending_buffer() {
        let author = HavenSocial::new(vec![81u8; 32]).unwrap();
        let reader = HavenSocial::new(vec![82u8; 32]).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        author.add_contact_bundle(cid.clone(), reader.my_bundle()).unwrap();
        reader.add_contact_bundle(cid.clone(), author.my_bundle()).unwrap();
        // The relay still holds an envelope from long ago…
        let old = author.post(cid.clone(), "ancient".into(), vec![], None, None, false, false, 1_000).unwrap();
        // …and the author has rotated well past the KEEP_EPOCHS window since.
        for _ in 0..6 {
            author.rotate_circle(cid.clone());
        }
        author.post(cid.clone(), "recent".into(), vec![], None, None, false, false, 2_000).unwrap();
        for env in author.sync_envelopes(cid.clone()).into_iter().filter(|e| e[0] != TAG_EPOCH_EVENT) {
            let _ = reader.receive(cid.clone(), env);
        }
        let p = RelayHistoryPlanner::new(tmp("fossil"));
        let b = p.ingest(reader.clone(), cid.clone(), vec![RelayHistoryItem { key: "haven/mailbox/default/old".into(), envelope: old }]);
        assert_eq!((b.unreadable, b.parked), (1, 0), "{b:?}");
        assert!(b.retry.is_empty());
        let pending = reader.state.lock().unwrap().circles.iter().find(|c| c.id == cid).unwrap().pending_epoch.len();
        assert_eq!(pending, 0, "the fossil must not occupy a pending slot");
    }

    #[test]
    fn garbage_is_unreadable_and_recorded_so_it_is_not_refetched_forever() {
        let (_a, reader, _envs) = fixture(71, 1);
        let p = RelayHistoryPlanner::new(tmp("garbage"));
        let b = p.ingest(
            reader,
            DEFAULT_CIRCLE.into(),
            vec![RelayHistoryItem { key: "haven/mailbox/default/zz".into(), envelope: vec![TAG_EPOCH_EVENT, 1, 2, 3] }],
        );
        assert_eq!(b.unreadable, 1, "{b:?}");
        assert!(p.commit_staged());
        assert!(p.is_ingested("haven/mailbox/default/zz".into()));
    }
}
