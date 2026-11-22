//! When a stored file was first written, for the relay's newest-first listing (`httprelay`,
//! `GET /n/<prefix>`).
//!
//! Nothing is recorded for this: it is the creation time the filesystem already keeps for
//! every file. A file's MODIFICATION time cannot stand in for it, because the mailbox's liveness
//! refresh (TOUCH, a HAS hit) moves that daily.
//!
//! `std::fs::Metadata::created` covers Apple and Windows. On Linux it needs `statx`, which the
//! standard library only calls on glibc; the relay ships as a static musl binary and also runs
//! inside the Android app, so there the system call is made directly. `None` means the kernel or
//! the filesystem does not keep a creation time, and the listing then says it cannot be ordered.

use std::path::Path;

/// Nanoseconds since the Unix epoch at which `path` was created, if the platform keeps that.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn birth_nanos(path: &Path) -> Option<u128> {
    use std::os::unix::ffi::OsStrExt;
    const STATX_BTIME: u32 = 0x800;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // `struct statx` is 256 bytes; `u64`s give it the alignment the kernel writes with.
    let mut buf = [0u64; 32];
    // SAFETY: `c` is a NUL-terminated path that outlives the call, `buf` is a writable 256-byte
    // buffer (the size of `struct statx`), and the kernel writes nothing beyond it.
    let rc = unsafe {
        libc::syscall(libc::SYS_statx, libc::AT_FDCWD, c.as_ptr(), 0 as libc::c_int, STATX_BTIME, buf.as_mut_ptr())
    };
    if rc != 0 {
        return None;
    }
    let bytes: Vec<u8> = buf.iter().flat_map(|w| w.to_ne_bytes()).collect();
    parse_statx_btime(&bytes)
}

/// `stx_mask` at 0, `stx_btime` at 0x50 (`i64` seconds, then `u32` nanoseconds).
#[cfg(any(target_os = "linux", target_os = "android", test))]
fn parse_statx_btime(statx: &[u8]) -> Option<u128> {
    const STATX_BTIME: u32 = 0x800;
    let mask = u32::from_ne_bytes(statx.get(0..4)?.try_into().ok()?);
    if mask & STATX_BTIME == 0 {
        return None;
    }
    let sec = i64::from_ne_bytes(statx.get(0x50..0x58)?.try_into().ok()?);
    let nsec = u32::from_ne_bytes(statx.get(0x58..0x5c)?.try_into().ok()?);
    (sec > 0).then(|| sec as u128 * 1_000_000_000 + u128::from(nsec))
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub(crate) fn birth_nanos(path: &Path) -> Option<u128> {
    let t = std::fs::metadata(path).ok()?.created().ok()?;
    t.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_nanos())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_creation_time_is_read_from_where_the_kernel_puts_it() {
        let mut s = vec![0u8; 256];
        assert_eq!(parse_statx_btime(&s), None, "no creation time reported");
        s[0..4].copy_from_slice(&0x800u32.to_ne_bytes());
        s[0x50..0x58].copy_from_slice(&1_700_000_000i64.to_ne_bytes());
        s[0x58..0x5c].copy_from_slice(&5u32.to_ne_bytes());
        // The neighbours (access time before, change time after) must not be what is read.
        s[0x40..0x48].copy_from_slice(&1i64.to_ne_bytes());
        s[0x60..0x68].copy_from_slice(&2i64.to_ne_bytes());
        assert_eq!(parse_statx_btime(&s), Some(1_700_000_000u128 * 1_000_000_000 + 5));
        assert_eq!(parse_statx_btime(&s[..0x58]), None, "a short buffer is not read past");
    }

    #[test]
    fn a_file_touched_later_keeps_the_time_it_was_created() {
        let dir = std::env::temp_dir().join(format!("haven-birth-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("f");
        std::fs::write(&p, b"x").unwrap();
        // Not every filesystem keeps it (an old kernel, some network mounts): nothing to check.
        let Some(born) = birth_nanos(&p) else { return };
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
        std::fs::File::options().write(true).open(&p).unwrap().set_modified(later).unwrap();
        assert_eq!(birth_nanos(&p), Some(born));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
