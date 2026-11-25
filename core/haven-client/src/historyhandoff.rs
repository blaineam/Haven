//! The history hand-off between devices of ONE account, engine side (Apple `HistoryHandoff.swift`
//! is the design; `HistoryHandoffWire.swift` is the wire format this file matches byte for byte).
//!
//! WHY THE BROWSER NEEDS IT. A relay mailbox is a pile of sealed envelopes named by their hash:
//! nothing says which is newest, and most of them are sealed under keys a device linked today
//! never held. A newly linked browser used to drain the whole pile to draw a feed: on a real
//! account that was ten thousand requests and 600 MB, arriving in no order, of which it could
//! open only its own account's posts. A device that already HOLDS the history can instead hand
//! it over newest first, re-sealed under a key the new device has:
//!
//!   NEW device (target)                          OLD device (source)
//!   PUT  history-req/<me>            ────▶       exports pages newest first, one circle at a
//!   GET  history-m/<me>/<source>     ◀────       time in turn, friends' posts included
//!   GET  history/<me>/<source>/<run>/<n>
//!
//! All of it on the account lane (`haven/self/<account>/…`), which only this account's devices
//! can read or write. The relay learns nothing it did not already hold.
//!
//! The TARGET here pulls a few pages and stops; it pulls more when the reader scrolls to the end
//! of what it has (`history_more`). The SOURCE half lets a desktop that holds the account key
//! answer the same request a phone would. Media is not carried: it is fetched when it comes on
//! screen, as everywhere else in the browser.

use serde::{Deserialize, Serialize};

use super::*;

/// Events per page (Apple `pageEvents`).
pub const PAGE_EVENTS: u32 = 120;
/// Pages pulled without being asked, and how many more each "the reader reached the end" allows.
pub const FIRST_PAGES: u32 = 6;
pub const MORE_PAGES: u32 = 6;
/// A source whose manifest has not moved for this long is presumed gone (Apple `staleSourceMs`).
pub const STALE_SOURCE_MS: u64 = 45 * 60 * 1000;
/// With no answer at all for this long, the mailbox backlog is read after all.
pub const GIVE_UP_WAITING_MS: u64 = 15 * 60 * 1000;
/// A mailbox listed for the first time this soon after the ask is the backlog the hand-off
/// replaces, and is skipped. Later listings are new posts.
pub const BASELINE_WINDOW_MS: u64 = 10 * 60 * 1000;
/// Backlog entries read from a relay that lists newest first: at linking, and again each time
/// the reader reaches the end of the feed.
pub const RELAY_STRETCH: usize = 150;
const RENUDGE_MS: u64 = 10 * 60 * 1000;
/// Pages a source uploads per pass, so one heartbeat never turns into the whole export.
const SERVE_PAGES_PER_PASS: u32 = 12;
const ABANDONED_RUN_MS: u64 = 3 * 24 * 3_600_000;

pub fn lane(acct: &str) -> String {
    format!("haven/self/{}/", acct.to_lowercase())
}
pub fn request_prefix(acct: &str) -> String {
    format!("{}history-req/", lane(acct))
}
pub fn request_key(acct: &str, target: &str) -> String {
    format!("{}{}", request_prefix(acct), target.to_lowercase())
}
pub fn manifest_prefix(acct: &str, target: &str) -> String {
    format!("{}history-m/{}/", lane(acct), target.to_lowercase())
}
pub fn manifest_key(acct: &str, target: &str, source: &str) -> String {
    format!("{}{}", manifest_prefix(acct, target), source.to_lowercase())
}
pub fn page_key(acct: &str, target: &str, source: &str, run: &str, n: u32) -> String {
    format!("{}history/{}/{}/{run}/{n}", lane(acct), target.to_lowercase(), source.to_lowercase())
}

/// The ask. Field names are Apple's (`HistoryHandoffWire.Request`).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Request {
    pub v: u32,
    pub device: String,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub done: Option<bool>,
    /// The asking device's account-signed roster wire, base64.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roster: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancelled: Option<bool>,
}

/// A source's progress (`HistoryHandoffWire.Manifest`).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub v: u32,
    pub run: String,
    pub source: String,
    pub for_request: u64,
    pub pages: u32,
    pub complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_events: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub served_events: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancelled: Option<bool>,
}

impl Manifest {
    pub fn is_live(&self, now: u64) -> bool {
        self.complete || now.saturating_sub(self.updated_at.unwrap_or(0)) < STALE_SOURCE_MS
    }
}

/// The manifest to follow: the one already followed while it is live, else the live one furthest
/// along (Apple `pickManifest`).
pub fn pick_manifest(all: &[Manifest], source: &str, run: &str, now: u64) -> Option<Manifest> {
    let found: Vec<&Manifest> = all.iter().filter(|m| m.cancelled != Some(true)).collect();
    if let Some(cur) = found.iter().find(|m| m.source == source && m.run == run && m.is_live(now)) {
        return Some((*cur).clone());
    }
    found
        .iter()
        .filter(|m| m.is_live(now))
        .max_by_key(|m| (m.complete, m.pages))
        .or_else(|| found.iter().find(|m| m.source == source && m.run == run))
        .map(|m| (*m).clone())
}

/// One page: `"HVH2" ‖ u16 circle-id length ‖ circle id ‖ u32 count ‖ count × (u32 length ‖
/// envelope) ‖ u32 media count ‖ count × (u16 ref length ‖ ref ‖ u64 size)`, little-endian.
/// `"HVH1"` is the same without the media list.
pub fn encode_page(circle_id: &str, envelopes: &[Vec<u8>]) -> Vec<u8> {
    let mut out = b"HVH2".to_vec();
    out.extend_from_slice(&(circle_id.len() as u16).to_le_bytes());
    out.extend_from_slice(circle_id.as_bytes());
    out.extend_from_slice(&(envelopes.len() as u32).to_le_bytes());
    for e in envelopes {
        out.extend_from_slice(&(e.len() as u32).to_le_bytes());
        out.extend_from_slice(e);
    }
    out.extend_from_slice(&0u32.to_le_bytes()); // media rides separately here
    out
}

/// `(circle id, envelopes)` of a page, or `None` for bytes that are not one. The media list of
/// a v2 page is checked for shape and dropped.
pub fn decode_page(data: &[u8]) -> Option<(String, Vec<Vec<u8>>)> {
    let v2 = data.starts_with(b"HVH2");
    if !v2 && !data.starts_with(b"HVH1") {
        return None;
    }
    let mut i = 4usize;
    let mut take = |n: usize| -> Option<&[u8]> {
        let end = i.checked_add(n)?;
        let s = data.get(i..end)?;
        i = end;
        Some(s)
    };
    let cl = u16::from_le_bytes(take(2)?.try_into().ok()?) as usize;
    let cid = String::from_utf8(take(cl)?.to_vec()).ok()?;
    let count = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
    // Every envelope costs at least its 4-byte length: a count the bytes cannot hold is a lie.
    if count > data.len() / 4 {
        return None;
    }
    let mut envs = Vec::with_capacity(count);
    for _ in 0..count {
        let n = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
        envs.push(take(n)?.to_vec());
    }
    if v2 {
        let mc = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
        for _ in 0..mc {
            let rl = u16::from_le_bytes(take(2)?.try_into().ok()?) as usize;
            take(rl)?;
            take(8)?;
        }
    }
    Some((cid, envs))
}

/// TARGET: what this device asked for and how far it has read. Persisted in the prefs.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Want {
    pub account: String,
    pub at: u64,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub run: String,
    #[serde(default)]
    pub next_page: u32,
    /// Pages this device may read so far; raised when the reader reaches the end of the feed.
    #[serde(default)]
    pub allowed_pages: u32,
    #[serde(default)]
    pub held: u32,
    #[serde(default)]
    pub received_events: u64,
    #[serde(default)]
    pub total_events: u64,
    #[serde(default)]
    pub last_nudge_at: u64,
    /// The source has said everything is up, and all of it has been read.
    #[serde(default)]
    pub complete: bool,
    /// Nobody answered (or the user said not to wait): the mailbox backlog is read instead.
    #[serde(default)]
    pub fallback: bool,
    /// `relay|circle` mailboxes whose backlog was skipped in favour of the hand-off.
    #[serde(default)]
    pub baselined: Vec<String>,
    /// How many backlog envelopes were left on the relays unfetched.
    #[serde(default)]
    pub skipped: u64,
    /// Per `relay|circle` mailbox on a relay that lists newest first: the oldest backlog entry
    /// opened so far. Everything the relay lists after it is still unread there.
    #[serde(default)]
    pub floors: HashMap<String, String>,
    /// Mailboxes whose next stretch the reader has asked for.
    #[serde(default)]
    pub more_pairs: Vec<String>,
    /// Mailboxes that have been planned from a newest-first listing.
    #[serde(default)]
    pub ordered: Vec<String>,
}

/// What a mailbox pass does with the backlog it was just shown.
#[derive(Debug, Default, PartialEq)]
pub struct BacklogPlan {
    /// Marked seen without being fetched.
    pub skip: Vec<String>,
    /// Skipped earlier, to be read now.
    pub reopen: Vec<String>,
}

impl Want {
    /// Is the hand-off, not the mailbox, how this device gets its backlog?
    pub fn replaces_backlog(&self) -> bool {
        !self.fallback
    }
    /// Should a mailbox listed for the first time now have its backlog skipped?
    pub fn skips_backlog_of(&self, pair: &str, now: u64) -> bool {
        self.replaces_backlog()
            && now.saturating_sub(self.at) < BASELINE_WINDOW_MS
            && !self.baselined.iter().any(|p| p == pair)
    }
    /// Decide what to do with `backlog` (the content keys of one mailbox, in the order the relay
    /// listed them). `newest_first` says that order is by arrival, newest first.
    pub fn plan_backlog(&mut self, pair: &str, backlog: &[String], newest_first: bool, now: u64) -> BacklogPlan {
        let mut plan = BacklogPlan::default();
        if self.skips_backlog_of(pair, now) {
            self.baselined.push(pair.to_string());
            // In hash order nothing can be said about which entries are recent: leave them all.
            let keep = if newest_first { RELAY_STRETCH.min(backlog.len()) } else { 0 };
            plan.skip = backlog[keep..].to_vec();
            self.skipped += plan.skip.len() as u64;
            if newest_first {
                self.ordered.push(pair.to_string());
                if keep < backlog.len() {
                    self.floors.insert(pair.to_string(), backlog[keep - 1].clone());
                }
            }
            return plan;
        }
        // Skipped whole while its relay could not order a listing, and the relay now can (it was
        // upgraded): the newest stretch is read after all, once.
        if newest_first && !self.fallback && !self.ordered.iter().any(|p| p == pair) {
            self.ordered.push(pair.to_string());
            let keep = RELAY_STRETCH.min(backlog.len());
            plan.reopen = backlog[..keep].to_vec();
            self.skipped = self.skipped.saturating_sub(keep as u64);
            if keep < backlog.len() {
                self.floors.insert(pair.to_string(), backlog[keep - 1].clone());
            }
            return plan;
        }
        if !newest_first || !self.more_pairs.iter().any(|p| p == pair) {
            return plan;
        }
        self.more_pairs.retain(|p| p != pair);
        let Some(floor) = self.floors.get(pair).cloned() else { return plan };
        // A floor the relay no longer holds (swept) leaves nothing to count from.
        let Some(at) = backlog.iter().position(|k| *k == floor) else {
            self.floors.remove(pair);
            return plan;
        };
        let end = (at + 1 + RELAY_STRETCH).min(backlog.len());
        plan.reopen = backlog[at + 1..end].to_vec();
        self.skipped = self.skipped.saturating_sub(plan.reopen.len() as u64);
        if end < backlog.len() {
            self.floors.insert(pair.to_string(), backlog[end - 1].clone());
        } else {
            self.floors.remove(pair);
        }
        plan
    }

    pub fn state(&self, now: u64) -> &'static str {
        if self.fallback {
            "relays"
        } else if self.complete {
            "done"
        } else if self.run.is_empty() {
            if now.saturating_sub(self.at) > 20_000 { "waiting" } else { "asking" }
        } else if self.next_page >= self.allowed_pages {
            "paused"
        } else {
            "receiving"
        }
    }
}

/// SOURCE: one run of pages for one of my devices. Persisted in the prefs.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Serve {
    pub request_at: u64,
    pub run: String,
    pub order: Vec<String>,
    #[serde(default)]
    pub cursors: HashMap<String, u64>,
    #[serde(default)]
    pub finished: Vec<String>,
    #[serde(default)]
    pub pages: u32,
    #[serde(default)]
    pub complete: bool,
    #[serde(default)]
    pub total_events: u64,
    #[serde(default)]
    pub served_events: u64,
}

/// Is a mailbox key ordinary content (a hash), as opposed to a lane with its own routing
/// (`__hello__`, `__relay__`, `__live__`)? Only content is skipped as backlog.
pub fn is_backlog_key(key: &str) -> bool {
    !key.contains("/__")
}

impl Engine {
    pub(super) async fn lane_list(self: &Arc<Self>, prefix: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for t in self.gather_self_sync_transports().await {
            for k in self.self_sync_list(&t, prefix).await {
                if !out.contains(&k) {
                    out.push(k);
                }
            }
        }
        out
    }

    pub(super) async fn lane_get(self: &Arc<Self>, key: &str) -> Option<Vec<u8>> {
        for t in self.gather_self_sync_transports().await {
            if let Some(b) = self.self_sync_fetch(&t, key).await {
                return Some(b);
            }
        }
        None
    }

    pub(super) async fn lane_put(self: &Arc<Self>, key: &str, data: &[u8]) -> bool {
        let mut ok = false;
        for t in self.gather_self_sync_transports().await {
            if self.self_sync_put(&t, key, data).await {
                ok = true;
            }
        }
        ok
    }

    fn history_want(&self) -> Option<Want> {
        self.prefs.lock().history_want.clone()
    }

    /// Does this device get its backlog from another device of the account rather than from the
    /// mailbox? A linked browser does.
    pub(super) fn wants_history_handoff(&self) -> bool {
        self.is_web_device() && self.is_seedless() && self.seedless.lock().linked
    }

    /// TARGET: make sure the ask exists (a browser linked before this existed gets one too).
    pub(super) fn ensure_history_want(&self) {
        if !self.wants_history_handoff() {
            return;
        }
        let acct = self.node_id_hex().to_lowercase();
        if acct.is_empty() {
            return;
        }
        let mut p = self.prefs.lock();
        if p.history_want.as_ref().is_some_and(|w| w.account == acct) {
            return;
        }
        p.history_want = Some(Want { account: acct, at: now_ms(), allowed_pages: FIRST_PAGES, ..Default::default() });
        let _ = p.save(&self.paths);
        log::info!("history hand-off: asking my other devices for recent history");
    }

    /// A mailbox was just listed: what of its backlog is left on the relay, and what that was
    /// left earlier is read now ([`Want::plan_backlog`]).
    pub(super) fn history_plan_backlog(&self, pair: &str, backlog: &[String], newest_first: bool) -> BacklogPlan {
        let mut p = self.prefs.lock();
        let Some(w) = p.history_want.as_mut() else { return BacklogPlan::default() };
        let before = (w.baselined.len(), w.more_pairs.len(), w.ordered.len());
        let plan = w.plan_backlog(pair, backlog, newest_first, now_ms());
        if before != (w.baselined.len(), w.more_pairs.len(), w.ordered.len()) {
            let _ = p.save(&self.paths);
        }
        plan
    }

    /// Is the hand-off (not the mailbox) how this device gets what it could not open?
    pub(super) fn history_replaces_backlog(&self) -> bool {
        self.wants_history_handoff() && self.history_want().is_some_and(|w| w.replaces_backlog())
    }

    async fn history_announce(self: &Arc<Self>, force: bool) {
        let Some(mut w) = self.history_want() else { return };
        let now = now_ms();
        if !force && now.saturating_sub(w.last_nudge_at) < RENUDGE_MS {
            return;
        }
        let me = self.social.my_device_node_hex().to_lowercase();
        let roster = self.social.my_device_roster_wire();
        let req = Request {
            v: 1,
            device: me.clone(),
            at: w.at,
            done: None,
            roster: (!roster.is_empty()).then(|| base64::engine::general_purpose::STANDARD.encode(&roster)),
            cancelled: None,
        };
        let Ok(body) = serde_json::to_vec(&req) else { return };
        if !self.lane_put(&request_key(&w.account, &me), &body).await {
            log::info!("history hand-off: request not published yet (no relay took it)");
            return;
        }
        w.last_nudge_at = now;
        // Only the nudge stamp: a pull running beside this must not have its cursor rewound.
        {
            let mut p = self.prefs.lock();
            if let Some(cur) = p.history_want.as_mut().filter(|c| c.at == w.at) {
                cur.last_nudge_at = now;
                let _ = p.save(&self.paths);
            }
        }
        for d in self.social.device_node_ids_for(w.account.clone()) {
            let d = d.to_lowercase();
            if d != me && d != w.account {
                self.send_frame_direct(wire::HISTORY_NUDGE, me.as_bytes(), &d);
            }
        }
    }

    /// TARGET: read whatever pages are ready and allowed. True if anything was added.
    pub async fn history_pull(self: &Arc<Self>) -> bool {
        self.ensure_history_want();
        let Some(mut w) = self.history_want() else { return false };
        if w.complete || w.account != self.node_id_hex().to_lowercase() {
            return false;
        }
        // Paused at the end of what the reader has looked at: no request at all.
        if !w.run.is_empty() && w.next_page >= w.allowed_pages {
            return false;
        }
        if self.history_pulling.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        struct Guard<'a>(&'a Engine);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                self.0.history_pulling.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _guard = Guard(self);

        let me = self.social.my_device_node_hex().to_lowercase();
        let mut manifests: Vec<Manifest> = Vec::new();
        for key in self.lane_list(&manifest_prefix(&w.account, &me)).await {
            if let Some(m) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Manifest>(&b).ok()) {
                if m.for_request >= w.at {
                    manifests.push(m);
                }
            }
        }
        let now = now_ms();
        let Some(m) = pick_manifest(&manifests, &w.source, &w.run, now) else {
            self.history_announce(w.last_nudge_at == 0).await;
            if !w.fallback && now.saturating_sub(w.at) > GIVE_UP_WAITING_MS {
                log::info!("history hand-off: no device answered; reading the relay backlog instead");
                self.history_use_relays();
            }
            return false;
        };
        if w.run != m.run || w.source != m.source {
            w.run = m.run.clone();
            w.source = m.source.clone();
            w.next_page = 0;
            w.held = 0;
            w.received_events = 0;
        }
        w.total_events = m.total_events.unwrap_or(0).max(w.received_events);
        let mut progressed = false;
        while w.next_page < m.pages && w.next_page < w.allowed_pages {
            let Some(blob) = self.lane_get(&page_key(&w.account, &me, &m.source, &m.run, w.next_page)).await else {
                break; // not on a reachable relay yet
            };
            let Some((circle_id, envelopes)) = decode_page(&blob) else {
                log::warn!("history hand-off: page {} unreadable, skipped", w.next_page);
                w.next_page += 1;
                continue;
            };
            if !self.social.circles().iter().any(|c| c.id == circle_id) {
                // Its circle has not reached this device yet (self-sync brings the list). Wait,
                // but a circle that never arrives must not hold every page behind it.
                w.held += 1;
                if w.held >= 4 {
                    w.next_page += 1;
                    w.held = 0;
                }
                break;
            }
            w.received_events += self.ingest_history_page(&circle_id, envelopes).await;
            w.next_page += 1;
            w.held = 0;
            progressed = true;
            self.save_history_cursor(&w);
        }
        if m.complete && w.next_page >= m.pages {
            w.complete = true;
            let done = Request { v: 1, device: me.clone(), at: w.at, done: Some(true), roster: None, cancelled: None };
            if let Ok(body) = serde_json::to_vec(&done) {
                self.lane_put(&request_key(&w.account, &me), &body).await;
            }
            log::info!("history hand-off: complete, {} events over {} pages", w.received_events, m.pages);
        }
        self.save_history_cursor(&w);
        if progressed {
            self.emit_changed();
        }
        progressed
    }

    /// Write the pull's cursor back, keeping what other paths own (the page allowance the reader
    /// raised meanwhile, the skipped mailboxes, a fallback the user chose).
    fn save_history_cursor(&self, w: &Want) {
        let mut p = self.prefs.lock();
        let Some(cur) = p.history_want.as_mut().filter(|c| c.at == w.at) else { return };
        cur.source = w.source.clone();
        cur.run = w.run.clone();
        cur.next_page = w.next_page;
        cur.held = w.held;
        cur.received_events = w.received_events;
        cur.total_events = w.total_events;
        cur.complete = w.complete;
        let _ = p.save(&self.paths);
    }

    /// Open one page: the roster and key commit first, so its events open on the first try.
    /// Returns how many EVENTS it carried.
    async fn ingest_history_page(self: &Arc<Self>, circle_id: &str, mut envelopes: Vec<Vec<u8>>) -> u64 {
        let rank = |e: &Vec<u8>| match e.first() {
            Some(0x04) => 0,
            Some(0x03) => 1,
            _ => 2,
        };
        envelopes.sort_by_key(rank);
        let events = envelopes.iter().filter(|e| e.first() == Some(&0x02)).count() as u64;
        let mut applied = 0usize;
        for (i, env) in envelopes.into_iter().enumerate() {
            if matches!(self.social.receive(circle_id.to_string(), env), Ok(true)) {
                applied += 1;
            }
            // A page is a hundred-odd unseals: let the page (a browser has one thread) breathe.
            if i % 8 == 7 {
                crate::rt::sleep(std::time::Duration::from_millis(2)).await;
            }
        }
        if applied > 0 {
            self.persist();
        }
        events
    }

    /// The reader reached the end of what this device holds: allow the next pages. False when
    /// there is nothing more to ask for.
    pub fn history_more(self: &Arc<Self>) -> bool {
        let (relays, pages) = {
            let mut p = self.prefs.lock();
            let Some(w) = p.history_want.as_mut() else { return false };
            // The next stretch of every mailbox that still has one, on relays that list newest
            // first. One request per stretch: asked again only once this one has been taken.
            let relays: Vec<String> =
                if w.fallback || !w.more_pairs.is_empty() { Vec::new() } else { w.floors.keys().cloned().collect() };
            w.more_pairs.extend(relays.iter().cloned());
            // The next pages from my other devices, only once the pages already allowed have
            // been read: a burst of scroll events must not turn into the whole history.
            let pages = !w.complete && !w.fallback;
            if pages && w.next_page >= w.allowed_pages {
                w.allowed_pages = w.next_page + MORE_PAGES;
            }
            let _ = p.save(&self.paths);
            (relays, pages)
        };
        if !relays.is_empty() {
            // An unchanged listing answers 204 with no keys: forget the digests so it is sent.
            let mut st = self.dyn_state.lock();
            for pair in &relays {
                st.mailbox_list_digests.remove(pair);
            }
            st.next_poll_due_ms = 0;
        }
        if relays.is_empty() && !pages {
            return false;
        }
        let me = self.clone();
        crate::rt::spawn(async move {
            me.history_pull().await;
        });
        true
    }

    /// Stop waiting for another device: read the mailbox backlog after all.
    pub fn history_use_relays(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock();
            let Some(w) = p.history_want.as_mut() else { return };
            if w.fallback {
                return;
            }
            w.fallback = true;
            w.baselined.clear();
            w.floors.clear();
            w.more_pairs.clear();
            let _ = p.save(&self.paths);
        }
        {
            let mut st = self.dyn_state.lock();
            let before = st.seen_mailbox.len();
            st.seen_mailbox.retain(|k| !is_backlog_key(k));
            if st.seen_mailbox.len() != before {
                st.seen_journal.note_removed();
            }
            st.mailbox_list_digests.clear();
            st.next_poll_due_ms = 0;
        }
        self.flush_seen_mailbox();
        self.emit_changed();
    }

    pub fn history_status(&self) -> serde_json::Value {
        match self.history_want() {
            Some(w) if self.wants_history_handoff() => serde_json::json!({
                "state": w.state(now_ms()),
                "received": w.received_events,
                "total": w.total_events,
                "skipped": w.skipped,
                "more": (!w.complete && !w.fallback) || !w.floors.is_empty(),
            }),
            _ => serde_json::json!({ "state": "idle", "received": 0, "total": 0, "skipped": 0, "more": false }),
        }
    }

    // ---- source -----------------------------------------------------------------------------

    /// SOURCE: answer every open request from my other devices. Only a device that holds the
    /// account key serves: it is the one certain to hold the history it would hand over.
    pub async fn history_serve(self: &Arc<Self>) -> bool {
        if self.is_seedless() {
            return false;
        }
        let acct = self.node_id_hex().to_lowercase();
        if acct.is_empty() || self.social.circles().is_empty() {
            return false;
        }
        if self.history_serving.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        struct Guard<'a>(&'a Engine);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                self.0.history_serving.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let _guard = Guard(self);

        let me = self.social.my_device_node_hex().to_lowercase();
        let mine: Vec<String> = self.social.device_node_ids_for(acct.clone()).into_iter().map(|d| d.to_lowercase()).collect();
        let now = now_ms();
        {
            let mut p = self.prefs.lock();
            let before = p.history_serves.len();
            p.history_serves.retain(|_, s| s.run.parse::<u64>().unwrap_or(0) > now.saturating_sub(ABANDONED_RUN_MS));
            if p.history_serves.len() != before {
                let _ = p.save(&self.paths);
            }
        }
        let mut did = false;
        for key in self.lane_list(&request_prefix(&acct)).await {
            let device = key.rsplit('/').next().unwrap_or("").to_lowercase();
            // Only a device the account's own signed roster lists: the lane is writable by my
            // devices alone, and a page is sealed to devices the roster names, never to a key
            // that merely asks.
            if device.len() != 64 || device == me || !mine.contains(&device) {
                continue;
            }
            let Some(req) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Request>(&b).ok()) else { continue };
            if req.done == Some(true) || req.cancelled == Some(true) {
                let mut p = self.prefs.lock();
                if p.history_serves.remove(&device).is_some() {
                    let _ = p.save(&self.paths);
                }
                continue;
            }
            let mut run = self.prefs.lock().history_serves.get(&device).cloned().filter(|s| s.request_at == req.at);
            if run.is_none() {
                if self.another_source_serves(&acct, &device, req.at, &me).await {
                    continue;
                }
                let order: Vec<String> = self.social.circles().into_iter().map(|c| c.id).collect();
                let total = order.iter().map(|c| self.social.history_event_count(c.clone())).sum();
                log::info!("history hand-off: serving one of my devices, {} circles", order.len());
                run = Some(Serve { request_at: req.at, run: now_ms().to_string(), order, total_events: total, ..Default::default() });
            }
            let Some(mut run) = run else { continue };
            if !run.complete && self.serve_run(&mut run, &acct, &device, &me).await {
                did = true;
            }
            let mut p = self.prefs.lock();
            p.history_serves.insert(device, run);
            let _ = p.save(&self.paths);
        }
        did
    }

    async fn another_source_serves(self: &Arc<Self>, acct: &str, target: &str, request: u64, me: &str) -> bool {
        let now = now_ms();
        for key in self.lane_list(&manifest_prefix(acct, target)).await {
            let Some(m) = self.lane_get(&key).await.and_then(|b| serde_json::from_slice::<Manifest>(&b).ok()) else { continue };
            if m.source.to_lowercase() != me && m.for_request >= request && (m.cancelled == Some(true) || m.is_live(now)) {
                return true;
            }
        }
        false
    }

    /// One page per circle in turn, newest first everywhere, so the new device sees what is
    /// recent in every circle before any circle's distant past.
    async fn serve_run(self: &Arc<Self>, run: &mut Serve, acct: &str, device: &str, me: &str) -> bool {
        let mut did = false;
        let mut budget = SERVE_PAGES_PER_PASS;
        while !run.complete && budget > 0 {
            let pending: Vec<String> = run.order.iter().filter(|c| !run.finished.contains(c)).cloned().collect();
            if pending.is_empty() {
                run.complete = true;
                self.put_manifest(run, acct, device, me).await;
                log::info!("history hand-off: served {} pages", run.pages);
                break;
            }
            for cid in pending {
                if budget == 0 {
                    break;
                }
                let before = run.cursors.get(&cid).copied().unwrap_or(0);
                let page = self.social.export_history_page(cid.clone(), before, PAGE_EVENTS);
                if page.events == 0 {
                    run.finished.push(cid);
                    continue;
                }
                let blob = encode_page(&cid, &page.envelopes);
                if !self.lane_put(&page_key(acct, device, me, &run.run, run.pages), &blob).await {
                    return did; // no relay took it: resume from this cursor next time
                }
                run.pages += 1;
                run.served_events += u64::from(page.events);
                run.cursors.insert(cid, page.oldest_ms);
                self.put_manifest(run, acct, device, me).await;
                did = true;
                budget -= 1;
                crate::rt::sleep(std::time::Duration::from_millis(20)).await;
            }
        }
        did
    }

    async fn put_manifest(self: &Arc<Self>, run: &Serve, acct: &str, device: &str, me: &str) {
        let m = Manifest {
            v: 1,
            run: run.run.clone(),
            source: me.to_string(),
            for_request: run.request_at,
            pages: run.pages,
            complete: run.complete,
            updated_at: Some(now_ms()),
            total_events: Some(run.total_events),
            served_events: Some(run.served_events),
            cancelled: None,
        };
        if let Ok(body) = serde_json::to_vec(&m) {
            self.lane_put(&manifest_key(acct, device, me), &body).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_page_round_trips_and_reads_apples_two_formats() {
        let envs = vec![vec![0x04, 1, 2], vec![0x02; 300], vec![]];
        let page = encode_page("fam", &envs);
        assert_eq!(decode_page(&page), Some(("fam".to_string(), envs.clone())));
        // v1: no media list at all.
        let mut v1 = b"HVH1".to_vec();
        v1.extend_from_slice(&page[4..page.len() - 4]);
        assert_eq!(decode_page(&v1), Some(("fam".to_string(), envs.clone())));
        // v2 with a media list (ref + size): read past, not returned.
        let mut v2 = page[..page.len() - 4].to_vec();
        v2.extend_from_slice(&1u32.to_le_bytes());
        v2.extend_from_slice(&3u16.to_le_bytes());
        v2.extend_from_slice(b"i:a");
        v2.extend_from_slice(&77u64.to_le_bytes());
        assert_eq!(decode_page(&v2), Some(("fam".to_string(), envs)));
    }

    #[test]
    fn a_page_that_is_not_one_is_refused() {
        assert_eq!(decode_page(b""), None);
        assert_eq!(decode_page(b"NOPE\0\0\0\0\0\0"), None);
        let good = encode_page("c", &[vec![1, 2, 3]]);
        for cut in 0..good.len() {
            assert_eq!(decode_page(&good[..cut]), None, "cut at {cut}");
        }
        // A count far beyond what the bytes could hold must not allocate for it.
        let mut lie = b"HVH1".to_vec();
        lie.extend_from_slice(&1u16.to_le_bytes());
        lie.push(b'c');
        lie.extend_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(decode_page(&lie), None);
    }

    #[test]
    fn the_records_use_apples_field_names() {
        let m: Manifest = serde_json::from_str(
            r#"{"v":1,"run":"17","source":"ab","forRequest":5,"pages":3,"complete":false,"updatedAt":9,"totalEvents":40,"servedEvents":12}"#,
        )
        .unwrap();
        assert_eq!((m.for_request, m.pages, m.total_events, m.served_events), (5, 3, Some(40), Some(12)));
        let back = serde_json::to_string(&m).unwrap();
        assert!(back.contains("\"forRequest\":5") && back.contains("\"updatedAt\":9") && !back.contains("cancelled"));
        // A manifest from a build without the optional fields still reads.
        assert!(serde_json::from_str::<Manifest>(r#"{"v":1,"run":"1","source":"a","forRequest":1,"pages":0,"complete":true}"#).is_ok());
        let r = Request { v: 1, device: "dd".into(), at: 7, done: None, roster: Some("AAEC".into()), cancelled: None };
        assert_eq!(serde_json::to_string(&r).unwrap(), r#"{"v":1,"device":"dd","at":7,"roster":"AAEC"}"#);
        assert_eq!(serde_json::from_str::<Request>(r#"{"v":1,"device":"dd","at":7,"done":true}"#).unwrap().done, Some(true));
    }

    fn manifest(source: &str, run: &str, pages: u32, complete: bool, updated: u64) -> Manifest {
        Manifest { v: 1, run: run.into(), source: source.into(), for_request: 1, pages, complete, updated_at: Some(updated), total_events: None, served_events: None, cancelled: None }
    }

    #[test]
    fn the_source_already_followed_is_kept_while_it_lives() {
        let now = 10 * STALE_SOURCE_MS;
        let a = manifest("a", "1", 2, false, now - 1000);
        let b = manifest("b", "2", 9, false, now - 1000);
        assert_eq!(pick_manifest(&[a.clone(), b.clone()], "a", "1", now).unwrap().source, "a");
        // Nothing followed yet: the one furthest along.
        assert_eq!(pick_manifest(&[a.clone(), b.clone()], "", "", now).unwrap().source, "b");
        // The followed one went quiet: switch.
        let stale = manifest("a", "1", 2, false, now - STALE_SOURCE_MS - 1);
        assert_eq!(pick_manifest(&[stale.clone(), b], "a", "1", now).unwrap().source, "b");
        // Quiet and alone: still better than nothing.
        assert_eq!(pick_manifest(&[stale], "a", "1", now).unwrap().source, "a");
        // Cancelled by the source: never followed.
        let mut gone = a;
        gone.cancelled = Some(true);
        assert!(pick_manifest(&[gone], "a", "1", now).is_none());
    }

    #[test]
    fn a_mailbox_first_listed_right_after_the_ask_is_backlog_and_later_ones_are_not() {
        let mut w = Want { account: "a".into(), at: 1_000, allowed_pages: FIRST_PAGES, ..Default::default() };
        assert!(w.skips_backlog_of("r|c", 2_000));
        w.baselined.push("r|c".into());
        assert!(!w.skips_backlog_of("r|c", 2_000), "only once per mailbox");
        assert!(w.skips_backlog_of("r|d", 2_000));
        assert!(!w.skips_backlog_of("r|d", 1_000 + BASELINE_WINDOW_MS), "a circle joined later is read in full");
        w.fallback = true;
        assert!(!w.skips_backlog_of("r|e", 2_000), "once the relays are the source, nothing is skipped");
        assert!(is_backlog_key("haven/mailbox/c/0123abcd"));
        for k in ["haven/mailbox/c/__hello__/a/b/c", "haven/mailbox/c/__relay__/x", "haven/mailbox/c/__live__/d/e"] {
            assert!(!is_backlog_key(k), "{k}");
        }
    }

    fn keys(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("haven/mailbox/c/{i:04}")).collect()
    }

    #[test]
    fn on_a_relay_that_lists_newest_first_the_newest_stretch_is_read_and_the_rest_waits() {
        let mut w = Want { account: "a".into(), at: 1_000, ..Default::default() };
        let all = keys(RELAY_STRETCH * 2 + 10);
        let plan = w.plan_backlog("r|c", &all, true, 2_000);
        assert_eq!(plan.skip, all[RELAY_STRETCH..].to_vec(), "only what is older than the first stretch is left");
        assert!(plan.reopen.is_empty());
        assert_eq!(w.floors.get("r|c"), Some(&all[RELAY_STRETCH - 1]));
        assert_eq!(w.skipped as usize, RELAY_STRETCH + 10);
        // Listed again with nothing asked: nothing moves.
        assert_eq!(w.plan_backlog("r|c", &all, true, 3_000), BacklogPlan::default());

        // The reader reaches the end: the next stretch, counted from the floor even though two
        // newer posts have arrived above it since.
        w.more_pairs.push("r|c".into());
        let mut later = vec!["haven/mailbox/c/new2".to_string(), "haven/mailbox/c/new1".to_string()];
        later.extend(all.iter().cloned());
        let plan = w.plan_backlog("r|c", &later, true, 4_000);
        assert_eq!(plan.reopen, all[RELAY_STRETCH..RELAY_STRETCH * 2].to_vec());
        assert!(plan.skip.is_empty() && w.more_pairs.is_empty());
        assert_eq!(w.floors.get("r|c"), Some(&all[RELAY_STRETCH * 2 - 1]));

        // The last ten, and then there is no floor left to ask from.
        w.more_pairs.push("r|c".into());
        assert_eq!(w.plan_backlog("r|c", &later, true, 5_000).reopen, all[RELAY_STRETCH * 2..].to_vec());
        assert!(w.floors.is_empty());
        assert_eq!(w.skipped, 0);
    }

    #[test]
    fn a_short_mailbox_is_read_whole_and_hash_order_is_left_alone() {
        let mut w = Want { account: "a".into(), at: 1_000, ..Default::default() };
        let few = keys(7);
        assert_eq!(w.plan_backlog("r|c", &few, true, 2_000), BacklogPlan::default());
        assert!(w.floors.is_empty() && w.baselined == vec!["r|c".to_string()]);
        // A relay that cannot order its listing: nothing in it can be called recent.
        let plan = w.plan_backlog("old|c", &few, false, 2_000);
        assert_eq!(plan.skip, few);
        assert!(w.floors.is_empty());
        // That relay is upgraded later: the newest of what was skipped is read, once.
        let many = keys(RELAY_STRETCH + 5);
        let plan = w.plan_backlog("old|c", &many, true, 9_000_000);
        assert_eq!(plan.reopen, many[..RELAY_STRETCH].to_vec());
        assert_eq!(w.floors.get("old|c"), Some(&many[RELAY_STRETCH - 1]));
        assert_eq!(w.plan_backlog("old|c", &many, true, 9_000_001), BacklogPlan::default());
        w.floors.clear();
        // Asking for more of a mailbox whose floor the relay has swept: nothing, and no loop.
        w.floors.insert("r|d".into(), "haven/mailbox/d/gone".into());
        w.baselined.push("r|d".into());
        w.ordered.push("r|d".into());
        w.more_pairs.push("r|d".into());
        assert_eq!(w.plan_backlog("r|d", &few, true, 3_000), BacklogPlan::default());
        assert!(w.floors.is_empty() && w.more_pairs.is_empty());
    }

    #[test]
    fn the_state_the_page_shows() {
        let mut w = Want { account: "a".into(), at: 1_000, allowed_pages: 6, ..Default::default() };
        assert_eq!(w.state(2_000), "asking");
        assert_eq!(w.state(60_000), "waiting");
        w.run = "9".into();
        assert_eq!(w.state(60_000), "receiving");
        w.next_page = 6;
        assert_eq!(w.state(60_000), "paused");
        w.complete = true;
        assert_eq!(w.state(60_000), "done");
        w.fallback = true;
        assert_eq!(w.state(60_000), "relays");
    }
}
