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
        let destNodes = relayNodes(circleId).filter { !$0.hasPrefix("s3:") }
        let s3Configured = mediaS3(for: circleId) != nil
        let allConfirmed = destNodes.allSatisfy { MediaBackupLedger.has($0, ref) }
            && (!s3Configured || MediaBackupLedger.has("s3", ref))
        if allConfirmed && (!destNodes.isEmpty || s3Configured) { return }
        // Read the file + seal (encrypt MBs) OFF the main thread — doing it on the main actor janked the UI
        // (the serial backup queue runs these back-to-back). The engine + file read are thread-safe.
        guard let url = MediaStore.shared.storagePath(for: ref) else { return }
        let sealed: Data? = await Task.detached(priority: .utility) { () -> Data? in
            guard let raw = try? Data(contentsOf: url) else { return nil }
            return try? social.sealCircleMedia(circleId: circleId, data: raw)
        }.value
        guard let sealed else { HavenLog.sync("backup SEAL-FAIL ref=\(ref)"); return }
        let nodes = relayNodes(circleId)
        let chunked = sealed.count > mediaChunkBytes
        HavenLog.sync("backup ref=\(ref) size=\(sealed.count) chunked=\(chunked) relays=\(nodes.count) s3=\(mediaS3(for: circleId) != nil)")
        var landed = false
        // 1) S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT,
        //    whereas the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a
        //    pure-relay cross-NAT path (noq/iroh fork bug), so blob transfers that must cross a NAT
        //    stall and die while messaging on the same relay path works. The bucket leg used to be
        //    gated on "no relays configured" — now it always runs when a bucket is configured.
        if let s3 = mediaS3(for: circleId), !MediaBackupLedger.has("s3", ref) {
            if await s3.headObject(key: key(ref)) { MediaBackupLedger.mark("s3", ref); landed = true }
            else {
                do {
                    try await putMedia(ref: ref, sealed: sealed) { try await s3.putObject(key: $0, data: $1) }
                    HavenLog.sync("backup s3-put OK ref=\(ref) size=\(sealed.count) chunked=\(chunked)")
                    MediaBackupLedger.mark("s3", ref); landed = true
                }
                catch { HavenLog.sync("backup s3-put FAIL ref=\(ref): \(error.localizedDescription)") }
            }
        } else if mediaS3(for: circleId) != nil { landed = true }
        // 2) Mirror to every relay (redundancy + the LAN/hosted fast-path). Content-addressed
        //    key → idempotent re-puts; a relay in backoff is skipped (RelayClients is health-aware).
        //    "s3:" pseudo-entries are the bucket handled above — dialing them can only fail.
        //    Per relay: its plain-HTTP interface is tried FIRST (the reliable cross-NAT path); the
        //    iroh blob dial is the fallback/fast-path when no HTTP interface is known/reachable.
        for node in nodes where !node.hasPrefix("s3:") {
            if MediaBackupLedger.has(node, ref) { landed = true; continue }   // already confirmed on this relay
            // Our OWN hosted relay: store the media directly in the local mailbox (no iroh self-dial).
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                try? await putMedia(ref: ref, sealed: sealed) { _ = RelayHost.shared.localPut($0, $1) }
                MediaBackupLedger.mark(node, ref); landed = true
                continue
            }
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                var put = false
                for base in http.urls where !httpUrlBad(base) {
                    if case .success(let existing) = await httpGet(base, http.token, key(ref)), existing != nil {
                        put = true; break   // already mirrored (content-addressed, idempotent)
                    }
                    do {
                        try await putMedia(ref: ref, sealed: sealed) { k, d in
                            guard await httpPut(base, http.token, k, d) else { throw URLError(.cannotConnectToHost) }
                        }
                        put = true
                    } catch { markHttpUrlBad(base) }
                    if put { break }
                }
                if put {
                    RelayMailboxStore.shared.markSeen(node)
                    HavenLog.sync("backup http-put OK ref=\(ref) relay=\(node.prefix(8))")
                    MediaBackupLedger.mark(node, ref); landed = true
                    continue   // the iroh path serves the SAME store — done with this relay
                }
            }
            guard let c = await RelayClients.client(node) else { continue }
            if await c.has(key: key(ref)) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); MediaBackupLedger.mark(node, ref); landed = true; continue }
            do {
                try await putMedia(ref: ref, sealed: sealed) { try await c.put(key: $0, data: $1) }
                RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                MediaBackupLedger.mark(node, ref); landed = true
            }
            catch { RelayHealth.shared.recordFailure(node); RelayClients.forget(node) }
        }
        if !landed { HavenLog.sync("backup NO-DEST ref=\(ref)") }
    }

    /// The bucket used for MEDIA in this circle: the owner's own creds for a circle whose pre-signed
    /// pool we mint, else the shared/volunteer mailbox bucket. Same selection as `uploadEvent`.
    private static func mediaS3(for circleId: String) -> S3Client? {
        isOwner(circleId) ? ownerS3() : mailboxClient()
    }

    /// PUT one sealed media blob through a destination's key/value writer — sliced into 8 MB chunks
    /// plus a manifest when large, a single blob otherwise (the shared wire format).
    private static func putMedia(ref: String, sealed: Data, put: (String, Data) async throws -> Void) async throws {
        if sealed.count > mediaChunkBytes {
            var sizes: [Int] = []
            var off = 0
            while off < sealed.count {
                let end = min(off + mediaChunkBytes, sealed.count)
                let slice = sealed.subdata(in: off..<end)
                try await put(chunkKey(ref, sizes.count), slice)
                sizes.append(slice.count); off = end
            }
            try await put(key(ref), makeManifest(sizes: sizes))
        } else {
            try await put(key(ref), sealed)
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
                for node in relayNodes(cid) {
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
                for node in relayNodes(cid) where !node.hasPrefix("s3:") {
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
