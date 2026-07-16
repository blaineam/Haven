import Foundation

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
        // Pinned DM conversations (ordered) sync across my devices, last-writer-wins. Only broadcast when
        // non-empty so a fresh device can't blank a sibling's pins (absence ≠ authoritative).
        let pins = DMPinStore.shared.pinned
        if !pins.isEmpty { m["setting:pinnedDMs"] = Data(pins.joined(separator: "\n").utf8) }
        // DM read watermarks — reading a thread on one device clears its badge on the others.
        // Monotonic per-conversation timestamps, merged by per-key MAX on apply (always safe:
        // no device can un-read another, and a fresh device's empty map changes nothing).
        let reads = DMReadStore.shared.lastRead
        if !reads.isEmpty, let data = try? JSONEncoder().encode(reads) { m["setting:dmLastRead"] = data }
        // Roster: contacts (full card) + blocked list.
        for c in ContactsStore.shared.contacts {
            if let data = try? JSONEncoder().encode(c) { m["contact:\(c.idHex)"] = data }
        }
        for hex in ConnectionsStore.shared.blocked { m["blocked:\(hex)"] = Data([1]) }
        // Explicit circle severances — LWW per entry, never inferred from absence (NOT a dynamic
        // prefix). Keyed removal:<circleId>|<hex>: value 1 = removed, value 0 = deliberately re-added.
        // The 0 write is what lets a re-add actually stick fleet-wide — before it, the grow-only
        // removal record re-severed a re-added friend on every sibling's sync pass, forever.
        for key in ConnectionsStore.shared.circleRemovals { m["removal:\(key)"] = Data([1]) }
        for key in ConnectionsStore.shared.clearedCircleRemovals { m["removal:\(key)"] = Data([0]) }
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
            for ci in social.circles() {
                // Shared FFI encoder → byte-identical circle records across iOS/desktop/Android.
                m["circle:\(ci.id)"] = encodeCircleSync(
                    name: ci.name,
                    memberBundles: social.circleMemberBundles(circleId: ci.id),
                    relays: RelayMailboxStore.shared.relays(forCircle: ci.id))
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
    private func applyLocal(_ h: AccountStateHandle, social: HavenSocial?) {
        let p = ProfileStore.shared
        // Never apply an EMPTY scalar over a non-empty local one (belt-and-suspenders against a blank
        // overwrite — see currentLocal). Non-empty incoming values still win normally.
        if let v = h.get(key: "profile:name"), let s = String(data: v, encoding: .utf8), !s.isEmpty, s != p.displayName {
            HavenLog.sync("apply profile:name '\(p.displayName)' → '\(s)'"); p.displayName = s
        }
        if let v = h.get(key: "profile:emoji"), let s = String(data: v, encoding: .utf8), !s.isEmpty, s != p.emoji { p.emoji = s }
        if let v = h.get(key: "profile:bio"), let s = String(data: v, encoding: .utf8), !s.isEmpty, s != p.bio {
            HavenLog.sync("apply profile:bio (\(p.bio.count)→\(s.count) chars)"); p.bio = s
        }
        if let v = h.get(key: "profile:link"), let s = String(data: v, encoding: .utf8), !s.isEmpty, s != p.link { p.link = s }
        if let v = h.get(key: "profile:avatar"), let b64 = String(data: v, encoding: .utf8), b64 != p.avatarBase64,
           let data = Data(base64Encoded: b64), let img = PlatformImage(data: data) {
            p.setAvatar(img)
        }

        let s = SettingsStore.shared
        if let b = boolValue(h, "setting:saveToPhotos"), b != s.saveToPhotos { s.saveToPhotos = b }
        if let b = boolValue(h, "setting:saveOthersToPhotos"), b != s.saveOthersToPhotos { s.saveOthersToPhotos = b }
        if let b = boolValue(h, "setting:autoOptimize"), b != s.autoOptimize { s.autoOptimize = b }
        // `setting:silent` is deliberately NOT applied (see currentLocal): a stale value left in an old
        // base by a previous build must not reach in and mute/unmute this device long after the fact.
        if let v = h.get(key: "setting:retentionDays"), v.count == 4 {
            let n = Int(Int32(littleEndian: v.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
            if n != s.retentionDays { s.retentionDays = n }
        }
        if let v = h.get(key: "setting:pinnedDMs"), let str = String(data: v, encoding: .utf8) {
            DMPinStore.shared.applySynced(str.split(separator: "\n").map(String.init))
        }
        if let v = h.get(key: "setting:dmLastRead"), let m = try? JSONDecoder().decode([String: UInt64].self, from: v) {
            DMReadStore.shared.applySynced(m)   // per-key MAX merge
            FeedStore.shared.recomputeUnreadDMs()
        }

        // Roster reconciliation (set-like — enumerate the converged state via entries()).
        let live = h.entries()

        // Contacts: upsert everything present; drop locals the converged state no longer has
        // (a contact deleted on another device propagated as a tombstone).
        var wantContacts: [String: Contact] = [:]
        for e in live where e.key.hasPrefix("contact:") {
            if let c = try? JSONDecoder().decode(Contact.self, from: e.value) { wantContacts[c.idHex] = c }
        }
        let cs = ContactsStore.shared
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

        // Circle severances synced from another of my devices → apply them here too: record the removal
        // and purge that member from the circle (so removing someone on my phone severs them on my Mac).
        // Value 0 = the removal was deliberately CLEARED (re-added) on another device — un-ban locally
        // and never re-sever; the member bundle comes back via the additive circle: record.
        for e in live where e.key.hasPrefix("removal:") {
            let key = String(e.key.dropFirst("removal:".count))   // "<circleId>|<hex>"
            guard let bar = key.firstIndex(of: "|") else { continue }
            let circleId = String(key[key.startIndex..<bar])
            let hex = String(key[key.index(after: bar)...])
            guard !circleId.isEmpty, !hex.isEmpty else { continue }
            if e.value.first == 0 {
                if conn.isRemovedFromCircle(hex, circleId: circleId) {
                    conn.clearCircleRemoval(hex, circleId: circleId)
                }
                continue
            }
            guard !conn.isRemovedFromCircle(hex, circleId: circleId) else { continue }
            conn.removeFromCircle(hex, circleId: circleId)
            social?.removeFromCircle(circleId: circleId, nodeHex: hex)
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
            for e in live where e.key.hasPrefix("roster:") { _ = social.ingestRosterWire(wire: e.value) }
        }

        // Circles: reconstruct each synced circle — create it, register every member's bundle
        // (so this device can seal to them), and record its relay mailbox(es). Additive in v1.
        if let social = social {
            let existing = social.circles()
            for e in live where e.key.hasPrefix("circle:") {
                let id = String(e.key.dropFirst("circle:".count))
                guard let rec = decodeCircleSync(bytes: e.value) else { continue }
                social.createCircle(id: id, name: rec.name)   // no-op if it already exists
                if let cur = existing.first(where: { $0.id == id }), cur.name != rec.name {
                    social.renameCircle(id: id, name: rec.name)
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

    /// One full sync pass: fold local changes into the base with fresh stamps, merge every peer
    /// slot, apply the converged result locally, persist, and re-publish our own slot. Safe to
    /// call on a timer; coalesces if already running. No-op without an account or any sync
    /// target (a relay or the user's S3 bucket — either works, no relay required).
    /// Returns `true` if the merge brought in changes from another device (so the caller can
    /// persist the engine state + refresh the UI — relevant when circles arrive).
    @discardableResult
    func sync(social: HavenSocial?) async -> Bool {
        guard !inFlight else { return false }
        guard let seed = AccountStore.storedSeed() else { return false }
        let accountHex = AccountStore.currentNodeHex()
        guard !accountHex.isEmpty else { return false }
        let transports = gatherTransports()
        guard !transports.isEmpty else { return false }   // needs a relay OR an S3 bucket
        inFlight = true
        defer { inFlight = false }

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

        // 3. Pull + merge every peer slot from every relay/bucket.
        let prefix = "haven/" + selfSyncSlotPrefix(accountNodeHex: accountHex)
        let ownKey = "haven/" + selfSyncSlotKey(accountNodeHex: accountHex, deviceNodeHex: SelfSyncDevice.hex)
        for t in transports {
            let keys = await tList(t, prefix)
            for key in keys where key != ownKey {
                guard let blob = await tFetch(t, key) else { continue }
                if let peer = try? openAccountState(accountSeed: seed, sealed: blob) {
                    base.merge(other: peer)
                }
            }
        }

        let changed = base.toBytes() != preMerge

        // 4. Apply the converged state locally + persist the new base.
        applyLocal(base, social: social)
        try? base.toBytes().write(to: baseURL, options: .atomic)

        // 5. Re-publish our own slot (sealed) to every relay/bucket for redundancy.
        guard let sealed = try? sealAccountState(accountSeed: seed, state: base) else { return changed }
        for t in transports { _ = await tUpload(t, ownKey, sealed) }
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
    func reset() { try? FileManager.default.removeItem(at: baseURL) }

    /// This device's sealed self-sync slot, folding in local changes first — the payload to hand a
    /// peer device directly over the nearby mesh. No relay/S3 involved.
    func sealedLocalSlot(social: HavenSocial?) -> Data? {
        guard let seed = AccountStore.storedSeed() else { return nil }
        let base = loadBase()
        foldLocal(into: base, social: social)
        try? base.toBytes().write(to: baseURL, options: .atomic)
        return try? sealAccountState(accountSeed: seed, state: base)
    }

    /// Merge a peer device's sealed slot received over a direct transport, apply + persist. Returns
    /// true if anything new arrived (so the caller can refresh the feed).
    @discardableResult
    func ingestPeerSlot(_ blob: Data, social: HavenSocial?) -> Bool {
        guard let seed = AccountStore.storedSeed(),
              let peer = try? openAccountState(accountSeed: seed, sealed: blob) else { return false }
        let base = loadBase()
        let before = base.toBytes()
        base.merge(other: peer)
        let changed = base.toBytes() != before
        applyLocal(base, social: social)
        try? base.toBytes().write(to: baseURL, options: .atomic)
        return changed
    }

    // MARK: transports (relay + S3 — self-sync works with either, or both)

    private enum Transport { case relay(String); case s3(S3Client) }

    /// Every place this device can read/write its self-sync slots: all configured relays plus
    /// the user's OWN S3 bucket (so sync works with no relay at all — BYO storage is enough).
    private func gatherTransports() -> [Transport] {
        var ts: [Transport] = RelayMailboxStore.shared.allRelays().map { .relay($0) }
        if let s3 = SharedStore.ownerS3() { ts.append(.s3(s3)) }
        return ts
    }

    private func tList(_ t: Transport, _ prefix: String) async -> [String] {
        switch t {
        case .relay(let node):
            guard let c = await RelayClients.client(node) else { return [] }
            return await c.list(prefix: prefix)
        case .s3(let c):
            return (try? await c.listKeys(prefix: prefix)) ?? []
        }
    }

    private func tFetch(_ t: Transport, _ key: String) async -> Data? {
        switch t {
        case .relay(let node):
            guard let c = await RelayClients.client(node) else { return nil }
            return await c.get(key: key)
        case .s3(let c):
            return try? await c.getObject(key: key)
        }
    }

    private func tUpload(_ t: Transport, _ key: String, _ data: Data) async -> Bool {
        switch t {
        case .relay(let node):
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
