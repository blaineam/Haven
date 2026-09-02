import Foundation
import CryptoKit

// Multi-device live sync (roadmap D16, Phase 3 — client wiring).
//
// Makes a user's OWN devices converge: each device writes a self-encrypted snapshot of its
// account state to a per-account mailbox slot it owns, and merges its peers' slots. The merge
// is the CRDT in `haven-p2p::selfsync` (last-write-wins per key), exposed through the FFI
// (`AccountStateHandle`, `sealAccountState`/`openAccountState`, `selfSyncSlotKey`). The relay
// only ever holds ciphertext sealed with a key only this account's devices can derive.
//
// Scope: PROFILE (name/emoji/bio/link), GLOBAL SETTINGS, CONTACTS, and the BLOCKED LIST.
// Scalar keys (profile/setting) apply via `get(key:)`; set-like state (contacts/blocked)
// reconciles via `entries()`, with local removals propagated as tombstones. Circles stay out
// for now: a device needs each member's public crypto bundle (held in the engine, not the
// Contact struct) to actually participate, so circle sync is a separate engine-state piece.

/// A stable **per-device** id. All of a user's devices share the account seed (same node id),
/// so each physical device needs its own id to own a sync slot and to break LWW ties. Random
/// 32 bytes, generated once, stored device-local in UserDefaults, never synced.
enum SelfSyncDevice {
    private static let key = "haven.selfsync.deviceId"
    static let id: Data = {
        let d = UserDefaults.standard
        if let hex = d.string(forKey: key), let data = Data(havenHex: hex), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        d.set(data.havenHexString, forKey: key)
        return data
    }()
    static var hex: String { id.havenHexString }
}

@MainActor
final class SelfSyncCoordinator {
    static let shared = SelfSyncCoordinator()
    private init() {}

    private var inFlight = false

    // MARK: seedless (S4) — seal/open with the granted self-sync key instead of the master seed
    //
    // A seedless device has NO account seed; it holds a granted 32-byte self-sync key
    // (`SelfSyncKeyStore`) that decrypts the exact same account-state slots. These helpers pick the
    // right primitive so every call site below is identity-agnostic (plan §2.2 F11 / §5).

    /// True when this device can produce/consume its self-sync slot: a master seed (seeded) or the
    /// granted key (seedless). Guards every sync entry.
    private func canSelfSync() -> Bool {
        SeedlessState.isEnabled ? (SelfSyncKeyStore.load() != nil) : (AccountStore.storedSeed() != nil)
    }

    /// Seal account state. Switch-Flip §6: once the self-sync key has ROTATED (a device revocation on a
    /// fully-capable fleet), seal under the rotated key at its epoch (the v1 path) — the bare account
    /// key / v0 grant is retired. Until then it is the byte-identical v0 path: the master seed (seeded)
    /// or the granted self-sync key (seedless).
    private func sealState(_ state: AccountStateHandle) -> Data? {
        if SelfSyncEpochStore.epoch > 0, let k = SelfSyncEpochStore.currentKey() {
            return try? sealAccountStateWithKeyEpoch(selfSyncKey: k, epoch: SelfSyncEpochStore.epoch, state: state)
        }
        if SeedlessState.isEnabled {
            guard let key = SelfSyncKeyStore.load() else { return nil }
            return try? sealAccountStateWithKey(selfSyncKey: key, state: state)
        }
        guard let seed = AccountStore.storedSeed() else { return nil }
        return try? sealAccountState(accountSeed: seed, state: state)
    }

    /// Open a peer/self slot. Switch-Flip §6: once rotated, dual-key open honoring ONLY the current
    /// epoch with an EMPTY seed_key (v0 authority retired) — a revoked device's stale-epoch or legacy v0
    /// write is refused (the revocation cut), and unreadable blobs are simply skipped by the caller (never
    /// tombstoned). Until then it is the byte-identical v0 open: the master seed or the granted key.
    private func openState(_ blob: Data) -> AccountStateHandle? {
        if SelfSyncEpochStore.epoch > 0, let k = SelfSyncEpochStore.currentKey() {
            return try? openAccountStateDual(sealed: blob, currentEpoch: SelfSyncEpochStore.epoch,
                                             currentKey: k, seedKey: Data())
        }
        if SeedlessState.isEnabled {
            guard let key = SelfSyncKeyStore.load() else { return nil }
            return try? openAccountStateWithKey(selfSyncKey: key, sealed: blob)
        }
        guard let seed = AccountStore.storedSeed() else { return nil }
        return try? openAccountState(accountSeed: seed, sealed: blob)
    }

    // Circle records are encoded/decoded by the shared FFI `encodeCircleSync`/`decodeCircleSync`
    // so iOS/desktop/Android emit byte-identical bytes (no per-platform JSON/base64 drift).

    /// Last converged state, persisted so we can detect what changed locally (LWW only advances
    /// a key's stamp when its value actually changes — otherwise two devices would ping-pong).
    private var baseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("haven-selfsync.bin")
    }

    // MARK: state ↔ CRDT mapping (v1: profile + global settings)

    /// The current local state as namespaced key → value bytes (no stamps). `social` (when
    /// available) contributes circle structure; without it, circles are simply not snapshotted.
    private func currentLocal(social: HavenSocial?) -> [String: Data] {
        var m: [String: Data] = [:]
        let p = ProfileStore.shared
        // Only broadcast NON-EMPTY profile scalars. A fresh/empty device must never stamp a blank value
        // that then wins last-writer-wins and REVERTS a sibling's real profile (absence ≠ authoritative —
        // same principle as the contact/circle tombstone rules). Clearing a field is an explicit action we
        // can model separately; silently blanking a real profile from another device is data loss.
        if !p.displayName.isEmpty { m["profile:name"] = Data(p.displayName.utf8) }
        if !p.emoji.isEmpty { m["profile:emoji"] = Data(p.emoji.utf8) }
        if !p.bio.isEmpty { m["profile:bio"] = Data(p.bio.utf8) }
        if !p.link.isEmpty { m["profile:link"] = Data(p.link.utf8) }
        // Profile photo (small base64 JPEG) — so a freshly-linked device gets the avatar too, not just
        // the name/bio. Was missing, which is why the avatar showed on posts but not on the profile.
        let av = p.avatarBase64
        if !av.isEmpty { m["profile:avatar"] = Data(av.utf8) }
        // LWW timestamps per profile field — so two of your devices resolve a profile edit by WHO EDITED
        // LAST, not who synced last (the endless profile/avatar ping-pong). See ProfileStore.
        do {
            func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            for f in ["name", "emoji", "bio", "link", "avatar"] {
                let ts = p.fieldTimestamp(f); if ts > 0 { m["profile-at:\(f)"] = le8(ts) }
            }
        }
        let s = SettingsStore.shared
        m["setting:saveToPhotos"] = Data([s.saveToPhotos ? 1 : 0])
        m["setting:saveOthersToPhotos"] = Data([s.saveOthersToPhotos ? 1 : 0])
        m["setting:autoOptimize"] = Data([s.autoOptimize ? 1 : 0])
        // NOT `setting:silent` — global mute is DEVICE-LOCAL (see SettingsStore.silent). It's seeded from
        // each device's own hardware silent switch / platform default, so syncing it made devices fight:
        // the phone's ringer state muted the Mac, and the Mac's converged value landed AFTER the feed had
        // already started a song — audible playback, then an abrupt cut once sync applied the mute. Like
        // `videoSoundOn`, this preference belongs to the device you're holding.
        m["setting:retentionDays"] = withUnsafeBytes(of: Int32(s.retentionDays).littleEndian) { Data($0) }
        // LWW timestamps for the synced settings — so two devices resolve a settings change by WHO CHANGED
        // it last, not who synced last (the same ping-pong that hit profiles). See SettingsStore.
        do {
            func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            for k in [s.tsKeySave, s.tsKeySaveOthers, s.tsKeyOpt, s.tsKeyRet] {
                let ts = s.settingTimestamp(k); if ts > 0 { m["setting-at:\(k)"] = le8(ts) }
            }
        }
        // Pinned DM conversations (ordered) sync across my devices, last-writer-wins. Only broadcast when
        // non-empty so a fresh device can't blank a sibling's pins (absence ≠ authoritative).
        let pins = DMPinStore.shared.pinned
        if !pins.isEmpty { m["setting:pinnedDMs"] = Data(pins.joined(separator: "\n").utf8) }
        // DM read watermarks — reading a thread on one device clears its badge on the others.
        // Monotonic per-conversation timestamps, merged by per-key MAX on apply (always safe:
        // no device can un-read another, and a fresh device's empty map changes nothing).
        let reads = DMReadStore.shared.lastRead
        if !reads.isEmpty, let data = try? JSONEncoder().encode(reads) { m["setting:dmLastRead"] = data }
        // Activity-seen watermark (the bell) — opening the activity list on one device clears the
        // badge on the others. 8-byte LE ms, merged MAX on apply — dmLastRead's exact contract,
        // for a single scalar. A fresh device's 0 is simply not broadcast, so it changes nothing.
        let activitySeen = ActivityStore.shared.seenAtMs
        if activitySeen > 0 {
            m["setting:activitySeenAt"] = withUnsafeBytes(of: activitySeen.littleEndian) { Data($0) }
        }
        // Stories I kept to my profile. Carries its own per-entry timestamps and tombstones, so it
        // merges rather than last-writer-wins: keeping one story on my phone and another on my Mac
        // must end with BOTH kept, and un-keeping must not be undone by a sibling's stale copy.
        if let keptData = KeptStoriesStore.shared.syncPayload() { m["setting:keptStories"] = keptData }
        // Roster: contacts (full card) + blocked list.
        for c in ContactsStore.shared.contacts {
            if let data = try? JSONEncoder().encode(c) { m["contact:\(c.idHex)"] = data }
        }
        // Contact removals — LWW by timestamp (contacts are additive-only, so a delete needs an explicit
        // newest-wins tombstone to stick fleet-wide). See ContactsStore.
        do {
            func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            for (hex, ms) in ContactsStore.shared.contactRemovedAt { m["contact-removed:\(hex)"] = le8(ms) }
            for (hex, ms) in ContactsStore.shared.contactReaddedAt { m["contact-readd:\(hex)"] = le8(ms) }
            // Whole-circle / DM deletions — LWW, so deleting a DM on one device deletes it on all of them
            // instead of a sibling's `circle:` record re-creating it.
            for (id, ms) in CircleDeletionStore.deletedAt { m["circle-deleted:\(id)"] = le8(ms) }
            for (id, ms) in CircleDeletionStore.recreatedAt { m["circle-recreated:\(id)"] = le8(ms) }
        }
        for hex in ConnectionsStore.shared.blocked { m["blocked:\(hex)"] = Data([1]) }
        // Explicit circle severances — LWW by TIMESTAMP so a fresh removal beats a stale re-add and vice
        // versa (the fix for "removals don't sync / re-adds get re-severed"). Two distinct keys carry
        // their own ms timestamp, resolved newest-wins on apply. Also still emit the legacy `removal:`=1/0
        // (derived from the current verdict) so a pre-LWW sibling keeps converging during the rollout —
        // those carry no time, so a new build treats them as ts=1 and they never override a real write.
        func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        for (key, ms) in ConnectionsStore.shared.removedAt { m["circle-removed:\(key)"] = le8(ms) }
        for (key, ms) in ConnectionsStore.shared.readdedAt { m["circle-readd:\(key)"] = le8(ms) }
        for key in ConnectionsStore.shared.circleRemovals { m["removal:\(key)"] = Data([1]) }   // legacy compat
        for (key, ms) in ConnectionsStore.shared.readdedAt where ms > (ConnectionsStore.shared.removedAt[key] ?? 0) {
            m["removal:\(key)"] = Data([0])   // legacy compat: currently re-added
        }
        // Relay DELETIONS — LWW by the forget timestamp, so deleting a relay on one device drops it on
        // all of them (and stops a sibling re-announcing it). Value = the 8-byte forgotAt (ms). Without
        // this the deletion was device-local and a sibling kept the relay active + re-announcing it,
        // resurrecting it ("deleted relays keep returning").
        for (hex, ms) in RelayMailboxStore.shared.forgottenRelays {
            m["relay-removal:\(hex)"] = withUnsafeBytes(of: ms.littleEndian) { Data($0) }
        }
        // …and re-adds under a DISTINCT key carrying their OWN re-add timestamp — NOT a bare `0`. A
        // delete and a re-add now resolve by LWW on the semantic time (newest wins), instead of the
        // clear always winning because the grow-only cleared set re-broadcast "0=clear" every sync.
        // THAT was the "I delete a relay and it keeps coming back" bug: an old re-add un-deleted the
        // relay forever. Now a delete newer than the last re-add sticks fleet-wide.
        for (hex, ms) in RelayMailboxStore.shared.clearedRelayForgetRecords {
            m["relay-readd:\(hex)"] = withUnsafeBytes(of: ms.littleEndian) { Data($0) }
        }
        // Circles: name + member bundles + relay nodes, so another device can reconstruct each
        // circle and seal to every member. (Additive in v1 — member/circle removal is a follow-up.)
        if let social = social {
            // Switch-Flip §2: carry the circle CREATOR (authority root) along the authenticated
            // circle-sync path so another of my devices / a shared-circle peer can pin it. I only
            // assert it for circles I own (the ones I created + the default "My Circle"); nil otherwise
            // (the real creator's own export carries it — absence never fabricates a creator).
            let myCreator = DeviceRosterManager.hexToData(social.myNodeHex())
            for ci in social.circles() {
                let creator = (CircleCreatorStore.iCreated(ci.id) || ci.id == "default") ? myCreator : nil
                // Shared FFI encoder → byte-identical circle records across iOS/desktop/Android.
                m["circle:\(ci.id)"] = encodeCircleSync(
                    name: ci.name,
                    memberBundles: social.circleMemberBundles(circleId: ci.id),
                    relays: RelayMailboxStore.shared.relays(forCircle: ci.id),
                    creator: creator)
            }
            // Contact device ROSTERS — so a freshly-linked device (e.g. the Mac) learns which device ids to
            // DIAL/seal for each friend directly from a sibling that already knows them, instead of dialing
            // dead account ids and timing out (the regression that made friend comms fail on the Mac). Keyed
            // by account hex so a newer roster version replaces the old. Additive (never tombstoned).
            for r in social.exportContactRosters() { m["roster:\(r.accountHex)"] = r.wire }
            // My OWN device roster — the fix for the own-device bootstrap deadlock. Without this a
            // sibling device never learns THIS device's id, so its relay rejects us (`ERR forbidden`)
            // and our relay-deletion tombstones never reach it (deleted relays keep returning). Shares
            // the `roster:` namespace, so the ingest loop already applies it (union-merging our device
            // id into the sibling's own-account list). Converges over any relay both devices can reach.
            for r in social.exportOwnRoster() { m["roster:\(r.accountHex)"] = r.wire }
        }
        return m
    }

    /// Namespaces whose keys are dynamic (set-like) — used to detect LOCAL removals so they
    /// propagate as tombstones (unblock, delete contact). Scalar namespaces (profile/setting)
    /// are always present, so they're never spuriously removed.
    private static let dynamicPrefixes = ["contact:", "blocked:", "circle:"]

    /// Write a merged state back into the local stores (only when a value actually differs, to
    /// avoid feedback loops through the stores' didSet broadcasts).
    private func applyLocal(_ h: AccountStateHandle, social: HavenSocial?) async {
        let p = ProfileStore.shared
        // Profile fields are LAST-WRITER-WINS by per-field timestamp — a remote value is applied only if
        // it was edited MORE RECENTLY than our local one. This ends the endless ping-pong where two
        // devices each thought "my non-empty value wins" and overwrote each other every sync. A field
        // WITHOUT a timestamp (an old build, or one never edited) reads as ts=0, so it never overrides a
        // real local edit — but still seeds an empty local field.
        func profTs(_ f: String) -> UInt64 {
            guard let v = h.get(key: "profile-at:\(f)"), v.count == 8 else { return 0 }
            return v.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        }
        // Untimestamped legacy value → ts=1 (barely > 0) ONLY to SEED an empty local field; it must never
        // overwrite a non-empty local (that would just swap two un-timestamped values once). A real local
        // edit (ts=now) always wins over this.
        if let v = h.get(key: "profile:name"), let s = String(data: v, encoding: .utf8) {
            var ts = profTs("name"); if ts == 0, p.fieldTimestamp("name") == 0, p.displayName.isEmpty, !s.isEmpty { ts = 1 }
            _ = p.applyRemote("name", string: s, ts: ts)
        }
        if let v = h.get(key: "profile:emoji"), let s = String(data: v, encoding: .utf8), !s.isEmpty {
            let ts = profTs("emoji")   // emoji always has a default; only a timestamped remote overrides it
            p.applyRemote("emoji", string: s, ts: ts)
        }
        if let v = h.get(key: "profile:bio"), let s = String(data: v, encoding: .utf8) {
            var ts = profTs("bio"); if ts == 0, p.fieldTimestamp("bio") == 0, p.bio.isEmpty, !s.isEmpty { ts = 1 }
            p.applyRemote("bio", string: s, ts: ts)
        }
        if let v = h.get(key: "profile:link"), let s = String(data: v, encoding: .utf8) {
            var ts = profTs("link"); if ts == 0, p.fieldTimestamp("link") == 0, p.link.isEmpty, !s.isEmpty { ts = 1 }
            p.applyRemote("link", string: s, ts: ts)
        }
        if let v = h.get(key: "profile:avatar"), let b64 = String(data: v, encoding: .utf8), b64 != p.avatarBase64 {
            var ts = profTs("avatar"); if ts == 0, p.fieldTimestamp("avatar") == 0, p.avatarBase64.isEmpty, !b64.isEmpty { ts = 1 }
            p.applyRemoteAvatar(base64: b64, ts: ts)
        }

        let s = SettingsStore.shared
        // Settings are LWW by per-key timestamp — same fix as profiles/removals. A remote value only wins
        // if it was changed more recently than ours; an untimestamped legacy record (old peer) maps to ts=1
        // so it seeds a never-touched device but can never overwrite a real local edit.
        func settingTs(_ key: String) -> UInt64 {
            if let v = h.get(key: "setting-at:\(key)"), v.count == 8 {
                return v.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            }
            return 1
        }
        if let b = boolValue(h, "setting:saveToPhotos") { s.applyRemoteBool(s.tsKeySave, b, ts: settingTs(s.tsKeySave)) }
        if let b = boolValue(h, "setting:saveOthersToPhotos") { s.applyRemoteBool(s.tsKeySaveOthers, b, ts: settingTs(s.tsKeySaveOthers)) }
        if let b = boolValue(h, "setting:autoOptimize") { s.applyRemoteBool(s.tsKeyOpt, b, ts: settingTs(s.tsKeyOpt)) }
        // `setting:silent` is deliberately NOT applied (see currentLocal): a stale value left in an old
        // base by a previous build must not reach in and mute/unmute this device long after the fact.
        if let v = h.get(key: "setting:retentionDays"), v.count == 4 {
            let n = Int(Int32(littleEndian: v.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
            s.applyRemoteRetentionDays(n, ts: settingTs(s.tsKeyRet))
        }
        if let v = h.get(key: "setting:pinnedDMs"), let str = String(data: v, encoding: .utf8) {
            DMPinStore.shared.applySynced(str.split(separator: "\n").map(String.init))
        }
        if let v = h.get(key: "setting:dmLastRead"), let m = try? JSONDecoder().decode([String: UInt64].self, from: v) {
            DMReadStore.shared.applySynced(m)   // per-key MAX merge
            FeedStore.shared.recomputeUnreadDMs()
        }
        if let v = h.get(key: "setting:activitySeenAt"), v.count == 8 {
            let ms = v.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            ActivityStore.shared.applySyncedSeenAt(ms)   // MAX merge — reading anywhere clears everywhere
        }
        if let v = h.get(key: "setting:keptStories") {
            KeptStoriesStore.shared.applySynced(v)   // per-entry LWW + tombstones
        }

        // Roster reconciliation (set-like — enumerate the converged state via entries()).
        let live = h.entries()

        let cs = ContactsStore.shared
        // Contact removals — LWW by timestamp, applied BEFORE the upsert so a removed contact is
        // tombstoned and `syncUpsert` refuses to resurrect them (contacts are otherwise additive-only,
        // which is exactly why deletes never stuck on a multi-device account). Newest of removed-vs-readd
        // wins; a fresh delete beats a stale re-add and a fresh re-add beats an old delete.
        func le8u(_ d: Data) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian } }
        var ctRemovedMs: [String: UInt64] = [:], ctReaddMs: [String: UInt64] = [:]
        for e in live {
            if e.key.hasPrefix("contact-removed:"), e.value.count == 8 {
                ctRemovedMs[String(e.key.dropFirst("contact-removed:".count))] = le8u(e.value)
            } else if e.key.hasPrefix("contact-readd:"), e.value.count == 8 {
                ctReaddMs[String(e.key.dropFirst("contact-readd:".count))] = le8u(e.value)
            }
        }
        for hex in Set(ctRemovedMs.keys).union(ctReaddMs.keys) where !hex.isEmpty {
            let rem = ctRemovedMs[hex] ?? 0, readd = ctReaddMs[hex] ?? 0
            if rem >= readd, rem > 0 { cs.mergeContactRemovedAt(hex, ms: rem) }
            else if readd > 0 { cs.mergeContactReaddedAt(hex, ms: readd) }
        }

        // Contacts: upsert everyone present that isn't tombstone-removed (syncUpsert enforces the tombstone).
        var wantContacts: [String: Contact] = [:]
        for e in live where e.key.hasPrefix("contact:") {
            if let c = try? JSONDecoder().decode(Contact.self, from: e.value) { wantContacts[c.idHex] = c }
        }
        for c in wantContacts.values { cs.syncUpsert(c) }
        // ADDITIVE ONLY — do not remove contacts a peer happens not to have (see the circle note above:
        // a freshly-restored device's empty state must never delete the primary's contacts/posts).

        // Blocked list: reconcile both directions.
        var wantBlocked = Set<String>()
        for e in live where e.key.hasPrefix("blocked:") {
            wantBlocked.insert(String(e.key.dropFirst("blocked:".count)))
        }
        let conn = ConnectionsStore.shared
        for hex in wantBlocked.subtracting(conn.blocked) { conn.block(hex) }
        for hex in conn.blocked.subtracting(wantBlocked) { conn.unblock(hex) }

        // Circle severances synced from my other devices — resolved by LAST-WRITER-WINS on timestamps, so
        // a fresh removal beats a stale re-add and a fresh re-add beats an old removal. Gather both sides
        // from the timestamped keys (plus legacy `removal:`=1/0 mapped to ts=1 so it loses to any real
        // write), pick the newest per key, then apply — set/lift the engine tombstone to match. This is
        // the fix for "removals don't sync to my other device" AND the older "a sibling re-severs a
        // re-added friend": the newest human action always wins, never a stale record. (le8u defined above.)
        var cRemovedMs: [String: UInt64] = [:]
        var cReaddMs: [String: UInt64] = [:]
        for e in live {
            if e.key.hasPrefix("circle-removed:"), e.value.count == 8 {
                let k = String(e.key.dropFirst("circle-removed:".count)); cRemovedMs[k] = max(cRemovedMs[k] ?? 0, le8u(e.value))
            } else if e.key.hasPrefix("circle-readd:"), e.value.count == 8 {
                let k = String(e.key.dropFirst("circle-readd:".count)); cReaddMs[k] = max(cReaddMs[k] ?? 0, le8u(e.value))
            } else if e.key.hasPrefix("removal:"), e.value.count == 1 {   // legacy pre-LWW record → ts=1
                let k = String(e.key.dropFirst("removal:".count))
                if e.value.first == 1 { cRemovedMs[k] = max(cRemovedMs[k] ?? 0, 1) }
                else { cReaddMs[k] = max(cReaddMs[k] ?? 0, 1) }
            }
        }
        for key in Set(cRemovedMs.keys).union(cReaddMs.keys) {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let circleId = String(key[key.startIndex..<bar])
            let hex = String(key[key.index(after: bar)...])
            guard !circleId.isEmpty, !hex.isEmpty else { continue }
            let rem = cRemovedMs[key] ?? 0, readd = cReaddMs[key] ?? 0
            if rem >= readd, rem > 0 {
                if conn.mergeRemovedAt(key, ms: rem),
                   social?.contactNodeIds(circleId: circleId).contains(hex) == true {
                    social?.removeFromCircle(circleId: circleId, nodeHex: hex)   // purge + engine tombstone (present)
                }
            } else if readd > 0 {
                if !conn.mergeReaddedAt(key, ms: readd) {
                    social?.clearCircleRemoval(circleId: circleId, nodeHex: hex)  // newest is a re-add → lift tombstone
                }
            }
        }

        // Relay delete vs re-add, from any of my devices, resolved by LWW on the SEMANTIC timestamp
        // (delete time vs re-add time) — NOT by which device synced last. Gather both sides, newest
        // wins per relay. Applied BEFORE the circle: records below re-add relays, so a relay whose
        // newest verdict is "deleted" stays gone. A legacy `relay-removal:<hex>` = 0 (old bare CLEAR)
        // decodes to del=0/readd=0 → ignored, which is exactly right: those were the resurrection bug.
        func le8(_ d: Data) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian } }
        var removalMs: [String: UInt64] = [:]
        var readdMs: [String: UInt64] = [:]
        for e in live where e.value.count == 8 {
            if e.key.hasPrefix("relay-removal:") {
                let hex = String(e.key.dropFirst("relay-removal:".count))
                if !hex.isEmpty { removalMs[hex] = max(removalMs[hex] ?? 0, le8(e.value)) }
            } else if e.key.hasPrefix("relay-readd:") {
                let hex = String(e.key.dropFirst("relay-readd:".count))
                if !hex.isEmpty { readdMs[hex] = max(readdMs[hex] ?? 0, le8(e.value)) }
            }
        }
        for hex in Set(removalMs.keys).union(readdMs.keys) {
            let del = removalMs[hex] ?? 0, readd = readdMs[hex] ?? 0
            if del > readd {
                RelayMailboxStore.shared.applyForgottenTombstone(hex, atMs: del)   // deleted, newer than any re-add
            } else if readd > 0 {
                RelayMailboxStore.shared.applyClearedRelayForget(hex, atMs: readd) // re-added, newer than any delete
            }
        }

        // Contact rosters synced from another of my devices → ingest so THIS device can also dial + seal to
        // each friend's CURRENT devices (verified against the account bundle carried inside the wire). This
        // is what lets a linked Mac reach friends it never contacted directly — it inherits their device ids
        // from the phone. Idempotent + version-checked in the engine, so a stale roster can't roll anything back.
        if let social = social {
            // A roster arriving here is very often MY OWN account's — a sibling device registering.
            // That advances the circle's epoch just as a contact's roster change does, so it needs the
            // same re-seal, and it was the door the first fix missed: the re-seal was wired only into
            // the CONTACT pull path, while a sibling's registration comes through self-sync. The
            // symptom was an Android leg parked on `@…777` while everyone else had moved to `@…778`.
            //
            // OFF-MAIN + EngineGate: ingest drains pending epoch events, and each drained event
            // re-verifies device credentials — cloning ML-DSA verifying keys per contact device.
            // The stall detector caught this exact loop blocking main 1.4–1.9s per foreground
            // sync on a real account; it is engine work like any other and queues behind the
            // mailbox drain instead of parking the UI.
            let wires = live.filter { $0.key.hasPrefix("roster:") }.map(\.value)
            if !wires.isEmpty {
                // ONE gate hold PER WIRE with air between them (the mailbox drain's shape). The hold
                // log showed this loop holding the engine for 9.5s on the owner's account — every
                // wire drains pending epoch events and re-verifies device credentials — and any
                // main-actor engine read in that window parked for the whole of it.
                let rosterChanged = await Task.detached(priority: .utility) {
                    var changed = false
                    for (i, wire) in wires.enumerated() {
                        if i > 0 { try? await Task.sleep(nanoseconds: 3_000_000) }
                        if await EngineGate.shared.run({ social.ingestRosterWireStatus(wire: wire) }) > 0 { changed = true }
                    }
                    return changed
                }.value
                if rosterChanged {
                    NotificationCenter.default.post(name: SharedStore.rosterEpochChangedNotification, object: nil)
                }
            }
        }

        // Circles: reconstruct each synced circle — create it, register every member's bundle
        // (so this device can seal to them), and record its relay mailbox(es). Additive in v1.
        // Whole-circle / DM deletions — LWW, applied BEFORE the circle: upsert. A deletion newer than any
        // re-creation deletes the circle locally too (so deleting a DM on the phone deletes it on the Mac);
        // the `circle:` loop then skips re-creating anything still tombstone-deleted.
        var cdDeletedMs: [String: UInt64] = [:], cdRecreatedMs: [String: UInt64] = [:]
        for e in live {
            if e.key.hasPrefix("circle-deleted:"), e.value.count == 8 {
                cdDeletedMs[String(e.key.dropFirst("circle-deleted:".count))] = le8u(e.value)
            } else if e.key.hasPrefix("circle-recreated:"), e.value.count == 8 {
                cdRecreatedMs[String(e.key.dropFirst("circle-recreated:".count))] = le8u(e.value)
            }
        }
        for id in Set(cdDeletedMs.keys).union(cdRecreatedMs.keys) where !id.isEmpty {
            let del = cdDeletedMs[id] ?? 0, rec = cdRecreatedMs[id] ?? 0
            if del >= rec, del > 0 {
                if CircleDeletionStore.mergeDeletedAt(id, ms: del),
                   social?.circles().contains(where: { $0.id == id }) == true {
                    social?.leaveCircle(id: id)
                }
            } else if rec > 0 {
                CircleDeletionStore.mergeRecreatedAt(id, ms: rec)
            }
        }

        if let social = social {
            let existing = social.circles()
            for e in live where e.key.hasPrefix("circle:") {
                let id = String(e.key.dropFirst("circle:".count))
                guard let rec = decodeCircleSync(bytes: e.value) else { continue }
                // Don't RESURRECT a circle/DM the user deleted (LWW): a sibling still listing it must not
                // re-create it every sync. A newer re-creation (below via markRecreated) lifts this.
                if CircleDeletionStore.isDeleted(id) { continue }
                social.createCircle(id: id, name: rec.name)   // no-op if it already exists
                if let cur = existing.first(where: { $0.id == id }), cur.name != rec.name {
                    social.renameCircle(id: id, name: rec.name)
                }
                // Switch-Flip §2: pin the CREATOR carried on the authenticated circle-sync record (the
                // "learned out-of-band" path). set_circle_creator is DEFINITION-bound — it overrides any
                // weakly-TOFU'd creator and can't be dislodged by a later disagreeing grant.
                if let creator = rec.creator, creator.count == 32 {
                    _ = social.setCircleCreator(circleId: id,
                                                accountHex: creator.map { String(format: "%02x", $0) }.joined())
                }
                // STRICTLY ADDITIVE: register each synced member. We do NOT remove members or leave
                // circles based on a peer's state. Absence-based removal caused catastrophic data loss:
                // a freshly-restored device has an empty engine, so it looked like "every circle/member
                // was removed", which tombstoned + propagated to the primary and wiped its posts. Real
                // circle-leave / member-removal must be driven by an explicit intent, not by absence.
                for bundle in rec.memberBundles {
                    // Don't re-add someone we EXPLICITLY removed from this circle. Additive sync was
                    // re-registering removed members from a peer's roster — which is exactly why "remove
                    // someone" never stuck. An explicit removal wins over a peer still listing them.
                    let hex = bundle.prefix(32).map { String(format: "%02x", $0) }.joined()
                    if conn.isRemovedFromCircle(hex, circleId: id) { continue }
                    _ = try? social.addContactBundle(circleId: id, bundle: bundle)
                }
                for node in rec.relays {
                    // Non-stamping add: a sync-learned relay must NOT get a fresh addedAt=now() (that
                    // fabricated stamp is what let a sibling perpetually defeat a deletion's LWW). Skips
                    // relays we've forgotten. Keeps its real adoption stamp (or 0 = unknown).
                    RelayMailboxStore.shared.addSynced(circleId: id, nodeHex: node)
                }
            }
        }
    }

    private func boolValue(_ h: AccountStateHandle, _ key: String) -> Bool? {
        guard let v = h.get(key: key), let first = v.first else { return nil }
        return first == 1
    }

    // MARK: sync

    /// Skip-upload bookkeeping (step 5): the digest of the converged state we last published, and
    /// when. Publishing is per-pass radio work against EVERY transport, yet the state is identical
    /// pass after pass on an idle device — the 6h floor keeps the slot's mailbox-GC liveness fresh
    /// without re-uploading the same bytes every ~2 minutes.
    private let lastPublishedHashKey = "haven.selfsync.lastPublishedHash"
    private let lastPublishedAtKey = "haven.selfsync.lastPublishedAt"
    private let republishFloor: TimeInterval = 6 * 3600

    /// Step-3 caches. Peer slot keys are FIXED per device (`self/<acct>/state/<dev>`), so the LIST
    /// only ever changes when a device is added/removed — re-LISTing every transport every pass was
    /// pure radio. Cached per transport for a bounded window (forced passes refresh). And per
    /// (transport,key): the digest of the last-fetched slot blob, so an unchanged slot skips the
    /// open+merge crypto (the transports expose no etag, so the GET itself can't be skipped).
    private var peerKeysCache: [String: (at: Date, keys: [String])] = [:]
    private var peerSlotDigest: [String: String] = [:]
    private let peerKeysTTL: TimeInterval = 600

    private func transportId(_ t: Transport) -> String {
        switch t {
        case .relay(let node): return "relay:\(node)"
        case .s3: return "s3"
        }
    }

    /// One full sync pass: fold local changes into the base with fresh stamps, merge every peer
    /// slot, apply the converged result locally, persist, and re-publish our own slot. Safe to
    /// call on a timer; coalesces if already running. No-op without an account or any sync
    /// target (a relay or the user's S3 bucket — either works, no relay required).
    /// `force` (explicit user actions: device link, force-sync, foreground pull) bypasses the
    /// thermal gate and the step-3 caches so a deliberate sync is never silently a no-op.
    /// Returns `true` if the merge brought in changes from another device (so the caller can
    /// persist the engine state + refresh the UI — relevant when circles arrive).
    @discardableResult
    func sync(social: HavenSocial?, force: Bool = false) async -> Bool {
        guard !inFlight else { return false }
        guard canSelfSync() else { return false }
        // A warm device defers the whole pass — this is multi-transport LIST+FETCH+crypto and the
        // state it converges changes rarely. Explicit user actions force through.
        if !force, ThermalPolicy.skipSelfSync { return false }
        let accountHex = AccountStore.currentNodeHex()
        guard !accountHex.isEmpty else { return false }
        let transports = gatherTransports()
        guard !transports.isEmpty else { return false }   // needs a relay OR an S3 bucket
        inFlight = true
        defer { inFlight = false }

        // Switch-Flip §6: before choosing the seal/open path, adopt any rotated key the primary sealed to
        // this device on its last revocation (from the canonical keygrant mailbox). Once adopted, sealState/
        // openState below run the v1 (epoch-keyed) path — a survivor that missed the rotation would otherwise
        // open nothing at the new epoch and silently fall off the channel.
        await adoptRotatedGrant(accountHex: accountHex, transports: transports)

        // 1. Base = last converged state (or empty).
        let base: AccountStateHandle
        if let data = try? Data(contentsOf: baseURL), let h = try? AccountStateHandle.fromBytes(bytes: data) {
            base = h
        } else {
            base = AccountStateHandle()
        }

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device).
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let device = SelfSyncDevice.id
        let local = currentLocal(social: social)
        for (key, value) in local {
            if base.get(key: key) != value {
                _ = try? base.set(key: key, value: value, ts: now, device: device)
            }
        }
        // Detect local removals in dynamic namespaces (a contact deleted, a peer unblocked) and
        // tombstone them so the removal propagates instead of a peer device re-adding them — but ONLY
        // when the engine isn't freshly-empty (see safeToTombstone: a just-restored device must not
        // tombstone the whole account).
        if safeToTombstone(local: local, base: base) {
            for e in base.entries() where Self.dynamicPrefixes.contains(where: { e.key.hasPrefix($0) }) {
                if local[e.key] == nil {
                    _ = try? base.remove(key: e.key, ts: now, device: device)
                }
            }
        }

        // Snapshot post-fold so we can tell whether the merge below actually brought anything new.
        let preMerge = base.toBytes()

        // 3. Pull + merge every peer slot from every relay/bucket. The key LIST is cached per
        // transport (slot keys only change when a device joins/leaves); an unchanged slot blob
        // (same digest as last fetch) skips the open+merge crypto.
        let prefix = "haven/" + selfSyncSlotPrefix(accountNodeHex: accountHex)
        let ownKey = "haven/" + selfSyncSlotKey(accountNodeHex: accountHex, deviceNodeHex: SelfSyncDevice.hex)
        for t in transports {
            let tid = transportId(t)
            let keys: [String]
            if !force, let hit = peerKeysCache[tid], Date().timeIntervalSince(hit.at) < peerKeysTTL {
                keys = hit.keys
            } else {
                keys = await tList(t, prefix)
                // Only cache a NON-EMPTY answer — an unreachable transport must retry next pass.
                if !keys.isEmpty { peerKeysCache[tid] = (Date(), keys) }
            }
            for key in keys where key != ownKey {
                guard let blob = await tFetch(t, key) else { continue }
                let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
                if !force, peerSlotDigest["\(tid)|\(key)"] == digest { continue }   // byte-identical since last merge
                if let peer = openState(blob) {
                    base.merge(other: peer)
                    peerSlotDigest["\(tid)|\(key)"] = digest
                    if peerSlotDigest.count > 200 { peerSlotDigest.removeAll() }   // bound (tiny anyway)
                }
            }
        }

        let changed = base.toBytes() != preMerge

        // 4. Apply the converged state locally + persist the new base.
        await applyLocal(base, social: social)
        let converged = base.toBytes()
        try? converged.write(to: baseURL, options: .atomic)

        // 5. Re-publish our own slot (sealed) to every relay/bucket for redundancy — SKIPPED when
        // the converged state is byte-identical to what we last published (the seal itself is
        // nonce-fresh every time, so the STATE bytes are the stable identity), with a 6h floor so
        // relay-side mailbox GC still sees the slot as live.
        // The epoch rides the identity: adopting a rotated key must re-publish (v1 seal) even
        // though the state bytes themselves didn't move.
        let stateHash = SHA256.hash(data: converged).map { String(format: "%02x", $0) }.joined()
            + "|e\(SelfSyncEpochStore.epoch)"
        let d = UserDefaults.standard
        let lastAt = d.double(forKey: lastPublishedAtKey)
        if !force, d.string(forKey: lastPublishedHashKey) == stateHash,
           Date().timeIntervalSince1970 - lastAt < republishFloor {
            return changed
        }
        guard let sealed = sealState(base) else { return changed }
        var uploaded = false
        for t in transports { if await tUpload(t, ownKey, sealed) { uploaded = true } }
        if uploaded {
            d.set(stateHash, forKey: lastPublishedHashKey)
            d.set(Date().timeIntervalSince1970, forKey: lastPublishedAtKey)
        }
        return changed
    }

    // MARK: - Direct (nearby) device-to-device sync — NO relay required
    //
    // Two of the user's own devices on the same Bluetooth/Wi-Fi don't need a relay or S3 to sync:
    // they trade their sealed self-sync slots directly over the nearby mesh. This is the local
    // "handshake" path — `sealedLocalSlot` is what a device offers, `ingestPeerSlot` is how it folds
    // in what it receives.

    private func loadBase() -> AccountStateHandle {
        if let data = try? Data(contentsOf: baseURL), let h = try? AccountStateHandle.fromBytes(bytes: data) { return h }
        return AccountStateHandle()
    }

    /// Fold local changes (with fresh stamps) into `base`, including removal tombstones. Mirrors the
    /// relay `sync()`'s steps 1–2.
    private func foldLocal(into base: AccountStateHandle, social: HavenSocial?) {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let device = SelfSyncDevice.id
        let local = currentLocal(social: social)
        for (key, value) in local where base.get(key: key) != value {
            _ = try? base.set(key: key, value: value, ts: now, device: device)
        }
        if safeToTombstone(local: local, base: base) {
            for e in base.entries() where Self.dynamicPrefixes.contains(where: { e.key.hasPrefix($0) }) {
                if local[e.key] == nil { _ = try? base.remove(key: e.key, ts: now, device: device) }
            }
        }
    }

    /// Whether it's safe to emit removal tombstones for dynamic keys. NOT safe when the engine looks
    /// freshly-empty (no circles) but the base still has circles — that's a just-reset / unready device,
    /// and tombstoning there is precisely what wiped accounts. In that state we only ADD, never remove.
    private func safeToTombstone(local: [String: Data], base: AccountStateHandle) -> Bool {
        let localHasCircle = local.keys.contains { $0.hasPrefix("circle:") }
        let baseHasCircle = base.entries().contains { $0.key.hasPrefix("circle:") }
        return localHasCircle || !baseHasCircle
    }

    /// Erase this device's self-sync base. Used when adopting a DIFFERENT identity (restore/link) or on
    /// factory reset, so a freshly-restored device never diffs its empty engine against a STALE base and
    /// tombstones the account's circles/contacts — the bug that propagated and wiped the primary's posts.
    /// Also drops any rotated self-sync key (§6): a different identity must start on the v0 path, never
    /// carry a stale rotated key that no longer matches the account.
    func reset() {
        try? FileManager.default.removeItem(at: baseURL)
        SelfSyncEpochStore.clear()
        // The step-3/5 caches describe the OLD base/identity — a fresh base must re-fetch and
        // re-publish everything.
        peerKeysCache.removeAll()
        peerSlotDigest.removeAll()
        UserDefaults.standard.removeObject(forKey: lastPublishedHashKey)
        UserDefaults.standard.removeObject(forKey: lastPublishedAtKey)
    }

    /// This device's sealed self-sync slot, folding in local changes first — the payload to hand a
    /// peer device directly over the nearby mesh. No relay/S3 involved.
    func sealedLocalSlot(social: HavenSocial?) -> Data? {
        guard canSelfSync() else { return nil }
        let base = loadBase()
        foldLocal(into: base, social: social)
        try? base.toBytes().write(to: baseURL, options: .atomic)
        return sealState(base)
    }

    /// Merge a peer device's sealed slot received over a direct transport, apply + persist. Returns
    /// true if anything new arrived (so the caller can refresh the feed).
    @discardableResult
    func ingestPeerSlot(_ blob: Data, social: HavenSocial?) async -> Bool {
        guard let peer = openState(blob) else { return false }
        let base = loadBase()
        let before = base.toBytes()
        base.merge(other: peer)
        let changed = base.toBytes() != before
        await applyLocal(base, social: social)
        try? base.toBytes().write(to: baseURL, options: .atomic)
        return changed
    }

    // MARK: §6 rotated self-sync KEY GRANTS — the canonical cross-platform transport
    //
    // On a device revocation the primary mints a fresh self-sync key and hands it to every STILL-authorized
    // device (never the revoked one). Each grant is sealed to ONE device and written to that device's
    // canonical mailbox slot `self/<account>/keygrant/<device>` (core `selfSyncGrantSlotKey`) — the SAME
    // per-device self-sync transport as state (`self/<account>/state/<device>`), so a rotated key crosses
    // iOS/desktop/Android identically. This replaces the old bespoke type-30 iroh frame.

    /// PRIMARY (seed-holder): seal the CURRENT rotated key to each still-authorized device and write each
    /// grant to its per-device keygrant slot over every transport. Idempotent (a device adopts only a
    /// strictly-newer epoch), so re-emitting on rotation AND on every full-state push lets an offline / late
    /// device converge. No-op on the v0 path (epoch 0) or without the account seed (only the primary signs).
    func publishEpochGrants() async {
        guard let seed = AccountStore.storedSeed() else { return }
        let epoch = SelfSyncEpochStore.epoch
        guard epoch > 0, let key = SelfSyncEpochStore.currentKey() else { return }
        let accountHex = AccountStore.currentNodeHex()
        guard !accountHex.isEmpty else { return }
        let transports = gatherTransports()
        guard !transports.isEmpty else { return }
        for bundle in DeviceRosterManager.shared.authorizedDeviceBundles() {
            let devHex = bundle.prefix(32).map { String(format: "%02x", $0) }.joined()
            guard devHex.count == 64,
                  let grant = try? sealSelfSyncKeyEpochGrant(accountSeed: seed, deviceBundle: bundle,
                                                             epoch: epoch, selfSyncKey: key) else { continue }
            let slot = "haven/" + selfSyncGrantSlotKey(accountNodeHex: accountHex, deviceNodeHex: devHex)
            for t in transports { _ = await tUpload(t, slot, grant) }
        }
    }

    /// Any device: adopt the highest-epoch grant addressed to THIS device from the keygrant mailbox. A grant
    /// sealed to another device fails to open and is skipped; only a strictly-newer epoch is adopted (replay-
    /// safe). Runs at the top of each poll so a survivor switches to the rotated channel before reading state.
    private func adoptRotatedGrant(accountHex: String, transports: [Transport]) async {
        let accountBundle: Data
        if SeedlessState.isEnabled {
            guard let b = AccountPublicStore.load() else { return }
            accountBundle = b
        } else {
            guard let seed = AccountStore.storedSeed(),
                  let b = (try? Account.fromSeed(seed: seed))?.publicBundle() else { return }
            accountBundle = b
        }
        let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
        let prefix = "haven/" + selfSyncGrantSlotPrefix(accountNodeHex: accountHex)
        for t in transports {
            for key in await tList(t, prefix) {
                guard let blob = await tFetch(t, key),
                      let grant = try? openSelfSyncKeyEpochGrant(deviceSeed: deviceSeed,
                                                                 accountBundle: accountBundle, envelope: blob)
                else { continue }
                if SelfSyncEpochStore.adoptIfNewer(epoch: grant.epoch, key: grant.key) {
                    HavenLog.net("switch-flip: adopted rotated self-sync key epoch \(grant.epoch)")
                }
            }
        }
    }

    // MARK: transports (relay + S3 — self-sync works with either, or both)

    private enum Transport { case relay(String); case s3(S3Client) }

    /// Every place this device can read/write its self-sync slots: all configured relays plus
    /// the user's OWN S3 bucket (so sync works with no relay at all — BYO storage is enough).
    /// ALSO includes active relays wired only through an HTTP interface (`setHttpInterface`
    /// creates the entry but no circle ever lists it, so `allRelays()` never returns it) — two
    /// linked devices whose only common ground is a FRIEND's relay had NO self-sync transport at
    /// all, which is precisely the "my devices each show different things" field complaint.
    private func gatherTransports() -> [Transport] {
        let store = RelayMailboxStore.shared
        var nodes = store.allRelays()
        for e in store.allEntries() where e.active && !e.isS3 && !nodes.contains(e.hex) {
            if store.httpInterface(e.hex) != nil { nodes.append(e.hex) }
        }
        var ts: [Transport] = nodes.map { .relay($0) }
        if let s3 = SharedStore.ownerS3() { ts.append(.s3(s3)) }
        return ts
    }

    // The relay ops climb the same ladder as SharedStore.uploadEvent: our OWN hosted relay reads/
    // writes its local store (no iroh self-connection), then the relay's signed plain-HTTP
    // interface (the transport that actually works cross-NAT — iroh-only self-sync was a dead
    // lane wherever the dial couldn't land while HTTP could), then iroh as the last rung.

    private func tList(_ t: Transport, _ prefix: String) async -> [String] {
        switch t {
        case .relay(let node):
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                return RelayHost.shared.localList(prefix)
            }
            if let keys = await SharedStore.selfSyncHttpList(node, prefix: prefix) { return keys }
            guard let c = await RelayClients.client(node) else { return [] }
            // list() now throws to distinguish a dead dial from an empty mailbox; here an
            // error just means this transport has nothing for us — fall through to [].
            return (try? await c.list(prefix: prefix)) ?? []
        case .s3(let c):
            return (try? await c.listKeys(prefix: prefix)) ?? []
        }
    }

    private func tFetch(_ t: Transport, _ key: String) async -> Data? {
        switch t {
        case .relay(let node):
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                return RelayHost.shared.localGet(key)
            }
            switch await SharedStore.selfSyncHttpGet(node, key: key) {
            case .hit(let d): return d
            case .miss: return nil          // reached — same store as iroh, don't redial
            case .unavailable: break        // no HTTP rung → iroh
            }
            guard let c = await RelayClients.client(node) else { return nil }
            return await c.get(key: key)
        case .s3(let c):
            return try? await c.getObject(key: key)
        }
    }

    private func tUpload(_ t: Transport, _ key: String, _ data: Data) async -> Bool {
        switch t {
        case .relay(let node):
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                return RelayHost.shared.localPut(key, data)
            }
            if await SharedStore.selfSyncHttpPut(node, key: key, data: data) { return true }
            guard let c = await RelayClients.client(node) else { return false }
            do { try await c.put(key: key, data: data); RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); return true }
            catch { RelayHealth.shared.recordFailure(node); return false }
        case .s3(let c):
            do { try await c.putObject(key: key, data: data); return true } catch { return false }
        }
    }
}

private extension Data {
    var havenHexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(havenHex hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self = Data(bytes)
    }
}
