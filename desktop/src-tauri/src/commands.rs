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

/// An upgrade offer awaiting a decision. `from_name` is resolved here so the banner can NAME whoever
/// is claiming the circle — the one thing the user needs to judge a claim nothing can verify.
#[derive(Serialize)]
pub struct CircleUpgradeOfferDto {
    pub legacy_circle_id: String,
    pub new_circle_id: String,
    /// Who is claiming the circle — full node hex + the resolved display name for the banner.
    pub from_hex: String,
    pub from_name: String,
    pub name: String,
    /// True when I authored this offer — no confirmation needed.
    pub mine: bool,
}

/// Upgrade offers on this circle I haven't followed. Every competing offer is returned: two people
/// can both claim a legacy circle, and nothing can settle it — so the UI shows them all and the
/// person picks. Never auto-followed.
#[tauri::command]
pub fn pending_circle_upgrades(engine: Eng, circle_id: String) -> Vec<CircleUpgradeOfferDto> {
    engine
        .pending_circle_upgrades(circle_id)
        .into_iter()
        .map(|o| CircleUpgradeOfferDto {
            from_name: engine.display_name(&o.from_hex),
            legacy_circle_id: o.legacy_circle_id,
            new_circle_id: o.new_circle_id,
            from_hex: o.from_hex,
            name: o.name,
            mine: o.mine,
        })
        .collect()
}

/// Whether the "upgrade this circle" action belongs on this circle — a shared one I made, not yet
/// offered. The created-here set is device-local, so only the engine can answer it.
#[tauri::command]
pub fn can_offer_circle_upgrade(engine: Eng, circle_id: String) -> bool {
    engine.can_offer_circle_upgrade(circle_id)
}

/// Offer to carry a circle I made onto its replacement. Returns the replacement's id.
#[tauri::command]
pub fn upgrade_circle(engine: Eng, circle_id: String) -> Option<String> {
    engine.upgrade_circle(circle_id)
}

/// Follow someone's offer — only ever from an explicit click on a banner that named them.
#[tauri::command]
pub fn accept_circle_upgrade(engine: Eng, circle_id: String, new_circle_id: String) -> bool {
    engine.accept_circle_upgrade(circle_id, new_circle_id)
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

/// Switch-Flip 1.0.7 §2: promote a member to circle admin (creator/admin only). Returns whether the
/// grant was authored — false if this device isn't authorized to delegate.
#[tauri::command]
pub fn grant_circle_admin(engine: Eng, circle_id: String, admin_hex: String) -> bool {
    engine.grant_circle_admin(circle_id, admin_hex)
}

/// The current admin accounts (node hex) of a circle — the creator plus creator-delegated admins.
#[tauri::command]
pub fn circle_admins(engine: Eng, circle_id: String) -> Vec<String> {
    engine.circle_admins(&circle_id)
}

// ---- feed / authoring --------------------------------------------------------------------

#[tauri::command]
pub fn feed(engine: Eng, circle_id: String) -> Vec<FeedItemDto> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    engine.maybe_purge_expired_media(&cid); // feed refresh = the purge hook (throttled, off-thread)
    engine.feed(&cid).into_iter().map(|it| feed_item_dto(&engine, it)).collect()
}

/// Media refs flagged sensitive by any member of this circle — the frontend blurs these until the
/// viewer reveals them. We only ever read the federated set; desktop authors no flags.
#[tauri::command]
pub fn sensitive_refs(engine: Eng, circle_id: String) -> Vec<String> {
    let cid = if circle_id.is_empty() { DEFAULT_CIRCLE.to_string() } else { circle_id };
    engine.sensitive_refs(&cid)
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
pub fn edit_post(
    engine: Eng,
    circle_id: String,
    target: String,
    body: String,
    // The caller MUST pass the item's current attachments back in — an edit replaces the media
    // array rather than merging it. Optional only so an older UI bundle can't fail to invoke;
    // `None` still means "strip", which is why both call sites in app.js pass the real values.
    media: Option<Vec<String>>,
    music: Option<TrackInput>,
) {
    engine.edit_post(circle_id, target, body, media.unwrap_or_default(), music.map(|m| m.into_ffi()));
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

// ---- seedless enrollment (seed-drop S4) ---------------------------------------------------

#[derive(serde::Serialize)]
pub struct SeedlessStatusDto {
    /// This device holds no account seed (runs seedless).
    pub seedless: bool,
    /// The enroll grant has been accepted — fully credentialed + operational.
    pub linked: bool,
    /// Still waiting on a grant (a scanned ticket, no credential yet).
    pub linking: bool,
}

/// UI status for the seedless linking flow (drives the "waiting for your other device…" screen).
#[tauri::command]
pub fn seedless_status(engine: Eng) -> SeedlessStatusDto {
    let (seedless, linked, linking) = engine.seedless_status();
    SeedlessStatusDto { seedless, linked, linking }
}

/// NEW DEVICE: adopt a scanned/pasted `haven-enroll:` ticket, register a seedless identity, and
/// relaunch into linking mode (the engine then handshakes with the primary). Legacy `haven-seed:` /
/// raw-seed codes still go through `onboard_link` — this is the new, seedless link path.
#[tauri::command]
pub fn onboard_link_seedless(app: tauri::AppHandle, ticket: String) -> R<()> {
    crate::engine::onboard_seedless(&ticket)?;
    app.restart();
}

/// PRIMARY: mint a `haven-enroll:` ticket string (render as QR + copyable) for a new seedless device.
#[tauri::command]
pub fn enroll_mint_ticket(engine: Eng) -> R<String> {
    engine.mint_enroll_ticket().map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
pub struct EnrollRequestDto {
    pub device_hex: String,
    pub name: String,
}

/// PRIMARY: the seedless-enroll requests awaiting the user's confirm.
#[tauri::command]
pub fn enroll_pending(engine: Eng) -> Vec<EnrollRequestDto> {
    engine
        .enroll_pending()
        .into_iter()
        .map(|(device_hex, name)| EnrollRequestDto { device_hex, name })
        .collect()
}

/// PRIMARY: confirm a pending seedless-enroll request → issue the grant + push full state.
#[tauri::command]
pub fn enroll_approve(engine: Eng, device_hex: String) -> R<()> {
    engine.approve_enroll(device_hex).map_err(|e| e.to_string())
}

/// PRIMARY: dismiss a pending seedless-enroll request.
#[tauri::command]
pub fn enroll_reject(engine: Eng, device_hex: String) {
    engine.reject_enroll(device_hex);
}

/// NEW DEVICE: the grant landed (`haven:enrolled`) → relaunch so the engine rebuilds seedless-linked.
#[tauri::command]
pub fn finish_enroll(app: tauri::AppHandle) {
    app.restart();
}

#[tauri::command]
pub fn messages(engine: Eng, circle_id: String) -> Vec<FeedItemDto> {
    engine.maybe_purge_expired_media(&circle_id); // really drop expired DMs + GC their blobs (throttled)
    engine.messages(&circle_id).into_iter().map(|it| feed_item_dto(&engine, it)).collect()
}

/// Delete every locally-stored media blob no post, message, comment or scheduled send references
/// anymore (Settings ▸ Advanced ▸ Storage). Returns what was freed so the UI can show it.
#[derive(Serialize)]
pub struct MediaCleanupDto {
    pub bytes: u64,
    pub files: usize,
}

#[tauri::command]
pub fn media_cleanup(engine: Eng) -> MediaCleanupDto {
    let (bytes, files) = engine.cleanup_unused_media();
    MediaCleanupDto { bytes, files }
}

// ---- #1 size-sorted cleanup screen -------------------------------------------------------

/// One row of the "Manage media" screen (see engine::MediaRow). `reference` is the on-disk storage
/// name — the handle for pin/delete/download.
#[derive(Serialize)]
pub struct MediaInventoryRowDto {
    pub reference: String,
    pub bytes: u64,
    pub mtime_ms: u64,
    pub kind: String,
    pub circle_name: String,
    pub snippet: Option<String>,
    pub is_orphan: bool,
    pub is_pinned: bool,
}

/// Every stored media blob, largest first, joined to the post/DM it belongs to (best-effort). Blocking
/// (walks every circle's feed) — the same precedent as `media_cleanup`.
#[tauri::command]
pub fn media_inventory(engine: Eng) -> Vec<MediaInventoryRowDto> {
    engine
        .media_inventory()
        .into_iter()
        .map(|r| MediaInventoryRowDto {
            reference: r.reference,
            bytes: r.bytes,
            mtime_ms: r.mtime_ms,
            kind: r.kind.to_string(),
            circle_name: r.circle_name,
            snippet: r.snippet,
            is_orphan: r.is_orphan,
            is_pinned: r.is_pinned,
        })
        .collect()
}

/// Delete the LOCAL blobs for these refs (the posts stay; referenced ones become downloadable
/// placeholders). Returns freed bytes.
#[tauri::command]
pub fn media_delete_selected(engine: Eng, refs: Vec<String>) -> u64 {
    engine.media_delete_selected(refs)
}

// ---- #2 device pin ("keep on this device") ----------------------------------------------

#[tauri::command]
pub fn media_pin(engine: Eng, refs: Vec<String>) {
    engine.pin_media(refs);
}

#[tauri::command]
pub fn media_unpin(engine: Eng, refs: Vec<String>) {
    engine.unpin_media(refs);
}

#[tauri::command]
pub fn media_pinned_count(engine: Eng) -> usize {
    engine.pinned_count()
}

// ---- Kept stories (held on my profile past the 24h story window) ------------------------

/// Every story I chose to keep, newest first. The "You" view unions these with the LIVE feed so a
/// kept story reappears once its event has been purged; the circle story tray does NOT read this, so
/// a kept story still leaves everyone's story row on schedule.
#[tauri::command]
pub fn kept_stories(engine: Eng) -> Vec<crate::store::KeptStory> {
    engine.kept_stories()
}

/// Toggle Keep for one story. Keeping snapshots the content and PINS its media (or the cleanup
/// sweeps reclaim the blobs once the event is gone and it becomes a row of placeholders); un-keeping
/// writes a tombstone so a sibling doesn't quietly re-add it, and releases the pin. Returns the new
/// state so the caller can re-label the control without a round trip.
#[tauri::command]
pub fn toggle_kept_story(engine: Eng, entry: crate::store::KeptStory) -> bool {
    if engine.is_story_kept(&entry.id) {
        engine.unkeep_story(&entry.id);
        false
    } else {
        engine.keep_story(entry);
        true
    }
}

// ---- #3 evicted placeholder + on-demand download ----------------------------------------

/// If this ref was deliberately evicted, its last-known bytes (drives the "Download N" placeholder);
/// `None` otherwise (the tile is simply still syncing).
#[tauri::command]
pub fn media_evicted_size(engine: Eng, reference: String) -> Option<u64> {
    engine.evicted_size(&reference)
}

/// User tapped "Download" on an evicted placeholder: clear the eviction and fetch this one ref now.
#[tauri::command]
pub fn media_download(engine: Eng, reference: String) {
    engine.media_download(reference);
}

/// User tapped "Ask for it back": ask the post's AUTHOR to re-upload media a relay has swept.
/// A relay's retention swept it, but the author almost always still has the original — this is the
/// difference between "gone" and "gone from the relay".
#[tauri::command]
pub fn media_request_when_available(
    engine: Eng,
    reference: String,
    circle_id: String,
    post_id: String,
    author_short: String,
) {
    engine.request_media_when_available(reference, circle_id, post_id, author_short);
}

/// Whether we're already waiting to hear that this ref is back, so the placeholder can say
/// "We'll tell you when it's back" instead of offering the ask a second time.
#[tauri::command]
pub fn media_is_wanted(engine: Eng, reference: String) -> bool {
    engine.media_is_wanted(&reference)
}

/// "Message <author>" from a post's ⋯ menu: open (or reuse) the DM with them and carry the post's
/// media. Returns the DM circle id, or `None` when the author isn't a contact.
#[tauri::command]
pub fn message_author(
    engine: Eng,
    author_short: String,
    circle_id: String,
    post_id: String,
) -> Option<crate::engine::MessageAuthorTarget> {
    engine.message_author(author_short, circle_id, post_id)
}

// ---- #4 local media limits (age/size caps) ----------------------------------------------

#[derive(Serialize)]
pub struct MediaLimitsDto {
    pub days: u32,
    pub gb: u32,
}

#[tauri::command]
pub fn get_media_limits(engine: Eng) -> MediaLimitsDto {
    let (days, gb) = engine.get_media_limits();
    MediaLimitsDto { days, gb }
}

#[tauri::command]
pub fn set_media_limits(engine: Eng, days: u32, gb: u32) {
    engine.set_media_limits(days, gb);
}

#[tauri::command]
pub fn send_dm(engine: Eng, circle_id: String, body: String, media: Vec<String>, music: Option<TrackInput>) {
    engine.send_dm(circle_id, body, media, music.map(|m| m.into_ffi()));
}

// ---- connect / contacts ------------------------------------------------------------------

#[tauri::command]
pub fn connect_by_link(engine: Eng, uri: String) -> bool {
    engine.connect_by_link(uri)
}

/// Drain the `haven://` URLs the OS handed us. The FRONTEND routes them (app.js `routeDeepLink`), because
/// a post link and an invite link are different destinations and only one parser may decide which.
/// Draining is destructive so a link is never acted on twice — the frontend calls this both at boot and
/// on the `haven:deep-link` ping, and either may win.
#[tauri::command]
pub fn take_deep_links(links: tauri::State<'_, crate::DeepLinks>) -> Vec<String> {
    std::mem::take(&mut *links.0.lock().unwrap())
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
pub struct RelayMediaLimitsDto {
    pub max_age_days: u32,
    pub max_bytes: u64,
}

/// How much of your circles' media this host keeps, and for how long. `0` on either = no limit for
/// that dimension.
#[tauri::command]
pub fn get_relay_media_limits(engine: Eng) -> RelayMediaLimitsDto {
    let (max_age_days, max_bytes) = engine.relay_media_limits();
    RelayMediaLimitsDto { max_age_days, max_bytes }
}

#[tauri::command]
pub fn set_relay_media_limits(engine: Eng, max_age_days: u32, max_bytes: u64) {
    engine.set_relay_media_limits(max_age_days, max_bytes);
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

/// Extensions the drop path will read back. Anything else is not media and is refused here rather
/// than in JS, so this command can never be turned into a general "read any file" primitive.
const DROP_VIDEO_EXTS: &[&str] = &["mp4", "mov", "m4v", "webm", "avi", "mkv", "3gp"];
const DROP_IMAGE_EXTS: &[&str] =
    &["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"];

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
        crate::localmedia::image_mime(&bytes)
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

/// Answered or declined a ringing call here → tell my other devices to stop ringing.
#[tauri::command]
pub fn call_handled_elsewhere(engine: Eng, session_id: String) {
    engine.call_handled_elsewhere(session_id);
}

#[tauri::command]
pub fn call_camera_state(engine: Eng, session_id: String, on: bool, to: Vec<String>) {
    engine.call_camera_state(session_id, on, to);
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
