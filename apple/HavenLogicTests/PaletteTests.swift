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

    /// A CarPlay launch never creates `PaletteStore.shared`, so `current` must already hold the SAVED
    /// choice (it used to be the Sunset default, which the car drew as pink whatever was selected).
    func testStoredPaletteIsReadWithoutCreatingTheStore() {
        let d = UserDefaults(suiteName: "palette-stored-\(UUID().uuidString)")!
        XCTAssertEqual(PaletteStore.stored(in: d).id, "sunset")
        d.set("neutral", forKey: PaletteStore.key)
        XCTAssertEqual(PaletteStore.stored(in: d).id, "neutral")
        d.set("gone", forKey: PaletteStore.key)
        XCTAssertEqual(PaletteStore.stored(in: d).id, "sunset", "an unknown id falls back")
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
}

final class MediaCircleSetsTests: XCTestCase {
    private func fresh() -> MediaCircleSets { MediaCircleSets(defaults: UserDefaults(suiteName: "mcs-\(UUID().uuidString)")!) }

    func testUnregisteredOrSingleCircleSealsForItselfAlone() {
        let sets = fresh()
        XCTAssertEqual(sets.sealSet(ref: "img_a", circleId: "A"), ["A"])
        sets.register(refs: ["img_a"], circleIds: ["A"])
        XCTAssertEqual(sets.sealSet(ref: "img_a", circleId: "A"), ["A"])
        XCTAssertEqual(MediaCircleSets.tag(["A"]), "", "the legacy seal filename is unchanged for one circle")
    }

    func testEveryCirclesJobSealsForTheSameSetWithTheOriginFirst() {
        let sets = fresh()
        sets.register(refs: ["img_a", "thumb_a"], circleIds: ["A", "B", "C", "B"])
        for cid in ["A", "B", "C"] {
            XCTAssertEqual(sets.sealSet(ref: "img_a", circleId: cid), ["A", "B", "C"], "job for \(cid)")
        }
        XCTAssertEqual(sets.sealSet(ref: "thumb_a", circleId: "B"), ["A", "B", "C"])
        XCTAssertEqual(sets.sealSet(ref: "img_a", circleId: "Z"), ["Z"], "a circle outside the set seals alone")
    }

    func testALaterWiderPostWidensButNeverNarrows() {
        let sets = fresh()
        sets.register(refs: ["r"], circleIds: ["A", "B"])
        sets.register(refs: ["r"], circleIds: ["A", "C"])
        XCTAssertEqual(sets.sealSet(ref: "r", circleId: "A"), ["A", "B", "C"])
    }

    func testTagDiffersPerSetAndSurvivesRelaunch() {
        XCTAssertNotEqual(MediaCircleSets.tag(["A", "B"]), MediaCircleSets.tag(["A", "C"]))
        let d = UserDefaults(suiteName: "mcs-\(UUID().uuidString)")!
        MediaCircleSets(defaults: d).register(refs: ["r"], circleIds: ["A", "B"])
        XCTAssertEqual(MediaCircleSets(defaults: d).sealSet(ref: "r", circleId: "B"), ["A", "B"])
    }

    func testRegistryIsBounded() {
        let sets = fresh()
        for i in 0..<600 { sets.register(refs: ["r\(i)"], circleIds: ["A", "B"]) }
        XCTAssertEqual(sets.sealSet(ref: "r0", circleId: "A"), ["A"], "the oldest entries are pruned")
        XCTAssertEqual(sets.sealSet(ref: "r599", circleId: "A"), ["A", "B"])
    }
}
