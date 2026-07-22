//! **Haven relay path proxy** — one local HTTP origin that routes by path to the
//! dual-faced relay backends (and answers a small status surface itself).
//!
//! ```text
//! peer ──HTTPS──► cloudflared / nginx ──► path-proxy :8675
//!                                           │
//!          ┌──────────────┬─────────────────┼──────────────────┐
//!          ▼              ▼                 ▼                  ▼
//!    media :8674   fabric :3340      WS hairpin          status
//!    /k /l /t …   /relay /derp …    /webrtc/*         /  /_haven
//! ```
//!
//! | Kind | Paths | Backend |
//! |---|---|---|
//! | **Media** | `/k/…`, `/l/…`, `/t/…` | HTTP mailbox (`httprelay`) |
//! | **Fabric** | `/relay`, `/derp`, `/ping` (+ subpaths) | iroh-relay (DERP / live + call signaling) |
//! | **Hairpin** | `/webrtc`, `/webrtc/…` | WebSocket call-media bipipe (works over free CF) |
//! | **Status** | `/`, `/_haven`, `/_haven/…` | answered here (JSON route table) |
//!
//! WebSocket upgrades on fabric paths are preserved (raw-pipe after the 101).
//! Unknown paths get `404` with a short hint — not silently dumped onto media.

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use crate::ws_hairpin::{self, HairpinHub};

/// Default local bind for the unified front-door proxy.
pub const DEFAULT_PATH_ROUTER_BIND: &str = "127.0.0.1:8675";

// ── Route table ──────────────────────────────────────────────────────────────

/// Which logical service a request maps to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RouteKind {
    /// Sealed media / mailbox HTTP (`httprelay`).
    Media,
    /// iroh-relay DERP fabric (live frames + call-signaling hairpin over WSS).
    Fabric,
    /// WebSocket call-media hairpin (TCP/TLS-only path through free CF tunnels).
    Hairpin,
    /// Served by the proxy itself (health + route map).
    Status,
    /// No matching prefix — proxy returns 404.
    Unknown,
}

impl RouteKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::Fabric => "fabric",
            Self::Hairpin => "hairpin",
            Self::Status => "status",
            Self::Unknown => "unknown",
        }
    }
}

/// Classify a request path (with or without `?query`) into a [`RouteKind`].
///
/// This is the single source of truth for “what does this path mean on the
/// Haven public origin.”
pub fn classify_path(path: &str) -> RouteKind {
    let path = path.split('?').next().unwrap_or(path);
    let path = if path.is_empty() { "/" } else { path };

    // Status (proxy-local) — keep under /_haven so it never collides with store keys.
    if path == "/" || path == "/_haven" || path.starts_with("/_haven/") {
        return RouteKind::Status;
    }

    // Call-media WebSocket hairpin (free CF compatible).
    if path == "/webrtc" || path.starts_with("/webrtc/") {
        return RouteKind::Hairpin;
    }

    // Fabric — iroh-relay HTTP paths (see iroh_relay::http::{RELAY_PATH, RELAY_PROBE_PATH}).
    if path == "/relay"
        || path.starts_with("/relay/")
        || path == "/derp"
        || path.starts_with("/derp/")
        || path == "/ping"
        || path.starts_with("/ping/")
    {
        return RouteKind::Fabric;
    }

    // Media — httprelay verbs (GET/PUT/HEAD /k/, LIST /l/, TOUCH /t/).
    if path.starts_with("/k/") || path.starts_with("/l/") || path.starts_with("/t/") {
        return RouteKind::Media;
    }

    RouteKind::Unknown
}

// ── Config / server ──────────────────────────────────────────────────────────

/// Config for the path proxy.
#[derive(Clone, Debug)]
pub struct PathRouterConfig {
    /// Local bind (default `127.0.0.1:8675`). Empty string = disabled.
    pub bind: String,
    /// Media mailbox backend (`host:port`, no scheme). Empty = fabric/status only.
    pub media_backend: String,
    /// DERP fabric backend (`host:port`, no scheme). Empty = media/status only.
    pub derp_backend: String,
    /// Optional shared secret; if join JSON includes `token`, it must match.
    pub http_token: String,
}

impl Default for PathRouterConfig {
    fn default() -> Self {
        Self {
            bind: DEFAULT_PATH_ROUTER_BIND.into(),
            media_backend: "127.0.0.1:8674".into(),
            derp_backend: "127.0.0.1:3340".into(),
            http_token: String::new(),
        }
    }
}

/// Guard for a running path proxy. Drop aborts the accept loop.
pub struct PathRouter {
    /// Local address actually bound.
    pub local_addr: SocketAddr,
    _task: JoinHandle<()>,
}

impl PathRouter {
    /// Start the reverse proxy. Returns `None` only if bind is empty (disabled).
    pub async fn spawn(cfg: &PathRouterConfig) -> Result<Option<Self>> {
        if cfg.bind.trim().is_empty() {
            return Ok(None);
        }
        let bind: SocketAddr = cfg
            .bind
            .parse()
            .with_context(|| format!("invalid path-proxy bind {}", cfg.bind))?;
        let media = cfg.media_backend.trim().to_string();
        let derp = cfg.derp_backend.trim().to_string();
        let http_token = cfg.http_token.clone();
        let listener = TcpListener::bind(bind)
            .await
            .with_context(|| format!("path-proxy bind {bind}"))?;
        let local_addr = listener.local_addr().unwrap_or(bind);
        let state = Arc::new(ProxyState {
            media_backend: media,
            derp_backend: derp,
            http_token,
            local_addr,
            hairpin: Arc::new(HairpinHub::new()),
        });
        let task = tokio::spawn(async move {
            loop {
                let Ok((client, _)) = listener.accept().await else {
                    break;
                };
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    if let Err(_e) = handle_client(client, &state).await {
                        // Quiet by default — clients retry; avoid log spam on probe noise.
                    }
                });
            }
        });
        Ok(Some(Self {
            local_addr,
            _task: task,
        }))
    }

    pub fn local_port(&self) -> u16 {
        self.local_addr.port()
    }
}

struct ProxyState {
    media_backend: String,
    derp_backend: String,
    http_token: String,
    local_addr: SocketAddr,
    hairpin: Arc<HairpinHub>,
}

impl ProxyState {
    fn status_json(&self) -> String {
        let media = if self.media_backend.is_empty() {
            "null".into()
        } else {
            format!("\"{}\"", self.media_backend)
        };
        let fabric = if self.derp_backend.is_empty() {
            "null".into()
        } else {
            format!("\"{}\"", self.derp_backend)
        };
        format!(
            r#"{{"service":"haven-path-proxy","bind":"{}","routes":[{{"kind":"media","paths":["/k/*","/l/*","/t/*"],"backend":{media}}},{{"kind":"fabric","paths":["/relay","/relay/*","/derp","/derp/*","/ping","/ping/*"],"backend":{fabric},"note":"iroh DERP — live frames + call signaling"}},{{"kind":"hairpin","paths":["/webrtc","/webrtc/hairpin"],"backend":"local","note":"WebSocket call-media bipipe — works over free Cloudflare tunnels"}},{{"kind":"status","paths":["/","/_haven","/_haven/*"],"backend":"local"}}]}}"#,
            self.local_addr
        )
    }
}

async fn handle_client(mut client: TcpStream, state: &ProxyState) -> Result<()> {
    // Read request head (up to \r\n\r\n). Cap to avoid unbounded memory.
    const MAX_HEAD: usize = 64 * 1024;
    let mut head = Vec::with_capacity(1024);
    let mut buf = [0u8; 1024];
    loop {
        let n = client.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
        if head.len() > MAX_HEAD {
            return Err(anyhow!("request head too large"));
        }
        if head.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }

    let path = parse_request_path(&head).unwrap_or("/");
    let kind = classify_path(path);
    // Optional request log for diagnosing trycloudflare / browser oddities.
    // Enable with HAVEN_PATH_PROXY_LOG=/path/to/file (append).
    if let Ok(log_path) = std::env::var("HAVEN_PATH_PROXY_LOG") {
        let line = format!(
            "{:?} kind={} path={} head_first={:?}\n",
            std::time::SystemTime::now(),
            kind.as_str(),
            path,
            std::str::from_utf8(&head[..head.len().min(160)]).unwrap_or("?")
        );
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(line.as_bytes())
            });
    }

    match kind {
        RouteKind::Status => {
            serve_status(&mut client, &head, state).await?;
        }
        RouteKind::Media => {
            let backend = state.media_backend.as_str();
            if backend.is_empty() {
                write_simple(&mut client, 503, "media backend offline", b"media offline\n").await?;
            } else {
                proxy_to(&mut client, &head, backend).await?;
            }
        }
        RouteKind::Fabric => {
            let backend = state.derp_backend.as_str();
            if backend.is_empty() {
                write_simple(
                    &mut client,
                    503,
                    "fabric backend offline",
                    b"fabric (DERP) offline\n",
                )
                .await?;
            } else {
                proxy_to(&mut client, &head, backend).await?;
            }
        }
        RouteKind::Hairpin => {
            ws_hairpin::handle_hairpin(
                client,
                &head,
                Arc::clone(&state.hairpin),
                &state.http_token,
            )
            .await?;
        }
        RouteKind::Unknown => {
            let body = format!(
                "haven path proxy: unknown path `{path}`\n\
                 media:   /k/… /l/… /t/…\n\
                 fabric:  /relay /derp /ping\n\
                 hairpin: /webrtc/hairpin  (WebSocket call media over free CF)\n\
                 status:  /  /_haven\n"
            );
            write_simple(&mut client, 404, "no route", body.as_bytes()).await?;
        }
    }
    Ok(())
}

async fn serve_status(client: &mut TcpStream, head: &[u8], state: &ProxyState) -> Result<()> {
    let path = parse_request_path(head).unwrap_or("/");
    let path_only = path.split('?').next().unwrap_or(path);
    // HEAD/GET only for status.
    let method = parse_request_method(head).unwrap_or("GET");
    if method != "GET" && method != "HEAD" {
        write_simple(client, 405, "method not allowed", b"GET or HEAD only\n").await?;
        return Ok(());
    }
    // Browsers (Safari especially) treat unknown Content-Types + empty bodies as a *download*.
    // Prefer HTML for human visits (Accept: text/html); JSON for machines (/_haven, curl *).
    let accept = header_value(head, "accept").unwrap_or("");
    let wants_html = accept.contains("text/html");
    let is_routes = path_only == "/_haven/routes" || path_only == "/_haven";
    let is_root = path_only == "/";
    let (status, reason, content_type, body): (u16, &str, &str, String) =
        if is_root || is_routes {
            let json = state.status_json();
            if is_root && wants_html {
                (
                    200,
                    "ok",
                    "text/html; charset=utf-8",
                    status_html(&json, &state.local_addr.to_string()),
                )
            } else {
                (200, "ok", "application/json; charset=utf-8", json)
            }
        } else {
            (
                404,
                "not found",
                "application/json; charset=utf-8",
                format!(r#"{{"error":"not found","path":"{path_only}"}}"#),
            )
        };
    let body_bytes = body.as_bytes();
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         X-Haven-Path-Proxy: 1\r\n\
         Connection: close\r\n\
         \r\n",
        body_bytes.len()
    );
    client.write_all(resp.as_bytes()).await?;
    if method != "HEAD" {
        client.write_all(body_bytes).await?;
    }
    let _ = client.shutdown().await;
    Ok(())
}

fn status_html(json: &str, bind: &str) -> String {
    // Escape for HTML text node (json is our own ASCII).
    let escaped = json.replace('&', "&amp;").replace('<', "&lt;");
    format!(
        r#"<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Haven relay</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;line-height:1.45;color:#111}}
 code,pre{{font-size:.85rem;background:#f4f4f5;padding:.15rem .35rem;border-radius:4px}}
 pre{{padding:1rem;overflow:auto}}
 .ok{{color:#15803d;font-weight:600}}
</style></head><body>
<h1>Haven path proxy</h1>
<p class="ok">Front door is up.</p>
<p>This URL is the <strong>public HTTPS origin</strong> for a circle relay (media + iroh fabric + call hairpin).
It is not a website — Haven clients use signed API paths. Opening it in a browser only checks that the tunnel reaches this host.</p>
<p>Local bind: <code>{bind}</code></p>
<ul>
 <li><code>/k/*</code> <code>/l/*</code> <code>/t/*</code> — sealed media mailbox</li>
 <li><code>/relay</code> <code>/derp</code> <code>/ping</code> — iroh DERP fabric</li>
 <li><code>/webrtc/hairpin</code> — call media over free Cloudflare</li>
</ul>
<pre>{escaped}</pre>
</body></html>"#
    )
}

fn header_value<'a>(head: &'a [u8], name: &str) -> Option<&'a str> {
    let text = std::str::from_utf8(head).ok()?;
    let want = name.to_ascii_lowercase();
    for line in text.lines().skip(1) {
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case(&want) {
                return Some(v.trim());
            }
        }
    }
    None
}

async fn write_simple(client: &mut TcpStream, status: u16, reason: &str, body: &[u8]) -> Result<()> {
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         X-Haven-Path-Proxy: 1\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    );
    client.write_all(resp.as_bytes()).await?;
    client.write_all(body).await?;
    let _ = client.shutdown().await;
    Ok(())
}

async fn proxy_to(client: &mut TcpStream, head: &[u8], backend: &str) -> Result<()> {
    let mut upstream = TcpStream::connect(backend)
        .await
        .with_context(|| format!("connect backend {backend}"))?;

    // Rewrite Host to the backend and force Connection: close so keep-alive reuse cannot
    // leave cloudflared mid-stream on a previous media/DERP hop (Safari 0-byte downloads
    // were often media 401 application/octet-stream from a confused origin path).
    let rewritten = rewrite_proxy_head(head, backend);
    upstream.write_all(&rewritten).await?;

    let (mut cr, mut cw) = client.split();
    let (mut ur, mut uw) = upstream.split();
    let c2u = async {
        let mut buf = [0u8; 16 * 1024];
        loop {
            let n = cr.read(&mut buf).await?;
            if n == 0 {
                let _ = uw.shutdown().await;
                break;
            }
            uw.write_all(&buf[..n]).await?;
        }
        Ok::<(), std::io::Error>(())
    };
    let u2c = async {
        let mut buf = [0u8; 16 * 1024];
        loop {
            let n = ur.read(&mut buf).await?;
            if n == 0 {
                let _ = cw.shutdown().await;
                break;
            }
            cw.write_all(&buf[..n]).await?;
        }
        Ok::<(), std::io::Error>(())
    };
    // Finish both directions; Connection: close on the rewritten head limits keep-alive reuse.
    let _ = tokio::join!(c2u, u2c);
    Ok(())
}

/// Adjust request head for a single-origin reverse proxy hop.
fn rewrite_proxy_head(head: &[u8], backend: &str) -> Vec<u8> {
    let Ok(text) = std::str::from_utf8(head) else {
        return head.to_vec();
    };
    let Some(split) = text.find("\r\n\r\n") else {
        return head.to_vec();
    };
    let header_block = &text[..split];
    let rest = &text[split + 4..]; // may include already-read body bytes
    let lines: Vec<&str> = header_block.split("\r\n").collect();
    if lines.is_empty() {
        return head.to_vec();
    }
    // request line stays; rewrite Host + Connection.
    let mut out = String::with_capacity(head.len() + 32);
    out.push_str(lines[0]);
    out.push_str("\r\n");
    let mut saw_host = false;
    let mut saw_conn = false;
    for line in lines.iter().skip(1) {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("host:") {
            out.push_str("Host: ");
            out.push_str(backend);
            out.push_str("\r\n");
            saw_host = true;
            continue;
        }
        if lower.starts_with("connection:") {
            out.push_str("Connection: close\r\n");
            saw_conn = true;
            continue;
        }
        // Drop hop-by-hop headers that confuse keep-alive pooling through free CF.
        if lower.starts_with("keep-alive:") || lower.starts_with("proxy-connection:") {
            continue;
        }
        out.push_str(line);
        out.push_str("\r\n");
    }
    if !saw_host {
        out.push_str("Host: ");
        out.push_str(backend);
        out.push_str("\r\n");
    }
    if !saw_conn {
        out.push_str("Connection: close\r\n");
    }
    out.push_str("\r\n");
    out.push_str(rest);
    out.into_bytes()
}

/// Extract the request-target path from a raw HTTP request head.
fn parse_request_path(head: &[u8]) -> Option<&str> {
    let text = std::str::from_utf8(head).ok()?;
    let line = text.lines().next()?;
    // "GET /path HTTP/1.1"
    let mut parts = line.split_whitespace();
    let _method = parts.next()?;
    let target = parts.next()?;
    // Absolute-form request-target: "http://host/path" — rare for reverse proxies.
    if let Some(idx) = target.find("://") {
        let after = &target[idx + 3..];
        let path = after.find('/').map(|i| &after[i..]).unwrap_or("/");
        return Some(path);
    }
    Some(target)
}

fn parse_request_method(head: &[u8]) -> Option<&str> {
    let text = std::str::from_utf8(head).ok()?;
    let line = text.lines().next()?;
    line.split_whitespace().next()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_media() {
        assert_eq!(classify_path("/k/haven/media/x"), RouteKind::Media);
        assert_eq!(classify_path("/l/haven/mailbox/c"), RouteKind::Media);
        assert_eq!(classify_path("/t/haven/mailbox/c"), RouteKind::Media);
        assert_eq!(classify_path("/k/x?q=1"), RouteKind::Media);
    }

    #[test]
    fn classifies_fabric() {
        assert_eq!(classify_path("/relay"), RouteKind::Fabric);
        assert_eq!(classify_path("/relay?token=x"), RouteKind::Fabric);
        assert_eq!(classify_path("/relay/extra"), RouteKind::Fabric);
        assert_eq!(classify_path("/derp"), RouteKind::Fabric);
        assert_eq!(classify_path("/derp/ws"), RouteKind::Fabric);
        assert_eq!(classify_path("/ping"), RouteKind::Fabric);
        assert_eq!(classify_path("/ping/"), RouteKind::Fabric);
    }

    #[test]
    fn classifies_status() {
        assert_eq!(classify_path("/"), RouteKind::Status);
        assert_eq!(classify_path("/_haven"), RouteKind::Status);
        assert_eq!(classify_path("/_haven/routes"), RouteKind::Status);
    }

    #[test]
    fn classifies_hairpin() {
        assert_eq!(classify_path("/webrtc"), RouteKind::Hairpin);
        assert_eq!(classify_path("/webrtc/hairpin"), RouteKind::Hairpin);
        assert_eq!(classify_path("/webrtc/hairpin?x=1"), RouteKind::Hairpin);
    }

    #[test]
    fn classifies_unknown() {
        assert_eq!(classify_path("/api/v1"), RouteKind::Unknown);
        assert_eq!(classify_path("/favicon.ico"), RouteKind::Unknown);
        assert_eq!(classify_path("/turn"), RouteKind::Unknown); // TURN is UDP, not HTTP
    }

    #[test]
    fn parse_path() {
        let h = b"GET /k/abc HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(parse_request_path(h), Some("/k/abc"));
        let h2 = b"GET /relay HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(parse_request_path(h2), Some("/relay"));
        let h3 = b"GET http://example.com/relay HTTP/1.1\r\n\r\n";
        assert_eq!(parse_request_path(h3), Some("/relay"));
        assert_eq!(parse_request_method(h), Some("GET"));
    }
}
