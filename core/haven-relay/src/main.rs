//! `haven-relay` — the easy circle relay.
//!
//! A single static binary a non-technical user can download, run, and link to their
//! circle. Once linked it acts as:
//!   1. an always-on **connection relay** — forwards sealed mesh-relay frames toward
//!      circle members who can't be reached directly (it only moves ciphertext), and
//!   2. a **media store-and-forward** — runs `rclone serve s3` bound to localhost and
//!      exposes it over the iroh overlay (`haven/s3/1`), so the circle's sealed-blob
//!      mailbox is reachable with **no public host**.
//!
//! It is a **non-key-holder**: linking it never grants it any key that can read circle
//! content. See `relay/README.md` for the security/metadata note.
//!
//! Usage:
//!   haven-relay run [--link <code>] [--data DIR] [--no-storage]
//!                   [--s3 | --rclone-remote <remote:path>] [--s3-port 8333]
//!   haven-relay run --config relay.json
//!   haven-relay link [--data DIR]    # print the saved circle link + QR (paste into the app)
//!   haven-relay make-link --circle fam --member <hex> [--member <hex> …]   # operator helper
//!   haven-relay id [--data DIR]      # print this relay's node id (for the app's storage config)

mod config;
mod derp;
mod link;
mod qr;
mod runner;
mod service;

use anyhow::{anyhow, Result};

fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str);

    match cmd {
        Some("run") => run(&args[2..]),
        Some("link") => print_link(&args[2..]),
        Some("make-link") => make_link(&args[2..]),
        Some("id") => print_id(&args[2..]),
        Some("service") => match args.get(2).map(String::as_str) {
            // Pass through any `run` flags (esp. `--data <custom storage path>`) so the auto-start
            // command matches how the operator runs it.
            Some("install") => service::install(&args[3..]),
            Some("uninstall") | Some("remove") => service::uninstall(),
            _ => {
                eprintln!("usage: haven-relay service install [--data DIR] | uninstall");
                std::process::exit(2);
            }
        },
        // An operator had no way to ask a running relay what it is. That matters more here than for
        // most CLIs: a relay is invisible while it appears to work, so a box can sit on a build from
        // before a PROTOCOL change indefinitely — and the symptom of that (a relay authorizing only
        // the one circle its link granted, pre-1.1.2) looks like "my media isn't on any relay", not
        // like an out-of-date binary. Both spellings, because `--version` is what everyone tries.
        Some("version") | Some("-V") | Some("--version") => {
            println!("haven-relay {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("-h") | Some("--help") | None => {
            print_help();
            Ok(())
        }
        Some(other) => {
            eprintln!("unknown command: {other}\n");
            print_help();
            std::process::exit(2);
        }
    }
}

fn print_help() {
    eprintln!(
        "haven-relay — be the always-on relay for your circle (moves ciphertext only)\n\n\
         The dead-simple way: download, run, paste your circle link, leave it running.\n\
         It serves your circle's sealed-media mailbox from THIS machine's local disk and\n\
         relays live messages, all over Haven Net (no cloud, no ports, no config).\n\n\
         USAGE:\n  \
         haven-relay run --link <code>            first run: attach to your circle (saved)\n  \
         haven-relay run                          restart: reuse the saved circle link\n  \
         haven-relay run --config relay.json      everything from a JSON file\n  \
         haven-relay link                         reprint the saved link + QR for the app\n  \
         haven-relay id                           print this relay's node id\n  \
         haven-relay version                      print the relay version (are you up to date?)\n  \
         haven-relay service install              auto-start on login/reboot (systemd/launchd/Task)\n  \
         haven-relay service uninstall            remove the auto-start\n  \
         haven-relay make-link --circle <tag> --member <hex> …   (operator helper)\n\n\
         STORAGE BACKENDS (default = local disk, fully decentralized):\n  \
         (default)                 local-disk blob mailbox at <data>/store over haven/blob/1\n  \
         --s3                      run `rclone serve s3` of a local dir over haven/s3/1\n  \
         --rclone-remote <r:path>  serve any rclone remote (rclone owns the provider auth)\n  \
         --no-storage              connection relay only (no media mailbox)\n\n\
         HTTP MEDIA INTERFACE (default = ON, the reliable cross-NAT media path):\n  \
         --http <bind>             bind address (default 0.0.0.0:8674)\n  \
         --http-url <url>          public URL members reach it at (port-forward/proxy/tunnel)\n  \
         --tunnel-token <token>    Cloudflare Zero Trust tunnel install token (with --http-url:\n  \
                                   run bundled cloudflared for your custom domain)\n  \
         --tunnel                  force a free Cloudflare Quick Tunnel (*.trycloudflare.com)\n  \
         --no-tunnel               do not auto-start a quick tunnel (default is ON when no --http-url)\n  \
         --no-http                 disable the HTTP interface\n  \
         Requests need the bearer token printed at start (persisted in <data>/http_token).\n  \
         On first tunnel use, cloudflared is downloaded next to this binary (or into <data>/bin).\n\n\
         RETENTION (your choice; default = keep media forever, prune mailbox after 30 days):\n  \
         --media-max-age-days N    prune media not touched for N days (0 = keep forever)\n  \
         --media-max-bytes SIZE    cap the media store, oldest deleted first (50G, 500M; 0 = unbounded)\n  \
         --mailbox-ttl-days N      override the 30-day mailbox event TTL\n  \
         With both media limits set, whichever rule frees more space wins. Sweeps run hourly;\n  \
         the first media sweep waits 48h after limits are first enabled.\n\n\
         COMMON FLAGS:  --data DIR  --s3-port PORT  --rclone PATH  --rclone-config FILE\n\n\
         The relay never holds any key that can read your circle's content. It forwards\n\
         sealed frames and serves sealed blobs it cannot open. No logs are written.\n"
    );
}

/// Run the relay (synchronous wrapper around the async runner). On a fresh data dir this
/// also prints the link/QR to paste into the app.
fn run(args: &[String]) -> Result<()> {
    let cfg = config::Config::from_args(args)?;
    // Show the paste-into-the-app link/QR every run — it's the whole point and harmless
    // to reprint (it's public routing data, not a secret).
    qr::print_link_qr(&cfg.link.to_uri());
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(runner::run(cfg))
}

/// Print the saved circle link + QR (so a user can re-add the relay in the app any time).
fn print_link(args: &[String]) -> Result<()> {
    let data = arg_value(args, "--data").unwrap_or_else(config::default_data_dir);
    let link = config::load_link(std::path::Path::new(&data)).map_err(|_| {
        anyhow!("no saved circle link in {data} — run `haven-relay run --link <code>` first")
    })?;
    qr::print_link_qr(&link.to_uri());
    Ok(())
}

/// Operator helper: build a relay link from a circle tag + the member node ids. In the
/// real product the app emits this code (it knows the roster); this lets a CLI operator
/// or a test produce one too.
fn make_link(args: &[String]) -> Result<()> {
    let mut circle = String::new();
    let mut members = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--circle" => {
                circle = args.get(i + 1).cloned().ok_or_else(|| anyhow!("--circle needs a value"))?;
                i += 2;
            }
            "--member" => {
                members.push(args.get(i + 1).cloned().ok_or_else(|| anyhow!("--member needs a value"))?);
                i += 2;
            }
            other => return Err(anyhow!("unknown flag: {other}")),
        }
    }
    if circle.is_empty() || members.is_empty() {
        return Err(anyhow!("usage: make-link --circle <tag> --member <hex> [--member <hex> …]"));
    }
    let link = link::RelayLink::new(circle, members);
    // Validate by round-tripping.
    link::RelayLink::parse(&link.to_uri())?;
    println!("{}", link.to_uri());
    Ok(())
}

/// Print this relay's stable node id (derived from its persisted identity seed). The app
/// references this id as the storage `volunteer_node_id` and as a relay it can dial.
fn print_id(args: &[String]) -> Result<()> {
    let data = arg_value(args, "--data").unwrap_or_else(config::default_data_dir);
    let seed = config::load_or_create_seed(&data)?;
    let id = haven_p2p::identity::Identity::from_seed(&seed);
    println!("{}", hex32(&id.public().node_id_bytes()));
    Ok(())
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
