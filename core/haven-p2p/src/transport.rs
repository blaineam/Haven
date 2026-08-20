//! Transport seam: the path-selector that keeps traffic off the relay whenever
//! a closer, cheaper path exists.
//!
//! Priority ladder (reachability first, then bandwidth):
//!   1. **Bluetooth (BLE)** — always-on presence + small payloads / control msgs,
//!      works with zero network. Low bandwidth, so not for bulk.
//!   2. **Local WiFi / peer-to-peer WiFi** — same LAN or router-less AWDL-style
//!      direct link. Hundreds of Mbps; this carries the big files.
//!   3. **Relay** — last resort when no local path exists. Carries only opaque
//!      encrypted blobs (it never holds plaintext or PII).
//!
//! The selector *races* the available paths (Happy-Eyeballs style), prefers the
//! cheapest/fastest that's actually up, and may upgrade mid-transfer (e.g. start on
//! BLE, switch to WiFi once it negotiates).
//!
//! This module is the trait-only seam. Concrete impls land next:
//!   * `IrohTransport`  — covers rungs 2 & 3 (LAN discovery + relay fallback).
//!   * `BleTransport`   — covers rung 1 (CoreBluetooth on Apple).
//! Both feed the same [`Transport`] interface so the selector treats them uniformly.

use std::fmt;

/// A physical path to a peer, ordered cheapest/most-private first.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Path {
    /// Bluetooth LE — local, zero-network, low-bandwidth.
    Bluetooth,
    /// Local or peer-to-peer WiFi — local, high-bandwidth.
    LocalWifi,
    /// Relay network — non-local, last resort, encrypted blobs only.
    Relay,
}

impl Path {
    /// Rough rank used by the selector; lower = preferred.
    pub fn priority(self) -> u8 {
        match self {
            Path::Bluetooth => 0,
            Path::LocalWifi => 1,
            Path::Relay => 2,
        }
    }

    /// Whether this path can carry bulk (large file) traffic acceptably.
    pub fn suits_bulk(self) -> bool {
        !matches!(self, Path::Bluetooth)
    }
}

impl fmt::Display for Path {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Path::Bluetooth => "bluetooth",
            Path::LocalWifi => "local-wifi",
            Path::Relay => "relay",
        };
        f.write_str(s)
    }
}

/// Given the paths currently reachable to a peer and whether the payload is bulk,
/// choose the path to use. Bulk traffic skips Bluetooth even if it ranks first.
pub fn select(reachable: &[Path], is_bulk: bool) -> Option<Path> {
    reachable
        .iter()
        .copied()
        .filter(|p| !is_bulk || p.suits_bulk())
        .min_by_key(|p| p.priority())
}

/// The interface every concrete transport implements. Intentionally tiny; the
/// selector and the rest of the core only ever see opaque encrypted bytes.
///
/// (Async / streaming signatures will firm up alongside the iroh impl; this captures
/// the shape so the selector and FFI can be designed against it now.)
pub trait Transport {
    /// Which [`Path`] this transport represents.
    fn path(&self) -> Path;
    /// Whether this transport currently has a usable route to the given node id.
    fn is_reachable(&self, node_id: &[u8; 32]) -> bool;
}

// ── Low-data mode: link constraint + the policy table (docs/SATELLITE-DESIGN.md §5) ──────────────
//
// Satellite is NOT a fourth rung on the ladder above. The bytes go to the same relay over the same
// HTTP interface, so it is a *constraint annotation* on [`Path::Relay`]; modelling it as a rung
// would wrongly let the selector prefer it over [`Path::LocalWifi`].
//
// This table is the single source of truth for both clients. Apple and Android each detect the
// constraint with their own platform API and then ask THIS function what may cross, so the two can
// never drift into different ideas of what low-data mode means.

/// How little bandwidth the current path can be trusted with.
///
/// Platform mapping:
/// * Apple — `NWPath.isUltraConstrained` (iOS 26+) ⇒ [`Self::Ultra`]; `NWPath.isConstrained`
///   (Low Data Mode, since iOS 13) ⇒ [`Self::Low`]; otherwise [`Self::Normal`].
/// * Android — `TRANSPORT_SATELLITE` ⇒ [`Self::Ultra`]; a missing
///   `NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED` (API 36+) or a metered network ⇒ [`Self::Low`].
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Default)]
pub enum LinkConstraint {
    /// Ordinary Wi-Fi or cellular. Nothing is withheld.
    #[default]
    Normal,
    /// Low Data Mode, a metered hotspot, or a bandwidth-constrained cell. Bulk and speculative
    /// traffic stops; conversation still feels normal.
    Low,
    /// A carrier satellite bearer, or anything else the OS calls ultra-constrained. Text and the
    /// state required to decrypt it, and nothing else.
    Ultra,
}

impl LinkConstraint {
    /// True when low-data behaviour applies at all.
    pub fn is_saving(self) -> bool {
        !matches!(self, LinkConstraint::Normal)
    }
}

impl fmt::Display for LinkConstraint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            LinkConstraint::Normal => "normal",
            LinkConstraint::Low => "low",
            LinkConstraint::Ultra => "ultra",
        })
    }
}

/// A kind of traffic the app is about to generate, for [`allowance`] to rule on.
///
/// Deliberately about *purpose* rather than *size*: "a thumbnail" is a decision the policy can make
/// consistently on both platforms, where "48 KB" is not.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Traffic {
    /// Sending or receiving a text message. The one thing that always survives.
    Text,
    /// The circle roster / epoch-key convergence needed to *decrypt* text. Required for correctness,
    /// so it is never denied — but it yields to text.
    KeyConvergence,
    /// Reactions, read receipts, typing indicators — conversational garnish.
    Presence,
    /// Photo or video bytes, in either direction.
    Media,
    /// Thumbnails and avatars: small individually, unbounded in aggregate.
    Thumbnail,
    /// Unfurling a URL someone sent.
    LinkPreview,
    /// Stories.
    Story,
    /// A WebRTC call.
    Call,
    /// Fetching older history the user has not scrolled to.
    HistoryBackfill,
    /// Reconciling with the user's own other devices.
    SelfSync,
    /// Enrolment, seed-drop, pairing — thousands of bytes of post-quantum key material.
    Enrollment,
}

/// What the policy permits for a given traffic kind on a given link.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Allowance {
    /// Proceed.
    Allow,
    /// Proceed only behind an explicit, per-item user action, having shown what it will cost.
    /// Never a background or speculative fetch.
    AskFirst,
    /// Do not emit bytes. A refusal, not a throttle — a rate-limited 8 MiB chunk is still an 8 MiB
    /// chunk eventually.
    Deny,
}

impl Allowance {
    /// True when traffic of this kind may go out with no further prompting.
    pub fn is_automatic(self) -> bool {
        matches!(self, Allowance::Allow)
    }
}

/// The policy table. `docs/SATELLITE-DESIGN.md` §5 is this function in prose.
///
/// The deliberate shape: [`LinkConstraint::Low`] keeps a conversation feeling normal and stops
/// everything speculative or bulky; [`LinkConstraint::Ultra`] keeps only text and the key state
/// required to read it. Media is the sole `AskFirst` on both, because a user who genuinely needs one
/// photo out should be able to spend the bytes knowingly — silent refusal is worse than an informed
/// expensive choice. Nothing else gets an override.
pub fn allowance(link: LinkConstraint, traffic: Traffic) -> Allowance {
    use Allowance::*;
    use LinkConstraint::*;
    use Traffic::*;
    match link {
        Normal => Allow,
        Low => match traffic {
            // Thumbnails and avatars stay ALLOWED here on purpose. They are small, and a feed with
            // no pictures in it is a broken feed, not a thrifty one — the win on a metered link is
            // stopping autoplaying video, not starving the layout. They are denied at Ultra, where
            // the aggregate genuinely matters.
            Text | KeyConvergence | Presence | Call | Thumbnail => Allow,
            Media => AskFirst,
            // Enrolment on a merely-metered link is fine: it is a one-off the user initiated.
            Enrollment => Allow,
            LinkPreview | Story | HistoryBackfill | SelfSync => Deny,
        },
        Ultra => match traffic {
            Text | KeyConvergence => Allow,
            Media => AskFirst,
            Presence | Thumbnail | LinkPreview | Story | Call | HistoryBackfill | SelfSync
            | Enrollment => Deny,
        },
    }
}

#[cfg(test)]
mod low_data_tests {
    use super::*;

    /// Every traffic kind, so the sweeps below cannot silently miss one added later.
    const ALL_TRAFFIC: [Traffic; 11] = [
        Traffic::Text,
        Traffic::KeyConvergence,
        Traffic::Presence,
        Traffic::Media,
        Traffic::Thumbnail,
        Traffic::LinkPreview,
        Traffic::Story,
        Traffic::Call,
        Traffic::HistoryBackfill,
        Traffic::SelfSync,
        Traffic::Enrollment,
    ];

    /// How permissive an allowance is, for the monotonicity check.
    fn rank(a: Allowance) -> u8 {
        match a {
            Allowance::Deny => 0,
            Allowance::AskFirst => 1,
            Allowance::Allow => 2,
        }
    }

    /// The success criterion from docs/SATELLITE-DESIGN.md §1.1: text gets through on any link, and
    /// so does the key state required to decrypt it. If either of these ever becomes conditional the
    /// feature has stopped being a messaging feature.
    #[test]
    fn text_and_the_keys_to_read_it_always_get_through() {
        for link in [LinkConstraint::Normal, LinkConstraint::Low, LinkConstraint::Ultra] {
            assert_eq!(allowance(link, Traffic::Text), Allowance::Allow, "text on {link}");
            assert_eq!(
                allowance(link, Traffic::KeyConvergence),
                Allowance::Allow,
                "key convergence on {link}"
            );
        }
    }

    /// Tightening the link may never loosen the policy. This is the invariant that keeps the table
    /// honest as categories get added — a new row that is stricter on Low than on Ultra is a bug.
    #[test]
    fn policy_never_loosens_as_the_link_tightens() {
        for t in ALL_TRAFFIC {
            let (normal, low, ultra) = (
                rank(allowance(LinkConstraint::Normal, t)),
                rank(allowance(LinkConstraint::Low, t)),
                rank(allowance(LinkConstraint::Ultra, t)),
            );
            assert!(normal >= low, "{t:?}: Low is more permissive than Normal");
            assert!(low >= ultra, "{t:?}: Ultra is more permissive than Low");
        }
    }

    /// An unconstrained link is not low-data mode. Nothing may be withheld.
    #[test]
    fn normal_links_withhold_nothing() {
        assert!(!LinkConstraint::Normal.is_saving());
        for t in ALL_TRAFFIC {
            assert_eq!(allowance(LinkConstraint::Normal, t), Allowance::Allow, "{t:?}");
        }
    }

    /// On a satellite bearer, text and key state are the ONLY things that move on their own, and
    /// media is the only thing a user can spend bytes on deliberately.
    #[test]
    fn ultra_carries_text_only_with_media_behind_an_explicit_choice() {
        assert!(LinkConstraint::Ultra.is_saving());
        let automatic: Vec<Traffic> = ALL_TRAFFIC
            .into_iter()
            .filter(|t| allowance(LinkConstraint::Ultra, *t).is_automatic())
            .collect();
        assert_eq!(automatic, vec![Traffic::Text, Traffic::KeyConvergence]);

        assert_eq!(allowance(LinkConstraint::Ultra, Traffic::Media), Allowance::AskFirst);
        for t in [Traffic::Story, Traffic::Call, Traffic::HistoryBackfill, Traffic::SelfSync] {
            assert_eq!(allowance(LinkConstraint::Ultra, t), Allowance::Deny, "{t:?}");
        }
    }

    /// Low Data Mode is not satellite mode: a conversation still feels like a conversation. What
    /// stops is the speculative and the bulky.
    #[test]
    fn low_keeps_conversation_intact_and_stops_the_speculative() {
        assert!(LinkConstraint::Low.is_saving());
        for t in [Traffic::Text, Traffic::Presence, Traffic::Call, Traffic::Thumbnail] {
            assert_eq!(allowance(LinkConstraint::Low, t), Allowance::Allow, "{t:?}");
        }
        // Thumbnails survive a metered link and do NOT survive a satellite one. Pinning both ends
        // keeps a future tidy-up from collapsing them into one rule.
        assert_eq!(allowance(LinkConstraint::Ultra, Traffic::Thumbnail), Allowance::Deny);
        for t in [Traffic::Story, Traffic::HistoryBackfill, Traffic::SelfSync, Traffic::LinkPreview] {
            assert_eq!(allowance(LinkConstraint::Low, t), Allowance::Deny, "{t:?}");
        }
        assert_eq!(allowance(LinkConstraint::Low, Traffic::Media), Allowance::AskFirst);
    }

    /// Media is never silently dropped and never silently sent, at any saving level — the user
    /// decides, having been told the cost.
    #[test]
    fn media_is_always_a_deliberate_choice_when_saving() {
        for link in [LinkConstraint::Low, LinkConstraint::Ultra] {
            assert_eq!(allowance(link, Traffic::Media), Allowance::AskFirst, "media on {link}");
        }
    }
}
