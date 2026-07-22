//! Long-running path proxy for multi-device fabric smoke.
//!
//! ```sh
//! cargo run -p haven-net --example path_proxy_listen -- 0.0.0.0:8675
//! ```

use haven_net::{PathRouter, PathRouterConfig};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let bind = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "0.0.0.0:8675".into());
    println!("▸ path-proxy listening on {bind}");
    println!("  GET  /_haven");
    println!("  WSS  /webrtc/hairpin");
    let router = PathRouter::spawn(&PathRouterConfig {
        bind: bind.clone(),
        media_backend: String::new(),
        derp_backend: String::new(),
        http_token: String::new(),
    })
    .await?
    .expect("bind path proxy");
    println!("✓ bound {}", router.local_addr);
    // Park forever (drop kills the accept loop).
    std::future::pending::<()>().await;
    Ok(())
}
