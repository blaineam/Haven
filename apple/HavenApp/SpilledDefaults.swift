import Foundation

/// Large, per-media maps that used to live in `UserDefaults`, each in its own small file instead.
///
/// Field report, 2026-10-02 (owner's iPhone 17 Pro Max, "gets really hot"): the app's preferences
/// plist was 1.1 MB and rewritten every few seconds. cfprefsd persists a domain as ONE file, so a
/// tiny write anywhere (a watermark, a backoff tick) re-encoded and re-wrote every ref-keyed map in
/// it — media aspects, thumb/preview companions, fetch backoff, evictions, pins — thousands of
/// 70-character refs each. Those maps now live here, one binary plist per key under
/// `Application Support/haven-prefs/`, written only when THAT map changed, coalesced to one write
/// per burst, off the caller's thread. The preferences plist goes back to holding settings.
///
/// Reads are served from memory after the first touch. A key still in `UserDefaults` from an older
/// build is migrated on first read (file written, then the defaults entry removed). Property-list
/// values only (Data, String, NSNumber, arrays, dictionaries) — exactly what these call sites stored.
final class SpilledDefaults: @unchecked Sendable {
    static let shared: SpilledDefaults = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SpilledDefaults(directory: base.appendingPathComponent("haven-prefs", isDirectory: true),
                               legacy: .standard)
    }()

    private let directory: URL
    private let legacy: UserDefaults?
    private let writeDelay: TimeInterval
    private let lock = NSLock()
    private var cache: [String: Any] = [:]
    private var loaded: Set<String> = []
    private var dirty: Set<String> = []
    private var writeScheduled = false
    private let queue = DispatchQueue(label: "haven.spilled-defaults", qos: .utility)

    init(directory: URL, legacy: UserDefaults?, writeDelay: TimeInterval = 3) {
        self.directory = directory
        self.legacy = legacy
        self.writeDelay = writeDelay
    }

    // MARK: Reads

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked(key)
    }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }

    // MARK: Writes

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        // Overwritten before ever being read: the old defaults copy is moot — drop it, or it would
        // stay in the preferences plist forever.
        if loaded.insert(key).inserted { legacy?.removeObject(forKey: key) }
        if let value { cache[key] = value } else { cache.removeValue(forKey: key) }
        dirty.insert(key)
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in self?.flush() }
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }

    /// Write every changed key now (backgrounding; tests). Safe from any thread.
    func flush() {
        lock.lock()
        let keys = dirty
        dirty.removeAll()
        writeScheduled = false
        let values = keys.map { ($0, cache[$0]) }
        lock.unlock()
        guard !values.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, value) in values {
            let url = fileURL(key)
            guard let value else { try? FileManager.default.removeItem(at: url); continue }
            if let data = try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Factory reset: every spilled map goes, in memory and on disk.
    func removeAll() {
        lock.lock()
        cache.removeAll(); dirty.removeAll(); loaded.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Internals

    private func fileURL(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe + ".plist")
    }

    /// Caller holds `lock`.
    private func loadLocked(_ key: String) -> Any? {
        if loaded.contains(key) { return cache[key] }
        loaded.insert(key)
        if let data = try? Data(contentsOf: fileURL(key)),
           let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
           let v = root["v"] {
            cache[key] = v
            // The file is authoritative; drop a stale defaults copy an interrupted migration left.
            legacy?.removeObject(forKey: key)
            return v
        }
        // Migrate from UserDefaults: write the file FIRST, then drop the defaults entry.
        guard let legacy, let v = legacy.object(forKey: key) else { return nil }
        cache[key] = v
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: ["v": v], format: .binary, options: 0),
           (try? data.write(to: fileURL(key), options: .atomic)) != nil {
            legacy.removeObject(forKey: key)
        }
        return v
    }
}
