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
//! ## Updating the pin (no manual signing)
//!
//! Bump [`CLOUDFLARED_VERSION`] only. CI does the rest every build:
//! - **Xcode Cloud:** `ci_post_clone` re-fetches → HavenMac post-build codesigns with
//!   `EXPANDED_CODE_SIGN_IDENTITY` (`apple/Scripts/embed-cloudflared.sh`).
//! - **Microsoft Store MSIX:** `release.yml` embeds `cloudflared.exe`; Partner Center
//!   re-signs the package on upload (no Authenticode step).
//!
//! `tools/fetch-cloudflared.sh` reads this same version string so the CLI/desktop/Apple
//! helpers never drift.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};

/// Pinned cloudflared release — **single source of truth** (fetch script greps this line).
/// Bump this string only; never hand-sign the binary after an update.
pub const CLOUDFLARED_VERSION: &str = "2026.7.2";

/// How to run the bundled `cloudflared` connector.
#[derive(Clone, Debug)]
pub enum TunnelSpec {
    /// Free ephemeral `*.trycloudflare.com` — hostname changes every restart.
    Quick {
        /// e.g. `http://127.0.0.1:8674`
        local_http: String,
    },
    /// Named Cloudflare Tunnel with a **stable custom domain**.
    ///
    /// Easy path (Zero Trust dashboard):
    /// 1. Create a tunnel → add a public hostname (`relay.example.com` → `http://127.0.0.1:8674`)
    /// 2. Copy the install **token**
    /// 3. Paste token + `https://relay.example.com` into Haven
    ///
    /// Haven runs `cloudflared tunnel run --token …` and announces `public_url` to the circle.
    NamedToken {
        token: String,
        /// What members should use — e.g. `https://relay.example.com`
        public_url: String,
    },
}

/// A running cloudflared process (quick or named). Dropping this kills the child.
pub struct QuickTunnel {
    child: Child,
    /// Announced public HTTPS URL (trycloudflare or the user's custom domain).
    pub public_url: String,
    /// `"quick"` or `"named"`.
    pub kind: &'static str,
}

impl Drop for QuickTunnel {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl QuickTunnel {
    /// Start from a [`TunnelSpec`] — prefer this over the mode-specific helpers.
    pub fn start_spec(cloudflared: &Path, spec: TunnelSpec) -> Result<Self> {
        match spec {
            TunnelSpec::Quick { local_http } => Self::start(cloudflared, &local_http),
            TunnelSpec::NamedToken { token, public_url } => {
                Self::start_named_token(cloudflared, &token, &public_url)
            }
        }
    }

    /// Start a free quick tunnel to `local_http` (typically `http://127.0.0.1:8674`).
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

        let public_url = wait_for_log_signal(
            &mut child,
            Duration::from_secs(45),
            |line| extract_trycloudflare_url(line),
            "cloudflared did not print a trycloudflare.com URL within 45s",
        )?;

        Ok(Self {
            child,
            public_url,
            kind: "quick",
        })
    }

    /// Run a **named** Cloudflare Tunnel with a dashboard install token + stable public URL.
    ///
    /// The public hostname and origin (`http://127.0.0.1:8674`) must already be configured in the
    /// Cloudflare Zero Trust tunnel UI — the token only authenticates this connector.
    pub fn start_named_token(cloudflared: &Path, token: &str, public_url: &str) -> Result<Self> {
        if !cloudflared.is_file() {
            bail!("cloudflared not found at {}", cloudflared.display());
        }
        let token = token.trim();
        if token.is_empty() {
            bail!("cloudflare tunnel token is empty");
        }
        let public_url = normalize_public_url(public_url)?;
        let mut child = Command::new(cloudflared)
            .args([
                "tunnel",
                "--no-autoupdate",
                "--protocol",
                "http2",
                "run",
                "--token",
                token,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawn named tunnel {}", cloudflared.display()))?;

        // Named tunnels don't print a trycloudflare URL — wait until the connector registers
        // (or stay healthy for a few seconds if log wording changes).
        let ready = wait_for_log_signal(
            &mut child,
            Duration::from_secs(45),
            |line| {
                let l = line.to_ascii_lowercase();
                if l.contains("registered tunnel connection")
                    || l.contains("connection registered")
                    || l.contains("connindex=")
                    || (l.contains("tunnel") && l.contains("connected"))
                {
                    Some(())
                } else {
                    None
                }
            },
            "cloudflared named tunnel did not register within 45s — check the token and that the \
             public hostname's service is http://127.0.0.1:8674 in the Cloudflare dashboard",
        );
        match ready {
            Ok(()) => {}
            Err(e) => {
                // Soft path: process still running after a short grace — accept and announce.
                if child.try_wait().ok().flatten().is_none() {
                    // Give the edge a moment; many builds log differently.
                    thread::sleep(Duration::from_secs(3));
                    if child.try_wait().ok().flatten().is_some() {
                        return Err(e);
                    }
                } else {
                    return Err(e);
                }
            }
        }

        Ok(Self {
            child,
            public_url,
            kind: "named",
        })
    }
}

/// Normalize a user-entered public URL to `https://host[:port][/path]` without a trailing slash.
pub fn normalize_public_url(raw: &str) -> Result<String> {
    let t = raw.trim().trim_end_matches('/');
    if t.is_empty() {
        bail!("public URL is empty");
    }
    let with_scheme = if t.starts_with("https://") || t.starts_with("http://") {
        t.to_string()
    } else {
        format!("https://{t}")
    };
    // Require a host-looking string after the scheme.
    let host = with_scheme
        .split("://")
        .nth(1)
        .unwrap_or("")
        .split('/')
        .next()
        .unwrap_or("");
    if host.is_empty() || !host.contains('.') {
        bail!("public URL needs a real hostname (e.g. https://relay.example.com)");
    }
    Ok(with_scheme)
}

/// How the operator wants the public HTTPS front door to work.
///
/// **Manual is intentional and first-class** — if Cloudflare ever restricts free trycloudflare
/// or token install, operators set a stable URL and run *any* tunnel/proxy themselves
/// (cloudflared service, Caddy, nginx, Tailscale Funnel, etc.). Haven only announces the URL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrontDoorMode {
    /// Free ephemeral trycloudflare when no custom URL is set (default for first-run).
    Auto,
    /// Operator runs the tunnel/proxy; Haven only announces [`public_url`].
    Manual,
    /// Haven runs bundled `cloudflared` with a Zero Trust install token + custom domain.
    Bundled,
}

impl FrontDoorMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Manual => "manual",
            Self::Bundled => "bundled",
        }
    }

    /// Parse prefs / CLI / UI values. Unknown → `Auto`.
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "manual" | "external" | "announce" => Self::Manual,
            "bundled" | "named" | "token" => Self::Bundled,
            _ => Self::Auto,
        }
    }
}

/// What to do when the relay HTTP interface comes up.
#[derive(Clone, Debug)]
pub enum FrontDoorAction {
    /// Spawn bundled cloudflared (quick or named).
    Spawn(TunnelSpec),
    /// Do not spawn cloudflared — announce this public URL only (manual / external front door).
    AnnounceOnly { public_url: String },
    /// No public HTTPS — callers use LAN (if any) or iroh.
    LanOnly,
}

/// Resolve operator prefs into a concrete front-door action.
///
/// Prefer an explicit [`FrontDoorMode`]. When `mode` is `Auto`, flags still infer:
/// - URL + token → bundled named
/// - URL only → **manual** (announce-only — proper external-tunnel path)
/// - neither + `auto_quick` → free trycloudflare
///
/// `auto_quick` is ignored for `Manual` and `Bundled` (those modes never fall back to free).
pub fn resolve_front_door(
    mode: FrontDoorMode,
    public_url: Option<&str>,
    tunnel_token: Option<&str>,
    auto_quick: bool,
    local_http: &str,
) -> Result<FrontDoorAction> {
    let url_raw = public_url.map(str::trim).filter(|s| !s.is_empty());
    let token = tunnel_token.map(str::trim).filter(|s| !s.is_empty());

    // Explicit mode wins — this is what keeps Manual correct if free/token paths go away.
    match mode {
        FrontDoorMode::Manual => {
            let u = url_raw.ok_or_else(|| {
                anyhow!(
                    "manual front door needs a public URL (e.g. https://relay.example.com) — \
                     run your own tunnel/proxy to http://127.0.0.1:8674, then paste that HTTPS URL"
                )
            })?;
            Ok(FrontDoorAction::AnnounceOnly {
                public_url: normalize_public_url(u)?,
            })
        }
        FrontDoorMode::Bundled => {
            let u = url_raw.ok_or_else(|| {
                anyhow!("bundled Cloudflare tunnel needs a public URL (your custom domain)")
            })?;
            let t = token.ok_or_else(|| {
                anyhow!(
                    "bundled mode needs a Cloudflare tunnel install token from the Zero Trust dashboard"
                )
            })?;
            Ok(FrontDoorAction::Spawn(TunnelSpec::NamedToken {
                token: t.to_string(),
                public_url: normalize_public_url(u)?,
            }))
        }
        FrontDoorMode::Auto => {
            // Infer from fields so old prefs (no mode key) keep working.
            match (url_raw, token) {
                (Some(u), Some(t)) => Ok(FrontDoorAction::Spawn(TunnelSpec::NamedToken {
                    token: t.to_string(),
                    public_url: normalize_public_url(u)?,
                })),
                (Some(u), None) => Ok(FrontDoorAction::AnnounceOnly {
                    public_url: normalize_public_url(u)?,
                }),
                (None, Some(_)) => bail!(
                    "Cloudflare tunnel token needs a public URL (or set front-door mode to bundled)"
                ),
                (None, None) if auto_quick => Ok(FrontDoorAction::Spawn(TunnelSpec::Quick {
                    local_http: local_http.to_string(),
                })),
                (None, None) => Ok(FrontDoorAction::LanOnly),
            }
        }
    }
}

/// Back-compat wrapper: returns a spawnable [`TunnelSpec`] only (Manual / Lan → `None`).
pub fn resolve_tunnel_spec(
    public_url: Option<&str>,
    tunnel_token: Option<&str>,
    auto_quick: bool,
    local_http: &str,
) -> Result<Option<TunnelSpec>> {
    match resolve_front_door(
        FrontDoorMode::Auto,
        public_url,
        tunnel_token,
        auto_quick,
        local_http,
    )? {
        FrontDoorAction::Spawn(s) => Ok(Some(s)),
        FrontDoorAction::AnnounceOnly { .. } | FrontDoorAction::LanOnly => Ok(None),
    }
}

fn wait_for_log_signal<T, F>(
    child: &mut Child,
    timeout: Duration,
    match_line: F,
    timeout_msg: &str,
) -> Result<T>
where
    F: Fn(&str) -> Option<T> + Send + Sync + 'static,
    T: Send + 'static,
{
    use std::sync::Arc;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let (tx, rx) = mpsc::channel::<T>();
    let match_line = Arc::new(match_line);

    let spawn_pump = |reader: Box<dyn std::io::Read + Send>,
                      tx: mpsc::Sender<T>,
                      match_line: Arc<F>| {
        thread::spawn(move || {
            for line in BufReader::new(reader).lines().flatten() {
                if let Some(v) = match_line(&line) {
                    let _ = tx.send(v);
                    return;
                }
            }
        });
    };
    if let Some(s) = stdout {
        spawn_pump(Box::new(s), tx.clone(), Arc::clone(&match_line));
    }
    if let Some(s) = stderr {
        spawn_pump(Box::new(s), tx, match_line);
    }

    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{timeout_msg}");
        }
        match rx.recv_timeout(left.min(Duration::from_secs(1))) {
            Ok(v) => return Ok(v),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Ok(Some(status)) = child.try_wait() {
                    bail!("cloudflared exited early: {status}");
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = child.kill();
                bail!("cloudflared output closed before ready");
            }
        }
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

    #[test]
    fn normalize_public_url_adds_https() {
        assert_eq!(
            normalize_public_url("relay.example.com").unwrap(),
            "https://relay.example.com"
        );
        assert_eq!(
            normalize_public_url("https://relay.example.com/").unwrap(),
            "https://relay.example.com"
        );
    }

    #[test]
    fn resolve_named_needs_url_and_token() {
        let s = resolve_tunnel_spec(
            Some("https://relay.example.com"),
            Some("eyJtoken"),
            true,
            "http://127.0.0.1:8674",
        )
        .unwrap()
        .unwrap();
        match s {
            TunnelSpec::NamedToken { public_url, .. } => {
                assert_eq!(public_url, "https://relay.example.com");
            }
            _ => panic!("expected named"),
        }
        // URL alone → external (Haven does not spawn cloudflared).
        assert!(resolve_tunnel_spec(
            Some("https://relay.example.com"),
            None,
            true,
            "http://127.0.0.1:8674",
        )
        .unwrap()
        .is_none());
        // Auto quick when nothing set.
        assert!(matches!(
            resolve_tunnel_spec(None, None, true, "http://127.0.0.1:8674")
                .unwrap()
                .unwrap(),
            TunnelSpec::Quick { .. }
        ));
    }

    #[test]
    fn manual_mode_is_announce_only_never_spawns() {
        let a = resolve_front_door(
            FrontDoorMode::Manual,
            Some("relay.example.com"),
            Some("should-be-ignored"),
            true, // auto_quick ignored in manual
            "http://127.0.0.1:8674",
        )
        .unwrap();
        match a {
            FrontDoorAction::AnnounceOnly { public_url } => {
                assert_eq!(public_url, "https://relay.example.com");
            }
            _ => panic!("manual must not spawn cloudflared"),
        }
        assert!(resolve_front_door(
            FrontDoorMode::Manual,
            None,
            None,
            true,
            "http://127.0.0.1:8674",
        )
        .is_err());
    }

    #[test]
    fn bundled_mode_requires_token_and_url() {
        assert!(resolve_front_door(
            FrontDoorMode::Bundled,
            Some("https://relay.example.com"),
            None,
            false,
            "http://127.0.0.1:8674",
        )
        .is_err());
        let a = resolve_front_door(
            FrontDoorMode::Bundled,
            Some("https://relay.example.com"),
            Some("tok"),
            false,
            "http://127.0.0.1:8674",
        )
        .unwrap();
        assert!(matches!(a, FrontDoorAction::Spawn(TunnelSpec::NamedToken { .. })));
    }

    #[test]
    fn auto_url_only_is_manual_announce() {
        let a = resolve_front_door(
            FrontDoorMode::Auto,
            Some("https://relay.example.com"),
            None,
            true,
            "http://127.0.0.1:8674",
        )
        .unwrap();
        assert!(matches!(a, FrontDoorAction::AnnounceOnly { .. }));
    }
}
