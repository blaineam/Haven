//! Tauri command surface — the bridge the WebView frontend calls via `invoke()`.
//!
//! Most commands need nothing but the engine and live in `haven_client::commands`, shared with the
//! browser build; the frontend reaches those through one Tauri command, [`engine_invoke`]. What is
//! left here needs this application: the window, the OS (autostart, files), the Instagram
//! importer, the music catalogue, onboarding/relaunch.

use std::sync::Arc;

use base64::Engine as _;
use tauri::State;

pub use haven_client::commands::*;

use crate::engine::Engine;

type TauriEng<'a> = State<'a, Arc<Engine>>;

/// Run a shared engine command by name (see `haven_client::commands::dispatch`). A name that is
/// not a shared command is reported as the fixed string `unknown-command`, which the frontend uses
/// to route it to this crate's own handler instead — including before any engine exists
/// (onboarding), when only host commands can be answered.
#[tauri::command]
pub async fn engine_invoke(app: tauri::AppHandle, name: String, args: serde_json::Value) -> R<serde_json::Value> {
    use tauri::Manager;
    if !NAMES.contains(&name.as_str()) {
        return Err("unknown-command".into());
    }
    let Some(engine) = app.try_state::<Arc<Engine>>().map(|s| s.inner().clone()) else {
        return Err("the engine is not running yet".into());
    };
    dispatch(Eng(&engine), &name, &args).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub fn self_test() -> serde_json::Value {
    let r = haven_ffi::self_test();
    serde_json::json!({
        "identity_ok": r.identity_ok,
        "hybrid_kem_ok": r.hybrid_kem_ok,
        "signature_ok": r.signature_ok,
        "link_ok": r.link_ok,
        "all_ok": r.all_ok,
        "node_id_hex": r.node_id_hex,
        "summary": r.summary,
    })
}

/// NEW DEVICE: adopt a scanned/pasted `haven-enroll:` ticket, register a seedless identity, and
/// relaunch into linking mode (the engine then handshakes with the primary). Legacy `haven-seed:` /
/// raw-seed codes still go through `onboard_link` — this is the new, seedless link path.
#[tauri::command]
pub fn onboard_link_seedless(app: tauri::AppHandle, ticket: String) -> R<()> {
    crate::engine::onboard_seedless(&ticket)?;
    app.restart();
}

/// NEW DEVICE: the grant landed (`haven:enrolled`) → relaunch so the engine rebuilds seedless-linked.
#[tauri::command]
pub fn finish_enroll(app: tauri::AppHandle) {
    app.restart();
}

/// Drain the `haven://` URLs the OS handed us. The FRONTEND routes them (app.js `routeDeepLink`), because
/// a post link and an invite link are different destinations and only one parser may decide which.
/// Draining is destructive so a link is never acted on twice — the frontend calls this both at boot and
/// on the `haven:deep-link` ping, and either may win.
#[tauri::command]
pub fn take_deep_links(links: tauri::State<'_, crate::DeepLinks>) -> Vec<String> {
    std::mem::take(&mut *links.0.lock())
}

/// Whether Haven launches at login + whether it auto-hosts the relay on launch.
#[tauri::command]
pub fn autostart_status(app: tauri::AppHandle, engine: TauriEng) -> AutostartDto {
    use tauri_plugin_autostart::ManagerExt;
    let login_item = app.autolaunch().is_enabled().unwrap_or(false);
    AutostartDto { login_item, host_on_launch: engine.host_on_launch() }
}

/// Enable/disable launch-on-login and the auto-host-relay-on-launch preference. Setting both =
/// the desktop client becomes an always-on relay that survives reboot.
#[tauri::command]
pub fn set_autostart(app: tauri::AppHandle, engine: TauriEng, login_item: bool, host_on_launch: bool) -> R<()> {
    use tauri_plugin_autostart::ManagerExt;
    let mgr = app.autolaunch();
    if login_item {
        mgr.enable().map_err(|e| e.to_string())?;
    } else {
        mgr.disable().map_err(|e| e.to_string())?;
    }
    engine.set_host_on_launch(host_on_launch);
    Ok(())
}

/// Read a file dropped onto the window back into the WebView as base64, so the drop path can run
/// through the SAME JS sanitize/downscale pipeline the file picker uses.
///
/// This replaces the old `add_media_path`, which sealed the dropped file straight from disk. That
/// was cheaper — file→file, never a Vec in this process — but it also meant a dropped photo or video
/// was posted BYTE-FOR-BYTE as it sat on disk: full resolution, and with its capture EXIF/GPS intact.
/// The picker path has stripped that since day one (canvas re-encode); drag-and-drop was the hole.
/// Correctness wins over the allocation: the WebView already base64s the picker's re-encoded output
/// across this same boundary, so the only new cost is holding the SOURCE in memory too — and
/// `max_bytes` (the caller's `MEDIA_TARGETS.MAX_SOURCE_BYTES_*`) bounds it. Enforced here, not just
/// in JS, so an oversize file is refused before it is ever read.
#[tauri::command]
pub fn read_media_file_b64(path: String, max_bytes: u64) -> R<serde_json::Value> {
    let p = std::path::Path::new(&path);
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let is_video = DROP_VIDEO_EXTS.contains(&ext.as_str());
    if !is_video && !DROP_IMAGE_EXTS.contains(&ext.as_str()) {
        return Err(format!("not a media file: {path}"));
    }
    let len = std::fs::metadata(p).map_err(|e| format!("{path}: {e}"))?.len();
    if len > max_bytes {
        return Err(format!("too large: {len} bytes"));
    }
    let bytes = std::fs::read(p).map_err(|e| format!("{path}: {e}"))?;
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("dropped").to_string();
    Ok(serde_json::json!({
        "name": name,
        "is_video": is_video,
        "data_base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
    }))
}

/// True on a truly fresh install (empty roster + no legacy seed) — the frontend shows the
/// welcome screen instead of the app. Takes no engine, so it works before one exists.
#[tauri::command]
pub fn needs_onboarding() -> R<bool> {
    // Demo mode is never fresh: it seeds its own identity into its OWN data dir, so asking the REAL
    // store whether it's empty answers the wrong question. On a machine that happens to have a real
    // identity this looked fine — the check returned false and the demo feed appeared. On a CLEAN
    // machine (a fresh VM, a CI runner, anywhere screenshots get generated) it returned true and the
    // seeded dataset was hidden behind onboarding. Caught on a first-run Linux VM.
    #[cfg(debug_assertions)]
    if crate::demo::is_demo() {
        return Ok(false);
    }
    let base = crate::store::Paths::resolve().map_err(|e| e.to_string())?;
    let fresh = crate::store::Identities::load(&base).is_empty()
        && crate::store::load_seed().map_err(|e| e.to_string())?.is_none();
    Ok(fresh)
}

/// True when this run is the demo/screenshot capture. Always false in release, where the module that
/// reads the env var doesn't exist — so the frontend can gate capture-only behaviour on it safely.
#[tauri::command]
pub fn demo_mode() -> bool {
    #[cfg(debug_assertions)]
    {
        crate::demo::is_demo()
    }
    #[cfg(not(debug_assertions))]
    {
        false
    }
}

/// "Create my Haven" — mint a brand-new identity, then relaunch into it.
#[tauri::command]
pub fn onboard_create(app: tauri::AppHandle) -> R<()> {
    let acct = haven_ffi::Account::generate();
    let seed: [u8; 32] = acct
        .secret_seed()
        .try_into()
        .map_err(|_| "generated seed is not 32 bytes".to_string())?;
    save_first_identity(seed)?;
    app.restart();
}

/// "Link an existing identity" — adopt a transfer code/seed from another device, then relaunch.
#[tauri::command]
pub fn onboard_link(app: tauri::AppHandle, code: String) -> R<()> {
    let seed = decode_seed(&code)?;
    save_first_identity(seed)?;
    app.restart();
}

/// Switch the active identity and relaunch so the engine rebuilds on the new seed + data dir.
#[tauri::command]
pub fn switch_identity(app: tauri::AppHandle, engine: TauriEng, node_hex: String) -> R<()> {
    engine.set_active_identity(&node_hex).map_err(|e| e.to_string())?;
    app.restart();
}

/// Parse a picked `.zip` for the preview. Result arrives on `haven:import` (phase `previewing`, or
/// `failed` with the message to show).
#[tauri::command]
pub fn instagram_read(engine: TauriEng, path: String) {
    crate::igimport::read(engine.inner().clone(), path);
}

/// The whole importer state, for a view that mounts mid-import (or after a relaunch resumed one).
#[tauri::command]
pub fn instagram_status() -> serde_json::Value {
    crate::igimport::status()
}

/// Start importing the previewed archive into `circle_id`. `include_stories` is OFF by default and
/// that default is load-bearing — see the note in `igimport::run`.
#[tauri::command]
pub fn instagram_run(
    engine: TauriEng,
    circle_id: String,
    include_stories: Option<bool>,
    match_songs: Option<bool>,
) {
    crate::igimport::run(
        engine.inner().clone(),
        circle_id,
        include_stories.unwrap_or(false),
        match_songs.unwrap_or(false),
        0,
    );
}

/// Free-text song search (iTunes Search API — no key, no account, same source Android uses).
#[tauri::command]
pub async fn music_search(query: String, limit: Option<usize>) -> Vec<SongDto> {
    let hits = crate::songsuggest::search(&query, limit.unwrap_or(25)).await.unwrap_or_default();
    hits.into_iter()
        .filter(crate::songsuggest::is_suitable)
        .map(|t| SongDto {
            catalog_id: t.catalog_id(),
            title: t.title.clone(),
            artist: t.artist.clone(),
            artwork_url: t.artwork_url.clone(),
            duration_ms: t.duration_ms,
            preview_url: t.preview_url,
        })
        .collect()
}

/// The 30-second clip for a song a POST already carries.
///
/// A TrackRef stores catalog id, title, artist and artwork — never a preview URL, because nothing
/// about a preview belongs on a post. The feed still has to be able to PLAY the attached song, so it
/// looks one up by name, exactly as Android's `MusicSearch.resolve` does.
#[tauri::command]
pub async fn music_resolve(title: String, artist: String, catalog_id: Option<String>) -> Option<SongDto> {
    // BY ID FIRST, when the ref carries one. A TrackRef's catalog id IS the store URL, and every
    // iTunes URL ends in `/id<digits>` (or carries `?i=<digits>` for a track inside an album). A
    // text search for "New Beginnings Shah Feryan" can simply miss — obscure titles are exactly
    // where it fails, and a missed lookup means the story plays nothing at all.
    if let Some(id) = catalog_id.as_deref().and_then(itunes_track_id) {
        if let Some(hit) = crate::songsuggest::lookup(&id).await {
            return Some(SongDto {
                catalog_id: hit.catalog_id(),
                title: hit.title.clone(),
                artist: hit.artist.clone(),
                artwork_url: hit.artwork_url.clone(),
                duration_ms: hit.duration_ms,
                preview_url: hit.preview_url,
            });
        }
    }
    let q = format!("{title} {artist}");
    let hit = crate::songsuggest::search(q.trim(), 1).await.unwrap_or_default().into_iter().next()?;
    Some(SongDto {
        catalog_id: hit.catalog_id(),
        title: hit.title.clone(),
        artist: hit.artist.clone(),
        artwork_url: hit.artwork_url.clone(),
        duration_ms: hit.duration_ms,
        preview_url: hit.preview_url,
    })
}

/// Songs for what the post is ABOUT — its caption and when it was taken. The same suggester the
/// importer scores hundreds of silent posts with, offered to the composer as a tab.
#[tauri::command]
pub async fn music_suggestions(
    caption: String,
    genre: Option<String>,
    created_at_ms: Option<u64>,
    limit: Option<usize>,
) -> Vec<SongDto> {
    let themes = crate::songsuggest::caption_themes(&caption, 2);
    let (year, month) = crate::songsuggest::year_month(
        created_at_ms.unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0)
        }),
    );
    let picked = crate::songsuggest::suggestions(
        &themes,
        genre.as_deref(),
        year,
        month,
        &std::collections::HashSet::new(),
        limit.unwrap_or(12),
    )
    .await;
    picked
        .into_iter()
        .map(|t| SongDto {
            catalog_id: t.catalog_id,
            title: t.title,
            artist: t.artist,
            artwork_url: t.artwork_url,
            duration_ms: t.duration_ms,
            preview_url: t.preview_url,
        })
        .collect()
}

/// Let the frontend write to the app log. Debug-level questions about what the DOM actually did
/// ("which render path did this post take?") are otherwise invisible from outside the webview.
#[tauri::command]
pub fn ui_log(line: String) {
    log::info!("ui: {line}");
}

/// The frontend answering an `haven:ig-encode` request (see `igencode`).
///
/// `refs` absent or null means "could not" — the import seals the raw archive bytes instead, which
/// is what it did before the WebView was ever asked. Never an error path: a frontend that is busy,
/// closed, or refused the file must degrade the import, not fail it.
#[tauri::command]
pub fn instagram_encoded(job: u64, refs: Option<Vec<String>>) {
    crate::igencode::fulfill(job, refs);
}

/// Stop — really "pause". The checkpoint is KEPT, so reopening the importer carries on from here.
#[tauri::command]
pub fn instagram_cancel() {
    crate::igimport::cancel();
}

/// Carry on from a Stop, without waiting for a relaunch to notice the checkpoint.
#[tauri::command]
pub fn instagram_resume(engine: TauriEng) {
    crate::igimport::resume_now(engine.inner().clone());
}

/// Forget the previewed/finished archive. A no-op while a run is in flight.
#[tauri::command]
pub fn instagram_reset(engine: TauriEng) {
    crate::igimport::reset(&engine);
}

#[cfg(test)]
#[path = "tests_commands.rs"]
mod cov_command_tests;
