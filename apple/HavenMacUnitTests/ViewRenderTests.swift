import XCTest
import SwiftUI
import AppKit
@testable import HavenUITestHost

/// Renders the store-backed screens through a real `NSHostingView` against seeded stores, so their
/// bodies run for real (relay lists, recoverable/deleted relays, identity flows, media placeholders)
/// and the text they put on screen can be checked.
@MainActor
final class ViewRenderTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws { windows.removeAll() }

    /// Host `view` in an off-screen window, lay it out and let its first appearance run.
    private func render<V: View>(_ view: V, width: CGFloat = 560, height: CGFloat = 900) async -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        windows.append(window)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<8 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        return host
    }

    /// Whether the view actually drew something: an off-screen bitmap of it holds more than a flat fill.
    /// (Accessibility text isn't published for a window that is never shown, and these windows must
    /// never be shown on the owner's screen.)
    private func drawsContent(_ host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(host.fittingSize.width, 0, "the view has a size", file: file, line: line)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap", file: file, line: line) }
        host.cacheDisplay(in: host.bounds, to: rep)
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 60)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        XCTAssertGreaterThan(seen.count, 1, "something other than a flat fill was drawn", file: file, line: line)
    }

    private func seedRelays() -> [String] {
        let r = RelayMailboxStore.shared
        let live = String(repeating: "a1", count: 32), gone = String(repeating: "a2", count: 32), erased = String(repeating: "a3", count: 32)
        r.add(circleId: "default", nodeHex: live, name: "Basement NAS")
        r.setHttpInterface(live, urls: ["https://relay.example"], token: "t")
        r.add(circleId: "default", nodeHex: gone, name: "Old box")
        r.forget(nodeHex: gone)
        r.add(circleId: "default", nodeHex: erased, name: "Erased box")
        r.eraseNow(erased)
        return [live, gone, erased]
    }
    private func cleanup(_ hexes: [String]) {
        let r = RelayMailboxStore.shared
        for h in hexes { r.eraseNow(h); r.dropErased(h); r.unforget(h) }
        r.setDefault(nil)
    }

    func testRelayScreensListLiveForgottenAndDeletedRelays() async {
        _ = await Harness.feed()
        let hexes = seedRelays()
        defer { cleanup(hexes) }
        let relays = await render(RelaysView())
        drawsContent(relays)
        _ = await render(DeletedRelaysSection())
        _ = await render(RecoverableRelaysSection())
        let pool = await render(RelayPoolSection(circleId: "default"))
        drawsContent(pool)
        _ = await render(RelayRetentionControls())
        _ = await render(RelayFrontDoorControls())
        _ = await render(CircleMailboxSection(circleId: "default"))
        _ = await render(AddRelaySheet())
    }

    func testStorageScreens() async {
        _ = await Harness.feed()
        _ = await render(StorageSettingsView(circleId: "default"))
        _ = await render(StorageSettingsView())
        _ = await render(AdvancedStorageView(circleId: "default"))
        _ = await render(AdvancedStorageView())
    }

    func testIdentityAndDeviceLinkScreens() async {
        _ = await Harness.feed()
        let account = AccountStore()
        let move = await render(TransferIdentityView(accountStore: account))
        drawsContent(move)
        _ = await render(LinkDeviceView(accountStore: account))
        _ = await render(EnrollDeviceView())
        _ = await render(EnrollScanView(accountStore: account, onLinked: {}))
        _ = await render(RestoreIdentityView(accountStore: account, onRestored: {}))
        _ = await render(RestoreIdentityView(accountStore: account, linkMode: true, onRestored: {}))
    }

    func testMediaScreens() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let missing = "img_" + String(repeating: "c", count: 64)
        _ = await render(MissingMediaPlaceholder(ref: missing, isVideo: false))
        _ = await render(MissingMediaPlaceholder(ref: "vid_" + String(repeating: "d", count: 64), isVideo: true,
                                                 postContext: (circleId: "default", postId: "p1", authorShort: "abcd"),
                                                 mediaList: []))
        EvictedMediaStore.shared.mark(missing, bytes: 2_500_000)
        _ = await render(MissingMediaPlaceholder(ref: missing))
        EvictedMediaStore.shared.clear(missing)
        MediaWantedStore.shared.add(missing, manual: true)
        _ = await render(MissingMediaPlaceholder(ref: missing))
        MediaWantedStore.shared.clear(missing)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var data = rep.representation(using: .jpeg, properties: [:])!
        data.append(contentsOf: UUID().uuidString.utf8)
        let ref = MediaStore.contentRef(.image, data)
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        _ = await render(FeedImage(ref: ref) { Color.gray })
        _ = await render(ComposerAttachmentTile(ref: ref))
        _ = await render(ComposerAttachmentTile(ref: missing, size: 80))
        _ = await render(MediaCleanupView())
        MediaStore.shared.delete(ref)
    }

    func testDeviceAndRelayHistoryScreens() async throws {
        let store = await Harness.feed()
        let mgr = DeviceRosterManager.shared
        mgr.stepDown()
        defer { mgr.stepDown() }
        let account = AccountStore()
        _ = await render(AuthorizedDevicesView(accountStore: account))            // no roster yet
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let engine = Engine(try HavenSocial(accountSeed: seed))
        let primary = try Account.fromSeed(seed: seed)
        _ = await mgr.enable(engine: engine, accountSeed: seed, accountBundle: primary.publicBundle(), accountHex: primary.nodeIdHex())
        let phone = Account.generate()
        _ = await mgr.addLinkedDevice(bundle: phone.publicBundle(), nodeHex: phone.nodeIdHex(), name: "Blaine's phone",
                                      engine: engine, accountSeed: seed)
        let devices = await render(AuthorizedDevicesView(accountStore: account))   // primary + one linked device
        drawsContent(devices)
        _ = store
        _ = await render(Form { RelayHistorySection() })
    }

    func testTheIncomingCallScreen() async {
        let store = await Harness.feed()
        let caller = Peer(byte: 0xE1, name: "Ringing friend")
        await caller.befriend(store)
        _ = await render(CallOverlay(), width: 420, height: 800)   // no call: nothing to show, and no crash
        CallManager.shared.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertTrue(CallManager.shared.ringing)
        let incoming = await render(CallOverlay(), width: 420, height: 800)
        drawsContent(incoming)
        _ = await render(AddToCallPicker(), width: 420, height: 600)
        CallManager.shared.decline()
        XCTAssertFalse(CallManager.shared.ringing)
    }
}
