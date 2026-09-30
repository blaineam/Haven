import Foundation

/// What a self-sync apply can move in the ENGINE: circles (id → name) and each circle's members.
///
/// `SelfSyncCoordinator.applyLocal` re-applies the whole converged self-sync state on every pass —
/// idempotent create / rename / member adds that are no-ops almost always. Comparing this shape
/// before and after the pass is how it knows whether the engine really changed, so an unchanged pass
/// neither dirties the engine nor asks for a whole-engine export (e2e `responsive` idle window).
/// Members compare as a set: the engine's listing order is not a change. Pure for HavenLogicTests.
enum SelfSyncEngineDiff {
    struct Shape: Equatable, Sendable {
        var circles: [String: String] = [:]
        var members: [String: Set<String>] = [:]
    }
}
