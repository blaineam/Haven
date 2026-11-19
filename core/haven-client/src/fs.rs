//! The filesystem the client layer persists to.
//!
//! On every native target this is `std::fs`, re-exported — same functions, same types, no wrapper.
//! A browser has no filesystem, so on `wasm32` the same names are backed by an in-memory tree
//! ([`mem`]) that the page loads from, and flushes to, its own durable storage (IndexedDB). The
//! client code is written once against `crate::fs` and does not know which it got.
//!
//! One rule for code in this crate: never ask a `Path` about the disk directly (`p.exists()`,
//! `p.is_file()`, `p.metadata()`) — those go to the real OS and are always "no" in a browser. Use
//! [`exists`] / [`is_file`] / [`metadata`] here instead.

#[cfg(not(target_arch = "wasm32"))]
pub use std::fs::*;

#[cfg(target_arch = "wasm32")]
pub use mem::*;

use std::path::Path;

/// Does anything exist at `path`?
pub fn exists(path: impl AsRef<Path>) -> bool {
    metadata(path).is_ok()
}

/// Is `path` a regular file?
pub fn is_file(path: impl AsRef<Path>) -> bool {
    metadata(path).map(|m| m.is_file()).unwrap_or(false)
}

/// The in-memory tree behind `crate::fs` in a browser. Compiled for native tests too, so its
/// behaviour is checked by the ordinary test run rather than only inside a browser.
#[cfg(any(target_arch = "wasm32", test))]
pub mod mem {
    use std::collections::BTreeMap;
    use std::io::{self, Read, Write};
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    use web_time::SystemTime;

    #[derive(Clone)]
    struct Entry {
        data: Vec<u8>,
        modified: SystemTime,
    }

    /// One durable change for the page's persister to apply, in order.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum Change {
        Put(PathBuf),
        Remove(PathBuf),
    }

    #[derive(Default)]
    struct Tree {
        files: BTreeMap<PathBuf, Entry>,
        dirs: std::collections::BTreeSet<PathBuf>,
        changes: Vec<Change>,
    }

    static TREE: Mutex<Option<Tree>> = Mutex::new(None);

    fn with<R>(f: impl FnOnce(&mut Tree) -> R) -> R {
        let mut g = TREE.lock().unwrap_or_else(|e| e.into_inner());
        f(g.get_or_insert_with(Tree::default))
    }

    fn not_found(p: &Path) -> io::Error {
        io::Error::new(io::ErrorKind::NotFound, format!("{}: no such file", p.display()))
    }

    /// Seed a file from durable storage at startup. Not recorded as a change.
    pub fn preload(path: impl Into<PathBuf>, data: Vec<u8>, modified: SystemTime) {
        with(|t| {
            t.files.insert(path.into(), Entry { data, modified });
        });
    }

    /// The changes since the last call, in order — what the persister must write through. A path
    /// appears once, with its final fate.
    pub fn take_changes() -> Vec<Change> {
        with(|t| {
            let all = std::mem::take(&mut t.changes);
            let mut out: Vec<Change> = Vec::new();
            for c in all.into_iter().rev() {
                let p = match &c {
                    Change::Put(p) | Change::Remove(p) => p,
                };
                if !out.iter().any(|o| matches!(o, Change::Put(q) | Change::Remove(q) if q == p)) {
                    out.push(c);
                }
            }
            out.reverse();
            out
        })
    }

    /// A file's current bytes, for the persister (None if it has since been removed).
    pub fn snapshot(path: &Path) -> Option<Vec<u8>> {
        with(|t| t.files.get(path).map(|e| e.data.clone()))
    }

    pub fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
        let p = path.as_ref();
        with(|t| t.files.get(p).map(|e| e.data.clone()).ok_or_else(|| not_found(p)))
    }

    pub fn read_to_string(path: impl AsRef<Path>) -> io::Result<String> {
        String::from_utf8(read(path)?).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
        let p = path.as_ref().to_path_buf();
        with(|t| {
            t.files.insert(p.clone(), Entry { data: contents.as_ref().to_vec(), modified: SystemTime::now() });
            t.changes.push(Change::Put(p));
        });
        Ok(())
    }

    pub fn remove_file(path: impl AsRef<Path>) -> io::Result<()> {
        let p = path.as_ref();
        with(|t| match t.files.remove(p) {
            Some(_) => {
                t.changes.push(Change::Remove(p.to_path_buf()));
                Ok(())
            }
            None => Err(not_found(p)),
        })
    }

    pub fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
        let (from, to) = (from.as_ref(), to.as_ref().to_path_buf());
        with(|t| match t.files.remove(from) {
            Some(e) => {
                t.files.insert(to.clone(), e);
                t.changes.push(Change::Remove(from.to_path_buf()));
                t.changes.push(Change::Put(to));
                Ok(())
            }
            None => Err(not_found(from)),
        })
    }

    /// Directories are implied by the files under them; an explicitly created one is remembered so
    /// it reads back as existing while still empty.
    pub fn create_dir_all(path: impl AsRef<Path>) -> io::Result<()> {
        let p = path.as_ref().to_path_buf();
        with(|t| {
            t.dirs.insert(p);
        });
        Ok(())
    }

    pub fn remove_dir_all(path: impl AsRef<Path>) -> io::Result<()> {
        let dir = path.as_ref();
        with(|t| {
            let doomed: Vec<PathBuf> = t.files.keys().filter(|k| k.starts_with(dir)).cloned().collect();
            for k in doomed {
                t.files.remove(&k);
                t.changes.push(Change::Remove(k));
            }
            t.dirs.retain(|d| !d.starts_with(dir));
        });
        Ok(())
    }

    #[derive(Clone)]
    pub struct Metadata {
        len: u64,
        file: bool,
        modified: SystemTime,
    }

    impl Metadata {
        pub fn len(&self) -> u64 {
            self.len
        }
        pub fn is_empty(&self) -> bool {
            self.len == 0
        }
        pub fn is_file(&self) -> bool {
            self.file
        }
        pub fn is_dir(&self) -> bool {
            !self.file
        }
        pub fn modified(&self) -> io::Result<SystemTime> {
            Ok(self.modified)
        }
    }

    pub fn metadata(path: impl AsRef<Path>) -> io::Result<Metadata> {
        let p = path.as_ref();
        with(|t| {
            if let Some(e) = t.files.get(p) {
                return Ok(Metadata { len: e.data.len() as u64, file: true, modified: e.modified });
            }
            if t.dirs.contains(p) || t.files.keys().any(|k| k.starts_with(p) && k != p) {
                return Ok(Metadata { len: 0, file: false, modified: SystemTime::UNIX_EPOCH });
            }
            Err(not_found(p))
        })
    }

    pub struct DirEntry {
        path: PathBuf,
    }

    impl DirEntry {
        pub fn path(&self) -> PathBuf {
            self.path.clone()
        }
        pub fn file_name(&self) -> std::ffi::OsString {
            self.path.file_name().map(|n| n.to_os_string()).unwrap_or_default()
        }
        pub fn metadata(&self) -> io::Result<Metadata> {
            metadata(&self.path)
        }
    }

    /// The immediate children of `path` (files and sub-directories), each once.
    pub fn read_dir(path: impl AsRef<Path>) -> io::Result<std::vec::IntoIter<io::Result<DirEntry>>> {
        let dir = path.as_ref();
        with(|t| {
            let mut kids: std::collections::BTreeSet<PathBuf> = Default::default();
            for k in t.files.keys().chain(t.dirs.iter()) {
                if let Ok(rest) = k.strip_prefix(dir) {
                    if let Some(first) = rest.components().next() {
                        kids.insert(dir.join(first));
                    }
                }
            }
            if kids.is_empty() && !t.dirs.contains(dir) {
                return Err(not_found(dir));
            }
            Ok(kids.into_iter().map(|path| Ok(DirEntry { path })).collect::<Vec<_>>().into_iter())
        })
    }

    /// An open file: reads come from a snapshot taken at open; writes are buffered and committed
    /// on `flush`, `sync_all` and drop.
    pub struct File {
        path: PathBuf,
        buf: Vec<u8>,
        pos: usize,
        writable: bool,
        dirty: bool,
    }

    impl File {
        pub fn open(path: impl AsRef<Path>) -> io::Result<File> {
            let p = path.as_ref();
            Ok(File { path: p.to_path_buf(), buf: read(p)?, pos: 0, writable: false, dirty: false })
        }
        pub fn create(path: impl AsRef<Path>) -> io::Result<File> {
            let p = path.as_ref().to_path_buf();
            write(&p, [])?;
            Ok(File { path: p, buf: Vec::new(), pos: 0, writable: true, dirty: false })
        }
        pub fn sync_all(&mut self) -> io::Result<()> {
            self.flush()
        }
        pub fn metadata(&self) -> io::Result<Metadata> {
            Ok(Metadata { len: self.buf.len() as u64, file: true, modified: SystemTime::now() })
        }
    }

    impl Read for File {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            let n = out.len().min(self.buf.len().saturating_sub(self.pos));
            out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
            self.pos += n;
            Ok(n)
        }
    }

    impl Write for File {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            if !self.writable {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "file not opened for writing"));
            }
            self.buf.extend_from_slice(data);
            self.dirty = true;
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            if self.dirty {
                self.dirty = false;
                write(&self.path, &self.buf)?;
            }
            Ok(())
        }
    }

    impl Drop for File {
        fn drop(&mut self) {
            let _ = self.flush();
        }
    }

    #[derive(Default)]
    pub struct OpenOptions {
        read: bool,
        write: bool,
        append: bool,
        create: bool,
        truncate: bool,
    }

    impl OpenOptions {
        pub fn new() -> Self {
            Self::default()
        }
        pub fn read(&mut self, v: bool) -> &mut Self {
            self.read = v;
            self
        }
        pub fn write(&mut self, v: bool) -> &mut Self {
            self.write = v;
            self
        }
        pub fn append(&mut self, v: bool) -> &mut Self {
            self.append = v;
            self
        }
        pub fn create(&mut self, v: bool) -> &mut Self {
            self.create = v;
            self
        }
        pub fn truncate(&mut self, v: bool) -> &mut Self {
            self.truncate = v;
            self
        }
        pub fn open(&self, path: impl AsRef<Path>) -> io::Result<File> {
            let p = path.as_ref();
            let existing = read(p);
            let buf = match existing {
                Ok(b) if self.truncate => {
                    drop(b);
                    write(p, [])?;
                    Vec::new()
                }
                Ok(b) => b,
                Err(_) if self.create => {
                    write(p, [])?;
                    Vec::new()
                }
                Err(e) => return Err(e),
            };
            // Appends land at the end because writes always extend the buffer; `pos` only reads.
            Ok(File { path: p.to_path_buf(), buf, pos: 0, writable: self.write || self.append, dirty: false })
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::io::{Read, Write};

        // The tree is process-wide; each test works under its own root so they cannot collide.
        fn root(name: &str) -> PathBuf {
            PathBuf::from(format!("/memfs-test/{name}"))
        }

        #[test]
        fn write_read_rename_remove_round_trip() {
            let d = root("rt");
            write(d.join("a.bin"), b"one").unwrap();
            assert_eq!(read(d.join("a.bin")).unwrap(), b"one");
            assert_eq!(read_to_string(d.join("a.bin")).unwrap(), "one");
            rename(d.join("a.bin"), d.join("b.bin")).unwrap();
            assert!(read(d.join("a.bin")).is_err());
            assert_eq!(metadata(d.join("b.bin")).unwrap().len(), 3);
            remove_file(d.join("b.bin")).unwrap();
            assert_eq!(remove_file(d.join("b.bin")).unwrap_err().kind(), io::ErrorKind::NotFound);
        }

        #[test]
        fn directories_are_implied_listed_and_removed() {
            let d = root("dirs");
            assert!(metadata(&d).is_err());
            create_dir_all(d.join("empty")).unwrap();
            write(d.join("media/x"), b"1").unwrap();
            write(d.join("media/sub/y"), b"22").unwrap();
            write(d.join("top"), b"333").unwrap();
            assert!(metadata(d.join("media")).unwrap().is_dir());
            assert!(metadata(d.join("empty")).unwrap().is_dir());
            let mut names: Vec<String> =
                read_dir(&d).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            assert_eq!(names, ["empty", "media", "top"]);
            let files: Vec<bool> = read_dir(d.join("media")).unwrap().map(|e| e.unwrap().metadata().unwrap().is_file()).collect();
            assert_eq!(files.iter().filter(|f| **f).count(), 1);
            remove_dir_all(d.join("media")).unwrap();
            assert!(read(d.join("media/sub/y")).is_err());
            assert!(read(d.join("top")).is_ok());
        }

        #[test]
        fn files_buffer_writes_and_append_extends() {
            let d = root("file");
            {
                let mut f = File::create(d.join("log")).unwrap();
                f.write_all(b"ab").unwrap();
                f.sync_all().unwrap();
            }
            OpenOptions::new().create(true).append(true).open(d.join("log")).unwrap().write_all(b"cd").unwrap();
            let mut s = String::new();
            File::open(d.join("log")).unwrap().read_to_string(&mut s).unwrap();
            assert_eq!(s, "abcd");
            assert!(OpenOptions::new().append(true).open(d.join("missing")).is_err());
            assert!(File::open(d.join("log")).unwrap().write_all(b"x").is_err());
        }

        #[test]
        fn changes_report_each_path_once_with_its_final_fate() {
            let d = root("changes");
            let _ = take_changes();
            write(d.join("k"), b"1").unwrap();
            write(d.join("k"), b"2").unwrap();
            write(d.join("gone"), b"x").unwrap();
            remove_file(d.join("gone")).unwrap();
            preload(d.join("seeded"), b"s".to_vec(), SystemTime::UNIX_EPOCH);
            let mine: Vec<Change> = take_changes()
                .into_iter()
                .filter(|c| matches!(c, Change::Put(p) | Change::Remove(p) if p.starts_with(&d)))
                .collect();
            assert_eq!(mine, [Change::Put(d.join("k")), Change::Remove(d.join("gone"))]);
            assert_eq!(snapshot(&d.join("k")).unwrap(), b"2");
            assert_eq!(snapshot(&d.join("seeded")).unwrap(), b"s");
        }
    }
}
