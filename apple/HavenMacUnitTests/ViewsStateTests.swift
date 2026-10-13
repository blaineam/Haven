import XCTest
import SwiftUI
import AppKit
@testable import HavenUITestHost

/// The small, decision-bearing pieces that live beside the screens: relative timestamps, the sync
/// pill's wording, the per-device and per-circle preference stores, the profile's last-writer-wins
/// merge, pinned conversations and staged DM drafts. Each test restores what it touches so the
/// shared host process stays clean for the screens rendered after it.
@MainActor
final class ViewsStateTests: XCTestCase {
    private let d = UserDefaults.standard

    // MARK: relative time

    func testRelativeTimeBucketsGetCoarserAsPostsAge() {
        func ago(_ secs: Double) -> UInt64 { UInt64((Date().timeIntervalSince1970 - secs) * 1000) }
        XCTAssertEqual(relativeTimeShort(ago(0)), "now")
        XCTAssertEqual(relativeTimeShort(ago(4)), "now")
        XCTAssertEqual(relativeTimeShort(ago(30)), "30s")
        XCTAssertEqual(relativeTimeShort(ago(5 * 60 + 2)), "5m")
        XCTAssertEqual(relativeTimeShort(ago(3 * 3600 + 5)), "3h")
        XCTAssertEqual(relativeTimeShort(ago(2 * 86_400 + 5)), "2d")
        XCTAssertEqual(relativeTimeShort(ago(3 * 604_800 + 5)), "3w")
        XCTAssertEqual(relativeTimeShort(ago(8 * 2_592_000 + 5)), "8mo")
        // Months stop at a year: a 2023 post must read in years, never "32mo".
        XCTAssertEqual(relativeTimeShort(ago(2 * 31_536_000 + 5)), "2y")
        XCTAssertEqual(relativeTimeShort(ago(364 * 86_400)), "12mo")
        XCTAssertEqual(relativeTimeShort(ago(365 * 86_400 + 60)), "1y")
        // A timestamp from the future (clock skew) is "now", not a negative number.
        XCTAssertEqual(relativeTimeShort(ago(-600)), "now")
    }

    // MARK: sync pill

    func testSyncBadgeWordingAndColour() {
        XCTAssertEqual(SyncBadgeState.synced.color, .green)
        XCTAssertEqual(SyncBadgeState.deviceOnly.color, .red)
        XCTAssertEqual(SyncBadgeState.retrying(pending: 2).color, .orange)
        XCTAssertEqual(SyncBadgeState.sending(done: 1, total: 3).color, .yellow)
        XCTAssertEqual(SyncBadgeState.queued(pending: 4).color, .yellow)

        XCTAssertEqual(SyncBadgeState.synced.label, "Synced")
        XCTAssertEqual(SyncBadgeState.deviceOnly.label, "On this device only")
        XCTAssertEqual(SyncBadgeState.sending(done: 1, total: 3).label, "Sending 1 of 3")
        XCTAssertEqual(SyncBadgeState.queued(pending: 4).label, "Syncing 4…")
        XCTAssertEqual(SyncBadgeState.retrying(pending: 2).label, "Retrying (2 waiting)")
    }

    // MARK: SettingsStore

    func testSettingsPersistAndRestoreTheirDefaults() async {
        _ = await Harness.feed()
        let s = SettingsStore.shared
        let keys = ["haven.saveToPhotos", "haven.saveOthersToPhotos", "haven.autoOptimize", "haven.superDataSaver",
                    "haven.sendOriginal", "haven.retentionDays", "haven.keepMyPosts", "haven.identifySongsInVideos",
                    "haven.videoSoundOn", "haven.settingTs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let was = (s.saveToPhotos, s.saveOthersToPhotos, s.autoOptimize, s.superDataSaver, s.sendOriginal, s.retentionDays,
                   s.keepMyPosts, s.identifySongsInVideos, s.videoSoundOn)
        defer {
            s.saveToPhotos = was.0; s.saveOthersToPhotos = was.1; s.autoOptimize = was.2; s.superDataSaver = was.3
            s.sendOriginal = was.4; s.retentionDays = was.5; s.keepMyPosts = was.6; s.identifySongsInVideos = was.7
            s.videoSoundOn = was.8
            for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        }

        s.saveToPhotos = false; s.saveOthersToPhotos = true; s.autoOptimize = false; s.sendOriginal = true
        s.keepMyPosts = false; s.identifySongsInVideos = false; s.videoSoundOn = true; s.superDataSaver = true
        XCTAssertEqual(d.object(forKey: "haven.saveToPhotos") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "haven.saveOthersToPhotos") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "haven.autoOptimize") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "haven.sendOriginal") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "haven.keepMyPosts") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "haven.identifySongsInVideos") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "haven.videoSoundOn") as? Bool, true)
        XCTAssertTrue(s.dataSaverActive, "the manual switch alone makes the data saver bind")

        s.retentionDays = 0
        XCTAssertNil(s.retentionSecs, "0 days means keep forever")
        s.retentionDays = -3
        XCTAssertNil(s.retentionSecs, "a negative value is also forever, never a huge unsigned number")
        s.retentionDays = 30
        XCTAssertEqual(s.retentionSecs, 30 * 86_400)
        XCTAssertEqual(d.integer(forKey: "haven.retentionDays"), 30)
    }

    func testSyncedSettingsResolveByLastWriterWins() async {
        _ = await Harness.feed()
        let s = SettingsStore.shared
        let wasSave = s.saveToPhotos, wasRet = s.retentionDays
        let savedTs = d.object(forKey: "haven.settingTs.v1")
        defer {
            s.saveToPhotos = wasSave; s.retentionDays = wasRet
            if let savedTs { d.set(savedTs, forKey: "haven.settingTs.v1") } else { d.removeObject(forKey: "haven.settingTs.v1") }
        }
        // A local change stamps "now"; a remote value older than that must lose.
        s.saveToPhotos = true
        s.saveToPhotos = false
        let local = s.settingTimestamp(s.tsKeySave)
        XCTAssertGreaterThan(local, 0)
        XCTAssertFalse(s.applyRemoteBool(s.tsKeySave, true, ts: local - 1), "an older remote value is ignored")
        XCTAssertFalse(s.saveToPhotos)
        XCTAssertFalse(s.applyRemoteBool(s.tsKeySave, true, ts: local), "a tie is not newer")
        // A newer remote value wins, takes the remote timestamp, and does NOT re-stamp as a local edit.
        XCTAssertTrue(s.applyRemoteBool(s.tsKeySave, true, ts: local + 1))
        XCTAssertTrue(s.saveToPhotos)
        XCTAssertEqual(s.settingTimestamp(s.tsKeySave), local + 1)
        // Each synced key routes to its own setting; an unknown key changes nothing but still records the stamp.
        let others = s.saveOthersToPhotos, opt = s.autoOptimize
        XCTAssertTrue(s.applyRemoteBool(s.tsKeySaveOthers, !others, ts: s.settingTimestamp(s.tsKeySaveOthers) + 1))
        XCTAssertEqual(s.saveOthersToPhotos, !others)
        XCTAssertTrue(s.applyRemoteBool(s.tsKeyOpt, !opt, ts: s.settingTimestamp(s.tsKeyOpt) + 1))
        XCTAssertEqual(s.autoOptimize, !opt)
        s.saveOthersToPhotos = others; s.autoOptimize = opt

        let retTs = s.settingTimestamp(s.tsKeyRet) + 1   // minimal bump: do not leave a far-future stamp for later suites
        XCTAssertTrue(s.applyRemoteRetentionDays(90, ts: retTs))
        XCTAssertEqual(s.retentionDays, 90)
        XCTAssertEqual(s.settingTimestamp(s.tsKeyRet), retTs)
        XCTAssertFalse(s.applyRemoteRetentionDays(7, ts: retTs - 1))
        XCTAssertEqual(s.retentionDays, 90)
        XCTAssertEqual(s.settingTimestamp("haven.never.set"), 0)
    }

    // MARK: CircleSettingsStore

    func testCircleNicknamesAreLocalAndTrimmed() {
        let c = CircleSettingsStore.shared
        let id = "views-test-nick"
        defer { c.setNickname("", for: id) }
        XCTAssertNil(c.nickname(id))
        XCTAssertEqual(c.displayName(id, real: "Family"), "Family")
        c.setNickname("  The Crew \n", for: id)
        XCTAssertEqual(c.nickname(id), "The Crew")
        XCTAssertEqual(c.displayName(id, real: "Family"), "The Crew")
        c.setNickname("   ", for: id)
        XCTAssertNil(c.nickname(id), "whitespace clears the nickname")
        XCTAssertEqual(c.displayName(id, real: "Family"), "Family")
    }

    func testCircleMediaOverridesFallBackToGlobalDefaults() {
        let c = CircleSettingsStore.shared, s = SettingsStore.shared
        let id = "views-test-media"
        let was = (s.saveToPhotos, s.saveOthersToPhotos, s.autoOptimize, s.retentionDays)
        defer {
            c.clearMediaOverrides(for: id)
            s.saveToPhotos = was.0; s.saveOthersToPhotos = was.1; s.autoOptimize = was.2; s.retentionDays = was.3
        }
        s.saveToPhotos = true; s.saveOthersToPhotos = false; s.autoOptimize = true; s.retentionDays = 14
        XCTAssertFalse(c.hasMediaOverride(id))
        XCTAssertTrue(c.saveOwnToPhotos(id)); XCTAssertFalse(c.saveOthersToPhotos(id))
        XCTAssertTrue(c.autoOptimize(id)); XCTAssertEqual(c.retentionDays(id), 14)
        XCTAssertEqual(c.retentionSecs(id), 14 * 86_400)
        XCTAssertNil(c.ownOverride(id)); XCTAssertNil(c.othersOverride(id))
        XCTAssertNil(c.optimizeOverride(id)); XCTAssertNil(c.retentionOverride(id))

        c.setSaveOwn(false, for: id); c.setSaveOthers(true, for: id); c.setOptimize(false, for: id); c.setRetention(0, for: id)
        XCTAssertTrue(c.hasMediaOverride(id))
        XCTAssertFalse(c.saveOwnToPhotos(id)); XCTAssertTrue(c.saveOthersToPhotos(id))
        XCTAssertFalse(c.autoOptimize(id)); XCTAssertEqual(c.retentionDays(id), 0)
        XCTAssertNil(c.retentionSecs(id), "this circle keeps forever even though the default is 14 days")
        XCTAssertEqual(c.ownOverride(id), false); XCTAssertEqual(c.othersOverride(id), true)
        XCTAssertEqual(c.optimizeOverride(id), false); XCTAssertEqual(c.retentionOverride(id), 0)
        XCTAssertEqual((d.dictionary(forKey: "haven.circle.saveOwn") as? [String: Bool])?[id], false)

        c.setSaveOwn(nil, for: id)
        XCTAssertTrue(c.saveOwnToPhotos(id), "clearing one override returns that setting to the global default")
        XCTAssertTrue(c.hasMediaOverride(id), "the others are still overridden")
        c.clearMediaOverrides(for: id)
        XCTAssertFalse(c.hasMediaOverride(id))
        XCTAssertEqual(c.retentionDays(id), 14)
    }

    func testLockedCirclesNeverReachSpotlightOrTheUnlockSet() {
        let c = CircleSettingsStore.shared
        let open = "views-test-open", locked = "views-test-locked"
        defer { c.setSpotlight(false, for: open); c.setSpotlight(false, for: locked); c.setBiometric(false, for: locked) }
        XCTAssertFalse(c.spotlightEnabled(open))
        c.setSpotlight(true, for: open)
        c.setSpotlight(true, for: locked)
        XCTAssertEqual(Set(c.spotlightCircleIds).intersection([open, locked]), [open, locked])
        c.setBiometric(true, for: locked)
        XCTAssertTrue(c.biometricRequired(locked))
        XCTAssertFalse(c.spotlightCircleIds.contains(locked), "a locked circle must never leak into the system search index")
        XCTAssertTrue(c.spotlightCircleIds.contains(open))

        // The gate: required + not yet unlocked = locked; relock puts it back.
        XCTAssertTrue(BiometricGate.shared.isLocked(locked))
        XCTAssertFalse(BiometricGate.shared.isLocked(open))
        BiometricGate.shared.relockAll()
        XCTAssertTrue(BiometricGate.shared.unlocked.isEmpty)
        c.setBiometric(false, for: locked)
        XCTAssertFalse(BiometricGate.shared.isLocked(locked))
        _ = CircleSettingsStore.biometricsAvailable   // must answer without prompting
    }

    // MARK: ProfileStore

    func testProfileMergesRemoteFieldsByTimestamp() async {
        _ = await Harness.feed()
        let p = ProfileStore.shared
        let was = (p.displayName, p.emoji, p.bio, p.link)
        defer { p.displayName = was.0; p.emoji = was.1; p.bio = was.2; p.link = was.3 }
        // Other suites in this process may already have applied remote values with later stamps, so every
        // timestamp here is built from the field's CURRENT stamp: strictly newer, or strictly older.
        func newer(_ field: String, by ms: UInt64 = 1) -> UInt64 {
            max(p.fieldTimestamp(field), UInt64(Date().timeIntervalSince1970 * 1000)) + ms
        }
        p.displayName = "Local Name"
        let t = p.fieldTimestamp("name")
        XCTAssertGreaterThan(t, 0, "a local edit stamps the field")

        XCTAssertFalse(p.applyRemote("name", string: "Old Remote", ts: t - 1))
        XCTAssertEqual(p.displayName, "Local Name")
        let nameTs = newer("name")
        XCTAssertTrue(p.applyRemote("name", string: "New Remote", ts: nameTs))
        XCTAssertEqual(p.displayName, "New Remote")
        XCTAssertEqual(p.fieldTimestamp("name"), nameTs, "the remote value keeps the remote timestamp, not a fresh local one")

        let bio1 = newer("bio")
        XCTAssertTrue(p.applyRemote("bio", string: "hello", ts: bio1))
        XCTAssertEqual(p.bio, "hello")
        XCTAssertFalse(p.applyRemote("bio", string: "stale", ts: bio1), "an equal stamp is not newer")
        XCTAssertEqual(p.bio, "hello")
        XCTAssertTrue(p.applyRemote("bio", string: "", ts: bio1 + 1), "a deliberate clear is allowed to win when newer")
        XCTAssertEqual(p.bio, "")
        XCTAssertTrue(p.applyRemote("link", string: "example.org", ts: newer("link")))
        XCTAssertEqual(p.link, "example.org")
        let emoji = p.emoji
        XCTAssertTrue(p.applyRemote("emoji", string: "", ts: newer("emoji")))
        XCTAssertEqual(p.emoji, emoji, "an empty emoji never replaces the default one")
        XCTAssertTrue(p.applyRemote("emoji", string: "🦊", ts: newer("emoji")))
        XCTAssertEqual(p.emoji, "🦊")
        XCTAssertTrue(ProfileStore.avatarChoices.contains("🦊"))
        XCTAssertEqual(Set(ProfileStore.avatarChoices).count, ProfileStore.avatarChoices.count)
    }

    func testProfileAvatarRoundTripsThroughTheSignedCard() async throws {
        _ = await Harness.feed()
        let p = ProfileStore.shared
        let before = p.avatar
        defer { p.setAvatar(before) }
        p.setAvatar(nil)
        XCTAssertEqual(p.avatarBase64, "", "no photo, nothing rides the card")

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 400, height: 300)); image.addRepresentation(rep)
        p.setAvatar(image)
        XCTAssertNotNil(p.avatar)
        let b64 = p.avatarBase64
        XCTAssertFalse(b64.isEmpty)
        XCTAssertEqual(b64, p.avatarBase64, "the encoded card photo is cached")
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        // 192 points: on a Retina Mac that is up to 384 pixels. Either way far smaller than the 400px original.
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        XCTAssertLessThanOrEqual(max(decoded.pixelsWide, decoded.pixelsHigh), 192 * scale, "the card photo is downscaled")

        // A remote clear removes the photo; an older one is ignored; a remote photo is adopted without being re-stamped.
        let t = max(p.fieldTimestamp("avatar"), UInt64(Date().timeIntervalSince1970 * 1000))
        XCTAssertFalse(p.applyRemoteAvatar(base64: "", ts: p.fieldTimestamp("avatar")), "an equal stamp is not newer")
        XCTAssertNotNil(p.avatar)
        XCTAssertTrue(p.applyRemoteAvatar(base64: "", ts: t + 1))
        XCTAssertNil(p.avatar)
        XCTAssertTrue(p.applyRemoteAvatar(base64: b64, ts: t + 2))
        XCTAssertNotNil(p.avatar)
        XCTAssertEqual(p.fieldTimestamp("avatar"), t + 2)
        XCTAssertTrue(p.applyRemoteAvatar(base64: "not base64 at all!!", ts: t + 3), "garbage is tolerated and leaves the photo alone")
        XCTAssertNotNil(p.avatar)
    }

    // MARK: pinned conversations and staged drafts

    func testPinnedConversationsCapAtSixAndKeepTheirOrder() {
        let pins = DMPinStore.shared
        let was = pins.pinned
        defer { for id in pins.pinned { pins.remove(id) }; for id in was { pins.toggle(id) } }
        for id in pins.pinned { pins.remove(id) }
        XCTAssertFalse(pins.isFull)
        let ids = (1...7).map { "dm:pin\($0)" }
        for id in ids { pins.toggle(id) }
        XCTAssertEqual(pins.pinned, Array(ids.prefix(6)), "a seventh pin is refused; order is pin order")
        XCTAssertTrue(pins.isFull)
        XCTAssertFalse(pins.isPinned(ids[6]))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "haven.dm.pinned"), pins.pinned)

        pins.toggle(ids[1])   // unpin
        XCTAssertFalse(pins.isPinned(ids[1]))
        XCTAssertFalse(pins.isFull)
        pins.remove("dm:never-pinned")   // harmless
        pins.setOrder([ids[5], ids[0], "dm:stranger"])
        XCTAssertEqual(pins.pinned, [ids[5], ids[0], ids[2], ids[3], ids[4]],
                       "the chosen order leads, unknown ids are dropped, unlisted pins keep their place")
    }

    func testStagedDMDraftsAndScrollTargetsAreTakenOnce() {
        let drafts = DMDraftStore.shared
        drafts.stage(circleId: "dm:abc", text: "look at this https://example.org")
        XCTAssertEqual(drafts.openThread, "dm:abc")
        XCTAssertEqual(drafts.takeDraft("dm:abc"), "look at this https://example.org")
        XCTAssertNil(drafts.takeDraft("dm:abc"), "the composer owns the text after it takes it")
        XCTAssertNil(drafts.takeDraft("dm:other"))
        drafts.stageScroll(circleId: "dm:abc", messageId: "m42")
        XCTAssertEqual(drafts.takeScrollTarget("dm:abc"), "m42")
        XCTAssertNil(drafts.takeScrollTarget("dm:abc"))
        drafts.openThread = nil
    }
}
