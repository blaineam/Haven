import Foundation

/// Did a self-sync merge change anything the ENGINE holds — i.e. does it owe a whole-engine export?
///
/// Only records `SelfSyncCoordinator.applyLocal` turns into engine calls count (`enginePrefixes`).
/// A `circle:` record also carries the circle's RELAYS, which live in `RelayMailboxStore` and save
/// themselves: a linked device re-adopting a relay ("self-sync un-forgot") rewrote the record, read
/// as an engine change, and exported the whole engine on an otherwise idle phone (e2e `responsive`,
/// `selfSyncAndPull` in `perf.persistReasons`). So a `circle:` record is compared through
/// `circleEngineView` — its name, members and creator, never its relays. Pure (the FFI decode is
/// passed in) so HavenLogicTests covers it.
enum SelfSyncEngineDiff {
    static let enginePrefixes = ["circle:", "circle-deleted:", "circle-recreated:",
                                 "circle-removed:", "circle-readd:", "removal:", "roster:"]

    /// `circleEngineView`: the engine-relevant projection of a `circle:` record's bytes, or nil when
    /// it cannot be decoded (then the raw bytes are compared — never miss a change we can't read).
    static func differs(_ a: [String: Data], _ b: [String: Data],
                        circleEngineView: (Data) -> AnyHashable?) -> Bool {
        func view(_ key: String, _ v: Data) -> AnyHashable {
            if key.hasPrefix("circle:"), let p = circleEngineView(v) { return p }
            return AnyHashable(v)
        }
        func pick(_ m: [String: Data]) -> [String: AnyHashable] {
            var out: [String: AnyHashable] = [:]
            for (k, v) in m where enginePrefixes.contains(where: { k.hasPrefix($0) }) { out[k] = view(k, v) }
            return out
        }
        return pick(a) != pick(b)
    }
}
