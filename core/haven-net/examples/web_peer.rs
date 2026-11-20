//! Native counterpart for the browser-transport smoke (`web-client/smoke`): a circle DERP plus one
//! ordinary Haven node registered on it, so a relay-only browser node (`haven-web`) can be proven
//! against the real native wire in both directions.
//!
//! ```sh
//! cargo run -p haven-net --example web_peer -- 127.0.0.1:3340
//! ```
//!
//! Prints `DERP=<url>` and `NODE=<hex>`, echoes every inbound frame back to its sender prefixed
//! with `echo:`, and — for each 64-hex node id read on stdin — DIALS that node and sends it
//! `hello-from-native`, which is what proves a tab can be *reached*, not only reach out.

use std::sync::{Arc, OnceLock};

use haven_net::{set_endpoint_policy, DerpConfig, DerpServer, EndpointPolicy, InboundHandler, Node};
use tokio::io::AsyncBufReadExt;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let bind = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:3340".into());
    let derp = DerpServer::spawn(&DerpConfig { enabled: true, bind: bind.clone(), public_url: format!("http://{bind}") })
        .await?
        .expect("derp enabled");
    let url = format!("http://{}", derp.local_addr);
    println!("DERP={url}");
    // This circle's DERP only — no n0 — exactly the map a browser node is given.
    set_endpoint_policy(EndpointPolicy::haven_only([url]));

    let mut secret = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut secret);
    let slot: Arc<OnceLock<Arc<Node>>> = Arc::new(OnceLock::new());
    let rt = tokio::runtime::Handle::current();
    let handler: InboundHandler = {
        let slot = slot.clone();
        Arc::new(move |from: [u8; 32], payload: Vec<u8>| {
            println!("RECV from={} bytes={}", hex(&from), payload.len());
            let Some(node) = slot.get().cloned() else { return };
            rt.spawn(async move {
                let mut reply = b"echo:".to_vec();
                reply.extend_from_slice(&payload);
                if let Err(e) = node.send_to_node(&hex(&from), &reply).await {
                    println!("ECHO-FAILED {e}");
                }
            });
        })
    };
    let node = Arc::new(Node::spawn(secret, handler).await?);
    let _ = slot.set(node.clone());
    println!("NODE={}", node.node_id_hex());

    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let target = line.trim().to_string();
        if target.len() != 64 {
            continue;
        }
        match node.send_to_node(&target, b"hello-from-native").await {
            Ok(()) => println!("DIALED {target}"),
            Err(e) => println!("DIAL-FAILED {target} {e}"),
        }
    }
    // stdin closed: keep serving until killed.
    std::future::pending::<()>().await;
    Ok(())
}
