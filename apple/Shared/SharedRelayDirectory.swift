import Foundation
import CryptoKit

/// App → NSE hand-off of each circle's relay HTTP interface, mirrored into the App Group.
///
/// The Notification Service Extension can't reach the engine or `RelayMailboxStore`, yet a push
/// routinely arrives BEFORE the content is fetchable by the app (banner-first gap). The app
/// mirrors `{base URLs, token}` per circle whenever its relay bookkeeping changes; the NSE reads
/// the mirror to GET the pushed envelope (`mk`) and small media (`mr`) while it still has its
/// execution window — so the app opens onto content that is already on the device.
///
/// Privacy: the token is the relay's HTTP token exactly as every member device already holds it,
/// and requests are still per-request signed (`httpAuthHeader`, one-shot nonce) — the mirror
/// grants nothing the app process didn't have. Everything fetched stays sealed until the app's
/// engine opens it.
enum SharedRelayDirectory {
    struct RelayInterface: Codable, Equatable {
        /// Base URLs to try, in order.
        let u: [String]
        /// The relay's HTTP token (request-signing input, not a bearer secret on its own).
        let t: String
    }
    private struct Directory: Codable {
        /// circleId → that circle's relay interfaces.
        var circles: [String: [RelayInterface]]
        /// The all-circles default relay (applies to ANY circle id, mirrored once).
        var any: [RelayInterface]
    }

    private static let dirKey = "haven.relay.directory.v1"
    private static let fetchedKey = "haven.push.fetched.v1"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedNotificationPrivacy.appGroup) }

    /// App side: mirror the per-circle interfaces (+ the all-circles default). Skips the write when
    /// byte-identical to what's stored — this rides relay bookkeeping that runs often.
    static func write(circles: [String: [RelayInterface]], any: [RelayInterface]) {
        guard let d = defaults,
              let data = try? JSONEncoder().encode(Directory(circles: circles, any: any)) else { return }
        if d.data(forKey: dirKey) == data { return }
        d.set(data, forKey: dirKey)
    }

    /// NSE side: every interface worth trying for a circle — its own relays first, then the
    /// all-circles default (deduped).
    static func interfaces(for circleId: String) -> [RelayInterface] {
        guard let d = defaults, let data = d.data(forKey: dirKey),
              let dir = try? JSONDecoder().decode(Directory.self, from: data) else { return [] }
        var out = dir.circles[circleId] ?? []
        for i in dir.any where !out.contains(i) { out.append(i) }
        return out
    }

    // MARK: recently-fetched keys — NSE dedupe, so a burst of pushes for one envelope fetches once.

    static func recentlyFetched(_ key: String) -> Bool {
        guard let d = defaults else { return false }
        return ((d.array(forKey: fetchedKey) as? [String]) ?? []).contains(key)
    }

    static func markFetched(_ key: String) {
        guard let d = defaults else { return }
        var list = (d.array(forKey: fetchedKey) as? [String]) ?? []
        guard !list.contains(key) else { return }
        list.append(key)
        if list.count > 200 { list.removeFirst(list.count - 200) }   // small, insertion-ordered
        d.set(list, forKey: fetchedKey)
    }
}

/// Writer half of the `haven.push.hints.v1` App-Group drop. The NSE (and the macOS silent-push
/// handler) APPENDS one hint per push — which circle, the exact mailbox key, media refs, and the
/// post id; the app's foreground fast-path (`SharedPushHints.drain` in SharedStore) reads and
/// CLEARS the array, turning each hint into a targeted GET + media prefetch. The reader clears,
/// writers only ever append — so a hint survives the NSE being killed mid-fetch.
enum SharedPushHintWriter {
    static let key = "haven.push.hints.v1"

    static func append(c: String, mk: String?, mr: [String]?, p: String?) {
        guard !c.isEmpty, let d = UserDefaults(suiteName: SharedNotificationPrivacy.appGroup) else { return }
        var arr: [[String: Any]] = []
        if let data = d.data(forKey: key),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            arr = existing
        }
        var o: [String: Any] = ["c": c]
        if let mk, !mk.isEmpty { o["mk"] = mk }
        if let mr, !mr.isEmpty { o["mr"] = mr }
        if let p, !p.isEmpty { o["p"] = p }
        arr.append(o)
        if arr.count > 64 { arr.removeFirst(arr.count - 64) }   // bounded, like SharedInbox
        if let data = try? JSONSerialization.data(withJSONObject: arr) { d.set(data, forKey: key) }
    }
}

/// Sealed media blobs the push pipeline prefetched, parked in the App Group container for the app
/// to open + adopt on next launch/foreground (`FeedStore.adoptPushMediaScratch`). Files stay
/// SEALED at rest — only the app's engine can open them for their circle.
enum SharedPushMediaScratch {
    struct Item {
        let ref: String
        let circleId: String
        let sealed: Data
    }

    private static var dir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedNotificationPrivacy.appGroup)?
            .appendingPathComponent("Library/Caches/haven-push-media", isDirectory: true)
    }

    /// NSE side: park one sealed blob (+ a sidecar naming its ref and circle).
    static func save(ref: String, circleId: String, sealed: Data) {
        guard let dir, !ref.isEmpty, !sealed.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Hash the ref for the file name — refs are caller-controlled, file names must not be.
        let name = SHA256.hash(data: Data(ref.utf8)).map { String(format: "%02x", $0) }.joined()
        guard (try? sealed.write(to: dir.appendingPathComponent(name + ".sealed"), options: .atomic)) != nil,
              let meta = try? JSONSerialization.data(withJSONObject: ["ref": ref, "c": circleId]) else { return }
        try? meta.write(to: dir.appendingPathComponent(name + ".meta"), options: .atomic)
    }

    /// App side: take everything (files removed — one adoption attempt each; the normal media
    /// fetch lanes remain the reliable backstop).
    static func drain() -> [Item] {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              !names.isEmpty else { return [] }
        var out: [Item] = []
        for name in names where name.hasSuffix(".meta") {
            let metaURL = dir.appendingPathComponent(name)
            let blobURL = dir.appendingPathComponent(String(name.dropLast(".meta".count)) + ".sealed")
            defer {
                try? FileManager.default.removeItem(at: metaURL)
                try? FileManager.default.removeItem(at: blobURL)
            }
            guard let m = try? Data(contentsOf: metaURL),
                  let obj = (try? JSONSerialization.jsonObject(with: m)) as? [String: String],
                  let ref = obj["ref"], let cid = obj["c"], !ref.isEmpty,
                  let sealed = try? Data(contentsOf: blobURL), !sealed.isEmpty else { continue }
            out.append(Item(ref: ref, circleId: cid, sealed: sealed))
        }
        // Sweep orphans (blob without meta / interrupted writes) so the scratch can't grow.
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in rest { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
        return out
    }
}

/// The NSE-side fetch of what a push named: the exact mailbox key (`mk`) into `SharedInbox` —
/// the SAME downstream path an inline `ev` takes — and small media (`mr`) into the scratch dir.
/// Everything is best-effort inside the NSE's budget; the app's mailbox poll stays the backstop.
enum SharedPushPrefetch {
    /// Hard total cap on prefetched media per push (sealed bytes). Thumbs/posters by contract.
    static let mediaBudget = 4 * 1024 * 1024

    static func run(circleId: String, mailboxKey: String?, mediaRefs: [String], skipEnvelope: Bool) async {
        let ifaces = SharedRelayDirectory.interfaces(for: circleId)
        guard !ifaces.isEmpty, let seed = SharedSeed.read() else { return }
        if !skipEnvelope, let mk = mailboxKey,
           mk.hasPrefix("haven/mailbox/\(circleId)/"),          // hint sanity — never a free fetch
           !SharedRelayDirectory.recentlyFetched(mk) {
            if let env = await get(ifaces, seed: seed, key: mk), !env.isEmpty {
                SharedInbox.append(env: env)                    // app ingests on next open
                SharedRelayDirectory.markFetched(mk)
            }
        }
        var budget = mediaBudget
        for ref in mediaRefs.prefix(4) where budget > 0 {
            guard !ref.isEmpty, !SharedRelayDirectory.recentlyFetched("media:" + ref) else { continue }
            guard let blob = await get(ifaces, seed: seed, key: "haven/media/\(ref)"),
                  !blob.isEmpty, blob.count <= budget,
                  !blob.starts(with: Data("HVCHUNK1".utf8))     // chunked manifest → app-side fetch
            else { continue }
            SharedPushMediaScratch.save(ref: ref, circleId: circleId, sealed: blob)
            SharedRelayDirectory.markFetched("media:" + ref)
            budget -= blob.count
        }
    }

    /// GET one key across the mirrored interfaces. Signs PER attempt — the auth header carries a
    /// one-shot nonce (a reused header is a replay and the relay refuses it). Short timeout: the
    /// whole prefetch lives inside the NSE's ~10s slice of its budget.
    private static func get(_ ifaces: [SharedRelayDirectory.RelayInterface],
                            seed: Data, key: String) async -> Data? {
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        for iface in ifaces {
            for base in iface.u {
                let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                guard let url = URL(string: "\(trimmed)/k/\(enc)"),
                      let auth = try? httpAuthHeader(seed: seed, token: iface.t, method: "GET",
                                                     key: key, body: Data()) else { continue }
                var req = URLRequest(url: url, timeoutInterval: 8)
                req.setValue(auth, forHTTPHeaderField: "Authorization")
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                      !data.isEmpty else { continue }
                return data
            }
        }
        return nil
    }
}
