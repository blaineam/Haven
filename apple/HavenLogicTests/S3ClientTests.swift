import XCTest
import CryptoKit

/// The S3 client's request building (SigV4) and its transport behaviour against a stub protocol.
/// The pre-signed URL path is checked against AWS's published example (a fixed key, date and
/// signature), so a regression in the signing-key chain or canonicalisation cannot pass quietly.
final class S3ClientTests: XCTestCase {

    // MARK: Stub transport

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data))?
        nonisolated(unsafe) static var seen: [(request: URLRequest, body: Data?)] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body: Data?
            if let b = request.httpBody { body = b }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    out.append(buf, count: n)
                }
                body = out
            }
            Self.seen.append((request, body))
            let (code, data) = Self.handler?(request, body) ?? (200, Data())
            let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let cfg = HavenHTTP.makeConfiguration()
        cfg.protocolClasses = [Stub.self]
        session = URLSession(configuration: cfg)
        Stub.handler = nil
        Stub.seen = []
    }

    override func tearDown() {
        session.invalidateAndCancel()
        Stub.handler = nil
        super.tearDown()
    }

    private func client(endpoint: String = "https://s3.example.test", region: String = "us-west-2",
                        bucket: String = "bkt") -> S3Client {
        S3Client(config: S3Config(endpoint: endpoint, region: region, bucket: bucket,
                                  accessKey: "AKIDEXAMPLE", secret: "SECRETKEY"), session: session)
    }

    private func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private let fixedNow = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    // MARK: Config

    func testConfigCompleteness() {
        var c = S3Config(endpoint: "e", region: "", bucket: "b", accessKey: "a", secret: "s")
        XCTAssertTrue(c.isComplete, "region is optional")
        c.secret = ""
        XCTAssertFalse(c.isComplete)
        c.secret = "s"; c.bucket = ""
        XCTAssertFalse(c.isComplete)
        c.bucket = "b"; c.endpoint = ""
        XCTAssertFalse(c.isComplete)
        c.endpoint = "e"; c.accessKey = ""
        XCTAssertFalse(c.isComplete)
    }

    func testConfigCodableRoundTrip() throws {
        let c = S3Config(endpoint: "e", region: "r", bucket: "b", accessKey: "a", secret: "s")
        let back = try JSONDecoder().decode(S3Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testInitNormalisesEndpointAndRegion() {
        XCTAssertEqual(client(endpoint: "https://r2.example.test").endpoint, "r2.example.test")
        XCTAssertEqual(client(endpoint: "http://minio.local:9000").endpoint, "minio.local:9000")
        XCTAssertEqual(client(endpoint: "bare.host").endpoint, "bare.host")
        XCTAssertEqual(client(region: "").region, "us-east-1", "an empty region defaults like AWS")
        XCTAssertEqual(client(region: "eu-1").region, "eu-1")
    }

    // MARK: Pre-signed URL: AWS published example

    func testPresignMatchesAWSDocumentationExample() throws {
        let c = S3Client(config: S3Config(endpoint: "examplebucket.s3.amazonaws.com", region: "us-east-1",
                                          bucket: "unused", accessKey: "AKIAIOSFODNN7EXAMPLE",
                                          secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"), session: session)
        let url = try XCTUnwrap(c.presign(method: "GET", path: "/test.txt", expires: 86_400, now: fixedNow))
        XCTAssertEqual(url.absoluteString,
            "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    func testPresignedURLUsesPathStyleAndClampsExpiry() throws {
        let c = client()
        let u = try XCTUnwrap(c.presignedURL(method: "PUT", key: "haven/mailbox/c 1/m/0", expires: 99_999_999, now: fixedNow))
        XCTAssertEqual(u.host, "s3.example.test")
        XCTAssertEqual(u.path, "/bkt/haven/mailbox/c 1/m/0")
        XCTAssertTrue(u.absoluteString.contains("/bkt/haven/mailbox/c%201/m/0?"), "key path is percent-encoded, slashes kept")
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(v("X-Amz-Expires"), "604800", "SigV4 caps at 7 days")
        XCTAssertEqual(v("X-Amz-Credential"), "AKIDEXAMPLE/20130524/us-west-2/s3/aws4_request")
        XCTAssertEqual(v("X-Amz-SignedHeaders"), "host")
        XCTAssertEqual(v("X-Amz-Signature")?.count, 64)
        let low = try XCTUnwrap(c.presignedURL(method: "GET", key: "k", expires: 0, now: fixedNow))
        XCTAssertTrue(low.absoluteString.contains("X-Amz-Expires=1&"), "expiry floors at 1s")
    }

    func testPresignedListURLCarriesPrefixAndSignsIt() throws {
        let c = client()
        let a = try XCTUnwrap(c.presignedURL(method: "GET", key: "", listPrefix: "haven/mailbox/c1/", now: fixedNow))
        XCTAssertEqual(a.path, "/bkt")
        let q = URLComponents(url: a, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "list-type" }?.value, "2")
        XCTAssertEqual(q.first { $0.name == "prefix" }?.value, "haven/mailbox/c1/")
        XCTAssertEqual(q.first { $0.name == "max-keys" }?.value, "1000")
        let b = try XCTUnwrap(c.presignedURL(method: "GET", key: "", listPrefix: "haven/mailbox/c2/", now: fixedNow))
        let sigA = q.first { $0.name == "X-Amz-Signature" }?.value
        let sigB = URLComponents(url: b, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "X-Amz-Signature" }?.value
        XCTAssertNotEqual(sigA, sigB, "the prefix is part of what is signed")
    }

    func testPresignIsDeterministicForFixedTimeAndSensitiveToInputs() throws {
        let c = client()
        let a = c.presignedURL(method: "GET", key: "k", now: fixedNow)
        XCTAssertEqual(a, c.presignedURL(method: "GET", key: "k", now: fixedNow))
        XCTAssertNotEqual(a, c.presignedURL(method: "PUT", key: "k", now: fixedNow), "method is signed")
        XCTAssertNotEqual(a, c.presignedURL(method: "GET", key: "k2", now: fixedNow))
        XCTAssertNotEqual(a, c.presignedURL(method: "GET", key: "k", now: fixedNow.addingTimeInterval(86_400)))
    }

    // MARK: Header-signed request

    func testSignedRequestHeadersAndSignature() throws {
        let c = client()
        let payload = Data("hello".utf8)
        let req = try c.signedRequest(method: "PUT", path: "/bkt/a%20b/c", query: [], payload: payload, now: fixedNow)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString, "https://s3.example.test/bkt/a%20b/c")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Host"), "s3.example.test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-content-sha256"), sha256Hex(payload))

        // Re-derive the signature independently from the SigV4 spec.
        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let canonical = ["PUT", "/bkt/a%20b/c", "",
                         "host:s3.example.test\nx-amz-content-sha256:\(sha256Hex(payload))\nx-amz-date:20130524T000000Z\n",
                         "host;x-amz-content-sha256;x-amz-date", sha256Hex(payload)].joined(separator: "\n")
        let scope = "20130524/us-west-2/s3/aws4_request"
        let sts = ["AWS4-HMAC-SHA256", "20130524T000000Z", scope, sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        let kSigning = hmac(hmac(hmac(hmac(Data("AWS4SECRETKEY".utf8), "20130524"), "us-west-2"), "s3"), "aws4_request")
        let sig = hmac(kSigning, sts).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/\(scope), SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\(sig)")
    }

    func testSignedRequestEmptyPayloadHashAndSortedEncodedQuery() throws {
        let c = client()
        let req = try c.signedRequest(method: "GET", path: "/bkt",
                                      query: [("prefix", "a b/c"), ("list-type", "2"), ("max-keys", "1000")],
                                      payload: Data(), now: fixedNow)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-content-sha256"),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://s3.example.test/bkt?list-type=2&max-keys=1000&prefix=a%20b%2Fc",
                       "query keys sort, and values encode '/' strictly")
    }

    func testEncodingHelpers() {
        let c = client()
        XCTAssertEqual(c.encodePath("a/b c/d~e-f_g.h"), "a/b%20c/d~e-f_g.h")
        XCTAssertEqual(c.encodePath("/lead//dbl/"), "/lead//dbl/", "empty segments are preserved")
        XCTAssertEqual(c.encodePath("ü"), "%C3%BC")
        XCTAssertEqual(c.encodeStrict("a/b+c"), "a%2Fb%2Bc")
    }

    func testParseKeys() {
        let xml = "<ListBucketResult><Contents><Key>a/1</Key></Contents><Contents><Key>b&amp;c</Key></Contents></ListBucketResult>"
        XCTAssertEqual(S3Client.parseListKeys(Data(xml.utf8)), ["a/1", "b&c"])
        XCTAssertEqual(S3Client.parseListKeys(Data("<ListBucketResult/>".utf8)), [])
        XCTAssertEqual(S3Client.parseListKeys(Data([0xFF, 0xFE, 0xFD])), [], "non-UTF8 body parses to nothing")
        XCTAssertEqual(S3Client.parseListKeys(Data("<Key>unterminated".utf8)), [])
    }

    func testS3ErrorDescription() {
        XCTAssertEqual(S3Error.bad("boom").errorDescription, "boom")
    }

    // MARK: Transport

    func testPutObjectSendsSignedBodyToPathStyleURL() async throws {
        Stub.handler = { _, _ in (200, Data()) }
        let body = Data("sealed-bytes".utf8)
        try await client().putObject(key: "haven/x y", data: body)
        let seen = try XCTUnwrap(Stub.seen.last)
        XCTAssertEqual(seen.request.httpMethod, "PUT")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://s3.example.test/bkt/haven/x%20y")
        XCTAssertEqual(seen.body, body)
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-amz-content-sha256"), sha256Hex(body))
        XCTAssertNotNil(seen.request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPutObjectThrowsOnHTTPError() async {
        Stub.handler = { _, _ in (403, Data()) }
        do {
            try await client().putObject(key: "k", data: Data([1]))
            XCTFail("a 403 must surface")
        } catch {
            XCTAssertEqual(error.localizedDescription, "PUT k → HTTP 403")
        }
    }

    func testGetObjectReturnsBodyAndThrowsOn404() async throws {
        Stub.handler = { req, _ in
            req.url!.path.hasSuffix("/present") ? (200, Data("payload".utf8)) : (404, Data())
        }
        let got = try await client().getObject(key: "present")
        XCTAssertEqual(got, Data("payload".utf8))
        do { _ = try await client().getObject(key: "absent"); XCTFail("expected 404 to throw") }
        catch { XCTAssertEqual(error.localizedDescription, "GET absent → HTTP 404") }
    }

    func testHeadObjectTriState() async {
        Stub.handler = { req, _ in
            switch req.url!.path {
            case "/bkt/yes": return (200, Data())
            default: return (404, Data())
            }
        }
        let c = client()
        let yes = await c.headObjectExists(key: "yes")
        let no = await c.headObjectExists(key: "no")
        XCTAssertEqual(yes, true)
        XCTAssertEqual(no, false, "an answering bucket that lacks the key is false, not nil")
        let boolYes = await c.headObject(key: "yes")
        let boolNo = await c.headObject(key: "no")
        XCTAssertTrue(boolYes)
        XCTAssertFalse(boolNo)
    }

    func testHeadObjectNilWhenUnreachable() async {
        let cfg = HavenHTTP.makeConfiguration()
        cfg.protocolClasses = [FailingStub.self]
        let s = URLSession(configuration: cfg)
        defer { s.invalidateAndCancel() }
        let c = S3Client(config: S3Config(endpoint: "x.test", region: "", bucket: "b", accessKey: "a", secret: "s"), session: s)
        let r = await c.headObjectExists(key: "k")
        XCTAssertNil(r, "no HTTP response at all must read as nil so callers skip expensive sealing")
        let b = await c.headObject(key: "k")
        XCTAssertFalse(b)
    }

    final class FailingStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    func testListKeysQueriesBucketRootAndParsesResponse() async throws {
        Stub.handler = { _, _ in (200, Data("<Key>haven/mailbox/c/m/0</Key><Key>haven/mailbox/c/m/1</Key>".utf8)) }
        let keys = try await client().listKeys(prefix: "haven/mailbox/c/")
        XCTAssertEqual(keys, ["haven/mailbox/c/m/0", "haven/mailbox/c/m/1"])
        let url = try XCTUnwrap(Stub.seen.last?.request.url)
        XCTAssertEqual(url.path, "/bkt")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "list-type" }?.value, "2")
        XCTAssertEqual(q.first { $0.name == "prefix" }?.value, "haven/mailbox/c/")
    }

    func testStaticPresignedGetAndPut() async {
        Stub.handler = { req, body in
            req.httpMethod == "GET" ? (200, Data("pool".utf8)) : (body == Data([9]) ? (200, Data()) : (500, Data()))
        }
        let u = URL(string: "https://s3.example.test/bkt/k?sig=1")!
        let got = await S3Client.getURL(u, session: session)
        XCTAssertEqual(got, Data("pool".utf8))
        let putOK = await S3Client.putURL(u, data: Data([9]), session: session)
        XCTAssertTrue(putOK)
        let putBad = await S3Client.putURL(u, data: Data([8]), session: session)
        XCTAssertFalse(putBad)
        Stub.handler = { _, _ in (500, Data()) }
        let missing = await S3Client.getURL(u, session: session)
        XCTAssertNil(missing, "a non-2xx pre-signed GET is a miss, not data")
    }
}
