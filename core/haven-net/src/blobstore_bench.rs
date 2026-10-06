//! Store-listing benchmark (ignored by default): a synthetic relay store shaped like a real
//! long-lived one, then the three listing paths a relay serves all day — a member's circle LIST,
//! a sibling's whole-store AGES inventory, and this relay's own steady-state mesh pass
//! (`keys_to_pull` against a peer that holds what we hold).
//!
//! ```text
//! HAVEN_BENCH_DIR=/tmp/havenbench HAVEN_BENCH_MAILBOX=500000 \
//!   cargo test -p haven-net --release --lib bench_store_listing -- --ignored --nocapture
//! ```
//! The store is built once and reused across runs (delete the dir to rebuild). Run it under
//! `strace -c -f` on Linux to count the stat calls per request.

use super::*;
use std::time::Instant;

fn cpu_secs() -> f64 {
    // getrusage(RUSAGE_SELF): user + system CPU of the whole process.
    #[repr(C)]
    struct Tv {
        s: i64,
        us: i64,
    }
    #[repr(C)]
    struct Ru {
        utime: Tv,
        stime: Tv,
        rest: [i64; 14],
    }
    extern "C" {
        fn getrusage(who: i32, ru: *mut Ru) -> i32;
    }
    let mut ru = Ru { utime: Tv { s: 0, us: 0 }, stime: Tv { s: 0, us: 0 }, rest: [0; 14] };
    unsafe { getrusage(0, &mut ru) };
    (ru.utime.s + ru.stime.s) as f64 + (ru.utime.us + ru.stime.us) as f64 / 1e6
}

fn build_store(root: &Path, mailbox: usize) {
    if root.join(".bench-built").is_file() {
        return;
    }
    let _ = std::fs::remove_dir_all(root);
    let circles = 10usize;
    let per = mailbox / circles;
    let body = vec![7u8; 64];
    for c in 0..circles {
        let cid = if c == 0 { "default".to_string() } else { format!("dm:{c:064x}-{:064x}", c + 1) };
        // ~13% events, ~46% relay announces (2 relays), ~40% live frames (4 dests), a few hellos.
        let events = per * 13 / 100;
        let announces = per * 46 / 100;
        let hellos = 50;
        let live = per - events - announces - hellos;
        for i in 0..events {
            local_put(root, &format!("haven/mailbox/{cid}/{:064x}", i * 31 + c), &body).unwrap();
        }
        for i in 0..announces {
            let relay = format!("{:064x}", 0xaa + (i % 2));
            local_put(root, &format!("haven/mailbox/{cid}/__relay__/{relay}/{:064x}", i), &body).unwrap();
        }
        for i in 0..live {
            let dest = format!("{:064x}", 0xd0 + (i % 4));
            local_put(root, &format!("haven/mailbox/{cid}/__live__/{dest}/{:064x}", i), &body).unwrap();
        }
        for i in 0..hellos {
            local_put(root, &format!("haven/mailbox/{cid}/__hello__/{:064x}/{:064x}/{:064x}", 1, 2, i), &body)
                .unwrap();
        }
    }
    // 1000 chunked media refs: manifest + 3 windows + a scope marker = 5000 files.
    for r in 0..1000 {
        let rf = format!("{r:064x}");
        local_put(root, &format!("haven/media/{rf}"), &body).unwrap();
        for w in 0..3 {
            local_put(root, &format!("haven/media/{rf}.p/{w}"), &body).unwrap();
        }
        local_put(root, &media_scope_key(&rf, "default"), MEDIA_SCOPE_BODY).unwrap();
    }
    std::fs::write(root.join(".bench-built"), b"").unwrap();
}

fn build_replica(root: &Path, listing: &str) {
    if root.join(".bench-built").is_file() {
        return;
    }
    let _ = std::fs::remove_dir_all(root);
    let text = std::fs::read_to_string(listing).expect("replica listing");
    let (mut n, mut mailbox) = (0usize, 0usize);
    for line in text.lines() {
        let mut it = line.splitn(4, ' ');
        let (_, Some(mtime), _, Some(rel)) = (it.next(), it.next(), it.next(), it.next()) else { continue };
        let Ok(mtime) = mtime.parse::<u64>() else { continue };
        let path = root.join("haven").join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, b"x").unwrap();
        let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(mtime);
        let _ = std::fs::File::options().write(true).open(&path).and_then(|f| f.set_modified(t));
        n += 1;
        mailbox += rel.starts_with("mailbox/") as usize;
    }
    std::fs::write(root.join(".haven-gc-enabled"), b"").unwrap();
    backdate(&root.join(".haven-gc-enabled"), GC_GRACE.as_secs() + 3600);
    std::fs::write(root.join(".bench-built"), b"").unwrap();
    eprintln!("replica: {n} files ({mailbox} mailbox)");
}

#[test]
#[ignore]
fn bench_store_listing() {
    let root = PathBuf::from(std::env::var("HAVEN_BENCH_DIR").unwrap_or_else(|_| "/tmp/havenbench".into()));
    let mailbox: usize = std::env::var("HAVEN_BENCH_MAILBOX").ok().and_then(|v| v.parse().ok()).unwrap_or(500_000);
    let reps: usize = std::env::var("HAVEN_BENCH_REPS").ok().and_then(|v| v.parse().ok()).unwrap_or(5);
    let t = Instant::now();
    match std::env::var("HAVEN_BENCH_REPLICA") {
        // A replica of a real store's SHAPE: `<btime> <mtime> <size> <store-relative path>` per
        // line (paths under `haven/`, as `stat -c "%W %Y %s %n"` prints them from the store's
        // `haven/` dir). Names and mtimes only — every body is one byte, nothing is copied.
        Ok(listing) => build_replica(&root, &listing),
        Err(_) => build_store(&root, mailbox),
    }
    eprintln!("store ready in {:.1}s ({mailbox} mailbox + 5000 media files)", t.elapsed().as_secs_f64());

    let mut auth = RelayAuth::default();
    let member = format!("{:064x}", 0xd0);
    let sibling = format!("{:064x}", 0x5151);
    auth.authorize("default", vec![member.clone()], vec![sibling.clone()]);

    // The first request of each kind is reported on its own ("cold": what a just-started relay
    // pays), the rest averaged ("warm": the steady state a relay serves all day).
    // HAVEN_BENCH_ONLY=<substring> runs just the matching phases (for per-phase strace counts).
    let only = std::env::var("HAVEN_BENCH_ONLY").ok();
    let run = |name: &str, f: &mut dyn FnMut() -> usize| {
        if only.as_deref().is_some_and(|o| !name.contains(o)) {
            return;
        }
        let mut cold = (0.0, 0.0);
        let (mut wall, mut cpu, mut n) = (0.0, 0.0, 0);
        for i in 0..reps {
            let (w0, c0) = (Instant::now(), cpu_secs());
            n = f();
            let (w, c) = (w0.elapsed().as_secs_f64() * 1e3, (cpu_secs() - c0) * 1e3);
            if i == 0 {
                cold = (w, c);
            } else {
                wall += w;
                cpu += c;
            }
        }
        let warm = reps.saturating_sub(1).max(1) as f64;
        eprintln!(
            "{name:<44} {n:>7} keys  cold wall {:>8.1} ms cpu {:>8.1} ms | warm wall {:>8.1} ms cpu {:>8.1} ms",
            cold.0,
            cold.1,
            wall / warm,
            cpu / warm
        );
    };

    // 1. A member's poll of its circle (the app's LIST, both transports).
    run("LIST haven/mailbox/default/ (member)", &mut || {
        let mut keys = local_list(&root, "haven/mailbox/default/");
        listing_retain(&root, &auth, &member, &mut keys, |k| k.as_str());
        keys.len()
    });
    // 2. A member's narrow live-call poll (2 s cadence during a call).
    run("LIST …/default/__live__/<me>/ (in-call poll)", &mut || {
        local_list(&root, &format!("haven/mailbox/default/__live__/{member}/")).len()
    });
    // 3. A sibling relay's mesh inventory: AGES over the whole store, every 15 s per sibling.
    run("AGES haven (sibling mesh inventory)", &mut || {
        let mut pairs = local_list_ages(&root, SYNC_PREFIX);
        listing_retain(&root, &auth, &sibling, &mut pairs, |(k, _)| k.as_str());
        pairs.len()
    });
    // 4. Our own steady-state mesh pass: the peer advertises exactly what we hold.
    let peer: Vec<(String, u64)> =
        if only.as_deref().is_none_or(|o| "keys_to_pull".contains(o)) { local_list_ages(&root, SYNC_PREFIX) } else { Vec::new() };
    run("keys_to_pull (steady-state mesh pass)", &mut || {
        keys_to_pull(&root, &peer, &Retention::default(), &|_| true).len()
    });
    // Optionally: the retention pass a relay runs hourly, then the same requests again.
    if std::env::var("HAVEN_BENCH_SWEEP").is_ok() {
        let t = Instant::now();
        let stats = gc_sweep_with(&root, &Retention::default(), GC_GRACE);
        eprintln!(
            "gc_sweep_with: {} control-plane + {} TTL entries deleted in {:.1}s; mailbox now {} keys",
            stats.control_deleted,
            stats.mailbox_deleted,
            t.elapsed().as_secs_f64(),
            local_list(&root, "haven/mailbox/").len()
        );
    }
}
