import Foundation
import CryptoKit

/// A tiny, dependency-free S3 client (AWS SigV4, path-style) for the circle's shared
/// store + mailbox. It only ever moves **sealed** bytes: everything uploaded is already
/// end-to-end encrypted to the circle, so the bucket host (even another member
/// "volunteering as tribute") stores opaque blobs it cannot read. Keys live only in the
/// device Keychain (see StorageStore) — never on any Haven server.
///
/// Works with AWS S3, Cloudflare R2, Backblaze B2, rclone serve s3, etc.
/// A portable S3 connection config — your own bucket, or a circle's shared relay bucket.
struct S3Config: Codable, Equatable {
    var endpoint: String
    var region: String
    var bucket: String
    var accessKey: String
    var secret: String
    var isComplete: Bool { !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty && !secret.isEmpty }
}

struct S3Client {
    let endpoint: String
    let region: String
    let bucket: String
    let accessKey: String
    let secret: String

    init(config c: S3Config) {
        endpoint = c.endpoint.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        region = c.region.isEmpty ? "us-east-1" : c.region
        bucket = c.bucket
        accessKey = c.accessKey
        secret = c.secret
    }

    @MainActor
    init?(_ s: StorageStore) {
        guard s.s3Configured else { return nil }
        self.init(config: S3Config(endpoint: s.s3Endpoint, region: s.s3Region, bucket: s.s3Bucket,
                                   accessKey: s.s3AccessKey, secret: s.s3Secret))
    }

    // MARK: - Public API

    func putObject(key: String, data: Data) async throws {
        var req = try signedRequest(method: "PUT", path: "/\(bucket)/\(encodePath(key))", query: [], payload: data)
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        try check(resp, "PUT \(key)")
    }

    func getObject(key: String) async throws -> Data {
        let req = try signedRequest(method: "GET", path: "/\(bucket)/\(encodePath(key))", query: [], payload: Data())
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, "GET \(key)")
        return data
    }

    func headObject(key: String) async -> Bool {
        await headObjectExists(key: key) == true
    }

    /// Tri-state HEAD: true = the key exists, false = the bucket ANSWERED but doesn't hold it,
    /// nil = no HTTP response at all (offline/unreachable). The distinction lets callers skip
    /// expensive work (e.g. sealing a multi-hundred-MB media file) when the bucket can't be
    /// reached anyway — a plain false would force the upload attempt.
    func headObjectExists(key: String) async -> Bool? {
        guard let req = try? signedRequest(method: "HEAD", path: "/\(bucket)/\(encodePath(key))", query: [], payload: Data()) else { return nil }
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        return (200..<300).contains(http.statusCode)
    }

    /// List object keys under a prefix (ListObjectsV2). Used to poll the mailbox.
    func listKeys(prefix: String) async throws -> [String] {
        let query = [("list-type", "2"), ("prefix", prefix), ("max-keys", "1000")]
        let req = try signedRequest(method: "GET", path: "/\(bucket)", query: query, payload: Data())
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, "LIST \(prefix)")
        return Self.parseKeys(data)
    }

    private func check(_ resp: URLResponse, _ what: String) throws {
        guard let http = resp as? HTTPURLResponse else { throw S3Error.bad("no response: \(what)") }
        guard (200..<300).contains(http.statusCode) else { throw S3Error.bad("\(what) → HTTP \(http.statusCode)") }
    }

    /// Minimal XML scrape of <Key>…</Key> from a ListObjectsV2 response.
    private static func parseKeys(_ data: Data) -> [String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var keys: [String] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<Key>"), let close = rest.range(of: "</Key>") {
            let k = rest[open.upperBound..<close.lowerBound]
            keys.append(String(k).replacingOccurrences(of: "&amp;", with: "&"))
            rest = rest[close.upperBound...]
        }
        return keys
    }

    // MARK: - SigV4

    private func signedRequest(method: String, path: String, query: [(String, String)], payload: Data) throws -> URLRequest {
        // HAVEN_NO_NET: every bucket op is signed here first, so one guard closes PUT/GET/HEAD/LIST.
        // `headObjectExists` reads the throw as nil — "no HTTP response at all", which is the truth.
        guard !HavenNet.offline else { throw S3Error.bad("offline (HAVEN_NO_NET)") }
        let host = endpoint
        let now = Date()
        let amzDate = Self.iso8601.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256Hex(payload)

        let canonicalQuery = query
            .map { (encodeStrict($0.0), encodeStrict($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = hmac(hmacChain(dateStamp: dateStamp), Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var urlString = "https://\(host)\(path)"
        if !canonicalQuery.isEmpty { urlString += "?\(canonicalQuery)" }
        guard let u = URL(string: urlString) else { throw S3Error.bad("bad url") }

        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - Pre-signed URLs (query-string SigV4)
    //
    // Lets the bucket owner mint scoped, expiring, single-object URLs and hand THOSE to the
    // circle — so members conduct mailbox ops without ever seeing the access key/secret.

    /// A pre-signed URL for `method` ("GET"/"PUT") on `key`, valid `expires` seconds (≤7 days).
    func presignedURL(method: String, key: String, expires: Int = 604_800, listPrefix: String? = nil) -> URL? {
        let host = endpoint
        let now = Date()
        let amzDate = Self.iso8601.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let path = listPrefix != nil ? "/\(bucket)" : "/\(bucket)/\(encodePath(key))"

        var query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKey)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "\(min(max(expires, 1), 604_800))"),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let p = listPrefix { query.append(("list-type", "2")); query.append(("prefix", p)); query.append(("max-keys", "1000")) }

        let canonicalQuery = query
            .map { (encodeStrict($0.0), encodeStrict($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let payloadHash = "UNSIGNED-PAYLOAD"
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = hmac(hmacChain(dateStamp: dateStamp), Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://\(host)\(path)?\(canonicalQuery)&X-Amz-Signature=\(signature)")
    }

    /// Plain HTTPS GET of a pre-signed URL (members fetching the mailbox).
    static func getURL(_ url: URL) async -> Data? {
        guard !HavenNet.offline else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
    /// Plain HTTPS PUT to a pre-signed URL (members writing to the mailbox).
    static func putURL(_ url: URL, data: Data) async -> Bool {
        guard !HavenNet.offline else { return false }
        var req = URLRequest(url: url); req.httpMethod = "PUT"; req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.upload(for: req, from: data),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }
    /// Parse keys from a pre-signed LIST response (same XML scrape as listKeys).
    static func parseListKeys(_ data: Data) -> [String] { parseKeys(data) }

    private func hmacChain(dateStamp: String) -> SymmetricKey {
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), Data(dateStamp.utf8))
        let kRegion = hmac(SymmetricKey(data: kDate), Data(region.utf8))
        let kService = hmac(SymmetricKey(data: kRegion), Data("s3".utf8))
        let kSigning = hmac(SymmetricKey(data: kService), Data("aws4_request".utf8))
        return SymmetricKey(data: kSigning)
    }
    private func hmac(_ key: SymmetricKey, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: key)) }
    private func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Path encoding keeps "/" as a separator (object keys are path-like).
    private func encodePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? String($0) }
            .joined(separator: "/")
    }
    /// Strict encoding for canonical query (encodes "/" too), per SigV4.
    private func encodeStrict(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? s
    }

    private static let unreserved: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
    private static let iso8601: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

enum S3Error: Error, LocalizedError {
    case bad(String)
    var errorDescription: String? { if case .bad(let m) = self { return m } else { return "S3 error" } }
}
