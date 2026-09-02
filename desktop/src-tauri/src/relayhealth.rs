//! Per-relay health for graceful fallback. A relay that fails to connect / put / list is put
//! into exponential backoff so we stop hammering a dead relay and quietly use the others — and
//! we retry it later, so a relay that comes back is picked up again automatically. Redundancy
//! (writing to every configured relay) + this backoff = graceful degradation: posts still flow
//! as long as ONE relay (or the BYO S3 bucket, or a direct peer link) is reachable.

const BASE_BACKOFF_MS: u64 = 5_000; // first failure → 5s cool-off
const MAX_BACKOFF_MS: u64 = 300_000; // capped at 5 minutes

const URL_BASE_BACKOFF_MS: u64 = 5_000; // a URL's first failure → 5s, not the old flat 2 minutes
const URL_MAX_BACKOFF_MS: u64 = 120_000; // …escalating to the 2 minutes it used to start at
const URL_STREAK_DECAY_MS: u64 = 300_000; // no failure for 5 minutes → the streak is forgotten

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RelayHealth {
    pub fails: u32,
    /// Earliest time (epoch ms) we'll try this relay again; 0 = available now.
    pub next_retry_ms: u64,
    /// Epoch ms of the last SUCCESSFUL op; 0 = never. Gates what we re-announce to the circle —
    /// vouching for relay ids we haven't actually reached lately is how dead relays echoed
    /// around the mesh forever ("old relays keep coming back").
    pub last_success_ms: u64,
}

impl RelayHealth {
    /// Is the relay usable right now (not in a backoff window)?
    pub fn available(&self, now_ms: u64) -> bool {
        now_ms >= self.next_retry_ms
    }

    /// Did WE personally complete a successful op within `within_ms` of `now_ms`?
    pub fn proven_alive(&self, now_ms: u64, within_ms: u64) -> bool {
        self.last_success_ms > 0 && now_ms.saturating_sub(self.last_success_ms) <= within_ms
    }

    /// A successful operation clears the backoff and stamps proof-of-life.
    pub fn record_success_at(&mut self, now_ms: u64) {
        self.fails = 0;
        self.next_retry_ms = 0;
        self.last_success_ms = now_ms;
    }

    /// A successful operation clears the backoff (no timestamp — prefer `record_success_at`).
    pub fn record_success(&mut self) {
        self.fails = 0;
        self.next_retry_ms = 0;
    }

    /// A failure grows the backoff exponentially (5s, 10s, 20s … capped at 5m).
    pub fn record_failure(&mut self, now_ms: u64) {
        self.fails = self.fails.saturating_add(1);
        let shift = (self.fails - 1).min(6); // cap the exponent so the shift never overflows
        let backoff = BASE_BACKOFF_MS.saturating_mul(1u64 << shift).min(MAX_BACKOFF_MS);
        self.next_retry_ms = now_ms.saturating_add(backoff);
    }
}

/// Per-URL health for a relay's plain-HTTP interface. A relay is reached over ONE of the URLs it
/// announces, and a URL that doesn't answer is backed off so a dead LAN address doesn't cost a
/// connect-timeout per chunk. That back-off used to be a flat 2 minutes from the FIRST failure,
/// which is right for a relay announcing several URLs (the others carry the traffic) and wrong for
/// the shape most people actually run: a NAS/Docker relay behind one hostname, a free-tunnel front
/// door, the QA stub on one loopback port. There the plain-HTTP lane IS the relay — an
/// HTTP-mailbox-only host never iroh-dials, so the "fallback" underneath is nothing at all — and a
/// single refused connect (a laptop opening its lid before Wi-Fi is up, a relay restarting) took
/// mailbox, self-sync, hello and media dark for two full minutes.
///
/// So it escalates instead of starting at the cap: 5s, 10s, 20s … capped at the 2 minutes it used
/// to begin with. A transient costs one heartbeat; a genuinely dead address still reaches the same
/// steady state, ~2.5 minutes in. Same shape as `RelayHealth` above, one level down.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HttpUrlHealth {
    /// Consecutive failures, decayed by `URL_STREAK_DECAY_MS` of quiet.
    pub fails: u32,
    /// Epoch ms of the last failure; 0 = never.
    pub last_fail_ms: u64,
    /// Earliest time (epoch ms) this URL is worth trying again; 0 = now.
    pub next_retry_ms: u64,
}

impl HttpUrlHealth {
    /// Is this URL worth trying right now (not inside a back-off window)?
    pub fn available(&self, now_ms: u64) -> bool {
        now_ms >= self.next_retry_ms
    }

    /// A failure grows the back-off (5s, 10s, 20s … capped at 2m) and returns the new window in ms
    /// so the caller can say out loud how long this URL is parked for.
    ///
    /// There is no success hook to reset the streak — the plain-HTTP ops that succeed are spread
    /// across a dozen call sites and only ever see the relay's node id, not the URL — so the streak
    /// decays on QUIET instead: `URL_STREAK_DECAY_MS` with no failure means whatever went wrong is over.
    /// A URL that is genuinely dead re-fails at least once per capped window, well inside the decay,
    /// so it never gets a free pass; a URL that had one bad moment and then worked all morning does.
    pub fn record_failure(&mut self, now_ms: u64) -> u64 {
        if self.fails > 0 && now_ms.saturating_sub(self.last_fail_ms) >= URL_STREAK_DECAY_MS {
            self.fails = 0;
        }
        self.fails = self.fails.saturating_add(1);
        let shift = (self.fails - 1).min(6); // cap the exponent so the shift never overflows
        let backoff = URL_BASE_BACKOFF_MS.saturating_mul(1u64 << shift).min(URL_MAX_BACKOFF_MS);
        self.last_fail_ms = now_ms;
        self.next_retry_ms = now_ms.saturating_add(backoff);
        backoff
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_http_url_is_available() {
        let h = HttpUrlHealth::default();
        assert!(h.available(0));
        assert!(h.available(1_000_000));
    }

    #[test]
    fn one_transient_costs_seconds_not_two_minutes() {
        // The regression this type exists for: a single refused connect at startup used to park the
        // relay's only HTTP URL for 120s, and with no iroh fallback under an HTTP-only relay that is
        // a total blackout — measured on the desktop e2e leg as a 94.6s profile edit.
        let mut h = HttpUrlHealth::default();
        assert_eq!(h.record_failure(1_000), 5_000);
        assert!(!h.available(1_000 + 4_999));
        assert!(h.available(1_000 + 5_000)); // back before the next 10s heartbeat
    }

    #[test]
    fn repeated_failure_escalates_to_the_old_cap() {
        let mut h = HttpUrlHealth::default();
        assert_eq!(h.record_failure(0), 5_000);
        assert_eq!(h.record_failure(0), 10_000);
        assert_eq!(h.record_failure(0), 20_000);
        assert_eq!(h.record_failure(0), 40_000);
        assert_eq!(h.record_failure(0), 80_000);
        assert_eq!(h.record_failure(0), URL_MAX_BACKOFF_MS); // a genuinely dead address, same as before
        for _ in 0..30 {
            assert_eq!(h.record_failure(0), URL_MAX_BACKOFF_MS); // and it stays there (no overflow)
        }
    }

    #[test]
    fn a_quiet_url_gets_a_fresh_slate() {
        let mut h = HttpUrlHealth::default();
        h.record_failure(0);
        h.record_failure(0);
        h.record_failure(0); // deep in the streak
        // …then it works all morning, so the next bad moment is a FIRST failure again.
        assert_eq!(h.record_failure(URL_STREAK_DECAY_MS), 5_000);
    }

    #[test]
    fn a_dead_url_never_decays_out_of_its_cap() {
        let mut h = HttpUrlHealth::default();
        let mut now = 0u64;
        // A dead URL re-fails once per capped window, which is well inside the decay, so it stays
        // capped instead of cycling back to the 5s base every few minutes.
        for _ in 0..10 {
            let w = h.record_failure(now);
            now += w;
        }
        assert_eq!(h.record_failure(now), URL_MAX_BACKOFF_MS);
    }

    #[test]
    fn fresh_relay_is_available() {
        let h = RelayHealth::default();
        assert!(h.available(0));
        assert!(h.available(1_000_000));
    }

    #[test]
    fn failure_starts_backoff_then_recovers() {
        let mut h = RelayHealth::default();
        h.record_failure(1_000);
        assert!(!h.available(1_000));
        assert!(!h.available(1_000 + 4_999));
        assert!(h.available(1_000 + 5_000)); // 5s base backoff elapsed
    }

    #[test]
    fn backoff_grows_exponentially() {
        let mut h = RelayHealth::default();
        h.record_failure(0); // 5s
        assert_eq!(h.next_retry_ms, 5_000);
        h.record_failure(0); // 10s
        assert_eq!(h.next_retry_ms, 10_000);
        h.record_failure(0); // 20s
        assert_eq!(h.next_retry_ms, 20_000);
    }

    #[test]
    fn backoff_is_capped() {
        let mut h = RelayHealth::default();
        for _ in 0..30 {
            h.record_failure(0);
        }
        assert_eq!(h.next_retry_ms, MAX_BACKOFF_MS); // never grows past the cap (no overflow)
    }

    #[test]
    fn success_resets_backoff() {
        let mut h = RelayHealth::default();
        h.record_failure(1_000);
        h.record_success();
        assert_eq!(h.fails, 0);
        assert!(h.available(1_000));
    }
}
