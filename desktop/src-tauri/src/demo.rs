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
//! 3. **It never goes online.** `HAVEN_DEMO=1` implies `HAVEN_NO_NET`, and that is enforced at every
//!    outbound transport (see `netgate`), not just at `Engine::start`: the relay HTTP lane, S3, the
//!    push worker, the moderation ledger and the iTunes lookups all refuse, so no UI-driven command
//!    can leak the synthetic cast to a real peer. Everything below is local anyway: authoring +
//!    `receive` are pure state transitions.

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
            p.contacts.push(Contact { id_hex: hex.clone(), name: name.to_string(), verify_hex, emoji: String::new(), avatar: String::new(), bio: String::new(), link: String::new() })
        });
        people.push(Persona { name, engine: friend, hex });
    }

    // ── Demo media (the same real, PII-free photos iOS and Android bundle) ────────────────
    let photo = |bytes: &[u8]| -> String { engine.add_local_media(DEFAULT_CIRCLE, bytes, false) };
    let video = |bytes: &[u8]| -> String { engine.add_local_media(DEFAULT_CIRCLE, bytes, true) };
    let (sunset, ridge, coffee) = (photo(assets::SUNSET), photo(assets::RIDGE), photo(assets::COFFEE));
    let (pottery, trail, plant, pup) =
        (photo(assets::POTTERY), photo(assets::TRAIL), photo(assets::PLANT), photo(assets::PUP));
    let brunch = photo(assets::BRUNCH);
    let (vid_cove, vid_ridge) = (video(assets::VIDEO_COVE), video(assets::VIDEO_RIDGE));

    // Own avatar: local-only on desktop (prefs, never broadcast), but it's what the You tab draws.
    let me_avatar = assets::data_url(assets::AVATAR_ME, "image/jpeg");
    engine.demo_with_prefs(|p| p.profile.avatar = me_avatar);

    // ── Stories tray (two friends + me) ───────────────────────────────────────────────────
    story(&main, people.first(), &[sunset.clone()], "golden hour at the cove 🌅", 40);
    story(&main, people.get(1), &[ridge], "made it to the ridge 🥾", 95);
    let _ = main.post(DEFAULT_CIRCLE.into(), "studio fuel ☕️".into(), vec![coffee], None,
                      Some(86_400), true, false, ms_ago(20));

    // ── The circle feed: friends + me, with reactions + comments ──────────────────────────
    let p1 = friend_post(&main, &people, 0, "first throw off the new wheel 🪴 obsessed", &[pottery], None, 180);
    let p2 = friend_post(&main, &people, 1, "12 miles before breakfast. trail magic is real.", &[trail],
                         Some(track("Sunrun", "The Wanderers")), 140);
    let p3 = my_post(&main, "new little corner of the studio came together today 🌿", &[plant], 75);
    // Two ADJACENT video posts + a mixed carousel — Android's demo shape (DemoSeed.kt). The feed
    // autoplays only the centred card's visible page, so this is what makes that coordinator visible;
    // the still+clip pair is also the only genuinely MIXED-aspect carousel now that every bundled
    // photo is the same 1080x1350, so it's what exercises the fit + blurred-backdrop path.
    my_post(&main, "the cove at golden hour, on repeat 🌊", &[vid_cove.clone()], 58);
    my_post(&main, "ridge wind — sound off, obviously 🏔️", &[vid_ridge], 52);
    my_post(&main, "a clip and a still from the same afternoon", &[sunset, vid_cove], 46);
    let p4 = friend_post(&main, &people, 2, "everyone, meet the newest member of the crew 🐾", &[pup], None, 30);
    let p5 = friend_post(&main, &people, 3, "sunday slow brunch — the sourdough finally rose 🍞",
                         &[brunch], None, 12);

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
// The SAME real, royalty-free, people-free photos iOS and Android bundle — not gradients. Desktop
// generated two-stop gradients here instead, on the theory that it had no asset pipeline; the result
// was a screenshot set where every "photo" was a flat tan rectangle while the phones showed an actual
// brunch. `include_bytes!` IS the asset pipeline: this module is `#[cfg(debug_assertions)]`, so not
// one of these bytes reaches a release binary.
//
// Byte-for-byte copies of `apple/HavenApp/DemoAssets` (+ Android's two demo clips), checked in HERE
// rather than `include_bytes!`d across the tree. Reaching into `../../../apple/…` was the first
// instinct — one set of bytes, no drift — and it broke immediately: desktop is routinely checked out
// as core/ + desktop/ alone (that's all the Windows build box has), and coupling the Windows build to
// the Apple tree fails it for a debug-only screenshot feature. Android duplicates the same files for
// the same reason. If these ever need refreshing, copy them from Apple again — that's the source.
#[rustfmt::skip]
mod assets {
    pub const SUNSET:  &[u8] = include_bytes!("../demo-assets/photo-sunset.jpg");
    pub const RIDGE:   &[u8] = include_bytes!("../demo-assets/photo-ridge.jpg");
    pub const COFFEE:  &[u8] = include_bytes!("../demo-assets/photo-coffee.jpg");
    pub const POTTERY: &[u8] = include_bytes!("../demo-assets/photo-pottery.jpg");
    pub const TRAIL:   &[u8] = include_bytes!("../demo-assets/photo-trail.jpg");
    pub const PLANT:   &[u8] = include_bytes!("../demo-assets/photo-plant.jpg");
    pub const PUP:     &[u8] = include_bytes!("../demo-assets/photo-pup.jpg");
    pub const BRUNCH:  &[u8] = include_bytes!("../demo-assets/photo-brunch.jpg");
    pub const AVATAR_ME: &[u8] = include_bytes!("../demo-assets/avatar-me.jpg");
    pub const VIDEO_COVE:  &[u8] = include_bytes!("../demo-assets/video-cove.mp4");
    pub const VIDEO_RIDGE: &[u8] = include_bytes!("../demo-assets/video-ridge.mp4");

    /// A `data:` URL — the shape the frontend's `img src` wants for a prefs-stored avatar.
    pub fn data_url(bytes: &[u8], mime: &str) -> String {
        format!("data:{mime};base64,{}", b64(bytes))
    }

    /// Standard base64. Hand-rolled to keep a debug-only convenience from adding a dependency the
    /// release tree would carry.
    fn b64(input: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
        for c in input.chunks(3) {
            let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
            let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
            for i in 0..4 {
                // Past the real bytes each 6-bit group is padding, not data.
                if i <= c.len() {
                    out.push(T[(n >> (18 - i * 6)) as usize & 0x3F] as char);
                } else {
                    out.push('=');
                }
            }
        }
        out
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    /// Every bundled still, by the name the seeder uses for it.
    const ALL_PHOTOS: [(&str, &[u8]); 8] = [
        ("sunset", assets::SUNSET), ("ridge", assets::RIDGE), ("coffee", assets::COFFEE),
        ("pottery", assets::POTTERY), ("trail", assets::TRAIL), ("plant", assets::PLANT),
        ("pup", assets::PUP), ("brunch", assets::BRUNCH),
    ];

    /// The bundled photos must be REAL photos. `include_bytes!` guarantees the files exist (the build
    /// fails otherwise) — what it can't guarantee is that they're still decodable images rather than,
    /// say, a Git LFS pointer or a truncated copy, which would silently put an empty frame in every
    /// screenshot exactly like the gradients did.
    #[test]
    fn bundled_demo_photos_are_real_jpegs() {
        for (name, bytes) in ALL_PHOTOS {
            assert_eq!(crate::localmedia::image_mime(bytes), "image/jpeg", "{name} is not a JPEG");
            assert!(bytes.len() > 10_000, "{name} is {} bytes — truncated?", bytes.len());
        }
    }

    #[test]
    fn bundled_demo_videos_are_real_mp4s() {
        for (name, bytes) in [("cove", assets::VIDEO_COVE), ("ridge", assets::VIDEO_RIDGE)] {
            assert_eq!(&bytes[4..8], b"ftyp", "{name} is not an MP4");
            assert!(bytes.len() > 10_000, "{name} is {} bytes — truncated?", bytes.len());
        }
    }

    /// Every demo photo must be a DIFFERENT image. The media store is content-addressed, so two
    /// identical files would collapse to one ref and render the carousel as the same picture twice.
    #[test]
    fn bundled_demo_photos_are_distinct() {
        let set: std::collections::HashSet<_> = ALL_PHOTOS.iter().map(|(_, b)| *b).collect();
        assert_eq!(set.len(), ALL_PHOTOS.len());
    }

    /// The avatar has to reach the frontend as something `img src` will actually load.
    #[test]
    fn avatar_data_url_is_a_loadable_jpeg() {
        let u = assets::data_url(assets::AVATAR_ME, "image/jpeg");
        assert!(u.starts_with("data:image/jpeg;base64,/9j/"), "unexpected prefix: {}", &u[..40]);
        let b64 = u.strip_prefix("data:image/jpeg;base64,").unwrap();
        assert_eq!(b64.len() % 4, 0, "base64 must be whole quanta");
        // '=' is not in the alphabet, so it may only ever appear as trailing padding.
        assert_eq!(b64.trim_end_matches('=').find('='), None, "padding inside the body");
    }

    /// Base64 is hand-rolled here (no dependency for a debug-only file), so pin it to RFC 4648's own
    /// vectors — including each padding length, which is the only part that's easy to get wrong.
    #[test]
    fn base64_matches_rfc4648() {
        let u = |b: &[u8]| assets::data_url(b, "x").strip_prefix("data:x;base64,").unwrap().to_string();
        assert_eq!(u(b""), "");
        assert_eq!(u(b"f"), "Zg==");
        assert_eq!(u(b"fo"), "Zm8=");
        assert_eq!(u(b"foo"), "Zm9v");
        assert_eq!(u(b"foob"), "Zm9vYg==");
        assert_eq!(u(b"fooba"), "Zm9vYmE=");
        assert_eq!(u(b"foobar"), "Zm9vYmFy");
        assert_eq!(u(&[0xFF, 0xFF, 0xFF]), "////"); // the high bits of the alphabet
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
