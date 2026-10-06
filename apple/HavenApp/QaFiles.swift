#if DEBUG
import Foundation

/// Where the QA fleet's drop / dump / staging files live (docs/QA.md "qa-cmd v2"): `qa-cmd.json`,
/// `qa-dump.json`, `qa-account-*.txt`, `qa-*-bundle.bin`, `qa-authorize-members.txt`, staged media.
///
/// DEBUG-only — this whole file, and every call site, is compiled out of Release, so the App Store /
/// TestFlight / Developer ID builds are unchanged by it.
///
/// Every build keeps them in its own Application Support, EXCEPT the e2e fleet's HavenStub
/// (`Scripts/qa-e2e-build-stub.sh` compiles it with `-D HAVEN_QA_STUB`, bundle id
/// `com.blaineam.kith.qa.stub`). The stub is sandboxed, and macOS App Data protection forbids every
/// other process — the harness included — from touching its container unless the owner grants
/// "access data from other apps" / Full Disk Access, which he will not (2026-10-06). So the stub's
/// QA files (and its hosted relay store, which the harness inspects) live in a plain directory the
/// harness owns, `~/Library/Application Support/HavenQA/stub/`, reachable from inside the sandbox
/// through the stub-only `temporary-exception.files.home-relative-path.read-write` entitlement
/// (`Haven.macOS.stub.entitlements`). Nothing outside that directory is shared.
enum QaFiles {
    /// The directory the harness reads and writes for this build.
    static var dir: URL? {
        #if HAVEN_QA_STUB && os(macOS)
        return stubSharedDir
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #endif
    }

    #if HAVEN_QA_STUB && os(macOS)
    /// `~/Library/Application Support/HavenQA/stub/` of the REAL home. Inside the sandbox
    /// `NSHomeDirectory()` is the container, so resolve the account's home from the password entry.
    /// The harness creates the directory (the sandbox can only write inside the exception path).
    static let stubSharedDir: URL = {
        let home: String
        if let pw = getpwuid(getuid()) { home = String(cString: pw.pointee.pw_dir) } else { home = NSHomeDirectory() }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/HavenQA/stub", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// True only for the stub binary (compile flag) running under the stub's own bundle id.
    static var isStub: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".qa.stub") == true }

    /// Hermetic fleet: with `HAVEN_QA_STUB_RESET=1` in the launch environment, wipe the stub's OWN
    /// container state before any store reads it — the wipe the bootstrap used to do from outside
    /// (`rm` + `defaults delete` on the container), which App Data protection now forbids. Same list
    /// as before: feed, media, seen-set, self-sync blob, qa files, and the preferences domain (the
    /// companion maps live there). The keychain identity is kept, exactly as before. The shared QA
    /// directory is the harness's to wipe — it stages A's bundle there BEFORE this launch.
    /// Refuses to run under any other bundle id, so a mis-flagged build can never wipe a real account.
    static func applyStubResetAtLaunch() {
        guard ProcessInfo.processInfo.environment["HAVEN_QA_STUB_RESET"] == "1" else { return }
        guard isStub else {
            NSLog("[QaFiles] stub reset refused: bundle id \(Bundle.main.bundleIdentifier ?? "?") is not the QA stub")
            return
        }
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            for name in ["haven-relay-store", "haven-media", "haven-feed.json", "haven-mailbox-seen.txt", "haven-selfsync.bin"] {
                try? fm.removeItem(at: base.appendingPathComponent(name))
            }
            for item in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix("qa-") {
                try? fm.removeItem(at: item)
            }
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        NSLog("[QaFiles] stub reset: container QA state wiped")
    }
    #endif
}
#endif
