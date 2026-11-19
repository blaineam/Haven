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
//! `ACCOUNT=`, `TICKET=`; approves the first enrollment request (`ENROLLED <device>`); posts each
//! line it reads on stdin; and prints `FEED <me|other> <body>` for every post as it appears.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use haven_client::engine::{Engine, HostingOptions};
use haven_client::net::WebBundle;
use haven_client::store::{Paths, Prefs};

const CIRCLE: &str = "default";

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

/// The web client's files: everything under a built bundle directory (`web-client/dist`).
fn load_bundle(dir: &Path) -> AnyResult<WebBundle> {
    fn walk(root: &Path, dir: &Path, bundle: &mut WebBundle) -> AnyResult<()> {
        for entry in std::fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                walk(root, &path, bundle)?;
                continue;
            }
            let name = path.strip_prefix(root)?.to_string_lossy().replace('\\', "/");
            if !bundle.insert(&name, std::fs::read(&path)?) {
                return Err(format!("{name} is not a servable bundle file").into());
            }
        }
        Ok(())
    }
    let mut bundle = WebBundle::new();
    walk(dir, dir, &mut bundle).map_err(|e| format!("{}: {e}", dir.display()))?;
    if bundle.lookup("/app/").is_none() {
        return Err(format!("{} has no index.html — run web-client/build.sh", dir.display()).into());
    }
    Ok(bundle)
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
    let bundle = load_bundle(Path::new(&web_dir))?;

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
