import Foundation

/// One-time move of the pre-rename (Kith) media into the current store, then removal of the
/// legacy folder.
///
/// The rename (1a96c5cd, 2026-06-21) changed the media directory from `kith-media/` to
/// `haven-media/` and dropped the migration, so ~200 MB of June media sat unread on the owner's
/// phone. File names never changed shape: both stores keep a ref's bytes at `<ref>.<ext>`
/// (`img_<id>.jpg`, `vid_<id>.mp4`, `aud_<id>.m4a`, `file_<id>.zip` — see `MediaStore.fileURL`),
/// so a legacy file MOVED to `haven-media/<same name>` is exactly where `MediaStore` looks the ref
/// up today, and `HeldMediaIndex` finds it on its first stat. Move, not copy — no doubling.
///
/// Per file: already in the current store → the legacy copy is redundant and deleted; otherwise
/// moved and verified (present, same size). The folder is removed only when EVERY entry was
/// accounted for; any failure (unrecognized name, move error, size mismatch) leaves the folder and
/// whatever is still in it for the next launch. Completion is recorded so it runs once.
///
/// `kith-avatar.jpg` moves to the legacy global avatar slot (`haven-avatar.jpg`, which the profile
/// namespace migration reads) when no avatar exists at all; otherwise it is redundant and deleted.
/// `kith-feed.json` is NOT touched: it is engine state sealed under the pre-rename crypto salts,
/// which this engine cannot open, and at 79 KB it costs nothing to keep.
///
/// Foundation only — covered by HavenLogicTests.
enum LegacyKithMigration {
    static let doneKey = "haven.legacyKith.migrated.v1"

    struct Outcome: Equatable {
        var moved = 0
        var alreadyPresent = 0
        var failed = 0
        var legacyRemoved = false
        var movedNames: [String] = []
    }

    /// The kinds `MediaStore` stores, with the extension it stores each under.
    private static let extByPrefix: [String: String] = ["img_": "jpg", "vid_": "mp4", "aud_": "m4a", "file_": "zip"]

    /// True when `name` is a stored-media file name the current store would look up as-is.
    static func isStoreFileName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return false }
        let stem = String(name[..<dot]), ext = String(name[name.index(after: dot)...])
        guard let hit = extByPrefix.first(where: { stem.hasPrefix($0.key) }) else { return false }
        return ext == hit.value && stem.count > hit.key.count && !stem.contains("/")
    }

    /// Move every legacy media file into `storeDir`; remove `legacyDir` only if all were accounted for.
    static func migrateMedia(legacyDir: URL, storeDir: URL) -> Outcome {
        let fm = FileManager.default
        var out = Outcome()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyDir.path, isDirectory: &isDir), isDir.boolValue else {
            out.legacyRemoved = true   // nothing to do
            return out
        }
        guard let names = try? fm.contentsOfDirectory(atPath: legacyDir.path) else {
            out.failed += 1
            return out
        }
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        for name in names.sorted() {
            if name.hasPrefix(".") { continue }   // Finder/system detritus, not media
            let src = legacyDir.appendingPathComponent(name)
            guard isStoreFileName(name) else { out.failed += 1; continue }
            let dst = storeDir.appendingPathComponent(name)
            let srcSize = size(src)
            if fm.fileExists(atPath: dst.path), size(dst) > 0 {
                // The current store already holds this ref — the legacy copy is redundant.
                if (try? fm.removeItem(at: src)) != nil { out.alreadyPresent += 1 } else { out.failed += 1 }
                continue
            }
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }   // an empty stub
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                out.failed += 1
                continue
            }
            guard fm.fileExists(atPath: dst.path), size(dst) == srcSize, srcSize >= 0 else {
                out.failed += 1
                continue
            }
            out.moved += 1
            out.movedNames.append(name)
        }
        if out.failed == 0 {
            out.legacyRemoved = (try? fm.removeItem(at: legacyDir)) != nil || !fm.fileExists(atPath: legacyDir.path)
        }
        return out
    }

    /// Returns true when the legacy avatar is gone (moved or redundant).
    static func migrateAvatar(legacy: URL, appSupport: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return true }
        let existing = (try? fm.contentsOfDirectory(atPath: appSupport.path))?
            .contains { $0.hasPrefix("haven-avatar") && $0.hasSuffix(".jpg") } ?? false
        if existing { return (try? fm.removeItem(at: legacy)) != nil }
        return (try? fm.moveItem(at: legacy, to: appSupport.appendingPathComponent("haven-avatar.jpg"))) != nil
    }

    /// Run once (recorded in `defaults` only when everything was migrated). Off the main thread.
    @discardableResult
    static func runOnce(appSupport: URL, storeDir: URL, defaults: UserDefaults = .standard) -> Outcome? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        var out = migrateMedia(legacyDir: appSupport.appendingPathComponent("kith-media", isDirectory: true),
                               storeDir: storeDir)
        let avatarDone = migrateAvatar(legacy: appSupport.appendingPathComponent("kith-avatar.jpg"),
                                       appSupport: appSupport)
        if !avatarDone { out.failed += 1 }
        if out.legacyRemoved, avatarDone { defaults.set(true, forKey: doneKey) }
        return out
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }
}
