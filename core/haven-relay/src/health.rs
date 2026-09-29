//! Self health check.
//!
//! The running relay probes itself every 30 s — HTTP interface answers, iroh endpoint bound,
//! blob store readable — and writes the verdict to `<data>/health.json` (version, booleans,
//! timestamp; nothing about peers or traffic). Two consumers:
//!
//! * `haven-relay health` (the Docker HEALTHCHECK, or any monitor): exit 0 when the last verdict
//!   is healthy AND fresh.
//! * the post-update probation: the first healthy verdict of a freshly-installed binary commits
//!   the update (see `update::confirm_healthy`); no healthy verdict in time → rollback.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// How often the relay re-probes itself.
pub const PROBE_INTERVAL: Duration = Duration::from_secs(30);
/// `haven-relay health` treats a verdict older than this as stale (relay hung or gone).
pub const DEFAULT_MAX_AGE_SECS: u64 = 180;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub v: u32,
    pub version: String,
    pub ok: bool,
    pub http: bool,
    pub iroh: bool,
    pub store: bool,
    pub ts: u64,
}

/// What to probe. `None` fields are "not configured here" and count as passing.
#[derive(Clone, Default)]
pub struct Probe {
    /// Address of the local HTTP media interface.
    pub http_addr: Option<std::net::SocketAddr>,
    pub node: Option<Arc<haven_net::Node>>,
    pub store: Option<PathBuf>,
}

/// Where to dial the HTTP interface bound at `bind` on `port` (unspecified → loopback).
pub fn local_http_addr(bind: &str, port: u16) -> Option<std::net::SocketAddr> {
    let ip = bind
        .rsplit_once(':')
        .and_then(|(h, _)| h.trim_matches(['[', ']']).parse::<std::net::IpAddr>().ok())
        .unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
    let ip = if ip.is_unspecified() {
        if ip.is_ipv6() { std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST) } else { std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST) }
    } else {
        ip
    };
    Some(std::net::SocketAddr::new(ip, port))
}

/// Does something answer HTTP at `addr`? Any `HTTP/1.x` status line counts (the media port answers
/// `/` with a 404 page by design) — this checks liveness, not authorization.
pub async fn http_answers(addr: std::net::SocketAddr) -> bool {
    let fut = async {
        let mut s = tokio::net::TcpStream::connect(addr).await.ok()?;
        s.write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").await.ok()?;
        let mut buf = [0u8; 12];
        let mut got = 0;
        while got < 8 {
            let n = s.read(&mut buf[got..]).await.ok()?;
            if n == 0 {
                break;
            }
            got += n;
        }
        Some(buf[..got].starts_with(b"HTTP/1."))
    };
    tokio::time::timeout(Duration::from_secs(5), fut).await.ok().flatten().unwrap_or(false)
}

/// Can we list the store directory?
pub fn store_readable(p: &Path) -> bool {
    std::fs::read_dir(p).is_ok()
}

impl Probe {
    pub async fn check(&self, version: &str) -> Report {
        let http = match self.http_addr {
            Some(a) => http_answers(a).await,
            None => true,
        };
        let iroh = self.node.as_ref().map(|n| n.endpoint_bound()).unwrap_or(true);
        let store = self.store.as_deref().map(store_readable).unwrap_or(true);
        Report {
            v: 1,
            version: version.to_string(),
            ok: http && iroh && store,
            http,
            iroh,
            store,
            ts: crate::update::install::now_secs(),
        }
    }
}

pub fn health_path(data_dir: &Path) -> PathBuf {
    data_dir.join("health.json")
}

fn write_report(data_dir: &Path, r: &Report) {
    let path = health_path(data_dir);
    let tmp = data_dir.join(format!("health.json.{}.tmp", std::process::id()));
    if let Ok(bytes) = serde_json::to_vec(r) {
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

/// Probe forever; the first healthy verdict calls `on_first_healthy` once. State transitions
/// (healthy ↔ unhealthy) are printed — the component names only, nothing else.
pub fn spawn(probe: Probe, data_dir: PathBuf, on_first_healthy: impl FnOnce() + Send + 'static) {
    tokio::spawn(async move {
        let mut first = Some(on_first_healthy);
        let mut last_ok: Option<bool> = None;
        // A quick first probe so probation doesn't wait a full interval.
        tokio::time::sleep(Duration::from_secs(3)).await;
        loop {
            let r = probe.check(crate::update::VERSION).await;
            write_report(&data_dir, &r);
            if r.ok {
                if let Some(f) = first.take() {
                    f();
                }
            }
            if last_ok != Some(r.ok) {
                if r.ok {
                    if last_ok.is_some() {
                        println!("✓ health: all checks passing again.");
                    }
                } else {
                    let failing: Vec<&str> = [("http", r.http), ("iroh", r.iroh), ("store", r.store)]
                        .iter()
                        .filter(|(_, ok)| !ok)
                        .map(|(n, _)| *n)
                        .collect();
                    eprintln!("⚠ health: failing — {}", failing.join(", "));
                }
                last_ok = Some(r.ok);
            }
            tokio::time::sleep(if r.ok { PROBE_INTERVAL } else { Duration::from_secs(5) }).await;
        }
    });
}

/// Evaluate a stored report: `Ok(())` healthy, `Err(reason)` otherwise.
pub fn evaluate(r: Option<&Report>, now: u64, max_age: u64) -> Result<(), String> {
    let r = r.ok_or("no health report yet (relay starting, or not running)")?;
    if now.saturating_sub(r.ts) > max_age {
        return Err(format!("health report is stale ({}s old) — relay hung or stopped", now.saturating_sub(r.ts)));
    }
    if !r.ok {
        let mut bad = Vec::new();
        if !r.http {
            bad.push("HTTP interface not answering");
        }
        if !r.iroh {
            bad.push("iroh endpoint not bound");
        }
        if !r.store {
            bad.push("blob store unreadable");
        }
        return Err(bad.join(", "));
    }
    Ok(())
}

/// `haven-relay health [--data DIR] [--max-age SECS]` — exit 0 healthy, 1 unhealthy.
pub fn cli(args: &[String]) -> ! {
    let arg = |f: &str| args.iter().position(|a| a == f).and_then(|i| args.get(i + 1).cloned());
    let data = PathBuf::from(arg("--data").unwrap_or_else(crate::config::default_data_dir));
    let max_age = arg("--max-age").and_then(|s| s.parse().ok()).unwrap_or(DEFAULT_MAX_AGE_SECS);
    let report: Option<Report> = std::fs::read(health_path(&data)).ok().and_then(|b| serde_json::from_slice(&b).ok());
    match evaluate(report.as_ref(), crate::update::install::now_secs(), max_age) {
        Ok(()) => {
            println!("healthy (haven-relay {})", report.map(|r| r.version).unwrap_or_default());
            std::process::exit(0)
        }
        Err(why) => {
            println!("unhealthy: {why}");
            std::process::exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluate_fresh_stale_and_failing() {
        let good = Report { v: 1, version: "1.0.0".into(), ok: true, http: true, iroh: true, store: true, ts: 1000 };
        assert!(evaluate(Some(&good), 1010, 180).is_ok());
        assert!(evaluate(Some(&good), 1000 + 181, 180).unwrap_err().contains("stale"));
        assert!(evaluate(None, 1000, 180).is_err());
        let bad = Report { ok: false, http: false, ..good.clone() };
        assert!(evaluate(Some(&bad), 1000, 180).unwrap_err().contains("HTTP"));
    }

    #[test]
    fn http_addr_for_bind() {
        assert_eq!(local_http_addr("0.0.0.0:8674", 8674).unwrap().to_string(), "127.0.0.1:8674");
        assert_eq!(local_http_addr("192.168.1.5:8674", 8674).unwrap().to_string(), "192.168.1.5:8674");
        assert_eq!(local_http_addr("[::]:9000", 9000).unwrap().to_string(), "[::1]:9000");
    }

    #[tokio::test]
    async fn probe_checks_http_and_store() {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = l.accept().await {
                let mut b = [0u8; 256];
                let _ = s.read(&mut b).await;
                let _ = s.write_all(b"HTTP/1.1 404 not a website\r\nContent-Length: 0\r\n\r\n").await;
            }
        });
        let dir = std::env::temp_dir().join(format!("hr-health-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = Probe { http_addr: Some(addr), node: None, store: Some(dir.clone()) };
        let r = p.check("1.2.3").await;
        assert!(r.ok && r.http && r.store, "{r:?}");
        let p = Probe { http_addr: None, node: None, store: Some(dir.join("missing")) };
        assert!(!p.check("1.2.3").await.ok);
        // Nothing listening → HTTP fails.
        let dead = { let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap(); l.local_addr().unwrap() };
        assert!(!http_answers(dead).await);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
