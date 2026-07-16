//! Live device-to-device delivery (multi-device D16, Phase 4b): hand a payload straight to the
//! user's OTHER devices over iroh while they're online, so a sibling doesn't sit waiting for its
//! next mailbox poll (~30s base on Android/desktop, ~120s on iOS) to learn what just happened.
//!
//! ## This is an optimisation, and it is never a replacement
//!
//! The mailbox put stays **unconditional**. Live delivery decides only *how fast* a sibling learns
//! something — never *whether* it can. Two reasons this is not negotiable:
//!
//! 1. **The sender cannot know the recipient set.** A device that is offline right now, or that the
//!    user links tomorrow, can only ever be served by the durable mailbox. "I reached both devices
//!    I know about" is not the same claim as "everyone has it", so a successful live push can never
//!    license skipping the put.
//! 2. **Absence is not deletion.** A device that missed a live push has not learned anything — least
//!    of all that a record is gone. Every consumer of what we deliver here merges through the
//!    [`haven_p2p::selfsync`] CRDT, where a missed message is indistinguishable from one not yet sent
//!    and only an explicit (newer-stamped) tombstone removes anything. Nothing downstream may treat
//!    "you didn't get it live" as information.
//!
//! So the delivery guarantee is exactly what it is today, and the failure mode of everything in this
//! module is "the sibling finds out on its next poll, as it always did".
//!
//! ## What ordering buys here (and what it doesn't)
//!
//! The Phase 4b sketch says "ordered store-and-forward". For account state that phrasing oversells
//! it: [`AccountState::merge`](haven_p2p::selfsync::AccountState::merge) is commutative, associative
//! and idempotent, so a live push that arrives out of order, twice, or not at all converges to the
//! same state anyway. Ordering matters for the **epoch KeyCommit backlog** (a device must see a
//! commit to hold the key that opens content sealed under it) — that is a property of the mailbox
//! backlog, not of this path. This module therefore promises no order, and deliberately does not
//! invent one the engine does not need.

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use crate::Node;

/// How long ONE sibling's direct attempt may take before we stop waiting on it. Live delivery is a
/// latency optimisation: something that takes longer than this has already lost to the mailbox
/// poll it was meant to beat, so we mark it unreached and move on rather than block the caller.
/// (iroh's own dial timeout is ~30s — far too long to hold a UI-triggered push behind.)
pub const DEVICE_DEADLINE: Duration = Duration::from_secs(3);

/// Ceiling on a whole [`deliver_to_own_devices`] call, so N offline siblings cost ~this much and
/// not N × [`DEVICE_DEADLINE`]. Devices we never got to are reported unreached — which, per the
/// module docs, costs them nothing but latency.
pub const TOTAL_BUDGET: Duration = Duration::from_secs(5);

/// Which siblings took the payload live, and which are left to the mailbox.
///
/// `unreached` is **not** an error and not a durability signal — the caller's unconditional mailbox
/// put covers exactly these devices (and the ones we were never told about). It exists so callers
/// can log/measure how often the fast path wins.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct LiveDelivery {
    /// Device transport ids (hex) that accepted the payload on a live connection.
    pub delivered: Vec<String>,
    /// Device transport ids (hex) that were offline, too slow, or squeezed out by the budget.
    pub unreached: Vec<String>,
}

impl LiveDelivery {
    /// Did at least one sibling take it live? (Diagnostics only — never a reason to skip the put.)
    pub fn any_delivered(&self) -> bool {
        !self.delivered.is_empty()
    }
}

/// Push `payload` directly to each of the user's own `devices`, best-effort, and report who took it.
///
/// `devices` must be **device transport ids**, never the account id: under per-device transport
/// seeds (the fix for own-device relay-id collision) the account id is a contact handle that resolves
/// to no endpoint, so dialing it is a guaranteed timeout that would burn the budget a live sibling
/// needed. Our own id is filtered here regardless — dialing yourself sends iroh's path discovery into
/// an unbounded loop (the self-connect leak), and while [`Node::conn_for`] guards that at the dial
/// chokepoint, a live-delivery fan-out over a roster that legitimately contains us shouldn't be
/// leaning on that backstop every push. Duplicates are collapsed and casing normalised.
///
/// Never returns an error: an unreachable sibling is an expected outcome, not a failure. Attempts are
/// sequential — a sibling that fails to dial is put in [`Node`]'s per-peer backoff, so it fails fast
/// (and cheaply) on subsequent pushes instead of paying [`DEVICE_DEADLINE`] again.
pub async fn deliver_to_own_devices(node: &Node, devices: &[String], payload: &[u8]) -> LiveDelivery {
    let me = node.node_id_hex();
    // BTreeSet: dedup + a deterministic attempt order (a roster can list the same sibling twice, and
    // each duplicate would otherwise cost a full dial).
    let targets: BTreeSet<String> = devices
        .iter()
        .map(|d| d.trim().to_ascii_lowercase())
        .filter(|d| !d.is_empty() && *d != me)
        .collect();

    let mut out = LiveDelivery::default();
    let started = Instant::now();
    for dev in targets {
        // Out of budget: everyone left is the mailbox's problem (which it was anyway).
        let Some(left) = TOTAL_BUDGET.checked_sub(started.elapsed()) else {
            out.unreached.push(dev);
            continue;
        };
        let deadline = left.min(DEVICE_DEADLINE);
        match tokio::time::timeout(deadline, node.send_to_node(&dev, payload)).await {
            Ok(Ok(())) => out.delivered.push(dev),
            // Dial refused/failed, or slower than a poll would have been. Either way: mailbox.
            Ok(Err(_)) | Err(_) => out.unreached.push(dev),
        }
    }
    out
}
