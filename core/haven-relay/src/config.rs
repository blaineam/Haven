//! Relay configuration: parsed from CLI flags or a JSON config file, plus a persisted
//! identity seed so the relay's node id is stable across restarts (a circle keeps
//! pointing at the same relay).

use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::link::RelayLink;

/// Which media store-and-forward backend the relay serves.
///
/// * [`Local`](StoreBackend::Local) — the **default**: serve sealed blobs straight from a
///   local directory over the native `haven/blob/1` mailbox. Zero external dependencies,
///   nothing public, the headline "just run it" mode.
/// * [`Rclone`](StoreBackend::Rclone) — opt-in: run `rclone serve s3` against a named
///   rclone remote (any of rclone's ~70 backends) and expose it over `haven/s3/1`. rclone
///   owns the provider auth; Haven never holds a provider OAuth token.
/// * [`S3`](StoreBackend::S3) — opt-in: run `rclone serve s3` against a plain local data
///   dir (the classic store-and-forward) and expose it over `haven/s3/1`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StoreBackend {
    /// Serve sealed blobs from a local directory over `haven/blob/1`.
    Local,
    /// Serve an rclone remote (`<remote>:<path>`) over `haven/s3/1` via `rclone serve s3`.
    Rclone { remote: String },
    /// Serve a local data dir over `haven/s3/1` via `rclone serve s3`.
    S3,
    /// No media store; connection relay only.
    None,
}

/// Fully-resolved runtime configuration.
pub struct Config {
    /// The circle this relay serves (parsed from the link).
    pub link: RelayLink,
    /// Where the persisted identity seed + local store live.
    pub data_dir: PathBuf,
    /// 32-byte identity seed (loaded or freshly generated, then persisted).
    pub seed: [u8; 32],
    /// Which media store backend to run (or `None` for relay-only).
    pub backend: StoreBackend,
    /// Loopback port for the local `rclone serve s3` (S3 / rclone backends only).
    pub s3_port: u16,
    /// Path to the `rclone` binary (falls back to PATH lookup at run time).
    pub rclone_bin: Option<String>,
    /// Optional explicit rclone.conf path (so a remote resolves without env wrangling).
    pub rclone_config: Option<String>,
    /// Sibling relay node ids (64-hex) to mesh-replicate the mailbox with — every ~30s this
    /// relay pulls any sealed blob a peer holds that it lacks (and vice-versa, as peers do the
    /// same), so the circle's mailbox self-heals and any relay can join/leave freely. Only the
    /// local-disk store backend meshes (S3/rclone backends are external). `--peer <hex>` (repeatable).
    pub peers: Vec<String>,
    /// Bind address for the plain-HTTP blob interface — the DEFAULT cross-NAT media transport
    /// (the iroh blob ALPN drops datagrams on pure-relay cross-NAT paths). `None` = disabled
    /// (`--no-http`). Local-disk backend only.
    pub http_bind: Option<String>,
    /// Public URL clients should use to reach the HTTP interface (port-forward / reverse proxy /
    /// tunnel), e.g. `https://relay.example.com`. Printed for the operator to hand to circle
    /// members; defaults to the LAN address when unset.
    pub http_url: Option<String>,
    /// When true and `http_url` is unset, start a Cloudflare Quick Tunnel (`*.trycloudflare.com`)
    /// against the local HTTP interface so remote members can reach media without port-forwarding.
    /// Default ON for serious always-on deployments; `--no-tunnel` disables; `--http-url` wins
    /// unless `--tunnel-token` is also set (named custom domain).
    pub auto_tunnel: bool,
    /// Cloudflare Zero Trust tunnel **install token** (from the dashboard). With `--http-url`,
    /// runs bundled/downloaded cloudflared as a named connector for that stable domain.
    pub tunnel_token: Option<String>,
    /// Bearer token the HTTP interface requires (generated once, persisted next to the seed).
    pub http_token: String,
    /// Operator-chosen store retention (mailbox TTL override + optional media age/size
    /// limits). Defaults to today's behavior: 30-day mailbox TTL, media never deleted.
    pub retention: haven_net::blobstore::Retention,
    /// Embed open-source iroh-relay (DERP) so the circle can use this box as the transport
    /// fabric instead of n0. Default ON for local-disk always-on relays.
    pub derp_enabled: bool,
    /// Local bind for iroh-relay HTTP (TLS off — front door terminates). Default 127.0.0.1:3340.
    pub derp_bind: String,
    /// Public HTTPS URL for DERP (defaults to the media `http_url` / tunnel URL when empty).
    pub derp_url: Option<String>,
}

/// On-disk JSON config (the `--config` form), all fields optional except `link`.
#[derive(Deserialize)]
struct FileConfig {
    link: String,
    #[serde(default)]
    data_dir: Option<String>,
    /// Backend: "local" (default), "s3", "rclone", or "none".
    #[serde(default)]
    storage: Option<String>,
    /// rclone remote name (implies the rclone backend), e.g. "mydrive:haven".
    #[serde(default)]
    rclone_remote: Option<String>,
    #[serde(default = "default_s3_port")]
    s3_port: u16,
    #[serde(default)]
    rclone_bin: Option<String>,
    #[serde(default)]
    rclone_config: Option<String>,
    /// Sibling relay node ids (64-hex) to mesh-replicate the mailbox with.
    #[serde(default)]
    peers: Option<Vec<String>>,
    /// HTTP blob-interface bind address ("0.0.0.0:8674" default; "off" disables).
    #[serde(default)]
    http_bind: Option<String>,
    /// Public URL for the HTTP interface (reverse proxy / port-forward / tunnel).
    #[serde(default)]
    http_url: Option<String>,
    /// Auto Cloudflare Quick Tunnel when http_url is unset (default true).
    #[serde(default)]
    auto_tunnel: Option<bool>,
    /// Cloudflare tunnel install token for a custom domain (pair with http_url).
    #[serde(default)]
    tunnel_token: Option<String>,
    /// Embed iroh-relay DERP (default true for local storage).
    #[serde(default)]
    derp: Option<bool>,
    #[serde(default)]
    derp_bind: Option<String>,
    #[serde(default)]
    derp_url: Option<String>,
    /// Mailbox TTL override in days (default 30).
    #[serde(default)]
    mailbox_ttl_days: Option<u64>,
    /// Delete media not touched for this many days (0/absent = keep forever, the default).
    #[serde(default)]
    media_max_age_days: Option<u64>,
    /// Total-size cap on the media store, e.g. "50G" / "500M" (0/absent = unbounded).
    #[serde(default)]
    media_max_bytes: Option<String>,
}

fn default_s3_port() -> u16 {
    8333
}

impl Config {
    /// Parse from `run` subcommand args.
    ///
    /// `--link` is optional: with no flags at all, a previously-persisted link is loaded
    /// from the data dir (`link.json`) so `haven-relay run` is a true zero-arg restart.
    /// When `--link` *is* given it is persisted, so the next run needs no arguments.
    pub fn from_args(args: &[String]) -> Result<Self> {
        // --config short-circuits to the file form.
        if let Some(path) = arg_value(args, "--config") {
            return Self::from_file(&path);
        }

        let data_dir = arg_value(args, "--data")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(default_data_dir()));

        // Resolve the link: explicit --link wins (and is persisted); otherwise reuse the
        // persisted one. This is what makes `haven-relay run` restart-safe with no args.
        let link = match arg_value(args, "--link") {
            Some(code) => {
                let link = RelayLink::parse(&code)?;
                save_link(&data_dir, &link)?;
                link
            }
            None => load_link(&data_dir).map_err(|_| {
                anyhow!(
                    "no --link given and no saved circle link in {} — run once with \
                     `--link <code>` (the code the Haven app shows you)",
                    data_dir.display()
                )
            })?,
        };

        let s3_port = arg_value(args, "--s3-port")
            .map(|v| v.parse::<u16>())
            .transpose()
            .map_err(|_| anyhow!("--s3-port must be a number"))?
            .unwrap_or(8333);
        let rclone_bin = arg_value(args, "--rclone");
        let rclone_config = arg_value(args, "--rclone-config");

        // Backend resolution (local-disk is the default).
        let backend = if args.iter().any(|a| a == "--no-storage") {
            StoreBackend::None
        } else if let Some(remote) = arg_value(args, "--rclone-remote") {
            StoreBackend::Rclone { remote }
        } else if args.iter().any(|a| a == "--s3") {
            StoreBackend::S3
        } else {
            StoreBackend::Local
        };

        // Repeatable `--peer <hex>` flags → sibling relays to mesh-replicate with.
        let peers: Vec<String> = args
            .windows(2)
            .filter(|w| w[0] == "--peer")
            .map(|w| w[1].trim().to_lowercase())
            .filter(|h| h.len() == 64)
            .collect();

        // HTTP blob interface: on by default (the default cross-NAT media transport);
        // `--no-http` disables, `--http <bind>` overrides the bind address.
        let http_bind = if args.iter().any(|a| a == "--no-http") {
            None
        } else {
            Some(arg_value(args, "--http").unwrap_or_else(|| DEFAULT_HTTP_BIND.to_string()))
        };
        let http_url = arg_value(args, "--http-url");
        let tunnel_token = arg_value(args, "--tunnel-token");
        // Auto quick-tunnel: ON by default when no explicit public URL. `--no-tunnel` disables;
        // `--tunnel` forces on even if a stale config said otherwise. Named tunnel (url+token)
        // does not need auto_quick.
        let auto_tunnel = if args.iter().any(|a| a == "--no-tunnel") {
            false
        } else if args.iter().any(|a| a == "--tunnel") {
            true
        } else {
            http_url.is_none() && tunnel_token.is_none()
        };

        // Operator-chosen retention. Absent/0 media limits = today's behavior (never delete).
        let retention = resolve_retention(
            arg_value(args, "--mailbox-ttl-days")
                .map(|v| v.parse::<u64>().map_err(|_| anyhow!("--mailbox-ttl-days must be a number")))
                .transpose()?,
            arg_value(args, "--media-max-age-days")
                .map(|v| v.parse::<u64>().map_err(|_| anyhow!("--media-max-age-days must be a number")))
                .transpose()?,
            arg_value(args, "--media-max-bytes").as_deref(),
        )?;

        // Haven fabric (iroh DERP): default ON for local-disk relays so a linked Mac/Linux/CLI
        // box can replace n0. `--no-derp` disables; `--derp-bind` / `--derp-url` override.
        let derp_enabled = if args.iter().any(|a| a == "--no-derp") {
            false
        } else if args.iter().any(|a| a == "--derp") {
            true
        } else {
            matches!(backend, StoreBackend::Local)
        };
        let derp_bind =
            arg_value(args, "--derp-bind").unwrap_or_else(|| "127.0.0.1:3340".to_string());
        let derp_url = arg_value(args, "--derp-url");

        let seed = load_or_create_seed(&data_dir)?;
        let http_token = load_or_create_http_token(&data_dir)?;
        Ok(Self {
            link, data_dir, seed, backend, s3_port, rclone_bin, rclone_config, peers,
            http_bind, http_url, auto_tunnel, tunnel_token, http_token, retention,
            derp_enabled, derp_bind, derp_url,
        })
    }

    fn from_file(path: &str) -> Result<Self> {
        let raw = std::fs::read(path).map_err(|e| anyhow!("read config {path}: {e}"))?;
        let fc: FileConfig =
            serde_json::from_slice(&raw).map_err(|e| anyhow!("parse config {path}: {e}"))?;
        let link = RelayLink::parse(&fc.link)?;
        let data_dir = fc
            .data_dir
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(default_data_dir()));
        let seed = load_or_create_seed(&data_dir)?;

        let backend = match (fc.rclone_remote, fc.storage.as_deref()) {
            (Some(remote), _) => StoreBackend::Rclone { remote },
            (None, Some("none")) => StoreBackend::None,
            (None, Some("s3")) => StoreBackend::S3,
            (None, Some("rclone")) => {
                return Err(anyhow!("storage=\"rclone\" needs a rclone_remote"))
            }
            // "local" or unset → local-disk default.
            (None, _) => StoreBackend::Local,
        };

        // Persist the link so later zero-arg `haven-relay run` works too.
        save_link(&data_dir, &link)?;

        let http_bind = match fc.http_bind.as_deref() {
            Some("off") | Some("none") => None,
            Some(b) => Some(b.to_string()),
            None => Some(DEFAULT_HTTP_BIND.to_string()),
        };
        let http_token = load_or_create_http_token(&data_dir)?;
        let retention = resolve_retention(
            fc.mailbox_ttl_days,
            fc.media_max_age_days,
            fc.media_max_bytes.as_deref(),
        )?;
        let derp_enabled = fc.derp.unwrap_or(matches!(&backend, StoreBackend::Local));
        let derp_bind = fc.derp_bind.unwrap_or_else(|| "127.0.0.1:3340".to_string());
        let derp_url = fc.derp_url.filter(|u| !u.trim().is_empty());
        Ok(Self {
            link,
            data_dir,
            seed,
            backend,
            s3_port: fc.s3_port,
            rclone_bin: fc.rclone_bin,
            rclone_config: fc.rclone_config,
            peers: fc
                .peers
                .unwrap_or_default()
                .into_iter()
                .map(|h| h.trim().to_lowercase())
                .filter(|h| h.len() == 64)
                .collect(),
            http_bind,
            http_url: fc.http_url.clone(),
            auto_tunnel: fc.auto_tunnel.unwrap_or(
                fc.http_url.is_none() && fc.tunnel_token.as_ref().map(|t| t.is_empty()).unwrap_or(true),
            ),
            tunnel_token: fc.tunnel_token.filter(|t| !t.trim().is_empty()),
            http_token,
            retention,
            derp_enabled,
            derp_bind,
            derp_url,
        })
    }
}

/// Fold the operator's raw retention knobs into a [`haven_net::blobstore::Retention`].
/// Absent (or 0) media limits mean "keep media forever" — exactly the pre-retention
/// behavior — so a config written before these knobs existed resolves identically.
fn resolve_retention(
    mailbox_ttl_days: Option<u64>,
    media_max_age_days: Option<u64>,
    media_max_bytes: Option<&str>,
) -> Result<haven_net::blobstore::Retention> {
    let mut retention = haven_net::blobstore::Retention::default();
    if let Some(days) = mailbox_ttl_days {
        // The mailbox TTL is not optional (0 would delete every event instantly on the
        // hourly sweep) — refuse rather than guess.
        if days == 0 {
            return Err(anyhow!("--mailbox-ttl-days must be at least 1 (default 30)"));
        }
        retention.mailbox_ttl = std::time::Duration::from_secs(days * 24 * 3600);
    }
    if let Some(days) = media_max_age_days {
        if days > 0 {
            retention.media_max_age = Some(std::time::Duration::from_secs(days * 24 * 3600));
        }
    }
    if let Some(size) = media_max_bytes {
        let bytes = parse_size(size)?;
        if bytes > 0 {
            retention.media_max_bytes = Some(bytes);
        }
    }
    Ok(retention)
}

/// Parse a human size — plain bytes or a K/M/G/T suffix (optionally with a trailing B),
/// decimal allowed: "50G", "500M", "1.5T", "1073741824". Powers of 1024.
pub fn parse_size(s: &str) -> Result<u64> {
    let up = s.trim().to_ascii_uppercase();
    let up = up.strip_suffix('B').unwrap_or(&up);
    let (num, mult) = match up.chars().last() {
        Some('K') => (&up[..up.len() - 1], 1u64 << 10),
        Some('M') => (&up[..up.len() - 1], 1u64 << 20),
        Some('G') => (&up[..up.len() - 1], 1u64 << 30),
        Some('T') => (&up[..up.len() - 1], 1u64 << 40),
        _ => (up, 1u64),
    };
    let v: f64 = num
        .trim()
        .parse()
        .map_err(|_| anyhow!("bad size '{s}' — use bytes or K/M/G/T, e.g. 50G or 500M"))?;
    if !v.is_finite() || v < 0.0 {
        return Err(anyhow!("bad size '{s}'"));
    }
    Ok((v * mult as f64) as u64)
}

/// Default bind for the HTTP blob interface.
pub const DEFAULT_HTTP_BIND: &str = "0.0.0.0:8674";

/// The HTTP bearer token, generated once and persisted (owner-only) next to the seed so the
/// relay's token — like its node id — is stable across restarts.
pub fn load_or_create_http_token(data_dir: &(impl AsRef<Path> + ?Sized)) -> Result<String> {
    let dir = data_dir.as_ref();
    std::fs::create_dir_all(dir).map_err(|e| anyhow!("create {}: {e}", dir.display()))?;
    let path = dir.join("http_token");
    if let Ok(raw) = std::fs::read_to_string(&path) {
        let tok = raw.trim().to_string();
        if !tok.is_empty() {
            return Ok(tok);
        }
    }
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    let tok: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::write(&path, &tok).map_err(|e| anyhow!("write http token: {e}"))?;
    set_owner_only(&path);
    Ok(tok)
}

/// Persisted circle link, so `haven-relay run` (no args) is restart-safe.
#[derive(Serialize, Deserialize)]
struct LinkFile {
    link: String,
}

fn link_path(data_dir: &Path) -> PathBuf {
    data_dir.join("link.json")
}

/// Persist the circle link to the data dir (owner-only).
pub fn save_link(data_dir: &Path, link: &RelayLink) -> Result<()> {
    std::fs::create_dir_all(data_dir).map_err(|e| anyhow!("create {}: {e}", data_dir.display()))?;
    let path = link_path(data_dir);
    let lf = LinkFile { link: link.to_uri() };
    std::fs::write(&path, serde_json::to_vec_pretty(&lf)?).map_err(|e| anyhow!("write link: {e}"))?;
    set_owner_only(&path);
    Ok(())
}

/// Load the previously-persisted circle link.
pub fn load_link(data_dir: &Path) -> Result<RelayLink> {
    let raw = std::fs::read(link_path(data_dir)).map_err(|e| anyhow!("no saved link: {e}"))?;
    let lf: LinkFile = serde_json::from_slice(&raw).map_err(|e| anyhow!("saved link malformed: {e}"))?;
    RelayLink::parse(&lf.link)
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

/// Default data dir: `$HAVEN_RELAY_DIR` or `~/.haven-relay`.
pub fn default_data_dir() -> String {
    if let Ok(d) = std::env::var("HAVEN_RELAY_DIR") {
        return d;
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    format!("{home}/.haven-relay")
}

/// Persisted identity seed model: a fresh seed is generated once and saved with
/// owner-only permissions, so the relay's node id is stable across restarts.
#[derive(Serialize, Deserialize)]
struct SeedFile {
    seed_hex: String,
}

/// Load the relay's 32-byte identity seed, generating + persisting one on first run.
///
/// Order: `HAVEN_RELAY_SEED` env (64-hex) → `<data_dir>/identity.json` → generate + persist. The env
/// override exists specifically for Docker/Kubernetes, where a container recreated WITHOUT a durable
/// volume for `<data_dir>` would otherwise mint a brand-new node id on every restart (the identity
/// file lands in the ephemeral layer and is lost). Pinning the seed in the env keeps the relay's node
/// id — and therefore its address in every circle member's relay list — stable across restarts and
/// image updates, no volume required. Generate `openssl rand -hex 32`.
pub fn load_or_create_seed(data_dir: &(impl AsRef<Path> + ?Sized)) -> Result<[u8; 32]> {
    if let Ok(env_seed) = std::env::var("HAVEN_RELAY_SEED") {
        let trimmed = env_seed.trim();
        if !trimmed.is_empty() {
            match decode_hex32(trimmed) {
                Ok(bytes) => return Ok(bytes),
                Err(_) => return Err(anyhow!("HAVEN_RELAY_SEED must be exactly 64 hex chars (32 bytes)")),
            }
        }
    }

    let dir = data_dir.as_ref();
    std::fs::create_dir_all(dir).map_err(|e| anyhow!("create {}: {e}", dir.display()))?;
    let seed_path = dir.join("identity.json");

    if let Ok(raw) = std::fs::read(&seed_path) {
        if let Ok(sf) = serde_json::from_slice::<SeedFile>(&raw) {
            if let Ok(bytes) = decode_hex32(&sf.seed_hex) {
                return Ok(bytes);
            }
        }
    }

    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let sf = SeedFile { seed_hex: hex32(&seed) };
    std::fs::write(&seed_path, serde_json::to_vec_pretty(&sf)?)
        .map_err(|e| anyhow!("write seed: {e}"))?;
    set_owner_only(&seed_path);
    Ok(seed)
}

#[cfg(unix)]
fn set_owner_only(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}
#[cfg(not(unix))]
fn set_owner_only(_path: &Path) {}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn decode_hex32(s: &str) -> Result<[u8; 32]> {
    let s = s.trim();
    if s.len() != 64 {
        return Err(anyhow!("seed must be 64 hex chars"));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("bad hex"))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_size_accepts_human_forms() {
        assert_eq!(parse_size("0").unwrap(), 0);
        assert_eq!(parse_size("1024").unwrap(), 1024);
        assert_eq!(parse_size("500M").unwrap(), 500 * (1 << 20));
        assert_eq!(parse_size("50G").unwrap(), 50 * (1u64 << 30));
        assert_eq!(parse_size("50gb").unwrap(), 50 * (1u64 << 30));
        assert_eq!(parse_size("1.5T").unwrap(), (1.5 * (1u64 << 40) as f64) as u64);
        assert!(parse_size("watermelon").is_err());
        assert!(parse_size("-5G").is_err());
    }

    #[test]
    fn retention_defaults_to_todays_behavior() {
        // No knobs → exactly the pre-retention policy (30d mailbox, media forever).
        let r = resolve_retention(None, None, None).unwrap();
        assert_eq!(r, haven_net::blobstore::Retention::default());
        assert!(!r.media_limited());
        // 0 is the documented "unbounded / no limit" spelling for the media knobs.
        let r = resolve_retention(None, Some(0), Some("0")).unwrap();
        assert!(!r.media_limited());
        // Explicit limits land where the sweep reads them.
        let r = resolve_retention(Some(60), Some(90), Some("50G")).unwrap();
        assert_eq!(r.mailbox_ttl, std::time::Duration::from_secs(60 * 24 * 3600));
        assert_eq!(r.media_max_age, Some(std::time::Duration::from_secs(90 * 24 * 3600)));
        assert_eq!(r.media_max_bytes, Some(50 * (1u64 << 30)));
        // A zero mailbox TTL would delete every event on the next sweep — refused.
        assert!(resolve_retention(Some(0), None, None).is_err());
    }

    #[test]
    fn seed_persists_across_loads() {
        let tmp = std::env::temp_dir().join(format!("haven-relay-test-{}", std::process::id()));
        let a = load_or_create_seed(&tmp).unwrap();
        let b = load_or_create_seed(&tmp).unwrap();
        assert_eq!(a, b, "seed is stable across restarts");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
