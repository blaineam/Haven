import XCTest

/// Shared plumbing for the screen-by-screen UI tests.
///
/// Every launch is `-UITestMode -UITestReset`: a DEBUG-only switch (see `UITestMode` in the app)
/// that wipes the app's own container and keychain items first, then runs the PII-free demo cast
/// (Maya/Theo/Nina/Sam in "Your circle", DM threads with Maya — "kiln" — and Theo — "gpx") fully
/// offline with animations off. So each test starts from the same seeded state and can assert
/// exact values instead of inventing unique strings to dodge an earlier run's leftovers.
///
/// Like the rest of HavenUITests these need a SIGNED simulator build: the identity lives in the
/// data-protection keychain, which an unsigned build cannot write (see HavenUITests).
class HavenUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        SpringboardHygiene.dismissQueuedOpenPrompts()
    }

    /// Launch fresh into `tab` (circle | messages | you), optionally auto-presenting a demo scene.
    @discardableResult
    func launch(tab: String = "circle", scene: String? = nil, extraArgs: [String] = [],
                env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestReset"] + extraArgs
        app.launchEnvironment["HAVEN_TAB"] = tab
        if let scene { app.launchEnvironment["HAVEN_SCENE"] = scene }
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A static text whose label contains `text` (case-insensitive).
    func text(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func button(_ app: XCUIApplication, labeled label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Wait until `element` satisfies `format` (an NSPredicate over the element, e.g. "label == %@").
    @discardableResult
    func wait(_ element: XCUIElement, until format: String, _ args: CVarArg...,
              timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Swipe until `element` is realized AND sits in the open middle of the screen. Lazy lists keep
    /// off-screen rows out of the tree, and a row that is "hittable" can still be under the floating
    /// composer or the tab bar, where a tap lands on them instead.
    @discardableResult
    func scroll(_ app: XCUIApplication, to element: XCUIElement, up: Bool = true, max: Int = 10) -> Bool {
        let height = app.windows.firstMatch.frame.height
        func placed() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let f = element.frame
            return f.minY > height * 0.12 && f.maxY < height * 0.72
        }
        // A short, slow drag (a quarter of the screen) to nudge a row that is already in the tree;
        // a full swipe overshoots it straight past the open band.
        func nudge(contentUp: Bool) {
            let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: contentUp ? 0.6 : 0.35))
            let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: contentUp ? 0.35 : 0.6))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        // Which side of the screen the row was last seen on: a row scrolled out of a lazy list stays
        // in the query with an infinite frame, so "where it went" has to be remembered.
        var lastSeenAbove: Bool?
        var n = 0
        while !placed() && n < max {
            let f = element.exists ? element.frame : .null
            if f.minY.isFinite && f.maxY.isFinite {
                if f.minY <= height * 0.12 {
                    lastSeenAbove = true
                    if f.maxY < -height * 0.2 { app.swipeDown() } else { nudge(contentUp: false) }
                } else if f.maxY >= height * 0.72 {
                    lastSeenAbove = false
                    if f.minY > height * 1.2 { app.swipeUp() } else { nudge(contentUp: true) }
                } else if up { app.swipeUp() } else { app.swipeDown() }   // in the band but covered
            } else if let above = lastSeenAbove {
                if above { app.swipeDown() } else { app.swipeUp() }
            } else if up { app.swipeUp() } else { app.swipeDown() }
            n += 1
        }
        if n > 0 { settle(element) }
        return element.waitForExistence(timeout: 5)
    }

    /// The first element of `query` that is on screen in the open band, scrolling down the list
    /// until one is. (A lazy list keeps rows it has scrolled past in the tree with an empty frame,
    /// so "first match" can be a row far above the screen.)
    func firstOnScreen(_ app: XCUIApplication, _ query: XCUIElementQuery, maxScrolls: Int = 8) -> XCUIElement? {
        let height = app.windows.firstMatch.frame.height
        for attempt in 0...maxScrolls {
            if let hit = query.allElementsBoundByIndex.first(where: {
                let f = $0.frame
                return f.minY.isFinite && f.height > 0 && f.minY > height * 0.12 && f.maxY < height * 0.72
            }) {
                if attempt > 0 { settle(hit) }
                return hit
            }
            app.swipeUp()
        }
        return nil
    }

    /// Wait for a scroll to come to rest: a tap on a list that is still decelerating only stops it.
    func settle(_ element: XCUIElement, timeout: TimeInterval = 5) {
        guard element.exists else { return }
        var last = CGRect.null   // the first poll only records; "still" needs two equal samples
        let still = NSPredicate { _, _ in
            let now = element.exists ? element.frame : .zero
            defer { last = now }
            return now == last
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: still, object: nil)], timeout: timeout)
    }

    /// Wait for the seeded circle feed: the composer's Post pill names "Your circle"'s title.
    @discardableResult
    func waitForFeed(_ app: XCUIApplication) -> String {
        let send = app.buttons["composeSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the circle feed should show its composer")
        let prefix = "Post to everyone in "
        XCTAssertTrue(wait(send, until: "label BEGINSWITH %@", prefix, timeout: 30))
        return String(send.label.dropFirst(prefix.count))
    }

    /// Type into a field, finishing any tail the simulator dropped under host load (only ever
    /// appends the missing suffix — a field holding anything else still fails the equality check).
    @discardableResult
    func type(_ text: String, into field: XCUIElement, replacing: Bool = false) -> XCUIElement {
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the field should exist before typing")
        if replacing, let current = field.value as? String, !current.isEmpty,
           current != field.placeholderValue {
            // Tap at the far end so the caret lands AFTER the existing text (a centred tap can put
            // it anywhere, and deletes then eat nothing), then delete it all.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        } else {
            focus(field)
        }
        field.typeText(text)
        for _ in 0..<2 {
            let now = field.value as? String ?? ""
            guard now != text, text.hasPrefix(now) else { break }
            focus(field)
            field.typeText(String(text.dropFirst(now.count)))
        }
        XCTAssertEqual(field.value as? String, text, "the field should hold exactly what was typed")
        return field
    }

    /// Tap a field to focus it. On iPad a multi-line reply field reports itself un-hittable at its
    /// centre (its own horizontal scroll indicator sits there), so tap its leading edge instead.
    func focus(_ field: XCUIElement) {
        if field.isHittable { field.tap() }
        else { field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap() }
    }

    /// Back out of a pushed screen via the navigation bar's back button.
    func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}
