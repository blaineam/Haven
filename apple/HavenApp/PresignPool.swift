import Foundation

/// The pre-signed URL pool behind the S3 "advanced" mailbox (`PresignStore`), without the Keychain,
/// the feed or notifications: how the owner mints a pool, when a cached pool is still fresh, and how a
/// member takes its next single-use PUT slot. The bucket owner mints scoped, expiring, single-object
/// URLs and hands THOSE to the circle, so members never see the access key.
struct PresignPool: Codable, Equatable {
    let circleId: String
    let expires: Double            // unix seconds
    var puts: [String: [String]]   // memberHex → [pre-signed PUT url]
    let gets: [String: String]     // key → pre-signed GET url
    let listURL: String            // pre-signed LIST url for the mailbox prefix

    static let slotsPerMember = 60
    static let ttl: TimeInterval = 604_800   // 7 days (SigV4 max)
    /// A cached pool is refetched this long before it lapses, so a request never races its expiry.
    static let freshnessMargin: TimeInterval = 60
    /// The owner's local fallback reminder fires this long before the TTL ends.
    static let reminderLead: TimeInterval = 86_400

    static func mailboxKey(circleId: String, memberHex: String, slot: Int) -> String {
        "haven/mailbox/\(circleId)/\(memberHex)/\(slot)"
    }
    static func mailboxPrefix(circleId: String) -> String { "haven/mailbox/\(circleId)/" }
    static func poolKey(circleId: String) -> String { "haven/presign/\(circleId)/pool" }

    /// Mint a pool: `slotsPerMember` PUT URLs and as many GET URLs per member, plus one LIST URL for
    /// the circle's mailbox prefix. A URL the signer could not build is skipped, not replaced by "".
    static func mint(circleId: String, members: [String], s3: S3Client, now: Date = Date(),
                     slots: Int = slotsPerMember) -> PresignPool {
        var puts: [String: [String]] = [:]
        var gets: [String: String] = [:]
        for m in members {
            var urls: [String] = []
            for n in 0..<slots {
                let key = mailboxKey(circleId: circleId, memberHex: m, slot: n)
                if let put = s3.presignedURL(method: "PUT", key: key, now: now) { urls.append(put.absoluteString) }
                if let get = s3.presignedURL(method: "GET", key: key, now: now) { gets[key] = get.absoluteString }
            }
            puts[m] = urls
        }
        let listURL = s3.presignedURL(method: "GET", key: "", listPrefix: mailboxPrefix(circleId: circleId), now: now)?.absoluteString ?? ""
        return PresignPool(circleId: circleId, expires: now.timeIntervalSince1970 + ttl,
                           puts: puts, gets: gets, listURL: listURL)
    }

    func isFresh(now: Date = Date()) -> Bool { expires > now.timeIntervalSince1970 + Self.freshnessMargin }

    /// The PUT URL at index `used` in my own namespace (first-come-first-use), or nil when I have no
    /// slots or they are exhausted until the owner re-mints.
    func putURL(forMember hex: String, used: Int) -> URL? {
        guard let mine = puts[hex], !mine.isEmpty, used >= 0, used < mine.count else { return nil }
        return URL(string: mine[used])
    }

    /// When the owner's local reminder should fire (unix seconds).
    var reminderAt: TimeInterval { expires - Self.reminderLead }
}
