import Foundation

/// The app's `tmp/` directory, kept from growing without bound.
///
/// Field report, 2026-10-02 (owner's iPhone 17 Pro Max): `tmp/` held 182 files, ~49.5 GB — every
/// video ever picked from Photos (copied out of the picker's short-lived URL, then never deleted:
/// `prepareVideo` transcodes FROM the copy but does not own it), every story/camera recording,
/// trimmed clips, Shazam spills, history-handoff seals, abandoned atomic-write directories. iOS
/// only purges an app's tmp under storage pressure, so on a phone with free space it simply grew.
///
/// Two halves: the import paths now `discard` their temp source once it is consumed, and a launch
/// sweep reclaims anything older than `maxAge` that a previous process left behind (crash, kill
/// mid-transcode, or the builds before this fix). The age test uses the NEWEST of the creation,
/// modification and added-to-directory dates: a picker copy keeps the ORIGINAL video's dates (a
/// clip shot in April copied in today looks months old by mtime alone), but the date it was added
/// to tmp is the copy's.
/// Foundation only — covered by HavenLogicTests.
enum TempSweep {
    /// Old enough that no import, export or upload of the current or a previous launch still
    /// needs it. (A transcode of the longest allowed clip finishes in minutes.)
    static let maxAge: TimeInterval = 24 * 3600

    /// Delete `url` when it lives in this process's temp directory — a scratch copy we made for an
    /// import and have now consumed. Anything else (a Files-picker URL, a share-inbox file, the
    /// media store) is not ours to delete here and is left alone.
    static func discardIfTemp(_ url: URL, tempDir: URL = FileManager.default.temporaryDirectory) {
        guard isInside(url, tempDir) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    struct Result: Equatable { var removed = 0; var bytes: Int64 = 0 }

    /// Remove top-level entries of `tempDir` whose newest timestamp is older than `maxAge`.
    /// Directories go whole (and count their contents). Entries named in `keep` are spared.
    @discardableResult
    static func sweep(tempDir: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date(), maxAge: TimeInterval = maxAge,
                      keep: Set<String> = []) -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey,
                                      .isDirectoryKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: keys,
                                                      options: []) else { return Result() }
        var out = Result()
        for url in items where !keep.contains(url.lastPathComponent) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let newest = [v?.creationDate, v?.contentModificationDate, v?.addedToDirectoryDate]
                .compactMap { $0 }.max() ?? now
            guard now.timeIntervalSince(newest) > maxAge else { continue }
            let bytes = (v?.isDirectory ?? false) ? directoryBytes(url) : Int64(v?.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                out.removed += 1
                out.bytes += bytes
            }
        }
        return out
    }

    private static func directoryBytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}
