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
//! `!oldimg <caption>` posts a picture dated 90 days ago and rotates the circle's keys past it
//! (`OLD ready=<bool>`), `!ticket` mints another ticket as `TICKET<n>=`, `!pair <code>` answers a `haven-pair:` code); and prints `FEED <me|other> <body>[ [media N]]`
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
    // `HAVEN_SMOKE_TUNNEL=1`: go out through a real Cloudflare quick tunnel instead of loopback —
    // the path a browser on another network actually takes (TLS terminated by the tunnel provider,
    // WebSockets and uploads through its proxy). Not hermetic; never the default.
    // DO NOT use it on a machine that is hosting a real Haven relay: starting a tunnel first
    // sweeps "leftover" Haven tunnel helpers (`kill_orphan_cloudflareds`), and a real relay's
    // helper looks exactly like one.
    let tunnel = std::env::var("HAVEN_SMOKE_TUNNEL").is_ok_and(|v| v == "1");

    let mut seed = [0u8; 32];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut seed)?;
    let dir = std::env::temp_dir().join(format!("haven-web-primary-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    // Nothing of a harness run may land in the real app's folders: the tunnel helper's log
    // otherwise goes to the platform data dir (`…/Haven/logs`), next to a person's real identity.
    std::env::set_var("HAVEN_CLOUDFLARED_LOG_DIR", dir.join("logs"));
    let paths = Paths { base: dir.clone(), root: dir.clone() };
    {
        // The operator's choices: announce this front door as-is (no tunnel), and offer web access.
        let mut prefs = Prefs::load(&paths);
        if tunnel {
            // The shipping default: Haven starts its own free Cloudflare tunnel (cloudflared must be
            // on PATH or beside this binary) and announces whatever hostname it is given.
            prefs.relay_front_door = Some("auto".into());
            prefs.relay_auto_tunnel = Some(true);
        } else {
            prefs.relay_front_door = Some("manual".into());
            prefs.relay_public_url = origin.clone();
            prefs.relay_auto_tunnel = Some(false);
        }
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
    // `HAVEN_SMOKE_GUEST=1`: a second account that hosts nothing — it becomes a contact of the
    // hosting one and uses that account's relay, like a friend joining a circle.
    let guest = std::env::var("HAVEN_SMOKE_GUEST").is_ok_and(|v| v == "1");
    if !guest {
        engine.start_hosting().await.map_err(|e| e.to_string())?;
    }
    let origin = if guest {
        "none".to_string()
    } else if tunnel {
        let mut public = None;
        for _ in 0..240 {
            if let (Some(url), _, true) = engine.live_front_door() {
                if url.starts_with("https://") {
                    public = Some(url.trim_end_matches('/').to_string());
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        public.ok_or("the tunnel never came up (is cloudflared on PATH?)")?
    } else {
        origin
    };
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

    // The harness stops this process with SIGTERM. Stop hosting first, so a tunnel helper this run
    // started is stopped with it instead of being left behind pointing at a dead port.
    #[cfg(unix)]
    {
        let engine = engine.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let (Ok(mut term), Ok(mut int)) = (signal(SignalKind::terminate()), signal(SignalKind::interrupt())) else { return };
            tokio::select! { _ = term.recv() => {}, _ = int.recv() => {} }
            engine.stop_hosting();
            std::process::exit(0);
        });
    }

    let mut tickets = 1;
    let mut unique_pictures: u32 = 0;
    let mut shown: HashSet<String> = HashSet::new();
    let mut known_contacts: HashSet<String> = HashSet::new();
    let mut web_allowed = false;
    loop {
        tokio::time::sleep(Duration::from_millis(200)).await;
        // Accept every connection request (the person on the other end of an invite), and say
        // when someone has become a contact (`CONTACT <account hex>`).
        for req in engine.pending() {
            engine.approve(req.id_hex.clone());
            println!("APPROVED {}", req.id_hex);
        }
        for c in engine.contacts() {
            if known_contacts.insert(c.id_hex.clone()) {
                println!("CONTACT {}", c.id_hex);
            }
        }
        // The circle's standing on web devices, whenever it changes (`WEBSTATE allowed=<bool>`).
        let now_allowed = engine.circle_web_access(CIRCLE).allowed;
        if now_allowed != web_allowed {
            web_allowed = now_allowed;
            println!("WEBSTATE allowed={web_allowed}");
        }
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
            // `!invite` prints this account's invite link (`INVITE=`); `!connect <link>` uses one.
            if line == "!invite" {
                println!("INVITE={}", engine.invite_uri());
                continue;
            }
            if let Some(uri) = line.strip_prefix("!connect ") {
                println!("CONNECTING {}", engine.connect_by_link(uri.trim().to_string()));
                continue;
            }
            // `!web on|off` states this account's position on web devices in the circle
            // (`WEB on|off allowed=<bool>`).
            if let Some(v) = line.strip_prefix("!web ") {
                let on = v.trim() == "on";
                let ok = engine.set_circle_web_access(CIRCLE.into(), on);
                println!("WEB {} set={ok} allowed={}", if on { "on" } else { "off" }, engine.circle_web_access(CIRCLE).allowed);
                continue;
            }
            // `!revoke web` removes every browser from this account (`REVOKED <n>`).
            if line == "!revoke web" {
                let web: Vec<String> = haven_client::commands::device_roster(Eng(&engine))
                    .devices
                    .into_iter()
                    .filter(|d| haven_ffi::is_web_device_name(d.name.clone()))
                    .map(|d| d.node_hex)
                    .collect();
                for d in &web {
                    engine.revoke_device(d.clone());
                }
                println!("REVOKED {}", web.len());
                continue;
            }
            // `!pair <haven-pair: code>` answers a code another device is showing (scan-to-link):
            // `PAIRED` once the offer was delivered, `PAIRFAIL <why>` otherwise.
            if let Some(code) = line.strip_prefix("!pair ") {
                match engine.link_scanned_device(code.to_string()).await {
                    Ok(()) => println!("PAIRED"),
                    Err(e) => println!("PAIRFAIL {e}"),
                }
                continue;
            }
            // `!oldimg <caption>`: a picture from before any circle key a new browser is handed.
            if let Some(caption) = line.strip_prefix("!oldimg ") {
                let mut img = image::RgbImage::new(31, 17);
                for (x, y, px) in img.enumerate_pixels_mut() {
                    *px = image::Rgb([(x * 7) as u8, (y * 13) as u8, 200]);
                }
                let mut png = Vec::new();
                image::DynamicImage::ImageRgb8(img)
                    .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                    .map_err(|e| format!("png: {e}"))?;
                let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &png);
                let reference = haven_client::commands::add_media(Eng(&engine), CIRCLE.into(), b64, false)
                    .map_err(|e| format!("add_media: {e}"))?;
                println!("OLD ready={}", engine.harness_post_before_the_keys(CIRCLE, caption, reference).await);
                continue;
            }
            // `!newimg <caption>` attaches a picture nobody holds yet (media is addressed by its
            // content, so the fixed PNG below is the SAME blob every time it is posted).
            if let Some(caption) = line.strip_prefix("!newimg ") {
                unique_pictures += 1;
                let mut img = image::RgbImage::new(24, 24);
                for (x, y, px) in img.enumerate_pixels_mut() {
                    *px = image::Rgb([(x * 9) as u8, (y * 9) as u8, (unique_pictures * 37 % 251) as u8]);
                }
                let mut png = Vec::new();
                image::DynamicImage::ImageRgb8(img)
                    .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                    .map_err(|e| format!("png: {e}"))?;
                let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &png);
                let reference = haven_client::commands::add_media(Eng(&engine), CIRCLE.into(), b64, false)
                    .map_err(|e| format!("add_media: {e}"))?;
                engine.post(CIRCLE.into(), caption.to_string(), vec![reference], None, false, None);
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
