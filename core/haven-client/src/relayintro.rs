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
/// The member enroll's steady-state gate (iOS/Android parity): the set changes rarely.
pub const ENROLL_GAP_MS: u64 = 600_000;
/// A FAILED enroll (relay unreachable, dial failed, refused) is retried this soon, not after the
/// steady-state gate: a brand-new member stays refused ("media never loads, my DMs don't send") until
/// the relay hears the list, so one lost attempt must not cost ten minutes.
pub const ENROLL_RETRY_GAP_MS: u64 = 60_000;

/// What the engine remembers per circle about the last member enroll.
#[derive(Default, Clone)]
pub struct EnrollState {
    /// When the last attempt started (`None` = never).
    pub last_ms: Option<u64>,
    /// The relays that attempt addressed.
    pub relays: BTreeSet<String>,
    /// The member list a relay last ACCEPTED (set only when an enroll landed).
    pub members: BTreeSet<String>,
    /// Whether the latest attempt landed on at least one relay.
    pub landed: bool,
}

/// The member-enroll gate. Due when forced, never enrolled, the circle's relay set gained a relay since
/// the last enroll (that relay has never heard the list), the MEMBER SET differs from the one a relay
/// last accepted (`members_changed` — a contact or device that joined without an approval), the last
/// attempt did not land and [`ENROLL_RETRY_GAP_MS`] has passed, or [`ENROLL_GAP_MS`] has passed.
/// iOS `RelayIntroduction.enrollDue` / Android `RelayIntroduction.enrollDue` parity.
pub fn enroll_due(
    now_ms: u64,
    last_ms: Option<u64>,
    last_relays: &BTreeSet<String>,
    relays: &[String],
    force: bool,
    members_changed: bool,
    last_landed: bool,
) -> bool {
    if force {
        return true;
    }
    let Some(last) = last_ms else { return true };
    if relays.iter().any(|r| !last_relays.contains(&r.to_lowercase())) {
        return true;
    }
    // A relay that never answers the verb (older build, unreachable) must not be re-dialed every
    // heartbeat: after a failed attempt the retry gap applies even to a changed member set.
    if !last_landed {
        return now_ms.saturating_sub(last) >= ENROLL_RETRY_GAP_MS;
    }
    if members_changed {
        return true;
    }
    now_ms.saturating_sub(last) >= ENROLL_GAP_MS
}

/// Which outbound call frames re-open a peer's iroh dial backoff first. Mobile/desktop dial backoff runs
/// minutes after failed connects; a call is the moment the user said "this person, now", so an INVITE (or
/// the callee's ACCEPT) must not wait out a strike count built while the peer was offline. Call SETUP
/// frames only — ICE/SDP/hangup and the sealed media frames that share the path never re-arm a dial.
/// iOS/Android `CallDialPolicy` parity.
pub fn call_setup_forgives_dial(frame_type: u8) -> bool {
    matches!(frame_type, 10 | 11 | 21 | 22)
}

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

    fn set(rs: &[&str]) -> BTreeSet<String> {
        rs.iter().map(|r| r.to_string()).collect()
    }

    #[test]
    fn a_new_member_set_reopens_the_gate_without_waiting_ten_minutes() {
        let ra = "a".repeat(64);
        let enrolled = set(&[&ra]);
        assert!(!enroll_due(60_000, Some(0), &enrolled, &[ra.clone()], false, false, true));
        assert!(enroll_due(60_000, Some(0), &enrolled, &[ra.clone()], false, true, true));
    }

    #[test]
    fn a_failed_enroll_retries_in_a_minute_not_ten() {
        let ra = "a".repeat(64);
        let enrolled = set(&[&ra]);
        assert!(!enroll_due(31_000, Some(1_000), &enrolled, &[ra.clone()], false, false, false));
        assert!(enroll_due(1_000 + ENROLL_RETRY_GAP_MS, Some(1_000), &enrolled, &[ra.clone()], false, false, false));
        assert!(ENROLL_RETRY_GAP_MS < ENROLL_GAP_MS);
    }

    #[test]
    fn a_relay_that_never_answers_the_verb_is_not_redialed_every_heartbeat() {
        let ra = "a".repeat(64);
        let enrolled = set(&[&ra]);
        assert!(!enroll_due(21_000, Some(1_000), &enrolled, &[ra.clone()], false, true, false));
    }

    #[test]
    fn force_and_a_new_relay_still_win_over_everything() {
        let ra = "a".repeat(64);
        let rb = "b".repeat(64);
        let enrolled = set(&[&ra]);
        assert!(enroll_due(2_000, Some(1_000), &enrolled, &[ra.clone()], true, false, false));
        assert!(enroll_due(2_000, Some(1_000), &enrolled, &[ra.clone(), rb], false, false, false));
        assert!(enroll_due(0, None, &BTreeSet::new(), &[ra], false, false, true));
    }

    #[test]
    fn call_setup_frames_forgive_the_dial_backoff_and_signaling_never_does() {
        for t in [10u8, 11, 21, 22] {
            assert!(call_setup_forgives_dial(t), "type {t}");
        }
        for t in [12u8, 13, 15, 16, 17, 18, 31, 32, 33] {
            assert!(!call_setup_forgives_dial(t), "type {t}");
        }
    }

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
