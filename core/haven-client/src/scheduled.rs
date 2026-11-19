//! Scheduled messages — "send later" with no server, mirroring the iOS `ScheduledStore`.
//! Items are queued to a small JSON file and fired by an in-process timer when their time
//! arrives (and once on launch, so anything overdue while the app was closed goes out then).
//! Because Haven is serverless, delivery only happens while the app is running — exactly like
//! the iOS behaviour.

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// A portable song reference attached to a scheduled post (serialisable; converted to the
/// core `TrackRefFfi` at fire time).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct SchedTrack {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub artwork_url: String,
    #[serde(default)]
    pub duration_ms: u64,
}

/// Whether a queued item is a circle post or a direct message.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SchedKind {
    Post,
    Dm,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScheduledItem {
    pub id: String,
    pub kind: SchedKind,
    /// Target circle (a `dm:` circle for a DM).
    pub circle_id: String,
    pub body: String,
    #[serde(default)]
    pub media: Vec<String>,
    #[serde(default)]
    pub music: Option<SchedTrack>,
    #[serde(default)]
    pub mute_video: bool,
    /// Wall-clock send time (epoch ms).
    pub send_at_ms: u64,
    pub created_at_ms: u64,
}

/// The queue, persisted to `scheduled.json`.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ScheduledStore {
    #[serde(default)]
    pub items: Vec<ScheduledItem>,
}

impl ScheduledStore {
    pub fn load(file: &Path) -> Self {
        match fs::read(file) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => ScheduledStore::default(),
        }
    }

    pub fn save(&self, file: &Path) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self).unwrap_or_default();
        fs::write(file, bytes)
    }

    pub fn add(&mut self, item: ScheduledItem) {
        self.items.push(item);
        self.items.sort_by_key(|i| i.send_at_ms);
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.items.len();
        self.items.retain(|i| i.id != id);
        self.items.len() != before
    }

    /// Split out everything due at `now_ms`, leaving only the still-pending items in `self`.
    /// Pure + deterministic so it's unit-testable without any clock or I/O.
    pub fn take_due(&mut self, now_ms: u64) -> Vec<ScheduledItem> {
        let mut due = Vec::new();
        let mut pending = Vec::new();
        for it in self.items.drain(..) {
            if it.send_at_ms <= now_ms {
                due.push(it);
            } else {
                pending.push(it);
            }
        }
        self.items = pending;
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, at: u64) -> ScheduledItem {
        ScheduledItem {
            id: id.into(),
            kind: SchedKind::Post,
            circle_id: "default".into(),
            body: format!("body {id}"),
            media: vec![],
            music: None,
            mute_video: false,
            send_at_ms: at,
            created_at_ms: 0,
        }
    }

    #[test]
    fn add_keeps_items_sorted_by_send_time() {
        let mut s = ScheduledStore::default();
        s.add(item("c", 300));
        s.add(item("a", 100));
        s.add(item("b", 200));
        let order: Vec<_> = s.items.iter().map(|i| i.id.clone()).collect();
        assert_eq!(order, vec!["a", "b", "c"]);
    }

    #[test]
    fn take_due_partitions_on_now() {
        let mut s = ScheduledStore::default();
        s.add(item("past", 50));
        s.add(item("now", 100));
        s.add(item("future", 150));
        let due = s.take_due(100);
        let due_ids: Vec<_> = due.iter().map(|i| i.id.clone()).collect();
        assert_eq!(due_ids, vec!["past", "now"]); // <= now fires
        assert_eq!(s.items.len(), 1);
        assert_eq!(s.items[0].id, "future");
    }

    #[test]
    fn take_due_empty_when_nothing_ready() {
        let mut s = ScheduledStore::default();
        s.add(item("future", 9999));
        assert!(s.take_due(100).is_empty());
        assert_eq!(s.items.len(), 1);
    }

    #[test]
    fn remove_by_id() {
        let mut s = ScheduledStore::default();
        s.add(item("a", 1));
        s.add(item("b", 2));
        assert!(s.remove("a"));
        assert!(!s.remove("a"));
        assert_eq!(s.items.len(), 1);
        assert_eq!(s.items[0].id, "b");
    }

    #[test]
    fn save_load_round_trip() {
        let dir = std::env::temp_dir().join(format!("haven-sched-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let file = dir.join("scheduled.json");
        let mut s = ScheduledStore::default();
        s.add(item("a", 123));
        s.items[0].music = Some(SchedTrack { catalog_id: "x".into(), title: "T".into(), artist: "A".into(), ..Default::default() });
        s.save(&file).unwrap();
        let back = ScheduledStore::load(&file);
        assert_eq!(back.items, s.items);
        let _ = fs::remove_dir_all(&dir);
    }
}
