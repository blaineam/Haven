import Foundation
import UserNotifications

/// The S3 "advanced" mailbox that **never shares the bucket credentials**. The bucket owner
/// mints a pool of scoped, expiring **pre-signed URLs** (one per upload slot, plus GETs + a
/// LIST), seals the pool to the circle, parks it in the bucket, and broadcasts a single
/// bootstrap GET URL over the circle's sealed channel. Members fetch the pool and use its URLs
/// for mailbox ops — they only ever hold single-object, time-limited URLs, never the secret.
///
/// Freshness: the owner re-mints on every app launch + whenever the worker's twice-daily silent
/// push wakes them; a local fallback notification fires ~1 day before the 7-day TTL if pushes
/// were dropped. (Events only for now — media stays on the relay / direct P2P.)
@MainActor
final class PresignStore: ObservableObject {
    static let shared = PresignStore()
    private let d = UserDefaults.standard
    static let ttl = PresignPool.ttl

    typealias Pool = PresignPool

    private var pools: [String: Pool] = [:]   // in-memory cache, per circle
    private func bootKey(_ c: String) -> String { "haven.presign.boot.\(c)" }
    private func usedKey(_ c: String) -> String { "haven.presign.used.\(c)" }
    private let ownedKey = "haven.presign.owned"

    /// Circle ids this device owns the bucket for (so we re-mint them).
    var ownedCircles: [String] {
        get { (d.array(forKey: ownedKey) as? [String]) ?? [] }
        set { d.set(Array(Set(newValue)), forKey: ownedKey) }
    }

    /// Does a circle have a pre-signed pool available to *this* device (a member's path)?
    func hasPool(_ circleId: String) -> Bool { d.string(forKey: bootKey(circleId)) != nil }

    // MARK: Member side

    /// Store the bootstrap GET URL for a circle's pool (received over the sealed channel).
    func setBootstrap(circleId: String, getURL: String) {
        d.set(getURL, forKey: bootKey(circleId))
        pools[circleId] = nil   // force a refetch
    }

    /// The current pool (cached, else fetched + unsealed via the bootstrap URL).
    func pool(_ circleId: String) async -> Pool? {
        if let p = pools[circleId], p.isFresh() { return p }
        guard let boot = d.string(forKey: bootKey(circleId)), let url = URL(string: boot),
              let sealed = await S3Client.getURL(url),
              let data = await FeedStore.shared.openCirclePresign(circleId: circleId, sealed: sealed),
              let p = try? JSONDecoder().decode(Pool.self, from: data) else { return nil }
        pools[circleId] = p
        return p
    }

    /// Next unused PUT URL for *my* slot pool (first-come-first-use within my own namespace).
    func nextPutURL(circleId: String, myHex: String) async -> URL? {
        guard let p = await pool(circleId) else { return nil }
        let used = d.integer(forKey: usedKey(circleId))
        guard let url = p.putURL(forMember: myHex, used: used) else { return nil }   // exhausted until the owner re-mints
        d.set(used + 1, forKey: usedKey(circleId))
        return url
    }

    func listURL(_ circleId: String) async -> URL? {
        guard let p = await pool(circleId) else { return nil }
        return URL(string: p.listURL)
    }
    func getURL(circleId: String, key: String) async -> URL? {
        guard let p = await pool(circleId), let s = p.gets[key] else { return nil }
        return URL(string: s)
    }

    // MARK: Owner side

    /// Mint a fresh pool for a circle, seal + park it in the bucket, and broadcast the bootstrap.
    func mintAndPublish(circleId: String, members: [String], s3: S3Client) async {
        let pool = PresignPool.mint(circleId: circleId, members: members, s3: s3)
        guard let data = try? JSONEncoder().encode(pool),
              let sealed = await FeedStore.shared.sealCirclePresign(circleId: circleId, data: data) else { return }
        let poolKey = PresignPool.poolKey(circleId: circleId)
        try? await s3.putObject(key: poolKey, data: sealed)
        guard let boot = s3.presignedURL(method: "GET", key: poolKey) else { return }
        setBootstrap(circleId: circleId, getURL: boot.absoluteString)         // owner uses it too
        FeedStore.shared.broadcastPresignBootstrap(circleId: circleId, getURL: boot.absoluteString)
        scheduleReminder(at: pool.reminderAt)
    }

    /// Re-mint every circle this device owns the bucket for (on launch + on the silent push).
    func remintAllOwned() {
        guard let s3 = SharedStore.ownerS3() else { return }
        for cid in ownedCircles {
            let members = FeedStore.shared.memberHexes(circleId: cid)
            Task { await mintAndPublish(circleId: cid, members: members, s3: s3) }
        }
    }

    /// Local fallback reminder (works with NO push) so the owner refreshes before the TTL lapses.
    private func scheduleReminder(at when: TimeInterval) {
        let interval = when - Date().timeIntervalSince1970
        guard interval > 60 else { return }
        let c = UNMutableNotificationContent()
        c.title = "Keep your circle's storage fresh"
        c.body = "Open Haven so your circle's shared storage keeps working."
        let req = UNNotificationRequest(identifier: "presign-remind",
                                        content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}
