//! "Load history from your relays" — the deep relay-mailbox pass (Apple `RelayHistoryResync`,
//! Android `RelayHistory.kt` parity). A child module of `engine` so it can use the engine's relay
//! plumbing directly.
//!
//! The ordinary `poll_mailbox` fetches only keys its seen-set never recorded, and on this platform a
//! key is marked seen when its envelope merely BUFFERED, when it failed to open, and the re-open after
//! a key commit is switched off — so a post that arrived before the key that opens it, and then lost
//! its parked copy, is never looked at again even though the relay still holds it. This pass ignores
//! the seen-set: per circle, per relay, the FULL listing, minus the core planner's own
//! ingested-key journal; fetch in bounded batches; ingest control plane first; save the engine; THEN
//! commit the batch to the journal and the seen-set; one retry pass for what parked; then the media
//! the feed names, relay-first. It never seals, uploads, fans out, notifies or pushes.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use haven_ffi::history_resync::{RelayHistoryItem, RelayHistoryPlanner};
use serde_json::{json, Value};

use super::*;

const BATCH: usize = 24;
const FETCH_CONCURRENCY: usize = 4;

/// One run's honest progress (field meanings: Apple `RelayHistoryProgress`).
#[derive(Clone, Default, Debug, PartialEq)]
pub struct RelayHistoryProgress {
    pub phase: &'static str,
    pub circles_done: usize,
    pub circles_total: usize,
    pub entries_found: usize,
    pub entries_checked: usize,
    pub posts_added: usize,
    pub unreadable: usize,
    pub waiting: usize,
    pub media_done: usize,
    pub media_total: usize,
    pub media_missing: usize,
    pub relay_errors: usize,
    pub media_deferred: bool,
    pub started_ms: u64,
    pub finished_ms: u64,
}

impl RelayHistoryProgress {
    fn running(&self) -> bool {
        matches!(self.phase, "scanning" | "retrying" | "media")
    }

    /// "added" | "uptodate" | "unreachable" — which closing line the summary shows.
    pub fn outcome(&self) -> &'static str {
        if self.posts_added > 0 || self.media_done > 0 {
            "added"
        } else if self.relay_errors > 0
            && self.entries_found == 0
            && self.circles_total > 0
            && self.relay_errors >= self.circles_total
        {
            "unreachable"
        } else {
            "uptodate"
        }
    }

    /// 0…1: the scan is the first 60%, media the rest; an empty phase never holds the bar still.
    pub fn fraction(&self) -> f64 {
        let part = |d: usize, t: usize| if t == 0 { 1.0 } else { (d as f64 / t as f64).min(1.0) };
        match self.phase {
            "scanning" => 0.6 * part(self.circles_done, self.circles_total) * 0.95,
            "retrying" => 0.57 + 0.03 * part(self.entries_checked, self.entries_found),
            "media" => 0.6 + 0.4 * part(self.media_done, self.media_total),
            "done" | "cancelled" => 1.0,
            _ => 0.0,
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "state": if self.phase.is_empty() { "idle" } else { self.phase },
            "circles_done": self.circles_done, "circles_total": self.circles_total,
            "entries_found": self.entries_found, "entries_checked": self.entries_checked,
            "posts_added": self.posts_added, "unreadable": self.unreadable, "waiting": self.waiting,
            "media_done": self.media_done, "media_total": self.media_total,
            "media_missing": self.media_missing, "relay_errors": self.relay_errors,
            "media_deferred": self.media_deferred,
            "started_ms": self.started_ms, "finished_ms": self.finished_ms,
            "outcome": self.outcome(), "fraction": self.fraction(),
            // Relays are a mailbox, not an archive (30-day idle sweep): every finished run says so.
            "retention_caveat": self.phase == "done",
        })
    }
}

/// Each key once, with every relay that listed it, first relay's keys first.
pub fn merge_plans(per_relay: Vec<(String, Vec<String>)>) -> Vec<(String, Vec<String>)> {
    let mut order: Vec<String> = Vec::new();
    let mut nodes: HashMap<String, Vec<String>> = HashMap::new();
    for (node, keys) in per_relay {
        for k in keys {
            let e = nodes.entry(k.clone()).or_insert_with(|| {
                order.push(k.clone());
                Vec::new()
            });
            if !e.contains(&node) {
                e.push(node.clone());
            }
        }
    }
    order.into_iter().map(|k| { let n = nodes.remove(&k).unwrap_or_default(); (k, n) }).collect()
}

/// One media candidate: (ref, circle, is_small, item). `item` is the user-visible photo/video the ref
/// belongs to — its primary ref; a small companion (thumb / preview / poster) names its primary.
pub type MediaCandidate = (String, String, bool, String);

/// The media phase's plan. The summary counts user-visible ITEMS, never refs: a photo, its thumb and
/// its preview are one item. An item counts as done once ANY of its refs landed — on a constrained
/// link only companions are considered at all, so the companion alone is the item; on a normal link
/// a thumb that lands before the full-size file already makes the photo visible in the feed.
#[derive(Debug, Default)]
pub struct MediaPlan {
    /// Items new to the feed (not in `before` — a recovered post or comment named them) that already
    /// have something on disk: counted done up front, whichever path fetched them.
    pub landed: usize,
    /// Items counted: `landed` + items with something to fetch.
    pub total: usize,
    /// Refs to fetch, small companions first (fetch behaviour is per ref, unchanged).
    pub want: Vec<MediaCandidate>,
    counted: HashSet<String>,
}

/// `candidates` in feed order, synthetic refs dropped; `before` = every ref the feed named when the
/// run STARTED. On constrained links only small companions are considered.
pub fn plan_media(
    candidates: Vec<MediaCandidate>, before: &HashSet<String>, constrained: bool,
    has: impl Fn(&str) -> bool, evicted: impl Fn(&str) -> bool,
) -> MediaPlan {
    let mut order: Vec<String> = Vec::new();
    let mut items: HashMap<String, (bool, Vec<MediaCandidate>)> = HashMap::new(); // (any present, missing)
    let mut taken: HashSet<String> = HashSet::new();
    for cand in candidates {
        if (constrained && !cand.2) || !taken.insert(cand.0.clone()) {
            continue;
        }
        let e = items.entry(cand.3.clone()).or_insert_with(|| {
            order.push(cand.3.clone());
            (false, Vec::new())
        });
        if has(&cand.0) {
            e.0 = true;
        } else if !evicted(&cand.0) {
            e.1.push(cand);
        }
    }
    let mut plan = MediaPlan::default();
    for item in order {
        let Some((present, missing)) = items.remove(&item) else { continue };
        if present && !before.contains(&item) {
            plan.landed += 1;
            plan.total += 1;
            plan.counted.insert(item);
        } else if !missing.is_empty() {
            plan.total += 1;
        }
        plan.want.extend(missing);
    }
    plan.want.sort_by_key(|w| !w.2);
    plan
}

/// Turns per-ref fetch results into per-item counts: an item is done at its first ref that lands,
/// missing once every one of its refs failed; an item counted up front never counts again.
pub struct MediaTally {
    pending: HashMap<String, usize>,
    counted: HashSet<String>,
}

impl MediaTally {
    pub fn new(plan: &MediaPlan) -> Self {
        let mut pending: HashMap<String, usize> = HashMap::new();
        for w in &plan.want {
            *pending.entry(w.3.clone()).or_default() += 1;
        }
        Self { pending, counted: plan.counted.clone() }
    }

    /// (done delta, missing delta) for one fetched ref of `item`.
    pub fn record(&mut self, item: &str, ok: bool) -> (usize, usize) {
        let left = self.pending.get_mut(item).map(|n| {
            *n = n.saturating_sub(1);
            *n
        });
        if self.counted.contains(item) {
            (0, 0)
        } else if ok {
            self.counted.insert(item.to_string());
            (1, 0)
        } else if left.unwrap_or(0) == 0 {
            self.counted.insert(item.to_string());
            (0, 1)
        } else {
            (0, 0)
        }
    }
}

struct RhState {
    progress: RelayHistoryProgress,
    cancel: Arc<AtomicBool>,
    planner: Option<Arc<RelayHistoryPlanner>>,
}

fn state() -> &'static parking_lot::Mutex<RhState> {
    static S: OnceLock<parking_lot::Mutex<RhState>> = OnceLock::new();
    S.get_or_init(|| {
        parking_lot::Mutex::new(RhState {
            progress: RelayHistoryProgress::default(),
            cancel: Arc::new(AtomicBool::new(false)),
            planner: None,
        })
    })
}

fn update(f: impl FnOnce(&mut RelayHistoryProgress)) {
    f(&mut state().lock().progress);
}

#[derive(Clone)]
struct Pending {
    circle: String,
    key: String,
    nodes: Vec<String>,
}

impl Engine {
    fn rh_planner(&self) -> Arc<RelayHistoryPlanner> {
        let mut s = state().lock();
        if let Some(p) = &s.planner {
            return p.clone();
        }
        let path = self.paths.root.join("relay-history.journal");
        let p = RelayHistoryPlanner::new(path.to_string_lossy().into_owned());
        s.planner = Some(p.clone());
        p
    }

    fn rh_relays(&self, circle_id: &str) -> Vec<String> {
        self.relays_for(circle_id).into_iter().filter(|h| !h.starts_with("s3:")).collect()
    }

    /// "satellite" | "norelay" | None.
    pub fn relay_history_unavailable(self: &Arc<Self>) -> Option<&'static str> {
        if self.low_data_level() == "ultra" {
            return Some("satellite");
        }
        if !self.social.circles().iter().any(|c| !self.rh_relays(&c.id).is_empty()) {
            return Some("norelay");
        }
        None
    }

    /// The settings row + QA dump: progress plus why it can't run right now.
    pub fn relay_history_status(self: &Arc<Self>) -> Value {
        let mut v = state().lock().progress.to_json();
        v["unavailable"] = json!(self.relay_history_unavailable());
        v["journal_keys"] = json!(self.rh_planner().ingested_count());
        v
    }

    pub fn relay_history_start(self: &Arc<Self>) -> bool {
        if self.relay_history_unavailable().is_some() {
            return false;
        }
        let cancel = {
            let mut s = state().lock();
            if s.progress.running() {
                return false;
            }
            s.progress = RelayHistoryProgress { phase: "scanning", started_ms: now_ms(), ..Default::default() };
            s.cancel = Arc::new(AtomicBool::new(false));
            s.cancel.clone()
        };
        log::info!("relay history: start");
        self.emit_changed();
        let me = self.clone();
        tauri::async_runtime::spawn(async move { me.relay_history_run(cancel).await });
        true
    }

    pub fn relay_history_cancel(&self) {
        state().lock().cancel.store(true, Ordering::SeqCst);
    }

    pub fn relay_history_dismiss(&self) {
        let mut s = state().lock();
        if !s.progress.running() {
            s.progress = RelayHistoryProgress::default();
        }
    }

    /// QA: forget the resync's own journal (a clean first run).
    pub fn relay_history_reset_journal(&self) {
        self.relay_history_cancel();
        self.rh_planner().reset();
        state().lock().progress = RelayHistoryProgress::default();
    }

    /// One relay's FULL listing of a circle's mailbox (no delta digest, no seen-set).
    async fn rh_list(self: &Arc<Self>, circle_id: &str, node: &str) -> Option<Vec<String>> {
        let prefix = format!("haven/mailbox/{circle_id}/");
        if let Some((bases, token)) = self.relay_http_reachable(node) {
            for base in &bases {
                if self.http_url_bad(base) {
                    continue;
                }
                match self.http_list_delta(base, &token, &prefix, None).await {
                    Ok((keys, _)) => {
                        self.mark_relay_ok(node);
                        return Some(keys.unwrap_or_default());
                    }
                    Err(RelayErr::Forbidden) => {
                        self.note_refused(node, "history list");
                        return None;
                    }
                    Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                }
            }
        }
        let client = self.relay_client_for(node).await?;
        let keys = client.list(prefix).await.ok()?;
        self.mark_relay_ok(node);
        Some(keys)
    }

    async fn rh_get(self: &Arc<Self>, node: &str, key: &str) -> Option<Vec<u8>> {
        if let Some((bases, token)) = self.relay_http_reachable(node) {
            for base in &bases {
                if self.http_url_bad(base) {
                    continue;
                }
                match self.http_get(base, &token, key).await {
                    Ok(d) => return d.filter(|d| !d.is_empty()),
                    Err(RelayErr::Forbidden) => return None,
                    Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                }
            }
        }
        let client = self.relay_client_for(node).await?;
        client.get(key.to_string()).await.filter(|d| !d.is_empty())
    }

    fn rh_event_count(&self, circles: &[String]) -> u64 {
        circles.iter().map(|c| self.social.history_event_count(c.clone())).sum()
    }

    async fn relay_history_run(self: Arc<Self>, cancel: Arc<AtomicBool>) {
        let cancelled = || cancel.load(Ordering::SeqCst);
        let circles: Vec<String> = self
            .social
            .circles()
            .into_iter()
            .map(|c| c.id)
            .filter(|c| !self.rh_relays(c).is_empty())
            .collect();
        update(|p| p.circles_total = circles.len());
        let before = self.rh_event_count(&circles);
        // The media the feed already named: anything outside it at the end came from this run.
        let refs_before: HashSet<String> =
            circles.iter().flat_map(|c| self.rh_media_candidates(c)).map(|(r, _, _, _)| r).collect();
        let planner = self.rh_planner();
        let mut retry: Vec<Pending> = Vec::new();
        let mut landed = false;
        for cid in &circles {
            if cancelled() {
                break;
            }
            let mut per_relay = Vec::new();
            let mut listed_any = false;
            for node in self.rh_relays(cid) {
                let Some(keys) = self.rh_list(cid, &node).await else { continue };
                listed_any = true;
                per_relay.push((node, planner.plan(cid.clone(), keys)));
            }
            if !listed_any {
                update(|p| p.relay_errors += 1);
            }
            let work: Vec<Pending> = merge_plans(per_relay)
                .into_iter()
                .map(|(key, nodes)| Pending { circle: cid.clone(), key, nodes })
                .collect();
            update(|p| p.entries_found += work.len());
            for batch in work.chunks(BATCH) {
                if cancelled() {
                    break;
                }
                let (r, changed) = self.rh_ingest(&planner, batch, true).await;
                retry.extend(r);
                landed |= changed;
            }
            update(|p| p.circles_done += 1);
            if landed {
                self.emit_changed();
            }
        }
        if !cancelled() && !retry.is_empty() {
            update(|p| p.phase = "retrying");
            let mut still = 0;
            for batch in retry.chunks(BATCH) {
                if cancelled() {
                    break;
                }
                let (r, changed) = self.rh_ingest(&planner, batch, false).await;
                still += r.len();
                landed |= changed;
            }
            update(|p| p.waiting = still);
        }
        let added = self.rh_event_count(&circles).saturating_sub(before) as usize;
        update(|p| p.posts_added = added);
        if landed {
            self.emit_changed();
        }
        log::info!("relay history: scan done {:?}", state().lock().progress);
        if !cancelled() {
            update(|p| p.phase = "media");
            self.rh_media(&circles, &refs_before, &cancel).await;
        }
        update(|p| {
            p.phase = if cancelled() { "cancelled" } else { "done" };
            p.finished_ms = now_ms();
        });
        log::info!("relay history: finished {:?}", state().lock().progress);
        self.emit_changed();
    }

    /// Fetch → ingest → save → commit. Returns (keys to retry, whether anything applied).
    async fn rh_ingest(
        self: &Arc<Self>, planner: &Arc<RelayHistoryPlanner>, batch: &[Pending], counting: bool,
    ) -> (Vec<Pending>, bool) {
        let mut got: Vec<Option<Vec<u8>>> = Vec::with_capacity(batch.len());
        for group in batch.chunks(FETCH_CONCURRENCY) {
            let futs = group.iter().map(|p| {
                let me = self.clone();
                let p = p.clone();
                async move {
                    for n in &p.nodes {
                        if let Some(d) = me.rh_get(n, &p.key).await {
                            return Some(d);
                        }
                    }
                    None
                }
            });
            let handles: Vec<_> = futs.map(tauri::async_runtime::spawn).collect();
            for h in handles {
                got.push(h.await.ok().flatten());
            }
        }
        let meta: HashMap<&str, &Pending> = batch.iter().map(|p| (p.key.as_str(), p)).collect();
        let mut by_circle: Vec<(String, Vec<RelayHistoryItem>)> = Vec::new();
        for (p, d) in batch.iter().zip(got) {
            let Some(d) = d else { continue };
            let item = RelayHistoryItem { key: p.key.clone(), envelope: d };
            match by_circle.iter_mut().find(|(c, _)| c == &p.circle) {
                Some((_, v)) => v.push(item),
                None => by_circle.push((p.circle.clone(), vec![item])),
            }
        }
        let mut retry = Vec::new();
        let mut processed = Vec::new();
        let mut changed = false;
        let mut unreadable = 0usize;
        for (cid, items) in by_circle {
            let r = planner.ingest(self.social.clone(), cid, items);
            unreadable += r.unreadable as usize;
            changed |= r.applied > 0;
            retry.extend(r.retry.iter().filter_map(|k| meta.get(k.as_str()).map(|p| (*p).clone())));
            processed.extend(r.processed);
        }
        update(|p| {
            if counting {
                p.entries_checked += batch.len();
            }
            p.unreadable += unreadable;
        });
        if processed.is_empty() {
            return (retry, changed);
        }
        // Mark-after-persist: journal + seen-set learn a key only once its event is on disk.
        if store::write_state(&self.paths, &self.social.export_state()).is_ok() {
            if !planner.commit_staged() {
                planner.discard_staged();
            }
            for k in processed {
                self.mark_mailbox_seen(k);
            }
            self.flush_seen_mailbox();
        } else {
            planner.discard_staged();
        }
        (retry, changed)
    }

    /// Every media candidate the circle's feed names — posts, comments and their small companions
    /// (each tagged with the primary it belongs to) — deduped, synthetic refs dropped.
    fn rh_media_candidates(&self, cid: &str) -> Vec<MediaCandidate> {
        let mut refs: Vec<String> = Vec::new();
        for item in self.social.feed(cid.to_string(), now_ms(), None) {
            refs.extend(item.media.iter().cloned());
            for c in &item.comments {
                refs.extend(c.media.iter().cloned());
            }
        }
        let mut primary: HashMap<String, String> = HashMap::new();
        for r in &refs {
            let pair = Self::parse_thumb_marker(r)
                .or_else(|| Self::parse_preview_marker(r))
                .or_else(|| haven_p2p::mediavariants::parse_poster(r));
            if let Some((content, small)) = pair {
                primary.entry(small.to_string()).or_insert_with(|| content.to_string());
            }
        }
        let small: HashSet<String> = Self::small_companion_refs(&refs).into_iter().collect();
        let mut seen: HashSet<String> = HashSet::new();
        refs.iter()
            .chain(small.iter())
            .filter(|r| !LocalMedia::is_synthetic(r) && seen.insert((*r).clone()))
            .map(|r| {
                let item = primary.get(r).cloned().unwrap_or_else(|| r.clone());
                (r.clone(), cid.to_string(), small.contains(r), item)
            })
            .collect()
    }

    /// "Photos and videos" = ITEMS this run brought onto the device: items new to the feed with
    /// something on disk now (whichever path fetched it) plus items this phase fetches itself.
    async fn rh_media(self: &Arc<Self>, circles: &[String], before: &HashSet<String>, cancel: &Arc<AtomicBool>) {
        let constrained = self.low_data_level() != "normal";
        let candidates: Vec<_> = circles.iter().flat_map(|c| self.rh_media_candidates(c)).collect();
        let plan = plan_media(candidates, before, constrained, |r| self.media.has(r), |r| self.evicted_contains(r));
        let mut tally = MediaTally::new(&plan);
        update(|p| {
            p.media_total = plan.total;
            p.media_done = plan.landed;
        });
        for (r, cid, _, item) in &plan.want {
            if cancel.load(Ordering::SeqCst) {
                return;
            }
            let ok = self.media.has(r) || self.fetch_media_healing(cid, r).await;
            let (done, missing) = tally.record(item, ok);
            update(|p| {
                p.media_done += done;
                p.media_missing += missing;
            });
            if ok {
                self.emit_changed();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_dedupes_across_relays_in_relay_order() {
        let m = merge_plans(vec![
            ("r1".into(), vec!["a".into(), "b".into()]),
            ("r2".into(), vec!["b".into(), "c".into()]),
            ("r2".into(), vec!["b".into()]),
        ]);
        assert_eq!(m.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert_eq!(m[1].1, vec!["r1".to_string(), "r2".to_string()]);
        assert_eq!(m[2].1, vec!["r2".to_string()]);
    }

    fn c(r: &str, small: bool, item: &str) -> MediaCandidate {
        (r.into(), "circle".into(), small, item.into())
    }

    fn set(v: &[&str]) -> HashSet<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// The e2e: ONE recovered photo post (photo + thumb + preview), all three already fetched by the
    /// ordinary ingest path → one item, done.
    #[test]
    fn media_plan_counts_one_recovered_photo_with_companions_as_one_item() {
        let cands = vec![c("p", false, "p"), c("p.t", true, "p"), c("p.v", true, "p")];
        let disk = set(&["p", "p.t", "p.v"]);
        let plan = plan_media(cands.clone(), &set(&[]), false, |r| disk.contains(r), |_| false);
        assert_eq!((plan.landed, plan.total, plan.want.len()), (1, 1, 0));
        // Nothing fetched yet: the three refs are fetched small-first, the item counts once.
        let plan = plan_media(cands.clone(), &set(&[]), false, |_| false, |_| false);
        assert_eq!((plan.landed, plan.total), (0, 1));
        assert_eq!(plan.want.iter().map(|w| w.0.as_str()).collect::<Vec<_>>(), ["p.t", "p.v", "p"]);
        let mut t = MediaTally::new(&plan);
        let sum = plan.want.iter().map(|w| t.record(&w.3, true)).fold((0, 0), |a, d| (a.0 + d.0, a.1 + d.1));
        assert_eq!(sum, (1, 0));
        // Only the full-size landed by another path, companions still to fetch: done up front, once.
        let disk = set(&["p"]);
        let plan = plan_media(cands.clone(), &set(&[]), false, |r| disk.contains(r), |_| false);
        assert_eq!((plan.landed, plan.total, plan.want.len()), (1, 1, 2));
        let mut t = MediaTally::new(&plan);
        assert_eq!(t.record("p", false), (0, 0));
        assert_eq!(t.record("p", true), (0, 0));
        // Constrained: the companion alone is the item.
        let disk = set(&["p.t"]);
        let plan = plan_media(cands, &set(&[]), true, |r| disk.contains(r), |_| false);
        assert_eq!((plan.landed, plan.total, plan.want.len()), (1, 1, 1));
        let p = RelayHistoryProgress { phase: "done", posts_added: 2, media_done: 1, media_total: 1, ..Default::default() };
        assert_eq!(p.outcome(), "added");
    }

    #[test]
    fn media_plan_old_media_missing_items_and_eviction() {
        // Old item "a" (thumb on disk, full missing), recovered "b" fully on disk, old "gone" evicted,
        // old "x" whose two refs both fail.
        let before = set(&["a", "a.t", "gone", "x", "x.t"]);
        let disk = set(&["a.t", "b", "b.t"]);
        let cands = vec![
            c("a", false, "a"), c("a.t", true, "a"), c("b", false, "b"), c("b.t", true, "b"),
            c("gone", false, "gone"), c("x", false, "x"), c("x.t", true, "x"),
        ];
        let plan = plan_media(cands, &before, false, |r| disk.contains(r), |r| r == "gone");
        assert_eq!(plan.landed, 1, "old media already there never counts; the recovered item once");
        assert_eq!(plan.total, 3);
        assert_eq!(plan.want.iter().map(|w| w.0.as_str()).collect::<Vec<_>>(), ["x.t", "a", "x"]);
        let mut t = MediaTally::new(&plan);
        assert_eq!(t.record("x", false), (0, 0), "x still has a ref to try");
        assert_eq!(t.record("a", true), (1, 0));
        assert_eq!(t.record("x", false), (0, 1), "every ref of x failed → one missing item");
    }

    #[test]
    fn progress_fraction_outcome_and_caveat() {
        let mut p = RelayHistoryProgress { phase: "scanning", circles_total: 4, ..Default::default() };
        let mut last = p.fraction();
        for d in 1..=4 {
            p.circles_done = d;
            assert!(p.fraction() >= last);
            last = p.fraction();
        }
        p.phase = "media";
        assert!((p.fraction() - 1.0).abs() < 1e-9, "empty media phase is complete at once");
        p.phase = "done";
        assert_eq!(p.outcome(), "uptodate");
        assert_eq!(p.to_json()["retention_caveat"], json!(true));
        p.posts_added = 3;
        assert_eq!(p.outcome(), "added");
        let q = RelayHistoryProgress { phase: "done", circles_total: 2, relay_errors: 2, ..Default::default() };
        assert_eq!(q.outcome(), "unreachable");
        assert_eq!(RelayHistoryProgress { phase: "cancelled", ..Default::default() }.to_json()["retention_caveat"], json!(false));
    }
}
