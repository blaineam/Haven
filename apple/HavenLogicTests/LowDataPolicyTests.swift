import XCTest

/// How the user's Low Data preference combines with what the network reports. The satellite rows are
/// the ones that matter: a preference must never weaken an ultra-constrained path (the OS will refuse
/// the traffic regardless), and "Always on" must never be weaker than the path itself.
final class LowDataPolicyTests: XCTestCase {
    private typealias P = LowDataPolicy

    func testResolutionTable() {
        let table: [(LowDataPreference, LowDataLevel, LowDataLevel)] = [
            (.automatic, .normal, .normal), (.automatic, .low, .low), (.automatic, .ultra, .ultra),
            (.always, .normal, .low), (.always, .low, .low), (.always, .ultra, .ultra),
            (.off, .normal, .normal), (.off, .low, .normal), (.off, .ultra, .ultra),
        ]
        for (pref, detected, expected) in table {
            XCTAssertEqual(P.resolve(preference: pref, detected: detected), expected, "\(pref) on \(detected)")
        }
    }

    func testUltraIsNeverWeakenedByAnyPreference() {
        for pref in LowDataPreference.allCases {
            XCTAssertEqual(P.resolve(preference: pref, detected: .ultra), .ultra)
        }
    }

    func testResolvedIsNeverMoreRestrictiveThanAlwaysAndNeverLessThanOffAllows() {
        for detected in LowDataLevel.allCases {
            XCTAssertLessThanOrEqual(P.resolve(preference: .off, detected: detected), P.resolve(preference: .automatic, detected: detected))
            XCTAssertGreaterThanOrEqual(P.resolve(preference: .always, detected: detected), P.resolve(preference: .automatic, detected: detected))
        }
    }

    func testImprovementOnlyWhenTheLinkGotBetter() {
        XCTAssertTrue(P.improved(from: .ultra, to: .low))
        XCTAssertTrue(P.improved(from: .ultra, to: .normal))
        XCTAssertTrue(P.improved(from: .low, to: .normal))
        XCTAssertFalse(P.improved(from: .normal, to: .low))
        XCTAssertFalse(P.improved(from: .low, to: .low), "no change is not an improvement")
        XCTAssertFalse(P.improved(from: .normal, to: .ultra))
    }

    func testLevelOrdering() {
        XCTAssertLessThan(LowDataLevel.normal, .low)
        XCTAssertLessThan(LowDataLevel.low, .ultra)
        XCTAssertEqual(LowDataLevel.allCases.sorted(), [.normal, .low, .ultra])
    }

    func testStatusLines() {
        XCTAssertEqual(P.status(effective: .normal, preference: .automatic, linkQuality: nil), "Full speed. Nothing is being held back.")
        XCTAssertEqual(P.status(effective: .low, preference: .automatic, linkQuality: nil), "This network is metered or in Low Data Mode.")
        XCTAssertEqual(P.status(effective: .low, preference: .always, linkQuality: nil), "Low data mode is on for every network.")
        XCTAssertEqual(P.status(effective: .ultra, preference: .automatic, linkQuality: nil), "Satellite or ultra-constrained link — text only.")
        XCTAssertEqual(P.status(effective: .ultra, preference: .off, linkQuality: "moderate"),
                       "Satellite or ultra-constrained link (link moderate) — text only.")
        XCTAssertFalse(P.status(effective: .normal, preference: .automatic, linkQuality: "good").contains("good"),
                       "quality is only quoted for a satellite link")
    }

    func testPreferenceLabelsAndStoredValues() {
        XCTAssertEqual(LowDataPreference.allCases.map(\.label), ["Automatic", "Always on", "Off"])
        XCTAssertEqual(LowDataPreference.allCases.map(\.id), [0, 1, 2])
        XCTAssertEqual(P.preference(fromStored: nil), .automatic, "nothing stored -> follow the network")
        XCTAssertEqual(P.preference(fromStored: 1), .always)
        XCTAssertEqual(P.preference(fromStored: 2), .off)
        XCTAssertEqual(P.preference(fromStored: 99), .automatic, "an unknown value from a newer build falls back safely")
    }
}
