//! The desktop counterpart of the iOS `FeedStore` / Android `HavenNet` networking core:
//! owns the [`HavenSocial`] engine and the [`HavenNode`] iroh transport, speaks the
//! byte-exact [`crate::wire`] protocol, drives the Hello/Event handshake, persists state,
//! and runs the circle relay/mailbox so a Windows PC forms circles and exchanges posts
//! with an iPhone or Android phone.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use haven_ffi::{
    parse_link, Account, FeedItemFfi, HavenNode, HavenSocial, InboundListener, RelayClient,
    RelayServerHandle, TrackRefFfi,
};
use haven_s3::{S3Config, S3Mailbox};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex as TokioMutex;

use crate::callwire;
use crate::localmedia::LocalMedia;
use crate::store::{self, Contact, Paths, Prefs, Profile};
use crate::wire;

pub const DEFAULT_CIRCLE: &str = "default";

/// One configured relay's full state for the Relays hub UI (active + inactive).
#[derive(Clone)]
pub struct RelayDetail {
    pub node_hex: String,
    pub name: String,
    pub active: bool,
    pub is_s3: bool,
    pub is_default: bool,
    pub hosted: bool,
    pub reachable: bool,
}

/// Someone who said hello but we haven't approved yet.
#[derive(Clone)]
pub struct PendingRequest {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
    pub bundle: Vec<u8>,
}

#[derive(Default)]
struct DynState {
    pending: Vec<PendingRequest>,
    /// node ids we initiated a connect to (scanned their QR) → expected verify hash.
    initiated: HashMap<String, String>,
    /// Mailbox keys already ingested or confirmed uploaded — PERSISTED to `mailbox-seen.txt`
    /// (loaded at engine start, flushed after each poll/backfill that added keys). In-memory
    /// only, every cold start re-pulled + re-verified the ENTIRE mailbox — thousands of
    /// duplicate envelopes on a mature circle, all burned on crypto the engine then dropped.
    seen_mailbox: HashSet<String>,
    /// seen_mailbox holds keys not yet flushed to disk.
    seen_mailbox_dirty: bool,
    /// ref -> partial chunks while a media transfer is in flight.
    incoming_media: HashMap<String, IncomingMedia>,
    requested_refs: HashSet<String>,
    /// ref -> last direct (peer) media-request ms. THROTTLE: a missing ref must not be re-blasted to
    /// every contact on every sweep (that floods the network with hundreds of thousands of frames and
    /// buries real delivery — the iOS "nothing communicates" flood). The relay/mailbox restore is the
    /// real, idempotent path; direct peer re-requests are capped + cooled-down to fill gaps only.
    media_req_at: HashMap<String, u64>,
    /// last time we mirrored our OWN media to the circle relays (idempotent backfill, ~every 2 min).
    last_media_backfill_ms: u64,
    /// last time we TOUCH-refreshed our event envelopes on the circle relays (mailbox-GC liveness,
    /// daily). In-memory: 0 at start → first loop tick refreshes, then every 24h of uptime.
    last_event_refresh_ms: u64,
    internet_active: bool,
    relay_active: bool,
    started: bool,
    hosting: bool,
    foreground: bool,
    /// Coalesces overlapping self-sync passes (the 15s loop must never run two at once).
    self_syncing: bool,
}

/// Where a self-sync slot can be read/written: a Haven relay (by node hex) or the user's S3.
enum SelfSyncTransport {
    Relay(String),
    S3(Arc<S3Mailbox>),
}

struct IncomingMedia {
    total: u32,
    chunks: HashMap<u32, Vec<u8>>,
}

pub struct Engine {
    seed: [u8; 32],
    social: Arc<HavenSocial>,
    paths: Paths,
    media: LocalMedia,
    app: StdMutex<Option<AppHandle>>,
    node: StdMutex<Option<Arc<HavenNode>>>,
    relay_host: StdMutex<Option<Arc<RelayServerHandle>>>,
    prefs: StdMutex<Prefs>,
    dyn_state: StdMutex<DynState>,
    scheduled: StdMutex<crate::scheduled::ScheduledStore>,
    roster: StdMutex<crate::roster::DeviceRoster>,
    sched_counter: std::sync::atomic::AtomicU64,
    relay_clients: TokioMutex<HashMap<String, Arc<RelayClient>>>,
    /// Per-relay backoff health, keyed by node hex — drives graceful fallback.
    relay_health: StdMutex<HashMap<String, crate::relayhealth::RelayHealth>>,
    s3: TokioMutex<Option<Arc<S3Mailbox>>>,
    /// Client for relays' plain-HTTP media interfaces — the DEFAULT cross-NAT media transport.
    http: reqwest::Client,
    /// HTTP relay URLs that recently failed to answer → retry-after epoch ms (2-min backoff), so a
    /// dead LAN address doesn't cost a connect-timeout per chunk.
    http_url_bad: StdMutex<HashMap<String, u64>>,
    /// Frame-9 mesh-relay msgIds already seen (dedup / loop protection, parity with iOS seenRelay).
    seen_relay: StdMutex<std::collections::HashSet<String>>,
}

const MEDIA_CHUNK_SIZE: usize = 512 * 1024;
/// Relay/S3 media chunk size — 8 MB, well under blobstore's MAX_BLOB (256 MB) and memory-safe.
/// (Distinct from MEDIA_CHUNK_SIZE above, which is the peer-to-peer iroh frame chunk.)
const MEDIA_CHUNK_BYTES: usize = 8 * 1024 * 1024;
/// 9-byte ASCII magic marking a chunk manifest blob. A sealed envelope is JSON starting with '{',
/// so it can never collide. Must be byte-identical across iOS/macOS + Android.
const MEDIA_MANIFEST_MAGIC: &[u8] = b"HVCHUNK1\n";

fn hex_to_bytes32(hex: &str) -> Option<Vec<u8>> {
    if hex.len() != 64 {
        return None;
    }
    (0..32).map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()).collect()
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Engine {
    /// Build the engine for an existing or freshly-created seed. Loads prefs + restores state.
    pub fn new(paths: Paths, seed: [u8; 32]) -> Result<Arc<Self>> {
        let social = HavenSocial::new(seed.to_vec())
            .map_err(|e| anyhow::anyhow!("HavenSocial::new: {e}"))?;
        if let Some(state) = store::read_state(&paths) {
            social.import_state(state);
        }
        let prefs = Prefs::load(&paths);
        let media = LocalMedia::new(paths.media_dir());
        let scheduled = crate::scheduled::ScheduledStore::load(&paths.scheduled_file());
        let roster = crate::roster::DeviceRoster::load(&paths);
        // Engine acts under this device's UNIQUE transport identity (parity with iOS configure() /
        // Android init): the account id stays the sealing/trust anchor + the contact handle friends
        // pin; friends resolve it to this device's node id via the signed roster (frame 27), so any
        // number of devices can run under one account without colliding on iroh discovery.
        let _ = social.use_device_identity(roster.device_seed.clone());
        let _ = social.register_device(
            roster.device_bundle(),
            crate::roster::DeviceRoster::device_name(),
            now_ms() / 1000,
        );
        let dyn_state = DynState {
            seen_mailbox: std::fs::read_to_string(paths.root.join("mailbox-seen.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            ..DynState::default()
        };
        Ok(Arc::new(Self {
            seed,
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            relay_host: StdMutex::new(None),
            prefs: StdMutex::new(prefs),
            dyn_state: StdMutex::new(dyn_state),
            scheduled: StdMutex::new(scheduled),
            roster: StdMutex::new(roster),
            sched_counter: std::sync::atomic::AtomicU64::new(0),
            relay_clients: TokioMutex::new(HashMap::new()),
            relay_health: StdMutex::new(HashMap::new()),
            s3: TokioMutex::new(None),
            http: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(4))
                .build()
                .unwrap_or_default(),
            http_url_bad: StdMutex::new(HashMap::new()),
            seen_relay: StdMutex::new(std::collections::HashSet::new()),
        }))
    }

    pub fn set_app(&self, app: AppHandle) {
        *self.app.lock().unwrap() = Some(app);
    }

    pub fn set_foreground(&self, fg: bool) {
        self.dyn_state.lock().unwrap().foreground = fg;
    }

    fn emit_changed(&self) {
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("haven:changed", ());
        }
    }

    fn notify(&self, title: &str, body: &str) {
        if self.dyn_state.lock().unwrap().foreground {
            return;
        }
        if let Some(app) = self.app.lock().unwrap().clone() {
            // Native OS notification (Action Center / toast)…
            use tauri_plugin_notification::NotificationExt;
            let _ = app.notification().builder().title(title).body(body).show();
            // …and an in-app event for a toast if a window is open.
            let _ = app.emit("haven:notify", serde_json::json!({ "title": title, "body": body }));
        }
    }

    // ---- identity / profile -----------------------------------------------------------

    pub fn node_id_hex(&self) -> String {
        self.social.my_node_hex()
    }

    pub fn invite_uri(&self) -> String {
        let base = Account::from_seed(self.seed.to_vec())
            .map(|a| a.haven_uri())
            .unwrap_or_default();
        self.embed_invite_hints(base)
    }

    pub fn invite_link(&self, domain: &str) -> String {
        let base = Account::from_seed(self.seed.to_vec())
            .map(|a| a.haven_link(domain.to_string()))
            .unwrap_or_default();
        self.embed_invite_hints(base)
    }

    // ---- invite device-id hints (roster-bootstrap bridge) --------------------------------
    //
    // Under the device-seed transport a friend's ACCOUNT id resolves to no node, and their signed
    // roster (frame 27) can only arrive over a path that itself needs a device id — the bootstrap
    // deadlock. The invite link therefore carries my device node id(s) as a `?d=` query BEFORE the
    // `#` fragment (an old parser reads only the fragment, so the link stays compatible); the
    // scanner dials the hints until the real roster supersedes them. Mirrors iOS/Android.

    /// Insert `?d=<my device ids>` before the link's `#` fragment.
    fn embed_invite_hints(&self, link: String) -> String {
        let acct = self.social.my_node_hex().to_lowercase();
        let mut ids: Vec<String> = vec![self.social.my_device_node_hex()];
        for d in self.social.device_node_ids_for(acct.clone()) {
            let l = d.to_lowercase();
            if l != acct && !ids.iter().any(|i| i.to_lowercase() == l) {
                ids.push(d);
            }
        }
        ids.retain(|i| i.len() == 64);
        ids.truncate(4);
        let Some(hash) = link.find('#') else { return link };
        if ids.is_empty() || link.contains('?') {
            return link;
        }
        format!("{}?d={}{}", &link[..hash], ids.join(","), &link[hash..])
    }

    /// The `d=` device ids from a pasted/scanned link (empty when absent). Only 64-hex ids pass.
    fn extract_invite_hints(link: &str) -> Vec<String> {
        let Some(q_start) = link.find('?') else { return vec![] };
        let end = link.find('#').unwrap_or(link.len());
        if q_start >= end {
            return vec![];
        }
        for pair in link[q_start + 1..end].split('&') {
            let Some((k, v)) = pair.split_once('=') else { continue };
            if k != "d" {
                continue;
            }
            return v
                .split(',')
                .map(|s| s.to_lowercase())
                .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()))
                .take(4)
                .collect();
        }
        vec![]
    }

    /// Remember a contact's invite-hint device ids (dialed until their signed roster lands).
    fn record_device_hints(&self, account_hex: &str, ids: Vec<String>) {
        if ids.is_empty() {
            return;
        }
        let key = account_hex.to_lowercase();
        let mut p = self.prefs.lock().unwrap();
        let cur = p.device_hints.entry(key).or_default();
        for d in ids {
            if !cur.contains(&d) {
                cur.push(d);
            }
        }
        let excess = cur.len().saturating_sub(8);
        if excess > 0 {
            cur.drain(..excess);
        }
        let _ = p.save(&self.paths);
    }

    fn device_hints_for(&self, account_hex: &str) -> Vec<String> {
        self.prefs.lock().unwrap().device_hints.get(&account_hex.to_lowercase()).cloned().unwrap_or_default()
    }

    pub fn get_profile(&self) -> Profile {
        self.prefs.lock().unwrap().profile.clone()
    }

    pub fn set_profile(self: &Arc<Self>, profile: Profile) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.profile = profile;
            let _ = p.save(&self.paths);
        }
        // Re-greet contacts so the new name/card propagates.
        self.sync_with_contacts();
        self.emit_changed();
    }

    // ---- multi-identity -----------------------------------------------------------------

    /// (node_hex, label, is_active) for every identity on this device.
    pub fn identities(&self) -> Vec<(String, String, bool)> {
        let ids = store::Identities::load(&self.paths);
        ids.items
            .iter()
            .map(|e| (e.node_hex.clone(), e.label.clone(), e.node_hex == ids.active))
            .collect()
    }

    /// Mint a brand-new identity (its seed goes to the secure store). Does not switch to it.
    pub fn add_identity(&self, label: &str) -> Result<String> {
        let acct = Account::generate();
        let seed: [u8; 32] = acct
            .secret_seed()
            .try_into()
            .map_err(|_| anyhow::anyhow!("generated seed not 32 bytes"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    /// Adopt an existing identity from a 32-byte seed (e.g. a transfer from another device).
    pub fn import_identity(&self, label: &str, seed: [u8; 32]) -> Result<String> {
        let acct = Account::from_seed(seed.to_vec()).map_err(|e| anyhow::anyhow!("bad seed: {e}"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    pub fn rename_identity(&self, node_hex: &str, label: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.rename(node_hex, label) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(())
    }

    /// Make `node_hex` the active identity. Mirrors its seed to the legacy `master-seed` so the
    /// headless relay follows it too. The caller must relaunch the app to rebuild the engine.
    pub fn set_active_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.set_active(node_hex) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        if let Some(seed) = store::load_identity_seed(node_hex)? {
            store::save_seed(&seed)?;
            // Switching to a DIFFERENT identity: clear the self-sync base so the rebuilt engine doesn't
            // diff the new (empty-until-synced) account against the old identity's base and tombstone it.
            store::remove_if_exists(&self.paths.selfsync_state_file());
        }
        ids.save(&self.paths)?;
        Ok(())
    }

    pub fn remove_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        match ids.remove(node_hex) {
            Some(dir) => {
                ids.save(&self.paths)?;
                store::delete_identity_seed(node_hex);
                if !dir.is_empty() {
                    let _ = std::fs::remove_dir_all(self.paths.base.join(dir));
                }
                self.emit_changed();
                Ok(())
            }
            None => Err(anyhow::anyhow!("cannot remove the active or an unknown identity")),
        }
    }

    // ---- start --------------------------------------------------------------------------

    /// Start the iroh node and begin syncing. Safe to call repeatedly.
    pub async fn start(self: &Arc<Self>) {
        {
            if self.node.lock().unwrap().is_some() {
                return;
            }
        }
        let listener: Arc<dyn InboundListener> = Arc::new(NodeListener {
            engine: Arc::downgrade(self),
        });
        // Bind the transport to the per-DEVICE seed (unique node/relay id per install, parity with
        // iOS/Android device-seed transport) — never the account id, which is identity-only.
        let device_seed = self.roster.lock().unwrap().device_seed.clone();
        match HavenNode::start(device_seed, listener).await {
            Ok(node) => {
                *self.node.lock().unwrap() = Some(node);
                self.dyn_state.lock().unwrap().started = true;
                self.emit_changed();
                self.sync_with_contacts();
                self.poll_mailbox().await;
                self.request_missing_media();
            }
            Err(e) => {
                log::error!("node start failed: {e}");
            }
        }
        self.fire_due_scheduled(); // flush anything overdue from while the app was closed
        self.purge_stale_relays().await; // erase relays inactive AND unseen > 7 days (config else survives)
        self.start_mailbox_loop();
    }

    fn start_mailbox_loop(self: &Arc<Self>) {
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(15)).await;
                me.poll_mailbox().await;
                // Persistently retry any media an interrupted nearby/iroh transfer left incomplete —
                // relay first, then peers — every tick until nothing is missing (parity with iOS/Android).
                me.request_missing_media();
                me.fire_due_scheduled();
                me.mesh_sync().await;
                me.poll_self_sync().await;
                // Re-emit our own relay id every tick so peers reliably learn it (frame 19 was a one-shot
                // at relay start). Cheap; no-op unless we host.
                me.reannounce_own_relay();
                // Mirror our own media to the relays we know periodically (~every 2 min). The cross-device
                // chunk path is unreliable; the relay is the durable convergence path.
                let due = {
                    let mut st = me.dyn_state.lock().unwrap();
                    let now = now_ms();
                    if now - st.last_media_backfill_ms > 120_000 {
                        st.last_media_backfill_ms = now;
                        true
                    } else {
                        false
                    }
                };
                if due {
                    me.backfill_media_to_relays().await;
                }
                // Daily (first tick after launch, then every 24h of uptime): re-assert my event
                // envelopes in every circle mailbox — upload what a relay never saw, TOUCH what
                // it already holds so relay-side mailbox GC (30-day TTL) keeps live entries
                // while legacy duplicates and stale-epoch copies age out.
                let refresh_due = {
                    let mut st = me.dyn_state.lock().unwrap();
                    let now = now_ms();
                    if now - st.last_event_refresh_ms > 86_400_000 {
                        st.last_event_refresh_ms = now;
                        true
                    } else {
                        false
                    }
                };
                if refresh_due {
                    for c in me.social.circles() {
                        me.backfill_mailbox(&c.id).await;
                    }
                }
                me.purge_stale_relays().await; // GC relays inactive + unseen > 7 days (config else survives)
            }
        });
    }

    /// If we're hosting a relay, pull from every sibling relay so the mailbox self-replicates
    /// across the mesh — any relay can then join/leave freely without losing the circle's data.
    async fn mesh_sync(self: &Arc<Self>) {
        let Some(host) = self.relay_host.lock().unwrap().clone() else { return };
        let my_hex = host.node_id_hex();
        let peers: std::collections::BTreeSet<String> = {
            let p = self.prefs.lock().unwrap();
            p.relays.values().flatten().filter(|h| p.relay_is_active(h)).cloned().collect()
        };
        for peer in peers {
            if peer == my_hex || !self.relay_available(&peer) {
                continue;
            }
            if host.sync_from(peer.clone()).await > 0 {
                self.mark_relay_ok(&peer);
                self.dyn_state.lock().unwrap().relay_active = true;
                self.emit_changed();
            }
        }
    }

    // ---- scheduled messages -------------------------------------------------------------

    fn persist_scheduled(&self) {
        let snap = self.scheduled.lock().unwrap().clone();
        let _ = snap.save(&self.paths.scheduled_file());
    }

    /// Queue a post or DM to be sent at `send_at_ms`. Returns the generated item id.
    pub fn schedule(
        self: &Arc<Self>,
        kind: crate::scheduled::SchedKind,
        circle_id: String,
        body: String,
        media: Vec<String>,
        music: Option<crate::scheduled::SchedTrack>,
        mute_video: bool,
        send_at_ms: u64,
    ) -> String {
        let n = self.sched_counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("sch-{}-{n}", now_ms());
        let item = crate::scheduled::ScheduledItem {
            id: id.clone(),
            kind,
            circle_id,
            body,
            media,
            music,
            mute_video,
            send_at_ms,
            created_at_ms: now_ms(),
        };
        self.scheduled.lock().unwrap().add(item);
        self.persist_scheduled();
        self.emit_changed();
        id
    }

    pub fn list_scheduled(&self) -> Vec<crate::scheduled::ScheduledItem> {
        self.scheduled.lock().unwrap().items.clone()
    }

    pub fn cancel_scheduled(self: &Arc<Self>, id: &str) {
        let removed = self.scheduled.lock().unwrap().remove(id);
        if removed {
            self.persist_scheduled();
            self.emit_changed();
        }
    }

    /// Send everything whose time has arrived, then persist the remaining queue.
    pub fn fire_due_scheduled(self: &Arc<Self>) {
        let due = self.scheduled.lock().unwrap().take_due(now_ms());
        if due.is_empty() {
            return;
        }
        for it in due {
            let music = it.music.map(|m| TrackRefFfi {
                catalog_id: m.catalog_id,
                title: m.title,
                artist: m.artist,
                artwork_url: m.artwork_url,
                duration_ms: m.duration_ms,
            });
            match it.kind {
                crate::scheduled::SchedKind::Post => {
                    self.post(it.circle_id, it.body, it.media, music, it.mute_video);
                }
                crate::scheduled::SchedKind::Dm => {
                    self.send_dm(it.circle_id, it.body, it.media);
                }
            }
        }
        self.persist_scheduled();
        self.emit_changed();
    }

    pub fn started(&self) -> bool {
        self.dyn_state.lock().unwrap().started
    }

    pub fn host_on_launch(&self) -> bool {
        self.prefs.lock().unwrap().host_on_launch
    }

    /// Composer reachability light for a circle: "synced" = a relay/bucket holds posts for offline
    /// members (this circle has a relay, or a global relay/bucket/self-host is configured); "local" =
    /// device-only, nothing will leave this machine until a transport is configured. (Desktop has no
    /// local proximity mesh, so there's no mesh-based "syncing" state.)
    pub fn sync_status(&self, circle_id: &str) -> String {
        let any_transport = {
            let prefs = self.prefs.lock().unwrap();
            !prefs.active_relays_for(circle_id).is_empty()
                || prefs.s3.is_some()
                || prefs.host_on_launch
                || prefs.relays.values().flatten().any(|h| prefs.relay_is_active(h))
        };
        if any_transport {
            return "synced".into();
        }
        // No relay/bucket configured: online = best-effort direct iroh delivery done (green, no nag);
        // only genuinely offline is the device-only warning. (Previously pinned a relay-less node to a
        // permanent "device only" red.)
        if self.dyn_state.lock().unwrap().internet_active { "synced".into() } else { "local".into() }
    }

    pub fn set_host_on_launch(self: &Arc<Self>, on: bool) {
        let mut p = self.prefs.lock().unwrap();
        p.host_on_launch = on;
        let _ = p.save(&self.paths);
    }

    pub fn video_sound_on(&self) -> bool {
        self.prefs.lock().unwrap().video_sound_on
    }

    pub fn set_video_sound(self: &Arc<Self>, on: bool) {
        let mut p = self.prefs.lock().unwrap();
        p.video_sound_on = on;
        let _ = p.save(&self.paths);
    }

    // ---- Multi-device roster (iOS/Android parity; the signed-credential crypto is in the shared core) ----

    fn account_bundle(&self) -> Vec<u8> {
        haven_ffi::Account::from_seed(self.seed.to_vec()).map(|a| a.public_bundle()).unwrap_or_default()
    }

    /// Sign + push the current roster to the engine, then persist.
    fn push_roster(self: &Arc<Self>) {
        let now = now_ms() / 1000;
        let signed = self.roster.lock().unwrap().resign(&self.seed, now);
        if let Some((list, creds)) = signed {
            self.social.set_my_device_roster(list, creds);
        }
        let _ = self.roster.lock().unwrap().save(&self.paths);
    }

    /// Turn THIS device into the primary (master-key holder) that authorizes/revokes the others.
    pub fn enable_device_roster(self: &Arc<Self>) {
        let bundle = self.account_bundle();
        let hex = self.node_id_hex();
        self.roster.lock().unwrap().enable(&bundle, &hex);
        self.push_roster();
        self.emit_changed();
    }

    /// Revoke a linked device — it can decrypt nothing posted afterward.
    pub fn revoke_device(self: &Arc<Self>, node_hex: String) {
        if !self.roster.lock().unwrap().revoke(&node_hex) {
            return;
        }
        self.push_roster();
        self.emit_changed();
    }

    /// Step this device down from being the primary (e.g. the wrong device claimed the role).
    pub fn step_down_as_primary(self: &Arc<Self>) {
        {
            let mut r = self.roster.lock().unwrap();
            r.step_down();
            let _ = r.save(&self.paths);
        }
        self.emit_changed();
    }

    /// Ask the primary (over iroh, to my own node id) to authorize this device with its own key.
    pub fn request_device_enrollment(self: &Arc<Self>) {
        let (bundle, name, hex) = {
            let r = self.roster.lock().unwrap();
            (r.device_bundle(), crate::roster::DeviceRoster::device_name(), r.device_node_hex())
        };
        let mut payload = Vec::new();
        wire::lp_append(&mut payload, &bundle);
        wire::lp_append(&mut payload, name.as_bytes());
        wire::lp_append(&mut payload, hex.as_bytes());
        let me = self.node_id_hex();
        self.send_frame(wire::DEVICE_ENROLL, &payload, &me);
    }

    /// I hold the master seed → authorize the requesting device: issue its credential, add it to my
    /// signed roster, and send the grant back.
    fn handle_enrollment_request(self: &Arc<Self>, payload: &[u8]) {
        let mut r = wire::Reader::new(payload);
        let Some(bundle) = r.lp() else { return };
        let name = r.lp().map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_else(|| "Device".into());
        let Some(hex_b) = r.lp() else { return };
        let hex = String::from_utf8_lossy(&hex_b).into_owned();
        let my_dev = self.roster.lock().unwrap().device_node_hex();
        if hex.is_empty() || hex == my_dev {
            return; // not my own device's request
        }
        let account_bundle = self.account_bundle();
        let account_hex = self.node_id_hex();
        let now = now_ms() / 1000;
        let cred = {
            let mut rr = self.roster.lock().unwrap();
            rr.enable(&account_bundle, &account_hex);
            rr.add_linked_device(&bundle, &hex, &name, &self.seed, now)
        };
        let Some(cred) = cred else { return };
        self.push_roster();
        let mut grant = Vec::new();
        wire::lp_append(&mut grant, hex.as_bytes());
        wire::lp_append(&mut grant, &cred);
        let me = self.node_id_hex();
        self.send_frame(wire::DEVICE_GRANT, &grant, &me);
    }

    /// I'm the requesting device → store the credential the primary issued for my key.
    fn handle_device_grant(self: &Arc<Self>, payload: &[u8]) {
        let mut r = wire::Reader::new(payload);
        let Some(hex_b) = r.lp() else { return };
        let hex = String::from_utf8_lossy(&hex_b).into_owned();
        let Some(cred) = r.lp() else { return };
        let mut rr = self.roster.lock().unwrap();
        if hex != rr.device_node_hex() {
            return; // not for me
        }
        rr.credential = Some(cred);
        let _ = rr.save(&self.paths);
    }

    /// (isEnabled, thisDeviceAuthorized, devices) for the Authorized-Devices UI.
    pub fn device_roster_dto(&self) -> (bool, bool, Vec<crate::roster::RosterDeviceDto>) {
        let r = self.roster.lock().unwrap();
        (r.is_enabled(), r.is_authorized(), r.devices(&self.node_id_hex()))
    }

    // ---- circles ------------------------------------------------------------------------

    pub fn feed_circles(&self) -> Vec<haven_ffi::CircleInfoFfi> {
        self.social
            .circles()
            .into_iter()
            .filter(|c| !c.id.starts_with("dm:"))
            .collect()
    }

    pub fn create_circle(self: &Arc<Self>, name: String) -> String {
        let id = format!("circle-{}-{}", &self.node_id_hex().chars().take(8).collect::<String>(), now_ms());
        self.social.create_circle(id.clone(), name);
        self.persist();
        self.emit_changed();
        id
    }

    pub fn rename_circle(self: &Arc<Self>, id: String, name: String) {
        self.social.rename_circle(id, name);
        self.persist();
        self.emit_changed();
    }

    pub fn leave_circle(self: &Arc<Self>, id: String) {
        if id == DEFAULT_CIRCLE {
            return;
        }
        self.social.leave_circle(id);
        self.persist();
        self.emit_changed();
    }

    /// Add an existing contact to a circle + greet them there so it forms on their side.
    pub fn add_to_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        self.clear_circle_removal(&circle_id, &contact_id_hex); // deliberate re-add un-bans them
        let _ = self.social.add_existing_to_circle(circle_id.clone(), contact_id_hex.clone());
        self.persist();
        self.emit_changed();
        self.send_hello(&circle_id, &contact_id_hex);
    }

    /// Remove a member from a circle (without blocking). Records the severance so it propagates to our
    /// own devices as an INTENTIONAL removal and survives the additive re-sync (apply_local won't re-add
    /// anyone in `circle_removals`), then re-keys the relay mailbox to the remaining members so the
    /// removed person can't pull future media.
    pub fn remove_from_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        {
            let mut p = self.prefs.lock().unwrap();
            let entry = format!("{circle_id}|{}", contact_id_hex.to_lowercase());
            p.circle_removals_cleared.retain(|e| e != &entry);
            if !p.circle_removals.iter().any(|e| e == &entry) {
                p.circle_removals.push(entry);
            }
            let _ = p.save(&self.paths);
        }
        self.social.remove_from_circle(circle_id, contact_id_hex);
        self.persist();
        self.authorize_membership();
        self.emit_changed();
    }

    /// Was this member explicitly removed from this circle? (Blocks their unsolicited handshake rejoin.)
    fn is_removed_from_circle(&self, circle_id: &str, id_hex: &str) -> bool {
        let entry = format!("{circle_id}|{}", id_hex.to_lowercase());
        self.prefs.lock().unwrap().circle_removals.iter().any(|e| e == &entry)
    }

    /// Re-allow a member into a circle — ONLY on a deliberate re-add (approve / add / invite connect).
    /// The entry moves to `circle_removals_cleared` (even when THIS device holds no removal — a
    /// sibling might) so the clear propagates via self-sync as an explicit newer LWW write instead of
    /// silently losing to a stale removal record.
    fn clear_circle_removal(&self, circle_id: &str, id_hex: &str) {
        let entry = format!("{circle_id}|{}", id_hex.to_lowercase());
        let mut p = self.prefs.lock().unwrap();
        p.circle_removals.retain(|e| e != &entry);
        if !p.circle_removals_cleared.iter().any(|e| e == &entry) {
            p.circle_removals_cleared.push(entry);
        }
        let _ = p.save(&self.paths);
    }

    // ---- feed / authoring ---------------------------------------------------------------

    pub fn feed(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let retention = self.prefs.lock().unwrap().retention_secs;
        self.social.feed(circle_id.to_string(), now_ms(), retention)
    }

    pub fn post(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool) {
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        match self.social.post(circle_id.clone(), body, media.clone(), music, None, false, mute_video, now_ms()) {
            Ok(env) => {
                self.after_author(&circle_id, &env);
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    for r in media {
                        me.upload_media(&circle_id, &r).await;
                    }
                });
            }
            Err(e) => log::error!("post failed: {e}"),
        }
    }

    pub fn post_story(self: &Arc<Self>, body: String, media: Option<String>, music: Option<TrackRefFfi>) {
        if body.trim().is_empty() && media.is_none() && music.is_none() {
            return;
        }
        let media_vec: Vec<String> = media.iter().cloned().collect();
        match self.social.post(DEFAULT_CIRCLE.to_string(), body, media_vec, music, Some(86_400), true, false, now_ms()) {
            Ok(env) => {
                self.after_author(DEFAULT_CIRCLE, &env);
                if let Some(r) = media {
                    let me = self.clone();
                    tauri::async_runtime::spawn(async move { me.upload_media(DEFAULT_CIRCLE, &r).await; });
                }
            }
            Err(e) => log::error!("post_story failed: {e}"),
        }
    }

    pub fn comment(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if body.trim().is_empty() {
            return;
        }
        if let Ok(env) = self.social.comment(circle_id.clone(), target, body, vec![], now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn react(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.react(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unreact(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.unreact(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn edit_post(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if let Ok(env) = self.social.edit(circle_id.clone(), target, body, vec![], None, false, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unsend_post(self: &Arc<Self>, circle_id: String, target: String) {
        if let Ok(env) = self.social.unsend(circle_id.clone(), target, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    /// Persist, bump the UI, and broadcast a freshly-authored sealed envelope to members.
    fn after_author(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        self.persist();
        self.emit_changed();
        let payload = wire::event_payload(circle_id, env);
        for id_hex in self.social.contact_node_ids(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &payload, &id_hex);
        }
        let me = self.clone();
        let cid = circle_id.to_string();
        let env = env.to_vec();
        tauri::async_runtime::spawn(async move {
            // The epoch HEAD (roster + current key commit) rides along with every authored event:
            // a relay-only peer could otherwise pull the event long before the commit that opens it
            // (it would sit in their pending-epoch buffer until the next full backfill). Cheap —
            // the commit is cached until the epoch/recipient set changes, and the persisted
            // seen-set dedupes the re-upload. iOS/Android parity.
            for head in me.social.export_epoch_head(cid.clone()) {
                me.upload_event(&cid, &head).await;
            }
            me.upload_event(&cid, &env).await;
            me.flush_seen_mailbox();
        });
    }

    // ---- DMs ----------------------------------------------------------------------------

    pub fn dm_circle_id(&self, id_hex: &str) -> String {
        let mut pair = [self.node_id_hex(), id_hex.to_string()];
        pair.sort();
        format!("dm:{}-{}", pair[0], pair[1])
    }

    fn dm_allows(circle_id: &str, node_hex: &str) -> bool {
        // 2+ members so group DMs are admitted too; the sender must be one of the encoded members.
        let parts: Vec<&str> = circle_id.trim_start_matches("dm:").split('-').collect();
        parts.len() >= 2 && parts.contains(&node_hex)
    }

    /// Deterministic GROUP-DM circle id — sorted node ids of every member (me + others).
    pub fn group_dm_circle_id(&self, other_hexes: &[String]) -> String {
        let mut all: Vec<String> = other_hexes.iter().map(|h| h.to_lowercase()).collect();
        all.push(self.node_id_hex());
        all.sort();
        all.dedup();
        format!("dm:{}", all.join("-"))
    }

    pub fn start_dm(self: &Arc<Self>, contact_id_hex: String, contact_name: String) -> String {
        let id = self.dm_circle_id(&contact_id_hex);
        self.social.create_circle(id.clone(), contact_name);
        let _ = self.social.add_existing_to_circle(id.clone(), contact_id_hex.clone());
        self.persist();
        self.send_hello(&id, &contact_id_hex);
        id
    }

    /// Open (or create) a GROUP DM with 2+ contacts (each `(id_hex, name)`); returns the dm circle id.
    pub fn start_group_dm(self: &Arc<Self>, members: Vec<(String, String)>) -> String {
        if members.len() == 1 {
            return self.start_dm(members[0].0.clone(), members[0].1.clone());
        }
        let hexes: Vec<String> = members.iter().map(|(h, _)| h.clone()).collect();
        let id = self.group_dm_circle_id(&hexes);
        let title = members.iter().map(|(_, n)| n.clone()).collect::<Vec<_>>().join(", ");
        self.social.create_circle(id.clone(), title);
        for (hex, _) in &members {
            let _ = self.social.add_existing_to_circle(id.clone(), hex.clone());
        }
        self.persist();
        for (hex, _) in &members {
            self.send_hello(&id, hex);
        }
        id
    }

    pub fn messages(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let mut m = self.social.feed(circle_id.to_string(), now_ms(), None);
        // Hide anything exchanged before this DM was cleared (see `delete_conversation`). A DM's circle id is
        // deterministic, so a re-started/re-synced thread would otherwise resurrect the old messages.
        if let Some(&cutoff) = self.prefs.lock().unwrap().dm_cleared_before.get(circle_id) {
            m.retain(|i| i.created_at >= cutoff);
        }
        m.sort_by_key(|i| i.created_at);
        m
    }

    /// Delete a whole DM conversation locally: record a "cleared before" watermark (so re-syncing or
    /// re-starting this deterministic-id DM won't restore old messages — true network deletion is
    /// impossible in P2P) and leave the circle. Mirrors iOS `FeedStore.deleteConversation`.
    pub fn delete_conversation(self: &Arc<Self>, circle_id: String) {
        if !circle_id.starts_with("dm:") {
            return;
        }
        {
            let mut p = self.prefs.lock().unwrap();
            p.dm_cleared_before.insert(circle_id.clone(), now_ms());
            let _ = p.save(&self.paths);
        }
        self.leave_circle(circle_id);
    }

    pub fn send_dm(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>) {
        if body.trim().is_empty() && media.is_empty() {
            return;
        }
        if let Ok(env) = self.social.post(circle_id.clone(), body, media.clone(), None, None, false, false, now_ms()) {
            self.after_author(&circle_id, &env);
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                for r in media {
                    me.upload_media(&circle_id, &r).await;
                }
            });
        }
    }

    /// DM threads as (circleId, partnerName, lastBody, lastAt, memberCount). Sorted most-recently-active
    /// first. `memberCount` lets the UI tell a group DM (2+ others) from a 1:1.
    pub fn dm_threads(&self) -> Vec<(String, String, String, u64, u32)> {
        let cleared = self.prefs.lock().unwrap().dm_cleared_before.clone();
        let mut out = vec![];
        for c in self.social.circles() {
            if !c.id.starts_with("dm:") {
                continue;
            }
            let cutoff = cleared.get(&c.id).copied();
            let (last_body, last_at) = self
                .social
                .feed(c.id.clone(), now_ms(), None)
                .iter()
                .filter(|i| cutoff.map_or(true, |cut| i.created_at >= cut))
                .max_by_key(|i| i.created_at)
                .map(|i| (crate::secret::preview(&i.body), i.created_at))
                .unwrap_or_default();
            out.push((c.id.clone(), c.name.clone(), last_body, last_at, c.member_count));
        }
        out.sort_by(|a, b| b.3.cmp(&a.3));
        out
    }

    // ---- connect / handshake ------------------------------------------------------------

    pub fn connect_by_link(self: &Arc<Self>, uri: String) -> bool {
        let trimmed = uri.trim().to_string();
        let info = match parse_link(trimmed.clone()) {
            Ok(i) => i,
            Err(_) => return false,
        };
        // Scanning/pasting an invite is a DELIBERATE add: clear any old removal tombstone, or their
        // hellos stay dropped (handshake guard) and self-sync re-severs them (re-add never sticks).
        self.clear_circle_removal(DEFAULT_CIRCLE, &info.id_hex);
        // Store the invite's device-id hints BEFORE the hello, so the very first dial can reach
        // their device (their account id resolves to no node post-device-seed).
        self.record_device_hints(&info.id_hex, Self::extract_invite_hints(&trimmed));
        self.dyn_state
            .lock()
            .unwrap()
            .initiated
            .insert(info.id_hex.clone(), info.verification_hex.clone());
        self.send_hello(DEFAULT_CIRCLE, &info.id_hex);
        true
    }

    pub fn pending(&self) -> Vec<PendingRequest> {
        self.dyn_state.lock().unwrap().pending.clone()
    }

    pub fn approve(self: &Arc<Self>, id_hex: String) {
        let req = {
            let mut st = self.dyn_state.lock().unwrap();
            let idx = st.pending.iter().position(|p| p.id_hex == id_hex);
            idx.map(|i| st.pending.remove(i))
        };
        if let Some(req) = req {
            // Approving IS a deliberate re-add — clear any old removal tombstone or their hellos
            // stay dropped (handshake guard) and self-sync re-severs them on every pass.
            self.clear_circle_removal(DEFAULT_CIRCLE, &req.id_hex);
            self.accept_contact(DEFAULT_CIRCLE, &req.bundle, &req.id_hex, &req.name, &req.verify_hex, true);
            self.emit_changed();
        }
    }

    pub fn dismiss(self: &Arc<Self>, id_hex: String) {
        self.dyn_state.lock().unwrap().pending.retain(|p| p.id_hex != id_hex);
        self.emit_changed();
    }

    pub fn contacts(&self) -> Vec<Contact> {
        self.prefs.lock().unwrap().contacts.clone()
    }

    pub fn blocked(&self) -> Vec<String> {
        self.prefs.lock().unwrap().blocked.clone()
    }

    pub fn block(self: &Arc<Self>, id_hex: String) {
        self.social.block_member(id_hex.clone());
        {
            let mut p = self.prefs.lock().unwrap();
            p.contacts.retain(|c| c.id_hex != id_hex);
            if !p.blocked.contains(&id_hex) {
                p.blocked.push(id_hex.clone());
            }
            let _ = p.save(&self.paths);
        }
        self.dyn_state.lock().unwrap().pending.retain(|r| r.id_hex != id_hex);
        self.persist();
        self.emit_changed();
    }

    pub fn unblock(self: &Arc<Self>, id_hex: String) {
        let mut p = self.prefs.lock().unwrap();
        p.blocked.retain(|b| *b != id_hex);
        let _ = p.save(&self.paths);
    }

    fn accept_contact(self: &Arc<Self>, circle_id: &str, bundle: &[u8], id_hex: &str, name: &str, verify_hex: &str, hello_back: bool) {
        let _ = self.social.add_contact_bundle(circle_id.to_string(), bundle.to_vec());
        {
            let mut p = self.prefs.lock().unwrap();
            if !p.contacts.iter().any(|c| c.id_hex == id_hex) {
                p.contacts.push(Contact {
                    id_hex: id_hex.to_string(),
                    name: name.to_string(),
                    verify_hex: verify_hex.to_string(),
                });
            }
            let _ = p.save(&self.paths);
        }
        self.persist();
        if hello_back {
            self.send_hello(circle_id, id_hex);
            // I'm the accepter sharing history → make sure the relay holds it ASAP so the new member
            // can pull it from the relay if the direct back-fill doesn't reach them.
            let me = self.clone();
            let cid = circle_id.to_string();
            tauri::async_runtime::spawn(async move { me.backfill_history_to_relay(&cid).await; });
        }
    }

    /// Ensure the relay holds this circle's FULL history (every event + every media blob I hold, not
    /// just my own) ASAP, so a newly-added member who can't receive it directly can pull it from the
    /// relay — no fragmented posts. Parity with iOS/Android. No-op without a mailbox.
    async fn backfill_history_to_relay(self: &Arc<Self>, circle_id: &str) {
        let has_relay = !self.relays_for(circle_id).is_empty();
        let has_s3 = self.prefs.lock().unwrap().s3.is_some();
        if !has_relay && !has_s3 {
            return;
        }
        for env in self.social.sync_envelopes(circle_id.to_string()) {
            self.upload_event(circle_id, &env).await;
        }
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        let mut refs: Vec<String> = vec![];
        for item in feed {
            for r in item.media {
                if !refs.contains(&r) {
                    refs.push(r);
                }
            }
            for cm in item.comments {
                for r in cm.media {
                    if !refs.contains(&r) {
                        refs.push(r);
                    }
                }
            }
        }
        for r in refs {
            if self.media.has(&r) {
                self.upload_media(circle_id, &r).await;
            }
        }
    }

    /// Resolve a feed item's short author id (8 hex) to a contact's display name.
    pub fn display_name(&self, author_short: &str) -> String {
        let p = self.prefs.lock().unwrap();
        p.contacts
            .iter()
            .find(|c| c.id_hex.starts_with(author_short))
            .map(|c| c.name.clone())
            .unwrap_or_else(|| {
                if author_short.len() >= 6 {
                    format!("Someone ({})", &author_short[..6])
                } else {
                    author_short.to_string()
                }
            })
    }

    // ---- outbound helpers ---------------------------------------------------------------

    fn hello_payload(&self, circle_id: &str) -> Option<Vec<u8>> {
        let profile = self.prefs.lock().unwrap().profile.clone();
        let name = if profile.name.trim().is_empty() { "Someone".to_string() } else { profile.name.clone() };
        let circle_name = self
            .social
            .circles()
            .into_iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.name)
            .unwrap_or_else(|| "My Circle".to_string());
        let bundle = self.social.my_bundle();
        // Avatar is left out of the Hello (keeps it small, matches Android); it travels in-app.
        let signed = self.social.my_signed_profile(name, profile.bio, profile.link, String::new(), profile.emoji);
        Some(wire::hello_payload(circle_id, &circle_name, &bundle, &signed))
    }

    /// Send our Hello + back-fill this circle's events to one node.
    fn send_hello(self: &Arc<Self>, circle_id: &str, to_node_hex: &str) {
        let Some(hello) = self.hello_payload(circle_id) else { return };
        self.send_frame(wire::HELLO, &hello, to_node_hex);
        for env in self.social.sync_envelopes(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &wire::event_payload(circle_id, &env), to_node_hex);
        }
        // Tell this peer about every relay I know for the circle, so we share all mailboxes.
        for node_hex in self.relays_for(circle_id) {
            if let Ok(sealed) = self.social.seal_circle_media(circle_id.to_string(), node_hex.into_bytes()) {
                self.send_frame(wire::RELAY_NODE, &wire::event_payload(circle_id, &sealed), to_node_hex);
            }
        }
    }

    pub fn sync_with_contacts(self: &Arc<Self>) {
        let ids: Vec<String> = self.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
        for id_hex in &ids {
            self.send_hello(DEFAULT_CIRCLE, id_hex);
        }
        // Proactively announce MY device roster (frame 27) every greet cycle — under device-id
        // transport a friend can only dial + authorize this desktop once they hold its signed
        // roster (iOS/Android parity; small, signed, receiver version-checks + dedups).
        let roster_wire = self.social.my_device_roster_wire();
        if !roster_wire.is_empty() {
            for id_hex in &ids {
                self.send_frame(wire::DEVICE_ROSTER, &roster_wire, id_hex);
            }
            // Bootstrap the device-id exchange over the RELAY too: when a friend flips to the
            // per-device transport their account id stops resolving, so a direct send can't carry
            // my roster — but their relay node IS reachable. Never announce to ourselves (a
            // self-dial sends iroh path discovery into the runaway loop).
            let my_acct = self.social.my_node_hex().to_lowercase();
            let my_dev = self.social.my_device_node_hex().to_lowercase();
            for c in self.social.circles() {
                for relay_hex in self.relays_for(&c.id) {
                    let h = relay_hex.to_lowercase();
                    if h == my_acct || h == my_dev || h.starts_with("s3:") {
                        continue;
                    }
                    self.send_frame(wire::DEVICE_ROSTER, &roster_wire, &relay_hex);
                }
            }
        }
        // Re-emit our own relay id whenever we re-greet contacts, so a peer that just came online surfaces
        // our relay instead of missing the one-shot announce.
        self.reannounce_own_relay();
    }

    fn send_frame(self: &Arc<Self>, t: u8, payload: &[u8], to_node_hex: &str) {
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let frame = wire::frame(t, payload);
        // Transport edge (parity with iOS sendIroh / Android sendFrame): callers address an ACCOUNT
        // id so the social/allow logic stays on account ids; expand to that account's authorized
        // DEVICE ids here — under device-seed transport the account id alone resolves to NO node.
        // device_node_ids_for is identity for an unknown/device-id input, so pre-expanded callers
        // stay correct.
        let mut targets = self.social.device_node_ids_for(to_node_hex.to_string());
        if targets.is_empty() {
            targets.push(to_node_hex.to_string());
        }
        // Invite-link dial hints bridge the roster bootstrap: until this contact's signed roster
        // lands, their account id resolves to no node — the hint is the only real id.
        for h in self.device_hints_for(to_node_hex) {
            if !targets.iter().any(|t| t.eq_ignore_ascii_case(&h)) {
                targets.push(h);
            }
        }
        for to in targets {
            let node = node.clone();
            let frame = frame.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = node.send_to_node(to.clone(), frame).await {
                    log::debug!("send type={t} to {} failed: {e}", &to.chars().take(8).collect::<String>());
                }
            });
        }
    }

    // ---- inbound dispatch ---------------------------------------------------------------

    fn dispatch(self: &Arc<Self>, payload: Vec<u8>) {
        self.dispatch_from(None, payload)
    }

    /// `sender_device` = the AUTHENTICATED transport id the frame arrived from (None when relayed/
    /// unknown). A direct HELLO teaches us a dialable device id for its account — the reply-path
    /// bootstrap (an invitee holds no invite hints for the initiator).
    fn dispatch_from(self: &Arc<Self>, sender_device: Option<String>, payload: Vec<u8>) {
        if payload.is_empty() {
            return;
        }
        let t = payload[0];
        let body = payload[1..].to_vec();
        // Call/media frames lead with a 64-char sender hex — drop blocked senders early.
        if matches!(t, wire::MEDIA_REQ | wire::CALL_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::GROUP_INVITE) {
            if body.len() >= 64 {
                let head = String::from_utf8_lossy(&body[..64]).into_owned();
                if head.len() == 64 && self.prefs.lock().unwrap().blocked.contains(&head) {
                    return;
                }
            }
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            me.dyn_state.lock().unwrap().internet_active = true;
            match t {
                wire::HELLO => me.handle_hello_from(sender_device.as_deref(), &body),
                wire::EVENT => me.handle_event(&body),
                wire::RELAY_NODE => me.handle_relay_node(&body).await,
                wire::MEDIA_REQ => me.handle_media_request(&body).await,
                wire::MEDIA_CHUNK => me.handle_media_chunk(&body),
                wire::CALL_INVITE | wire::GROUP_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP
                | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => me.handle_call(t, &body),
                wire::DEVICE_ENROLL => me.handle_enrollment_request(&body),
                wire::DEVICE_GRANT => me.handle_device_grant(&body),
                wire::DEVICE_ROSTER => me.handle_device_roster_announce(&body),
                wire::RELAY => me.handle_relay(&body),
                _ => log::debug!("ignoring frame type {t} (not yet handled)"),
            }
            me.emit_changed();
        });
    }

    fn handle_hello(self: &Arc<Self>, payload: &[u8]) {
        self.handle_hello_from(None, payload)
    }

    fn handle_hello_from(self: &Arc<Self>, sender_device: Option<&str>, payload: &[u8]) {
        let Some(hello) = wire::parse_hello(payload) else { return };
        let id_hex = wire::node_hex(&hello.bundle);
        if self.prefs.lock().unwrap().blocked.contains(&id_hex) {
            return;
        }
        // A hello delivered DIRECTLY teaches us the sender's dialable device id for this account —
        // the reply-path bootstrap. The signed roster (frame 27) supersedes; a hint can at worst
        // misroute sealed frames (they stay unreadable), same trust as invite-link hints.
        if let Some(dev) = sender_device {
            if dev.len() == 64 && !dev.eq_ignore_ascii_case(&id_hex) {
                self.record_device_hints(&id_hex, vec![dev.to_lowercase()]);
            }
        }
        let Ok(actual_verify) = self.social.bundle_verification_hex(hello.bundle.clone()) else { return };
        let name = self
            .social
            .verify_profile(hello.bundle.clone(), hello.signed_profile.clone())
            .unwrap_or_else(|| "Someone".to_string());

        if hello.circle_id.starts_with("dm:") && !Self::dm_allows(&hello.circle_id, &id_hex) {
            return;
        }
        // A member you explicitly removed from THIS circle must NOT auto-rejoin on their handshake
        // (parity with iOS/Android). Deliberate re-adds (approve / add_to_circle / connect_by_link)
        // clear the tombstone first, so this only blocks the unsolicited rejoin.
        if self.is_removed_from_circle(&hello.circle_id, &id_hex) {
            return;
        }
        self.social.create_circle(hello.circle_id.clone(), hello.circle_name.clone());

        let expected = self.dyn_state.lock().unwrap().initiated.get(&id_hex).cloned();
        if let Some(expected) = expected {
            if !expected.is_empty() && expected != actual_verify {
                log::warn!("verify mismatch for {id_hex} — dropping (possible MITM)");
                return;
            }
            self.accept_contact(&hello.circle_id, &hello.bundle, &id_hex, &name, &actual_verify, true);
            self.dyn_state.lock().unwrap().initiated.remove(&id_hex);
            return;
        }
        if self.prefs.lock().unwrap().contacts.iter().any(|c| c.id_hex == id_hex) {
            let _ = self.social.add_contact_bundle(hello.circle_id.clone(), hello.bundle.clone());
            return;
        }
        if !hello.circle_id.starts_with("dm:") {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.pending.iter().any(|p| p.id_hex == id_hex) {
                st.pending.push(PendingRequest { id_hex, name, verify_hex: actual_verify, bundle: hello.bundle });
            }
        }
    }

    fn handle_event(self: &Arc<Self>, payload: &[u8]) {
        let Some(ev) = wire::parse_event(payload) else { return };
        let changed = self.social.receive(ev.circle_id.clone(), ev.envelope).unwrap_or(false);
        if changed {
            self.persist();
            self.emit_changed();
            self.request_missing_media();
            let is_dm = ev.circle_id.starts_with("dm:");
            self.notify(
                if is_dm { "New message" } else { "New in your circle" },
                if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
            );
        }
    }

    // ---- relay / mailbox ----------------------------------------------------------------

    async fn handle_relay_node(self: &Arc<Self>, body: &[u8]) {
        let mut r = wire::Reader::new(body);
        let Some(cid) = r.lp() else { return };
        let circle_id = String::from_utf8_lossy(&cid).into_owned();
        let sealed = r.rest();
        if circle_id.is_empty() || sealed.is_empty() {
            return;
        }
        let Some(opened) = self.social.open_circle_media_sender(circle_id.clone(), sealed) else { return };
        let announcer_hex = opened.sender_hex.to_lowercase(); // authenticated envelope sender (account id)
        let text = String::from_utf8_lossy(&opened.data).trim().to_string();
        // Extended announce: JSON {node, urls, token} also carries the relay's plain-HTTP media
        // interface (the reliable cross-NAT path). Legacy announces are the bare 64-hex id.
        let mut announced_urls: Vec<String> = Vec::new();
        let mut announced_token = String::new();
        let node_hex = if text.starts_with('{') {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return };
            announced_urls = v["urls"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|u| u.as_str())
                        .filter(|u| u.starts_with("http"))
                        .map(|u| u.to_string())
                        .collect()
                })
                .unwrap_or_default();
            announced_token = v["token"].as_str().unwrap_or_default().to_string();
            v["node"].as_str().unwrap_or_default().trim().to_lowercase()
        } else {
            text.to_lowercase()
        };
        if node_hex.len() != 64 {
            return;
        }
        {
            // A contact RE-ANNOUNCED a circle relay. Reactivating a deactivated/forgotten entry is
            // allowed ONLY when the announce comes from the relay's OWNER — the announced id is one of
            // the sender's own authorized device ids (their in-app relay; that's what lets your PC's
            // relay come back on your phone when the PC itself re-announces it), or their account id
            // (legacy account-id relay). A THIRD-PARTY echo must never resurrect it: every member
            // re-announces every relay they hold proof-of-life for, so a relay the user deliberately
            // deleted — but which is still RUNNING somewhere (an old docker container, a forgotten
            // daemon) — bounced back within one sync tick, forever. Non-owner announces of a tombstoned
            // relay are dropped; brand-new relays still auto-pool below. iOS/Android parity.
            let announcer_owns_relay = node_hex == announcer_hex
                || self
                    .social
                    .device_node_ids_for(announcer_hex.clone())
                    .iter()
                    .any(|d| d.to_lowercase() == node_hex);
            let mut p = self.prefs.lock().unwrap();
            let was_suppressed_or_inactive =
                p.suppressed_relays.contains(&node_hex) || !p.relay_is_active(&node_hex);
            if was_suppressed_or_inactive && !announcer_owns_relay {
                return;
            }
            if was_suppressed_or_inactive {
                p.suppressed_relays.retain(|h| h != &node_hex);
                p.ensure_relay_entry(&node_hex, None, node_hex.starts_with("s3:"), true);
            } else {
                p.ensure_relay_entry(&node_hex, None, node_hex.starts_with("s3:"), false);
            }
            let list = p.relays.entry(circle_id.clone()).or_default();
            if !list.contains(&node_hex) {
                list.push(node_hex.clone());
            }
            // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
            if !announced_urls.is_empty() && !announced_token.is_empty() {
                p.set_relay_http(&node_hex, announced_urls.clone(), announced_token.clone());
            }
            let _ = p.save(&self.paths);
            // Clear any stale backoff so a just-reactivated relay is retried immediately.
            if was_suppressed_or_inactive {
                drop(p);
                self.relay_health.lock().unwrap().remove(&node_hex);
            }
        }
        self.backfill_mailbox(&circle_id).await;
        self.poll_mailbox().await;
    }

    pub fn relay_status(&self) -> (bool, bool, bool, bool, bool) {
        let st = self.dyn_state.lock().unwrap();
        let prefs = self.prefs.lock().unwrap();
        // Only ACTIVE relays count — a fully-deactivated set means "no relay" even though configs linger.
        let has_relay = prefs
            .relays
            .values()
            .flatten()
            .any(|h| prefs.relay_is_active(h))
            || (!prefs.default_relay.is_empty() && prefs.relay_is_active(&prefs.default_relay))
            || prefs.s3.is_some();
        (st.hosting, has_relay, st.relay_active, st.internet_active, st.started)
    }

    /// The relay's node id (64-hex), which a friend pastes into "Adopt relay" so we share a
    /// mailbox. `None` unless we're currently hosting.
    pub fn relay_link(&self) -> Option<String> {
        self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex())
    }

    /// Start serving the circle's mailbox from this device + adopt it for every circle.
    pub async fn start_hosting(self: &Arc<Self>) -> Result<String> {
        {
            if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                return Ok(h.node_id_hex());
            }
        }
        // Attach the relay to the EXISTING messaging node's endpoint (one iroh node, two ALPNs) — a
        // second in-process iroh node made iroh churn paths unboundedly (the tens-of-GB leak). The relay
        // id is therefore the account node id.
        let Some(node) = self.node.lock().unwrap().clone() else {
            return Err(anyhow::anyhow!("relay host: messaging node not started yet"));
        };
        let dir = self.paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();
        let handle = RelayServerHandle::attach(node, dir.to_string_lossy().to_string());
        let node_hex = handle.node_id_hex();
        *self.relay_host.lock().unwrap() = Some(handle.clone());
        self.dyn_state.lock().unwrap().hosting = true;
        // Lock the mailbox to circle members before announcing it (audit transport-F4).
        self.authorize_membership();
        // Plain-HTTP media interface — the DEFAULT cross-NAT media transport (the iroh blob ALPN
        // drops datagrams on pure-relay cross-NAT paths). Token-gated; the token travels only
        // inside the sealed frame-19 announce.
        self.start_relay_http(&handle, &node_hex).await;
        self.adopt_relay(node_hex.clone()).await;
        self.emit_changed();
        Ok(node_hex)
    }

    /// Serve the hosted relay's store over HTTP and record our URLs+token on our own RelayEntry so
    /// every announce carries them. URLs = the optional configured public URL first, then the LAN IP.
    async fn start_relay_http(self: &Arc<Self>, handle: &Arc<RelayServerHandle>, node_hex: &str) {
        let token = {
            let mut p = self.prefs.lock().unwrap();
            if p.relay_http_token.is_empty() {
                use rand::RngCore;
                let mut bytes = [0u8; 16];
                rand::rngs::OsRng.fill_bytes(&mut bytes);
                p.relay_http_token = bytes.iter().map(|b| format!("{b:02x}")).collect();
                let _ = p.save(&self.paths);
            }
            p.relay_http_token.clone()
        };
        let port = match handle.serve_http("0.0.0.0:8674".into(), token.clone()).await {
            Ok(p) => p,
            Err(_) => match handle.serve_http("0.0.0.0:0".into(), token.clone()).await {
                Ok(p) => p,
                Err(e) => {
                    log::warn!("relay http serve failed: {e}");
                    return;
                }
            },
        };
        let mut urls = Vec::new();
        {
            let p = self.prefs.lock().unwrap();
            if p.relay_public_url.starts_with("http") {
                urls.push(p.relay_public_url.trim_end_matches('/').to_string());
            }
        }
        if let Some(ip) = Self::primary_lan_ip() {
            urls.push(format!("http://{ip}:{port}"));
        }
        log::info!("relay http on :{port} urls={urls:?}");
        if urls.is_empty() {
            return;
        }
        let mut p = self.prefs.lock().unwrap();
        if p.set_relay_http(node_hex, urls, token) {
            let _ = p.save(&self.paths);
        }
    }

    /// This machine's primary LAN IPv4 (UDP-connect trick — no packet is actually sent).
    fn primary_lan_ip() -> Option<String> {
        let s = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
        s.connect("8.8.8.8:80").ok()?;
        let ip = s.local_addr().ok()?.ip();
        if ip.is_loopback() {
            return None;
        }
        Some(ip.to_string())
    }

    /// The frame-19 announce body for one relay: the legacy bare 64-hex node id, or — once the
    /// relay's plain-HTTP interface is known — JSON `{"node":hex,"urls":[…],"token":…}` so members
    /// also learn the reliable cross-NAT media path. A legacy receiver ignores the JSON form.
    fn relay_announce_body(&self, hex: &str) -> Vec<u8> {
        if let Some((urls, token)) = self.prefs.lock().unwrap().relay_http(hex) {
            if let Ok(json) = serde_json::to_vec(&serde_json::json!({
                "node": hex, "urls": urls, "token": token,
            })) {
                return json;
            }
        }
        hex.as_bytes().to_vec()
    }

    /// A contact's signed device roster (frame 27): learn which DEVICE ids to dial/seal for them,
    /// then re-authorize our hosted relay so those devices can read their mailboxes (iOS/Android
    /// parity — without this a friend's device-seed phone stays "forbidden" at this relay).
    fn handle_device_roster_announce(self: &Arc<Self>, body: &[u8]) {
        if self.social.ingest_roster_wire(body.to_vec()) {
            self.persist();
            self.authorize_membership();
        }
    }

    /// Push current circle membership to the in-process relay so each circle's mailbox is served ONLY
    /// to its members (+ sibling relays for mesh sync) — a stranger who learns the relay id gets
    /// nothing (audit transport-F4). Idempotent; call on host start and whenever membership changes.
    pub fn authorize_membership(self: &Arc<Self>) {
        let Some(handle) = self.relay_host.lock().unwrap().clone() else { return };
        let me = self.social.my_node_hex();
        for c in self.social.circles() {
            let mut accounts = self.social.contact_node_ids(c.id.clone());
            if !me.is_empty() && !accounts.contains(&me) {
                accounts.push(me.clone());
            }
            // Authorize each member at the TRANSPORT layer by their DEVICE ids (peers connect as
            // their device under device-seed transport), keeping the account id too for any
            // pre-multidevice peer. Includes MY OWN device ids so a sibling device can read this
            // host's mailbox. De-duplicated. Parity with iOS circleMemberships().
            let mut members: Vec<String> = Vec::new();
            for a in &accounts {
                if !members.contains(a) {
                    members.push(a.clone());
                }
                for d in self.social.device_node_ids_for(a.clone()) {
                    if !members.contains(&d) {
                        members.push(d);
                    }
                }
            }
            let relays = self.relays_for(&c.id);
            handle.authorize_circle(c.id.clone(), members, relays);
        }
    }

    pub fn stop_hosting(self: &Arc<Self>) {
        *self.relay_host.lock().unwrap() = None;
        self.dyn_state.lock().unwrap().hosting = false;
        self.emit_changed();
    }

    /// Re-emit THIS host's own relay id (frame 19) to every circle's contacts, WITHOUT adopt_relay's heavy
    /// backfill. Frame 19 used to fire only once at relay start, so a sibling/friend that wasn't reachable
    /// at that instant never learned the relay (the iPhone "sees the PC but won't show its relay"). Cheap
    /// (one sealed announce per circle per contact), so it's safe to run every sync tick. No-op unless we're
    /// hosting. (Desktop has no nearby/Bluetooth mesh, so this is the iroh-only subset of the iOS fix.)
    pub fn reannounce_own_relay(self: &Arc<Self>) {
        // Re-emit EVERY relay this device knows for each circle — not just the one it hosts. A
        // frame-19 announce used to fire once at relay start / adopt time, so a member who wasn't
        // reachable at that instant never learned an adopted EXTERNAL relay (NAS docker daemon).
        // Android re-announces all circle relays per hello; this is that parity (iOS too).
        let own_hex = self
            .relay_host
            .lock()
            .unwrap()
            .as_ref()
            .map(|h| h.node_id_hex())
            .filter(|h| h.len() == 64);
        for c in self.social.circles() {
            // ONLY announce relays WE have proof of life for (a successful op within 5 min) or the
            // one we host. Re-announcing everything ever LEARNED made dead relay ids echo around
            // the mesh forever (each member re-broadcast them; receivers reactivated them).
            let now = now_ms();
            let mut hexes: Vec<String> = {
                let p = self.prefs.lock().unwrap();
                let health = self.relay_health.lock().unwrap();
                p.relays
                    .get(&c.id)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|h| {
                        h.len() == 64
                            && !h.starts_with("s3:")
                            && p.relay_is_active(h)
                            && health.get(h).map(|hh| hh.proven_alive(now, 300_000)).unwrap_or(false)
                    })
                    .collect()
            };
            if let Some(own) = &own_hex {
                if !hexes.iter().any(|h| h == own) {
                    hexes.push(own.clone());
                }
            }
            if hexes.is_empty() {
                continue;
            }
            let members = self.social.contact_node_ids(c.id.clone());
            for hex in &hexes {
                let body = self.relay_announce_body(hex);
                let Ok(sealed) = self.social.seal_circle_media(c.id.clone(), body.clone()) else { continue };
                let frame = wire::event_payload(&c.id, &sealed);
                for id_hex in &members {
                    self.send_frame(wire::RELAY_NODE, &frame, id_hex);
                }
            }
        }
    }

    /// Periodically mirror MY OWN media to every circle relay I know (idempotent backup). The cross-device
    /// chunk request/response path is unreliable, so instead each device durably mirrors its own media to
    /// the relays it knows — including a sibling's hosted relay — and the other side reads it back during
    /// its normal poll/restore. upload_media is content-addressed + idempotent (re-puts are cheap), so this
    /// just fills gaps. Throttled to ~once per 2 min by the caller.
    async fn backfill_media_to_relays(self: &Arc<Self>) {
        let circle_ids: Vec<String> = self.social.circles().into_iter().map(|c| c.id).collect();
        for circle_id in circle_ids {
            let has_relay = !self.relays_for(&circle_id).is_empty();
            let has_s3 = self.prefs.lock().unwrap().s3.is_some();
            if !has_relay && !has_s3 {
                continue;
            }
            let feed = self.social.feed(circle_id.clone(), now_ms(), None);
            let mut refs: Vec<String> = vec![];
            for item in feed {
                if !item.is_me {
                    continue; // only MY media — others' media is mirrored by their own devices
                }
                for r in item.media {
                    if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && !refs.contains(&r) {
                        refs.push(r);
                    }
                }
                for cm in item.comments {
                    for r in cm.media {
                        if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && !refs.contains(&r) {
                            refs.push(r);
                        }
                    }
                }
            }
            for r in refs {
                self.upload_media(&circle_id, &r).await;
            }
        }
    }

    /// Adopt a relay node for all circles (ADDED to the redundant set, not replacing existing
    /// relays) + tell contacts via frame 19. Adopt several for redundancy.
    pub async fn adopt_relay(self: &Arc<Self>, node_hex: String) {
        let hex = node_hex.trim().to_lowercase();
        if hex.len() != 64 {
            return;
        }
        {
            // Explicit adoption overrides a prior Forget AND reactivates the entry — re-adding a
            // previously-deactivated relay always works. Mirrors iOS `add(circleId:nodeHex:)`.
            let mut p = self.prefs.lock().unwrap();
            p.suppressed_relays.retain(|h| h != &hex);
            p.ensure_relay_entry(&hex, None, false, true);
            let _ = p.save(&self.paths);
        }
        for c in self.social.circles() {
            {
                let mut p = self.prefs.lock().unwrap();
                let list = p.relays.entry(c.id.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
                let _ = p.save(&self.paths);
            }
            if let Ok(sealed) = self.social.seal_circle_media(c.id.clone(), self.relay_announce_body(&hex)) {
                let frame = wire::event_payload(&c.id, &sealed);
                for id_hex in self.social.contact_node_ids(c.id.clone()) {
                    self.send_frame(wire::RELAY_NODE, &frame, &id_hex);
                }
            }
            self.backfill_mailbox(&c.id).await;
        }
        self.poll_mailbox().await;
    }

    /// Normalize a relay hex: lower/trim a Haven node id, but leave a synthetic `s3:<bucket>` id as-is.
    fn norm_relay_hex(node_hex: &str) -> String {
        if node_hex.starts_with("s3:") {
            node_hex.to_string()
        } else {
            node_hex.trim().to_lowercase()
        }
    }

    /// DEACTIVATE a relay across EVERY circle (the old "forget" entry point, now non-destructive):
    /// flip active=false, KEEP its name + circle associations, suppress auto-relearn while inactive, and
    /// drop its cached connection + health. The config survives so it can be reactivated later.
    /// `relays_for` already filters inactive entries out, so it stops being dialed/served immediately.
    /// Mirrors iOS `forget(nodeHex:)`.
    pub async fn forget_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            let is_s3 = hex.starts_with("s3:");
            p.ensure_relay_entry(&hex, None, is_s3, false);
            if let Some(e) = p.relay_entries.get_mut(&hex) {
                e.active = false;
            }
            if !p.suppressed_relays.contains(&hex) {
                p.suppressed_relays.push(hex.clone());
            }
            let _ = p.save(&self.paths);
        }
        self.relay_clients.lock().await.remove(&hex);
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// Reactivate a deactivated relay: flip active=true and clear its suppression + backoff so it's
    /// dialed again. Mirrors iOS `reactivate`.
    pub async fn reactivate_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            p.suppressed_relays.retain(|h| h != &hex);
            p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
            let _ = p.save(&self.paths);
        }
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// Rename a relay (user-facing label only). Mirrors iOS `rename`.
    pub fn rename_relay(self: &Arc<Self>, node_hex: String, name: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return;
        }
        let mut p = self.prefs.lock().unwrap();
        if let Some(e) = p.relay_entries.get_mut(&hex) {
            e.name = trimmed.to_string();
            let _ = p.save(&self.paths);
            drop(p);
            self.emit_changed();
        }
    }

    /// Pick the all-circles default relay (every present + future circle inherits it). Empty = unset.
    /// Mirrors iOS `setDefault`.
    pub fn set_default_relay(self: &Arc<Self>, node_hex: String) {
        let mut p = self.prefs.lock().unwrap();
        if node_hex.is_empty() {
            p.default_relay.clear();
        } else {
            let hex = Self::norm_relay_hex(&node_hex);
            p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
            p.default_relay = hex;
        }
        let _ = p.save(&self.paths);
        drop(p);
        self.emit_changed();
    }

    /// ERASE a relay for good — removes its associations across every circle, its entry, the default, and
    /// its caches. Used by "Delete now" + purge_stale. Mirrors iOS `eraseNow`.
    pub async fn erase_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            for list in p.relays.values_mut() {
                list.retain(|h| h != &hex);
            }
            p.relays.retain(|_, v| !v.is_empty());
            if p.default_relay == hex {
                p.default_relay.clear();
            }
            p.relay_entries.remove(&hex);
            if !p.suppressed_relays.contains(&hex) {
                p.suppressed_relays.push(hex.clone());
            }
            let _ = p.save(&self.paths);
        }
        self.relay_clients.lock().await.remove(&hex);
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// ERASE only relays that are BOTH inactive AND unseen for > 7 days. An ACTIVE relay that's merely
    /// unreachable is never purged. Called on launch + on the sync timer. Mirrors iOS `purgeStale`.
    pub async fn purge_stale_relays(self: &Arc<Self>) {
        let dead = self.prefs.lock().unwrap().stale_relay_hexes();
        for hex in dead {
            self.erase_relay(hex).await;
        }
    }

    /// Add or remove a single relay's ASSOCIATION with exactly one circle (the per-circle override).
    /// Mirrors iOS `setCircleRelay`.
    pub async fn set_circle_relay(self: &Arc<Self>, node_hex: String, circle_id: String, on: bool) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            if on {
                p.suppressed_relays.retain(|h| h != &hex);
                p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
                let list = p.relays.entry(circle_id.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
            } else if let Some(list) = p.relays.get_mut(&circle_id) {
                list.retain(|h| h != &hex);
                if list.is_empty() {
                    p.relays.remove(&circle_id);
                }
            }
            let _ = p.save(&self.paths);
        }
        if on {
            self.backfill_mailbox(&circle_id).await;
        }
        self.poll_mailbox().await;
        self.emit_changed();
    }

    /// Add an S3 bucket as a (store-and-forward) relay: validate + persist its creds (secret → keychain
    /// via the existing s3_configure path), record an `s3:<bucket>` RelayEntry so it shows in the Relays
    /// list, associate it with every circle, and optionally make it the default. Returns its synthetic id.
    /// Mirrors iOS `addS3Relay`.
    pub async fn add_s3_relay(
        self: &Arc<Self>,
        pub_cfg: store::S3Public,
        secret_key: String,
        name: String,
        set_default: bool,
    ) -> Result<String> {
        let bucket = pub_cfg.bucket.clone();
        let hex = format!("s3:{bucket}");
        // s3_configure validates connectivity, stores the secret in the keychain, and sets prefs.s3.
        self.s3_configure(pub_cfg, secret_key).await?;
        {
            let mut p = self.prefs.lock().unwrap();
            let label = if name.trim().is_empty() { format!("S3 · {bucket}") } else { name.trim().to_string() };
            p.ensure_relay_entry(&hex, Some(&label), true, true);
            for c in self.social.circles() {
                let list = p.relays.entry(c.id).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
            }
            if set_default {
                p.default_relay = hex.clone();
            }
            let _ = p.save(&self.paths);
        }
        for c in self.social.circles() {
            self.backfill_mailbox(&c.id).await;
        }
        self.poll_mailbox().await;
        self.emit_changed();
        Ok(hex)
    }

    /// Full per-relay detail (active + inactive) for the Relays hub. One row per configured RelayEntry,
    /// sorted active-first then by name. Mirrors iOS `allEntries`.
    pub fn relays_detail(&self) -> Vec<RelayDetail> {
        let now = now_ms();
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        let prefs = self.prefs.lock().unwrap();
        let health = self.relay_health.lock().unwrap();
        let mut out: Vec<RelayDetail> = prefs
            .relay_entries
            .values()
            .map(|e| RelayDetail {
                node_hex: e.hex.clone(),
                name: e.name.clone(),
                active: e.active,
                is_s3: e.is_s3,
                is_default: prefs.default_relay == e.hex,
                hosted: hosted.as_deref() == Some(e.hex.as_str()),
                reachable: health.get(&e.hex).map(|h| h.available(now)).unwrap_or(true),
            })
            .collect();
        out.sort_by(|a, b| match (a.active, b.active) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        });
        out
    }

    /// The set of relay hexes explicitly associated with a circle (INCLUDING inactive) — for the
    /// per-circle override toggles. Mirrors iOS `explicitRelays(forCircle:)`.
    pub fn circle_relay_hexes(&self, circle_id: &str) -> Vec<String> {
        self.prefs.lock().unwrap().relays.get(circle_id).cloned().unwrap_or_default()
    }

    /// The redundant ACTIVE relay set for a circle (mirrored writes, fallback reads). Deactivated relays
    /// are filtered out so they aren't dialed/served, but their config survives. Includes the all-circles
    /// default. Mirrors iOS `relays(forCircle:)`.
    fn relays_for(&self, circle_id: &str) -> Vec<String> {
        self.prefs.lock().unwrap().active_relays_for(circle_id)
    }

    fn relay_available(&self, node_hex: &str) -> bool {
        let now = now_ms();
        self.relay_health.lock().unwrap().get(node_hex).map(|h| h.available(now)).unwrap_or(true)
    }

    fn mark_relay_ok(&self, node_hex: &str) {
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_success_at(now_ms());
        // Stamp the relay's last-seen so purge_stale never reaps a relay that's actually working, and
        // an inactive relay's stale-clock only counts time since it last succeeded. Mirrors iOS markSeen.
        let mut p = self.prefs.lock().unwrap();
        if p.relay_entries.contains_key(node_hex) {
            p.relay_mark_seen(node_hex);
            let _ = p.save(&self.paths);
        }
    }

    fn mark_relay_fail(&self, node_hex: &str) {
        let now = now_ms();
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_failure(now);
    }

    async fn relay_client_for(self: &Arc<Self>, node_hex: &str) -> Option<Arc<RelayClient>> {
        // An `s3:<bucket>` relay is a store-and-forward bucket, NOT a dialable iroh node — it's served
        // by the separate `s3_client()` path in upload_event/backfill. Never try to iroh-dial it.
        if node_hex.starts_with("s3:") {
            return None;
        }
        {
            let clients = self.relay_clients.lock().await;
            if let Some(c) = clients.get(node_hex) {
                return Some(c.clone());
            }
        }
        // NEVER dial our OWN node ids (account id — a pre-device-seed leftover in a relay list — or
        // our device id). A self-dial sends iroh's path discovery into a tight loop
        // (open_path_on_all_conns), exploding memory by tens of GB — THE runaway leak. We never need
        // a client to ourselves. Same root cause + fix as iOS/macOS.
        if self.social.my_node_hex().eq_ignore_ascii_case(node_hex)
            || self.social.my_device_node_hex().eq_ignore_ascii_case(node_hex)
        {
            return None;
        }
        if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
            if h.node_id_hex() == node_hex {
                return None;
            }
        }
        // Skip a relay that's in its backoff window — try the others instead.
        if !self.relay_available(node_hex) {
            return None;
        }
        // Warm path (parity with iOS): dial over the messaging node's LONG-LIVED, DERP-established
        // endpoint instead of RelayClient::connect binding a fresh endpoint per client — the cold
        // endpoint restarts DERP discovery every time, which is exactly the cross-NAT 30s timeout
        // while messaging on the same relay path works.
        let warm = self.node.lock().unwrap().clone().and_then(|n| n.relay_client(node_hex.to_string()).ok());
        let res = match warm {
            Some(c) => Ok(c),
            // No messaging node yet → cold connect under the DEVICE seed (never the account seed:
            // the account id is identity-only and must not appear as a transport node).
            None => {
                let device_seed = self.roster.lock().unwrap().device_seed.clone();
                RelayClient::connect(device_seed, node_hex.to_string()).await
            }
        };
        match res {
            Ok(c) => {
                self.relay_clients.lock().await.insert(node_hex.to_string(), c.clone());
                Some(c)
            }
            Err(e) => {
                log::debug!("relay connect failed ({node_hex}): {e}");
                self.mark_relay_fail(node_hex);
                None
            }
        }
    }

    /// On a put/list/get failure: back the relay off and drop its cached connection.
    async fn relay_failed(self: &Arc<Self>, node_hex: &str) {
        self.mark_relay_fail(node_hex);
        self.relay_clients.lock().await.remove(node_hex);
    }

    fn mailbox_key(circle_id: &str, env: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(env);
        let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        format!("haven/mailbox/{circle_id}/{hex}")
    }

    /// Record a mailbox key as ingested/uploaded; [`Self::flush_seen_mailbox`] persists the set
    /// (call it once after a poll/backfill pass) so the cursor survives restarts.
    fn mark_mailbox_seen(&self, key: String) {
        let mut st = self.dyn_state.lock().unwrap();
        if st.seen_mailbox.insert(key) {
            st.seen_mailbox_dirty = true;
        }
    }
    fn flush_seen_mailbox(&self) {
        let snapshot = {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.seen_mailbox_dirty {
                return;
            }
            st.seen_mailbox_dirty = false;
            st.seen_mailbox.iter().cloned().collect::<Vec<_>>().join("\n")
        };
        let _ = std::fs::write(self.paths.root.join("mailbox-seen.txt"), snapshot);
    }

    /// Build (and cache) the BYO S3 mailbox client from prefs + the keychain secret, if configured.
    async fn s3_client(self: &Arc<Self>) -> Option<Arc<S3Mailbox>> {
        if let Some(c) = self.s3.lock().await.as_ref() {
            return Some(c.clone());
        }
        let pub_cfg = self.prefs.lock().unwrap().s3.clone()?;
        let secret = store::load_s3_secret()?;
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint,
            region: pub_cfg.region,
            bucket: pub_cfg.bucket,
            access_key: pub_cfg.access_key,
            secret_key: secret,
            prefix: pub_cfg.prefix,
        };
        let client = Arc::new(S3Mailbox::new(cfg).ok()?);
        *self.s3.lock().await = Some(client.clone());
        Some(client)
    }

    async fn upload_event(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        let key = Self::mailbox_key(circle_id, env);
        // Skip anything already confirmed in a mailbox: event envelopes re-seal deterministically
        // now, so a backfill reproduces the same content-addressed key and the persisted seen-set
        // turns the whole re-upload into a no-op instead of a network sweep.
        if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
            return;
        }
        let mut landed = false;
        // 1) Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        //    re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        for node_hex in self.relays_for(circle_id) {
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if hosted.as_deref() == Some(node_hex.as_str()) {
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    h.local_put(key.clone(), env.to_vec());
                    self.dyn_state.lock().unwrap().relay_active = true;
                    landed = true;
                }
                continue;
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                match client.put(key.clone(), env.to_vec()).await {
                    Ok(()) => {
                        self.mark_relay_ok(&node_hex);
                        self.dyn_state.lock().unwrap().relay_active = true;
                        landed = true;
                    }
                    Err(e) => {
                        log::debug!("mailbox put failed ({node_hex}): {e}");
                        self.relay_failed(&node_hex).await;
                    }
                }
            }
        }
        // 2) BYO S3 bucket — an additional, independent mailbox (also idempotent).
        if let Some(s3) = self.s3_client().await {
            if s3.put(&key, env).await.is_ok() {
                self.dyn_state.lock().unwrap().relay_active = true;
                landed = true;
            }
        }
        if landed {
            self.mark_mailbox_seen(key);
        }
    }

    async fn backfill_mailbox(self: &Arc<Self>, circle_id: &str) {
        let has_relay = !self.relays_for(circle_id).is_empty();
        let has_s3 = self.prefs.lock().unwrap().s3.is_some();
        if !has_relay && !has_s3 {
            return;
        }
        let envs = self.social.export_my_envelopes(circle_id.to_string());
        for env in &envs {
            self.upload_event(circle_id, env).await;
        }
        // TOUCH the same refs on every relay so mailbox GC keeps them (upload_event is
        // seen-set-skipped once an envelope landed ONCE — without this, nothing would ever
        // refresh a live entry and the relay's 30-day TTL would eat real history). Misses
        // are re-PUT inside, so the refresh also repairs a relay that lost our entries.
        self.refresh_mailbox(circle_id, &envs).await;
        self.flush_seen_mailbox();
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        for item in feed {
            if item.is_me {
                for r in item.media {
                    if self.media.has(&r) {
                        self.upload_media(circle_id, &r).await;
                    }
                }
            }
        }
    }

    /// Refresh the liveness of `envs` (my deterministically re-sealed envelopes) on every iroh
    /// relay serving `circle_id` — ONE batched TOUCH per relay bumps their mailbox-GC clocks;
    /// the relay replies with the keys it does NOT hold and those are re-PUT (refresh doubles
    /// as repair). Deliberately ignores the seen-set: "seen" means uploaded once, and this
    /// exists precisely to re-assert entries that already exist. Our own hosted relay is
    /// touched locally (no iroh self-dial); S3 mailboxes have no GC.
    async fn refresh_mailbox(self: &Arc<Self>, circle_id: &str, envs: &[Vec<u8>]) {
        if envs.is_empty() {
            return;
        }
        let by_key: HashMap<String, &Vec<u8>> =
            envs.iter().map(|e| (Self::mailbox_key(circle_id, e), e)).collect();
        let keys: Vec<String> = by_key.keys().cloned().collect();
        let prefix = format!("haven/mailbox/{circle_id}/");
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        for node_hex in self.relays_for(circle_id) {
            if hosted.as_deref() == Some(node_hex.as_str()) {
                let misses = match self.relay_host.lock().unwrap().as_ref() {
                    Some(h) => h.local_touch(keys.clone()),
                    None => continue,
                };
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    for k in misses {
                        if let Some(env) = by_key.get(&k) {
                            h.local_put(k, env.to_vec());
                        }
                    }
                }
                continue;
            }
            let Some(client) = self.relay_client_for(&node_hex).await else { continue };
            match client.touch(prefix.clone(), keys.clone()).await {
                Ok(misses) => {
                    self.mark_relay_ok(&node_hex);
                    for k in misses {
                        if let Some(env) = by_key.get(&k) {
                            let _ = client.put(k, env.to_vec()).await;
                        }
                    }
                }
                // Unreachable, or a pre-GC relay without TOUCH — it isn't sweeping, skip safely.
                Err(e) => log::debug!("mailbox touch failed ({node_hex}): {e}"),
            }
        }
    }

    pub async fn poll_mailbox(self: &Arc<Self>) {
        let mut changed = false;
        // (circle_id, relay_node_hex) for every circle × every configured relay — reading from
        // all of them means a message present on any reachable relay still arrives.
        let relay_targets: Vec<(String, String)> = {
            let prefs = self.prefs.lock().unwrap();
            prefs
                .relays
                .iter()
                .flat_map(|(cid, list)| list.iter().map(move |hex| (cid.clone(), hex.clone())))
                .collect()
        };
        for (circle_id, node_hex) in relay_targets {
            let Some(client) = self.relay_client_for(&node_hex).await else { continue };
            let prefix = format!("haven/mailbox/{circle_id}/");
            let keys = client.list(prefix).await;
            self.mark_relay_ok(&node_hex);
            if !keys.is_empty() {
                self.dyn_state.lock().unwrap().relay_active = true;
            }
            for key in keys {
                // seen_mailbox is keyed by the content-addressed key, so the same envelope
                // mirrored on several relays is ingested exactly once.
                if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                    continue;
                }
                let Some(env) = client.get(key.clone()).await else { continue };
                self.mark_mailbox_seen(key);
                if self.social.receive(circle_id.clone(), env).unwrap_or(false) {
                    changed = true;
                    let is_dm = circle_id.starts_with("dm:");
                    self.notify(
                        if is_dm { "New message" } else { "New in your circle" },
                        if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
                    );
                }
            }
        }
        // BYO S3 bucket mailbox (the same circle-sealed envelopes, in the user's own bucket).
        if let Some(s3) = self.s3_client().await {
            for c in self.social.circles() {
                let keys = s3.list(&format!("haven/mailbox/{}", c.id)).await.unwrap_or_default();
                if !keys.is_empty() {
                    self.dyn_state.lock().unwrap().relay_active = true;
                }
                for key in keys {
                    if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                        continue;
                    }
                    let env = match s3.get(&key).await {
                        Ok(Some(e)) => e,
                        _ => continue,
                    };
                    self.mark_mailbox_seen(key);
                    if self.social.receive(c.id.clone(), env).unwrap_or(false) {
                        changed = true;
                        let is_dm = c.id.starts_with("dm:");
                        self.notify(
                            if is_dm { "New message" } else { "New in your circle" },
                            if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
                        );
                    }
                }
            }
        }
        self.flush_seen_mailbox();
        if changed {
            self.persist();
            self.emit_changed();
            self.request_missing_media();
        }
    }

    /// Configure (and verify) a BYO S3/R2/B2 bucket. Stores the secret in the keychain, the rest
    /// in prefs, caches the client, and back-fills + polls. Errors if the bucket can't be reached.
    pub async fn s3_configure(self: &Arc<Self>, pub_cfg: store::S3Public, secret_key: String) -> Result<()> {
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint.clone(),
            region: pub_cfg.region.clone(),
            bucket: pub_cfg.bucket.clone(),
            access_key: pub_cfg.access_key.clone(),
            secret_key: secret_key.clone(),
            prefix: pub_cfg.prefix.clone(),
        };
        let client = S3Mailbox::new(cfg)?;
        // Connectivity / auth check.
        client.list("haven/mailbox").await.map_err(|e| anyhow::anyhow!("bucket unreachable: {e}"))?;
        store::save_s3_secret(&secret_key)?;
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = Some(pub_cfg);
            p.save(&self.paths)?;
        }
        *self.s3.lock().await = Some(Arc::new(client));
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            for c in me.social.circles() {
                me.backfill_mailbox(&c.id).await;
            }
            me.poll_mailbox().await;
        });
        Ok(())
    }

    pub async fn s3_clear(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = None;
            let _ = p.save(&self.paths);
        }
        store::delete_s3_secret();
        *self.s3.lock().await = None;
        self.emit_changed();
    }

    pub fn s3_status(&self) -> Option<store::S3Public> {
        self.prefs.lock().unwrap().s3.clone()
    }

    // ---- cross-device media bytes (frame 3 request / frame 5 sealed chunks) -------------

    fn media_key(reference: &str) -> String {
        format!("haven/media/{reference}")
    }
    // Chunks live in a SIBLING dir "<ref>.p/", not nested under the manifest key "haven/media/<ref>":
    // a disk relay maps each key segment to a directory, so "<ref>/<i>" would force "<ref>" to be both a
    // manifest FILE and a chunk DIRECTORY (a collision that fails the manifest write). "<ref>.p" is distinct.
    fn media_chunk_key(reference: &str, i: usize) -> String {
        format!("haven/media/{reference}.p/{i}")
    }

    // ---- Chunked media transfer (large-blob fix) -----------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net). Large sealed videos (600 MB+)
    // stored as ONE blob under "haven/media/<ref>" exceed that → a GET truncates and the receiver can't
    // play them. Fix: slice the SEALED bytes into 8 MB chunks under "haven/media/<ref>/<i>" and store a
    // tiny manifest under "haven/media/<ref>". Download fetches chunks IN ORDER and appends to a temp file
    // on disk (streaming — never the whole blob in RAM). Small media (<= one chunk) stays a single sealed
    // blob (no manifest) for back-compat. BYTE-IDENTICAL to iOS/macOS + Android (same 8 MB size, key
    // scheme, and manifest bytes: a 9-byte magic then JSON).
    fn make_manifest(sizes: &[usize]) -> Vec<u8> {
        let total: usize = sizes.iter().sum();
        let json = serde_json::json!({ "v": 1, "chunks": sizes.len(), "total": total, "sizes": sizes });
        let mut out = MEDIA_MANIFEST_MAGIC.to_vec();
        out.extend_from_slice(&serde_json::to_vec(&json).unwrap_or_else(|_| b"{}".to_vec()));
        out
    }
    /// If `blob` is a chunk manifest, return its chunk count; else None (legacy/small single blob).
    fn parse_manifest(blob: &[u8]) -> Option<usize> {
        if blob.len() <= MEDIA_MANIFEST_MAGIC.len() || &blob[..MEDIA_MANIFEST_MAGIC.len()] != MEDIA_MANIFEST_MAGIC {
            return None;
        }
        let body = &blob[MEDIA_MANIFEST_MAGIC.len()..];
        let obj: serde_json::Value = serde_json::from_slice(body).ok()?;
        let n = obj.get("chunks")?.as_u64()? as usize;
        if n > 0 { Some(n) } else { None }
    }

    /// A symmetric key derived from the ACCOUNT seed — every one of the user's own devices derives the
    /// identical key, so own-device media chunks sealed with it always open on a sibling. KEM-sealing to
    /// your own account doesn't decap reliably (the engine's per-device identity makes it fail), which is
    /// why media between a user's own devices never decrypted. HKDF-SHA256(ikm=seed, salt="haven-own-
    /// media-v1", info="", len=32) — byte-identical to the iOS CryptoKit derivation, so a chunk sealed on
    /// the PC opens on the iPhone and vice-versa.
    fn own_media_key(&self) -> [u8; 32] {
        let hk = hkdf::Hkdf::<Sha256>::new(Some(b"haven-own-media-v1"), &self.seed);
        let mut okm = [0u8; 32];
        hk.expand(&[], &mut okm).expect("32 is a valid HKDF length");
        okm
    }

    pub fn request_missing_media(self: &Arc<Self>) {
        let my_hex = self.node_id_hex();
        let mut missing: Vec<(String, String)> = vec![]; // (ref, circleId)
        for c in self.social.circles() {
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            for item in feed {
                // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so a sweep
                // would fire a doomed S3-404 + ~30s iroh dial for them every cycle and never converge.
                for r in item.media {
                    if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                        missing.push((r, c.id.clone()));
                    }
                }
                for cm in item.comments {
                    for r in cm.media {
                        if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                            missing.push((r, c.id.clone()));
                        }
                    }
                }
            }
        }
        // THROTTLE the direct (peer) fallback. A missing ref used to be re-requested from EVERY contact
        // on every 15s sweep, so a backlog of missing media flooded the network with hundreds of thousands
        // of frames per cycle, drowning real delivery (the iOS "nothing communicates" flood). Direct-request
        // each ref at most once per 5 min, and only a handful per cycle — the relay/mailbox restore below is
        // the real, idempotent path and runs unthrottled.
        let now = now_ms();
        let mut direct_budget = 8;
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.media_req_at.len() > 4000 {
                st.media_req_at.clear(); // bound the throttle map
            }
        }
        for (reference, circle_id) in missing {
            // Decide direct-eligibility up front (cooldown + per-cycle budget) so the spawned task only
            // peer-blasts when the gate allows; the relay restore always runs.
            let direct_ok = {
                let mut st = self.dyn_state.lock().unwrap();
                let stale = st.media_req_at.get(&reference).map(|&t| now - t > 300_000).unwrap_or(true);
                if stale && direct_budget > 0 {
                    st.media_req_at.insert(reference.clone(), now);
                    direct_budget -= 1;
                    true
                } else {
                    false
                }
            };
            let me = self.clone();
            let my_hex = my_hex.clone();
            tauri::async_runtime::spawn(async move {
                // ALWAYS try the circle's mailbox (relay/S3) first — content-addressed + idempotent, no flood.
                if me.fetch_media_from_relay(&circle_id, &reference).await {
                    me.emit_changed();
                    return;
                }
                // Relay couldn't serve it → re-request from peers, but only when the throttle allowed it
                // (capped at 8/cycle with a 5-min per-ref cooldown). An interrupted peer transfer still
                // completes over successive sweeps; chunk re-sends just fill the gaps.
                if !direct_ok {
                    return;
                }
                me.dyn_state.lock().unwrap().requested_refs.insert(reference.clone());
                let mut payload = my_hex.into_bytes();
                payload.extend_from_slice(reference.as_bytes());
                // NOTE: we deliberately do NOT add our own account node id as a request target here. iroh
                // publishes this device's endpoint under the shared account id, so dialing it is a self-dial,
                // which sends iroh's QUIC path-discovery into an unbounded loop (the multi-GB leak the
                // RelayClient guard already prevents). Own-device media converges via the relay backfill
                // (each device mirrors its own media to the relays a sibling reads) — the reliable path.
                let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
                for id_hex in ids {
                    me.send_frame(wire::MEDIA_REQ, &payload, &id_hex);
                }
            });
        }
    }

    // ---- Relay plain-HTTP media interface (client side) -----------------------------------------
    // GET/PUT against a relay's HTTP interface (core httprelay.rs): `<base>/k/<key>` with the relay's
    // bearer token (learned from the sealed frame-19 announce). This is the DEFAULT cross-NAT media
    // transport; a URL that doesn't answer is backed off 2 minutes so a dead LAN address doesn't cost
    // a connect-timeout per chunk. Keys are already URL-path-safe (haven/media/… ascii), so no encoding.

    fn http_url_bad(&self, base: &str) -> bool {
        self.http_url_bad.lock().unwrap().get(base).map(|&t| t > now_ms()).unwrap_or(false)
    }
    fn mark_http_url_bad(&self, base: &str) {
        self.http_url_bad.lock().unwrap().insert(base.to_string(), now_ms() + 120_000);
    }
    fn http_key_url(base: &str, key: &str) -> String {
        format!("{}/k/{}", base.trim_end_matches('/'), key)
    }
    /// GET one key. `Ok(Some)` = bytes, `Ok(None)` = reachable but 404 (a real MISS — the iroh path
    /// serves the same store, so skip dialing it), `Err(())` = unreachable.
    async fn http_get(&self, base: &str, token: &str, key: &str) -> Result<Option<Vec<u8>>, ()> {
        let resp = self.http.get(Self::http_key_url(base, key)).bearer_auth(token).send().await.map_err(|_| ())?;
        match resp.status().as_u16() {
            200..=299 => Ok(Some(resp.bytes().await.map_err(|_| ())?.to_vec())),
            404 => Ok(None),
            _ => Err(()),
        }
    }
    async fn http_put(&self, base: &str, token: &str, key: &str, body: Vec<u8>) -> bool {
        self.http
            .put(Self::http_key_url(base, key))
            .bearer_auth(token)
            .header("content-type", "application/octet-stream")
            .body(body)
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    async fn upload_media(self: &Arc<Self>, circle_id: &str, reference: &str) {
        let Some(blob) = self.media.raw_sealed(reference) else { return };
        let key = Self::media_key(reference);
        let chunked = blob.len() > MEDIA_CHUNK_BYTES;
        // S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT, whereas
        // the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a pure-relay cross-NAT
        // path (noq/iroh fork bug): blob transfers that must cross a NAT stall and die even while
        // messaging works over the same relay path.
        if let Some(s3) = self.s3_client().await {
            if chunked {
                let mut sizes = Vec::new();
                let mut ok = true;
                for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                    if s3.put(&Self::media_chunk_key(reference, i), slice).await.is_err() { ok = false; break; }
                    sizes.push(slice.len());
                }
                if ok { let _ = s3.put(&key, &Self::make_manifest(&sizes)).await; }
            } else {
                let _ = s3.put(&key, &blob).await;
            }
        }
        // Then mirror to every relay (redundancy + the LAN/hosted fast-path). Per relay, its plain-HTTP
        // interface is tried FIRST (the reliable cross-NAT path); the iroh blob dial is the fallback.
        // Large blobs are sliced into 8 MB chunks under "<key>.p/<i>" with a manifest at <key> so a GET
        // never exceeds MAX_BLOB. "s3:" pseudo-entries are the bucket handled above — can't be dialed.
        for node_hex in self.relays_for(circle_id) {
            if node_hex.starts_with("s3:") { continue; }
            // Relay HTTP interface — the DEFAULT cross-NAT path. Bind out of the lock FIRST so the
            // MutexGuard is dropped before any `.await` below (a guard held across await isn't Send).
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                let mut put = false;
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    let ok = if chunked {
                        let mut sizes = Vec::new();
                        let mut all = true;
                        for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                            if !self.http_put(base, &token, &Self::media_chunk_key(reference, i), slice.to_vec()).await {
                                all = false;
                                break;
                            }
                            sizes.push(slice.len());
                        }
                        all && self.http_put(base, &token, &key, Self::make_manifest(&sizes)).await
                    } else {
                        self.http_put(base, &token, &key, blob.clone()).await
                    };
                    if ok { put = true; break; } else { self.mark_http_url_bad(base); }
                }
                if put {
                    self.mark_relay_ok(&node_hex);
                    continue; // the iroh path serves the SAME store — done with this relay
                }
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                let res: Result<(), ()> = async {
                    if chunked {
                        let mut sizes = Vec::new();
                        for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                            client.put(Self::media_chunk_key(reference, i), slice.to_vec()).await.map_err(|_| ())?;
                            sizes.push(slice.len());
                        }
                        client.put(key.clone(), Self::make_manifest(&sizes)).await.map_err(|_| ())
                    } else {
                        client.put(key.clone(), blob.clone()).await.map_err(|_| ())
                    }
                }
                .await;
                match res {
                    Ok(()) => self.mark_relay_ok(&node_hex),
                    Err(()) => self.relay_failed(&node_hex).await,
                }
            }
        }
    }

    async fn fetch_media_from_relay(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        let key = Self::media_key(reference);
        // S3/HTTP bucket FIRST — the DEFAULT media transport (see upload_media): an iroh blob dial
        // that must cross a NAT stalls ~30s and dies, so the bucket is tried before any dial.
        if let Some(s3) = self.s3_client().await {
            if let Ok(Some(head)) = s3.get(&key).await {
                if let Some(count) = Self::parse_manifest(&head) {
                    let part = self.media.new_sealed_part(reference);
                    let mut ok = true;
                    for i in 0..count {
                        match s3.get(&Self::media_chunk_key(reference, i)).await {
                            Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {}
                            _ => { ok = false; break; }
                        }
                    }
                    if ok && self.media.adopt_sealed_part(reference, &part) {
                        return true;
                    }
                    let _ = std::fs::remove_file(&part);
                } else {
                    self.media.write_raw_sealed(reference, &head);
                    return true;
                }
            }
        }
        // Then each relay in turn. Per relay, its plain-HTTP interface is tried FIRST (the reliable
        // cross-NAT path); the iroh blob dial is the fallback/fast-path.
        for node_hex in self.relays_for(circle_id) {
            if node_hex.starts_with("s3:") { continue; }
            // Relay HTTP interface — the DEFAULT cross-NAT path. Bind out of the lock FIRST so the
            // MutexGuard is dropped before any `.await` below (a guard held across await isn't Send).
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                let mut http_miss = false;
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    match self.http_get(base, &token, &key).await {
                        Err(()) => { self.mark_http_url_bad(base); continue; }
                        Ok(None) => { http_miss = true; break; } // reachable, doesn't hold it
                        Ok(Some(head)) => {
                            if let Some(count) = Self::parse_manifest(&head) {
                                let part = self.media.new_sealed_part(reference);
                                let mut ok = true;
                                for i in 0..count {
                                    match self.http_get(base, &token, &Self::media_chunk_key(reference, i)).await {
                                        Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {}
                                        _ => { ok = false; break; }
                                    }
                                }
                                if ok && self.media.adopt_sealed_part(reference, &part) {
                                    self.mark_relay_ok(&node_hex);
                                    return true;
                                }
                                let _ = std::fs::remove_file(&part);
                            } else {
                                self.mark_relay_ok(&node_hex);
                                self.media.write_raw_sealed(reference, &head);
                                return true;
                            }
                            http_miss = true; // served the manifest but reassembly failed — don't dial
                            break;
                        }
                    }
                }
                // Reachable HTTP relay that answered 404 (or a completed HTTP attempt): the iroh path
                // serves the SAME store, so skip the ~30s doomed dial for this relay.
                if http_miss { continue; }
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                if let Some(head) = client.get(key.clone()).await {
                    if let Some(count) = Self::parse_manifest(&head) {
                        // Stream each chunk to a temp file on disk — never the whole blob in RAM.
                        let part = self.media.new_sealed_part(reference);
                        let mut ok = true;
                        for i in 0..count {
                            match client.get(Self::media_chunk_key(reference, i)).await {
                                Some(chunk) if self.media.append_sealed_part(&part, &chunk) => {}
                                _ => { ok = false; break; }
                            }
                        }
                        if ok && self.media.adopt_sealed_part(reference, &part) {
                            self.mark_relay_ok(&node_hex);
                            return true;
                        }
                        let _ = std::fs::remove_file(&part);
                        continue;
                    }
                    self.mark_relay_ok(&node_hex);
                    self.media.write_raw_sealed(reference, &head);
                    return true;
                }
            }
        }
        false
    }

    async fn handle_media_request(self: &Arc<Self>, body: &[u8]) {
        if body.len() <= 64 {
            return;
        }
        let requester = String::from_utf8_lossy(&body[..64]).into_owned();
        if requester.len() != 64 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[64..]).into_owned();
        if reference.is_empty() || !self.media.has(&reference) {
            return;
        }
        let Some(bytes) = self.media.load_any_circle(&self.social, &reference) else { return };
        self.send_media_chunks(&reference, &bytes, &requester).await;
    }

    async fn send_media_chunks(self: &Arc<Self>, reference: &str, bytes: &[u8], requester_hex: &str) {
        let total = ((bytes.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE).max(1) as u32;
        let ref_bytes = reference.as_bytes();
        // Own-device (the requester is MY OWN account) → seal each chunk with the symmetric account-key, which
        // a sibling can always open (KEM-to-self decap is unreliable). A friend requester → per-recipient KEM
        // seal as before. The receiver tries the symmetric open first, then falls back to the engine's KEM.
        let own = requester_hex == self.node_id_hex();
        let own_key = if own { Some(self.own_media_key()) } else { None };
        let mut index = 0u32;
        let mut offset = 0;
        while offset < bytes.len() {
            let end = (offset + MEDIA_CHUNK_SIZE).min(bytes.len());
            let chunk = &bytes[offset..end];
            let sealed = if let Some(key) = own_key.as_ref() {
                p2pcore::crypto::seal(key, chunk)
            } else {
                match self.social.seal_media(requester_hex.to_string(), chunk.to_vec()) {
                    Ok(s) => s,
                    Err(_) => return,
                }
            };
            self.send_frame(wire::MEDIA_CHUNK, &wire::chunk_frame(ref_bytes, index, total, &sealed), requester_hex);
            offset = end;
            index += 1;
        }
    }

    fn handle_media_chunk(self: &Arc<Self>, body: &[u8]) {
        if body.len() < 2 {
            return;
        }
        let ref_len = (body[0] as usize) | ((body[1] as usize) << 8);
        if body.len() < 2 + ref_len + 8 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[2..2 + ref_len]).into_owned();
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let sealed = &body[off..];
        if reference.is_empty() || total == 0 || self.media.has(&reference) {
            return;
        }
        // Own-device chunks are symmetric (account-key) sealed; friend chunks are KEM. Try the cheap
        // symmetric open first, then fall back to the engine's KEM open.
        let plain = p2pcore::crypto::open(&self.own_media_key(), sealed)
            .ok()
            .or_else(|| self.social.open_media(sealed.to_vec()));
        let Some(plain) = plain else { return };
        let mut complete: Option<Vec<u8>> = None;
        {
            let mut st = self.dyn_state.lock().unwrap();
            let entry = st.incoming_media.entry(reference.clone()).or_insert(IncomingMedia { total, chunks: HashMap::new() });
            entry.chunks.insert(index, plain);
            if entry.chunks.len() as u32 >= entry.total {
                // Sanity cap: store_under_ref seals the whole media in memory (~2-3x its size). Skip
                // anything absurdly large (corrupt total, or media bigger than we should hold at once)
                // rather than risk an allocation blow-up. (Android, a low-heap phone, caps tighter.)
                let total_size: usize = entry.chunks.values().map(|c| c.len()).sum();
                const MAX_MEDIA: usize = 1024 * 1024 * 1024; // 1 GB
                if total_size > 0 && total_size <= MAX_MEDIA {
                    let mut full = Vec::with_capacity(total_size);
                    for i in 0..entry.total {
                        if let Some(c) = entry.chunks.get(&i) {
                            full.extend_from_slice(c);
                        }
                    }
                    complete = Some(full);
                }
                st.incoming_media.remove(&reference);
            }
        }
        if let Some(full) = complete {
            self.media.store_under_ref(&self.social, DEFAULT_CIRCLE, &reference, &full);
            self.emit_changed();
        }
    }

    // ---- local media (attach + display) -------------------------------------------------

    pub fn add_local_media(&self, circle_id: &str, bytes: &[u8], is_video: bool) -> String {
        self.media.store(&self.social, circle_id, bytes, is_video)
    }

    pub fn add_local_audio(&self, circle_id: &str, bytes: &[u8]) -> String {
        self.media.store_kind(&self.social, circle_id, bytes, crate::localmedia::MediaKind::Audio)
    }

    /// Decrypt a stored media ref for display, trying the given circle then any circle.
    pub fn media_bytes(&self, circle_id: &str, reference: &str) -> Option<Vec<u8>> {
        self.media
            .load(&self.social, circle_id, reference)
            .or_else(|| self.media.load_any_circle(&self.social, reference))
    }

    // ---- calls (signaling only; WebRTC media lives in the WebView) ----------------------

    /// Parse an inbound call frame and forward it to the UI's WebRTC mesh via `haven:call`.
    fn handle_call(self: &Arc<Self>, t: u8, body: &[u8]) {
        let Some(app) = self.app.lock().unwrap().clone() else { return };
        let ev = match t {
            wire::CALL_INVITE => callwire::parse_invite_name(body).map(|(from, name)| {
                serde_json::json!({ "kind": "invite", "from": from, "name": name, "sessionId": format!("legacy:{from}"), "roster": [from] })
            }),
            wire::GROUP_INVITE => callwire::parse_group_invite(body).map(|g| {
                serde_json::json!({ "kind": "groupInvite", "from": g.from, "sessionId": g.session_id, "groupName": g.group_name, "roster": g.roster })
            }),
            wire::CALL_ACCEPT => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "accept", "from": a.from, "sessionId": a.session_id })
            }),
            wire::CALL_HANGUP => callwire::parse_hangup(body).map(|from| {
                serde_json::json!({ "kind": "hangup", "from": from })
            }),
            wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => callwire::parse_signal(body, "").map(|s| {
                let kind = match t { wire::SDP_OFFER => "offer", wire::SDP_ANSWER => "answer", _ => "ice" };
                serde_json::json!({ "kind": kind, "from": s.from, "sessionId": s.session_id, "json": String::from_utf8_lossy(&s.json) })
            }),
            _ => None,
        };
        if let Some(ev) = ev {
            // Only a known contact's call frames reach the UI — a stranger can't ring, inject, or
            // negotiate a call (audit F3, iOS/Android parity). These frames are unsealed, so the
            // self-asserted `from` is gated against the contact list here.
            let from = ev.get("from").and_then(|v| v.as_str()).unwrap_or("");
            if !self.is_contact(from) {
                return;
            }
            let _ = app.emit("haven:call", ev);
        }
    }

    /// Whether `hex` is a known contact — gates unsealed call control frames.
    fn is_contact(&self, hex: &str) -> bool {
        self.prefs.lock().unwrap().contacts.iter().any(|c| c.id_hex == hex)
    }

    /// Send a call-signaling frame direct AND live-forwarded through the circle relays (frame 9 —
    /// the relay host unwraps and sends the inner frame onward over its own connections). Cross-NAT
    /// fallback: a callee whose direct dial back to the caller fails still lands the ACCEPT within
    /// the ring window. (The invite push rings the callee, but the answer path was direct-only.)
    fn send_call_frame(self: &Arc<Self>, t: u8, frame_body: &[u8], to_hex: &str) {
        self.send_frame(t, frame_body, to_hex);
        let mut dests = self.social.device_node_ids_for(to_hex.to_string());
        if dests.is_empty() {
            dests.push(to_hex.to_string());
        }
        for h in self.device_hints_for(to_hex) {
            if !dests.iter().any(|d| d.eq_ignore_ascii_case(&h)) {
                dests.push(h);
            }
        }
        self.originate_relay_internet(&dests, &wire::frame(t, frame_body));
    }

    /// Originate a frame-9 live forward of `inner` to `dests` via up to 3 adopted internet relays.
    /// Wire format parity with iOS emitRelay: [16B msgId][1B ttl][1B destCount][32B×dest][inner].
    fn originate_relay_internet(self: &Arc<Self>, dests: &[String], inner: &[u8]) {
        let dest_bytes: Vec<Vec<u8>> = dests.iter().filter_map(|h| hex_to_bytes32(h)).collect();
        if dest_bytes.is_empty() {
            return;
        }
        let mut msg_id = [0u8; 16];
        {
            use rand::RngCore;
            rand::rngs::OsRng.fill_bytes(&mut msg_id);
        }
        self.seen_relay.lock().unwrap().insert(bytes_to_hex(&msg_id)); // don't reprocess our own
        let mut p = Vec::with_capacity(18 + dest_bytes.len() * 32 + inner.len());
        p.extend_from_slice(&msg_id);
        p.push(3); // ttl
        p.push(dest_bytes.len().min(255) as u8);
        for d in dest_bytes.iter().take(255) {
            p.extend_from_slice(d);
        }
        p.extend_from_slice(inner);
        let my_acct = self.social.my_node_hex().to_lowercase();
        let my_dev = self.social.my_device_node_hex().to_lowercase();
        let relays: Vec<String> = self.prefs.lock().unwrap().relays.values().flatten().cloned().collect();
        let mut used = std::collections::HashSet::new();
        let mut sent = 0;
        for r in relays {
            let h = r.to_lowercase();
            if h.starts_with("s3:") || h == my_acct || h == my_dev || !used.insert(h) {
                continue;
            }
            self.send_frame(wire::RELAY, &p, &r);
            sent += 1;
            if sent >= 3 {
                break;
            }
        }
    }

    /// Frame-9 mesh relay: process the inner frame if we're a destination, and forward it onward to
    /// the other destinations over our own connections (we may be the relay host the sender hopped
    /// through). Dedup by msgId (loop protection, parity with iOS handleRelay).
    fn handle_relay(self: &Arc<Self>, body: &[u8]) {
        if body.len() < 18 {
            return;
        }
        {
            let mut seen = self.seen_relay.lock().unwrap();
            if !seen.insert(bytes_to_hex(&body[..16])) {
                return;
            }
            if seen.len() > 2000 {
                seen.clear();
            }
        }
        let ttl = body[16];
        let dest_count = body[17] as usize;
        let mut off = 18;
        if body.len() < off + dest_count * 32 {
            return;
        }
        let mut dests = Vec::with_capacity(dest_count);
        for _ in 0..dest_count {
            dests.push(bytes_to_hex(&body[off..off + 32]));
            off += 32;
        }
        let inner = &body[off..];
        if inner.is_empty() {
            return;
        }
        let me_acct = self.social.my_node_hex().to_lowercase();
        let me_dev = self.social.my_device_node_hex().to_lowercase();
        let for_me = dests.iter().any(|d| {
            let l = d.to_lowercase();
            l == me_acct || l == me_dev
        });
        if for_me {
            self.dispatch(inner.to_vec());
        }
        if ttl == 0 {
            return;
        }
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        for dest in dests {
            let l = dest.to_lowercase();
            if l == me_acct || l == me_dev {
                continue;
            }
            let node = node.clone();
            let inner = inner.to_vec();
            tauri::async_runtime::spawn(async move {
                let _ = node.send_to_node(dest, inner).await;
            });
        }
    }

    pub fn call_group_invite(self: &Arc<Self>, session_id: String, group_name: String, roster: Vec<String>, to: Vec<String>) {
        let me = self.node_id_hex();
        let frame = callwire::group_invite(&me, &session_id, &group_name, &roster.join(","));
        for t in to {
            self.send_call_frame(wire::GROUP_INVITE, &frame, &t);
        }
    }

    pub fn call_accept(self: &Arc<Self>, session_id: String, to: Vec<String>) {
        let frame = callwire::accept(&self.node_id_hex(), &session_id);
        for t in to {
            self.send_call_frame(wire::CALL_ACCEPT, &frame, &t);
        }
    }

    pub fn call_hangup(self: &Arc<Self>, to: Vec<String>) {
        let frame = callwire::hangup(&self.node_id_hex());
        for t in to {
            self.send_call_frame(wire::CALL_HANGUP, &frame, &t);
        }
    }

    pub fn call_signal(self: &Arc<Self>, kind: String, session_id: String, json: String, to: String) {
        let t = match kind.as_str() {
            "offer" => wire::SDP_OFFER,
            "answer" => wire::SDP_ANSWER,
            _ => wire::ICE,
        };
        let frame = callwire::signal(&self.node_id_hex(), &session_id, json.as_bytes());
        self.send_call_frame(t, &frame, &to);
    }

    // ---- persistence --------------------------------------------------------------------

    fn persist(&self) {
        if let Err(e) = store::write_state(&self.paths, &self.social.export_state()) {
            log::error!("persist failed: {e}");
        }
    }

    // ---- multi-device self-sync (D16, Phase 3 — port of iOS SelfSync.swift) -------------

    /// One full self-sync pass across the user's OWN devices: fold local changes into the base
    /// CRDT with fresh stamps, merge every peer slot from every transport, apply the converged
    /// result locally, persist, and re-publish our own sealed slot. Coalesces if already running.
    /// No-op without any transport (a relay OR the user's S3 bucket).
    pub async fn poll_self_sync(self: &Arc<Self>) {
        use p2pcore::identity::Identity;
        use p2pcore::selfsync::{slot_key, slot_prefix, AccountState, Stamp};

        // Coalesce concurrent passes (the 15s loop must never overlap itself).
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.self_syncing {
                return;
            }
            st.self_syncing = true;
        }
        // Always clear the in-flight flag on the way out.
        struct Guard<'a>(&'a Engine);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                self.0.dyn_state.lock().unwrap().self_syncing = false;
            }
        }
        let _guard = Guard(self);

        let account_hex = self.node_id_hex();
        if account_hex.is_empty() {
            return;
        }
        let transports = self.gather_self_sync_transports().await;
        if transports.is_empty() {
            return; // needs a relay OR an S3 bucket
        }

        let self_key = Identity::from_seed(&self.seed).self_sync_key();

        // 1. Base = last converged state (or empty).
        let mut base = match std::fs::read(self.paths.selfsync_state_file()) {
            Ok(bytes) => AccountState::from_bytes(&bytes).unwrap_or_default(),
            Err(_) => AccountState::default(),
        };

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device). Only
        //    stamp a key when its value actually differs from base, so stamps advance on real
        //    change (otherwise two devices ping-pong).
        let now = now_ms();
        let device = crate::selfsync::device_id(&self.paths);
        let stamp = Stamp::new(now, device);
        let local = {
            let prefs = self.prefs.lock().unwrap();
            crate::selfsync::current_local(&prefs, &self.social)
        };
        for (key, value) in &local {
            if base.get(key) != Some(value.as_slice()) {
                base.set(key, value.clone(), stamp);
            }
        }
        // Detect local removals in dynamic namespaces and tombstone them — BUT NOT when the engine
        // looks freshly-empty (no circles locally while the base still has circles). That signature is
        // a just-restored / unready device, and tombstoning there is exactly what wiped accounts; in
        // that state we only ADD, never remove.
        let local_has_circle = local.keys().any(|k| k.starts_with("circle:"));
        let base_has_circle = base.entries().any(|(k, _)| k.starts_with("circle:"));
        if local_has_circle || !base_has_circle {
            let present_keys: Vec<String> = base.entries().map(|(k, _)| k.to_string()).collect();
            for key in present_keys {
                if crate::selfsync::DYNAMIC_PREFIXES.iter().any(|p| key.starts_with(p))
                    && !local.contains_key(&key)
                {
                    base.remove(&key, stamp);
                }
            }
        }

        // Snapshot post-fold so we can tell whether the merge below actually brought anything new.
        let pre_merge = base.to_bytes();

        // 3. Pull + merge every peer slot from every relay/bucket.
        let prefix = format!("haven/{}", slot_prefix(&account_hex));
        let own_key = format!(
            "haven/{}",
            slot_key(&account_hex, &hex::encode(device))
        );
        for t in &transports {
            let keys = self.self_sync_list(t, &prefix).await;
            for key in keys {
                if key == own_key {
                    continue;
                }
                let Some(blob) = self.self_sync_fetch(t, &key).await else { continue };
                if let Ok(peer) = AccountState::open(&self_key, &blob) {
                    base.merge(&peer);
                }
            }
        }

        let changed = base.to_bytes() != pre_merge;

        // 4. Apply the converged state locally + persist the new base.
        let entries: Vec<(String, Vec<u8>)> =
            base.entries().map(|(k, v)| (k.to_string(), v.to_vec())).collect();
        let applied = {
            let mut prefs = self.prefs.lock().unwrap();
            let applied = crate::selfsync::apply_local(&entries, &mut prefs, &self.social);
            if applied {
                let _ = prefs.save(&self.paths);
            }
            applied
        };
        if applied {
            self.persist();
            self.emit_changed();
        }
        let _ = std::fs::write(self.paths.selfsync_state_file(), base.to_bytes());

        // 5. Re-publish our own slot (sealed) to every relay/bucket for redundancy.
        let sealed = base.seal(&self_key);
        for t in &transports {
            self.self_sync_put(t, &own_key, &sealed).await;
        }

        let _ = changed; // change-detection is folded into `applied`; kept for parity with iOS.
    }

    /// Every place this device can read/write its self-sync slots: all distinct configured relays
    /// plus the user's OWN S3 bucket (so sync works with no relay at all — BYO storage is enough).
    async fn gather_self_sync_transports(self: &Arc<Self>) -> Vec<SelfSyncTransport> {
        let mut out: Vec<SelfSyncTransport> = vec![];
        let relays: std::collections::BTreeSet<String> = {
            let prefs = self.prefs.lock().unwrap();
            prefs
                .relays
                .values()
                .flatten()
                .filter(|h| prefs.relay_is_active(h) && !h.starts_with("s3:"))
                .cloned()
                .collect()
        };
        for node_hex in relays {
            out.push(SelfSyncTransport::Relay(node_hex));
        }
        if let Some(s3) = self.s3_client().await {
            out.push(SelfSyncTransport::S3(s3));
        }
        out
    }

    async fn self_sync_list(self: &Arc<Self>, t: &SelfSyncTransport, prefix: &str) -> Vec<String> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                let Some(client) = self.relay_client_for(node_hex).await else { return vec![] };
                let keys = client.list(prefix.to_string()).await;
                self.mark_relay_ok(node_hex);
                keys
            }
            SelfSyncTransport::S3(c) => c.list(prefix).await.unwrap_or_default(),
        }
    }

    async fn self_sync_fetch(self: &Arc<Self>, t: &SelfSyncTransport, key: &str) -> Option<Vec<u8>> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                let client = self.relay_client_for(node_hex).await?;
                client.get(key.to_string()).await
            }
            SelfSyncTransport::S3(c) => c.get(key).await.ok().flatten(),
        }
    }

    async fn self_sync_put(self: &Arc<Self>, t: &SelfSyncTransport, key: &str, data: &[u8]) {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                if let Some(client) = self.relay_client_for(node_hex).await {
                    match client.put(key.to_string(), data.to_vec()).await {
                        Ok(()) => self.mark_relay_ok(node_hex),
                        Err(_) => self.relay_failed(node_hex).await,
                    }
                }
            }
            SelfSyncTransport::S3(c) => {
                let _ = c.put(key, data).await;
            }
        }
    }

    pub fn reset(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            *p = Prefs::default();
            let _ = p.save(&self.paths);
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            *st = DynState::default();
        }
        self.media.clear();
        store::remove_if_exists(&self.paths.state_file());
        // A new identity must not inherit the old ingestion cursor.
        store::remove_if_exists(&self.paths.root.join("mailbox-seen.txt"));
        // Clear the self-sync base too, so adopting a new identity doesn't diff an empty engine against
        // a stale base and tombstone the account (the data-loss bug).
        store::remove_if_exists(&self.paths.selfsync_state_file());
        {
            let mut r = self.roster.lock().unwrap();
            *r = crate::roster::DeviceRoster::load(&self.paths);
            r.step_down();
            let _ = r.save(&self.paths);
        }
        store::delete_s3_secret();
        let _ = store::delete_seed();
        self.emit_changed();
    }
}

/// Adapter so the Rust iroh node can deliver inbound bytes back into the engine without a
/// strong reference cycle (the engine owns the node).
struct NodeListener {
    engine: Weak<Engine>,
}

impl InboundListener for NodeListener {
    fn on_inbound(&self, from_hex: String, payload: Vec<u8>) {
        if let Some(engine) = self.engine.upgrade() {
            engine.dispatch_from(if from_hex.is_empty() { None } else { Some(from_hex) }, payload);
        }
    }
}

#[cfg(test)]
mod round_trip_tests {
    use crate::wire;
    use haven_ffi::HavenSocial;

    /// Two parties handshake and exchange a post + a sealed media chunk through the exact
    /// `wire` framing the engine moves over iroh — a stand-in for a real cross-device test
    /// (Windows ↔ iPhone ↔ Android) that doesn't need two machines or the network.
    #[test]
    fn two_parties_exchange_post_and_media_over_wire() {
        let alice = HavenSocial::new([11u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let cid = "default".to_string();

        // --- Hello handshake (frame 0) ---
        let hello = wire::hello_payload(
            &cid,
            "My Circle",
            &alice.my_bundle(),
            &alice.my_signed_profile("Alice".into(), String::new(), String::new(), String::new(), String::new()),
        );
        let frame = wire::frame(wire::HELLO, &hello);
        assert_eq!(frame[0], wire::HELLO);
        let parsed = wire::parse_hello(&frame[1..]).expect("hello parses");
        assert_eq!(
            bob.verify_profile(parsed.bundle.clone(), parsed.signed_profile.clone()).as_deref(),
            Some("Alice"),
            "bob reads alice's signed name"
        );
        bob.add_contact_bundle(cid.clone(), parsed.bundle).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        // --- Post (frame 1) ---
        let env = alice.post(cid.clone(), "hello from windows".into(), vec![], None, None, false, false, 1_000).unwrap();
        // The EVENT wire frame still round-trips through the codec.
        let ev_frame = wire::frame(wire::EVENT, &wire::event_payload(&cid, &env));
        let ev = wire::parse_event(&ev_frame[1..]).expect("event parses");
        assert_eq!(ev.circle_id, cid, "event frame carries the circle id");
        // Posts are sealed under Alice's epoch key (group-keying), so Bob must receive her key commit
        // before he can open them. Her sync bundle carries the commit + the event — deliver it the way
        // the live sync path does (mirrors the core net_tests `sync` helper).
        let mut got_new = false;
        for envelope in alice.sync_envelopes(cid.clone()) {
            if bob.receive(cid.clone(), envelope).unwrap() { got_new = true; }
        }
        assert!(got_new, "bob ingests new content on first sync");
        let feed = bob.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hello from windows");
        assert!(!feed[0].is_me);

        // --- Sealed media chunk (frame 5) ---
        let blob = vec![9u8; 1000];
        let sealed = alice.seal_media(bob.my_node_hex(), blob.clone()).unwrap();
        let chunk = wire::chunk_frame(b"v:abc", 0, 1, &sealed);
        let ref_len = (chunk[0] as usize) | ((chunk[1] as usize) << 8);
        assert_eq!(String::from_utf8_lossy(&chunk[2..2 + ref_len]), "v:abc");
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        assert_eq!((index, total), (0, 1));
        assert_eq!(bob.open_media(chunk[off..].to_vec()), Some(blob), "bob reassembles + decrypts the media");
    }
}
