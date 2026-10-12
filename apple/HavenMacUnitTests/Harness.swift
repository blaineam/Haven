import XCTest
import Combine
@testable import HavenUITestHost

/// Shared plumbing for the hosted unit tests. They run INSIDE the isolated UI-test host
/// (com.blaineam.kith.uitesthost): the FFI-backed stores are process singletons, so the tests
/// drive them through their real entry points against a wiped container, with no network
/// (the scheme sets HAVEN_NO_NET) and no sleeps — every wait is on a published change.
@MainActor
enum Harness {
    /// Refuse to run anywhere but the isolated host: these tests mutate singletons and the
    /// container they run in.
    static func assertIsolatedHost(file: StaticString = #filePath, line: UInt = #line) {
        CoverageFlusher.install()
        let id = Bundle.main.bundleIdentifier ?? ""
        precondition(id.hasSuffix(".uitesthost"), "hosted unit tests must run in the isolated host, not \(id)")
        if !ThermalPolicy.testPinned {
            // A hot or Low-Power-Mode dev Mac would otherwise park the handoff / self-sync / serve gates.
            ThermalPolicy.testPinned = true
            HeavyWorkMonitor.shared.refresh()
        }
    }

    /// The configured feed store (the host app already booted it; this joins that boot).
    static func feed(file: StaticString = #filePath, line: UInt = #line) async -> FeedStore {
        assertIsolatedHost()
        let store = FeedStore.shared
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            store.configureForCurrentIdentity { c.resume() }
        }
        return store
    }

    /// Suspend until `predicate` holds, re-checking after every change the store publishes.
    /// Fails the test (rather than hanging) after `timeout` seconds.
    static func until(_ store: FeedStore, timeout: TimeInterval = 30, _ what: String = "condition",
                      file: StaticString = #filePath, line: UInt = #line,
                      _ predicate: @escaping @MainActor () -> Bool) async {
        if predicate() { return }
        let exp = XCTestExpectation(description: what)
        var bag = Set<AnyCancellable>()
        let check: @MainActor () -> Void = { if predicate() { exp.fulfill() } }
        // The store itself plus the sibling stores its operations land in: a predicate that reads
        // contacts, requests, relays or devices must wake when THEY publish, not only the feed.
        let sources: [ObservableObjectPublisher] = [
            store.objectWillChange, FeedBadges.shared.objectWillChange, ContactsStore.shared.objectWillChange,
            ConnectionsStore.shared.objectWillChange, RelayMailboxStore.shared.objectWillChange,
            DeviceRosterManager.shared.objectWillChange, HistoryHandoff.shared.objectWillChange,
            SharedMailboxStore.shared.objectWillChange,
        ]
        for p in sources {
            p.sink { _ in DispatchQueue.main.async { MainActor.assumeIsolated { check() } } }.store(in: &bag)
        }
        // Safety net for state that changes without publishing anywhere (static caches, files).
        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { _ in MainActor.assumeIsolated { check() } }.store(in: &bag)
        let r = await XCTWaiter().fulfillment(of: [exp], timeout: timeout)
        _ = bag
        if r != .completed { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }
}

/// A second identity: a real `HavenSocial` engine with its own seed, exchanging sealed
/// envelopes with the store under test exactly the way core's net tests do.
final class Peer {
    let engine: HavenSocial
    let hex: String
    let name: String

    init(byte: UInt8, name: String) {
        var seed = Data(count: 32)
        for i in 0..<32 { seed[i] = byte &+ UInt8(i) }
        self.engine = try! HavenSocial(accountSeed: seed)
        self.hex = engine.myNodeHex()
        self.name = name
    }

    var bundle: Data { engine.myBundle() }

    /// Give this friend a second device in their signed roster (their roster is empty until then),
    /// the state a real contact with a phone and a Mac is in.
    @discardableResult
    func registerDevice(name: String = "Friend's phone") -> Data {
        let device = Account.generate()
        return engine.registerDevice(deviceBundle: device.publicBundle(), name: name,
                                     createdAt: UInt64(Date().timeIntervalSince1970))
    }

    /// Befriend `store` on the shared circle: the store approves the peer's connection request
    /// (the real accept path) and the peer learns the store's keys.
    @MainActor
    func befriend(_ store: FeedStore, circle: String = "default") async {
        engine.createCircle(id: circle, name: "Your circle")
        let req = ConnectionRequest(idHex: hex, name: name, bundle: bundle, safetyWords: [])
        await store.approveConnectionNow(req)
        if let mine = store.myPublicBundle() { _ = try? engine.addContactBundle(circleId: circle, bundle: mine) }
    }

    /// Author a post in `circle` and replay the peer's sealed history into `store`.
    @MainActor @discardableResult
    func post(_ body: String, into store: FeedStore, circle: String = "default",
              createdAt: UInt64? = nil, media: [String] = []) async -> Int {
        let ts = createdAt ?? UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try? engine.post(circleId: circle, body: body, media: media, music: nil, retentionSecs: nil,
                             story: false, muteVideo: false, createdAt: ts)
        return await replay(into: store, circle: circle)
    }

    @MainActor @discardableResult
    func replay(into store: FeedStore, circle: String = "default") async -> Int {
        await store.ingestHandoffPage(circleId: circle, envelopes: engine.syncEnvelopes(circleId: circle)) ?? -1
    }
}

/// The host's coverage flush (`HavenApp/CoverageHook.c`, defined only in the UI-test host).
@_silgen_name("HavenCoverageFlush")
private func havenCoverageFlush(_ path: UnsafePointer<CChar>?) -> Int32

/// Writes the host's coverage profile when the test bundle finishes. The host is a sandboxed app
/// the test runner ends abruptly, whose Xcode-chosen profile path sits in a container xcodebuild
/// cannot read back — so the run would report no coverage. The profile goes to a build-output root
/// the host's entitlements allow instead; `HAVEN_COVERAGE_DIR` overrides where.
final class CoverageFlusher: NSObject, XCTestObservation {
    nonisolated(unsafe) private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        XCTestObservationCenter.shared.addTestObserver(CoverageFlusher())
    }
    func testBundleDidFinish(_ testBundle: Bundle) {
        let dir = ProcessInfo.processInfo.environment["HAVEN_COVERAGE_DIR"] ?? "/private/tmp/haven-apple-unit-prof"
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { NSLog("[coverage] cannot create %@: %@", dir, String(describing: error)) }
        let rc = havenCoverageFlush("\(dir)/host-\(ProcessInfo.processInfo.processIdentifier).profraw")
        NSLog("[coverage] flush rc=%d dir=%@ exists=%d", rc, dir, FileManager.default.fileExists(atPath: dir) ? 1 : 0)
    }
}
