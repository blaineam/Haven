//! Disk guard: keep the relay's disk from filling up.
//!
//! Every 30 s the free space of the filesystem holding the store is measured:
//!
//! * free ≥ floor: normal service.
//! * floor/4 ≤ free < floor: only small writes (≤ 64 KiB: mailbox events, rosters, control
//!   records) are accepted; media uploads and mesh replication get a clear refusal
//!   (HTTP 507 / `ERR insufficient storage`).
//! * free < floor/4: every new write is refused.
//!
//! Reads, TOUCH/HAS and the hourly GC keep running throughout, so members can still fetch what's
//! there and retention keeps freeing space; service resumes on its own once space is back.
//! `--min-free 0` disables the guard. The floor defaults to 1 GiB.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// Default free-space floor.
pub const DEFAULT_MIN_FREE: u64 = 1 << 30;
/// Largest PUT still accepted between floor/4 and floor.
pub const SMALL_PUT: u64 = 64 << 10;
const CHECK_EVERY: Duration = Duration::from_secs(30);

/// The PUT cap for `free` bytes available against a `floor` (`None` = no cap).
pub fn limit_for(free: u64, floor: u64) -> Option<u64> {
    if floor == 0 || free >= floor {
        None
    } else if free >= floor / 4 {
        Some(SMALL_PUT)
    } else {
        Some(0)
    }
}

/// Bytes available to an unprivileged writer on the filesystem holding `path`.
#[cfg(unix)]
pub fn free_bytes(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `s` a properly sized out-parameter.
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    #[allow(clippy::unnecessary_cast)] // field widths differ across unix targets
    Some((s.f_bavail as u64).saturating_mul(s.f_frsize as u64))
}

#[cfg(not(unix))]
pub fn free_bytes(_path: &Path) -> Option<u64> {
    None
}

fn fmt(n: u64) -> String {
    haven_net::blobstore::fmt_bytes(n)
}

/// Watch the store's filesystem and apply [`limit_for`] to the store's PUT cap.
pub fn spawn(store: PathBuf, floor: u64) {
    if floor == 0 {
        println!("  disk guard  : off (--min-free 0)");
        return;
    }
    if free_bytes(&store).is_none() {
        println!("  disk guard  : unavailable on this platform");
        return;
    }
    println!("  disk guard  : refuse new uploads below {} free", fmt(floor));
    std::thread::spawn(move || {
        let mut last: Option<Option<u64>> = None;
        loop {
            if let Some(free) = free_bytes(&store) {
                let lim = limit_for(free, floor);
                if last != Some(lim) {
                    haven_net::blobstore::set_put_limit(&store, lim);
                    match lim {
                        None if last.is_some() => println!("✓ disk guard: {} free again — accepting uploads.", fmt(free)),
                        None => {}
                        Some(0) => eprintln!("✗ disk guard: only {} free (floor {}) — refusing ALL new writes until space is freed.", fmt(free), fmt(floor)),
                        Some(_) => eprintln!("⚠ disk guard: only {} free (floor {}) — refusing media uploads and replication; small writes still accepted.", fmt(free), fmt(floor)),
                    }
                    last = Some(lim);
                }
            }
            std::thread::sleep(CHECK_EVERY);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thresholds() {
        let g = 1u64 << 30;
        assert_eq!(limit_for(5 * g, g), None);
        assert_eq!(limit_for(g, g), None);
        assert_eq!(limit_for(g - 1, g), Some(SMALL_PUT));
        assert_eq!(limit_for(g / 4, g), Some(SMALL_PUT));
        assert_eq!(limit_for(g / 4 - 1, g), Some(0));
        assert_eq!(limit_for(0, 0), None, "floor 0 disables the guard");
    }

    #[cfg(unix)]
    #[test]
    fn measures_free_space() {
        let free = free_bytes(&std::env::temp_dir()).expect("statvfs works on the temp dir");
        assert!(free > 0);
        assert!(free_bytes(Path::new("/definitely/not/here")).is_none());
    }
}
