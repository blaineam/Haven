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
        #if DEBUG
        c.protocolClasses = [TestTransport.self] + (c.protocolClasses ?? [])
        #endif
        return c
    }

    #if DEBUG
    /// Hosted unit tests (`HavenMacUnitTests`): answers every request this session makes from an
    /// in-process handler, so the relay and S3 HTTP lanes run for real with no network. Inert (the
    /// protocol declines every request) unless a test installs `testHandler`.
    nonisolated(unsafe) static var testHandler: (@Sendable (URLRequest, Data?) -> (status: Int, headers: [String: String], body: Data)?)?

    final class TestTransport: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { HavenHTTP.testHandler != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
                body = data
            }
            guard let handler = HavenHTTP.testHandler, let url = request.url,
                  let answer = handler(request, body) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let resp = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: answer.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    #endif

    /// Keeps `URLCache.shared` (what AsyncImage and any other framework default-session caller
    /// use) in memory only, so nothing can rebuild the on-disk Cache.db behind our back. Call
    /// once, early at launch, before the first request.
    static func disableSharedDiskCache() {
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
    }
}
