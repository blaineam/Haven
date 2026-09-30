import Foundation

/// The pure half of the "is this phone allowed to do heavy media I/O right now?" policy.
///
/// Field report (2026-09-28): an iPhone got hot DURING A CALL because Haven was streaming a whole
/// video peer-to-peer to a friend — sealing every 32 KB chunk on the engine actor — while the same
/// blob either already sat on the user's relay or was minutes from landing there. Nothing on the
/// serving side looked at the call, the thermal state, Low Power Mode, or the relay; every holder
/// answered every ask. This file holds the decisions (Foundation only, so HavenLogicTests covers
/// them host-less); `HeavyWorkMonitor` feeds it the live conditions.
///
/// The rule it encodes: THE RELAY IS THE MEDIA PATH. Peer-to-peer streaming to a friend is the
/// fallback for a circle with no relay at all (or a relay copy the requester provably cannot read),
/// and even then only while the device is cool, on power budget, and not in any call.
enum HeavyWorkPolicy {
    /// `ProcessInfo.ThermalState` mirrored as a Comparable — the test target can build these directly.
    enum Heat: Int, Comparable {
        case nominal = 0, fair, serious, critical
        static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }
        init(_ s: ProcessInfo.ThermalState) {
            switch s {
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            default: self = .nominal
            }
        }
    }

    /// The live inputs, sampled together.
    struct Conditions: Equatable {
        /// A Haven call exists (ringing, connecting, or connected).
        var havenCall = false
        /// Any OTHER call on the device: cellular, FaceTime, another VoIP app (CXCallObserver).
        var systemCall = false
        var heat: Heat = .nominal
        /// iOS Low Power Mode / macOS low-power mode.
        var lowPower = false
        /// A forced suspension and its reason ("" = none). Only the DEBUG `heavy_work_override` qa op
        /// sets it — the e2e suite's way to exercise the gate without a real call or a hot phone.
        var forced = ""

        /// Stop every deferrable heavy transfer: peer media serving, backfill uploads, non-thumbnail
        /// media prefetch, history handoff, heavy self-sync. A call's audio/video pipeline already
        /// owns the SoC and the radio; this phone's battery budget says no; or it is hot.
        var suspendHeavyIO: Bool { havenCall || systemCall || heat >= .serious || lowPower || !forced.isEmpty }

        /// Streaming a blob to a FRIEND is the most expensive thing Haven does per byte (a KEM seal
        /// per chunk). Only when nothing above applies AND the device is fully cool — at .fair the
        /// relay upload is what gets the budget, not peer serving.
        var peerServingAllowedForFriends: Bool { !suspendHeavyIO && heat < .fair }

        /// .critical: everything waits, including the upload of media you just authored.
        var pauseEverything: Bool { heat >= .critical }

        /// Human-readable reason for logs ("" when nothing is suspended).
        var reason: String {
            var r: [String] = []
            if havenCall { r.append("haven-call") }
            if systemCall { r.append("system-call") }
            if heat >= .fair { r.append("thermal=\(heat)") }
            if lowPower { r.append("low-power") }
            if !forced.isEmpty { r.append("forced=\(forced)") }
            return r.joined(separator: ",")
        }
    }

    // MARK: - Serving a peer's media request (frame 3 / frame 33)

    struct ServeRequest: Equatable {
        /// The requester is another device on MY account.
        var isOwnDevice: Bool
        /// ...and it is the target of an in-progress history handoff (own-device bulk copy).
        var isHandoffTarget = false
        /// The ref is confirmed (backup ledger) on a relay a different device can read.
        var onRelay: Bool
        /// The ref is queued or in flight in this device's relay upload queue.
        var uploadPending: Bool
        /// The circle the ref belongs to has a relay/mailbox the requester can fetch from.
        var circleHasRelay: Bool
        /// Relay hints (frame 32) already sent to this requester for this ref, recently. A requester
        /// that keeps asking after being pointed at the relay provably cannot read that copy.
        var hintsAlreadySent: Int
    }

    enum ServeDecision: Equatable {
        /// Stream the bytes peer-to-peer.
        case stream
        /// The relay holds it: answer with frame 32 so the requester pulls from the relay.
        case hintRelay
        /// Our own upload of it is queued / in flight: finish that FIRST and answer with frame 32
        /// when it lands (the upload is also promoted to the priority lane).
        case hintWhenUploaded
        /// Say nothing; the requester re-asks on its own schedule.
        case decline(String)
    }

    /// After this many relay hints for one ref, a requester that still asks gets the direct path
    /// (when the gate allows) — its relay fetch is failing for a reason a hint cannot fix.
    static let maxRelayHints = 3

    static func decideServe(_ r: ServeRequest, _ c: Conditions) -> ServeDecision {
        if c.pauseEverything { return .decline("critical-thermal") }
        if c.suspendHeavyIO { return .decline("suspended(\(c.reason))") }
        if r.isOwnDevice {
            // Own devices ride the cheap symmetric-key lane (nearby Multipeer, iroh) — no per-chunk
            // KEM seal — so they are served whenever heavy I/O is allowed. The one exception: our own
            // relay upload is about to land, and a sibling that is not mid-handoff can pull it there.
            if r.uploadPending, !r.isHandoffTarget, r.hintsAlreadySent < maxRelayHints {
                return .hintWhenUploaded
            }
            return .stream
        }
        if r.circleHasRelay, r.hintsAlreadySent < maxRelayHints {
            if r.onRelay { return .hintRelay }
            if r.uploadPending { return .hintWhenUploaded }
        }
        return c.peerServingAllowedForFriends ? .stream : .decline("friend-serving-off(\(c.reason.isEmpty ? "relay-first" : c.reason))")
    }

    /// Why a friend's ask ended in `.stream` rather than a hint — QA attribution only (the e2e
    /// `relayfirst` step names the cause of any direct serve). `circleKnown`: the ref resolved to
    /// a circle at all (an unresolved ref reads as "no relay" to `decideServe`).
    static func streamReason(_ r: ServeRequest, circleKnown: Bool) -> String {
        if r.isOwnDevice { return "own-device" }
        if !circleKnown { return "circle-unresolved" }
        if !r.circleHasRelay { return "circle-has-no-relay" }
        if r.hintsAlreadySent >= maxRelayHints { return "hints-exhausted" }
        if !r.onRelay && !r.uploadPending { return "not-on-relay-nor-queued" }
        return "other"
    }

    // MARK: - Requester side

    /// How long a FRESH ref waits on the relay before anyone is asked directly. The author's upload
    /// is usually what is still running; asking peers now makes the author's phone stream the whole
    /// file while its own relay upload competes for the same radio.
    static let freshRelayPatienceMs: UInt64 = 150_000

    /// Whether a relay miss may fall through to a direct peer ask.
    ///
    /// - `small`: thumbs/posters/previews (≤32 KB by contract) — cheap for everyone, always allowed.
    /// - `ageMs`: how old the post/comment referencing the ref is (nil = unknown → treated as old).
    static func mayDirectAskAfterRelayMiss(small: Bool, circleHasRelay: Bool, ageMs: UInt64?,
                                           userInitiated: Bool, _ c: Conditions) -> Bool {
        if small { return true }
        if c.suspendHeavyIO { return false }
        if userInitiated { return true }
        if circleHasRelay, let ageMs, ageMs < freshRelayPatienceMs { return false }
        return true
    }

    /// Direct asks go to the ref's AUTHOR first (one holder, not every contact). After this many
    /// targeted asks without an answer the ask widens to every contact, so media whose author is
    /// offline can still come from another holder.
    static let targetedAsksBeforeBroadcast = 2

    /// Missing-media lanes: full-size prefetch pauses under suspend; thumbs never do.
    static func prefetchAllowed(small: Bool, _ c: Conditions) -> Bool {
        small || !c.suspendHeavyIO
    }

    // MARK: - Relay upload queue

    struct UploadBudget: Equatable {
        /// Jobs this pass may take from the priority (just-authored) lane.
        var priority: Int
        /// Jobs this pass may take from the backfill lane.
        var backfill: Int
    }

    /// Uploading your OWN fresh media to the relay is what saves every future peer serve, so it keeps
    /// going (one at a time) through a call / Low Power Mode / .serious; only .critical stops it.
    /// Backfill waits for the gate to lift.
    static func uploadBudget(base: Int, _ c: Conditions) -> UploadBudget {
        if c.pauseEverything { return UploadBudget(priority: 0, backfill: 0) }
        if c.suspendHeavyIO { return UploadBudget(priority: 1, backfill: 0) }
        return UploadBudget(priority: base, backfill: base)
    }

    // MARK: - Ultra-constrained (satellite) link

    /// May a blob leave this device over the current link (`docs/PREVIEW-TIER-DESIGN.md` §4.1)?
    ///
    /// On an ultra-constrained link only satellite-safe media (a preview, or anything already within
    /// the preview budget) crosses — by EVERY path: the backup queue, a forced re-seal answering a
    /// friend's media-wanted ask, a relay-hint's deferred upload, a resume serve. The queue was gated
    /// and the ask-driven paths were not, so a friend's "can't find it on the relay" ask put the full
    /// original on the relay mid-satellite-pass. Held work is deferred, not dropped: it re-runs when
    /// the link improves.
    static func mayMoveOverLink(ultraConstrained: Bool, satelliteSafe: Bool) -> Bool {
        !ultraConstrained || satelliteSafe
    }
}

/// Which of my media refs the unsolicited own-device push (`FeedStore.pushOwnMediaNearby`) sends
/// this pass.
///
/// That push streams full originals to every one of my devices — over the nearby mesh AND iroh
/// (`sendMediaChunks` mirrors own-device chunks to all my device ids) — and it was the one serve path
/// the ultra-constrained gate never covered. On Android it put a 330 KB original on a sibling mid-
/// satellite-pass; the sibling (on a normal link) backed it up as its own and the friend got the full
/// photo (e2e `satellite holds back the full photo`). A ref the link may not carry is SKIPPED WITHOUT
/// being marked pushed, so the first pass after the link improves sends it — deferred, never dropped.
/// Mirrors Android's `OwnMediaPush.pick`.
enum OwnMediaPush {
    /// `alreadyPushed` gains every ref this pass sends; the budget counts only those.
    static func pick<S: Sequence>(_ refs: S, alreadyPushed: inout Set<String>, budget: Int,
                                  eligible: (String) -> Bool,
                                  mayMoveOverLink: (String) -> Bool) -> [String] where S.Element == String {
        var out: [String] = []
        for ref in refs {
            if out.count >= budget { break }
            if alreadyPushed.contains(ref) || !eligible(ref) { continue }
            if !mayMoveOverLink(ref) { continue }   // held for a better link — deliberately not marked
            alreadyPushed.insert(ref)
            out.append(ref)
        }
        return out
    }
}
