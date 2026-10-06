//! Directory-listing cache for relay stores — what keeps LIST / AGES / the mesh pass from walking
//! the whole store with a `stat` per file on every request.
//!
//! A long-lived relay (Blaine's NAS, 2026-10-06: ~475k files) answered every member's circle LIST,
//! every sibling's 15 s AGES inventory and its own mesh pass by recursively `read_dir`-ing the store
//! and calling `is_dir()` + `is_file()` (+ `metadata()` for AGES) on every entry: ~130k `stat`/10 s
//! sustained, 130–250 % CPU across the tokio workers, almost no network.
//!
//! The cache remembers each directory's entry NAMES (files vs subdirectories) together with the
//! directory's own mtime. POSIX filesystems bump a directory's mtime whenever an entry is created,
//! removed or renamed in it — every store write is a temp-file + rename and every delete is an
//! unlink — so one `stat` of the directory proves its cached names are still exact. A listing then
//! costs one `stat` per DIRECTORY instead of two or three per FILE.
//!
//! File mtimes (what AGES reports) are cached too, per directory, but on a much shorter leash: a
//! TOUCH / HAS / back-date moves a file's mtime WITHOUT touching its directory, so every such write
//! in this crate goes through [`note_mtime_changed`], which marks the directory for a re-stat; a
//! changed directory re-stats all its files; and cached mtimes are never older than
//! [`MTIME_MAX_AGE`], which bounds what an outside writer (an operator, a test back-dating a file
//! by hand) can make AGES misreport. A sibling's 15 s AGES then costs one `stat` per directory plus
//! one per file in directories that actually changed.
//!
//! Racy-timestamp guard (the git "racily clean" problem): a directory read while its mtime is still
//! within [`SETTLE`] of now is NOT cached — a second change inside the same timestamp tick would
//! otherwise leave the mtime unchanged and the new name invisible. Entries are also re-read after
//! [`MAX_AGE`] regardless, which bounds the damage of a clock stepped backwards. On Windows the
//! cache is bypassed entirely (NTFS directory timestamps are not a reliable change signal).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

/// A directory whose mtime is younger than this is re-read on every visit (see module docs).
const SETTLE: Duration = Duration::from_secs(2);
/// Re-read a cached directory at least this often even if its mtime never moved.
const MAX_AGE: Duration = Duration::from_secs(300);
/// Re-stat a directory's files at least this often for AGES (see module docs).
const MTIME_MAX_AGE: Duration = Duration::from_secs(60);

struct Dir {
    mtime: SystemTime,
    cached_at: Instant,
    files: Vec<Box<str>>,
    subdirs: Vec<Box<str>>,
    /// Each file's mtime (unix secs), parallel to `files`, and when they were read.
    mtimes: Option<(Vec<u64>, Instant)>,
}

/// Directories whose files' mtimes moved without the directory changing (TOUCH / HAS / backdate).
fn dirty() -> &'static Mutex<std::collections::HashSet<PathBuf>> {
    static D: OnceLock<Mutex<std::collections::HashSet<PathBuf>>> = OnceLock::new();
    D.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

/// A stored file's mtime was just set in place (TOUCH / HAS refresh, mesh back-date): its
/// directory's cached mtimes are stale. Call after every such write.
pub(crate) fn note_mtime_changed(file: &Path) {
    if let Some(dir) = file.parent() {
        dirty().lock().unwrap_or_else(|e| e.into_inner()).insert(dir.to_path_buf());
    }
}

fn take_dirty(dir: &Path) -> bool {
    dirty().lock().unwrap_or_else(|e| e.into_inner()).remove(dir)
}

fn mtime_secs(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        // Unreadable → "now" (age 0): a hiccup must never make an entry look old.
        .unwrap_or_else(|| {
            SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
        })
}

#[derive(Default)]
struct Cache {
    dirs: HashMap<PathBuf, Dir>,
}

impl Cache {
    /// Drop `dir` and everything cached beneath it (it vanished, or a subdirectory was removed).
    fn forget_tree(&mut self, dir: &Path) {
        if self.dirs.remove(dir).is_some() {
            self.dirs.retain(|p, _| !p.starts_with(dir));
        }
    }
}

fn caches() -> &'static Mutex<HashMap<PathBuf, Arc<Mutex<Cache>>>> {
    static C: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<Cache>>>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cache_for(root: &Path) -> Arc<Mutex<Cache>> {
    let mut all = caches().lock().unwrap_or_else(|e| e.into_inner());
    all.entry(root.to_path_buf()).or_default().clone()
}

fn trustworthy(mtime: SystemTime) -> bool {
    !cfg!(windows)
        && SystemTime::now().duration_since(mtime).map(|age| age >= SETTLE).unwrap_or(false)
}

/// Read `dir`'s entries: (files, subdirectories). In-progress `.part` writes are skipped, exactly
/// as the uncached walk did. Symlinks are resolved (the old walk used `is_dir()` / `is_file()`,
/// which follow them); everything else uses the `d_type` from `getdents`, no `stat`.
/// (file names, subdirectory names) of one directory.
type Entries = (Vec<Box<str>>, Vec<Box<str>>);

fn read_entries(dir: &Path) -> Option<Entries> {
    let rd = std::fs::read_dir(dir).ok()?;
    let (mut files, mut subdirs) = (Vec::new(), Vec::new());
    for entry in rd.flatten() {
        let Ok(mut ft) = entry.file_type() else { continue };
        if ft.is_symlink() {
            match std::fs::metadata(entry.path()) {
                Ok(m) => ft = m.file_type(),
                Err(_) => continue,
            }
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if ft.is_dir() {
            subdirs.push(name.into_boxed_str());
        } else if ft.is_file() {
            if Path::new(&name).extension().map(|e| e == "part").unwrap_or(false) {
                continue; // skip in-progress writes
            }
            files.push(name.into_boxed_str());
        }
    }
    Some((files, subdirs))
}

/// `f(dir, name, mtime)`: `mtime` is `Some(unix secs)` only when `want_mtimes`.
type Visitor<'a> = &'a mut dyn FnMut(&Path, &str, Option<u64>);

fn visit(cache: &mut Cache, dir: &Path, want_mtimes: bool, f: Visitor) {
    let mtime = match std::fs::metadata(dir) {
        Ok(m) if m.is_dir() => m.modified().ok(),
        _ => {
            cache.forget_tree(dir);
            return;
        }
    };
    let hit = mtime.is_some_and(|m| {
        cache.dirs.get(dir).is_some_and(|d| d.mtime == m && d.cached_at.elapsed() < MAX_AGE && trustworthy(m))
    });
    if !hit {
        let Some((files, subdirs)) = read_entries(dir) else {
            cache.forget_tree(dir);
            return;
        };
        // Subdirectories that disappeared take their cached subtrees with them.
        if let Some(old) = cache.dirs.get(dir) {
            let gone: Vec<PathBuf> =
                old.subdirs.iter().filter(|s| !subdirs.contains(s)).map(|s| dir.join(&**s)).collect();
            for g in gone {
                cache.forget_tree(&g);
            }
        }
        match mtime.filter(|m| trustworthy(*m)) {
            Some(m) => {
                cache.dirs.insert(
                    dir.to_path_buf(),
                    Dir { mtime: m, cached_at: Instant::now(), files, subdirs, mtimes: None },
                );
            }
            None => {
                // Too fresh to trust: serve this read, cache nothing.
                cache.dirs.remove(dir);
                for name in &files {
                    let t = want_mtimes.then(|| mtime_secs(&dir.join(&**name)));
                    f(dir, name, t);
                }
                let _ = take_dirty(dir);
                for s in subdirs {
                    visit(cache, &dir.join(&*s), want_mtimes, f);
                }
                return;
            }
        }
    }
    let d = cache.dirs.get_mut(dir).expect("cached above");
    if want_mtimes {
        let dirty = take_dirty(dir);
        let stale = dirty || !hit || d.mtimes.as_ref().is_none_or(|(_, at)| at.elapsed() >= MTIME_MAX_AGE);
        if stale {
            let m: Vec<u64> = d.files.iter().map(|n| mtime_secs(&dir.join(&**n))).collect();
            d.mtimes = Some((m, Instant::now()));
        }
        let (m, _) = d.mtimes.as_ref().expect("filled above");
        for (name, t) in d.files.iter().zip(m) {
            f(dir, name, Some(*t));
        }
    } else {
        for name in &d.files {
            f(dir, name, None);
        }
    }
    let subdirs = d.subdirs.clone();
    for s in subdirs {
        visit(cache, &dir.join(&*s), want_mtimes, f);
    }
}

/// Visit every stored file under `dir` (recursively) as `(containing directory, file name)`,
/// served from the per-store cache wherever a directory is provably unchanged. `root` keys the
/// cache (one per store). Best-effort, like the walk it replaces: unreadable directories are
/// skipped.
pub(crate) fn walk(root: &Path, dir: &Path, f: &mut dyn FnMut(&Path, &str)) {
    let cache = cache_for(root);
    let mut c = cache.lock().unwrap_or_else(|e| e.into_inner());
    visit(&mut c, dir, false, &mut |d, n, _| f(d, n));
}

/// [`walk`] with each file's mtime (unix secs) — the AGES inventory. Mtimes come from the cache
/// under the rules in the module docs.
pub(crate) fn walk_mtimes(root: &Path, dir: &Path, f: &mut dyn FnMut(&Path, &str, u64)) {
    let cache = cache_for(root);
    let mut c = cache.lock().unwrap_or_else(|e| e.into_inner());
    visit(&mut c, dir, true, &mut |d, n, t| f(d, n, t.unwrap_or(0)));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(root: &Path) -> Vec<String> {
        let mut out = Vec::new();
        walk(root, root, &mut |d, n| out.push(d.join(n).strip_prefix(root).unwrap().to_string_lossy().into_owned()));
        out.sort();
        out
    }

    fn age_dir(p: &Path, secs: u64) {
        // Directories can't be opened for write; `utimes` via File::open read-only works on unix.
        let f = std::fs::File::open(p).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(secs)).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn cached_names_follow_every_add_remove_and_rename() {
        let root = std::env::temp_dir().join(format!("haven-dircache-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("a/b")).unwrap();
        std::fs::write(root.join("a/one"), b"1").unwrap();
        std::fs::write(root.join("a/b/two"), b"2").unwrap();
        std::fs::write(root.join("a/b/three.part"), b"x").unwrap();
        for d in ["a/b", "a", ""] {
            age_dir(&root.join(d), 60);
        }
        assert_eq!(names(&root), vec!["a/b/two", "a/one"]);
        // Cached now. A new file in a SETTLED directory bumps its mtime → seen at once.
        std::fs::write(root.join("a/b/four"), b"4").unwrap();
        assert_eq!(names(&root), vec!["a/b/four", "a/b/two", "a/one"]);
        // A second write within the same instant (the racy window) is also seen: the directory
        // was read while its mtime was fresh, so it was not cached.
        std::fs::write(root.join("a/b/five"), b"5").unwrap();
        assert_eq!(names(&root), vec!["a/b/five", "a/b/four", "a/b/two", "a/one"]);
        // temp + rename (the store's write path) and unlink.
        std::fs::write(root.join("a/six.part"), b"6").unwrap();
        std::fs::rename(root.join("a/six.part"), root.join("a/six")).unwrap();
        std::fs::remove_file(root.join("a/one")).unwrap();
        assert_eq!(names(&root), vec!["a/b/five", "a/b/four", "a/b/two", "a/six"]);
        // Cached mtimes: a TOUCH (mtime set in place, directory untouched) is seen once noted.
        for d in ["a", ""] {
            age_dir(&root.join(d), 60);
        }
        let mtime_of = |name: &str| {
            let mut out = None;
            walk_mtimes(&root, &root.join("a"), &mut |_, n, t| {
                if n == name {
                    out = Some(t)
                }
            });
            out.unwrap()
        };
        let now = SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        assert!(mtime_of("six") + 5 >= now);
        let old = SystemTime::now() - Duration::from_secs(10_000);
        std::fs::File::options().write(true).open(root.join("a/six")).unwrap().set_modified(old).unwrap();
        note_mtime_changed(&root.join("a/six"));
        assert!(mtime_of("six") + 9_000 < now, "a noted in-place mtime change is re-read");
        // A whole subtree vanishing.
        std::fs::remove_dir_all(root.join("a/b")).unwrap();
        assert_eq!(names(&root), vec!["a/six"]);
        let _ = std::fs::remove_dir_all(&root);
    }
}
