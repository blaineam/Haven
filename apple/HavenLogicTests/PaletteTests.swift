import XCTest

final class PaletteTests: XCTestCase {
    func testDefaultIsSunsetAndMatchesTheOriginalBrand() {
        XCTAssertEqual(HavenPalette.default.id, "sunset")
        XCTAssertEqual(HavenPalette.default.stops, [0x7C3AED, 0xEC4899, 0xF59E0B])
    }

    func testUnknownOrMissingFallsBackToSunset() {
        XCTAssertEqual(HavenPalette.resolve(nil).id, "sunset")
        XCTAssertEqual(HavenPalette.resolve("nope").id, "sunset")
        XCTAssertEqual(HavenPalette.resolve("neutral").id, "neutral")
    }

    func testEveryPaletteHasThreeStopsAndUniqueId() {
        XCTAssertEqual(Set(HavenPalette.all.map(\.id)).count, HavenPalette.all.count)
        XCTAssertTrue(HavenPalette.all.allSatisfy { $0.stops.count == 3 })
        XCTAssertNotNil(HavenPalette.all.first { $0.id == "neutral" })
    }

    func testNeutralIsAchromatic() {
        for hex in HavenPalette.resolve("neutral").stops {
            let (r, g, b) = ((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF)
            XCTAssertLessThanOrEqual(max(r, g, b) - min(r, g, b), 0x10, "neutral stops should be near-grey")
        }
    }

    func testIconNamesOnlyForAlternates() {
        XCTAssertNil(HavenPalette.default.iconName)
        XCTAssertEqual(HavenPalette.resolve("ocean").iconName, "AppIcon-ocean")
    }

    @MainActor func testStorePersistsAndCommitsOnce() {
        let d = UserDefaults(suiteName: "palette-test-\(UUID().uuidString)")!
        let store = PaletteStore(defaults: d)
        XCTAssertEqual(store.palette.id, "sunset")
        store.select(HavenPalette.resolve("forest"))
        XCTAssertEqual(d.string(forKey: PaletteStore.key), "forest")
        XCTAssertEqual(PaletteStore.current.id, "forest")
        XCTAssertEqual(store.epoch, 0)          // not applied until the picker is left
        store.commit(); store.commit()
        XCTAssertEqual(store.epoch, 1)
        PaletteStore.current = .default
    }
}

final class MultiCirclePostTests: XCTestCase {
    func testNoPickMeansActiveCircleOnly() {
        XCTAssertEqual(MultiCirclePost.targets(picked: nil, active: "a"), ["a"])
        XCTAssertEqual(MultiCirclePost.targets(picked: [], active: "a"), ["a"])
    }

    func testActiveCircleLeadsAndNoRepeats() {
        XCTAssertEqual(MultiCirclePost.targets(picked: ["b", "a", "b", "c"], active: "a"), ["a", "b", "c"])
    }

    func testPickWithoutActiveKeepsOnlyThePick() {
        XCTAssertEqual(MultiCirclePost.targets(picked: ["b", "c"], active: "a"), ["b", "c"])
    }

    func testMediaLocksThePostToItsCircleButLocationsAndTextDoNot() {
        let synth: (String) -> Bool = { $0.hasPrefix("geo:") }
        XCTAssertFalse(MultiCirclePost.lockedToActive(attachedMedia: [], isSynthetic: synth))
        XCTAssertFalse(MultiCirclePost.lockedToActive(attachedMedia: ["geo:1,2"], isSynthetic: synth))
        XCTAssertTrue(MultiCirclePost.lockedToActive(attachedMedia: ["geo:1,2", "img_abc"], isSynthetic: synth))
    }
}
