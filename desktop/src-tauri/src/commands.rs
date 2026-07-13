//! Tauri command surface — the bridge the WebView2 frontend calls via `invoke()`. Each
//! command maps the shared engine's FFI records into JSON-friendly DTOs.

use std::sync::Arc;

use base64::Engine as _;
use haven_ffi::{FeedItemFfi, TrackRefFfi};
use serde::{Deserialize, Serialize};
use tauri::State;

use crate::engine::{Engine, DEFAULT_CIRCLE};
use crate::store::Profile;

type Eng<'a> = State<'a, Arc<Engine>>;
type R<T> = Result<T, String>;

#[derive(Serialize)]
pub struct ReactionDto {
    pub emoji: String,
    pub count: u32,
    pub mine: bool,
    pub authors: Vec<String>,
}

#[derive(Serialize)]
pub struct TrackDto {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub duration_ms: u64,
}

#[derive(Serialize)]
pub struct CommentDto {
    pub id: String,
    pub author_short: String,
    pub author_name: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
    pub reactions: Vec<ReactionDto>,
}

#[derive(Serialize)]
pub struct FeedItemDto {
    pub id: String,
    pub author_short: String,
    pub author_name: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub music: Option<TrackDto>,
    pub edited: bool,
    pub unsent: bool,
    pub story: bool,
    pub mute_video: bool,
    pub comments: Vec<CommentDto>,
    pub reactions: Vec<ReactionDto>,
}

#[derive(Serialize)]
pub struct CircleDto {
    pub id: String,
    pub name: String,
    pub member_count: u32,
}

#[derive(Serialize)]
pub struct ContactDto {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
}

#[derive(Serialize)]
pub struct PendingDto {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
}

#[derive(Serialize)]
pub struct BootstrapDto {
    pub node_id_hex: String,
    pub invite_uri: String,
    pub invite_link: String,
    pub profile: Profile,
    pub started: bool,
}

#[derive(Serialize)]
pub struct RelayStatusDto {
    pub hosting: bool,
    pub has_relay: bool,
    pub relay_active: bool,
    pub internet_active: bool,
    pub started: bool,
    pub relay_link: Option<String>,
}

#[derive(Serialize)]
pub struct DmThreadDto {
    pub circle_id: String,
    pub name: String,
    pub last_body: String,
    pub last_at: u64,
    /// Total members (me + others). > 2 ⇒ a group DM (UI shows sender names on incoming messages).
    pub member_count: u32,
    /// Inbound messages newer than this thread's read watermark (the row/pin badge count).
    pub unread: u32,
}

#[derive(Deserialize)]
pub struct TrackInput {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub artwork_url: String,
    #[serde(default)]
    pub duration_ms: u64,
}

impl TrackInput {
    fn into_ffi(self) -> TrackRefFfi {
        TrackRefFfi {
            catalog_id: self.catalog_id,
            title: self.title,
            artist: self.artist,
            artwork_url: self.artwork_url,
            duration_ms: self.duration_ms,
        }
    }
}

fn track_dto(t: TrackRefFfi) -> TrackDto {
    TrackDto {
        catalog_id: t.catalog_id,
        title: t.title,
        artist: t.artist,
        artwork_url: t.artwork_url,
        duration_ms: t.duration_ms,
    }
}

fn reaction_dto(r: haven_ffi::ReactionFfi) -> ReactionDto {
    ReactionDto { emoji: r.emoji, count: r.count, mine: r.mine, authors: r.authors }
}

fn feed_item_dto(engine: &Engine, it: FeedItemFfi) -> FeedItemDto {
    FeedItemDto {
        author_name: if it.is_me { "You".to_string() } else { engine.display_name(&it.author_short) },
        id: it.id,
        author_short: it.author_short,
        is_me: it.is_me,
        created_at: it.created_at,
        body: it.body,
        media: it.media,
        music: it.music.map(track_dto),
        edited: it.edited,
        unsent: it.unsent,
        story: it.story,
        mute_video: it.mute_video,
        comments: it
            .comments
            .into_iter()
            .map(|c| CommentDto {
                author_name: if c.is_me { "You".to_string() } else { engine.display_name(&c.author_short) },
                id: c.id,
                author_short: c.author_short,
                is_me: c.is_me,
                created_at: c.created_at,
                body: c.body,
                media: c.media,
                edited: c.edited,
                unsent: c.unsent,
                reactions: c.reactions.into_iter().map(reaction_dto).collect(),
            })
            .collect(),
        reactions: it.reactions.into_iter().map(reaction_dto).collect(),
    }
}

// ---- identity / lifecycle ----------------------------------------------------------------

#[tauri::command]
pub fn bootstrap(engine: Eng) -> BootstrapDto {
    BootstrapDto {
        node_id_hex: engine.node_id_hex(),
        invite_uri: engine.invite_uri(),
        invite_link: engine.invite_link("haven.is"),
        profile: engine.get_profile(),
        started: engine.started(),
    }
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

#[tauri::command]
pub fn get_profile(engine: Eng) -> Profile {
    engine.get_profile()
}

#[tauri::command]
pub fn set_profile(engine: Eng, name: String, bio: String, link: String, emoji: String, avatar: String) {
    engine.set_profile(Profile { name, bio, link, emoji, avatar });
}

// ---- circles -----------------------------------------------------------------------------

#[tauri::command]
pub fn circles(engine: Eng) -> Vec<CircleDto> {
    engine
        .feed_circles()
        .into_iter()
        .map(|c| CircleDto { id: c.id, name: c.name, member_count: c.member_count })
        .collect()
}

#[tauri::command]
pub fn create_circle(engine: Eng, name: String) -> String {
    engine.create_circle(name)
}

#[tauri::command]
pub fn rename_circle(engine: Eng, id: String, name: String) {
    engine.rename_circle(id, name);
}

#[tauri::command]
pub fn leave_circle(engine: Eng, id: String) {
    engine.leave_circle(id);
}

#[tauri::command]
pub fn add_to_circle(engine: Eng, circle_id: String, contact_id_hex: String) {
    engine.add_to_circle(circle_id, contact_id_hex);
}

#[tauri::command]
pub fn remove_from_circle(engine: Eng, circle_id: String, contact_id_hex: String) {
    engine.remove_from_circle(circle_id, contact_id_hex);
}

// ---- feed / authoring --------------------------------------------------------------------

#[tauri::command]
pub fn feed(engine: Eng, circle_id: String) -> Vec<FeedItemDto> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    engine.feed(&cid).into_iter().map(|it| feed_item_dto(&engine, it)).collect()
}

#[tauri::command]
pub fn post(engine: Eng, circle_id: String, body: String, media: Vec<String>, music: Option<TrackInput>, mute_video: Option<bool>) {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    engine.post(cid, body, media, music.map(|m| m.into_ffi()), mute_video.unwrap_or(false));
}

#[tauri::command]
pub fn post_story(engine: Eng, body: String, media: Option<String>, music: Option<TrackInput>) {
    engine.post_story(body, media, music.map(|m| m.into_ffi()));
}

#[tauri::command]
pub fn comment(engine: Eng, circle_id: String, target: String, body: String) {
    engine.comment(circle_id, target, body);
}

#[tauri::command]
pub fn react(engine: Eng, circle_id: String, target: String, emoji: String) {
    engine.react(circle_id, target, emoji);
}

#[tauri::command]
pub fn unreact(engine: Eng, circle_id: String, target: String, emoji: String) {
    engine.unreact(circle_id, target, emoji);
}

#[tauri::command]
pub fn edit_post(engine: Eng, circle_id: String, target: String, body: String) {
    engine.edit_post(circle_id, target, body);
}

#[tauri::command]
pub fn unsend_post(engine: Eng, circle_id: String, target: String) {
    engine.unsend_post(circle_id, target);
}

// ---- reports (decentralized moderation) ----------------------------------------------------

#[derive(Serialize)]
pub struct ReportDto {
    pub id: String,
    /// Who filed it — full node hex + resolved display name for the banner.
    pub reporter: String,
    pub reporter_name: String,
    /// The reported event id.
    pub target: String,
    /// The reported event's author — FULL node hex, usable directly for block/remove.
    pub author: String,
    pub reason: String,
    pub comment: String,
    pub created_at: u64,
}

/// File a report: seals it to the whole circle, appends a content-free ledger entry, and returns
/// the reported author's FULL node hex so the UI can offer block-in-the-same-motion.
#[tauri::command]
pub fn report(engine: Eng, circle_id: String, target: String, reason: String, comment: String) -> Option<String> {
    engine.report(circle_id, target, reason, comment)
}

/// Every report filed in the circle by ANY member — the circle's shared moderation signal.
#[tauri::command]
pub fn reports(engine: Eng, circle_id: String) -> Vec<ReportDto> {
    engine
        .reports(&circle_id)
        .into_iter()
        .map(|r| ReportDto {
            reporter_name: engine.display_name(&r.reporter_short),
            id: r.id,
            reporter: r.reporter,
            target: r.target,
            author: r.author,
            reason: r.reason,
            comment: r.comment,
            created_at: r.created_at,
        })
        .collect()
}

// ---- DMs ---------------------------------------------------------------------------------

#[tauri::command]
pub fn dm_threads(engine: Eng) -> Vec<DmThreadDto> {
    engine
        .dm_threads()
        .into_iter()
        .map(|(circle_id, name, last_body, last_at, member_count, unread)| DmThreadDto {
            circle_id,
            name,
            last_body,
            last_at,
            member_count,
            unread,
        })
        .collect()
}

/// The user is viewing a DM thread — advance its read watermark (clears its badge here and, via
/// self-sync, on the user's other devices).
#[tauri::command]
pub fn mark_dm_read(engine: Eng, circle_id: String) {
    engine.mark_dm_read(circle_id);
}

/// Delete a whole DM conversation locally (records a "cleared before" watermark so re-syncing this
/// deterministic-id DM won't restore old messages, then leaves the circle).
#[tauri::command]
pub fn delete_conversation(engine: Eng, circle_id: String) {
    engine.delete_conversation(circle_id);
}

#[tauri::command]
pub fn start_dm(engine: Eng, contact_id_hex: String, contact_name: String) -> String {
    engine.start_dm(contact_id_hex, contact_name)
}

/// Start a GROUP DM. `members` is a list of `[id_hex, name]` pairs (2+).
#[tauri::command]
pub fn start_group_dm(engine: Eng, members: Vec<(String, String)>) -> String {
    engine.start_group_dm(members)
}

/// Composer reachability light: "synced" | "local".
#[tauri::command]
pub fn sync_status(engine: Eng, circle_id: String) -> String {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    engine.sync_status(&cid)
}

/// Global "play video sound" toggle (videos start muted otherwise).
#[tauri::command]
pub fn video_sound_on(engine: Eng) -> bool {
    engine.video_sound_on()
}

#[tauri::command]
pub fn set_video_sound(engine: Eng, on: bool) {
    engine.set_video_sound(on);
}

// ---- multi-device roster ----------------------------------------------------------------

#[derive(serde::Serialize)]
pub struct DeviceRosterDto {
    pub enabled: bool,
    pub this_device_authorized: bool,
    pub devices: Vec<crate::roster::RosterDeviceDto>,
}

#[tauri::command]
pub fn device_roster(engine: Eng) -> DeviceRosterDto {
    let (enabled, this_device_authorized, devices) = engine.device_roster_dto();
    DeviceRosterDto { enabled, this_device_authorized, devices }
}

#[tauri::command]
pub fn enable_device_roster(engine: Eng) {
    engine.enable_device_roster();
}

#[tauri::command]
pub fn request_device_enrollment(engine: Eng) {
    engine.request_device_enrollment();
}

#[tauri::command]
pub fn revoke_device(engine: Eng, node_hex: String) {
    engine.revoke_device(node_hex);
}

#[tauri::command]
pub fn step_down_as_primary(engine: Eng) {
    engine.step_down_as_primary();
}

#[tauri::command]
pub fn messages(engine: Eng, circle_id: String) -> Vec<FeedItemDto> {
    engine.messages(&circle_id).into_iter().map(|it| feed_item_dto(&engine, it)).collect()
}

#[tauri::command]
pub fn send_dm(engine: Eng, circle_id: String, body: String, media: Vec<String>) {
    engine.send_dm(circle_id, body, media);
}

// ---- connect / contacts ------------------------------------------------------------------

#[tauri::command]
pub fn connect_by_link(engine: Eng, uri: String) -> bool {
    engine.connect_by_link(uri)
}

#[tauri::command]
pub fn pending(engine: Eng) -> Vec<PendingDto> {
    engine
        .pending()
        .into_iter()
        .map(|p| PendingDto { id_hex: p.id_hex, name: p.name, verify_hex: p.verify_hex })
        .collect()
}

#[tauri::command]
pub fn approve(engine: Eng, id_hex: String) {
    engine.approve(id_hex);
}

#[tauri::command]
pub fn dismiss(engine: Eng, id_hex: String) {
    engine.dismiss(id_hex);
}

#[tauri::command]
pub fn contacts(engine: Eng) -> Vec<ContactDto> {
    engine
        .contacts()
        .into_iter()
        .map(|c| ContactDto { id_hex: c.id_hex, name: c.name, verify_hex: c.verify_hex })
        .collect()
}

#[tauri::command]
pub fn blocked(engine: Eng) -> Vec<String> {
    engine.blocked()
}

#[tauri::command]
pub fn block(engine: Eng, id_hex: String) {
    engine.block(id_hex);
}

#[tauri::command]
pub fn unblock(engine: Eng, id_hex: String) {
    engine.unblock(id_hex);
}

// ---- relay / mailbox ---------------------------------------------------------------------

#[tauri::command]
pub fn relay_status(engine: Eng) -> RelayStatusDto {
    let (hosting, has_relay, relay_active, internet_active, started) = engine.relay_status();
    RelayStatusDto { hosting, has_relay, relay_active, internet_active, started, relay_link: engine.relay_link() }
}

#[tauri::command]
pub async fn start_hosting(engine: Eng<'_>) -> R<String> {
    engine.start_hosting().await.map_err(|e| e.to_string())
}

#[tauri::command]
pub fn stop_hosting(engine: Eng) {
    engine.stop_hosting();
}

#[derive(Serialize)]
pub struct AutostartDto {
    pub login_item: bool,
    pub host_on_launch: bool,
}

/// Whether Haven launches at login + whether it auto-hosts the relay on launch.
#[tauri::command]
pub fn autostart_status(app: tauri::AppHandle, engine: Eng) -> AutostartDto {
    use tauri_plugin_autostart::ManagerExt;
    let login_item = app.autolaunch().is_enabled().unwrap_or(false);
    AutostartDto { login_item, host_on_launch: engine.host_on_launch() }
}

/// Enable/disable launch-on-login and the auto-host-relay-on-launch preference. Setting both =
/// the desktop client becomes an always-on relay that survives reboot.
#[tauri::command]
pub fn set_autostart(app: tauri::AppHandle, engine: Eng, login_item: bool, host_on_launch: bool) -> R<()> {
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

#[tauri::command]
pub async fn adopt_relay(engine: Eng<'_>, node_hex: String) -> R<()> {
    engine.adopt_relay(node_hex).await;
    Ok(())
}

#[derive(Serialize)]
pub struct RelayDto {
    pub node_hex: String,
    pub name: String,
    pub active: bool,
    pub is_s3: bool,
    pub is_default: bool,
    pub reachable: bool,
    pub hosted: bool,
}

/// Every configured relay (active + inactive) with its metadata + reachability — for the Relays hub.
#[tauri::command]
pub fn relays(engine: Eng) -> Vec<RelayDto> {
    engine
        .relays_detail()
        .into_iter()
        .map(|d| RelayDto {
            node_hex: d.node_hex,
            name: d.name,
            active: d.active,
            is_s3: d.is_s3,
            is_default: d.is_default,
            reachable: d.reachable,
            hosted: d.hosted,
        })
        .collect()
}

/// DEACTIVATE a relay (config survives) — the user-facing "remove". Mirrors iOS `forget`.
#[tauri::command]
pub async fn forget_relay(engine: Eng<'_>, node_hex: String) -> R<()> {
    engine.forget_relay(node_hex).await;
    Ok(())
}

/// Reactivate a deactivated relay.
#[tauri::command]
pub async fn reactivate_relay(engine: Eng<'_>, node_hex: String) -> R<()> {
    engine.reactivate_relay(node_hex).await;
    Ok(())
}

/// Rename a relay (user-facing label only).
#[tauri::command]
pub fn rename_relay(engine: Eng, node_hex: String, name: String) {
    engine.rename_relay(node_hex, name);
}

/// Set (or clear, with an empty string) the all-circles default relay.
#[tauri::command]
pub fn set_default_relay(engine: Eng, node_hex: String) {
    engine.set_default_relay(node_hex);
}

/// ERASE a relay for good ("Delete now"), removing its config + every association.
#[tauri::command]
pub async fn erase_relay(engine: Eng<'_>, node_hex: String) -> R<()> {
    engine.erase_relay(node_hex).await;
    Ok(())
}

/// Toggle a single relay's association with ONE circle (the per-circle override).
#[tauri::command]
pub async fn set_circle_relay(engine: Eng<'_>, node_hex: String, circle_id: String, on: bool) -> R<()> {
    engine.set_circle_relay(node_hex, circle_id, on).await;
    Ok(())
}

/// The relay hexes explicitly associated with a circle (INCLUDING inactive) — for the override toggles.
#[tauri::command]
pub fn circle_relays(engine: Eng, circle_id: String) -> Vec<String> {
    engine.circle_relay_hexes(&circle_id)
}

/// Add an S3 bucket as a store-and-forward relay (secret → keychain). Returns its synthetic `s3:` id.
#[tauri::command]
pub async fn add_s3_relay(
    engine: Eng<'_>,
    endpoint: String,
    region: String,
    bucket: String,
    access_key: String,
    secret_key: String,
    prefix: String,
    name: String,
    set_default: bool,
) -> R<String> {
    let pub_cfg = crate::store::S3Public { endpoint, region, bucket, access_key, prefix };
    engine.add_s3_relay(pub_cfg, secret_key, name, set_default).await.map_err(|e| e.to_string())
}

// ---- media -------------------------------------------------------------------------------

#[tauri::command]
pub fn add_media(engine: Eng, circle_id: String, data_base64: String, is_video: bool) -> R<String> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_base64.trim())
        .map_err(|e| format!("bad base64: {e}"))?;
    Ok(engine.add_local_media(&cid, &bytes, is_video))
}

/// Stage a media file dropped onto the window. Tauri's drag-drop event hands us a filesystem path
/// (not bytes), so read it here, detect video by extension, and return the stored ref.
#[tauri::command]
pub fn add_media_path(engine: Eng, circle_id: String, path: String) -> R<String> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    let ext = std::path::Path::new(&path)
        .extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let is_video = matches!(ext.as_str(), "mp4" | "mov" | "m4v" | "webm" | "avi" | "mkv" | "3gp");
    // Seal the file straight to the at-rest store (off-heap file→file) — a large dropped video is
    // never loaded into a Vec here, avoiding a plaintext + sealed double-allocation in this process.
    engine
        .add_local_media_file(&cid, &path, is_video)
        .ok_or_else(|| format!("seal/store failed: {path}"))
}

/// Store a recorded voice note (sealed, content-addressed) and return an `a:` ref.
#[tauri::command]
pub fn add_audio(engine: Eng, circle_id: String, data_base64: String) -> R<String> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_base64.trim())
        .map_err(|e| format!("bad base64: {e}"))?;
    Ok(engine.add_local_audio(&cid, &bytes))
}

/// Return a `data:` URL for a stored media ref so the WebView can render it inline.
#[tauri::command]
pub fn media_data_url(engine: Eng, circle_id: String, reference: String) -> Option<String> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    let bytes = engine.media_bytes(&cid, &reference)?;
    let mime = if reference.starts_with("v:") {
        "video/mp4"
    } else if reference.starts_with("a:") {
        crate::localmedia::audio_mime(&bytes)
    } else {
        "image/jpeg"
    };
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Some(format!("data:{mime};base64,{b64}"))
}

// ---- scheduled messages ------------------------------------------------------------------

#[derive(Serialize)]
pub struct ScheduledDto {
    pub id: String,
    pub kind: String,
    pub circle_id: String,
    pub body: String,
    pub media_count: usize,
    pub has_music: bool,
    pub send_at_ms: u64,
}

/// Queue a post (`kind = "post"`) or DM (`kind = "dm"`) to send at `send_at_ms` (epoch ms).
#[tauri::command]
pub fn schedule_message(
    engine: Eng,
    kind: String,
    circle_id: String,
    body: String,
    media: Vec<String>,
    music: Option<TrackInput>,
    mute_video: Option<bool>,
    send_at_ms: u64,
) -> String {
    let sched_kind = if kind == "dm" {
        crate::scheduled::SchedKind::Dm
    } else {
        crate::scheduled::SchedKind::Post
    };
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    let track = music.map(|m| crate::scheduled::SchedTrack {
        catalog_id: m.catalog_id,
        title: m.title,
        artist: m.artist,
        artwork_url: m.artwork_url,
        duration_ms: m.duration_ms,
    });
    engine.schedule(sched_kind, cid, body, media, track, mute_video.unwrap_or(false), send_at_ms)
}

#[tauri::command]
pub fn scheduled(engine: Eng) -> Vec<ScheduledDto> {
    engine
        .list_scheduled()
        .into_iter()
        .map(|it| ScheduledDto {
            id: it.id,
            kind: match it.kind {
                crate::scheduled::SchedKind::Post => "post".into(),
                crate::scheduled::SchedKind::Dm => "dm".into(),
            },
            circle_id: it.circle_id,
            body: crate::secret::preview(&it.body),
            media_count: it.media.len(),
            has_music: it.music.is_some(),
            send_at_ms: it.send_at_ms,
        })
        .collect()
}

#[tauri::command]
pub fn cancel_scheduled(engine: Eng, id: String) {
    engine.cancel_scheduled(&id);
}

// ---- BYO S3 mailbox ----------------------------------------------------------------------

#[derive(Serialize)]
pub struct S3StatusDto {
    pub configured: bool,
    pub endpoint: String,
    pub bucket: String,
    pub region: String,
    pub access_key: String,
    pub prefix: String,
}

#[tauri::command]
pub fn s3_status(engine: Eng) -> S3StatusDto {
    match engine.s3_status() {
        Some(c) => S3StatusDto { configured: true, endpoint: c.endpoint, bucket: c.bucket, region: c.region, access_key: c.access_key, prefix: c.prefix },
        None => S3StatusDto { configured: false, endpoint: String::new(), bucket: String::new(), region: String::new(), access_key: String::new(), prefix: String::new() },
    }
}

#[tauri::command]
pub async fn s3_configure(engine: Eng<'_>, endpoint: String, region: String, bucket: String, access_key: String, secret_key: String, prefix: String) -> R<()> {
    let pub_cfg = crate::store::S3Public { endpoint, region, bucket, access_key, prefix };
    engine.s3_configure(pub_cfg, secret_key).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn s3_clear(engine: Eng<'_>) -> R<()> {
    engine.s3_clear().await;
    Ok(())
}

// ---- calls (signaling; the WebRTC mesh runs in the WebView) ------------------------------

#[tauri::command]
pub fn call_group_invite(engine: Eng, session_id: String, group_name: String, roster: Vec<String>, to: Vec<String>) {
    engine.call_group_invite(session_id, group_name, roster, to);
}

#[tauri::command]
pub fn call_accept(engine: Eng, session_id: String, to: Vec<String>) {
    engine.call_accept(session_id, to);
}

#[tauri::command]
pub fn call_hangup(engine: Eng, to: Vec<String>) {
    engine.call_hangup(to);
}

#[tauri::command]
pub fn call_signal(engine: Eng, kind: String, session_id: String, json: String, to: String) {
    engine.call_signal(kind, session_id, json, to);
}

#[tauri::command]
pub fn my_node_hex(engine: Eng) -> String {
    engine.node_id_hex()
}

// ---- multi-identity ----------------------------------------------------------------------

#[derive(Serialize)]
pub struct IdentityDto {
    pub node_hex: String,
    pub label: String,
    pub active: bool,
}

#[tauri::command]
pub fn identities(engine: Eng) -> Vec<IdentityDto> {
    engine
        .identities()
        .into_iter()
        .map(|(node_hex, label, active)| IdentityDto { node_hex, label, active })
        .collect()
}

#[tauri::command]
pub fn add_identity(engine: Eng, label: String) -> R<String> {
    engine.add_identity(&label).map_err(|e| e.to_string())
}

/// Import an identity from a base64-encoded 32-byte seed (a transfer from another device).
#[tauri::command]
pub fn import_identity(engine: Eng, label: String, seed_b64: String) -> R<String> {
    let seed = decode_seed(&seed_b64)?;
    engine.import_identity(&label, seed).map_err(|e| e.to_string())
}

/// Decode a 32-byte seed from a `haven-seed:<base64>` transfer code (from any client) OR a raw
/// base64 seed, in any base64 variant — so a code copied/scanned from a phone just works.
fn decode_seed(input: &str) -> R<[u8; 32]> {
    let s = input.trim();
    let s = s.strip_prefix("haven-seed:").unwrap_or(s).trim();
    use base64::engine::general_purpose as b64;
    let raw = b64::STANDARD
        .decode(s)
        .or_else(|_| b64::URL_SAFE.decode(s))
        .or_else(|_| b64::STANDARD_NO_PAD.decode(s))
        .or_else(|_| b64::URL_SAFE_NO_PAD.decode(s))
        .map_err(|e| format!("bad seed base64: {e}"))?;
    raw.try_into().map_err(|_| "seed is not 32 bytes".to_string())
}

// ---- first-run onboarding ----------------------------------------------------------------
//
// The GUI no longer auto-mints an identity on a fresh install (parity with iOS/Android, which
// both show a welcome screen first). On first launch the backend builds NO engine; the frontend
// calls `needs_onboarding` and shows Create / Link. Both paths persist the chosen seed and then
// `app.restart()` — the relaunch loads the now-present identity through the normal startup path.

/// True on a truly fresh install (empty roster + no legacy seed) — the frontend shows the
/// welcome screen instead of the app. Takes no engine, so it works before one exists.
#[tauri::command]
pub fn needs_onboarding() -> R<bool> {
    let base = crate::store::Paths::resolve().map_err(|e| e.to_string())?;
    let fresh = crate::store::Identities::load(&base).is_empty()
        && crate::store::load_seed().map_err(|e| e.to_string())?.is_none();
    Ok(fresh)
}

/// Persist `seed` as the first (active, legacy-root) identity, mirroring the legacy `master-seed`.
fn save_first_identity(seed: [u8; 32]) -> R<()> {
    let base = crate::store::Paths::resolve().map_err(|e| e.to_string())?;
    let hex = haven_ffi::Account::from_seed(seed.to_vec())
        .map_err(|e| format!("derive node id: {e}"))?
        .node_id_hex();
    crate::store::save_identity_seed(&hex, &seed).map_err(|e| e.to_string())?;
    let mut ids = crate::store::Identities::load(&base);
    ids.add(&hex, "Identity 1");
    ids.save(&base).map_err(|e| e.to_string())?;
    crate::store::save_seed(&seed).map_err(|e| e.to_string())?;
    Ok(())
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

#[tauri::command]
pub fn rename_identity(engine: Eng, node_hex: String, label: String) -> R<()> {
    engine.rename_identity(&node_hex, &label).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn remove_identity(engine: Eng, node_hex: String) -> R<()> {
    engine.remove_identity(&node_hex).map_err(|e| e.to_string())
}

/// Switch the active identity and relaunch so the engine rebuilds on the new seed + data dir.
#[tauri::command]
pub fn switch_identity(app: tauri::AppHandle, engine: Eng, node_hex: String) -> R<()> {
    engine.set_active_identity(&node_hex).map_err(|e| e.to_string())?;
    app.restart();
}

// ---- misc --------------------------------------------------------------------------------

#[tauri::command]
pub fn set_foreground(engine: Eng, fg: bool) {
    engine.set_foreground(fg);
}

#[tauri::command]
pub fn reset(engine: Eng) {
    engine.reset();
}
