//! The mailbox seen-set's on-disk form: an APPEND-ONLY journal, one key per line.
//!
//! Same fix as the Apple client (2026-10-02 heat report: a 21.6 MB seen-set re-joined and
//! rewritten whole after every mailbox pass). A new mark is now one appended line; the file is
//! rewritten only when keys LEAVE the set (one-shot repairs, the key-commit re-queue) or when the
//! journal carries far more lines than distinct keys (compaction, done once at load).
//!
//! The pending state lives in `DynState` next to the set (same lock); the file write happens
//! outside that lock, serialized by [`WRITE_LOCK`] so an append never races a rewrite.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::Path;

/// Serializes every journal write (taken BEFORE the state lock when snapshotting a write).
pub static WRITE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeenWrite {
    /// Add these keys at the end of the file.
    Append(Vec<String>),
    /// Replace the file with exactly these keys.
    Rewrite(Vec<String>),
}

#[derive(Default, Debug)]
pub struct SeenJournal {
    pending: Vec<String>,
    needs_rewrite: bool,
}

impl SeenJournal {
    /// A key newly entered the set.
    pub fn note_inserted(&mut self, key: &str) {
        if !self.needs_rewrite {
            self.pending.push(key.to_string());
        }
    }
    /// Keys left the set: only a rewrite can express that.
    pub fn note_removed(&mut self) {
        self.needs_rewrite = true;
        self.pending.clear();
    }
    /// Snapshot what to write and clear the pending state.
    pub fn take(&mut self, set: &HashSet<String>) -> Option<SeenWrite> {
        if self.needs_rewrite {
            self.needs_rewrite = false;
            self.pending.clear();
            return Some(SeenWrite::Rewrite(set.iter().cloned().collect()));
        }
        if self.pending.is_empty() {
            return None;
        }
        Some(SeenWrite::Append(std::mem::take(&mut self.pending)))
    }
    /// A failed write: the file's tail is unknown, so the next save rewrites.
    pub fn requeue(&mut self) {
        self.note_removed();
    }
}

/// Duplicates beyond a quarter of the set (and at least 1000 lines) are worth one rewrite.
pub fn wants_compaction(lines: usize, distinct: usize) -> bool {
    lines.saturating_sub(distinct) > std::cmp::max(1000, distinct / 4)
}

/// Read the journal; blank lines (an append's leading separator) are skipped. Returns the set and
/// whether it should be compacted.
pub fn load(path: &Path) -> (HashSet<String>, bool) {
    let Ok(text) = std::fs::read_to_string(path) else { return (HashSet::new(), false) };
    let mut lines = 0usize;
    let mut set = HashSet::new();
    for l in text.lines().filter(|l| !l.is_empty()) {
        lines += 1;
        set.insert(l.to_string());
    }
    let compact = wants_compaction(lines, set.len());
    (set, compact)
}

/// Apply `w` to the file at `path`. Returns false on failure.
pub fn perform(w: &SeenWrite, path: &Path) -> bool {
    match w {
        SeenWrite::Rewrite(keys) => {
            let tmp = path.with_extension("txt.tmp");
            std::fs::write(&tmp, keys.join("\n")).is_ok() && std::fs::rename(&tmp, path).is_ok()
        }
        SeenWrite::Append(keys) => {
            if keys.is_empty() {
                return true;
            }
            // Leading newline: a file written by the old whole-set saver has no trailing one.
            let chunk = format!("\n{}", keys.join("\n"));
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .and_then(|mut f| f.write_all(chunk.as_bytes()))
                .is_ok()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("seenjournal-{}-{}", std::process::id(), rand_suffix()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
    fn rand_suffix() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }

    #[test]
    fn marks_append_without_rewriting_the_old_file() {
        let d = tmpdir();
        let p = d.join("mailbox-seen.txt");
        let old: Vec<String> = (0..3000).map(|i| format!("haven/mailbox/c/{i:064}")).collect();
        std::fs::write(&p, old.join("\n")).unwrap(); // old format: no trailing newline
        let (mut set, compact) = load(&p);
        assert_eq!(set.len(), 3000);
        assert!(!compact);
        let before = std::fs::metadata(&p).unwrap().len();

        let mut j = SeenJournal::default();
        for k in ["new-1", "new-2"] {
            set.insert(k.to_string());
            j.note_inserted(k);
        }
        let w = j.take(&set).unwrap();
        assert_eq!(w, SeenWrite::Append(vec!["new-1".into(), "new-2".into()]));
        assert!(perform(&w, &p));
        assert_eq!(std::fs::metadata(&p).unwrap().len(), before + "\nnew-1\nnew-2".len() as u64);
        assert_eq!(load(&p).0, set, "first appended key must not fuse with the old last line");
        assert!(j.take(&set).is_none());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn removal_rewrites_exactly_the_set() {
        let d = tmpdir();
        let p = d.join("mailbox-seen.txt");
        let mut set: HashSet<String> = ["a/1", "a/2", "b/1"].iter().map(|s| s.to_string()).collect();
        let mut j = SeenJournal::default();
        assert!(perform(&SeenWrite::Rewrite(set.iter().cloned().collect()), &p));
        set.retain(|k| !k.starts_with("a/"));
        j.note_removed();
        set.insert("c/1".into());
        j.note_inserted("c/1"); // folded into the rewrite
        let w = j.take(&set).unwrap();
        assert!(matches!(w, SeenWrite::Rewrite(_)));
        assert!(perform(&w, &p));
        assert_eq!(load(&p).0, set);
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn duplicate_heavy_journal_wants_compaction_and_failed_append_requeues_a_rewrite() {
        assert!(wants_compaction(200_000, 140_000));
        assert!(!wants_compaction(1500, 1000));
        let mut j = SeenJournal::default();
        let set: HashSet<String> = ["x".to_string()].into_iter().collect();
        j.note_inserted("x");
        let w = j.take(&set).unwrap();
        assert!(!perform(&w, Path::new("/nonexistent-dir-for-test/seen.txt")));
        j.requeue();
        assert_eq!(j.take(&set), Some(SeenWrite::Rewrite(vec!["x".into()])));
    }
}
