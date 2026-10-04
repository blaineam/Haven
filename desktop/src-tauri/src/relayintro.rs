//! A relay that just JOINED one of our circles (adopted, announced by a member, synced from a sibling
//! device, or made the all-circles default) serves nobody until it has been introduced: it needs our
//! account-signed device roster (so it authorizes THIS device's id, not only the account id its link
//! named) and, from a member it already serves, the circle's member list (`enroll_members`). Both ran
//! only on the ~2-minute backfill tick, so a friend waited out the tick's phase before the new relay
//! answered them (e2e `multirelay`: 105–177 s). The engine heartbeat (10 s) now diffs the relay map and
//! introduces whatever joined. iOS `RelayIntroduction` / Android `RelayIntroduction` parity.

use std::collections::{BTreeSet, HashMap};

/// A relay that keeps re-joining (announce echoes) is introduced at most this often.
pub const REINTRODUCE_GAP_MS: u64 = 30_000;
/// Circle id meaning "every circle" — a relay made the all-circles default joined all of them.
pub const ALL_CIRCLES: &str = "*";

#[derive(Default)]
pub struct RelayIntroduction {
    /// The last relay map seen (`circle → relays`, plus the default under [`ALL_CIRCLES`]); `None`
    /// until the first look, which only seeds — what we start with was introduced in an earlier run.
    seen: Option<HashMap<String, BTreeSet<String>>>,
    introduced_at_ms: HashMap<String, u64>,
    pending: BTreeSet<String>,
}

impl RelayIntroduction {
    /// Record the current relay map; returns true when something JOINED and an introduction is due
    /// (then call [`Self::drain`]). The same (circle, relay) inside [`REINTRODUCE_GAP_MS`] is ignored;
    /// s3 pseudo-relays are never introduced (they have no auth map).
    pub fn observe(&mut self, now_ms: u64, current: HashMap<String, BTreeSet<String>>) -> bool {
        let Some(before) = self.seen.replace(current.clone()) else { return false };
        let mut due = false;
        for (cid, relays) in &current {
            for r in relays {
                if before.get(cid).is_some_and(|b| b.contains(r)) {
                    continue;
                }
                due |= self.note_joined(cid, r, now_ms);
            }
        }
        due
    }

    fn note_joined(&mut self, circle_id: &str, relay: &str, now_ms: u64) -> bool {
        let r = relay.to_lowercase();
        if r.len() != 64 || r.starts_with("s3:") || circle_id.is_empty() {
            return false;
        }
        let key = format!("{circle_id}|{r}");
        if let Some(at) = self.introduced_at_ms.get(&key) {
            if now_ms.saturating_sub(*at) < REINTRODUCE_GAP_MS {
                return false;
            }
        }
        self.introduced_at_ms.insert(key, now_ms);
        self.pending.insert(circle_id.to_string());
        true
    }

    /// The circles to introduce now ([`ALL_CIRCLES`] expanded against `circle_ids`), clearing the queue.
    pub fn drain(&mut self, circle_ids: &[String]) -> Vec<String> {
        let pending = std::mem::take(&mut self.pending);
        if pending.contains(ALL_CIRCLES) {
            return circle_ids.to_vec();
        }
        circle_ids.iter().filter(|c| pending.contains(*c)).cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &[&str])]) -> HashMap<String, BTreeSet<String>> {
        pairs.iter().map(|(c, rs)| (c.to_string(), rs.iter().map(|r| r.to_string()).collect())).collect()
    }

    #[test]
    fn first_look_only_seeds_then_a_joined_relay_is_introduced() {
        let ra = "a".repeat(64);
        let rb = "b".repeat(64);
        let mut p = RelayIntroduction::default();
        assert!(!p.observe(0, map(&[("cS", &[&rb])])));
        assert!(!p.observe(10_000, map(&[("cS", &[&rb])])));
        assert!(p.observe(20_000, map(&[("cS", &[&rb, &ra]), ("cA", &[&ra])])));
        let ids = vec!["default".to_string(), "cA".to_string(), "cS".to_string()];
        assert_eq!(p.drain(&ids), vec!["cA".to_string(), "cS".to_string()]);
        assert!(p.drain(&ids).is_empty());
    }

    #[test]
    fn a_rejoin_inside_the_gap_is_ignored_and_s3_never_counts() {
        let ra = "a".repeat(64);
        let mut p = RelayIntroduction::default();
        p.observe(0, map(&[]));
        assert!(p.observe(1_000, map(&[("cS", &[&ra])])));
        p.drain(&["cS".to_string()]);
        assert!(!p.observe(2_000, map(&[])));
        assert!(!p.observe(3_000, map(&[("cS", &[&ra])])));   // forget + re-add echo
        assert!(!p.observe(4_000, map(&[("cS", &[&ra, "s3:bucket"])])));
        p.observe(5_000, map(&[]));
        assert!(p.observe(REINTRODUCE_GAP_MS + 1_001, map(&[("cS", &[&ra])])));
    }

    #[test]
    fn a_new_default_introduces_every_circle() {
        let ra = "a".repeat(64);
        let mut p = RelayIntroduction::default();
        p.observe(0, map(&[]));
        assert!(p.observe(1_000, map(&[(ALL_CIRCLES, &[&ra])])));
        let ids = vec!["default".to_string(), "cS".to_string()];
        assert_eq!(p.drain(&ids), ids);
    }
}
