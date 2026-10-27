//! Which circles inherit a relay they were not explicitly given: the all-circles DEFAULT, and the
//! "every active relay" guess for a circle with no relays yet.
//!
//! The default is meant for a relay the user runs or chose. When it is a FRIEND's relay (a friend-invite
//! ticket's, a wired one, one announced for the circle we share) inheriting it puts a PRIVATE circle's
//! mailbox, enrollment and media on a relay whose operator is not in that circle — e2e `multirelay: no
//! private circle's media on a friend's relay that doesn't serve it`. A relay is a friend's when its node
//! id is a contact's account id or one of that contact's devices; it is withheld from a circle that
//! friend is not a member of. A relay no contact owns (own, hosted, cloud) is inherited by every circle,
//! a friend's relay still serves every circle the friend is IN, and an explicit per-circle assignment is
//! never filtered. Mirrors Android `RelayScope` and iOS `RelayDefaultScope`.

use std::collections::{HashMap, HashSet};

/// Snapshot of circle membership as relay operators (contacts' account + device ids, never mine).
#[derive(Clone, Debug, Default)]
pub struct RelayScope {
    /// Every contact node id across all circles — "a friend's relay" means being in here.
    friends: HashSet<String>,
    /// Per circle, the contact node ids that are IN it.
    members: HashMap<String, HashSet<String>>,
    /// When the snapshot was taken (ms); `0` = never / invalidated.
    built_ms: u64,
    /// False until the first snapshot lands: an engine that never built one filters nothing.
    known: bool,
}

pub const TTL_MS: u64 = 10_000;

impl RelayScope {
    /// Build from per-circle member sets.
    pub fn build(now_ms: u64, members: HashMap<String, HashSet<String>>) -> Self {
        let friends = members.values().flatten().cloned().collect();
        Self { friends, members, built_ms: now_ms, known: true }
    }

    /// Add one circle the snapshot did not list (created after it, or the base circle).
    pub fn learn_circle(&mut self, circle_id: &str, members: HashSet<String>) {
        self.friends.extend(members.iter().cloned());
        self.members.insert(circle_id.to_string(), members);
        self.known = true;
    }

    /// Forget the snapshot (a contact was added or removed).
    pub fn invalidate(&mut self) {
        self.built_ms = 0;
    }

    /// Is the whole snapshot out of date (never built, invalidated, or older than [`TTL_MS`])?
    pub fn expired(&self, now_ms: u64) -> bool {
        !self.known || self.built_ms == 0 || now_ms.saturating_sub(self.built_ms) > TTL_MS
    }

    /// Does the snapshot need work before it can judge `circle_id` at `now_ms`?
    pub fn stale(&self, circle_id: &str, now_ms: u64) -> bool {
        self.expired(now_ms) || !self.members.contains_key(circle_id)
    }

    /// May `circle_id` take `relay_hex` without an explicit assignment? The pure rule: not when it is
    /// a friend's node id and that friend is not in the circle.
    pub fn inherits(&self, circle_id: &str, relay_hex: &str) -> bool {
        if !self.known || relay_hex.starts_with("s3:") {
            return true;
        }
        let hex = relay_hex.to_lowercase();
        if !self.friends.contains(&hex) {
            return true;
        }
        self.members.get(circle_id).is_some_and(|m| m.contains(&hex))
    }

    /// The relays a circle with NO relays of its own may be guessed onto (a self-sync-learned circle whose
    /// record carried an empty list): a relay listed for another circle Y is usable only when EVERYONE in
    /// Y is also in `circle_id`, plus relays no circle lists at all. The old guess was "every active relay",
    /// which read a private circle's mailbox at a friend-operated standalone relay (R_C — its node id is no
    /// contact's, so `inherits` cannot see it); the transport then self-enrolled the circle there
    /// (`recover_forbidden`) and the next media upload was accepted. e2e `multirelay: … A private photo on R_C`.
    pub fn fallback(
        &self,
        circle_id: &str,
        lists: &HashMap<String, Vec<String>>,
        unwired: &[String],
    ) -> Vec<String> {
        let empty = HashSet::new();
        let mine = self.members.get(circle_id).unwrap_or(&empty);
        let mut out: Vec<String> = unwired.to_vec();
        for (y, relays) in lists {
            if y == circle_id {
                continue;
            }
            if self.members.get(y).unwrap_or(&empty).iter().all(|m| mine.contains(m)) {
                for r in relays {
                    if !out.contains(r) {
                        out.push(r.clone());
                    }
                }
            }
        }
        out
    }
}
