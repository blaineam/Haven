import XCTest

final class RelayPortBindTests: XCTestCase {
    private actor Binder {
        var freeAfter: Int          // attempts on the preferred port that fail first
        var ephemeralOk = true
        var attempts: [String] = []
        init(freeAfter: Int, ephemeralOk: Bool = true) { self.freeAfter = freeAfter; self.ephemeralOk = ephemeralOk }
        func serve(_ bind: String) throws -> UInt16 {
            attempts.append(bind)
            if bind.hasSuffix(":0") {
                guard ephemeralOk else { throw URLError(.cannotConnectToHost) }
                return 57634
            }
            if freeAfter > 0 { freeAfter -= 1; throw URLError(.cannotConnectToHost) }
            return RelayPortBind.preferredPort
        }
    }

    func testAFreePortBindsAtOnce() async {
        let b = Binder(freeAfter: 0)
        let r = await RelayPortBind.bind(serve: { try await b.serve($0) }, sleep: { _ in })
        XCTAssertEqual(r?.port, 8674); XCTAssertEqual(r?.preferred, true)
        let n = await b.attempts.count
        XCTAssertEqual(n, 1)
    }

    /// The gate-8 restart: the old listener lets go a moment after stop(). The relay must come back
    /// on the SAME port, not drift to an ephemeral one.
    func testARestartWaitsForItsOwnPortInsteadOfDrifting() async {
        let b = Binder(freeAfter: 3)
        let r = await RelayPortBind.bind(serve: { try await b.serve($0) }, sleep: { _ in })
        XCTAssertEqual(r?.port, 8674); XCTAssertEqual(r?.preferred, true)
        let tried = await b.attempts
        XCTAssertFalse(tried.contains("0.0.0.0:0"), "never went ephemeral: \(tried)")
    }

    func testAPortHeldBySomeoneElseStillFallsBackAfterTheRetries() async {
        let b = Binder(freeAfter: .max)
        var slept: UInt64 = 0
        let r = await RelayPortBind.bind(serve: { try await b.serve($0) }, sleep: { slept += $0 })
        XCTAssertEqual(r?.port, 57634); XCTAssertEqual(r?.preferred, false)
        let tried = await b.attempts
        XCTAssertEqual(tried.count, RelayPortBind.retryDelaysMs.count + 2)
        XCTAssertEqual(tried.last, "0.0.0.0:0")
        XCTAssertLessThanOrEqual(slept, 5_000, "the fallback is bounded")
    }

    func testNothingBindsIsNil() async {
        let b = Binder(freeAfter: .max, ephemeralOk: false)
        let r = await RelayPortBind.bind(serve: { try await b.serve($0) }, sleep: { _ in })
        XCTAssertNil(r)
    }
}
