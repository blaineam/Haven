import Foundation
@testable import HavenUITestHost

/// An in-process relay + S3 bucket behind `HavenHTTP`'s test transport. The app's real HTTP lanes
/// (signed relay PUT/GET/HEAD/LIST, SigV4 bucket PUT/GET/HEAD/LIST) run against it with no network:
/// `install()` points the session at this handler and opens ONLY the HTTP lane
/// (`HavenNet.testHTTPLane`) — iroh, Multipeer, push and tunnels stay refused.
final class FakeWire: @unchecked Sendable {
    static let shared = FakeWire()
    static let relayHost = "relay.fake.test"
    static let relayBase = "https://relay.fake.test"
    static let s3Host = "s3.fake.test"
    static let bucket = "fakebucket"

    struct Request { let method: String; let host: String; let path: String; let authorized: Bool }

    private let lock = NSLock()
    private var relay: [String: Data] = [:]
    private var bucketKV: [String: Data] = [:]
    private var log: [Request] = []
    private var _refuse = false
    private var _unreachable = false

    /// Answer every relay request 403 (the relay is up but does not know this device).
    var refuse: Bool { get { lock.withLock { _refuse } } set { lock.withLock { _refuse = newValue } } }
    /// Fail every connection (the relay is down).
    var unreachable: Bool { get { lock.withLock { _unreachable } } set { lock.withLock { _unreachable = newValue } } }

    func install() {
        reset()
        HavenHTTP.testHandler = { req, body in FakeWire.shared.handle(req, body) }
        HavenNet.testHTTPLane = true
    }
    func uninstall() {
        HavenNet.testHTTPLane = false
        HavenHTTP.testHandler = nil
        reset()
    }
    func reset() {
        lock.withLock { relay = [:]; bucketKV = [:]; log = []; _refuse = false; _unreachable = false }
    }

    // MARK: Inspecting and seeding the stores

    func relayKeys(prefix: String = "") -> [String] { lock.withLock { relay.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
    func relayData(_ key: String) -> Data? { lock.withLock { relay[key] } }
    func putRelay(_ key: String, _ data: Data) { lock.withLock { relay[key] = data } }
    func bucketKeys(prefix: String = "") -> [String] { lock.withLock { bucketKV.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
    func bucketData(_ key: String) -> Data? { lock.withLock { bucketKV[key] } }
    func putBucket(_ key: String, _ data: Data) { lock.withLock { bucketKV[key] = data } }
    func requests(method: String? = nil, host: String? = nil) -> [Request] {
        lock.withLock { log.filter { (method == nil || $0.method == method) && (host == nil || $0.host == host) } }
    }

    // MARK: The wire

    typealias Answer = (status: Int, headers: [String: String], body: Data)
    private func ans(_ status: Int, _ body: Data = Data()) -> Answer { (status: status, headers: [:], body: body) }

    private func handle(_ req: URLRequest, _ body: Data?) -> Answer? {
        guard let url = req.url, let host = url.host else { return nil }
        let method = req.httpMethod ?? "GET"
        let path = url.path(percentEncoded: false)
        return lock.withLock {
            log.append(Request(method: method, host: host, path: path,
                               authorized: req.value(forHTTPHeaderField: "Authorization")?.isEmpty == false))
            switch host {
            case Self.relayHost:
                if _unreachable { return nil }
                if _refuse { return ans(403) }
                if path.hasPrefix("/k/") {
                    let key = String(path.dropFirst(3))
                    switch method {
                    case "PUT": relay[key] = body ?? Data(); return ans(200)
                    case "GET": if let d = relay[key] { return ans(200, d) }; return ans(404)
                    case "HEAD": return ans(relay[key] != nil ? 200 : 404)
                    default: return ans(405)
                    }
                }
                if path.hasPrefix("/l/") {
                    let prefix = String(path.dropFirst(3))
                    let keys = relay.keys.filter { $0.hasPrefix(prefix) }.sorted()
                    return ans(200, Data(keys.joined(separator: "\n").utf8))
                }
                return ans(404)
            case Self.s3Host:
                let root = "/\(Self.bucket)"
                if path == root || path == root + "/" {
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let prefix = items.first { $0.name == "prefix" }?.value ?? ""
                    let keys = bucketKV.keys.filter { $0.hasPrefix(prefix) }.sorted()
                    let xml = "<ListBucketResult>" + keys.map { "<Contents><Key>\($0.replacingOccurrences(of: "&", with: "&amp;"))</Key></Contents>" }.joined() + "</ListBucketResult>"
                    return ans(200, Data(xml.utf8))
                }
                if path.hasPrefix(root + "/") {
                    let key = String(path.dropFirst(root.count + 1))
                    switch method {
                    case "PUT": bucketKV[key] = body ?? Data(); return ans(200)
                    case "GET": if let d = bucketKV[key] { return ans(200, d) }; return ans(404)
                    case "HEAD": return ans(bucketKV[key] != nil ? 200 : 404)
                    default: return ans(405)
                    }
                }
                return ans(404)
            default:
                return ans(503)   // nothing else is reachable
            }
        }
    }
}
