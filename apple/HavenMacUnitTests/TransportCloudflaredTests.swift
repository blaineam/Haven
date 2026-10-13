import XCTest
@testable import HavenUITestHost

/// The tunnel layer's rules with no `cloudflared` binary: URL scraping from connector output, the
/// front-door policy stored in preferences, the child-process plumbing exercised with throwaway shell
/// children standing in for the connector, and the crash guard that remembers their pids.
@MainActor
final class TransportCloudflaredTests: XCTestCase {
    private var tunnel: CloudflaredTunnel { CloudflaredTunnel.shared }
    private let keys = ["haven.relay.frontDoor", "haven.relay.autoTunnel", "haven.relay.publicURL", "haven.relay.cfTunnelToken"]
    private var saved: [String: Any] = [:]
    private var spawned: [Process] = []

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        saved = [:]
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }; UserDefaults.standard.removeObject(forKey: k) }
    }
    override func tearDown() async throws {
        for p in spawned where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        spawned = []
        CloudflaredChildGuard.clearAll()
        for k in keys { if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
    }

    private func shell(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        spawned.append(p)
        return p
    }
    private func waitFor(_ what: String, timeout: TimeInterval = 30, _ cond: @escaping @MainActor () -> Bool) async {
        await Harness.until(FeedStore.shared, timeout: timeout, what, cond)
    }

    // MARK: URLs

    func testPublicUrlsAreNormalisedToAnOriginWithNoTrailingSlash() {
        XCTAssertEqual(CloudflaredTunnel.normalizePublicURL("relay.example.com"), "https://relay.example.com")
        XCTAssertEqual(CloudflaredTunnel.normalizePublicURL("  https://relay.example.com//  "), "https://relay.example.com")
        XCTAssertEqual(CloudflaredTunnel.normalizePublicURL("http://relay.example.com:8080/"), "http://relay.example.com:8080")
        XCTAssertEqual(CloudflaredTunnel.normalizePublicURL("https://relay.example.com/haven"), "https://relay.example.com/haven")
        XCTAssertNil(CloudflaredTunnel.normalizePublicURL(""))
        XCTAssertNil(CloudflaredTunnel.normalizePublicURL("   /  "))
        XCTAssertNil(CloudflaredTunnel.normalizePublicURL("localhost"), "no dot, not a public hostname")
        XCTAssertNil(CloudflaredTunnel.normalizePublicURL("https://intranet"))
    }

    func testTheQuickTunnelHostnameIsPulledOutOfNoisyConnectorLogs() {
        let log = """
        2026-10-12T10:00:00Z INF Thank you for trying Cloudflare Tunnel. Doing so, without a Cloudflare account, is a quick way to experiment. See https://developers.cloudflare.com/cloudflare-one/
        2026-10-12T10:00:01Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-10-12T10:00:02Z INF +--------------------------------------------------------------------------------------------+
        2026-10-12T10:00:02Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
        2026-10-12T10:00:02Z INF |  https://quiet-fox-123.trycloudflare.com                                                   |
        """
        XCTAssertEqual(CloudflaredTunnel.extractTrycloudflareURL(log), "https://quiet-fox-123.trycloudflare.com")
        XCTAssertEqual(CloudflaredTunnel.extractTrycloudflareURL("see (https://a-b.trycloudflare.com)."), "https://a-b.trycloudflare.com")
        XCTAssertEqual(CloudflaredTunnel.extractTrycloudflareURL("https://a-b.trycloudflare.com/some/path?x=1 ok"), "https://a-b.trycloudflare.com",
                       "only the origin is announced")
        XCTAssertNil(CloudflaredTunnel.extractTrycloudflareURL("https://example.com and https://developers.cloudflare.com"))
        XCTAssertNil(CloudflaredTunnel.extractTrycloudflareURL(""))
        XCTAssertNil(CloudflaredTunnel.extractTrycloudflareURL("https://"))
    }

    // MARK: Front-door policy

    func testTheFrontDoorModeIsInferredFromWhatIsConfiguredWhenNoneWasChosen() {
        XCTAssertEqual(tunnel.frontDoorMode, "auto")
        tunnel.configuredPublicURL = "relay.example.com"
        XCTAssertEqual(tunnel.frontDoorMode, "manual", "a domain with no token: the operator runs their own tunnel")
        tunnel.tunnelToken = "tok"
        XCTAssertEqual(tunnel.frontDoorMode, "bundled", "a domain WITH a token: Haven runs the named tunnel")
    }

    func testAnExplicitModeWinsAndKeepsTheLegacyAutoFlagInSync() {
        tunnel.frontDoorMode = "manual"
        XCTAssertEqual(tunnel.frontDoorMode, "manual")
        XCTAssertFalse(tunnel.autoEnabled)
        tunnel.frontDoorMode = "bundled"
        XCTAssertEqual(tunnel.frontDoorMode, "bundled")
        XCTAssertFalse(tunnel.autoEnabled)
        tunnel.frontDoorMode = "  AUTO "
        XCTAssertEqual(tunnel.frontDoorMode, "auto")
        XCTAssertTrue(tunnel.autoEnabled)
        tunnel.frontDoorMode = "nonsense"
        XCTAssertEqual(tunnel.frontDoorMode, "auto", "anything unrecognised falls back to the free default")
        UserDefaults.standard.set("  Manual ", forKey: "haven.relay.frontDoor")
        XCTAssertEqual(tunnel.frontDoorMode, "manual", "read back case- and space-insensitively")
    }

    func testPreferencesTrimAndClearOnEmpty() {
        XCTAssertTrue(tunnel.autoEnabled, "free tunnels are on until the operator turns them off")
        tunnel.autoEnabled = false
        XCTAssertFalse(tunnel.autoEnabled)
        tunnel.configuredPublicURL = "  https://relay.example.com  "
        XCTAssertEqual(tunnel.configuredPublicURL, "https://relay.example.com")
        tunnel.configuredPublicURL = "   "
        XCTAssertEqual(tunnel.configuredPublicURL, "")
        XCTAssertNil(UserDefaults.standard.object(forKey: "haven.relay.publicURL"))
        tunnel.tunnelToken = " secret \n"
        XCTAssertEqual(tunnel.tunnelToken, "secret")
        tunnel.tunnelToken = ""
        XCTAssertNil(UserDefaults.standard.object(forKey: "haven.relay.cfTunnelToken"))
    }

    func testTheLayoutTheUiExplainsFollowsTheHost() {
        tunnel.setFrontDoorLayout(pathProxy: true, localPort: 8675)
        XCTAssertTrue(tunnel.usesPathProxy)
        XCTAssertEqual(tunnel.localFrontDoor, "http://127.0.0.1:8675")
        XCTAssertNil(tunnel.dualTunnelNote)
        XCTAssertNil(tunnel.derpPublicURL, "single origin: no stale second hostname")
        tunnel.setFrontDoorLayout(pathProxy: false, localPort: 8674, dualNote: "Path proxy off")
        XCTAssertFalse(tunnel.usesPathProxy)
        XCTAssertEqual(tunnel.localFrontDoor, "http://127.0.0.1:8674")
        XCTAssertEqual(tunnel.dualTunnelNote, "Path proxy off")
    }

    func testAConnectorIsOnlyExpectedWhereHavenWouldRunOne() {
        XCTAssertFalse(tunnel.expectsLiveConnector, "auto, nothing running, no URL")
        XCTAssertFalse(tunnel.isMainConnectorAlive)
        tunnel.frontDoorMode = "manual"
        tunnel.configuredPublicURL = "relay.example.com"
        tunnel.tunnelToken = "tok"
        XCTAssertFalse(tunnel.expectsLiveConnector, "manual: the operator's tunnel is none of our business")
        tunnel.frontDoorMode = "auto"
        XCTAssertTrue(tunnel.expectsLiveConnector, "a domain plus a token means a named connector should be up")
    }

    func testOfflineApplyingAFrontDoorSpawnsAndAnnouncesNothing() async {
        let fd = await tunnel.apply(port: 8675)
        XCTAssertNil(fd.announceURL)
        XCTAssertFalse(fd.spawnedConnector)
        let derp = await tunnel.startQuickDerp(port: 3340)
        XCTAssertNil(derp)
        XCTAssertNil(tunnel.publicURL)
    }

    func testLogsLiveUnderApplicationSupport() {
        let dir = CloudflaredTunnel.logsDirectory()
        XCTAssertTrue(dir.path.hasSuffix("Haven/logs"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    // MARK: Connector output (fake child)

    func testAQuickConnectorsUrlIsScrapedFromItsOutputEvenWhenSplitAcrossReads() async {
        let ready = CloudflaredTunnel.ReadyBox()
        // The URL arrives in two writes with a gap between them, as pipe reads often split it.
        let p = shell(#"printf 'INF |  https://split-or'; sleep 1; printf 'ange-42.trycloudflare.com  |\n'; sleep 30"#)
        XCTAssertTrue(tunnel.attach(proc: p, ready: ready, mode: .quick))
        await waitFor("the URL to be scraped") { ready.url == "https://split-orange-42.trycloudflare.com" }
        XCTAssertTrue(tunnel.isMainConnectorAlive)
        XCTAssertTrue(CloudflaredChildGuard.livePids().contains(p.processIdentifier), "the crash guard knows this child")
        XCTAssertTrue(ready.logText.contains("trycloudflare.com"))
        await tunnel.stopFully()
        await waitFor("the child to be gone") { kill(p.processIdentifier, 0) != 0 || !p.isRunning }
        XCTAssertFalse(tunnel.isMainConnectorAlive)
        XCTAssertFalse(CloudflaredChildGuard.livePids().contains(p.processIdentifier), "…and forgets it once stopped")
    }

    func testANamedConnectorIsReadyOnceItRegistersAConnection() async {
        let ready = CloudflaredTunnel.ReadyBox()
        let log = CloudflaredTunnel.prepareLogFile(name: "test-named-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let p = shell(#"echo 'INF Starting tunnel'; echo 'INF Registered tunnel connection connIndex=0 location=ams01'; sleep 30"#)
        XCTAssertTrue(tunnel.attach(proc: p, ready: ready, mode: .named, teeLog: log))
        await waitFor("the registration to be seen") { ready.namedReady }
        XCTAssertNil(ready.url, "a named tunnel announces the configured domain, not a scraped one")
        await waitFor("the output to be teed to the log file") {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Registered tunnel connection")
        }
        await tunnel.stopFully()
    }

    func testAConnectorThatCannotBeLaunchedIsReportedNotAssumed() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/nonexistent/cloudflared")
        XCTAssertFalse(tunnel.attach(proc: p, ready: CloudflaredTunnel.ReadyBox(), mode: .quick))
        XCTAssertFalse(tunnel.isMainConnectorAlive)
    }

    func testAStubbornChildIsKilledAfterAShortGrace() async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", #"$SIG{TERM}="IGNORE"; $|=1; print "up\n"; sleep 60"#]
        let out = Pipe(); p.standardOutput = out
        spawned.append(p)
        try? p.run()
        XCTAssertTrue(p.isRunning)
        CloudflaredTunnel.hardStopProcess(p)   // SIGTERM is ignored, so this has to escalate to SIGKILL
        await waitFor("the process to be reaped") { !p.isRunning }
        XCTAssertFalse(p.isRunning)
        CloudflaredTunnel.hardStopProcess(nil)
    }

    // MARK: Log files

    func testLogFilesRotateWhenTheyGrowHuge() throws {
        let name = "test-rotate-\(UUID().uuidString).log"
        let dir = CloudflaredTunnel.logsDirectory()
        let url = dir.appendingPathComponent(name)
        let bak = dir.appendingPathComponent(name + ".1")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: bak) }
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 2_100_000))
        let fresh = CloudflaredTunnel.prepareLogFile(name: name)
        XCTAssertEqual(fresh, url)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: bak.path)[.size] as? NSNumber)?.intValue, 2_100_000, "the old log is kept as .1")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, 0, "and a fresh one starts empty")
        CloudflaredTunnel.appendLogFile(url, line: "one")
        CloudflaredTunnel.appendLogFile(url, text: "two\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
        let created = dir.appendingPathComponent("test-created-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: created) }
        CloudflaredTunnel.appendLogFile(created, text: "x")   // missing file is created on first write
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "x")
    }

    func testTheCapturedLogIsCappedSoALongLivedTunnelCannotGrowItForever() {
        let box = CloudflaredTunnel.ReadyBox()
        for _ in 0..<80 { box.appendLog(String(repeating: "a", count: 1_000)) }
        XCTAssertLessThanOrEqual(box.logText.count, 64_000)
        box.appendLog("tail-marker")
        XCTAssertTrue(box.logText.hasSuffix("tail-marker"), "the newest output is what survives")
    }

    // MARK: Crash guard

    func testTheCrashGuardTracksOnlyRealPidsInItsTwoSlots() {
        CloudflaredChildGuard.clearAll()
        CloudflaredChildGuard.set(slot: 0, pid: 4242)
        CloudflaredChildGuard.set(slot: 1, pid: 4343)
        CloudflaredChildGuard.set(slot: 2, pid: 9999)    // out of range: ignored
        CloudflaredChildGuard.set(slot: -1, pid: 9999)
        XCTAssertEqual(CloudflaredChildGuard.livePids(), [4242, 4343])
        CloudflaredChildGuard.set(slot: 0, pid: 0)
        CloudflaredChildGuard.set(slot: 1, pid: 1)       // pid 1 is launchd, never a child of ours
        XCTAssertEqual(CloudflaredChildGuard.livePids(), [])
        CloudflaredChildGuard.set(slot: 0, pid: 77)
        CloudflaredChildGuard.clearAll()
        XCTAssertEqual(CloudflaredChildGuard.livePids(), [])
    }

    // MARK: Front door, with a stand-in connector

    /// A script standing in for the `cloudflared` binary: it records its arguments, then runs `body`.
    private func standIn(_ body: String) throws -> (bin: URL, args: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = dir.appendingPathComponent("args.txt")
        let bin = dir.appendingPathComponent("cloudflared")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(args.path)'\n\(body)\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (bin, args)
    }
    private func useStandIn(_ body: String) throws -> URL {
        let s = try standIn(body)
        CloudflaredTunnel.testBinary = s.bin
        CloudflaredTunnel.testAllowOffline = true
        CloudflaredTunnel.testRunViaShell = true
        addTeardownBlock { @MainActor in
            await self.tunnel.stopFully()
            CloudflaredTunnel.testBinary = nil
            CloudflaredTunnel.testAllowOffline = false
            CloudflaredTunnel.testRunViaShell = false
            try? FileManager.default.removeItem(at: s.bin.deletingLastPathComponent())
        }
        return s.args
    }

    func testManualAndUnconfiguredFrontDoorsNeverSpawnAConnector() async throws {
        _ = try useStandIn("exec sleep 120")   // the only thing any path here could spawn
        tunnel.frontDoorMode = "manual"
        tunnel.configuredPublicURL = "relay.example.com"
        var fd = await tunnel.apply(port: 8675)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com", "manual announces the operator's own URL")
        XCTAssertFalse(fd.spawnedConnector)
        tunnel.frontDoorMode = "bundled"   // a domain but no token: nothing to run
        fd = await tunnel.apply(port: 8675)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com")
        XCTAssertFalse(fd.spawnedConnector)
        tunnel.frontDoorMode = "bundled"
        tunnel.configuredPublicURL = ""
        fd = await tunnel.apply(port: 8675)
        XCTAssertNil(fd.announceURL, "bundled needs both a domain and a token")
        tunnel.frontDoorMode = "auto"      // a domain but no token: announce it, run nothing
        tunnel.configuredPublicURL = "relay.example.com"
        fd = await tunnel.apply(port: 8675)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com")
        XCTAssertFalse(fd.spawnedConnector)
        tunnel.configuredPublicURL = ""    // no domain and free tunnels switched off
        tunnel.autoEnabled = false
        fd = await tunnel.apply(port: 8675)
        XCTAssertNil(fd.announceURL)
        XCTAssertFalse(fd.spawnedConnector)
        XCTAssertFalse(tunnel.isMainConnectorAlive)
    }

    func testABundledFrontDoorRunsTheNamedConnectorWithItsTokenAndStopsCleanly() async throws {
        let args = try useStandIn("echo 'INF Registered tunnel connection connIndex=0 location=ams01'\nexec sleep 120")
        tunnel.frontDoorMode = "bundled"
        tunnel.configuredPublicURL = "relay.example.com"
        tunnel.tunnelToken = "tok-123"
        let fd = await tunnel.apply(port: 8675)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com")
        XCTAssertTrue(fd.spawnedConnector)
        XCTAssertEqual(tunnel.publicURL, "https://relay.example.com")
        XCTAssertTrue(tunnel.isMainConnectorAlive)
        XCTAssertTrue(tunnel.expectsLiveConnector)
        XCTAssertNotNil(tunnel.mainLogPath)
        let given = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(given.contains("run") && given.contains("--token") && given.contains("tok-123"), "\(given)")
        XCTAssertTrue(given.contains("--no-autoupdate") && given.contains("http2"), "a connector that must not update itself or use UDP")
        tunnel.setFrontDoorLayout(pathProxy: true, localPort: 8675)
        tunnel.stop()
        XCTAssertNil(tunnel.publicURL)
        XCTAssertFalse(tunnel.isMainConnectorAlive)
        XCTAssertFalse(tunnel.usesPathProxy)
        XCTAssertNil(tunnel.localFrontDoor)
    }

    func testAutoModeWithADomainAndATokenAlsoRunsTheNamedConnector() async throws {
        _ = try useStandIn("echo 'INF Connection registered connIndex=1'\nexec sleep 120")
        tunnel.frontDoorMode = "auto"
        tunnel.configuredPublicURL = "https://relay.example.com/"
        tunnel.tunnelToken = "tok"
        let fd = await tunnel.apply(port: 8675)
        XCTAssertTrue(fd.spawnedConnector)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com")
    }

    func testANamedConnectorThatDiesAtOnceFallsBackToAnnouncingTheDomain() async throws {
        _ = try useStandIn("echo 'ERR bad token'\nexit 3")
        tunnel.frontDoorMode = "bundled"
        tunnel.configuredPublicURL = "relay.example.com"
        tunnel.tunnelToken = "wrong"
        let fd = await tunnel.apply(port: 8675)
        XCTAssertEqual(fd.announceURL, "https://relay.example.com", "the domain is still announced…")
        XCTAssertFalse(fd.spawnedConnector, "…but nothing claims a connector is up")
        XCTAssertFalse(tunnel.isMainConnectorAlive)
    }

    func testADualDerpTunnelPublishesBothHostnamesWhenThePathProxyIsUnavailable() async throws {
        let args = try useStandIn("echo 'INF |  https://derp-fox-9.trycloudflare.com  |'\nexec sleep 120")
        tunnel.setFrontDoorLayout(pathProxy: true, localPort: 8675)
        let url = await tunnel.startQuickDerp(port: 3340)
        XCTAssertEqual(url, "https://derp-fox-9.trycloudflare.com")
        XCTAssertEqual(tunnel.derpPublicURL, url)
        XCTAssertFalse(tunnel.usesPathProxy, "a second free tunnel means the single-origin layout is off")
        XCTAssertTrue(tunnel.dualTunnelNote?.contains("derp-fox-9.trycloudflare.com") == true, "dual tunnels are never invisible")
        XCTAssertNotNil(tunnel.derpLogPath)
        let given = try String(contentsOf: args, encoding: .utf8)
        XCTAssertTrue(given.contains("127.0.0.1:3340"), given)
    }

    func testADerpTunnelThatNeverPrintsAUrlGivesNone() async throws {
        _ = try useStandIn("exit 1")
        let url = await tunnel.startQuickDerp(port: 3340)
        XCTAssertNil(url)
        XCTAssertNil(tunnel.derpPublicURL)
    }
}
