//! The only network traffic the updater makes: a plain, anonymous HTTPS GET of the public GitHub
//! release list, then of one release asset + its `.sig`. No node id, no install id, no telemetry,
//! no cookies — the request carries nothing but a fixed User-Agent (GitHub's API rejects requests
//! without one). What GitHub sees is exactly what it sees from anyone browsing the Releases page.

use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use super::version::{parse_releases, Release};

/// Fixed, non-identifying User-Agent (no version, no platform).
const USER_AGENT: &str = "haven-relay-updater";
/// Upper bound on the release-list JSON.
const MAX_LIST_BYTES: u64 = 8 << 20;
/// Upper bound on a relay binary (today's are ~30 MB).
pub const MAX_ASSET_BYTES: u64 = 256 << 20;
/// Upper bound on a `.sig` file.
pub const MAX_SIG_BYTES: u64 = 4096;

/// Build the HTTP client. `allow_http` is only ever true for a test/mirror override URL — the
/// real release source is HTTPS-only (and every binary is signature-checked regardless).
pub fn client(allow_http: bool) -> Result<reqwest::Client> {
    // reqwest is built without a bundled crypto provider (same build iroh uses); make sure the
    // process-wide ring provider is installed (main does this too — idempotent).
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(15 * 60))
        .redirect(reqwest::redirect::Policy::limited(5))
        .https_only(!allow_http)
        .build()
        .map_err(|e| anyhow!("http client: {e}"))
}

async fn get(client: &reqwest::Client, url: &str, accept: &str) -> Result<reqwest::Response> {
    let resp = client
        .get(url)
        .header(reqwest::header::ACCEPT, accept)
        .send()
        .await
        .map_err(|e| anyhow!("GET failed: {}", e.without_url()))?;
    let status = resp.status();
    if !status.is_success() {
        bail!("GET returned HTTP {}", status.as_u16());
    }
    Ok(resp)
}

/// Read a whole (small) body with a hard cap.
pub async fn fetch_capped(client: &reqwest::Client, url: &str, accept: &str, cap: u64) -> Result<Vec<u8>> {
    let mut resp = get(client, url, accept).await?;
    if resp.content_length().map(|n| n > cap).unwrap_or(false) {
        bail!("response too large");
    }
    let mut out = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| anyhow!("read: {}", e.without_url()))? {
        out.extend_from_slice(&chunk);
        if out.len() as u64 > cap {
            bail!("response too large");
        }
    }
    Ok(out)
}

/// The release list.
pub async fn fetch_releases(client: &reqwest::Client, url: &str) -> Result<Vec<Release>> {
    let body = fetch_capped(client, url, "application/vnd.github+json", MAX_LIST_BYTES).await?;
    parse_releases(&body).map_err(|e| anyhow!(e))
}

/// Stream `url` into `dest` (created fresh), hashing as it goes. Returns the SHA-256.
pub async fn download_to(client: &reqwest::Client, url: &str, dest: &Path, cap: u64) -> Result<[u8; 32]> {
    let mut resp = get(client, url, "application/octet-stream").await?;
    if resp.content_length().map(|n| n > cap).unwrap_or(false) {
        bail!("asset too large");
    }
    let mut f = tokio::fs::File::create(dest).await.with_context(|| format!("create {}", dest.display()))?;
    let mut h = Sha256::new();
    let mut n: u64 = 0;
    while let Some(chunk) = resp.chunk().await.map_err(|e| anyhow!("read: {}", e.without_url()))? {
        n += chunk.len() as u64;
        if n > cap {
            drop(f);
            let _ = tokio::fs::remove_file(dest).await;
            bail!("asset too large");
        }
        h.update(&chunk);
        f.write_all(&chunk).await?;
    }
    f.flush().await?;
    f.sync_all().await.ok();
    Ok(h.finalize().into())
}
