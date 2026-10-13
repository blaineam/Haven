import XCTest
import SwiftUI
import AppKit
@testable import HavenUITestHost

/// Off-screen rendering and fixtures shared by the Views* hosted tests. Windows are never ordered
/// front, so nothing appears on the owner's screen.
@MainActor
enum ViewBench {
    private static var windows: [NSWindow] = []

    static func reset() { windows.removeAll() }

    /// Host `view` in an off-screen window, lay it out and let its first appearance run.
    static func render<V: View>(_ view: V, width: CGFloat = 480, height: CGFloat = 900) async -> NSHostingView<V> {
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

    /// Distinct colours sampled from an off-screen bitmap of the view: more than one means something was drawn.
    static func colours(_ host: NSView) -> Int {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 60)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// Render and assert the view drew something other than a flat fill. Returns the host for further checks.
    @discardableResult
    static func renderDrawn<V: View>(_ view: V, width: CGFloat = 480, height: CGFloat = 900,
                                     file: StaticString = #filePath, line: UInt = #line) async -> NSHostingView<V> {
        let host = await render(view, width: width, height: height)
        XCTAssertGreaterThan(host.fittingSize.width, 0, "the view has a size", file: file, line: line)
        XCTAssertGreaterThan(colours(host), 1, "something other than a flat fill was drawn", file: file, line: line)
        return host
    }
}

/// Feed items and media for the screens. Everything is synthetic.
enum ViewFixtures {
    static func jpeg(_ tag: String = "", side: Int = 48) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }

    static func nowMs(minus secs: Double = 0) -> UInt64 { UInt64((Date().timeIntervalSince1970 - secs) * 1000) }

    static func comment(_ id: String, by author: String = "abcd", mine: Bool = false, body: String = "nice one",
                        media: [String] = [], edited: Bool = false, unsent: Bool = false,
                        reactions: [ReactionFfi] = [], ago: Double = 120) -> FeedCommentFfi {
        FeedCommentFfi(id: id, authorShort: author, isMe: mine, createdAt: nowMs(minus: ago), body: body, media: media,
                       edited: edited, unsent: unsent, reactions: reactions)
    }

    static func reaction(_ emoji: String, count: UInt32 = 1, mine: Bool = false, authors: [String] = []) -> ReactionFfi {
        ReactionFfi(emoji: emoji, count: count, mine: mine, authors: authors)
    }

    static func item(_ id: String = UUID().uuidString, by author: String = "abcd", mine: Bool = false, body: String = "A post",
                     media: [String] = [], music: TrackRefFfi? = nil, edited: Bool = false, unsent: Bool = false,
                     story: Bool = false, muteVideo: Bool = false, comments: [FeedCommentFfi] = [],
                     reactions: [ReactionFfi] = [], poll: PollFfi? = nil, ago: Double = 3600) -> FeedItemFfi {
        FeedItemFfi(id: id, authorShort: author, isMe: mine, createdAt: nowMs(minus: ago), body: body, media: media, music: music,
                    edited: edited, unsent: unsent, story: story, muteVideo: muteVideo, comments: comments,
                    reactions: reactions, poll: poll)
    }

    static let track = TrackRefFfi(catalogId: "1440857781~9876543210", title: "Midnight City", artist: "M83",
                                   artworkUrl: "start:3000;https://art.example/m83.jpg", durationMs: 243_000)
}
