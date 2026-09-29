//! Installing a verified update, the post-update probation, and rollback.
//!
//! All state lives in `<data>/update/` — next to (never inside) the identity and the store, so an
//! update can never touch the relay's node id or its sealed mailbox:
//!
//! ```text
//! <data>/update/state.json        bad versions, the pending (on-probation) install, last good
//! <data>/update/staging/          downloads in flight (.part) — swept when stale
//! <data>/update/bin/haven-relay   VOLUME mode: the updated binary the Docker entrypoint runs
//! <data>/update/bin/haven-relay.prev
//! ```
//!
//! Two install strategies:
//! * **Volume** (Docker): the new binary goes to `<data>/update/bin/haven-relay` on the persistent
//!   volume; the entrypoint supervisor runs it instead of the image's copy while it is newer, so
//!   an update survives container restarts AND recreation. Rollback = restore `.prev`, or delete it
//!   (falling back to the image binary) when there was no previous volume binary.
//! * **In place** (systemd / launchd / install.sh): the running executable's path is replaced by
//!   an atomic `rename(2)` (the running process keeps its old inode), with a copy kept as
//!   `<exe>.prev`. The service manager restarts it.
//!
//! Probation: the new binary, on its first starts, increments `attempts`; if it keeps dying
//! before passing its health check it rolls itself back after [`MAX_ATTEMPTS`]; if it runs but
//! doesn't become healthy within the window, the probation timer rolls it back. A rolled-back
//! version is recorded as bad and never offered again.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

use super::version::Version;

/// Exit code meaning "restart me (an update was installed, or rolled back)". Distinct from 0 (clean
/// stop) and 1 (error). The Docker entrypoint restarts on it immediately; systemd `Restart=always`
/// and launchd `KeepAlive` restart on any exit.
pub const EXIT_RESTART: i32 = 75;

/// How many starts a freshly-installed binary gets to pass its health check before it is rolled
/// back without further ado (covers a binary that crashes during startup).
pub const MAX_ATTEMPTS: u32 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InstallMode {
    Volume,
    Inplace,
}

/// An installed-but-not-yet-proven update.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pending {
    pub version: String,
    pub prev_version: String,
    pub mode: InstallMode,
    /// The path the new binary was installed at.
    pub active: PathBuf,
    /// Where the previous binary was kept, if there was one to keep.
    pub prev: Option<PathBuf>,
    pub installed_at: u64,
    #[serde(default)]
    pub attempts: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    /// Versions that failed after install — never offered again.
    #[serde(default)]
    pub bad: Vec<String>,
    #[serde(default)]
    pub pending: Option<Pending>,
    /// Last version that passed its post-update health check.
    #[serde(default)]
    pub last_good: Option<String>,
    /// Last version we printed "update available" for (notify-only installs say it once).
    #[serde(default)]
    pub notified: Option<String>,
}

impl State {
    pub fn bad_versions(&self) -> Vec<Version> {
        self.bad.iter().filter_map(|s| Version::parse(s)).collect()
    }
    pub fn mark_bad(&mut self, v: &str) {
        if !self.bad.iter().any(|b| b == v) {
            self.bad.push(v.to_string());
        }
    }
}

/// `<data>/update`.
pub fn update_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("update")
}

fn state_path(dir: &Path) -> PathBuf {
    dir.join("state.json")
}

pub fn staging_dir(dir: &Path) -> PathBuf {
    dir.join("staging")
}

/// The volume-mode binary path.
pub fn volume_bin(dir: &Path) -> PathBuf {
    dir.join("bin").join(if cfg!(windows) { "haven-relay.exe" } else { "haven-relay" })
}

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn load_state(dir: &Path) -> State {
    std::fs::read(state_path(dir))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Atomic write (temp + rename) so a crash mid-write never leaves a torn state file.
pub fn save_state(dir: &Path, st: &State) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    let tmp = dir.join(format!("state.json.{}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(st)?)?;
    std::fs::rename(&tmp, state_path(dir))?;
    Ok(())
}

fn prev_path_for(active: &Path) -> PathBuf {
    let mut name = active.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".prev");
    active.with_file_name(name)
}

#[cfg(unix)]
fn make_executable(p: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}
#[cfg(not(unix))]
fn make_executable(_p: &Path) -> Result<()> {
    Ok(())
}

pub fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

/// Volume install: `staged` (already verified, same filesystem) becomes `<dir>/bin/haven-relay`.
/// The existing volume binary is kept as `.prev` ONLY if it is what's running now — otherwise
/// (running the image's binary) a rollback should simply fall back to the image.
pub fn install_volume(
    dir: &Path,
    staged: &Path,
    new_version: &str,
    running_exe: &Path,
    running_version: &str,
) -> Result<Pending> {
    let active = volume_bin(dir);
    std::fs::create_dir_all(active.parent().unwrap_or(dir))?;
    let prev = prev_path_for(&active);
    let keep_prev = active.exists() && same_file(&active, running_exe);
    let _ = std::fs::remove_file(&prev);
    if keep_prev {
        std::fs::rename(&active, &prev).context("keep previous binary")?;
    }
    make_executable(staged)?;
    std::fs::rename(staged, &active).context("move update into place")?;
    Ok(Pending {
        version: new_version.to_string(),
        prev_version: running_version.to_string(),
        mode: InstallMode::Volume,
        active,
        prev: keep_prev.then_some(prev),
        installed_at: now_secs(),
        attempts: 0,
    })
}

/// In-place install over `exe`. `staged` MUST live in the same directory (same filesystem) so
/// the final rename is atomic. The running process keeps executing its old inode.
pub fn install_inplace(exe: &Path, staged: &Path, new_version: &str, running_version: &str) -> Result<Pending> {
    let prev = prev_path_for(exe);
    let _ = std::fs::remove_file(&prev);
    make_executable(staged)?;
    #[cfg(unix)]
    {
        // Copy (not rename) the old binary aside, so `exe` is never missing — even for an instant —
        // and a service manager restarting at the wrong moment always finds a binary.
        std::fs::copy(exe, &prev).context("keep previous binary")?;
        make_executable(&prev)?;
        std::fs::rename(staged, exe).context("move update into place")?;
    }
    #[cfg(not(unix))]
    {
        // Windows can't replace a running .exe, but it CAN rename one.
        std::fs::rename(exe, &prev).context("move running binary aside")?;
        if let Err(e) = std::fs::rename(staged, exe) {
            let _ = std::fs::rename(&prev, exe);
            return Err(anyhow!("move update into place: {e}"));
        }
    }
    Ok(Pending {
        version: new_version.to_string(),
        prev_version: running_version.to_string(),
        mode: InstallMode::Inplace,
        active: exe.to_path_buf(),
        prev: Some(prev),
        installed_at: now_secs(),
        attempts: 0,
    })
}

/// Undo `p`: restore the previous binary (or, volume mode with none, remove the update so the
/// image binary runs again). Does NOT touch state — see [`rollback_pending`].
pub fn undo_install(p: &Pending) -> Result<()> {
    match (&p.prev, p.mode) {
        (Some(prev), _) if prev.exists() => {
            #[cfg(not(unix))]
            {
                // Windows: move the running one aside first (can't overwrite it).
                let bad = p.active.with_extension("bad");
                let _ = std::fs::remove_file(&bad);
                let _ = std::fs::rename(&p.active, &bad);
            }
            std::fs::rename(prev, &p.active).context("restore previous binary")?;
        }
        (_, InstallMode::Volume) => {
            let _ = std::fs::remove_file(&p.active);
        }
        (_, InstallMode::Inplace) => {
            return Err(anyhow!("no previous binary kept at {} — cannot roll back", p.active.display()));
        }
    }
    Ok(())
}

/// Roll back the pending install (if any), mark its version bad, clear it. Returns the version
/// that was rolled back.
pub fn rollback_pending(dir: &Path) -> Result<Option<String>> {
    let mut st = load_state(dir);
    let Some(p) = st.pending.clone() else { return Ok(None) };
    let res = undo_install(&p);
    // Mark bad even if the file shuffle failed: never try this version again either way.
    st.mark_bad(&p.version);
    st.pending = None;
    save_state(dir, &st)?;
    res.map(|_| Some(p.version))
}

/// What the startup gate decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Gate {
    /// No update on probation.
    Normal,
    /// This binary IS the update on probation (attempt number inside).
    Probation(u32),
    /// Too many failed starts — rolled back; the caller must exit with [`EXIT_RESTART`].
    RolledBack(String),
}

/// Called at the very start of `run`, before anything that could fail on a bad release.
pub fn startup_gate(dir: &Path, my_version: &str) -> Gate {
    let mut st = load_state(dir);
    let Some(mut p) = st.pending.clone() else { return Gate::Normal };
    if p.version != my_version {
        // We are not the update on probation: the supervisor fell back to the previous binary (it
        // could not run the new one), or someone installed a different build by hand.
        if p.prev_version == my_version {
            eprintln!("⚠ update {} did not come up — staying on {my_version} and never retrying it.", p.version);
            st.mark_bad(&p.version);
            let _ = undo_install(&p);
        }
        st.pending = None;
        let _ = save_state(dir, &st);
        return Gate::Normal;
    }
    p.attempts += 1;
    if p.attempts > MAX_ATTEMPTS {
        return match rollback_pending(dir) {
            Ok(Some(v)) => {
                eprintln!("✗ update {v} failed to start {MAX_ATTEMPTS} times — rolled back to {}.", p.prev_version);
                Gate::RolledBack(v)
            }
            _ => Gate::Normal,
        };
    }
    st.pending = Some(p.clone());
    let _ = save_state(dir, &st);
    Gate::Probation(p.attempts)
}

/// The update on probation proved healthy: keep it.
pub fn commit(dir: &Path, my_version: &str) -> bool {
    let mut st = load_state(dir);
    match &st.pending {
        Some(p) if p.version == my_version => {
            st.pending = None;
            st.last_good = Some(my_version.to_string());
            save_state(dir, &st).is_ok()
        }
        _ => false,
    }
}

/// Is the update on probation still uncommitted (for the probation timer)?
pub fn still_pending(dir: &Path, my_version: &str) -> bool {
    matches!(&load_state(dir).pending, Some(p) if p.version == my_version)
}

/// Should the Docker entrypoint run the volume binary instead of the image's? Only when it is
/// strictly newer than the image's own binary and not a known-bad version — so rebuilding the
/// image with a newer release always wins over an older self-update.
pub fn prefer_volume(image: &Version, volume: Option<&Version>, bad: &[Version]) -> bool {
    match volume {
        Some(v) => v > image && !bad.contains(v),
        None => false,
    }
}

/// Run `<bin> version` (bounded time) and parse `haven-relay X.Y.Z[-rc.N]`.
pub fn binary_version(bin: &Path, timeout: Duration) -> Option<Version> {
    use std::process::{Command, Stdio};
    let mut child = Command::new(bin)
        .arg("version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return None;
                }
                break;
            }
            Ok(None) if std::time::Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut out = String::new();
    use std::io::Read;
    child.stdout.take()?.read_to_string(&mut out).ok()?;
    let line = out.lines().find(|l| l.starts_with("haven-relay "))?;
    Version::parse(line.trim_start_matches("haven-relay ").trim())
}

/// Delete stale downloads (older than a day, or any `.part` older than an hour).
pub fn sweep_staging(dir: &Path) {
    let Ok(rd) = std::fs::read_dir(staging_dir(dir)) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let age = e
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.elapsed().ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let is_part = p.extension().map(|x| x == "part").unwrap_or(false);
        if (is_part && age > 3600) || age > 24 * 3600 {
            let _ = std::fs::remove_file(&p);
        }
    }
}

/// Is `dir` writable by us (probe file create + remove)?
pub fn dir_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".haven-relay-write-test-{}", std::process::id()));
    match std::fs::OpenOptions::new().create(true).write(true).truncate(true).open(&probe) {
        Ok(f) => {
            drop(f);
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hr-install-{tag}-{}-{}", std::process::id(), now_secs()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn prefer_volume_only_when_strictly_newer_and_not_bad() {
        let v = |s: &str| Version::parse(s).unwrap();
        assert!(prefer_volume(&v("1.2.0"), Some(&v("1.2.1")), &[]));
        assert!(!prefer_volume(&v("1.2.1"), Some(&v("1.2.1")), &[]));
        assert!(!prefer_volume(&v("1.3.0"), Some(&v("1.2.1")), &[]), "a rebuilt newer image wins");
        assert!(!prefer_volume(&v("1.2.0"), Some(&v("1.2.1")), &[v("1.2.1")]));
        assert!(!prefer_volume(&v("1.2.0"), None, &[]));
    }

    #[test]
    fn volume_install_and_rollback_to_image() {
        let d = tmp("vol");
        let dir = update_dir(&d);
        std::fs::create_dir_all(staging_dir(&dir)).unwrap();
        let staged = staging_dir(&dir).join("new");
        std::fs::write(&staged, b"NEW").unwrap();
        let image = d.join("image-bin");
        std::fs::write(&image, b"IMAGE").unwrap();
        // Running the IMAGE binary: nothing to keep as .prev.
        let p = install_volume(&dir, &staged, "1.2.1", &image, "1.2.0").unwrap();
        assert_eq!(std::fs::read(volume_bin(&dir)).unwrap(), b"NEW");
        assert!(p.prev.is_none());
        let mut st = load_state(&dir);
        st.pending = Some(p);
        save_state(&dir, &st).unwrap();
        assert_eq!(rollback_pending(&dir).unwrap().as_deref(), Some("1.2.1"));
        assert!(!volume_bin(&dir).exists(), "rolled back to the image binary");
        let st = load_state(&dir);
        assert_eq!(st.bad, vec!["1.2.1".to_string()]);
        assert!(st.pending.is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn volume_install_keeps_running_volume_binary_as_prev() {
        let d = tmp("vol2");
        let dir = update_dir(&d);
        std::fs::create_dir_all(volume_bin(&dir).parent().unwrap()).unwrap();
        std::fs::create_dir_all(staging_dir(&dir)).unwrap();
        std::fs::write(volume_bin(&dir), b"OLD").unwrap();
        let staged = staging_dir(&dir).join("new");
        std::fs::write(&staged, b"NEW").unwrap();
        let p = install_volume(&dir, &staged, "1.2.2", &volume_bin(&dir), "1.2.1").unwrap();
        assert!(p.prev.is_some());
        undo_install(&p).unwrap();
        assert_eq!(std::fs::read(volume_bin(&dir)).unwrap(), b"OLD");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn inplace_install_is_atomic_and_reversible() {
        let d = tmp("inplace");
        let exe = d.join("haven-relay");
        std::fs::write(&exe, b"OLD").unwrap();
        let staged = d.join(".haven-relay.new");
        std::fs::write(&staged, b"NEW").unwrap();
        let p = install_inplace(&exe, &staged, "2.0.0", "1.9.0").unwrap();
        assert_eq!(std::fs::read(&exe).unwrap(), b"NEW");
        assert_eq!(std::fs::read(d.join("haven-relay.prev")).unwrap(), b"OLD");
        undo_install(&p).unwrap();
        assert_eq!(std::fs::read(&exe).unwrap(), b"OLD");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn startup_gate_counts_attempts_then_rolls_back() {
        let d = tmp("gate");
        let dir = update_dir(&d);
        let exe = d.join("haven-relay");
        std::fs::write(&exe, b"OLD").unwrap();
        let staged = d.join(".new");
        std::fs::write(&staged, b"NEW").unwrap();
        let p = install_inplace(&exe, &staged, "2.0.0", "1.9.0").unwrap();
        save_state(&dir, &State { pending: Some(p), ..Default::default() }).unwrap();
        for n in 1..=MAX_ATTEMPTS {
            assert_eq!(startup_gate(&dir, "2.0.0"), Gate::Probation(n));
        }
        assert_eq!(startup_gate(&dir, "2.0.0"), Gate::RolledBack("2.0.0".into()));
        assert_eq!(std::fs::read(&exe).unwrap(), b"OLD");
        let st = load_state(&dir);
        assert!(st.bad.contains(&"2.0.0".to_string()) && st.pending.is_none());
        assert_eq!(startup_gate(&dir, "1.9.0"), Gate::Normal);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn healthy_update_commits_and_fallback_marks_bad() {
        let d = tmp("commit");
        let dir = update_dir(&d);
        let pend = |v: &str| Pending {
            version: v.into(),
            prev_version: "1.0.0".into(),
            mode: InstallMode::Volume,
            active: volume_bin(&dir),
            prev: None,
            installed_at: 0,
            attempts: 0,
        };
        save_state(&dir, &State { pending: Some(pend("1.1.0")), ..Default::default() }).unwrap();
        assert_eq!(startup_gate(&dir, "1.1.0"), Gate::Probation(1));
        assert!(still_pending(&dir, "1.1.0"));
        assert!(commit(&dir, "1.1.0"));
        let st = load_state(&dir);
        assert!(st.pending.is_none() && st.bad.is_empty());
        assert_eq!(st.last_good.as_deref(), Some("1.1.0"));
        // The supervisor fell back to the previous binary without the new one ever committing.
        save_state(&dir, &State { pending: Some(pend("1.2.0")), ..Default::default() }).unwrap();
        assert_eq!(startup_gate(&dir, "1.0.0"), Gate::Normal);
        assert_eq!(load_state(&dir).bad, vec!["1.2.0".to_string()]);
        let _ = std::fs::remove_dir_all(&d);
    }
}
