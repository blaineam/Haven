//! Relay announces (frame 19) that arrived BEFORE this device held the circle's key, and the rules
//! for media in a circle this device knows NO relay for. Android `RelayAnnounceParking` /
//! `NoRelayMediaPolicy` and iOS `RelayAnnounceParking.swift` parity — same constants, same cases;
//! keep the three in step.
//!
//! A relay announce is sealed to the circle, so a freshly (re)installed device that has not yet
//! received the circle's key material cannot open it — and `ingest_relay_announce` used to return
//! `None`, dropping it for good. That is the only way a new device ever learns its FIRST relay (an
//! invite carries device ids, not a relay, and self-sync needs a transport), so a device whose first
//! announce raced its key ran relay-less indefinitely. Park them (bounded, expiring, de-duplicated)
//! and re-process when keys may have landed. Pure and clock-injected so the rules are unit-testable.

use std::collections::VecDeque;

/// Parked announces kept (oldest evicted past this).
pub const PARK_CAPACITY: usize = 64;
/// An announce older than this is dropped instead of retried.
pub const PARK_TTL_MS: u64 = 60 * 60_000;
/// Minimum gap between two drains, so a burst of frames does not spin.
pub const PARK_MIN_RETRY_GAP_MS: u64 = 5_000;

/// Re-asks one ref gets after hints while no relay is known (the author's relay-hint budget).
pub const MAX_REASKS_PER_REF: usize = 3;
/// Spacing between re-asks of the same ref.
pub const REASK_SPACING_MS: u64 = 4_000;
/// One relay-introduction nudge per (author, circle) at most this often.
pub const INTRO_NUDGE_EVERY_MS: u64 = 10 * 60_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parked {
    pub circle_id: String,
    pub sealed: Vec<u8>,
    pub parked_at_ms: u64,
}

pub struct RelayAnnounceParking {
    capacity: usize,
    ttl_ms: u64,
    min_retry_gap_ms: u64,
    items: VecDeque<Parked>, // oldest → newest (insertion / re-park recency)
    drained: bool,
    last_drain_ms: u64,
}

impl Default for RelayAnnounceParking {
    fn default() -> Self {
        Self::new(PARK_CAPACITY, PARK_TTL_MS, PARK_MIN_RETRY_GAP_MS)
    }
}

impl RelayAnnounceParking {
    pub fn new(capacity: usize, ttl_ms: u64, min_retry_gap_ms: u64) -> Self {
        Self { capacity, ttl_ms, min_retry_gap_ms, items: VecDeque::new(), drained: false, last_drain_ms: 0 }
    }

    /// Park an announce; the same sealed bytes (per circle) are kept once. Oldest are evicted past capacity.
    pub fn park(&mut self, circle_id: &str, sealed: &[u8], now_ms: u64) {
        self.items.retain(|p| !(p.circle_id == circle_id && p.sealed == sealed)); // re-park refreshes recency
        self.items.push_back(Parked { circle_id: circle_id.to_string(), sealed: sealed.to_vec(), parked_at_ms: now_ms });
        while self.items.len() > self.capacity {
            self.items.pop_front();
        }
    }

    /// The parked announces to re-process now: none until the retry gap has passed since the last
    /// drain, expired ones are dropped, and the returned ones are REMOVED (a still-unopenable one is
    /// simply parked again by the caller, keeping its place in the bounded queue).
    pub fn drain(&mut self, now_ms: u64) -> Vec<Parked> {
        if self.items.is_empty() || (self.drained && now_ms.saturating_sub(self.last_drain_ms) < self.min_retry_gap_ms) {
            return Vec::new();
        }
        self.drained = true;
        self.last_drain_ms = now_ms;
        let ttl = self.ttl_ms;
        self.items.drain(..).filter(|p| now_ms.saturating_sub(p.parked_at_ms) <= ttl).collect()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }
}

/// Only a fetch that actually asked at least one relay may claim "the relays answered and none holds it".
pub fn relays_answered_empty(relays_asked: usize) -> bool {
    relays_asked > 0
}

/// Re-ask the author right away after a hint we cannot act on (no relay known for the circle).
pub fn re_ask_after_unusable_hint(has_relay: bool, prior_reasks: usize, last_reask_ms: Option<u64>, now_ms: u64) -> bool {
    if has_relay || prior_reasks >= MAX_REASKS_PER_REF {
        return false;
    }
    match last_reask_ms {
        None => true,
        Some(last) => now_ms.saturating_sub(last) >= REASK_SPACING_MS,
    }
}

/// Ask the author to (re)announce their circle relay to us.
pub fn intro_nudge_due(has_relay: bool, last_nudge_ms: Option<u64>, now_ms: u64) -> bool {
    if has_relay {
        return false;
    }
    match last_nudge_ms {
        None => true,
        Some(last) => now_ms.saturating_sub(last) >= INTRO_NUDGE_EVERY_MS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p0() -> RelayAnnounceParking {
        RelayAnnounceParking::new(PARK_CAPACITY, PARK_TTL_MS, 0)
    }

    #[test]
    fn an_announce_parked_before_its_key_is_returned_on_the_next_drain() {
        let mut p = p0();
        p.park("default", b"sealed-1", 1_000);
        let got = p.drain(2_000);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].circle_id, "default");
        assert_eq!(got[0].sealed, b"sealed-1");
        assert_eq!(p.len(), 0, "handed over; the caller re-parks it if it is STILL unopenable");
    }

    #[test]
    fn the_same_announce_is_kept_once() {
        let mut p = p0();
        for i in 0..5 {
            p.park("default", b"same", i);
        }
        assert_eq!(p.len(), 1);
    }

    #[test]
    fn different_circles_are_distinct() {
        let mut p = p0();
        p.park("a", b"x", 1);
        p.park("b", b"x", 1);
        assert_eq!(p.len(), 2);
    }

    #[test]
    fn the_queue_is_bounded_and_keeps_the_newest() {
        let mut p = RelayAnnounceParking::new(3, PARK_TTL_MS, 0);
        for i in 1..=6u64 {
            p.park("c", format!("s{i}").as_bytes(), i);
        }
        assert_eq!(p.len(), 3);
        let mut kept: Vec<String> = p.drain(10).into_iter().map(|x| String::from_utf8(x.sealed).unwrap()).collect();
        kept.sort();
        assert_eq!(kept, vec!["s4", "s5", "s6"]);
    }

    #[test]
    fn expired_announces_are_dropped() {
        let mut p = RelayAnnounceParking::new(PARK_CAPACITY, 1_000, 0);
        p.park("c", b"old", 0);
        p.park("c", b"new", 5_000);
        let got: Vec<Vec<u8>> = p.drain(5_500).into_iter().map(|x| x.sealed).collect();
        assert_eq!(got, vec![b"new".to_vec()]);
    }

    #[test]
    fn drains_are_rate_limited_so_a_burst_of_frames_does_not_spin() {
        let mut p = RelayAnnounceParking::new(PARK_CAPACITY, PARK_TTL_MS, 5_000);
        p.park("c", b"one", 0);
        assert_eq!(p.drain(10_000).len(), 1);
        p.park("c", b"two", 10_001);
        assert!(p.drain(12_000).is_empty(), "too soon after the last drain");
        assert_eq!(p.drain(15_000).len(), 1, "gap elapsed");
    }

    #[test]
    fn the_first_drain_is_never_rate_limited() {
        // The Android sentinel bug (f6e0bf02): a first drain at a small clock value must still return.
        let mut p = RelayAnnounceParking::default();
        p.park("c", b"x", 0);
        assert_eq!(p.drain(1).len(), 1);
    }

    #[test]
    fn an_unopenable_one_parked_again_keeps_getting_retried() {
        let mut p = p0();
        p.park("c", b"later", 0);
        let first = p.drain(1).remove(0);
        p.park(&first.circle_id, &first.sealed, 1); // the key has not landed yet
        assert_eq!(p.drain(2).len(), 1, "still there for the next attempt");
    }

    #[test]
    fn a_fetch_that_asked_no_relay_does_not_claim_the_relays_answered_empty() {
        assert!(!relays_answered_empty(0));
        assert!(relays_answered_empty(1));
        assert!(relays_answered_empty(3));
    }

    #[test]
    fn the_constants_match_android_and_ios() {
        assert_eq!(MAX_REASKS_PER_REF, 3);
        assert_eq!(REASK_SPACING_MS, 4_000);
        assert_eq!(INTRO_NUDGE_EVERY_MS, 600_000);
        assert_eq!((PARK_CAPACITY, PARK_TTL_MS, PARK_MIN_RETRY_GAP_MS), (64, 3_600_000, 5_000));
    }

    #[test]
    fn a_hint_we_can_act_on_is_never_re_asked() {
        assert!(!re_ask_after_unusable_hint(true, 0, None, 10_000));
    }

    #[test]
    fn re_asks_are_spaced_and_capped_at_the_authors_hint_budget() {
        let t0 = 100_000;
        assert!(re_ask_after_unusable_hint(false, 0, None, t0));
        assert!(!re_ask_after_unusable_hint(false, 1, Some(t0), t0 + REASK_SPACING_MS - 1));
        assert!(re_ask_after_unusable_hint(false, 1, Some(t0), t0 + REASK_SPACING_MS));
        assert!(re_ask_after_unusable_hint(false, MAX_REASKS_PER_REF - 1, Some(t0), t0 + 60_000));
        assert!(!re_ask_after_unusable_hint(false, MAX_REASKS_PER_REF, Some(t0), t0 + 60_000));
    }

    #[test]
    fn the_intro_nudge_is_rate_limited_and_only_for_relayless_circles() {
        let now = 1_000_000;
        assert!(!intro_nudge_due(true, None, now));
        assert!(intro_nudge_due(false, None, now));
        assert!(!intro_nudge_due(false, Some(now - 1_000), now));
        assert!(intro_nudge_due(false, Some(now - INTRO_NUDGE_EVERY_MS), now));
    }
}
