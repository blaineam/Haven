//! qa-cmd v2 driver — the desktop leg of the cross-platform QA contract — **DEBUG BUILDS ONLY**.
//!
//! docs/QA.md ("qa-cmd v2") is the spec; `Scripts/qa-e2e-full.mjs` is the consumer. A DEBUG build
//! watches `<data-dir>/qa-cmd.json` (1.5s poll, deleted after ONE consume — same one-shot contract
//! as the iOS/Android pollers) and executes the op through the SAME engine methods the Tauri UI
//! commands call, so a driven action is indistinguishable from a clicked one. Every op — and a bare
//! `{"op":"dump"}` — refreshes `<data-dir>/qa-dump.json` (`device: "desktop"`). Ops also model a
//! user ACTIVELY using the app: every recognized op resets the adaptive sync cadence, and mutating
//! ops nudge an immediate mailbox poll — but `dump` never does (`Engine::qa_mark_user_active`).
//!
//! Media staging: `photo_path` / `video_path` / `file_path` are ABSOLUTE file paths (the harness
//! stages fixtures into the data dir). `HAVEN_QA_SEED_FILE` identity adoption already lives in
//! `store.rs` / `lib.rs` — it is deliberately not duplicated here.
//!
//! Like `demo.rs`, this must never exist in a release binary: the module is declared under
//! `#[cfg(debug_assertions)]` in lib.rs, and the guard below fails the build if that ever changes.
//! (`HAVEN_QA_DRIVER=1` can therefore only ever force the watcher on where it already exists —
//! a release build has no driver to enable.)

#[cfg(not(debug_assertions))]
compile_error!("qa.rs must never be compiled into a release build (see the module docs)");

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use haven_ffi::{FeedItemFfi, TrackRefFfi};
use serde_json::{json, Value};

use crate::engine::{Engine, DEFAULT_CIRCLE};

/// How many dumps this process has successfully written. Surfaced in the dump itself so the
/// orchestrator can tell a FROZEN file apart from a leg that is merely slow: if the counter is not
/// advancing between polls, the driver is stuck or its writes are failing — which previously looked
/// exactly like "the content never arrived".
static DUMP_WRITES: AtomicU64 = AtomicU64::new(0);

/// 1×1 transparent PNG — the `media:"photo"` fallback when no `photo_path` is staged, so a driver
/// can still exercise the media lanes without a fixture (desktop has no canvas to draw one).
const QA_PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44,
    0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f,
    0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64,
    0x60, 0xf8, 0x5f, 0x0f, 0x00, 0x02, 0x87, 0x01, 0x80, 0xeb, 0x47, 0xba, 0x92, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Start the drop-file watcher (mirrors the iOS 1.5s DEBUG poller). An initial dump is written
/// immediately so the orchestrator's first read never races the first op.
pub fn start(engine: Arc<Engine>) {
    std::thread::Builder::new()
        .name("qa-driver".into())
        .spawn(move || {
            let cmd_path = engine.data_root().join("qa-cmd.json");
            write_dump(&engine);
            let mut last_dump = Instant::now();
            loop {
                std::thread::sleep(Duration::from_millis(1500));
                let data = match std::fs::read(&cmd_path) {
                    Ok(d) => {
                        let _ = std::fs::remove_file(&cmd_path); // one-shot: consume before acting
                        d
                    }
                    Err(_) => Vec::new(), // no command pending — the common case
                };
                if !data.is_empty() {
                    match serde_json::from_slice::<Value>(&data) {
                        Ok(cmd) => {
                            let t0 = Instant::now();
                            apply(&engine, &cmd);
                            write_dump(&engine); // every op refreshes the dump (spec)
                            last_dump = Instant::now();
                            // A dump that takes longer than the orchestrator's poll interval makes
                            // this leg look slow-or-dead no matter how healthy the engine is, and it
                            // is invisible without a number.
                            let ms = t0.elapsed().as_millis();
                            if ms > 2_000 {
                                log::warn!("qa-cmd: op '{}' + dump took {ms} ms — slower than the orchestrator polls",
                                           field(&cmd, "op"));
                            }
                        }
                        Err(e) => log::warn!("qa-cmd: invalid JSON ({} B): {e}", data.len()),
                    }
                    continue;
                }
                // HEARTBEAT. The dump must never be able to freeze just because a command went
                // missing — and commands DO go missing: the orchestrator's writeFileSync truncates
                // before it writes, so a read landing in that window returns an empty file which is
                // then consumed and dropped. Previously that silently skipped the refresh. Refreshing
                // on a timer decouples the orchestrator's view of this leg from command delivery
                // entirely, so a lost command costs one interval instead of the whole step.
                if last_dump.elapsed() >= Duration::from_secs(5) {
                    write_dump(&engine);
                    last_dump = Instant::now();
                }
            }
        })
        .expect("spawn qa-driver thread");
}

/// String field accessor: absent / non-string / empty all read as "".
fn field(cmd: &Value, key: &str) -> String {
    cmd.get(key).and_then(Value::as_str).unwrap_or("").trim().to_string()
}

/// The circle a content op (post/story/file/music_post) authors into: an explicit KNOWN
/// `circle_id` wins; missing or unknown keeps current behavior — the default circle, desktop's
/// stand-in for the UI's "active" circle (iOS/Android fall back to their real active circle).
fn content_circle(engine: &Arc<Engine>, cmd: &Value) -> String {
    let cid = field(cmd, "circle_id");
    if cid.is_empty() || cid == DEFAULT_CIRCLE {
        return DEFAULT_CIRCLE.to_string();
    }
    if engine.feed_circles().iter().any(|c| c.id == cid) {
        cid
    } else {
        log::warn!("qa-cmd: unknown circle_id {} — authoring into the default circle", &cid[..cid.len().min(24)]);
        DEFAULT_CIRCLE.to_string()
    }
}

/// Execute one v2 op through the engine (the same methods `commands.rs` routes UI clicks to).
fn apply(engine: &Arc<Engine>, cmd: &Value) {
    let op = field(cmd, "op");
    match op.as_str() {
        // QA: force the link constraint so the satellite path can be exercised without a satellite.
        // Desktop has no path monitor at all (docs/PREVIEW-TIER-DESIGN.md §2), so this is also the
        // only way to put it into the Low/Ultra profiles from a test.
        // QA: approve every pending connection request. Same reason as the mobile drivers — an
        // automated fleet cannot depend on somebody clicking Approve, and without this the desktop
        // leg stalls on an un-approvable request from the stub.
        "approve_connections" => {
            for req in engine.pending() {
                engine.approve(req.id_hex.clone());
            }
        }
        "link_constraint" => {
            let level = cmd.get("level").and_then(|v| v.as_str()).unwrap_or("normal");
            engine.set_low_data_level(match level {
                "ultra" => "ultra",
                "low" => "low",
                _ => "normal",
            });
        }
        "post" => {
            let circle = content_circle(engine, cmd);
            let refs = stage_media(engine, &circle, cmd);
            engine.post(circle, field(cmd, "body"), refs, None, false, None);
        }
        "story" => {
            // UI stories live in the default circle; an explicit circle_id overrides (spec).
            let circle = content_circle(engine, cmd);
            let caption = {
                let c = field(cmd, "caption");
                if c.is_empty() { field(cmd, "body") } else { c }
            };
            let refs = stage_media(engine, &circle, cmd);
            engine.post_story(circle, caption, refs.into_iter().next(), None);
        }
        "dm" => {
            let to = field(cmd, "dm_to").to_lowercase();
            if to.len() != 64 {
                log::warn!("qa-cmd dm: dm_to is not a 64-hex account id");
                return;
            }
            let name = engine
                .contacts()
                .into_iter()
                .find(|c| c.id_hex.eq_ignore_ascii_case(&to))
                .map(|c| c.name)
                .unwrap_or_else(|| "Friend".into());
            let cid = engine.start_dm(to, name);
            let refs = stage_media(engine, &cid, cmd);
            engine.send_dm(cid, field(cmd, "body"), refs, None, None);
        }
        "react" => {
            let target = field(cmd, "target_id");
            let emoji = {
                let e = field(cmd, "emoji");
                if e.is_empty() { "❤️".to_string() } else { e }
            };
            match find_circle_of(engine, &target) {
                Some(cid) => engine.react(cid, target, emoji),
                None => log::warn!("qa-cmd react: no circle holds target {}", &target[..target.len().min(12)]),
            }
        }
        "comment" => {
            let target = field(cmd, "target_id");
            match find_circle_of(engine, &target) {
                Some(cid) => engine.comment(cid, target, field(cmd, "body")),
                None => log::warn!("qa-cmd comment: no circle holds target {}", &target[..target.len().min(12)]),
            }
        }
        "profile" => {
            let mut p = engine.get_profile();
            let name = field(cmd, "name");
            if !name.is_empty() {
                p.name = name;
            }
            engine.set_profile(p);
        }
        "circle_create" => {
            engine.create_circle(field(cmd, "name"));
        }
        "circle_invite" => {
            // No default-circle fallback here: silently inviting into `default` would leak the
            // personal circle, so a missing circle_id is a refused op, not a guess.
            let cid = field(cmd, "circle_id");
            let to = field(cmd, "dm_to").to_lowercase();
            if cid.is_empty() || to.len() != 64 {
                log::warn!("qa-cmd circle_invite: needs circle_id + 64-hex dm_to");
                return;
            }
            engine.add_to_circle(cid, to);
        }
        "file" => {
            let circle = content_circle(engine, cmd);
            let path = field(cmd, "file_path");
            match std::fs::read(&path) {
                Ok(bytes) => {
                    let r = engine.add_local_file(&circle, &bytes);
                    engine.post(circle, field(cmd, "body"), vec![r], None, false, None);
                }
                Err(e) => log::warn!("qa-cmd file: {path}: {e}"),
            }
        }
        "music_post" => {
            let m = cmd.get("music").cloned().unwrap_or(Value::Null);
            let g = |k: &str| m.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            let track = TrackRefFfi {
                catalog_id: {
                    let c = g("catalog_id");
                    if c.is_empty() { "qa".to_string() } else { c }
                },
                title: g("title"),
                artist: g("artist"),
                artwork_url: g("artwork_url"),
                duration_ms: m.get("duration_ms").and_then(Value::as_u64).unwrap_or(0),
            };
            engine.post(content_circle(engine, cmd), field(cmd, "body"), vec![], Some(track), false, None);
        }
        "mark_read" => {
            let cid = field(cmd, "circle_id");
            if cid.is_empty() {
                for (cid, ..) in engine.dm_threads() {
                    engine.mark_dm_read(cid);
                }
                engine.mark_activity_seen();
            } else {
                engine.mark_dm_read(cid);
            }
        }
        "dump" => {} // the refresh after `apply` is the whole op
        other => {
            log::warn!("qa-cmd: unknown op {other:?}");
            return; // not a user action — leave the sync cadence untouched
        }
    }
    // Every recognized op models a user actively using the app; `dump` is the one non-mutating
    // op — it marks activity but must NOT force a poll (see `Engine::qa_mark_user_active`).
    engine.qa_mark_user_active(op != "dump");
}

/// Stage the cmd's photo/video attachments (absolute paths, staged into the data dir by the
/// harness) into the sealed local store via the SAME file→file seal the drop path uses; returns
/// the refs to post. `media:"photo"` with no path falls back to the built-in PNG; synthetic video
/// is not supported here (no encoder) — pass `video_path`.
fn stage_media(engine: &Arc<Engine>, circle_id: &str, cmd: &Value) -> Vec<String> {
    let kind = field(cmd, "media").to_lowercase();
    let photo = field(cmd, "photo_path");
    let video = field(cmd, "video_path");
    let mut refs = Vec::new();
    if !photo.is_empty() {
        match engine.add_local_media_file(circle_id, &photo, false) {
            Some(r) => refs.push(r),
            None => log::warn!("qa-cmd: photo_path stage failed: {photo}"),
        }
    } else if kind == "photo" {
        refs.push(engine.add_local_media(circle_id, QA_PNG, false));
    }
    if !video.is_empty() {
        match engine.add_local_media_file(circle_id, &video, true) {
            Some(r) => refs.push(r),
            None => log::warn!("qa-cmd: video_path stage failed: {video}"),
        }
    } else if kind == "video" {
        log::warn!("qa-cmd: synthetic video unsupported on desktop — stage a video_path");
    }
    refs
}

/// Which circle holds event `target` — v2 cmds carry only the event id, while the engine's
/// react/comment need the circle. Posts first (the common case), then DM threads.
fn find_circle_of(engine: &Arc<Engine>, target: &str) -> Option<String> {
    if target.is_empty() {
        return None;
    }
    for c in engine.feed_circles() {
        if engine.feed(&c.id).iter().any(|i| i.id == target) {
            return Some(c.id);
        }
    }
    for (cid, ..) in engine.dm_threads() {
        if engine.messages(&cid).iter().any(|i| i.id == target) {
            return Some(cid);
        }
    }
    None
}

/// The other account in a 1:1 `dm:<a>-<b>` id; group DMs key by the whole circle id (the
/// orchestrator flattens the map, so any stable key works there).
fn dm_peer(circle_id: &str, me: &str) -> String {
    let parts: Vec<&str> = circle_id.trim_start_matches("dm:").split('-').collect();
    if parts.len() == 2 {
        if let Some(p) = parts.iter().find(|p| !p.eq_ignore_ascii_case(me)) {
            return (*p).to_string();
        }
    }
    circle_id.to_string()
}

/// Fetchable blobs only — `thumb:`/`poster:`-style synthetic markers aren't bytes and must not
/// be able to fail the orchestrator's media-blob gate (Android `realRefs` / Apple FeedView dump
/// parity: both reduce `media_refs` AND `media_present` to the real refs).
/// `preview:<content>:<companion>` / `thumb:` / `poster:` / `orig:` -> the companion ref it names.
fn parse_marker_companion(marker: &str) -> Option<String> {
    for scheme in ["preview:", "thumb:", "poster:", "orig:"] {
        if let Some(rest) = marker.strip_prefix(scheme) {
            let colon = rest.rfind(':')?;
            let companion = &rest[colon + 1..];
            if !companion.is_empty() {
                return Some(companion.to_string());
            }
        }
    }
    None
}

fn real_refs(media: &[String]) -> Vec<String> {
    media.iter().filter(|r| !crate::localmedia::LocalMedia::is_synthetic(r)).cloned().collect()
}

fn item_json(engine: &Arc<Engine>, circle_id: &str, it: &FeedItemFfi) -> Value {
    let mut reactions = serde_json::Map::new();
    for r in &it.reactions {
        reactions.insert(r.emoji.clone(), json!(r.count));
    }
    let real = real_refs(&it.media);
    json!({
        "id": it.id,
        "body": it.body,
        "circle": circle_id,
        "story": it.story,
        "caption": if it.story { Value::from(it.body.clone()) } else { Value::Null },
        "media_present": real.iter().map(|r| engine.media_present(r)).collect::<Vec<bool>>(),
        "media_refs": real,
        // Companion MARKERS and whether the blobs they name are here.
        //
        // real_refs() drops synthetic refs and a post never lists the bare companion ref, so without
        // these a preview is invisible to QA on this leg even when it has arrived — the satellite
        // assertions could not pass against desktop no matter what the product did. Apple parity
        // (FeedView qaWriteDump).
        "media_markers": it.media.iter()
            .filter(|r| crate::localmedia::LocalMedia::is_synthetic(r))
            .cloned().collect::<Vec<String>>(),
        "companions_present": it.media.iter().filter_map(|m| {
            let companion = parse_marker_companion(m)?;
            Some((companion.clone(), Value::from(engine.media_present(&companion))))
        }).collect::<serde_json::Map<String, Value>>(),
        "reactions": reactions,
        "comments": it.comments.iter().map(|c| json!({ "id": c.id, "body": c.body })).collect::<Vec<Value>>(),
    })
}

/// Refresh `<data-dir>/qa-dump.json`: every circle's posts (stories included — the tray filter is
/// a UI concern), every DM thread keyed by peer, profile + circles. Written atomically (tmp +
/// rename) so the orchestrator can never read half a dump.
fn write_dump(engine: &Arc<Engine>) {
    let root = engine.data_root();
    let me = engine.node_id_hex().to_lowercase();
    let mut posts = Vec::new();
    for c in engine.feed_circles() {
        for it in engine.feed(&c.id) {
            posts.push(item_json(engine, &c.id, &it));
        }
    }
    let mut dms = serde_json::Map::new();
    for (cid, ..) in engine.dm_threads() {
        let msgs: Vec<Value> = engine
            .messages(&cid)
            .iter()
            .map(|m| {
                // Same real-refs reduction as posts (Apple/Android dump parity).
                let real = real_refs(&m.media);
                json!({
                    "id": m.id,
                    "body": m.body,
                    "media_present": real.iter().map(|r| engine.media_present(r)).collect::<Vec<bool>>(),
                })
            })
            .collect();
        dms.insert(dm_peer(&cid, &me), Value::Array(msgs));
    }
    let circles: Vec<Value> = engine
        .feed_circles()
        .iter()
        .map(|c| json!({ "id": c.id, "name": c.name, "members": engine.circle_member_ids(&c.id) }))
        .collect();
    let dump = json!({
        "device": "desktop",
        "account_hex": me,
        "ts_ms": now_ms(),
        "posts": posts,
        "dms": dms,
        "profile": { "name": engine.get_profile().name },
        // null until the webview has reported — deliberately NOT a healthy-looking default.
        "call": match engine.qa_call_state() {
            Some((ringing, in_call)) => serde_json::json!({
                "ringing": ringing, "in_call": in_call,
                // WHICH session, and the last frame the engine handled ("recv:35" / "recv-unopenable:…"
                // / "none"). `in_call` alone cannot distinguish a leg that ignored a teardown from one
                // in a DIFFERENT session, or from one the frame never reached.
                "session": engine.qa_call_session(),
                "last_event": engine.qa_last_call_event(),
            }),
            None => serde_json::Value::Null,
        },
        "circles": circles,
        // What the engine is HOLDING BACK: parked (received-but-unopenable) envelopes per circle,
        // plus the rosters we know. A short feed alone cannot tell "never arrived" from "arrived and
        // could not be opened", and those have opposite fixes.
        "delivery": serde_json::from_str::<serde_json::Value>(&engine.diag_delivery_json())
            .unwrap_or(serde_json::Value::Null),
        // Liveness: strictly increasing while the driver is healthy. A stuck value means the file
        // is frozen, not that the fleet is quiet.
        "dump_seq": DUMP_WRITES.load(Ordering::Relaxed),
    });
    let tmp = root.join("qa-dump.json.tmp");
    // EVERY failure here is reported. All three steps used to be able to fail silently — a failed
    // `write` skipped the rename because it was wrapped in `if ... .is_ok()`, and the rename itself
    // was `let _ =`. The result was a dump file frozen at its last good write while the app went on
    // running perfectly: the orchestrator polls a stale file, every assertion against this leg reads
    // "never", and nothing anywhere says why. That cost a full QA run — desktop had the content
    // twelve minutes before the step it "failed" gave up.
    match serde_json::to_vec(&dump) {
        Ok(bytes) => {
            let n = bytes.len();
            if let Err(e) = std::fs::write(&tmp, bytes) {
                log::warn!("qa-dump: write of {n} B to {} failed: {e} — dump is now STALE", tmp.display());
                return;
            }
            if let Err(e) = std::fs::rename(&tmp, root.join("qa-dump.json")) {
                log::warn!("qa-dump: rename into place failed: {e} — dump is now STALE");
                return;
            }
            DUMP_WRITES.fetch_add(1, Ordering::Relaxed);
        }
        Err(e) => log::warn!("qa-dump: serialize failed: {e} — dump is now STALE"),
    }
}
