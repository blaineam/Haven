//! Runs an Instagram archive import: stage each item's media through the engine's normal sealing
//! path, then author the post SILENTLY and BACKDATED.
//!
//! Apple parity: `apple/HavenApp/InstagramImporter.swift`. Read that file's header first — the
//! decisions restated below are the ones that cost a real bug each, and they are restated only
//! where this platform's shape makes them non-obvious.
//!
//! ARCHITECTURE. The loop lives on a plain `std::thread`, not the async runtime: it is minutes of
//! CPU-bound decompress-and-seal work, and parking a tokio worker on that would starve the node's
//! own tasks. Everything it touches on the engine is `&self`-synchronous, and the one network call
//! it makes (a song search) is bridged with `tauri::async_runtime::block_on`, which is safe here
//! precisely because this is NOT a runtime thread.
//!
//! WHAT DESKTOP DOES NOT DO, and why it is a scope statement rather than an omission:
//!
//!   * **No re-encode.** `desktop/src-tauri` carries no encoder by design (see the CODEC DIVERGENCE
//!     note at the top of `reoptimize.rs`); the only one a WebView exposes is `MediaRecorder`, which
//!     emits VP8/Opus in WebM where every other Haven client expects H.264/AAC in MP4. An Instagram
//!     export is ALREADY a re-encode — Instagram's own, at ≤1080p — so importing the bytes as they
//!     stand keeps clips playable on every platform, whereas transcoding them here would hand the
//!     circle video an iPhone cannot decode. Anything genuinely oversized is still found later by
//!     the re-optimize scan, which is where that job belongs.
//!   * **No thumbnail companions.** Minting the ≤32 KB `thumb:` sidecar the composer attaches needs
//!     a decoder for the same reason. Imported media therefore fetches at full size on first view,
//!     exactly like a photo dragged into the desktop composer with optimization unavailable.
//!   * **No Shazam.** Identifying the song already playing in a reel is an Apple-only capability.
//!     Desktop only ever SUGGESTS, and only into silence — see the audio check in `stage`.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use haven_ffi::TrackRefFfi;
use serde::{Deserialize, Serialize};

use crate::engine::Engine;
use crate::instagram::{self, Item, Kind, Summary};
use crate::songsuggest;

// ---- Phase + shared state ----------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Idle,
    Reading,
    Previewing,
    Importing,
    Finished,
    Failed,
}

#[derive(Default)]
struct ImportState {
    phase: Option<Phase>,
    summary: Option<Summary>,
    archive_path: Option<PathBuf>,
    /// Shared with the running thread. Replaced (not merely cleared) per run, so a cancel aimed at
    /// a finished run can never stop the next one.
    cancel: Option<Arc<AtomicBool>>,
    running: bool,
    done: usize,
    total: usize,
    imported: usize,
    skipped: usize,
    /// Songs suggested this run, so one track is not attached to every silent post.
    used_songs: HashSet<String>,
    message: String,
    /// The checkpoint a STOPPED run left behind, so "Stop" can be offered as the pause it actually
    /// is without waiting for a relaunch to notice it. `None` once the run finishes on its own.
    resume: Option<Pending>,
}

impl ImportState {
    fn phase(&self) -> Phase {
        self.phase.unwrap_or(Phase::Idle)
    }
}

fn state() -> &'static Mutex<ImportState> {
    static S: OnceLock<Mutex<ImportState>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(ImportState::default()))
}

// ---- Resume across relaunch ---------------------------------------------------------------------

/// Everything needed to pick a half-finished import back up after Haven is quit or killed.
///
/// `done` is an index into the deterministic item order — see `instagram::read`, which sorts with a
/// tiebreak precisely so this index means the same thing on every run. `include_stories` is part of
/// the record because it CHANGES that order's membership: resuming with a different answer would
/// shift every subsequent index.
///
/// A plain path, not a bookmark: desktop has no sandbox indirection, so the path the user picked is
/// the path that still works next launch. If the archive has been moved or deleted, the resume is
/// abandoned silently — nagging about it on every cold start would be worse than forgetting an
/// import they can simply run again.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Pending {
    archive_path: String,
    circle_id: String,
    #[serde(default)]
    include_stories: bool,
    #[serde(default)]
    match_songs: bool,
    #[serde(default)]
    done: usize,
}

fn load_pending(engine: &Engine) -> Option<Pending> {
    let raw = std::fs::read(engine.paths().instagram_import_file()).ok()?;
    serde_json::from_slice(&raw).ok()
}

fn save_pending(engine: &Engine, p: &Pending) {
    if let Ok(bytes) = serde_json::to_vec_pretty(p) {
        let _ = std::fs::write(engine.paths().instagram_import_file(), bytes);
    }
}

fn clear_pending(engine: &Engine) {
    let _ = std::fs::remove_file(engine.paths().instagram_import_file());
}

/// Restart an import that a quit or a crash interrupted. Called once, after the engine starts.
pub fn resume_if_needed(engine: Arc<Engine>) {
    {
        let st = state().lock().unwrap();
        if st.running {
            return;
        }
    }
    let Some(p) = load_pending(&engine) else { return };
    let path = PathBuf::from(&p.archive_path);
    if !path.exists() {
        clear_pending(&engine);
        return;
    }
    std::thread::spawn(move || {
        let summary = match instagram::read(&path) {
            Ok(s) => s,
            Err(_) => {
                clear_pending(&engine);
                return;
            }
        };
        let total = ordered(&summary, p.include_stories).len();
        if p.done >= total {
            clear_pending(&engine);
            return;
        }
        {
            let mut st = state().lock().unwrap();
            st.archive_path = Some(path);
            st.summary = Some(summary);
            st.phase = Some(Phase::Previewing); // `run` requires this state
        }
        log::info!("ig-import: resuming at {}/{total}", p.done);
        run(engine, p.circle_id, p.include_stories, p.match_songs, p.done);
    });
}

// ---- Preview ------------------------------------------------------------------------------------

/// Parse an archive for the preview. Never blocks the caller: on a 1.28 GB export this walks a
/// multi-megabyte JSON and seeks the whole central directory.
pub fn read(engine: Arc<Engine>, path: String) {
    {
        let mut st = state().lock().unwrap();
        if st.running {
            return; // an import is already in flight; do not swap the archive out from under it
        }
        st.phase = Some(Phase::Reading);
        st.summary = None;
        st.message.clear();
    }
    emit(&engine);
    std::thread::spawn(move || {
        let path = PathBuf::from(path);
        match instagram::read(&path) {
            Ok(s) => {
                let mut st = state().lock().unwrap();
                st.archive_path = Some(path);
                st.summary = Some(s);
                st.phase = Some(Phase::Previewing);
            }
            Err(e) => {
                let mut st = state().lock().unwrap();
                st.phase = Some(Phase::Failed);
                st.message = e.message().to_string();
            }
        }
        emit(&engine);
    });
}

pub fn cancel() {
    let st = state().lock().unwrap();
    if let Some(c) = &st.cancel {
        c.store(true, Ordering::SeqCst);
    }
}

/// Back to square one. Refuses while a run is in flight — closing the window is not cancelling.
pub fn reset(engine: &Engine) {
    let mut st = state().lock().unwrap();
    if st.running {
        return;
    }
    *st = ImportState::default();
    drop(st);
    emit(engine);
}

// ---- Import --------------------------------------------------------------------------------------

/// Publish every parsed item into `circle_id`, NEWEST FIRST.
///
/// The feed is newest-first (haven-p2p `map_feed` ends with `order.iter().rev()`). Importing
/// oldest-first therefore meant every post published was NEWER than all the ones before it, so each
/// landed at the TOP of the list — directly above whatever the reader was looking at, shoving the
/// page down, hundreds of times. No amount of refresh throttling or scroll anchoring fixes that;
/// the content genuinely is arriving above them.
///
/// Reversed, each post is OLDER than the last and lands at the BOTTOM, below the reader, where new
/// arrivals cost them nothing. The feed grows downwards and their position is untouched.
///
/// `start_at` resumes a previous run. Only `resume_if_needed` passes it; a fresh import starts at 0.
pub fn run(
    engine: Arc<Engine>,
    circle_id: String,
    include_stories: bool,
    match_songs: bool,
    start_at: usize,
) {
    let (items, path) = {
        let mut st = state().lock().unwrap();
        if st.running || st.phase() != Phase::Previewing {
            return;
        }
        let (Some(summary), Some(path)) = (st.summary.as_ref(), st.archive_path.clone()) else {
            return;
        };
        let items = ordered(summary, include_stories);
        st.phase = Some(Phase::Importing);
        st.running = true;
        st.total = items.len();
        st.done = start_at.min(items.len());
        st.imported = 0;
        st.skipped = 0;
        st.used_songs.clear();
        st.resume = None;
        st.cancel = Some(Arc::new(AtomicBool::new(false)));
        (items, path)
    };
    let cancel = state().lock().unwrap().cancel.clone().unwrap_or_default();

    // Record the job BEFORE any work, so a crash on the very first item still resumes.
    save_pending(
        &engine,
        &Pending {
            archive_path: path.to_string_lossy().to_string(),
            circle_id: circle_id.clone(),
            include_stories,
            match_songs,
            done: start_at,
        },
    );
    emit(&engine);

    std::thread::spawn(move || {
        let total = items.len();
        let mut zip = match instagram::Archive::open(&path) {
            Ok(z) => z,
            Err(e) => {
                {
                    let mut st = state().lock().unwrap();
                    st.running = false;
                    st.phase = Some(Phase::Failed);
                    st.message = e.message().to_string();
                }
                emit(&engine);
                return;
            }
        };
        let present: HashSet<String> = zip.names().into_iter().collect();
        let mut imported = 0usize;
        let mut skipped = 0usize;
        // Every catalog id already attached this run. Without it, one search term per year meant one
        // song for every silent post in that year.
        let mut used_songs: HashSet<String> = HashSet::new();
        // The feed rebuild is asked for as we go, but THROTTLED. `haven:changed` triggers a full
        // re-render plus half a dozen `invoke`s in the frontend, so firing it 372 times back to back
        // makes the window unusable for the length of the import — the opposite of what running in
        // the background is for. Roughly every two seconds is enough for the feed to visibly fill in.
        let mut last_feed_nudge = std::time::Instant::now();
        log::info!("ig-import: starting {total} items from {start_at}");

        for (idx, item) in items.iter().enumerate() {
            if idx < start_at {
                continue; // already imported on a previous run
            }
            if cancel.load(Ordering::SeqCst) {
                break;
            }
            let began = std::time::Instant::now();
            let (refs, has_audio) =
                stage(&engine, &mut zip, &present, &circle_id, item, &cancel);
            // Stop means STOP. Staging one item can take a while (a 20-photo carousel is 20 seals),
            // and the check above happened before all of it — so hitting Stop used to finish the
            // item AND publish it, which is not what "stop" looks like from the outside.
            if cancel.load(Ordering::SeqCst) {
                break;
            }
            if refs.is_empty() {
                skipped += 1;
            } else {
                // Suggest a song ONLY into silence. A reel that shipped with its soundtrack keeps
                // it — that audio is baked into the video and is what the user actually chose;
                // layering a guess over it would be worse than adding nothing.
                let music = if match_songs && !has_audio {
                    let themes = songsuggest::caption_themes(&item.body, 2);
                    let (year, month) = songsuggest::year_month(item.created_at);
                    let picked = tauri::async_runtime::block_on(songsuggest::song(
                        &themes,
                        item.music_genre.as_deref(),
                        year,
                        month,
                        &used_songs,
                    ));
                    if let Some(t) = &picked {
                        used_songs.insert(t.catalog_id.clone());
                    }
                    picked.map(|t| TrackRefFfi {
                        catalog_id: t.catalog_id,
                        title: t.title,
                        artist: t.artist,
                        artwork_url: t.artwork_url,
                        duration_ms: t.duration_ms,
                    })
                } else {
                    None
                };

                if item.kind == Kind::Story {
                    // Stories, when the user opted in, land as KEPT stories rather than feed posts:
                    // a personal snapshot on their own profile with its media pinned. Keeping
                    // deliberately does not republish, which is what makes this safe — nobody else's
                    // feed fills with someone's old stories, and the circle is not asked to carry
                    // them at all. (Instagram auto-archives EVERY story and the export cannot say
                    // which were Highlights, so publishing them would resurrect years of things the
                    // user deliberately let expire.)
                    engine.keep_story(crate::store::KeptStory {
                        id: kept_identity(item),
                        body: item.body.clone(),
                        media: refs,
                        created_at: item.created_at,
                        kept_at: None, // stamped by keep_story
                        music_catalog_id: music.as_ref().map(|m| m.catalog_id.clone()),
                        music_title: music.as_ref().map(|m| m.title.clone()),
                        music_artist: music.as_ref().map(|m| m.artist.clone()),
                        music_artwork_url: music.as_ref().map(|m| m.artwork_url.clone()),
                        music_duration_ms: music.as_ref().map(|m| m.duration_ms),
                    });
                } else {
                    engine.post_imported(
                        circle_id.clone(),
                        item.body.clone(),
                        refs,
                        music,
                        false,
                        item.created_at, // BACKDATED — the whole point of importing history
                    );
                }
                imported += 1;
            }

            // Checkpoint after EVERY item. The unit of work is one post, so the most a kill can cost
            // is the item in flight — re-importing that one item is the failure mode we accept,
            // rather than re-importing all 300.
            let done = idx + 1;
            {
                let mut st = state().lock().unwrap();
                st.done = done;
                st.imported = imported;
                st.skipped = skipped;
                st.used_songs = used_songs.clone();
            }
            save_pending(
                &engine,
                &Pending {
                    archive_path: path.to_string_lossy().to_string(),
                    circle_id: circle_id.clone(),
                    include_stories,
                    match_songs,
                    done,
                },
            );
            let secs = began.elapsed().as_secs_f64();
            if secs > 5.0 {
                log::info!(
                    "ig-import: item {done}/{total} took {secs:.1}s ({} media)",
                    item.media_names.len()
                );
            }
            emit(&engine); // progress: cheap, and the pill/sheet want every tick
            if last_feed_nudge.elapsed() >= std::time::Duration::from_secs(2) {
                last_feed_nudge = std::time::Instant::now();
                engine.emit_changed();
            }
        }

        let stopped = cancel.load(Ordering::SeqCst);
        // A cancel KEEPS the checkpoint, so "Stop" is really "pause" — reopening the importer offers
        // to carry on. Finishing clears it.
        if !stopped {
            clear_pending(&engine);
        }
        {
            let mut st = state().lock().unwrap();
            st.running = false;
            st.phase = Some(Phase::Finished);
            st.imported = imported;
            st.skipped = skipped;
            st.resume = if stopped { load_pending(&engine) } else { None };
        }
        log::info!("ig-import: done — {imported} imported, {skipped} skipped, stopped={stopped}");
        emit(&engine);
        engine.emit_changed();
    });
}

/// The import order: stories filtered out unless asked for, then REVERSED so the newest post is
/// published first. Pure, so the resume path can recompute the same `total` without duplicating the
/// rule.
fn ordered(summary: &Summary, include_stories: bool) -> Vec<Item> {
    let mut items: Vec<Item> = summary
        .items
        .iter()
        .filter(|i| include_stories || i.kind != Kind::Story)
        .cloned()
        .collect();
    items.reverse();
    items
}

/// Stable id for a kept story, derived from the archive entry it came from.
///
/// `keep_story` is keyed on the original event id so a story is kept at most once — an import has no
/// Haven event to point at, so the archive path stands in. It is stable across runs, which makes
/// re-importing the same export idempotent instead of doubling every story. Apple parity.
fn kept_identity(item: &Item) -> String {
    match item.media_names.first() {
        Some(n) => format!("ig:{n}"),
        None => format!("ig:{}", item.created_at),
    }
}

/// Turn one parsed item's archive entries into Haven media refs, in album order.
///
/// A carousel stays ONE post: every photo in the album is staged into the same `media` array, so a
/// 20-photo Instagram carousel arrives as a 20-photo Haven post rather than 20 posts.
///
/// Returns the refs and whether ANY of this post's media makes a sound — one song plays per post, so
/// a carousel holding a single talking video must not get one layered on top of it.
fn stage(
    engine: &Arc<Engine>,
    zip: &mut instagram::Archive,
    present: &HashSet<String>,
    circle_id: &str,
    item: &Item,
    cancel: &AtomicBool,
) -> (Vec<String>, bool) {
    let mut refs = Vec::new();
    let mut any_audio = false;
    for name in &item.media_names {
        // A 20-photo carousel is 20 seals; a cancel should not have to wait out the album.
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        if !present.contains(name) {
            continue; // named by the JSON but absent from the archive (a partial download)
        }
        if instagram::is_video(name) {
            // Spilled to scratch and sealed file→file: `add_local_media_file` is the off-heap path,
            // so a 200 MB reel never exists as a plaintext + sealed `Vec` pair in this process.
            let scratch = scratch_path(&instagram::ext(name));
            if !zip.extract_to(name, &scratch) {
                let _ = std::fs::remove_file(&scratch);
                continue;
            }
            // Asked of the REAL file: "is it a video" and "does it make sound" are different
            // questions. A screen recording, a time-lapse or a clip muted before posting is a silent
            // video and deserves a song as much as a photo does. `None` = could not tell, which must
            // read as AUDIBLE (see `mp4_file_has_audio_track`).
            if songsuggest::mp4_file_has_audio_track(&scratch) != Some(false) {
                any_audio = true;
            }
            if let Some(r) = engine.add_local_media_file(circle_id, &scratch.to_string_lossy(), true)
            {
                // POSTER. Sealed first, asked about second — see `igencode`: the clip is never
                // shipped to the WebView (a reel would become a base64 string a third larger than
                // itself) and is never re-encoded. The WebView reads the sealed ref back and
                // returns a still, which is what a story ring and a video tile draw before play.
                // Without it, imported video reaches every platform with nothing to show.
                let poster = crate::igencode::poster(engine, circle_id, &r);
                refs.push(r);
                if let Some(extra) = poster {
                    refs.extend(extra);
                }
            } else {
                log::warn!("ig-import: video stage failed for {name}");
            }
            let _ = std::fs::remove_file(&scratch);
        } else {
            let Some(bytes) = zip.read(name) else { continue };
            // AUTO-OPTIMIZE. The WebView owns the only encoder this app has, so the still goes
            // there to be downscaled, re-encoded and given its ≤32 KB `thumb:` companion, exactly
            // as a photo dropped into the composer is. It comes back as refs already stored.
            // Falling back to sealing the archive bytes is the old behaviour, and is what happens
            // if the window is closed or the frontend refuses the file.
            match crate::igencode::image(engine, circle_id, &bytes) {
                Some(encoded) if !encoded.is_empty() => refs.extend(encoded),
                _ => refs.push(engine.add_local_media(circle_id, &bytes, false)),
            }
        }
    }
    (refs, any_audio)
}

fn scratch_path(ext: &str) -> PathBuf {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("haven-igimport-{}-{n}.{ext}", std::process::id()))
}

/// Carry on from a STOPPED run, in this session — the checkpoint a cancel deliberately kept.
///
/// Re-enters through `run`, which owns every invariant (it re-derives the item order from the same
/// summary and the same `include_stories` answer, so `done` still means what it meant). A relaunch
/// takes the other door, `resume_if_needed`, and lands in exactly the same place.
pub fn resume_now(engine: Arc<Engine>) {
    let pending = {
        let mut st = state().lock().unwrap();
        if st.running {
            return;
        }
        let Some(p) = st.resume.clone() else { return };
        st.phase = Some(Phase::Previewing); // `run` requires this state
        p
    };
    run(engine, pending.circle_id, pending.include_stories, pending.match_songs, pending.done);
}

// ---- Status ---------------------------------------------------------------------------------------

/// What the UI draws from — the whole importer in one JSON object, so a view that mounts mid-import
/// (or after a relaunch resumed one) renders correctly without replaying any events.
pub fn status() -> serde_json::Value {
    let st = state().lock().unwrap();
    let summary = st.summary.as_ref().map(|s| {
        serde_json::json!({
            "posts": s.count(Kind::Post),
            "reels": s.count(Kind::Reel),
            "stories": s.count(Kind::Story),
            "items": s.items.len(),
            "mediaCount": s.media_count,
            "totalBytes": s.total_bytes,
            "missing": s.missing.len(),
            "earliest": s.earliest(),
            "latest": s.latest(),
        })
    });
    serde_json::json!({
        "phase": st.phase(),
        "running": st.running,
        "done": st.done,
        "total": st.total,
        "imported": st.imported,
        "skipped": st.skipped,
        "message": st.message,
        "archivePath": st.archive_path.as_ref().map(|p| p.to_string_lossy().to_string()),
        // Present only after a Stop: how far the kept checkpoint got, so the sheet can offer to
        // carry on rather than looking like the run simply ended.
        "resumeFrom": st.resume.as_ref().map(|p| p.done),
        "summary": summary,
    })
}

fn emit(engine: &Engine) {
    engine.emit_event("haven:import", status());
}


#[cfg(test)]
mod tests {
    use super::*;

    fn item(kind: Kind, at: u64, name: &str) -> Item {
        Item {
            kind,
            created_at: at,
            body: String::new(),
            media_names: vec![name.to_string()],
            music_genre: None,
        }
    }

    fn summary(items: Vec<Item>) -> Summary {
        Summary { items, media_count: 0, total_bytes: 0, missing: vec![] }
    }

    #[test]
    fn import_order_is_newest_first() {
        // The parse hands back oldest-first; the import must walk it backwards, or every post
        // published lands ABOVE the reader in a newest-first feed.
        let s = summary(vec![
            item(Kind::Post, 1_000, "a.jpg"),
            item(Kind::Post, 2_000, "b.jpg"),
            item(Kind::Post, 3_000, "c.jpg"),
        ]);
        let got: Vec<u64> = ordered(&s, false).iter().map(|i| i.created_at).collect();
        assert_eq!(got, vec![3_000, 2_000, 1_000]);
    }

    #[test]
    fn stories_are_excluded_unless_asked_for() {
        let s = summary(vec![
            item(Kind::Post, 1_000, "a.jpg"),
            item(Kind::Story, 2_000, "s.jpg"),
            item(Kind::Reel, 3_000, "r.mp4"),
        ]);
        assert_eq!(ordered(&s, false).len(), 2);
        assert!(ordered(&s, false).iter().all(|i| i.kind != Kind::Story));
        assert_eq!(ordered(&s, true).len(), 3);
    }

    #[test]
    fn a_resumed_run_sees_the_same_sequence() {
        // `done` is an INDEX, so the order must not depend on anything but the summary and the
        // stories flag — both of which the checkpoint records.
        let s = summary(vec![
            item(Kind::Post, 1_000, "a.jpg"),
            item(Kind::Story, 1_000, "s.jpg"),
            item(Kind::Reel, 2_000, "r.mp4"),
        ]);
        let a: Vec<String> = ordered(&s, true).iter().map(|i| i.media_names[0].clone()).collect();
        let b: Vec<String> = ordered(&s, true).iter().map(|i| i.media_names[0].clone()).collect();
        assert_eq!(a, b);
    }

    #[test]
    fn kept_story_identity_is_stable_and_archive_derived() {
        let i = item(Kind::Story, 1_700_000_000_000, "media/stories/x.jpg");
        assert_eq!(kept_identity(&i), "ig:media/stories/x.jpg");
        let mut no_media = i.clone();
        no_media.media_names.clear();
        assert_eq!(kept_identity(&no_media), "ig:1700000000000");
    }
}

#[cfg(test)]
mod smoke {
    use super::*;
    use crate::engine::Engine;
    use crate::store::Paths;

    /// END-TO-END: parse a real archive, stage its bytes, PUBLISH, and read the posts back.
    ///
    /// Everything else about the desktop importer is unit-tested in pieces — ordering, checkpoints,
    /// theme extraction, the audio probe. What none of it covered is whether a post ever actually
    /// comes out the other end, which is the one thing an importer exists to do. This runs the real
    /// publish path against a real engine and asserts the feed contains the result.
    ///
    /// Hermetic: HAVEN_DESKTOP_DATA points the whole data tree at a temp dir, so this builds its own
    /// throwaway identity and cannot see (or touch) a real desktop install.
    #[test]
    fn imported_posts_actually_reach_the_feed() {
        let Some(archive) = crate::instagram::tests::validation_archive() else {
            eprintln!("skipping: no instagram-*.zip in ~/Downloads");
            return;
        };

        let tmp = std::env::temp_dir().join(format!("haven-igsmoke-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::env::set_var("HAVEN_DESKTOP_DATA", &tmp);
        let paths = Paths::resolve().expect("paths");
        let engine = Engine::new(paths, [7u8; 32]).expect("engine");

        let summary = crate::instagram::read(&archive).expect("parse");
        // NEWEST FIRST, exactly as the runner orders them.
        let items: Vec<_> = ordered(&summary, false).into_iter().take(3).collect();
        assert_eq!(items.len(), 3, "need three feed items to publish");

        let mut zip = crate::instagram::Archive::open(&archive).expect("open archive");
        let circle = "default";
        let mut published = 0usize;
        for item in &items {
            let mut refs = Vec::new();
            for name in &item.media_names {
                let Some(bytes) = zip.read(name) else { continue };
                let is_video = crate::instagram::is_video(name);
                refs.push(engine.add_local_media(circle, &bytes, is_video));
            }
            assert!(!refs.is_empty(), "staged no media for {:?}", item.media_names);
            engine.post_imported(circle.to_string(), item.body.clone(), refs,
                                 None, false, item.created_at);
            published += 1;
        }
        assert_eq!(published, 3);

        let feed = engine.feed(circle);
        assert!(feed.len() >= 3, "feed holds {} items, expected >= 3", feed.len());

        // BACKDATED — the whole point. A post must carry the archive's timestamp, not "now".
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        for item in &items {
            let found = feed.iter().find(|f| f.created_at == item.created_at)
                .unwrap_or_else(|| panic!("no feed post at {}", item.created_at));
            assert!(found.created_at < now_ms - 86_400_000,
                    "post is not backdated: {} vs now {}", found.created_at, now_ms);
            assert!(!found.media.is_empty(), "published post has no media");
        }

        // Newest-first feed: publishing oldest-last means the newest sits at the top.
        let dates: Vec<u64> = feed.iter().map(|f| f.created_at).collect();
        let mut sorted = dates.clone();
        sorted.sort_unstable_by(|a, b| b.cmp(a));
        assert_eq!(dates, sorted, "feed is not newest-first");

        std::env::remove_var("HAVEN_DESKTOP_DATA");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
