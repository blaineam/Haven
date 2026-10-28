//! Local-only index of multi-circle posts: which (circle, event id) copies are the SAME post.
//!
//! A multi-circle post is authored once per circle, so on the wire it is N unrelated posts. This
//! index (never sent anywhere, no core/wire change) lets an edit of any one copy be re-authored
//! into every sibling. Pure logic + a tiny JSON persistence layer so it is testable without the
//! engine. Posts made before this existed have no group and edit one circle only, as before.

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// Oldest groups are evicted past this many.
pub const MAX_GROUPS: usize = 500;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct PostGroups {
    /// Oldest first. Each group is a list of (circle_id, event_id) with >1 distinct circles.
    #[serde(default)]
    pub groups: Vec<Vec<(String, String)>>,
}

impl PostGroups {
    pub fn load(file: &Path) -> Self {
        match fs::read(file) {
            Ok(b) => serde_json::from_slice(&b).unwrap_or_default(),
            Err(_) => PostGroups::default(),
        }
    }

    pub fn save(&self, file: &Path) -> std::io::Result<()> {
        fs::write(file, serde_json::to_vec(self).unwrap_or_default())
    }

    /// Record a group. Ignored (false) unless it spans more than one distinct circle.
    pub fn register(&mut self, members: Vec<(String, String)>) -> bool {
        let mut seen = std::collections::HashSet::new();
        let members: Vec<_> = members.into_iter().filter(|(c, _)| seen.insert(c.clone())).collect();
        if members.len() < 2 {
            return false;
        }
        self.groups.push(members);
        if self.groups.len() > MAX_GROUPS {
            let over = self.groups.len() - MAX_GROUPS;
            self.groups.drain(..over);
        }
        true
    }

    /// Every OTHER copy of the post that (circle, event) belongs to; empty when ungrouped.
    pub fn siblings(&self, circle_id: &str, event_id: &str) -> Vec<(String, String)> {
        self.groups
            .iter()
            .find(|g| g.iter().any(|(c, e)| c == circle_id && e == event_id))
            .map(|g| g.iter().filter(|(c, _)| c != circle_id).cloned().collect())
            .unwrap_or_default()
    }

    /// Like [`siblings`], dropping copies whose circle no longer exists.
    pub fn live_siblings(&self, circle_id: &str, event_id: &str, circle_exists: impl Fn(&str) -> bool) -> Vec<(String, String)> {
        self.siblings(circle_id, event_id).into_iter().filter(|(c, _)| circle_exists(c)).collect()
    }

    /// The whole group's circle ids (including this copy's), empty when ungrouped.
    pub fn circle_set(&self, circle_id: &str, event_id: &str) -> Vec<String> {
        self.groups
            .iter()
            .find(|g| g.iter().any(|(c, e)| c == circle_id && e == event_id))
            .map(|g| g.iter().map(|(c, _)| c.clone()).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(c: &str, e: &str) -> (String, String) {
        (c.to_string(), e.to_string())
    }

    #[test]
    fn registers_only_when_more_than_one_circle() {
        let mut g = PostGroups::default();
        assert!(!g.register(vec![]));
        assert!(!g.register(vec![m("a", "1")]));
        assert!(!g.register(vec![m("a", "1"), m("a", "2")]), "same circle twice is one circle");
        assert!(g.groups.is_empty());
        assert!(g.register(vec![m("a", "1"), m("b", "2")]));
        assert_eq!(g.groups.len(), 1);
    }

    #[test]
    fn lookup_by_circle_and_event() {
        let mut g = PostGroups::default();
        g.register(vec![m("a", "1"), m("b", "2"), m("c", "3")]);
        assert_eq!(g.siblings("b", "2"), vec![m("a", "1"), m("c", "3")]);
        assert!(g.siblings("b", "9").is_empty(), "right circle, wrong event");
        assert!(g.siblings("z", "2").is_empty(), "right event, wrong circle");
        assert_eq!(g.circle_set("a", "1"), vec!["a", "b", "c"]);
        assert!(g.circle_set("a", "x").is_empty());
    }

    #[test]
    fn missing_sibling_circle_is_skipped() {
        let mut g = PostGroups::default();
        g.register(vec![m("a", "1"), m("b", "2"), m("c", "3")]);
        let live = g.live_siblings("a", "1", |c| c != "b");
        assert_eq!(live, vec![m("c", "3")]);
    }

    #[test]
    fn cap_evicts_oldest() {
        let mut g = PostGroups::default();
        for i in 0..(MAX_GROUPS + 3) {
            g.register(vec![m("a", &format!("a{i}")), m("b", &format!("b{i}"))]);
        }
        assert_eq!(g.groups.len(), MAX_GROUPS);
        assert!(g.siblings("a", "a0").is_empty(), "oldest evicted");
        assert!(g.siblings("a", "a2").is_empty());
        assert!(!g.siblings("a", "a3").is_empty(), "first survivor");
        assert!(!g.siblings("a", &format!("a{}", MAX_GROUPS + 2)).is_empty());
    }

    #[test]
    fn persists_round_trip_and_tolerates_garbage() {
        let dir = std::env::temp_dir().join(format!("pg-{}-{:?}", std::process::id(), std::thread::current().id()));
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("post-groups.json");
        let mut g = PostGroups::default();
        g.register(vec![m("a", "1"), m("b", "2")]);
        g.save(&f).unwrap();
        assert_eq!(PostGroups::load(&f), g);
        fs::write(&f, b"{{").unwrap();
        assert!(PostGroups::load(&f).groups.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }
}
