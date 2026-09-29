import Foundation
import Combine

// Narrow observable slices of `FeedStore`.
//
// `FeedStore` is one ObservableObject, and anything observing it re-evaluates on EVERY publish —
// a feed rebuild, a DM snapshot, a members fill, a moderation fill, a relay ingest. The root view
// (the tab bar) and the per-media-tile sensitive-content guard observed it for one or two values
// each, so every one of those publishes re-evaluated the whole tab scaffold and every visible
// guard. These mirror just those values; `FeedStore` stays the owner and writes them.

/// The tab-bar badges and the active circle id — everything `RootView` reads.
@MainActor
final class FeedBadges: ObservableObject {
    static let shared = FeedBadges()
    @Published private(set) var unseenCircle = 0
    @Published private(set) var unseenMessages = 0
    @Published private(set) var activeCircleId = "default"

    // Change-guarded: @Published fires on every assignment, equal or not.
    func setUnseenCircle(_ v: Int) { if v != unseenCircle { unseenCircle = v } }
    func setUnseenMessages(_ v: Int) { if v != unseenMessages { unseenMessages = v } }
    func setActiveCircleId(_ v: String) { if v != activeCircleId { activeCircleId = v } }
}

/// Bumps whenever any circle's federated sensitive-media set changes. The sensitive-content guard
/// (one per media tile) observes this instead of the whole store.
@MainActor
final class SensitiveFlagsSignal: ObservableObject {
    static let shared = SensitiveFlagsSignal()
    @Published private(set) var generation: UInt64 = 0
    func bump() { generation &+= 1 }
}
