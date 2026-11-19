//! Native counterpart for the browser-engine smoke (`web-client/smoke/engine.mjs`): an account's
//! PRIMARY device running the real client [`Engine`] — the code the desktop app runs — and
//! HOSTING its circle's relay the way the app does (mailbox + DERP behind the path proxy), with
//! web access on, so the relay serves the web client and a tab can link to the account through it.
//! Nothing is simulated between the two engines.
//!
//! ```sh
//! cargo run -p haven-client --example web_primary_engine -- web-client/dist
//! ```
//!
//! Hermetic: a throwaway account in a fresh temp directory, never the OS keyring or a real data
//! dir; every listener on a free loopback port (so it can run beside a real Haven app); no tunnel,
//! no TURN, no push. Prints `ORIGIN=` (the relay's front door — the page is at `<origin>/app/`),
//! `ACCOUNT=`, `TICKET=`; approves every enrollment request made with one of its tickets
//! (`ENROLLED <device>`); posts each line it reads on stdin (`!img <caption>` attaches a tiny PNG,
//! `!ticket` mints another ticket as `TICKET<n>=`); and prints `FEED <me|other> <body>[ [media N]]`
//! for every post once it holds the post's attachments.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use haven_client::commands::Eng;
use haven_client::engine::{Engine, HostingOptions};
use haven_client::store::{Paths, Prefs};

const CIRCLE: &str = "default";
/// A 1×1 PNG, base64 — the smallest real image.
const PNG_1X1: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> AnyResult<()> {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    haven_client::rt::set_runtime(rt.handle().clone());
    rt.block_on(run())
}

/// `HAVEN_SMOKE_LOG=info|debug` prints the engine's own log lines to stderr.
struct StderrLog;

impl log::Log for StderrLog {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::max_level() && m.target().starts_with("haven")
    }
    fn log(&self, r: &log::Record) {
        if self.enabled(r.metadata()) {
            eprintln!("   [primary {}] {}", r.level(), r.args());
        }
    }
    fn flush(&self) {}
}

/// A free loopback port (bound, read, released — fine for a harness).
fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?.local_addr()?.port())
}

/// Runs until killed; the temp directory is the OS's to reap.
async fn run() -> AnyResult<()> {
    // A throwaway identity has nobody to wake; keep test traffic off the production push worker.
    haven_client::netgate::set_push_off(true);
    if let Some(level) = std::env::var("HAVEN_SMOKE_LOG").ok().and_then(|l| l.parse::<log::LevelFilter>().ok()) {
        static LOGGER: StderrLog = StderrLog;
        let _ = log::set_logger(&LOGGER);
        log::set_max_level(level);
    }
    let web_dir = std::env::args().nth(1).ok_or("usage: web_primary_engine <web-client/dist>")?;
    let bundle = haven_client::net::load_web_bundle(Path::new(&web_dir)).map_err(|e| e.to_string())?;

    let (http, derp, proxy) = (free_port()?, free_port()?, free_port()?);
    let origin = format!("http://127.0.0.1:{proxy}");

    let mut seed = [0u8; 32];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut seed)?;
    let dir = std::env::temp_dir().join(format!("haven-web-primary-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    let paths = Paths { base: dir.clone(), root: dir.clone() };
    {
        // The operator's choices: announce this front door as-is (no tunnel), and offer web access.
        let mut prefs = Prefs::load(&paths);
        prefs.relay_front_door = Some("manual".into());
        prefs.relay_public_url = origin.clone();
        prefs.relay_auto_tunnel = Some(false);
        prefs.relay_web_access = true;
        prefs.save(&paths).map_err(|e| e.to_string())?;
    }

    let engine = Engine::new(paths, seed).map_err(|e| e.to_string())?;
    engine.set_hosting_options(HostingOptions {
        http_bind: format!("127.0.0.1:{http}"),
        derp_bind: format!("127.0.0.1:{derp}"),
        proxy_bind: format!("127.0.0.1:{proxy}"),
        turn: false,
        web_app: Some(Arc::new(bundle)),
    });
    engine.start().await;
    engine.start_hosting().await.map_err(|e| e.to_string())?;
    println!("ORIGIN={origin}");
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

    let mut tickets = 1;
    let mut shown: HashSet<String> = HashSet::new();
    loop {
        tokio::time::sleep(Duration::from_millis(200)).await;
        // Approve every enrollment request that verified against a ticket this device minted.
        for (device, _name) in engine.enroll_pending() {
            engine.approve_enroll(device.clone()).map_err(|e| e.to_string())?;
            println!("ENROLLED {device}");
        }
        while let Ok(line) = posts.try_recv() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            // `!ticket` mints another link ticket (`TICKET<n>=`).
            if line == "!ticket" {
                tickets += 1;
                println!("TICKET{tickets}={}", engine.mint_enroll_ticket().map_err(|e| e.to_string())?);
                continue;
            }
            // `!img <caption>` attaches a tiny PNG; anything else is a text post.
            let (body, media) = match line.strip_prefix("!img ") {
                Some(caption) => {
                    let reference = haven_client::commands::add_media(Eng(&engine), CIRCLE.into(), PNG_1X1.into(), false)
                        .map_err(|e| format!("add_media: {e}"))?;
                    (caption.to_string(), vec![reference])
                }
                None => (line.to_string(), vec![]),
            };
            engine.post(CIRCLE.into(), body, media, None, false, None);
        }
        for item in engine.feed(CIRCLE) {
            if !shown.contains(&item.id) {
                // An attachment is reported only once this device actually holds its bytes.
                let have = item.media.iter().filter(|r| engine.media_bytes(CIRCLE, r).is_some()).count();
                if have < item.media.len() {
                    continue; // still fetching — report it on a later pass
                }
                let media = if item.media.is_empty() { String::new() } else { format!(" [media {have}]") };
                println!("FEED {} {}{media}", if item.is_me { "me" } else { "other" }, item.body);
                shown.insert(item.id.clone());
            }
        }
    }
}
