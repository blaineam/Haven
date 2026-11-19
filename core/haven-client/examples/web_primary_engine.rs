//! Native counterpart for the browser-engine smoke (`web-client/smoke/engine.mjs`): an account's
//! PRIMARY device running the real client [`Engine`] — the code the desktop app runs — beside a
//! circle DERP, so the same engine compiled to WebAssembly can link to it from a tab and the two
//! can exchange posts with nothing simulated in between.
//!
//! ```sh
//! cargo run -p haven-client --example web_primary_engine
//! ```
//!
//! Hermetic: a throwaway account in a fresh temp directory, never the OS keyring or a real data
//! dir, and its only relay is the DERP it starts. Prints `DERP=`, `ACCOUNT=`, `TICKET=`; approves
//! the first enrollment request (`ENROLLED <device>`); posts each line it reads on stdin; and prints
//! `FEED <me|other> <body>` for every post as it appears.

use std::collections::HashSet;
use std::time::Duration;

use haven_client::engine::Engine;
use haven_client::store::{Paths, Prefs};
use haven_net::{DerpConfig, DerpServer};

const CIRCLE: &str = "default";
/// A relay id for the prefs entry that carries the DERP URL. Nothing listens under it; the entry
/// exists so the engine binds its node to this DERP instead of n0.
const RELAY_HEX: &str = "00000000000000000000000000000000000000000000000000000000000000d1";

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> AnyResult<()> {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    haven_client::rt::set_runtime(rt.handle().clone());
    rt.block_on(run())
}

/// Runs until killed; the temp directory is the OS's to reap.
async fn run() -> AnyResult<()> {
    // A throwaway identity has nobody to wake; keep test traffic off the production push worker.
    haven_client::netgate::set_push_off(true);
    let derp = DerpServer::spawn(&DerpConfig { enabled: true, bind: "127.0.0.1:0".into(), public_url: String::new() })
        .await
        .map_err(|e| e.to_string())?
        .expect("derp enabled");
    let url = format!("http://{}", derp.local_addr);
    println!("DERP={url}");

    let mut seed = [0u8; 32];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut seed)?;
    let dir = std::env::temp_dir().join(format!("haven-web-primary-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    let paths = Paths { base: dir.clone(), root: dir.clone() };
    {
        let mut prefs = Prefs::load(&paths);
        prefs.ensure_relay_entry(RELAY_HEX, Some("smoke DERP"), false, true);
        prefs.set_relay_derp(RELAY_HEX, &url);
        prefs.save(&paths).map_err(|e| e.to_string())?;
    }

    let engine = Engine::new(paths, seed).map_err(|e| e.to_string())?;
    engine.start().await;
    println!("ACCOUNT={}", engine.node_id_hex());
    println!("TICKET={}", engine.mint_enroll_ticket().map_err(|e| e.to_string())?);

    // Each line on stdin is posted to the circle as-is.
    let (tx, mut posts) = tokio::sync::mpsc::unbounded_channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let mut enrolled = false;
    let mut shown: HashSet<String> = HashSet::new();
    loop {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if !enrolled {
            if let Some((device, _name)) = engine.enroll_pending().into_iter().next() {
                engine.approve_enroll(device.clone()).map_err(|e| e.to_string())?;
                enrolled = true;
                println!("ENROLLED {device}");
            }
        }
        while let Ok(body) = posts.try_recv() {
            if !body.trim().is_empty() {
                engine.post(CIRCLE.into(), body.trim().to_string(), vec![], None, false, None);
            }
        }
        for item in engine.feed(CIRCLE) {
            if shown.insert(item.id.clone()) {
                println!("FEED {} {}", if item.is_me { "me" } else { "other" }, item.body);
            }
        }
    }
}
