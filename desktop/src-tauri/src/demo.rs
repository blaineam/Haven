//! PII-free demo dataset for screenshots — **DEBUG BUILDS ONLY**.
//!
//! Ports `apple/HavenApp/DemoSeed.swift` (the reference implementation) to desktop. It drives the
//! REAL engine with a small cast of fictional people: each "friend" is a full `HavenSocial` identity
//! from a deterministic throwaway seed; they handshake into circles, author sealed posts/stories/DMs,
//! and those envelopes are `receive()`d into the user's engine — so the feed, reactions, comments,
//! stories tray and DM list are genuinely populated, not faked views.
//!
//! Three hard rules, in order of importance:
//!
//! 1. **It cannot exist in a release build.** `lib.rs` declares this module under
//!    `#[cfg(debug_assertions)]` and the `compile_error!` below fails the build if anything ever
//!    declares it unguarded. A release binary that could seed a synthetic identity into a real
//!    user's store is the bug this whole file is written around.
//! 2. **It never touches the real identity.** Unlike iOS (whose demo runs in a throwaway simulator),
//!    a desktop dev has real data on this machine, so demo mode swaps in its own seed AND its own
//!    data dir (`<data>/Haven/demo`) — the real identity's state, prefs, media and keychain seed are
//!    never opened, let alone written.
//! 3. **It never goes online.** `HAVEN_DEMO=1` implies `HAVEN_NO_NET`: `lib.rs` skips `Engine::start`,
//!    so the iroh node never binds and the synthetic cast can never leak to a real peer. Everything
//!    below is local: authoring + `receive` are pure state transitions.

#[cfg(not(debug_assertions))]
compile_error!("demo.rs must never be compiled into a release build (see the module docs)");

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use haven_ffi::{HavenSocial, TrackRefFfi};

use crate::engine::{Engine, DEFAULT_CIRCLE};
use crate::store::{Contact, Paths, Profile};

/// The demo identity's data dir, under the normal base. Isolated on purpose — see rule 2.
const DEMO_DIR: &str = "demo";
/// Fixed account seed byte for "me", so a seeded run is reproducible across captures.
const ME_SEED_BYTE: u8 = 0x21;

/// Seed + show the synthetic dataset (`HAVEN_DEMO=1`).
pub fn is_demo() -> bool {
    std::env::var("HAVEN_DEMO").as_deref() == Ok("1")
}

/// Never bring the P2P node online. Implied by demo mode: a synthetic cast must never reach the wire.
pub fn no_net() -> bool {
    is_demo() || std::env::var("HAVEN_NO_NET").as_deref() == Ok("1")
}

/// The demo identity + its own data dir, wiped first so every capture starts from the same state
/// (re-seeding a populated dir would stack duplicate posts on each run).
pub fn identity() -> Result<([u8; 32], Paths)> {
    let base = Paths::resolve()?;
    let dir = base.base.join(DEMO_DIR);
    // Only ever the demo subdir — the real identity lives at `base` itself.
    let _ = std::fs::remove_dir_all(&dir);
    Ok((seed_bytes(ME_SEED_BYTE), Paths::resolve_for(DEMO_DIR)?))
}

/// A fictional person in the demo dataset.
struct Persona {
    name: &'static str,
    engine: Arc<HavenSocial>,
    hex: String,
}

/// Seed the dataset. No-op unless `HAVEN_DEMO=1`. Returns the feed count it verified.
pub fn seed(engine: &Arc<Engine>) -> Option<usize> {
    if !is_demo() {
        return None;
    }
    let main = engine.demo_social().clone();

    // ── The user ("me") ──────────────────────────────────────────────────────────────────
    // Written straight into prefs: `Engine::set_profile` broadcasts the card to contacts, and this
    // run must not touch the wire.
    engine.demo_with_prefs(|p| {
        p.profile = Profile {
            name: "Riley Avery".into(),
            bio: "designer · plant hoarder · weekend hiker 🌄".into(),
            link: "rileyavery.studio".into(),
            emoji: "🌿".into(),
            avatar: String::new(),
        };
    });

    let main_hex = main.my_node_hex();
    main.create_circle(DEFAULT_CIRCLE.into(), "Your circle".into());

    // ── The cast ─────────────────────────────────────────────────────────────────────────
    let cast = [("Maya Quinn", 0xA1u8), ("Theo Park", 0xB2), ("Nina Brooks", 0xC3), ("Sam Rivera", 0xD4)];
    let mut people: Vec<Persona> = vec![];
    for (name, seed_byte) in cast {
        let friend = match HavenSocial::new(seed_bytes(seed_byte).to_vec()) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("DEMO ERROR: persona {name} engine failed: {e}");
                continue;
            }
        };
        friend.create_circle(DEFAULT_CIRCLE.into(), "Your circle".into());
        // I learn their keys (so I can open their posts) and they learn mine (so they can seal to a
        // circle that includes me).
        let hex = match main.add_contact_bundle(DEFAULT_CIRCLE.into(), friend.my_bundle()) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("DEMO ERROR: add_contact_bundle failed for {name}: {e}");
                continue;
            }
        };
        if let Err(e) = friend.add_contact_bundle(DEFAULT_CIRCLE.into(), main.my_bundle()) {
            eprintln!("DEMO ERROR: reverse add_contact_bundle failed for {name}: {e}");
        }
        let verify_hex = friend.verification_hex();
        engine.demo_with_prefs(|p| {
            p.contacts.push(Contact { id_hex: hex.clone(), name: name.to_string(), verify_hex })
        });
        people.push(Persona { name, engine: friend, hex });
    }

    // ── Demo media (abstract, unmistakably synthetic gradient "photos") ───────────────────
    // Generated, not bundled: desktop ships no demo assets, and a gradient is provably PII-free.
    let photo = |i: usize| -> String {
        engine.add_local_media(DEFAULT_CIRCLE, &art::gradient(i), false)
    };
    let (sunset, ridge, coffee) = (photo(0), photo(1), photo(2));
    let (pottery, trail, plant, pup) = (photo(3), photo(4), photo(5), photo(6));
    let (brunch_a, brunch_b, brunch_c) = (photo(7), photo(8), photo(9));

    // ── Stories tray (two friends + me) ───────────────────────────────────────────────────
    story(&main, people.first(), &[sunset], "golden hour at the cove 🌅", 40);
    story(&main, people.get(1), &[ridge], "made it to the ridge 🥾", 95);
    let _ = main.post(DEFAULT_CIRCLE.into(), "studio fuel ☕️".into(), vec![coffee], None,
                      Some(86_400), true, false, ms_ago(20));

    // ── The circle feed: friends + me, with reactions + comments ──────────────────────────
    let p1 = friend_post(&main, &people, 0, "first throw off the new wheel 🪴 obsessed", &[pottery], None, 180);
    let p2 = friend_post(&main, &people, 1, "12 miles before breakfast. trail magic is real.", &[trail],
                         Some(track("Sunrun", "The Wanderers")), 140);
    let p3 = my_post(&main, "new little corner of the studio came together today 🌿", &[plant], 75);
    let p4 = friend_post(&main, &people, 2, "everyone, meet the newest member of the crew 🐾", &[pup], None, 30);
    // Multi-photo: exercises the feed carousel + its blurred backdrop.
    let p5 = friend_post(&main, &people, 3, "sunday slow brunch — the sourdough finally rose 🍞",
                         &[brunch_a, brunch_b, brunch_c], None, 12);

    react(&main, &people, &p1, "🔥", &[1, 2, 3]);
    react(&main, &people, &p1, "🪴", &[0]);
    comment(&main, &people, &p1, 1, "the glaze on this!! 😍", 170);
    comment(&main, &people, &p1, 3, "teach me your ways", 165);

    react(&main, &people, &p2, "👟", &[0, 2]);
    comment(&main, &people, &p2, 0, "those views are unreal", 130);

    react(&main, &people, &p3, "🌿", &[0, 1, 2, 3]);
    comment(&main, &people, &p3, 2, "cozy!! love the light in here", 60);

    react(&main, &people, &p4, "🐶", &[0, 1, 3]);
    react(&main, &people, &p4, "❤️", &[2]);
    comment(&main, &people, &p4, 0, "the FLOOF 😭🐾", 24);

    react(&main, &people, &p5, "🤤", &[0, 2]);

    // ── A second circle, so the switcher is populated ─────────────────────────────────────
    let crew = "demo-weekend-crew";
    main.create_circle(crew.into(), "Weekend Crew".into());
    for p in people.iter().take(3) {
        let _ = main.add_existing_to_circle(crew.into(), p.hex.clone());
        p.engine.create_circle(crew.into(), "Weekend Crew".into());
        let _ = p.engine.add_contact_bundle(crew.into(), main.my_bundle());
    }
    if let Some(p) = people.first() {
        if p.engine.post(crew.into(), "who's in for the cabin this weekend? ⛰️".into(), vec![], None,
                         None, false, false, ms_ago(220)).is_ok()
        {
            replay_into_main(&main, &p.engine, crew);
        }
    }
    let _ = main.post(crew.into(), "me!! bringing the sourdough 🍞".into(), vec![], None, None, false,
                      false, ms_ago(210));

    // ── DM threads (each DM is a private 2-person circle) ─────────────────────────────────
    if let Some(p) = people.first() {
        seed_dm(&main, &main_hex, p, &[
            (false, "did you see the new kiln schedule?", 300, None),
            (true, "yes! booked us both for saturday 🔥", 298, None),
            (false, "you're the best. coffee after?", 295, None),
            (true, "always ☕️", 292, Some(track("Slow Morning", "Wax & Wane"))),
        ]);
    }
    if let Some(p) = people.get(1) {
        seed_dm(&main, &main_hex, p, &[
            (false, "trail conditions look perfect for sunday", 500, None),
            (true, "sending the gpx now 🗺️", 496, None),
            (false, "🙌", 495, None),
        ]);
    }

    engine.demo_persist();
    engine.demo_mark_started(); // no node in demo mode — otherwise the status dot reads "starting…" forever

    // Count, don't assume. A friend's post is epoch-sealed: hand `receive` a bare post envelope
    // without the author's key commit and it is accepted and then never opens — the post silently
    // never appears (this ate 5 of Android's 8 demo posts). Anything less than the full cast here
    // means `replay_into_main` regressed.
    let items = main.feed(DEFAULT_CIRCLE.into(), now_ms(), None);
    let posts: Vec<_> = items.iter().filter(|i| !i.story && !i.unsent).collect();
    let mine = posts.iter().filter(|i| i.is_me).count();
    let stories = items.iter().filter(|i| i.story).count();
    let reactions: usize = posts.iter().map(|i| i.reactions.len()).sum();
    let comments: usize = posts.iter().map(|i| i.comments.len()).sum();
    let authors: std::collections::HashSet<_> = posts.iter().map(|i| i.author_short.clone()).collect();
    println!(
        "DEMO seeded: {} posts by {} authors ({} mine, {} friends'), {} stories, {} reaction sets, \
         {} comments, {} contacts, {} circles",
        posts.len(), authors.len(), mine, posts.len() - mine, stories, reactions, comments,
        people.len(), main.circles().len()
    );
    // Every persona MUST show up. Silence here is the whole failure mode: a missing key commit
    // doesn't error, it just quietly drops the post.
    for p in &people {
        if !posts.iter().any(|i| p.hex.starts_with(&i.author_short)) {
            println!("DEMO ERROR: {} has no post in the feed — sync replay regressed", p.name);
        }
    }
    Some(posts.len())
}

// ---- authoring helpers -----------------------------------------------------------------------

/// A friend authors a post into the default circle; it's received into my engine. Returns the shared
/// post id, so reactions/comments can target it.
fn friend_post(main: &Arc<HavenSocial>, people: &[Persona], i: usize, body: &str, media: &[String],
               music: Option<TrackRefFfi>, mins_ago: u64) -> Option<String> {
    let p = people.get(i)?;
    let ts = ms_ago(mins_ago);
    if let Err(e) = p.engine.post(DEFAULT_CIRCLE.into(), body.into(), media.to_vec(), music, None,
                                  false, false, ts) {
        eprintln!("DEMO ERROR: friend_post: post() failed for {}: {e}", p.name);
        return None;
    }
    replay_into_main(main, &p.engine, DEFAULT_CIRCLE);
    let id = id_for_created_at(main, ts);
    if id.is_none() {
        eprintln!("DEMO ERROR: friend_post: {}'s post did not land after sync replay", p.name);
    }
    id
}

/// I author a post into the default circle. Returns its id.
fn my_post(main: &Arc<HavenSocial>, body: &str, media: &[String], mins_ago: u64) -> Option<String> {
    let ts = ms_ago(mins_ago);
    main.post(DEFAULT_CIRCLE.into(), body.into(), media.to_vec(), None, None, false, false, ts).ok()?;
    id_for_created_at(main, ts)
}

fn story(main: &Arc<HavenSocial>, p: Option<&Persona>, media: &[String], caption: &str, mins_ago: u64) {
    let Some(p) = p else { return };
    if p.engine.post(DEFAULT_CIRCLE.into(), caption.into(), media.to_vec(), None, Some(86_400), true,
                     false, ms_ago(mins_ago)).is_ok()
    {
        replay_into_main(main, &p.engine, DEFAULT_CIRCLE); // commit + re-sealed events (see friend_post)
    }
}

/// Friends react to a target post. `by` are indices into `people`.
///
/// Note the replay — a reaction is epoch-sealed like a post, and by now the friend has ingested my
/// commit (they need my post to react to it), which puts them on an epoch I haven't seen. Receiving
/// the bare envelope `react()` returns drops the reaction silently. See the tests.
fn react(main: &Arc<HavenSocial>, people: &[Persona], target: &Option<String>, emoji: &str, by: &[usize]) {
    let Some(id) = target else { return };
    for i in by {
        let Some(p) = people.get(*i) else { continue };
        ensure_has_circle_history(main, &p.engine);
        if p.engine.react(DEFAULT_CIRCLE.into(), id.clone(), emoji.into(), ms_ago(5)).is_ok() {
            replay_into_main(main, &p.engine, DEFAULT_CIRCLE);
        }
    }
}

fn comment(main: &Arc<HavenSocial>, people: &[Persona], target: &Option<String>, i: usize, body: &str,
           mins_ago: u64) {
    let (Some(id), Some(p)) = (target, people.get(i)) else { return };
    ensure_has_circle_history(main, &p.engine);
    if p.engine.comment(DEFAULT_CIRCLE.into(), id.clone(), body.into(), vec![], ms_ago(mins_ago)).is_ok() {
        replay_into_main(main, &p.engine, DEFAULT_CIRCLE); // epoch-sealed, same as react
    }
}

/// Replay MY whole circle history into a friend's engine so they can react/comment on my posts.
/// Idempotent — receiving a known envelope is a no-op.
fn ensure_has_circle_history(main: &Arc<HavenSocial>, friend: &Arc<HavenSocial>) {
    for env in main.sync_envelopes(DEFAULT_CIRCLE.into()) {
        let _ = friend.receive(DEFAULT_CIRCLE.into(), env);
    }
}

/// Replay a friend's sync bundle (their epoch KEY COMMIT + re-sealed events) into my engine — what a
/// real hello back-fill delivers.
///
/// THE load-bearing call in this file. An epoch-sealed post only opens with the AUTHOR's key commit,
/// so feeding `receive` the bare post envelope returned by `post()` is accepted and then silently
/// never opens. Apple hit this (`DemoSeed.swift:285`) and Android shipped it in three places.
fn replay_into_main(main: &Arc<HavenSocial>, friend: &Arc<HavenSocial>, circle: &str) {
    for env in friend.sync_envelopes(circle.to_string()) {
        let _ = main.receive(circle.to_string(), env);
    }
}

/// Build a two-person DM circle and a short back-and-forth thread.
fn seed_dm(main: &Arc<HavenSocial>, main_hex: &str, friend: &Persona,
           lines: &[(bool, &str, u64, Option<TrackRefFfi>)]) {
    let mut ends = [main_hex.to_string(), friend.hex.clone()];
    ends.sort();
    let dm_id = format!("dm:{}-{}", ends[0], ends[1]);
    main.create_circle(dm_id.clone(), friend.name.into());
    let _ = main.add_existing_to_circle(dm_id.clone(), friend.hex.clone());
    friend.engine.create_circle(dm_id.clone(), "Riley Avery".into());
    let _ = friend.engine.add_contact_bundle(dm_id.clone(), main.my_bundle());
    for (mine, body, mins, music) in lines {
        let ts = ms_ago(*mins);
        if *mine {
            let _ = main.post(dm_id.clone(), (*body).into(), vec![], music.clone(), None, false, false, ts);
        } else if friend.engine.post(dm_id.clone(), (*body).into(), vec![], music.clone(), None, false,
                                     false, ts).is_ok()
        {
            replay_into_main(main, &friend.engine, &dm_id); // epoch-sealed, same as friend_post
        }
    }
}

// ---- small utilities -------------------------------------------------------------------------

fn id_for_created_at(main: &Arc<HavenSocial>, ts: u64) -> Option<String> {
    main.feed(DEFAULT_CIRCLE.into(), now_ms(), None)
        .into_iter()
        .find(|i| i.created_at == ts)
        .map(|i| i.id)
}

fn track(title: &str, artist: &str) -> TrackRefFfi {
    TrackRefFfi {
        catalog_id: format!("demo-{title}"),
        title: title.into(),
        artist: artist.into(),
        artwork_url: String::new(),
        duration_ms: 192_000,
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

fn ms_ago(mins: u64) -> u64 {
    now_ms().saturating_sub(mins * 60_000)
}

/// A deterministic 32-byte account seed from one distinguishing byte (mirrors `DemoSeed.seedData`).
fn seed_bytes(b: u8) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, slot) in out.iter_mut().enumerate() {
        *slot = b.wrapping_add(i as u8);
    }
    out
}

// ---- demo art --------------------------------------------------------------------------------
//
// Abstract gradient "photos", generated here rather than bundled. iOS ships real (people-free)
// stock photography as assets; desktop has no asset pipeline, and a generated gradient is provably
// PII-free — there is no image of anything. Encoded as PNG by hand: an encoder for a two-stop
// gradient is ~40 lines of stored-deflate, which is cheaper than taking an image-crate dependency
// that a release build would then carry for a debug-only feature.
mod art {
    /// One demo photo: a two-stop palette (RGB start → end) and its pixel size.
    ///
    /// The SIZES are deliberate, not incidental — `app.js` picks a carousel's page shape from the
    /// aspects it decodes:
    ///   • stories are portrait, because the story viewer is full-bleed;
    ///   • single-photo posts are 3:2 landscape, so a 1180px-wide window shows a post AND its
    ///     reactions AND the next author, rather than one giant card (0.8 is `PAGE_ASPECT_MIN` —
    ///     the tallest page the feed allows, and the worst case for a screenshot);
    ///   • the three brunch photos are MIXED on purpose. A uniform set keeps its exact aspect and
    ///     nothing letterboxes, so the blurred backdrop never draws — the mixed set is what actually
    ///     exercises the carousel's fit + blur-backdrop path.
    const PHOTOS: [(([u8; 3], [u8; 3]), usize, usize); 10] = [
        (([255, 154, 92], [122, 47, 122]), 900, 1200),  // sunset  — story, portrait
        (([104, 168, 196], [38, 61, 92]), 900, 1200),   // ridge   — story, portrait
        (([196, 148, 104], [74, 46, 34]), 900, 1200),   // coffee  — my story, portrait
        (([214, 132, 108], [92, 54, 68]), 1200, 800),   // pottery — 3:2
        (([126, 176, 116], [34, 66, 58]), 1200, 800),   // trail   — 3:2
        (([146, 196, 138], [40, 78, 62]), 1200, 800),   // plant   — 3:2
        (([228, 186, 132], [110, 74, 52]), 1200, 800),  // pup     — 3:2
        (([238, 172, 128], [124, 62, 62]), 1200, 800),  // brunch a — landscape ┐ mixed set:
        (([222, 196, 140], [96, 82, 52]), 1000, 1000),  // brunch b — square    ├ letterboxes,
        (([196, 156, 168], [72, 48, 78]), 900, 1200),   // brunch c — portrait  ┘ blur draws
    ];

    /// A diagonal two-stop gradient PNG for photo `i` (wraps).
    pub fn gradient(i: usize) -> Vec<u8> {
        let ((a, b), w, h) = PHOTOS[i % PHOTOS.len()];
        let mut raw = Vec::with_capacity(h * (1 + w * 3));
        for y in 0..h {
            raw.push(0); // filter: none
            for x in 0..w {
                // Diagonal ramp, so the blur backdrop behind a carousel has something to work with.
                // Signed throughout: every palette ramps at least one channel DOWN, and that
                // difference underflows if it ever touches an unsigned type.
                let t = (x + y) as i32 * 255 / (w + h - 2) as i32;
                for c in 0..3 {
                    let (from, to) = (a[c] as i32, b[c] as i32);
                    raw.push((from + (to - from) * t / 255) as u8);
                }
            }
        }
        png(&raw, w, h)
    }

    fn png(raw: &[u8], w: usize, h: usize) -> Vec<u8> {
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        let mut ihdr = Vec::new();
        ihdr.extend((w as u32).to_be_bytes());
        ihdr.extend((h as u32).to_be_bytes());
        ihdr.extend([8, 2, 0, 0, 0]); // 8-bit, truecolour RGB, no interlace
        chunk(&mut out, b"IHDR", &ihdr);
        chunk(&mut out, b"IDAT", &zlib_stored(raw));
        chunk(&mut out, b"IEND", &[]);
        out
    }

    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend((data.len() as u32).to_be_bytes());
        out.extend(kind);
        out.extend(data);
        let mut crc_in = kind.to_vec();
        crc_in.extend(data);
        out.extend(crc32(&crc_in).to_be_bytes());
    }

    /// zlib stream of DEFLATE *stored* (uncompressed) blocks — no compressor needed.
    fn zlib_stored(raw: &[u8]) -> Vec<u8> {
        let mut out = vec![0x78, 0x01];
        let mut rest = raw;
        loop {
            let n = rest.len().min(65_535);
            let last = n == rest.len();
            out.push(if last { 1 } else { 0 }); // BFINAL, BTYPE=00 (stored)
            out.extend((n as u16).to_le_bytes());
            out.extend((!(n as u16)).to_le_bytes());
            out.extend(&rest[..n]);
            rest = &rest[n..];
            if last {
                break;
            }
        }
        out.extend(adler32(raw).to_be_bytes());
        out
    }

    fn crc32(buf: &[u8]) -> u32 {
        let mut c = 0xFFFF_FFFFu32;
        for &b in buf {
            c ^= b as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }

    fn adler32(buf: &[u8]) -> u32 {
        let (mut a, mut b) = (1u32, 0u32);
        for &x in buf {
            a = (a + x as u32) % 65_521;
            b = (b + a) % 65_521;
        }
        (b << 16) | a
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gradient_is_a_valid_png() {
        let p = art::gradient(0);
        assert_eq!(&p[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        assert_eq!(&p[12..16], b"IHDR");
        assert!(p.ends_with(&[0xAE, 0x42, 0x60, 0x82])); // IEND crc
        assert_eq!(crate::localmedia::image_mime(&p), "image/png");
    }

    #[test]
    fn palettes_are_distinct() {
        // Each demo photo must look different — identical refs would also collide in the
        // content-addressed media store and render the carousel as one repeated image.
        let refs: std::collections::HashSet<_> = (0..10).map(|i| art::gradient(i)).collect();
        assert_eq!(refs.len(), 10);
    }

    #[test]
    fn seeds_are_deterministic_and_distinct() {
        assert_eq!(seed_bytes(0xA1), seed_bytes(0xA1));
        assert_ne!(seed_bytes(0xA1), seed_bytes(0xB2));
        assert_eq!(seed_bytes(0xA1)[0], 0xA1);
        assert_eq!(seed_bytes(0xA1)[1], 0xA2);
    }

    /// A friend's REACTION is epoch-sealed exactly like their post, so it needs the same treatment.
    /// This is a level deeper than the post bug: by the time a friend reacts, they have ingested my
    /// key commit (they need my post to react to it), which moves them to a NEWER epoch that I have
    /// not seen — so the bare envelope `react()` returns no longer opens for me, and the reaction
    /// vanishes with no error. Seeding via bare receive produced 0 reactions on a 5-post feed.
    #[test]
    fn friend_reaction_needs_the_sync_bundle_too() {
        let cid = DEFAULT_CIRCLE.to_string();
        let me = HavenSocial::new(seed_bytes(0x11).to_vec()).unwrap();
        let friend = HavenSocial::new(seed_bytes(0x12).to_vec()).unwrap();
        me.create_circle(cid.clone(), "c".into());
        friend.create_circle(cid.clone(), "c".into());
        me.add_contact_bundle(cid.clone(), friend.my_bundle()).unwrap();
        friend.add_contact_bundle(cid.clone(), me.my_bundle()).unwrap();

        // I post; the friend ingests my history so they hold the post they're reacting to.
        me.post(cid.clone(), "mine".into(), vec![], None, None, false, false, 1_000).unwrap();
        ensure_has_circle_history(&me, &friend);
        let target = me.feed(cid.clone(), now_ms(), None)[0].id.clone();

        let env = friend.react(cid.clone(), target, "🔥".into(), 2_000).unwrap();
        let _ = me.receive(cid.clone(), env); // the bare envelope
        let bare = me.feed(cid.clone(), now_ms(), None)[0].reactions.len();

        replay_into_main(&me, &friend, DEFAULT_CIRCLE);
        let replayed = me.feed(cid.clone(), now_ms(), None)[0].reactions.len();
        assert_eq!(replayed, 1, "the friend's reaction must open after the sync bundle is replayed");
        assert_eq!(bare, 0, "if this ever passes bare, the core changed — simplify react()");
    }

    /// The bug this file exists to not reintroduce: a friend's epoch-sealed post only opens once the
    /// AUTHOR's key commit has been replayed, so a bare post envelope must NOT be enough.
    #[test]
    fn friend_post_needs_the_sync_bundle_not_a_bare_envelope() {
        let cid = DEFAULT_CIRCLE.to_string();
        let me = HavenSocial::new(seed_bytes(0x01).to_vec()).unwrap();
        let friend = HavenSocial::new(seed_bytes(0x02).to_vec()).unwrap();
        me.create_circle(cid.clone(), "c".into());
        friend.create_circle(cid.clone(), "c".into());
        me.add_contact_bundle(cid.clone(), friend.my_bundle()).unwrap();
        friend.add_contact_bundle(cid.clone(), me.my_bundle()).unwrap();

        let env = friend
            .post(cid.clone(), "hi".into(), vec![], None, None, false, false, 1_000)
            .unwrap();
        let _ = me.receive(cid.clone(), env); // the bare envelope — Android's bug
        let bare = me.feed(cid.clone(), now_ms(), None).len();

        replay_into_main(&me, &friend, DEFAULT_CIRCLE);
        let replayed = me.feed(cid.clone(), now_ms(), None).len();
        assert_eq!(replayed, 1, "the friend's post must open after the sync bundle is replayed");
        assert!(bare <= replayed);
    }
}
