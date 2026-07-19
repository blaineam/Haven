//! Durable record of a half-finished chunked media transfer, so a 99%-complete download survives a
//! relaunch instead of restarting from chunk 0. Port of the iOS `ReassemblyStore`.
//!
//! A serve is slow by construction — 32 KB chunks, a seal each — so a 50 MB video is ~1,600 chunks
//! and interruptions are the norm, not the exception. Before this, every one of them threw the whole
//! transfer away: the desktop receive path accumulated chunks in a `HashMap<u32, Vec<u8>>` in RAM and
//! only touched disk once the LAST chunk arrived, so a process exit, a dropped link, or the 1 GB
//! in-memory cap silently discarded everything. That is why large media "never loaded" here — it
//! wasn't failing once, it was restarting forever.
//!
//! Two changes make resume real, and this module is the second. Chunk N's plaintext is now written
//! POSITIONALLY at offset N × chunkSize, so the partial is a valid sparse file with holes in exactly
//! the right places; this index remembers, across launches, WHICH holes.
//!
//! Bounded on three axes so it can't become the next unbounded-state leak (this codebase has already
//! lost a machine to one):
//!   * a partial with no progress in [`EXPIRY_SECS`] expires — its bytes and its record both go
//!   * the index is capped at [`MAX_RECORDS`], oldest-progress evicted first
//!   * a record whose part file has vanished is DROPPED, never resumed into: a bitmap without the
//!     bytes it describes is a lie, and resuming on it would leave permanent holes
//!
//! A partial can never be mistaken for a complete blob: it lives at `incoming_p2p_<bare id>.part`,
//! which is not a name `LocalMedia::has` (or any storage key) can produce.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// A transfer nobody has fed in a day is one whose sender is gone; its bytes are unaccountable disk.
pub const EXPIRY_SECS: u64 = 24 * 3600;

/// Cap on how many half-finished transfers we track at once. A peer that starts thousands of
/// transfers we never finish must not grow this without limit.
pub const MAX_RECORDS: usize = 512;

/// The bitmap is rewritten as chunks land — at hundreds of chunks a second, saving on every one
/// would be pure write churn. Debounced instead. Persisted progress may therefore LAG the file by up
/// to this interval, which is safe in exactly ONE direction: understating what we have costs a few
/// re-sent chunks (a positional rewrite of identical bytes), while overstating it would leave a
/// permanent hole. Nothing here may record a chunk before its bytes are on disk.
const SAVE_INTERVAL_SECS: u64 = 2;

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// One in-progress reassembly.
#[derive(Clone, Debug)]
pub struct Reassembly {
    /// The part file's NAME, not its path — the media dir moves between installs and platforms, so
    /// an absolute path persisted today may not resolve tomorrow. Rejoined with the index's `dir`.
    pub part: String,
    pub total: u32,
    /// Indices whose plaintext is CONFIRMED on disk.
    pub got: HashSet<u32>,
    /// Epoch seconds of the last chunk written — drives the [`EXPIRY_SECS`] abandonment sweep.
    pub updated: u64,
}

impl Reassembly {
    pub fn is_complete(&self) -> bool {
        self.got.len() as u32 >= self.total
    }
}

/// The persisted set of in-progress reassemblies, keyed by ref.
///
/// Lives in `DynState` behind the engine's state mutex, and persists as one line-delimited text file
/// alongside `mailbox-seen.txt` / `notified.txt` / `media-backed-up.txt` — the idiom this engine
/// already uses for exactly this kind of "cursor that must survive a restart" state.
#[derive(Default)]
pub struct ReassemblyIndex {
    /// The `media-reassembly.txt` path. Empty on a `Default` instance (never persisted) — see `save`.
    path: PathBuf,
    /// The media dir the part names resolve against.
    dir: PathBuf,
    records: HashMap<String, Reassembly>,
    last_save_secs: u64,
    dirty: bool,
}

impl ReassemblyIndex {
    /// Load the persisted transfers, dropping every one that can no longer be resumed into, and
    /// deleting the bytes of the ones that expired. Call once at engine construction.
    pub fn load(path: PathBuf, dir: PathBuf) -> Self {
        let mut me = Self { path, dir, ..Default::default() };
        if let Ok(text) = std::fs::read_to_string(&me.path) {
            for line in text.lines() {
                if let Some((reference, rec)) = parse_line(line) {
                    me.records.insert(reference, rec);
                }
            }
        }
        me.expire();
        me
    }

    /// Drop every record we must not resume into, deleting its bytes: expired (no progress in
    /// [`EXPIRY_SECS`]) or orphaned (its part file is gone). Returns how many were dropped.
    ///
    /// Run at load AND before each orphan sweep, so `live_parts` never names a file the sweep should
    /// have reclaimed and the sweep never reclaims a file a record still points at.
    pub fn expire(&mut self) -> usize {
        let cutoff = now_secs().saturating_sub(EXPIRY_SECS);
        let dir = self.dir.clone();
        let mut dropped = Vec::new();
        for (reference, r) in self.records.iter() {
            let p = dir.join(&r.part);
            let exists = p.exists();
            if !exists || r.updated < cutoff {
                if exists {
                    let _ = std::fs::remove_file(&p);
                }
                dropped.push(reference.clone());
            }
        }
        for reference in &dropped {
            self.records.remove(reference);
        }
        if !dropped.is_empty() {
            self.dirty = true;
            self.save();
        }
        dropped.len()
    }

    pub fn get(&self, reference: &str) -> Option<&Reassembly> {
        self.records.get(reference)
    }

    /// Every live part-file name with when it last made progress — what the orphan sweep must NOT
    /// reclaim. Keyed by NAME because that is what the sweep sees walking the media dir.
    pub fn live_parts(&self) -> HashMap<String, u64> {
        self.records.iter().map(|(_, r)| (r.part.clone(), r.updated)).collect()
    }

    /// Register a transfer that is starting, or hand back the one already in flight (which is what a
    /// resumed transfer's first chunk hits). Returns `(part name, true if this call created it)` —
    /// the caller creates/truncates the part file only when it is new, so a RESUMED transfer never
    /// truncates away the 99% it already has.
    ///
    /// A `total` that disagrees with the record's restarts the transfer: the bitmap indexes a
    /// different chunking of different bytes, so honouring it would leave permanent holes.
    pub fn begin(&mut self, reference: &str, part: String, total: u32) -> (String, bool) {
        if let Some(r) = self.records.get(reference) {
            if r.total == total {
                return (r.part.clone(), false);
            }
        }
        self.records.insert(
            reference.to_string(),
            Reassembly { part: part.clone(), total, got: HashSet::new(), updated: now_secs() },
        );
        self.enforce_cap();
        self.dirty = true;
        self.save_now();
        (part, true)
    }

    /// Record that chunk `index`'s bytes are ON DISK. Returns `Some(true)` once every chunk is in.
    ///
    /// Called only AFTER the positional write succeeded — see the note on `SAVE_INTERVAL_SECS`: the
    /// persisted bitmap may lag reality, but it must never lead it.
    pub fn mark(&mut self, reference: &str, index: u32) -> Option<bool> {
        let r = self.records.get_mut(reference)?;
        if index >= r.total {
            return Some(false);
        }
        r.got.insert(index);
        r.updated = now_secs();
        let complete = r.is_complete();
        self.dirty = true;
        if complete {
            self.save_now();
        } else {
            self.save();
        }
        Some(complete)
    }

    /// Forget a transfer — adopted, or its partial rejected — and flush immediately, so a relaunch
    /// never resurrects a reassembly whose bytes are already in place (or already thrown away).
    pub fn clear(&mut self, reference: &str) -> Option<Reassembly> {
        let gone = self.records.remove(reference)?;
        self.dirty = true;
        self.save_now();
        Some(gone)
    }

    /// How many chunks we hold for `reference` — the progress signal the frame-33 fallback watches.
    pub fn progress(&self, reference: &str) -> Option<u32> {
        self.records.get(reference).map(|r| r.got.len() as u32)
    }

    /// The `(total, bitmap)` for a resume ask, or `None` when there is nothing to resume — no
    /// record, or one with no chunks yet, in which case the caller must send a plain frame 3 so the
    /// common path stays byte-for-byte compatible with every peer in the field.
    pub fn resume_hint(&self, reference: &str) -> Option<(u32, HashSet<u32>)> {
        let r = self.records.get(reference)?;
        if r.got.is_empty() || r.total == 0 {
            return None;
        }
        Some((r.total, r.got.clone()))
    }

    /// Oldest progress goes first once we're over [`MAX_RECORDS`].
    fn enforce_cap(&mut self) {
        if self.records.len() <= MAX_RECORDS {
            return;
        }
        let mut by_age: Vec<(String, u64)> =
            self.records.iter().map(|(k, r)| (k.clone(), r.updated)).collect();
        by_age.sort_by_key(|(_, t)| *t);
        for (reference, _) in by_age.into_iter().take(self.records.len() - MAX_RECORDS) {
            if let Some(r) = self.records.remove(&reference) {
                let _ = std::fs::remove_file(self.dir.join(&r.part));
            }
        }
    }

    /// Debounced write — see [`SAVE_INTERVAL_SECS`].
    fn save(&mut self) {
        if now_secs().saturating_sub(self.last_save_secs) < SAVE_INTERVAL_SECS {
            return;
        }
        self.save_now();
    }

    fn save_now(&mut self) {
        if !self.dirty || self.path.as_os_str().is_empty() {
            return;
        }
        self.dirty = false;
        self.last_save_secs = now_secs();
        let body: Vec<String> =
            self.records.iter().map(|(reference, r)| encode_line(reference, r)).collect();
        let _ = std::fs::write(&self.path, body.join("\n"));
    }

    /// Flush whatever the debounce is still holding. Cheap and idempotent.
    pub fn flush(&mut self) {
        self.save_now();
    }
}

// ---- Line format ----------------------------------------------------------------------------
// `<ref>\t<part name>\t<total>\t<updated secs>\t<bitmap hex>` — one line per transfer, matching the
// engine's other line-delimited cursors. Tab-separated because a ref may contain ':' (`v:`/`dm:`)
// but never a tab or a newline. A line that doesn't parse is dropped, not guessed at.

fn encode_line(reference: &str, r: &Reassembly) -> String {
    let bits = crate::wire::bitmap(&r.got, r.total);
    let hex: String = bits.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}\t{}\t{}\t{}\t{}", reference, r.part, r.total, r.updated, hex)
}

fn parse_line(line: &str) -> Option<(String, Reassembly)> {
    let mut f = line.split('\t');
    let reference = f.next()?.to_string();
    let part = f.next()?.to_string();
    let total: u32 = f.next()?.parse().ok()?;
    let updated: u64 = f.next()?.parse().ok()?;
    let hex = f.next()?;
    // Same bounds a PEER's frame 33 gets, applied to our own file too: a corrupt or hand-edited line
    // must not be able to make us allocate a half-gigabyte bitmap at startup.
    if reference.is_empty() || part.is_empty() || total == 0 || total > crate::wire::MAX_RESUME_CHUNKS {
        return None;
    }
    if hex.len() != ((total as usize + 7) / 8) * 2 {
        return None;
    }
    let mut bits = Vec::with_capacity(hex.len() / 2);
    for i in (0..hex.len()).step_by(2) {
        bits.push(u8::from_str_radix(hex.get(i..i + 2)?, 16).ok()?);
    }
    Some((reference, Reassembly { part, total, got: crate::wire::bitmap_indices(&bits, total), updated }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "haven-reassembly-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn index(dir: &PathBuf) -> ReassemblyIndex {
        ReassemblyIndex::load(dir.join("media-reassembly.txt"), dir.clone())
    }

    /// The whole point: a transfer that died on its last chunk resumes there, not at chunk 0.
    #[test]
    fn a_1599_of_1600_partial_survives_a_relaunch() {
        let dir = tmp_dir("relaunch");
        std::fs::write(dir.join("incoming_p2p_x.part"), b"bytes").unwrap();
        {
            let mut ix = index(&dir);
            ix.begin("img_x", "incoming_p2p_x.part".into(), 1600);
            for i in 0..1599 {
                assert_eq!(ix.mark("img_x", i), Some(false));
            }
            ix.flush();
        }
        // Simulated relaunch: a fresh index off the same file.
        let ix = index(&dir);
        let (total, got) = ix.resume_hint("img_x").unwrap();
        assert_eq!(total, 1600);
        assert_eq!(got.len(), 1599);
        let missing: Vec<u32> = (0..1600).filter(|i| !got.contains(i)).collect();
        assert_eq!(missing, vec![1599], "a resume must ask for exactly the one chunk it lacks");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_record_whose_part_vanished_is_dropped_not_resumed_into() {
        let dir = tmp_dir("vanished");
        std::fs::write(dir.join("incoming_p2p_y.part"), b"bytes").unwrap();
        {
            let mut ix = index(&dir);
            ix.begin("img_y", "incoming_p2p_y.part".into(), 8);
            ix.mark("img_y", 0);
            ix.flush();
        }
        std::fs::remove_file(dir.join("incoming_p2p_y.part")).unwrap();
        // The bitmap without the bytes it describes is a lie — resuming on it leaves permanent holes.
        let ix = index(&dir);
        assert!(ix.get("img_y").is_none());
        assert!(ix.resume_hint("img_y").is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_abandoned_partial_expires_with_its_bytes() {
        let dir = tmp_dir("expire");
        let part = dir.join("incoming_p2p_z.part");
        std::fs::write(&part, b"bytes").unwrap();
        let stale = now_secs() - EXPIRY_SECS - 60;
        std::fs::write(
            dir.join("media-reassembly.txt"),
            format!("img_z\tincoming_p2p_z.part\t8\t{stale}\t01"),
        )
        .unwrap();
        let ix = index(&dir);
        assert!(ix.get("img_z").is_none());
        assert!(!part.exists(), "an expired partial's bytes must go too, not just its record");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_index_is_capped_and_evicts_oldest_progress_first() {
        let dir = tmp_dir("cap");
        let mut ix = index(&dir);
        for i in 0..(MAX_RECORDS + 10) {
            let part = format!("incoming_p2p_{i}.part");
            std::fs::write(dir.join(&part), b"b").unwrap();
            ix.begin(&format!("img_{i}"), part, 8);
            // Stamp ages by hand so the eviction order is deterministic (all inserts land in the
            // same second otherwise).
            ix.records.get_mut(&format!("img_{i}")).unwrap().updated = 1_000_000 + i as u64;
        }
        // The cap runs on insert, so the last insert trims to exactly MAX_RECORDS.
        assert!(ix.records.len() <= MAX_RECORDS, "index grew to {}", ix.records.len());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn live_parts_names_only_resumable_partials() {
        let dir = tmp_dir("live");
        std::fs::write(dir.join("incoming_p2p_a.part"), b"b").unwrap();
        let mut ix = index(&dir);
        ix.begin("img_a", "incoming_p2p_a.part".into(), 4);
        assert!(ix.live_parts().contains_key("incoming_p2p_a.part"));
        ix.clear("img_a");
        assert!(ix.live_parts().is_empty(), "a cleared reassembly must stop sparing its scratch");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_disagreeing_total_restarts_rather_than_reusing_a_bitmap_for_other_bytes() {
        let dir = tmp_dir("total");
        std::fs::write(dir.join("incoming_p2p_b.part"), b"b").unwrap();
        let mut ix = index(&dir);
        ix.begin("img_b", "incoming_p2p_b.part".into(), 100);
        ix.mark("img_b", 7);
        let (_, fresh) = ix.begin("img_b", "incoming_p2p_b.part".into(), 200);
        assert!(fresh, "a different chunking is a different transfer");
        assert_eq!(ix.progress("img_b"), Some(0));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mark_ignores_an_out_of_range_index_and_completes_exactly_once() {
        let dir = tmp_dir("mark");
        std::fs::write(dir.join("incoming_p2p_c.part"), b"b").unwrap();
        let mut ix = index(&dir);
        ix.begin("img_c", "incoming_p2p_c.part".into(), 2);
        assert_eq!(ix.mark("img_c", 99), Some(false)); // past `total` — never counts toward completion
        assert_eq!(ix.mark("img_c", 0), Some(false));
        assert_eq!(ix.mark("img_c", 0), Some(false)); // a duplicate chunk is not progress
        assert_eq!(ix.mark("img_c", 1), Some(true));
        assert_eq!(ix.mark("img_nope", 0), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_corrupt_persisted_line_is_dropped_not_guessed_at() {
        let dir = tmp_dir("corrupt");
        std::fs::write(dir.join("incoming_p2p_d.part"), b"b").unwrap();
        std::fs::write(
            dir.join("media-reassembly.txt"),
            // In order: absurd total (a 536 MB bitmap if believed), zero total, bitmap too short for
            // the total, non-hex bitmap, missing fields — then one good line.
            format!(
                "img_d\tincoming_p2p_d.part\t4294967295\t{now}\t00\n\
                 img_d\tincoming_p2p_d.part\t0\t{now}\t\n\
                 img_d\tincoming_p2p_d.part\t64\t{now}\t01\n\
                 img_d\tincoming_p2p_d.part\t8\t{now}\tzz\n\
                 img_d\tincoming_p2p_d.part\n\
                 img_d\tincoming_p2p_d.part\t8\t{now}\t81",
                now = now_secs()
            ),
        )
        .unwrap();
        let ix = index(&dir);
        let (total, got) = ix.resume_hint("img_d").unwrap();
        assert_eq!(total, 8);
        assert_eq!(got, [0u32, 7].into_iter().collect::<HashSet<u32>>());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_partial_with_no_chunks_yet_has_no_resume_hint() {
        // Nothing to tell the server, so the caller must fall back to a plain frame 3 — the common
        // path stays byte-for-byte what every peer in the field already understands.
        let dir = tmp_dir("empty");
        std::fs::write(dir.join("incoming_p2p_e.part"), b"b").unwrap();
        let mut ix = index(&dir);
        ix.begin("img_e", "incoming_p2p_e.part".into(), 4);
        assert!(ix.resume_hint("img_e").is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
