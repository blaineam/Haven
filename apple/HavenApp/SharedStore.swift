import Foundation
import CryptoKit

/// The "volunteer as tribute" shared circle store. A member who turns this on keeps a
/// sealed copy of the circle's media in their own S3 bucket and re-serves it to anyone
/// who's missing it — so memories survive even when the original sender is offline.
///
/// Security: every blob is sealed to the *circle* (seal_circle_media), so the bucket
/// host stores only opaque bytes it cannot read, and a fetched blob is verified against
/// the circle roster before it's opened. No credentials are ever shared between members
/// — the volunteer simply acts as a durable, always-available media source over the
/// existing P2P media protocol. Keys live only in the device Keychain.
/// The circle's shared relay bucket, received (sealed) from whoever volunteered theirs.
/// Distinct from StorageStore (your *own* bucket). Secret lives only in the Keychain.
@MainActor
final class SharedMailboxStore: ObservableObject {
    static let shared = SharedMailboxStore()
    @Published private(set) var config: S3Config?

    private let d = UserDefaults.standard
    private let key = "haven.sharedMailbox"

    private init() {
        if let data = d.data(forKey: key), var c = try? JSONDecoder().decode(S3Config.self, from: data) {
            c.secret = Keychain.get("sharedMailboxSecret") ?? ""
            config = c
        }
    }

    func set(_ c: S3Config) {
        var stored = c; stored.secret = ""   // keep the secret out of UserDefaults
        d.set(try? JSONEncoder().encode(stored), forKey: key)
        Keychain.set(c.secret, for: "sharedMailboxSecret")
        config = c
    }
    func clear() {
        d.removeObject(forKey: key)
        Keychain.set("", for: "sharedMailboxSecret")
        config = nil
    }
}

/// Serializes media backups so they don't all load full files into memory at once. backfillMailboxMedia
/// and the per-post backup sites used to spawn a Task PER media ref concurrently — each loading + sealing a
/// full file (2× in RAM) — which ballooned memory to ~3.4GB and jetsam-killed iOS once a device held a lot
/// of media. Process ONE at a time so peak memory is ~one media file, not the whole library.
@MainActor
final class MediaBackupQueue {
    static let shared = MediaBackupQueue()
    private var pending: [(ref: String, cid: String)] = []
    private var draining = false
    func enqueue(_ ref: String, circleId: String, social: HavenSocial) {
        if MediaStore.isSynthetic(ref) { return }   // geo: pins et al. carry no bytes — never relay-storable
        if pending.contains(where: { $0.ref == ref && $0.cid == circleId }) { return }
        pending.append((ref, circleId))
        if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }   // bound the queue itself
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while !pending.isEmpty {
                let job = pending.removeFirst()
                await SharedStore.backup(ref: job.ref, circleId: job.cid, social: social)
            }
            draining = false
        }
    }
}

/// Records which media blobs we've CONFIRMED are on which destination (relay node id, or "s3"), so
/// the every-2-min backfill stops re-uploading — or even re-reading/re-sealing — a blob the relay
/// already has. Media keys are content-addressed (`haven/media/<ref>`), so a blob never changes: once
/// it's on a relay it's there for good, making this a permanent, staleness-free cache. Before this,
/// the ONLY dedup was a live `has()`/`head()` round-trip, which fails over a flaky transport and made
/// the device re-upload the whole blob every cycle — "the iPhone constantly sends media the relay
/// already possesses." Keyed "dest|ref".
@MainActor
enum MediaBackupLedger {
    private static let defaultsKey = "haven.media.backedUp"
    private static var set: Set<String> = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    static func has(_ dest: String, _ ref: String) -> Bool { set.contains("\(dest)|\(ref)") }
    static func mark(_ dest: String, _ ref: String) {
        guard set.insert("\(dest)|\(ref)").inserted else { return }
        if set.count > 20_000 { set = Set(set.suffix(20_000)) }
        UserDefaults.standard.set(Array(set), forKey: defaultsKey)
    }
    /// Forget a destination's confirmations (e.g. a relay was wiped/forgotten) so we re-mirror to it.
    static func forgetDest(_ dest: String) {
        let before = set.count
        set = set.filter { !$0.hasPrefix("\(dest)|") }
        if set.count != before { UserDefaults.standard.set(Array(set), forKey: defaultsKey) }
    }
}

/// Exponential backoff for media backups that keep FAILING to land on any destination. Without this,
/// the every-2-min `backfillMailboxMedia` re-reads, re-seals and re-uploads the same blob forever when
/// no relay can hold it (e.g. every relay is behind a NAT the iroh blob ALPN can't traverse and there's
/// no S3 bucket) — the "my posts get synced again and again" heat/traffic storm. Once a blob lands
/// anywhere the backoff is cleared; while it can't land the retry interval doubles 2min → … → ~1h, so a
/// genuinely-unreachable blob costs one attempt an hour instead of thirty. In-memory only: a fresh
/// launch is a legitimate reason to retry promptly (the transport may have changed).
@MainActor
enum MediaBackupBackoff {
    private static let baseMs: UInt64 = 2 * 60 * 1000        // first retry gap after a stall
    private static let capMs: UInt64 = 60 * 60 * 1000        // never wait longer than an hour
    private static var nextTry: [String: UInt64] = [:]       // ref → earliest retry (epoch ms)
    private static var fails: [String: Int] = [:]            // ref → consecutive stall count

    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// True if `ref` stalled recently and its backoff window hasn't elapsed — skip re-enqueueing it.
    static func shouldSkip(_ ref: String) -> Bool {
        guard let due = nextTry[ref] else { return false }
        return nowMs() < due
    }

    /// The blob reached at least one destination (or is fully confirmed) — stop backing off.
    static func recordLanded(_ ref: String) {
        nextTry[ref] = nil
        fails[ref] = nil
    }

    /// The blob reached NO destination this pass — grow the retry gap.
    static func recordStalled(_ ref: String) {
        let n = (fails[ref] ?? 0) + 1
        fails[ref] = n
        let shift = min(n - 1, 5)                            // 2,4,8,16,32,64 min → capped
        let gap = min(baseMs << UInt64(shift), capMs)
        nextTry[ref] = nowMs() + gap
        if nextTry.count > 20_000 {                          // bound memory on huge feeds
            nextTry.removeAll(); fails.removeAll()
        }
    }
}

@MainActor
enum SharedStore {
    /// The bucket to use for the circle's mailbox: the shared relay if one was set,
    /// otherwise your own bucket *if* you've opted in as the volunteer.
    static func mailboxClient() -> S3Client? {
        if let c = SharedMailboxStore.shared.config, c.isComplete { return S3Client(config: c) }
        if StorageStore.shared.shareCircleMedia { return S3Client(StorageStore.shared) }
        return nil
    }
    /// True when this device participates in a shared mailbox (own volunteer or received relay).
    static var isVolunteering: Bool { mailboxClient() != nil }

    private static func key(_ ref: String) -> String { "haven/media/\(ref)" }
    // Chunks live in a SIBLING directory "<ref>.p/", NOT nested under the manifest key. On a hierarchical
    // disk relay (blobstore local_put maps each key segment to a directory) the manifest key "haven/media/<ref>"
    // is a FILE, so chunks under "haven/media/<ref>/<i>" would force "<ref>" to be a directory too — a
    // file-vs-dir collision that fails the manifest write. "<ref>.p" is a distinct name → no collision.
    private static func chunkKey(_ ref: String, _ i: Int) -> String { "haven/media/\(ref).p/\(i)" }

    // MARK: - Chunked media transfer (large-blob fix)
    //
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net blobstore). Large videos
    // (600 MB+) sealed into ONE blob under "haven/media/<ref>" exceed that, so a GET truncates and
    // the receiver can't play them (photos, ~5 MB, worked). Fix: slice the SEALED bytes into 8 MB
    // chunks under "haven/media/<ref>.p/<i>" and store a tiny manifest under "haven/media/<ref>". On
    // download, fetch chunks IN ORDER and APPEND to a file on disk (streaming — never hold the full
    // sealed blob in RAM, which OOM-killed Android before). Small media (<= one chunk) stays a single
    // sealed blob (no manifest) for back-compat. This format is BYTE-IDENTICAL across iOS/macOS,
    // Android and desktop so they interoperate.
    static let mediaChunkBytes = 8 * 1024 * 1024   // 8 MB — well under MAX_BLOB, memory-safe
    /// Magic prefix that marks a manifest blob (a sealed envelope is JSON starting with '{', so it can
    /// never collide). Exactly these 9 bytes, then a JSON body.
    static let manifestMagic = Data("HVCHUNK1\n".utf8)

    /// Build the manifest blob for a sealed media of `sizes` chunk lengths.
    private static func makeManifest(sizes: [Int]) -> Data {
        let total = sizes.reduce(0, +)
        let json: [String: Any] = ["v": 1, "chunks": sizes.count, "total": total, "sizes": sizes]
        var out = manifestMagic
        out.append((try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
        return out
    }
    /// If `blob` is a chunk manifest, return the parsed chunk count; else nil (legacy/small single blob).
    private static func parseManifest(_ blob: Data) -> Int? {
        guard blob.count > manifestMagic.count, blob.prefix(manifestMagic.count) == manifestMagic else { return nil }
        let body = blob.suffix(from: blob.startIndex + manifestMagic.count)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let n = obj["chunks"] as? Int, n > 0 else { return nil }
        return n
    }

    /// The relay node ids serving a circle (the common path) — posts are mirrored to ALL of them
    /// and read from any (graceful fallback if one is down).
    private static func relayNodes(_ circleId: String) -> [String] {
        RelayMailboxStore.shared.relays(forCircle: circleId)
    }
    /// First configured relay — for "does this circle have a relay at all" checks.
    private static func relayNode(_ circleId: String) -> String? {
        relayNodes(circleId).first
    }

    /// Relay node ids to MIRROR media to / FETCH media from — the circle's own relays PLUS every other
    /// known relay. Media keys (`haven/media/<ref>`) are content-addressed AND permission-free on the
    /// relay (unlike mailbox keys, which are circle-membership gated — a relay can `ERR forbidden` a
    /// device for messages while still storing its media), so a blob may safely live on ANY relay the
    /// members can reach. Mirroring to every known relay is what makes media land when a circle's own
    /// relays are all offline/NAT-unreachable but some OTHER relay (e.g. a hosted/NAS relay configured
    /// for a different circle) is reachable — that relay accepts the media even though it forbids the
    /// device's mailbox writes. Content-addressed keys make the extra puts idempotent, unreachable
    /// relays fail fast and back off, and mesh anti-entropy replicates the blob onto the circle's own
    /// relays once they return; a friend who shares any of these relays fetches it directly. `allRelays`
    /// is already active-only (deleted/forgotten relays excluded); s3: pseudo-nodes are handled by S3.
    private static func mediaDests(_ circleId: String) -> [String] {
        var nodes = relayNodes(circleId).filter { !$0.hasPrefix("s3:") }
        for r in RelayMailboxStore.shared.allRelays() where !r.hasPrefix("s3:") && !nodes.contains(r) {
            nodes.append(r)
        }
        return nodes
    }
    /// This device's OWN S3 bucket (the owner uses its credentials directly).
    static func ownerS3() -> S3Client? { S3Client(StorageStore.shared) }
    private static func isOwner(_ circleId: String) -> Bool {
        PresignStore.shared.ownedCircles.contains(circleId) && ownerS3() != nil
    }
    /// True when a circle has *some* mailbox — a Haven relay, a pre-signed pool, or raw S3 creds.
    static func hasMailbox(_ circleId: String) -> Bool {
        relayNode(circleId) != nil || isOwner(circleId) || PresignStore.shared.hasPool(circleId) || mailboxClient() != nil
    }

    /// Seal a locally-held media blob to the circle and store it in the circle's mailbox
    /// (relay if set, else S3) — idempotent.
    static func backup(ref: String, circleId: String, social: HavenSocial) async {
        // Skip entirely if this blob is already confirmed on EVERY destination — before the expensive
        // file read + seal. Content-addressed keys never change, so a confirmed upload is permanent.
        // This is what stops the periodic backfill from re-sending media the relay already has.
        // mediaDests broadens beyond the circle's own (possibly all-NAT'd) relays to any reachable
        // shared relay, so a video isn't stranded when the circle's relay is offline.
        let destNodes = mediaDests(circleId)
        let s3 = mediaS3(for: circleId)
        let allConfirmed = destNodes.allSatisfy { MediaBackupLedger.has($0, ref) }
            && (s3 == nil || MediaBackupLedger.has("s3", ref))
        if allConfirmed && (!destNodes.isEmpty || s3 != nil) { MediaBackupBackoff.recordLanded(ref); return }
        guard let url = MediaStore.shared.storagePath(for: ref) else { return }

        // ---- Probe phase: NO file read, NO seal. `key(ref)` is content-addressed — independent of
        // the sealed bytes — so every unconfirmed destination can be asked "do you already hold it?"
        // first. Sealing costs ~2× the file size in transient RAM (a 600 MB video → GBs), and doing it
        // only to find every unconfirmed relay unreachable/in backoff made EVERY backfill pass spike
        // memory for nothing. Only a destination that is REACHABLE and MISSING the blob justifies the
        // read+seal below; an unreachable one is retried on a later pass, after its backoff.
        enum Route { case ownRelay; case http(base: String, token: String); case dial(RelayClient) }
        var uploads: [(node: String, route: Route)] = []
        var s3Needs = false
        var landed = false   // some destination holds it (probe hit) or accepted it (upload)

        // S3/HTTP bucket — the DEFAULT media transport (see the upload ordering note below).
        if let s3, !MediaBackupLedger.has("s3", ref) {
            switch await s3.headObjectExists(key: key(ref)) {
            case .some(true): MediaBackupLedger.mark("s3", ref); landed = true
            case .some(false): s3Needs = true
            case .none: break   // bucket unreachable — don't seal on its behalf
            }
        } else if s3 != nil { landed = true }

        for node in destNodes {
            if MediaBackupLedger.has(node, ref) { landed = true; continue }   // already confirmed on this relay
            // Our OWN hosted relay: the local store answers instantly (no dial).
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                if RelayHost.shared.localGet(key(ref)) != nil { MediaBackupLedger.mark(node, ref); landed = true }
                else { uploads.append((node, .ownRelay)) }
                continue
            }
            // Plain-HTTP interface first (the reliable cross-NAT path). A reachable relay that
            // answers is authoritative — the iroh path serves the SAME store, so don't also dial.
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                var resolved = false
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpGet(base, http.token, key(ref)) {
                    case .success(let existing):
                        if existing != nil {
                            RelayMailboxStore.shared.markSeen(node)
                            MediaBackupLedger.mark(node, ref); landed = true
                        } else {
                            uploads.append((node, .http(base: base, token: http.token)))
                        }
                        resolved = true
                    case .failure:
                        markHttpUrlBad(base)
                    }
                    if resolved { break }
                }
                if resolved { continue }
            }
            // iroh fallback — RelayClients honors RelayHealth backoff (nil = skip WITHOUT sealing).
            guard let c = await RelayClients.client(node) else {
                HavenLog.sync("backup probe SKIP ref=\(ref) relay=\(node.prefix(8)) — unreachable/backing off (no http, no dial)")
                continue
            }
            if await c.has(key: key(ref)) {
                RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                MediaBackupLedger.mark(node, ref); landed = true
            } else {
                uploads.append((node, .dial(c)))
            }
        }

        guard s3Needs || !uploads.isEmpty else {
            // Every unconfirmed destination either turned out to already hold the blob (now in the
            // ledger) or was unreachable/backing off — the file is never read or sealed this pass.
            if !landed { HavenLog.sync("backup NO-DEST ref=\(ref)"); MediaBackupBackoff.recordStalled(ref) }
            else { MediaBackupBackoff.recordLanded(ref) }
            return
        }

        // ---- Seal to a TEMP FILE, now known to be needed by at least one reachable destination.
        // File→file in NATIVE memory (seal_circle_media_file): a large video sealed via the in-memory
        // path forces the whole sealed envelope through one contiguous Swift `Data`, which TRAPS
        // (EXC_BREAKPOINT in __DataStorage.init) when the allocation can't be satisfied — the app
        // crashed the instant a big video was posted. Sealing to disk keeps the big buffers off the
        // managed heap; the uploads below then stream the sealed file in 8 MB windows (never whole).
        // OFF the main thread — the serial backup queue runs these back-to-back.
        let sealedURL = url.deletingLastPathComponent()
            .appendingPathComponent(".seal-\(ref).tmp")
        defer { try? FileManager.default.removeItem(at: sealedURL) }
        let sealedOK = await Task.detached(priority: .utility) { () -> Bool in
            social.sealCircleMediaFile(circleId: circleId, inPath: url.path, outPath: sealedURL.path)
        }.value
        guard sealedOK,
              let sealedSize = (try? FileManager.default.attributesOfItem(atPath: sealedURL.path)[.size] as? Int) ?? nil
        else { HavenLog.sync("backup SEAL-FAIL ref=\(ref)"); MediaBackupBackoff.recordStalled(ref); return }
        let chunked = sealedSize > mediaChunkBytes
        HavenLog.sync("backup ref=\(ref) size=\(sealedSize) chunked=\(chunked) dests=\(uploads.count + (s3Needs ? 1 : 0)) s3=\(s3Needs)")

        // 1) S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT,
        //    whereas the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a
        //    pure-relay cross-NAT path (noq/iroh fork bug), so blob transfers that must cross a NAT
        //    stall and die while messaging on the same relay path works.
        if s3Needs, let s3 {
            do {
                try await putMediaFile(ref: ref, sealedURL: sealedURL, size: sealedSize) { try await s3.putObject(key: $0, data: $1) }
                HavenLog.sync("backup s3-put OK ref=\(ref) size=\(sealedSize) chunked=\(chunked)")
                MediaBackupLedger.mark("s3", ref); landed = true
            }
            catch { HavenLog.sync("backup s3-put FAIL ref=\(ref): \(error.localizedDescription)") }
        }
        // 2) Mirror to every relay that probed reachable-and-missing (redundancy + the LAN/hosted
        //    fast-path). Content-addressed key → idempotent re-puts.
        for (node, route) in uploads {
            switch route {
            case .ownRelay:
                // Our OWN hosted relay: store directly in the local mailbox (no iroh self-dial).
                try? await putMediaFile(ref: ref, sealedURL: sealedURL, size: sealedSize) { _ = RelayHost.shared.localPut($0, $1) }
                MediaBackupLedger.mark(node, ref); landed = true
            case .http(let base, let token):
                do {
                    try await putMediaFile(ref: ref, sealedURL: sealedURL, size: sealedSize) { k, d in
                        guard await httpPut(base, token, k, d) else { throw URLError(.cannotConnectToHost) }
                    }
                    RelayMailboxStore.shared.markSeen(node)
                    HavenLog.sync("backup http-put OK ref=\(ref) relay=\(node.prefix(8))")
                    MediaBackupLedger.mark(node, ref); landed = true
                } catch {
                    markHttpUrlBad(base)
                    HavenLog.sync("backup http-put FAIL ref=\(ref) relay=\(node.prefix(8)): \(error.localizedDescription) — trying blob dial")
                    // The HTTP interface died mid-upload — fall back to the iroh dial (same store).
                    guard let c = await RelayClients.client(node) else { continue }
                    do {
                        try await putMediaFile(ref: ref, sealedURL: sealedURL, size: sealedSize) { try await c.put(key: $0, data: $1) }
                        RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                        HavenLog.sync("backup blob-dial OK ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize) — cross-NAT blob path WORKS")
                        MediaBackupLedger.mark(node, ref); landed = true
                    }
                    catch {
                        HavenLog.sync("backup blob-dial FAIL ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize): \(error.localizedDescription)")
                        RelayHealth.shared.recordFailure(node); RelayClients.forget(node)
                    }
                }
            case .dial(let c):
                do {
                    try await putMediaFile(ref: ref, sealedURL: sealedURL, size: sealedSize) { try await c.put(key: $0, data: $1) }
                    RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                    HavenLog.sync("backup blob-dial OK ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize) — cross-NAT blob path WORKS")
                    MediaBackupLedger.mark(node, ref); landed = true
                }
                catch {
                    HavenLog.sync("backup blob-dial FAIL ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize): \(error.localizedDescription)")
                    RelayHealth.shared.recordFailure(node); RelayClients.forget(node)
                }
            }
        }
        if !landed { HavenLog.sync("backup NO-DEST ref=\(ref)"); MediaBackupBackoff.recordStalled(ref) }
        else { MediaBackupBackoff.recordLanded(ref) }
    }

    /// The bucket used for MEDIA in this circle: the owner's own creds for a circle whose pre-signed
    /// pool we mint, else the shared/volunteer mailbox bucket. Same selection as `uploadEvent`.
    private static func mediaS3(for circleId: String) -> S3Client? {
        isOwner(circleId) ? ownerS3() : mailboxClient()
    }

    /// PUT one sealed media blob that lives in a FILE through a destination's key/value writer,
    /// STREAMING the file in 8 MB windows so the whole sealed blob is never resident on the managed
    /// heap (a large video's sealed envelope is hundreds of MB — holding it whole traps the allocator).
    /// Large → 8 MB chunk keys + a manifest; small → a single blob. Same wire format as `putMedia`.
    private static func putMediaFile(ref: String, sealedURL: URL, size: Int,
                                     put: (String, Data) async throws -> Void) async throws {
        if size > mediaChunkBytes {
            guard let fh = try? FileHandle(forReadingFrom: sealedURL) else { throw URLError(.cannotOpenFile) }
            defer { try? fh.close() }
            var sizes: [Int] = []
            while true {
                let slice = (try? fh.read(upToCount: mediaChunkBytes)) ?? nil
                guard let slice, !slice.isEmpty else { break }
                try await put(chunkKey(ref, sizes.count), slice)
                sizes.append(slice.count)
            }
            try await put(key(ref), makeManifest(sizes: sizes))
        } else {
            // Small (≤ one window): reading it whole is memory-safe.
            let whole = (try? Data(contentsOf: sealedURL)) ?? Data()
            try await put(key(ref), whole)
        }
    }

    /// A source that can serve the manifest+chunk keys for one media ref.
    private enum MediaSource {
        case ownRelay                              // our own hosted relay (local store)
        case relay(RelayClient, String)            // dialed relay client + node hex
        case s3(S3Client)                          // shared/owner bucket
        case http(String, String)                  // relay plain-HTTP interface (base url, token)
    }
    /// Fetch one key's bytes from a source (nil = miss).
    private static func fetch(_ src: MediaSource, _ key: String) async -> Data? {
        switch src {
        case .ownRelay: return RelayHost.shared.localGet(key)
        case .relay(let c, _): return await c.get(key: key)
        case .s3(let s3): return try? await s3.getObject(key: key)
        case .http(let base, let token): return (try? await httpGet(base, token, key).get()) ?? nil
        }
    }

    // MARK: - Relay plain-HTTP media interface (client side)
    //
    // GET/PUT against a relay's HTTP interface (core httprelay.rs): `<base>/k/<key>` with the
    // relay's bearer token (learned from the sealed frame-19 announce). This is the DEFAULT
    // cross-NAT media transport; a URL that doesn't answer is backed off for 2 minutes so a dead
    // LAN address doesn't cost a connect-timeout per chunk.

    private static var httpUrlBadUntil: [String: Date] = [:]
    private static func httpUrlBad(_ base: String) -> Bool { (httpUrlBadUntil[base] ?? .distantPast) > Date() }
    private static func markHttpUrlBad(_ base: String) { httpUrlBadUntil[base] = Date().addingTimeInterval(120) }

    private static func httpKeyURL(_ base: String, _ key: String) -> URL? {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        return URL(string: "\(trimmed)/k/\(enc)")
    }

    /// GET one key. `.success(nil)` = relay reached but doesn't hold it (a real MISS — the iroh
    /// path serves the same store, so don't dial it for the same key); `.failure` = unreachable.
    private static func httpGet(_ base: String, _ token: String, _ key: String) async -> Result<Data?, Error> {
        guard let url = httpKeyURL(base, key) else { return .failure(URLError(.badURL)) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200...299: return .success(data)
            case 404: return .success(nil)
            default: return .failure(URLError(.badServerResponse))
            }
        } catch { return .failure(error) }
    }

    private static func httpPut(_ base: String, _ token: String, _ key: String, _ body: Data) async -> Bool {
        guard let url = httpKeyURL(base, key) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            return (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { return false }
    }

    /// Fetch a media blob from the circle's mailbox and open it for whichever circle it belongs to.
    /// If the mailbox holds a chunked manifest (large media), reassemble the sealed bytes by streaming
    /// each 8 MB chunk to a temp file on disk — the full sealed blob is NEVER held in RAM during transfer.
    static func restore(ref: String, circleIds: [String], social: HavenSocial) async -> Data? {
        var chosen: MediaSource?
        var head: Data?
        var src = "none"
        // We fetch the manifest key "haven/media/<ref>" first; whichever source serves it also serves
        // the chunks. Source order: (1) our OWN hosted relay's local store (instant, no dial),
        // (2) each relay's plain-HTTP interface — the DEFAULT cross-NAT media transport,
        // (3) the S3 bucket (only present when the user configured one — rare),
        // (4) dialed iroh relays — the opportunistic fast-path (the blob ALPN stalls ~30s and dies
        // when the dial must cross a NAT over pure relay, so it's tried LAST, not first).
        if RelayHost.shared.serving,
           circleIds.contains(where: { relayNodes($0).contains(RelayHost.shared.nodeId) }),
           let s = RelayHost.shared.localGet(key(ref)) {
            head = s; chosen = .ownRelay; src = "own:\(RelayHost.shared.nodeId.prefix(8))"
        }
        // Relays whose HTTP interface answered 404: the iroh path serves the same store — skip dialing.
        var httpMissed = Set<String>()
        if head == nil {
            httpOuter: for cid in circleIds {
                for node in mediaDests(cid) {
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId { continue }
                    guard let http = RelayMailboxStore.shared.httpInterface(node) else { continue }
                    for base in http.urls where !httpUrlBad(base) {
                        switch await httpGet(base, http.token, key(ref)) {
                        case .success(let s):
                            if let s {
                                RelayMailboxStore.shared.markSeen(node)
                                head = s; chosen = .http(base, http.token); src = "http:\(node.prefix(8))"
                                break httpOuter
                            }
                            httpMissed.insert(node)   // reachable, doesn't hold it
                        case .failure:
                            markHttpUrlBad(base)
                            continue
                        }
                        break   // reached the relay (miss) → don't try its other URLs
                    }
                }
            }
        }
        if head == nil, let s3 = circleIds.compactMap({ mediaS3(for: $0) }).first {
            if let s = try? await s3.getObject(key: key(ref)) { head = s; chosen = .s3(s3); src = "s3" }
        }
        if head == nil {
            outer: for cid in circleIds {
                for node in mediaDests(cid) {
                    // Our own hosted relay was already consulted above; never dial ourselves.
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId { continue }
                    if httpMissed.contains(node) { continue }   // same store already said MISS over HTTP
                    guard let c = await RelayClients.client(node) else { continue }
                    if let s = await c.get(key: key(ref)) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); head = s; chosen = .relay(c, node); src = "dial:\(node.prefix(8))"; break outer }
                }
            }
        }
        guard let head, let source = chosen else {
            HavenLog.relay("media restore \(ref.prefix(12)): NOT FOUND on any relay/S3")
            return nil
        }

        // Reassemble the SEALED bytes. If `head` is a manifest, stream each chunk to a temp file on disk
        // (bounded RAM: one 8 MB chunk at a time); otherwise `head` IS the sealed blob (legacy/small).
        let sealed: Data?
        if let chunkCount = parseManifest(head) {
            let temp = MediaStore.shared.makeTempFile()
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                try? FileManager.default.removeItem(at: temp)
                HavenLog.relay("media restore \(ref.prefix(12)): temp-open FAIL"); return nil
            }
            var ok = true
            for i in 0..<chunkCount {
                guard let part = await fetch(source, chunkKey(ref, i)) else { ok = false; break }
                do { try handle.write(contentsOf: part) } catch { ok = false; break }
            }
            try? handle.close()
            guard ok else {
                try? FileManager.default.removeItem(at: temp)
                HavenLog.relay("media restore \(ref.prefix(12)): chunked reassemble FAIL via \(src)"); return nil
            }
            sealed = try? Data(contentsOf: temp)   // read the reassembled sealed blob to open it
            try? FileManager.default.removeItem(at: temp)
        } else {
            sealed = head
        }
        guard let blob = sealed else {
            HavenLog.relay("media restore \(ref.prefix(12)): reassembled read FAIL via \(src)"); return nil
        }
        for cid in circleIds {
            if let data = social.openCircleMedia(circleId: cid, sealed: blob) {
                HavenLog.relay("media restore \(ref.prefix(12)): OK via \(src), \(data.count)B")
                return data
            }
        }
        HavenLog.relay("media restore \(ref.prefix(12)): found via \(src) (\(blob.count)B) but OPEN FAILED for all \(circleIds.count) circles")
        return nil
    }

    // MARK: - Shared mailbox (store-and-forward for ALL events)
    //
    // A sealed event envelope is already encrypted to the whole circle, so we store the
    // envelope itself in the bucket under mailbox/<circle>/<hash>. The sender uploads
    // when they're online; any member polls + downloads when *they're* online — the two
    // never need to overlap. The bucket only ever holds opaque, circle-sealed blobs.

    // Mailbox keys already ingested or confirmed uploaded — PERSISTED. This was in-memory only,
    // so every cold start treated the whole mailbox as new and re-downloaded + re-verified every
    // envelope (observed: ~6700 keys for an 88-event circle → the 30-second cold start on the
    // circle feed, all burned on crypto for duplicates the engine then dropped). Guarded by a lock
    // (poll/upload run on detached tasks); writes are debounced to one file save per burst.
    private static let seenLock = NSLock()
    private static var seenLoaded = false
    private static var seenMailbox = Set<String>()
    private static var seenSavePending = false
    private static var seenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-mailbox-seen.txt")
    }
    private static func withSeen<T>(_ body: (inout Set<String>) -> T) -> T {
        seenLock.lock(); defer { seenLock.unlock() }
        if !seenLoaded {
            seenLoaded = true
            if let text = try? String(contentsOf: seenURL, encoding: .utf8) {
                seenMailbox = Set(text.split(separator: "\n").map(String.init))
            }
        }
        return body(&seenMailbox)
    }
    private static func seenContains(_ key: String) -> Bool { withSeen { $0.contains(key) } }
    /// Record a key as seen and schedule a debounced save (one write per burst, off the caller).
    private static func markSeen(_ key: String) {
        let scheduleSave: Bool = withSeen { set in
            guard set.insert(key).inserted, !seenSavePending else { return false }
            seenSavePending = true
            return true
        }
        guard scheduleSave else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let snapshot: String = withSeen { set in
                seenSavePending = false
                return set.joined(separator: "\n")
            }
            try? snapshot.write(to: seenURL, atomically: true, encoding: .utf8)
        }
    }

    /// Wipe the persisted seen-set — identity reset/adoption must not inherit the old identity's
    /// ingestion cursor (its keys are meaningless to the new engine state).
    static func resetSeenMailbox() {
        withSeen { $0.removeAll() }
        try? FileManager.default.removeItem(at: seenURL)
    }

    /// Force the seen-set to disk NOW (called on background/terminate). The normal save is debounced
    /// 2s and one-shot per burst — an app killed during the initial sync burst (common on iOS) never
    /// wrote it, so the next launch treated the WHOLE mailbox as new and re-downloaded + re-verified
    /// every envelope (the "redownloads old posts on every launch" heat report). A synchronous flush
    /// on the way to the background closes that window.
    static func flushSeenMailbox() {
        let snapshot: String? = withSeen { set in
            guard seenLoaded, !set.isEmpty else { return nil }
            seenSavePending = false
            return set.joined(separator: "\n")
        }
        if let snapshot { try? snapshot.write(to: seenURL, atomically: true, encoding: .utf8) }
    }

    private static func mailboxKey(_ circleId: String, _ env: Data) -> String {
        let h = SHA256.hash(data: env).map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/\(h)"
    }

    /// Drop a sealed event envelope into the circle's mailbox (idempotent). Returns whether it
    /// is now safely in the mailbox (already present or just uploaded) — the background uploader
    /// uses this to know when to stop retrying. We only mark a key "seen" on success, so a
    /// failed upload is retried rather than silently dropped.
    @discardableResult
    static func uploadEvent(circleId: String, env: Data) async -> Bool {
        let key = mailboxKey(circleId, env)
        if seenContains(key) { return true }
        // Relay (common path) → owner's own bucket → member's pre-signed pool → legacy creds.
        let nodes = relayNodes(circleId)
        if !nodes.isEmpty {
            // Mirror to EVERY configured relay (redundancy). Content-addressed key → idempotent;
            // a relay in backoff is skipped. Success on ANY relay means it's safely in a mailbox.
            var landed = false
            for node in nodes {
                // Our OWN hosted relay: store directly into the local mailbox (no iroh self-connection,
                // which blows up iroh's path machinery) so offline members can still pull our posts.
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    _ = RelayHost.shared.localPut(key, env)
                    landed = true; continue
                }
                guard let c = await RelayClients.client(node) else { continue }
                if await c.has(key: key) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true; continue }
                do { try await c.put(key: key, data: env); RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true }
                catch { RelayHealth.shared.recordFailure(node); RelayClients.forget(node) }
            }
            if landed { markSeen(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        if PresignStore.shared.hasPool(circleId) && !isOwner(circleId) {
            // Member: write to one of our pre-signed PUT slots (no credentials).
            guard let put = await PresignStore.shared.nextPutURL(circleId: circleId, myHex: FeedStore.shared.myNodeHex) else {
                FeedStore.shared.markRelay(false); return false
            }
            if await S3Client.putURL(put, data: env) { markSeen(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        guard let s3 = isOwner(circleId) ? ownerS3() : mailboxClient() else { return false }
        if await s3.headObject(key: key) { markSeen(key); FeedStore.shared.markRelay(true); return true }
        do {
            try await s3.putObject(key: key, data: env)
            markSeen(key); FeedStore.shared.markRelay(true); return true
        } catch {
            FeedStore.shared.markRelay(false); return false
        }
    }

    /// Refresh the liveness of every envelope in `envelopes` on every relay serving `circleId`
    /// (relay-side mailbox GC deletes entries no member refreshes for 30 days — legacy duplicate
    /// and stale-epoch envelopes age out; these stay). ONE batched TOUCH per relay, not a
    /// round-trip per key; the relay replies with the keys it lacks and we re-PUT those, so the
    /// daily refresh doubles as repair (it also self-heals a relay that GC'd our history while
    /// we were away). Deliberately ignores the seen-set — "seen" means uploaded ONCE, and the
    /// whole point here is re-asserting entries that already exist.
    static func refreshMailbox(circleId: String, envelopes: [Data]) async {
        guard !envelopes.isEmpty else { return }
        var byKey: [String: Data] = [:]
        for env in envelopes { byKey[mailboxKey(circleId, env)] = env }
        let keys = Array(byKey.keys)
        let prefix = "haven/mailbox/\(circleId)/"
        for node in relayNodes(circleId) where !node.hasPrefix("s3:") {
            // Our OWN hosted relay: touch the local store directly (no iroh self-connection).
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                for k in RelayHost.shared.localTouch(keys) {
                    if let env = byKey[k] { _ = RelayHost.shared.localPut(k, env) }
                }
                continue
            }
            guard let c = await RelayClients.client(node) else { continue }
            do {
                let misses = try await c.touch(prefix: prefix, keys: keys)
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                for k in misses {
                    if let env = byKey[k] { try? await c.put(key: k, data: env) }
                }
            } catch {
                // Unreachable, or a pre-GC relay that doesn't speak TOUCH — either way it
                // isn't sweeping anything, so skipping the refresh is safe.
                HavenLog.relay("touch \(node.prefix(10)) \(circleId): \(error)")
            }
        }
    }

    /// Every mailbox key we've already ingested for a circle (from the persisted seen-set). Used to
    /// keep-alive posts we RECEIVED but didn't author — we can't re-derive a peer's key (only the
    /// author can re-seal), but we hold the keys we fetched, so we can TOUCH them.
    static func seenKeys(circleId: String) -> [String] {
        let prefix = "haven/mailbox/\(circleId)/"
        return withSeen { $0.filter { $0.hasPrefix(prefix) } }
    }

    /// TOUCH keys we HOLD but did not author, to keep them alive against the relay's 30-day GC.
    /// Unlike `refreshMailbox` this never re-PUTs misses (a reader can't reconstruct a peer's sealed
    /// envelope) — a key the relay already swept simply stays gone until its author refreshes it.
    /// This is what makes "any active member keeps a post alive", not just its author.
    static func touchHeldKeys(circleId: String) async {
        let keys = seenKeys(circleId: circleId)
        guard !keys.isEmpty else { return }
        let prefix = "haven/mailbox/\(circleId)/"
        for node in relayNodes(circleId) where !node.hasPrefix("s3:") {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                _ = RelayHost.shared.localTouch(keys)   // own store: bump liveness, ignore misses
                continue
            }
            guard let c = await RelayClients.client(node) else { continue }
            if let _ = try? await c.touch(prefix: prefix, keys: keys) {
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
            }
        }
    }

    /// Poll the mailbox for envelopes we haven't seen. Returns (circleId, envelope) pairs.
    static func pollMailbox(circleIds: [String]) async -> [(String, Data)] {
        var out: [(String, Data)] = []
        for cid in circleIds {
            let prefix = "haven/mailbox/\(cid)/"
            let nodes = relayNodes(cid)
            if !nodes.isEmpty {
                // Read from ALL relays; seenMailbox is keyed by the content-addressed key, so the
                // same envelope mirrored on several relays is ingested exactly once (dedup).
                for node in nodes {
                    // OUR OWN hosted relay: read the local store directly — we can't dial ourselves
                    // (self-dial guard), so this is how the host ingests what a sibling device or a
                    // friend uploaded to it (the previously-missing read-own-relay path).
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                        let localKeys = RelayHost.shared.localList(prefix)
                        let fresh = localKeys.filter { !seenContains($0) }
                        HavenLog.relay("poll OWN relay \(cid): \(localKeys.count) keys, \(fresh.count) new")
                        for key in fresh {
                            // Mark seen only once the bytes are in hand, so a failed read is
                            // retried on the next poll instead of being skipped forever.
                            if let data = RelayHost.shared.localGet(key) { markSeen(key); out.append((cid, data)) }
                        }
                        continue
                    }
                    guard let c = await RelayClients.client(node) else { continue }
                    let keys = await c.list(prefix: prefix)
                    RelayHealth.shared.recordSuccess(node)
                    RelayMailboxStore.shared.markSeen(node)
                    for key in keys where !seenContains(key) {
                        if let data = await c.get(key: key) { markSeen(key); out.append((cid, data)) }
                    }
                }
            } else if PresignStore.shared.hasPool(cid) && !isOwner(cid) {
                // Member: LIST + GET via the pre-signed pool URLs (no credentials).
                if let listURL = await PresignStore.shared.listURL(cid), let xml = await S3Client.getURL(listURL) {
                    for key in S3Client.parseListKeys(xml) where !seenContains(key) {
                        if let g = await PresignStore.shared.getURL(circleId: cid, key: key), let data = await S3Client.getURL(g) {
                            markSeen(key)
                            out.append((cid, data))
                        }
                    }
                }
            } else if let s3 = isOwner(cid) ? ownerS3() : mailboxClient(), let s3keys = try? await s3.listKeys(prefix: prefix) {
                for key in s3keys where !seenContains(key) {
                    if let data = try? await s3.getObject(key: key) { markSeen(key); out.append((cid, data)) }
                }
            }
        }
        return out
    }
}
