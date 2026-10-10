import XCTest

/// ASC disk-write diagnostic (2.0.0 (633), iOS 27.0.1): 280 MB of a 1.1 GB write budget was
/// CFNetwork committing to its SQLite URL cache (`__CFURLCache::CreateAndStoreCacheNode` →
/// `NSURLStorageURLCacheDB execSQLStatement` → WAL frames). Every relay LIST/GET/HEAD/PUT and S3
/// call went through `URLSession.shared`, whose default `URLCache` stores each response on disk —
/// and those responses are one-shot (nonce-signed auth, sealed bodies, digest-gated LIST polls) so
/// nothing ever reads them back. The cache is pure write amplification. The same path also carried
/// a separate 70 MB `__CFURLCache::CreateAndStoreCacheNode` diagnostic (disk-write:933d08eb).
final class HavenHTTPTests: XCTestCase {

    func testSessionHasNoURLCache() {
        let cfg = HavenHTTP.session.configuration
        XCTAssertNil(cfg.urlCache, "relay/S3 responses must never reach CFNetwork's on-disk cache")
        XCTAssertEqual(cfg.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSessionKeepsNoCookies() {
        // Ephemeral-equivalent: our requests are header-authenticated, a cookie jar is just more I/O.
        let cfg = HavenHTTP.session.configuration
        XCTAssertNil(cfg.httpCookieStorage)
        XCTAssertFalse(cfg.httpShouldSetCookies)
    }

    func testSharedCacheIsMemoryOnlyAfterLaunchHook() {
        let saved = URLCache.shared
        defer { URLCache.shared = saved }
        HavenHTTP.disableSharedDiskCache()
        XCTAssertEqual(URLCache.shared.diskCapacity, 0,
                       "framework callers of URLCache.shared (AsyncImage, …) must not write Cache.db")
        XCTAssertGreaterThan(URLCache.shared.memoryCapacity, 0)
    }

    /// Answers every request with a cacheable 200 and lets the session's cache policy decide.
    final class CacheableStub: URLProtocol {
        static let body = Data(repeating: 0xAB, count: 64 * 1024)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Cache-Control": "public, max-age=31536000",
                                                      "Content-Type": "application/octet-stream",
                                                      "Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// GETs one sealed-blob-shaped URL through `cfg` + the stub, then gives the asynchronous
    /// cache store ~1 s to land before reporting what the config's cache holds for it.
    private func storedResponse(_ cfg: URLSessionConfiguration) async throws -> CachedURLResponse? {
        cfg.protocolClasses = [CacheableStub.self] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let req = URLRequest(url: URL(string: "https://relay.invalid/k/blob-\(UUID().uuidString)")!)
        let (data, _) = try await session.data(for: req)
        XCTAssertEqual(data.count, CacheableStub.body.count)

        var cached: CachedURLResponse?
        for _ in 0..<20 {
            cached = cfg.urlCache?.cachedResponse(for: req)
            if cached != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return cached
    }

    func testSealedBlobResponsesAreNeverStoredInAURLCache() async throws {
        let cached = try await storedResponse(HavenHTTP.makeConfiguration())
        XCTAssertNil(cached, "a sealed-blob GET was written into the URL cache")
    }

    /// Control: the stub really does produce a storable response — a cache-bearing config keeps it.
    /// Without this the test above would pass vacuously for a nil `urlCache`.
    func testControlCachingConfigDoesStoreTheStubResponse() async throws {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
        let cached = try await storedResponse(cfg)
        XCTAssertNotNil(cached, "control: the stub's cacheable 200 should land in a real cache")
    }

    /// The regression guard: a new `URLSession.shared` call site silently puts the disk cache back.
    func testNoAppSourceUsesTheCachingSharedSession() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["HavenApp", "Shared", "HavenNotificationService", "HavenShareExtension",
                     "HavenBroadcast", "HavenWatch", "WatchShared"]
        var offenders: [String] = []
        for root in roots {
            let dir = apple.appendingPathComponent(root)
            guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains("URLSession.shared") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    offenders.append("\(root)/\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use HavenHTTP.session — URLSession.shared caches every response on disk")
    }
}
