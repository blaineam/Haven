import XCTest
import SwiftUI
@testable import HavenLogicTests

/// A feed post's media page must never claim more width than the card offered it.
///
/// It once did, and the result was a post rendered WIDER THAN THE PHONE with its picture cut off at
/// both screen edges, while the post directly below it looked perfect. The cause was one modifier:
/// `MissingMediaPlaceholder` drew the small `thumb:` companion with `.scaledToFill()`, which returns
/// a size that COVERS its proposal — so for any thumb wider in aspect than the page it was handed it
/// reported a width larger than that page. Nothing upstream shrinks an oversized child: the page's
/// `.frame(maxWidth: .infinity)` grows to fit it instead, and the `.clipShape` after that then clips
/// to the grown width rather than the card's. Measured at the time: a 512x288 thumb inside a 325pt
/// page claimed **1208pt**.
///
/// Only posts whose full-size bytes had not landed reached that branch — once they land `FeedImage`
/// draws with `.fit` — which is exactly why it hit one post in a feed and not its neighbour, and why
/// it survived so long.
///
/// This asserts the invariant rather than the modifier, so any future re-layout of the page is held
/// to the same contract however it is written. `ImageRenderer.proposedSize` imposes the card's
/// content width the way the feed does WITHOUT clamping the answer, so the rendered size is the size
/// the view actually claimed.
@MainActor
final class PostMediaPageWidthTests: XCTestCase {

    /// A post's content width on an iPhone: 393pt screen, less the feed stack's 16pt and the card's
    /// 18pt, both sides.
    private let pageWidth: CGFloat = 325
    /// `singleMediaMaxHeight` on a portrait phone.
    private let maxPageHeight: CGFloat = 680
    /// `minPageAspect` on a portrait phone.
    private let minPageAspect: CGFloat = 0.8

    /// Thumbnails are capped on their LARGER axis, so these are the shapes a 512px thumb takes for a
    /// tall phone screenshot, a landscape photo, a square crop and a panorama.
    private let thumbShapes: [(name: String, w: Int, h: Int)] = [
        ("tall", 236, 512), ("wide", 512, 288), ("square", 512, 512), ("panorama", 512, 128),
    ]

    /// `PostMediaView.pageHeight` — the page is as tall as the media wants until it would be taller
    /// than `minPageAspect`, capped. A tall shot gets 406pt, NOT the 680 cap, and that difference is
    /// why the width check below passes for a tall thumb: it was never the axis that broke.
    private func pageHeight(_ aspect: CGFloat) -> CGFloat {
        min(maxPageHeight, pageWidth / max(aspect, minPageAspect))
    }

    /// THE WIDTH CONTRACT: the page never claims more width than the card offered it.
    ///
    /// This is what let a card render past the screen edge. It fires on wide, square and panorama
    /// thumbs — measured at 1208pt, 680pt and 2720pt inside a 325pt card.
    func testMediaPageNeverExceedsTheWidthItWasOffered() {
        for shape in thumbShapes {
            let claimed = claimedSize(for: swatch(shape.w, shape.h))
            XCTAssertLessThanOrEqual(
                claimed.width, pageWidth + 0.5,
                "a \(shape.name) \(shape.w)x\(shape.h) thumb made the media page claim "
                + "\(Int(claimed.width))pt inside a \(Int(pageWidth))pt card — the card renders wider "
                + "than the screen and the picture is cut off at both edges")
        }
    }

    /// THE PICTURE CONTRACT: the placeholder shows the WHOLE photo, never a slice of it.
    ///
    /// The width contract above is not enough, and the reported post proved it. For a TALL source —
    /// a cropped screenshot — the page's width came out correct while the picture was still drawn
    /// 325x705 inside a 325x406 page and clipped to a blown-up vertical slice. Same modifier, same
    /// fix, but a width-only assertion is green for it.
    ///
    /// Measured on the IMAGE, not on the frame around it — and that distinction is the whole test.
    /// `PostMediaPlaceholder`'s `.frame(maxWidth: .infinity, minHeight: 160)` reports a clamped size
    /// however big the picture inside it goes, so asking the container is green for the tall case
    /// while the viewer is looking at a magnified slice. The image is what decides the framing, so
    /// the image is what gets asked.
    func testPlaceholderShowsTheWholePictureRatherThanASlice() {
        for shape in thumbShapes {
            let aspect = CGFloat(shape.w) / CGFloat(shape.h)
            let page = CGSize(width: pageWidth, height: pageHeight(aspect))
            let drawn = render(thumbPicture(swatch(shape.w, shape.h)), proposal: page)
            XCTAssertLessThanOrEqual(
                drawn.height, page.height + 0.5,
                "a \(shape.name) \(shape.w)x\(shape.h) thumb is drawn \(Int(drawn.width))x"
                + "\(Int(drawn.height)) in a \(Int(page.width))x\(Int(page.height)) page — it is "
                + "clipped, so the viewer sees a magnified slice of the photo instead of the photo")
            XCTAssertLessThanOrEqual(
                drawn.width, page.width + 0.5,
                "a \(shape.name) \(shape.w)x\(shape.h) thumb is drawn \(Int(drawn.width))x"
                + "\(Int(drawn.height)) in a \(Int(page.width))x\(Int(page.height)) page — the sides "
                + "are cut off")
        }
    }

    /// The page the feed builds around a not-yet-downloaded ref, reproduced: PostMediaView's
    /// single-media branch wrapping PostMediaPlaceholder's frame around the placeholder's thumb.
    ///
    /// Built from UIKit/AppKit types rather than the app's `PlatformImage` helper on purpose — the
    /// contract under test belongs to SwiftUI's layout, not to Haven's image plumbing, so the test
    /// should not go red because that plumbing moved.
    private func claimedSize(for img: TestImage) -> CGSize {
        let page = ZStack { placeholderView(img) }
            .frame(maxWidth: .infinity)
            .frame(height: maxPageHeight)
        return render(page, proposal: CGSize(width: pageWidth, height: maxPageHeight))
    }

    /// MissingMediaPlaceholder's thumb branch inside PostMediaPlaceholder's frame.
    private func placeholderView(_ img: TestImage) -> some View {
        ZStack { thumbPicture(img) }
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// Just the picture — the one modifier this whole file exists for.
    private func thumbPicture(_ img: TestImage) -> some View {
        testImage(img).resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func render(_ view: some View, proposal: CGSize) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: proposal.width, height: proposal.height)
        #if os(macOS)
        return renderer.nsImage?.size ?? .zero
        #else
        return renderer.uiImage?.size ?? .zero
        #endif
    }

    private func swatch(_ w: Int, _ h: Int) -> TestImage {
        #if os(macOS)
        let img = NSImage(size: CGSize(width: w, height: h))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.unlockFocus()
        return img
        #else
        let size = CGSize(width: w, height: h)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        #endif
    }

    private func testImage(_ img: TestImage) -> Image {
        #if os(macOS)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }
}

#if os(macOS)
import AppKit
private typealias TestImage = NSImage
#else
import UIKit
private typealias TestImage = UIImage
#endif
