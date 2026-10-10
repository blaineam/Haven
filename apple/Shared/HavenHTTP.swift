import Foundation

/// The one URLSession for relay, S3, push and DoH traffic — with NO URL cache.
///
/// `URLSession.shared` stores every eligible response in CFNetwork's on-disk SQLite cache
/// (`Library/Caches/<bundle>/Cache.db`). Nothing we fetch is ever served from it: relay requests
/// carry a one-shot nonce in their auth header, bodies are sealed blobs fetched once and held by
/// the app itself, and LIST polls are already deltas. So each poll was a pure cache insert + WAL
/// commit + LRU eviction — the 280 MB `NSURLStorageURLCacheDB` disk-write diagnostic on 2.0.0
/// (633). Foundation only; shared by the app, the Mac app and the notification extension.
enum HavenHTTP {
    static let session = URLSession(configuration: makeConfiguration())

    /// A fresh copy of `session`'s configuration (tests attach a stub protocol to it).
    static func makeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return c
    }

    /// Keeps `URLCache.shared` (what AsyncImage and any other framework default-session caller
    /// use) in memory only, so nothing can rebuild the on-disk Cache.db behind our back. Call
    /// once, early at launch, before the first request.
    static func disableSharedDiskCache() {
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
    }
}
