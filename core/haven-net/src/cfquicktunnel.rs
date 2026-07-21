//! Cloudflare **Quick Tunnel** helper — ephemeral `*.trycloudflare.com` HTTPS front door
//! for the local relay HTTP interface (`:8674`).
//!
//! Why this lives in `haven-net` (not only the CLI): the desktop engine and `haven-relay`
//! share the same lifecycle (start HTTP → expose a public URL → announce it). The heavy
//! protocol stays in the official `cloudflared` binary (Apache-2.0); we only locate/install
//! it, spawn it, scrape the printed hostname, and kill it on drop.
//!
//! ## Bundling vs first-launch install
//!
//! | Host | Strategy |
//! |---|---|
//! | Desktop app (macOS / Windows / Linux) | Ship `cloudflared` next to the app (Tauri `externalBin` / Helpers) |
//! | `haven-relay` CLI | On first use, download the official binary **next to** `haven-relay` (or into `--data`) |
//!
//! App Store / Microsoft Store builds must **code-sign** the helper with the product
//! identity; the fetch script in `tools/fetch-cloudflared.sh` is what CI runs before pack.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};

/// Pinned cloudflared release. Bump deliberately — store builds and CLI installers must agree.
pub const CLOUDFLARED_VERSION: &str = "2026.7.2";

/// A running quick tunnel. Dropping this kills `cloudflared` (the trycloudflare hostname dies with it).
pub struct QuickTunnel {
    child: Child,
    /// e.g. `https://explicit-valium-park-copies.trycloudflare.com`
    pub public_url: String,
}

impl Drop for QuickTunnel {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl QuickTunnel {
    /// Start a quick tunnel to `local_http` (typically `http://127.0.0.1:8674`).
    ///
    /// `cloudflared` must already exist at `bin`. Use [`ensure_cloudflared`] first.
    pub fn start(cloudflared: &Path, local_http: &str) -> Result<Self> {
        if !cloudflared.is_file() {
            bail!("cloudflared not found at {}", cloudflared.display());
        }
        let mut child = Command::new(cloudflared)
            .args([
                "tunnel",
                "--url",
                local_http,
                "--no-autoupdate",
                // HTTP/2 is friendlier through broken UDP paths; QUIC is still tried first by default
                // in recent builds, but http2 is a reliable fallback flag for some networks.
                "--protocol",
                "http2",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawn {}", cloudflared.display()))?;

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let (tx, rx) = mpsc::channel::<String>();

        // cloudflared prints the trycloudflare URL on stderr (historically) and sometimes stdout.
        let pump = |stream: Option<std::process::ChildStdout>, tx: mpsc::Sender<String>| {
            if let Some(s) = stream {
                thread::spawn(move || {
                    for line in BufReader::new(s).lines().flatten() {
                        if let Some(url) = extract_trycloudflare_url(&line) {
                            let _ = tx.send(url);
                        }
                    }
                });
            }
        };
        let pump_err = |stream: Option<std::process::ChildStderr>, tx: mpsc::Sender<String>| {
            if let Some(s) = stream {
                thread::spawn(move || {
                    for line in BufReader::new(s).lines().flatten() {
                        if let Some(url) = extract_trycloudflare_url(&line) {
                            let _ = tx.send(url);
                        }
                    }
                });
            }
        };
        pump(stdout, tx.clone());
        pump_err(stderr, tx);

        let deadline = Instant::now() + Duration::from_secs(45);
        let public_url = loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                let _ = child.kill();
                let _ = child.wait();
                bail!("cloudflared did not print a trycloudflare.com URL within 45s");
            }
            match rx.recv_timeout(left.min(Duration::from_secs(1))) {
                Ok(url) => break url,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    // Still starting — check the child hasn't died.
                    if let Ok(Some(status)) = child.try_wait() {
                        bail!("cloudflared exited early: {status}");
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let _ = child.kill();
                    bail!("cloudflared output closed before a URL appeared");
                }
            }
        };

        Ok(Self { child, public_url })
    }
}

/// Pull a `https://….trycloudflare.com` URL out of a log line.
pub fn extract_trycloudflare_url(line: &str) -> Option<String> {
    // Typical: " | https://random-words.trycloudflare.com |"
    let lower = line.to_ascii_lowercase();
    let idx = lower.find("https://")?;
    let rest = &line[idx..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == '|' || c == '"' || c == '\'')
        .unwrap_or(rest.len());
    let url = rest[..end].trim_end_matches(['.', ',', ';', ')']);
    if url.contains("trycloudflare.com") {
        Some(url.to_string())
    } else {
        None
    }
}

/// Ensure a cloudflared binary exists, searching `search_dirs` then optionally downloading
/// into `install_dir` (first-launch path for the CLI).
///
/// Search order:
/// 1. Each dir in `search_dirs` for `cloudflared` / `cloudflared.exe`
/// 2. `PATH`
/// 3. Download into `install_dir` when `allow_download` is true
pub fn ensure_cloudflared(
    search_dirs: &[PathBuf],
    install_dir: &Path,
    allow_download: bool,
) -> Result<PathBuf> {
    let name = cloudflared_filename();
    for dir in search_dirs {
        let p = dir.join(name);
        if p.is_file() {
            return Ok(p);
        }
        // Tauri externalBin layout: cloudflared-<target-triple>
        if let Some(triple) = target_triple_hint() {
            let p2 = dir.join(format!("cloudflared-{triple}"));
            if p2.is_file() {
                return Ok(p2);
            }
            #[cfg(windows)]
            {
                let p3 = dir.join(format!("cloudflared-{triple}.exe"));
                if p3.is_file() {
                    return Ok(p3);
                }
            }
        }
    }
    // PATH
    if let Ok(path) = which_in_path(name) {
        return Ok(path);
    }
    if !allow_download {
        bail!(
            "cloudflared not found (looked in {} and PATH). Bundle it with the app or re-run with download enabled.",
            search_dirs
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    std::fs::create_dir_all(install_dir)
        .with_context(|| format!("create {}", install_dir.display()))?;
    let dest = install_dir.join(name);
    if dest.is_file() {
        return Ok(dest);
    }
    download_cloudflared(&dest)?;
    Ok(dest)
}

fn cloudflared_filename() -> &'static str {
    #[cfg(windows)]
    {
        "cloudflared.exe"
    }
    #[cfg(not(windows))]
    {
        "cloudflared"
    }
}

fn target_triple_hint() -> Option<&'static str> {
    // Best-effort for Tauri externalBin names; not used for download URL selection.
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        return Some("aarch64-apple-darwin");
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        return Some("x86_64-apple-darwin");
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        return Some("x86_64-pc-windows-msvc");
    }
    #[cfg(all(target_os = "windows", target_arch = "aarch64"))]
    {
        return Some("aarch64-pc-windows-msvc");
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        return Some("x86_64-unknown-linux-gnu");
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        return Some("aarch64-unknown-linux-gnu");
    }
    #[allow(unreachable_code)]
    None
}

/// Official GitHub asset name + whether it's a bare binary (vs .tgz).
fn download_asset() -> Result<(&'static str, bool)> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        return Ok(("cloudflared-darwin-arm64.tgz", true));
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        return Ok(("cloudflared-darwin-amd64.tgz", true));
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        return Ok(("cloudflared-linux-amd64", false));
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        return Ok(("cloudflared-linux-arm64", false));
    }
    #[cfg(all(target_os = "linux", target_arch = "arm"))]
    {
        return Ok(("cloudflared-linux-arm", false));
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        return Ok(("cloudflared-windows-amd64.exe", false));
    }
    #[cfg(all(target_os = "windows", target_arch = "x86"))]
    {
        return Ok(("cloudflared-windows-386.exe", false));
    }
    #[allow(unreachable_code)]
    Err(anyhow!(
        "no prebuilt cloudflared asset for this OS/arch — install cloudflared manually"
    ))
}

fn download_cloudflared(dest: &Path) -> Result<()> {
    let (asset, is_tgz) = download_asset()?;
    let url = format!(
        "https://github.com/cloudflare/cloudflared/releases/download/{CLOUDFLARED_VERSION}/{asset}"
    );
    let tmp = dest.with_extension("download");
    eprintln!("▸ downloading cloudflared {CLOUDFLARED_VERSION}…");
    eprintln!("  {url}");
    download_file(&url, &tmp)?;

    if is_tgz {
        // Extract cloudflared from the tarball into dest.
        extract_tgz_binary(&tmp, dest)?;
        let _ = std::fs::remove_file(&tmp);
    } else {
        std::fs::rename(&tmp, dest).or_else(|_| {
            std::fs::copy(&tmp, dest)?;
            std::fs::remove_file(&tmp)?;
            Ok::<(), std::io::Error>(())
        })?;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(dest)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(dest, perms)?;
    }
    eprintln!("✓ cloudflared installed at {}", dest.display());
    Ok(())
}

/// Download with curl (macOS/Linux) or PowerShell (Windows) — no extra crate.
fn download_file(url: &str, dest: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        let status = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "Invoke-WebRequest -Uri '{}' -OutFile '{}' -UseBasicParsing",
                    url,
                    dest.display()
                ),
            ])
            .status()
            .context("spawn powershell for download")?;
        if !status.success() {
            bail!("download failed: {status}");
        }
        return Ok(());
    }
    #[cfg(not(windows))]
    {
        let status = Command::new("curl")
            .args(["-fsSL", "-o"])
            .arg(dest)
            .arg(url)
            .status()
            .context("spawn curl for download")?;
        if !status.success() {
            bail!("curl download failed: {status}");
        }
        return Ok(());
    }
}

fn extract_tgz_binary(tgz: &Path, dest: &Path) -> Result<()> {
    // tar -xzf tgz -C parent cloudflared  (archive root is the binary name)
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let status = Command::new("tar")
        .args(["-xzf"])
        .arg(tgz)
        .arg("-C")
        .arg(parent)
        .status()
        .context("spawn tar")?;
    if !status.success() {
        bail!("tar extract failed: {status}");
    }
    // tarball extracts as `cloudflared` in parent; rename if needed.
    let extracted = parent.join("cloudflared");
    if extracted != dest && extracted.is_file() {
        std::fs::rename(&extracted, dest).or_else(|_| {
            std::fs::copy(&extracted, dest)?;
            std::fs::remove_file(&extracted)?;
            Ok::<(), std::io::Error>(())
        })?;
    }
    if !dest.is_file() {
        bail!("tar extract did not produce {}", dest.display());
    }
    Ok(())
}

fn which_in_path(name: &str) -> Result<PathBuf> {
    #[cfg(windows)]
    let path_os = std::env::var_os("PATH").unwrap_or_default();
    #[cfg(not(windows))]
    let path_os = std::env::var_os("PATH").unwrap_or_default();
    for dir in std::env::split_paths(&path_os) {
        let p = dir.join(name);
        if p.is_file() {
            return Ok(p);
        }
    }
    bail!("{name} not on PATH")
}

/// Directory containing the current executable (for "neighboring binary" installs).
pub fn executable_dir() -> Result<PathBuf> {
    let exe = std::env::current_exe().context("current_exe")?;
    Ok(exe
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_trycloudflare_url_from_log_lines() {
        let line = "2026-07-20T12:00:00Z INF | https://explicit-valium-park-copies.trycloudflare.com |";
        assert_eq!(
            extract_trycloudflare_url(line).as_deref(),
            Some("https://explicit-valium-park-copies.trycloudflare.com")
        );
        assert!(extract_trycloudflare_url("no url here").is_none());
        assert!(extract_trycloudflare_url("https://example.com").is_none());
    }
}
