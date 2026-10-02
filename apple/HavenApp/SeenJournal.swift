import Foundation

/// The mailbox seen-set's on-disk form: an APPEND-ONLY journal of keys, one per line.
///
/// Field report, 2026-10-02 (owner's iPhone 17 Pro Max, "gets really hot"): the seen-set had grown
/// to ~140k keys / 21.6 MB, and every debounced save rewrote the WHOLE file — join 140k strings into
/// one 21 MB string, then an atomic write of it — once per mailbox burst, i.e. every couple of
/// seconds while a sync was running. A new mark is now one appended line; the whole file is
/// rewritten only when keys are REMOVED (the one-shot repairs, a re-open's `forgetSeenPrefix`, a
/// reset) or when the journal holds noticeably more lines than the set (duplicates appended by a
/// process killed between an append and the in-memory bookkeeping).
///
/// Not thread-safe by itself: the owner calls `noteInserted` / `noteRemoved` / `takeWrite` under the
/// same lock that guards the in-memory set, and `perform` under a separate write lock so an append
/// can never race a rewrite of the same file. Foundation only — covered by HavenLogicTests.
final class SeenJournal: @unchecked Sendable {
    /// What the next save has to do to make the file match the set.
    enum Write: Equatable {
        /// Add these keys at the end (the common case — a handful of new marks).
        case append([String])
        /// Replace the file with exactly these keys (after a removal or for compaction).
        case rewrite([String])
    }

    let url: URL
    private var pending: [String] = []
    private var needsRewrite = false

    init(url: URL) { self.url = url }

    /// Read the journal. Blank lines (the separator an append starts with) are skipped. Flags a
    /// compaction when the file carries many more lines than distinct keys.
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = 0
        var set = Set<String>()
        set.reserveCapacity(data.count / 100)
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            set.insert(String(sub))
        }
        if Self.wantsCompaction(lines: lines, distinct: set.count) { needsRewrite = true }
        return set
    }

    /// Duplicates beyond a quarter of the set (and at least 1000 lines) are worth one rewrite.
    static func wantsCompaction(lines: Int, distinct: Int) -> Bool {
        lines - distinct > max(1000, distinct / 4)
    }

    /// A key newly entered the set.
    func noteInserted(_ key: String) {
        guard !needsRewrite else { return }   // the coming rewrite carries it
        pending.append(key)
    }

    /// Keys left the set (or it was cleared): only a rewrite can express that.
    func noteRemoved() {
        needsRewrite = true
        pending.removeAll()
    }

    /// The file is gone (reset): start a fresh journal.
    func noteReset() {
        needsRewrite = false
        pending.removeAll()
    }

    var hasPendingWork: Bool { needsRewrite || !pending.isEmpty }

    /// Snapshot what to write and clear the pending state. `current` is read only for a rewrite.
    func takeWrite(current: @autoclosure () -> Set<String>) -> Write? {
        if needsRewrite {
            needsRewrite = false
            pending.removeAll()
            return .rewrite(Array(current()))
        }
        guard !pending.isEmpty else { return nil }
        let out = pending
        pending.removeAll()
        return .append(out)
    }

    /// Apply `write` to disk. Returns false when it failed (the caller re-queues via `requeue`).
    @discardableResult
    static func perform(_ write: Write, at url: URL) -> Bool {
        switch write {
        case .rewrite(let keys):
            let body = keys.joined(separator: "\n")
            do {
                try Data(body.utf8).write(to: url, options: .atomic)
                return true
            } catch { return false }
        case .append(let keys):
            guard !keys.isEmpty else { return true }
            // Leading newline: a file written by the old whole-set saver ends WITHOUT one, and the
            // first appended key must not fuse with its last line. Blank lines are skipped on load.
            let chunk = Data(("\n" + keys.joined(separator: "\n")).utf8)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                return (try? chunk.write(to: url, options: .atomic)) != nil
            }
            guard let fh = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? fh.close() }
            do {
                try fh.seekToEnd()
                try fh.write(contentsOf: chunk)
                return true
            } catch { return false }
        }
    }

    /// A failed write goes back in line (a failed append becomes a rewrite: the file's tail is unknown).
    func requeue(_ write: Write) {
        switch write {
        case .rewrite: needsRewrite = true
        case .append: needsRewrite = true; pending.removeAll()
        }
    }
}
