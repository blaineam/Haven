import XCTest
@testable import HavenLogicTests

/// Which running cloudflared the Mac app may kill on launch/quit.
///
/// The regression: quitting Haven (rc.3 build 629, 2026-10-03) left its helper running after the
/// app exited. The fix sweeps on quit and on next launch — so the matching rule now decides what
/// gets SIGKILLed, and it must never reach a process that is not ours.
final class CloudflaredOrphansTests: XCTestCase {

    private let bin = "/Applications/Haven.app/Contents/Helpers/cloudflared"
    private let logs = "/Users/me/Library/Containers/com.blaineam.kith/Data/Library/Application Support/Haven/logs"

    private func ours(_ pid: Int32, log: String = "cloudflared-main.log", tail: String = "tunnel --url http://127.0.0.1:8675 --no-autoupdate --protocol http2") -> String {
        "\(pid) \(bin) --logfile \(logs)/\(log) --loglevel info \(tail)"
    }

    // MARK: - The regression

    func testTheQuitOrphanFromBuild629IsFound() {
        let ps = """
          PID COMMAND
            1 /sbin/launchd
          812 /Applications/Haven.app/Contents/MacOS/Haven
        \(ours(4321))
        """
        let targets = sweep(ps)
        XCTAssertEqual(targets, [4321])
    }

    func testDerpTunnelAndNamedTunnelAreBothOurs() {
        let ps = [
            ours(10, log: "cloudflared-derp.log", tail: "tunnel --url http://127.0.0.1:3340"),
            ours(11, tail: "tunnel --no-autoupdate --protocol http2 run --token abc"),
        ].joined(separator: "\n")
        XCTAssertEqual(sweep(ps), [10, 11])
    }

    // MARK: - Never someone else's process

    func testAnotherAppsBundledCloudflaredIsNotOurs() {
        // The old scan matched any `/Contents/Helpers/cloudflared`.
        let other = "/Applications/Other.app/Contents/Helpers/cloudflared"
        let cmd = "\(other) --logfile /Users/me/Library/Logs/other/cloudflared-main.log tunnel run"
        XCTAssertFalse(CloudflaredOrphans.isOwned(command: cmd, binaryPath: bin, logsDir: logs))
    }

    func testUsersOwnHomebrewTunnelToHavensPortIsNotOurs() {
        // The old scan also killed any cloudflared pointed at 127.0.0.1:8675/8674/3340.
        let cmd = "/opt/homebrew/bin/cloudflared tunnel --url http://127.0.0.1:8675"
        XCTAssertFalse(CloudflaredOrphans.isOwned(command: cmd, binaryPath: bin, logsDir: logs))
    }

    func testOurBinaryWithoutOurLogfileIsNotOurs() {
        // e.g. the user running the bundled helper by hand, or another container's install.
        XCTAssertFalse(CloudflaredOrphans.isOwned(
            command: "\(bin) tunnel --url http://127.0.0.1:8675", binaryPath: bin, logsDir: logs))
        XCTAssertFalse(CloudflaredOrphans.isOwned(
            command: "\(bin) --logfile /tmp/cloudflared-main.log tunnel run", binaryPath: bin, logsDir: logs))
    }

    func testOurLogfileUnderADifferentBinaryIsNotOurs() {
        // A dev build (DerivedData helper) must not reap the installed app's live tunnel by path…
        let dev = "/Users/me/Library/Developer/Xcode/DerivedData/Haven/Build/Products/Debug/Haven.app/Contents/Helpers/cloudflared"
        let cmd = "\(dev) --logfile \(logs)/cloudflared-main.log tunnel run"
        XCTAssertFalse(CloudflaredOrphans.isOwned(command: cmd, binaryPath: bin, logsDir: logs))
        // …and a binary whose path merely STARTS with ours is a different file.
        let lookalike = "\(bin)-old --logfile \(logs)/cloudflared-main.log tunnel run"
        XCTAssertFalse(CloudflaredOrphans.isOwned(command: lookalike, binaryPath: bin, logsDir: logs))
    }

    func testLogsDirPrefixLookalikeIsNotOurs() {
        let cmd = "\(bin) --logfile \(logs)-backup/cloudflared-main.log tunnel run"
        XCTAssertFalse(CloudflaredOrphans.isOwned(command: cmd, binaryPath: bin, logsDir: logs))
    }

    func testLogfileEqualsFormIsOurs() {
        let cmd = "\(bin) --logfile=\(logs)/cloudflared-main.log tunnel run"
        XCTAssertTrue(CloudflaredOrphans.isOwned(command: cmd, binaryPath: bin, logsDir: logs + "/"))
    }

    // MARK: - Sweep bookkeeping

    func testLiveConnectorsAndSelfAreNeverTargets() {
        let ps = [ours(10), ours(11), ours(99)].joined(separator: "\n")
        let t = CloudflaredOrphans.sweepTargets(
            psOutput: ps, saved: [], binaryPath: bin, logsDir: logs,
            except: [11], selfPid: 99, executablePath: { _ in nil })
        XCTAssertEqual(t, [10])
    }

    func testSavedPidsAreIgnoredWhenPsWorks() {
        // A persisted PID is reused by some other process after a reboot — ps is the truth.
        XCTAssertEqual(sweep("1 /sbin/launchd", saved: [4321]), [])
    }

    func testPsUnavailableFallsBackToSavedPidsVerifiedByPath() {
        let paths: [Int32: String] = [10: bin, 11: "/usr/bin/some-reused-pid", 1: bin]
        let t = CloudflaredOrphans.sweepTargets(
            psOutput: nil, saved: [10, 11, 12, 1], binaryPath: bin, logsDir: logs,
            except: [], selfPid: 500, executablePath: { paths[$0] })
        XCTAssertEqual(t, [10], "only a saved PID still running our binary; never pid 1, never a dead pid")
    }

    func testParsePSSkipsJunkAndKeepsSpacesInPaths() {
        let rows = CloudflaredOrphans.parsePS("""
          PID COMMAND
        garbage
           42   /a b/c --x
        0 /kernel
        """)
        XCTAssertEqual(rows, [CloudflaredOrphans.Row(pid: 42, command: "/a b/c --x")])
    }

    private func sweep(_ ps: String, saved: [Int32] = []) -> Set<Int32> {
        CloudflaredOrphans.sweepTargets(
            psOutput: ps, saved: saved, binaryPath: bin, logsDir: logs,
            except: [], selfPid: 812, executablePath: { _ in nil })
    }
}
