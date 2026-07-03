//! Transport diagnostic: spawn a scratch node, report home relay + discovery publish state,
//! and optionally dial a target node id (blob LIST) to see whether cross-node connects work.
//!
//!   cargo run -p haven-net --example diag [target-node-hex]

use std::sync::Arc;
use std::time::Duration;

fn z32(bytes: &[u8]) -> String {
    const ALPH: &[u8] = b"ybndrfg8ejkmcpqxot1uwisza345h769";
    let (mut val, mut bits, mut out) = (0u64, 0u32, String::new());
    for &b in bytes {
        val = (val << 8) | b as u64;
        bits += 8;
        while bits >= 5 {
            out.push(ALPH[((val >> (bits - 5)) & 31) as usize] as char);
            bits -= 5;
        }
    }
    if bits > 0 {
        out.push(ALPH[((val << (5 - bits)) & 31) as usize] as char);
    }
    out
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).filter_map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()).collect()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let target = std::env::args().nth(1);
    let seed: [u8; 32] = rand::random();
    let node = haven_net::Node::spawn(seed, Arc::new(|_frame: Vec<u8>| {})).await?;
    println!("node id: {}", node.node_id_hex());

    for i in 0..15 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if let Some(url) = node.home_relay_url() {
            println!("home relay after {}s: {url}", i + 1);
            break;
        }
        if i == 14 {
            println!("NO home relay after 15s");
        }
    }

    // Poll for our own discovery record for up to 60s (publish happens after the home relay
    // is confirmed; a missing record after that = publishing is broken).
    let name = format!("_iroh.{}.dns.iroh.link", z32(&unhex(&node.node_id_hex())));
    let mut published = false;
    for i in 0..12 {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let out = std::process::Command::new("dig").args(["+short", "TXT", &name]).output()?;
        let txt = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !txt.is_empty() {
            println!("own DNS record after {}s ({name}):\n{txt}", (i + 1) * 5);
            published = true;
            break;
        }
    }
    if !published {
        println!("own DNS record ({name}): STILL NONE after 60s — publishing broken");
    }

    if target.as_deref() == Some("serve") {
        // Host a relay on this scratch node and stay up, so a second diag process can dial us.
        let dir = std::env::temp_dir().join(format!("diag-relay-{}", std::process::id()));
        std::fs::create_dir_all(&dir)?;
        node.enable_relay(dir);
        println!("SERVING relay — dial me: {}", node.node_id_hex());
        tokio::time::sleep(Duration::from_secs(600)).await;
        return Ok(());
    }
    if let Some(hex_id) = target {
        println!("dialing {hex_id} (blob list, 35s cap)…");
        let started = std::time::Instant::now();
        // DIAG_DIRECT=ip:port injects a direct address candidate (bypasses relay + discovery
        // routing) to bisect "wrong node id" from "relay path broken".
        let client = if let Ok(direct) = std::env::var("DIAG_DIRECT") {
            node.blob_client_direct(&hex_id, &direct)?
        } else {
            node.blob_client(&hex_id)?
        };
        let res = tokio::time::timeout(Duration::from_secs(35), client.list("haven/mailbox/")).await;
        match res {
            Ok(Ok(keys)) => println!("LIST ok in {:?}: {} keys", started.elapsed(), keys.len()),
            Ok(Err(e)) => println!("LIST error in {:?}: {e}", started.elapsed()),
            Err(_) => println!("LIST TIMED OUT after {:?}", started.elapsed()),
        }
    }
    Ok(())
}
