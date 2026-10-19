import XCTest
import AVFoundation
import Combine
@testable import HavenUITestHost

/// Which post owns the audio stage, and when a video may be audible. Pure state: the players are
/// item-less `AVPlayer`s (their volume is the observable), the songs are placeholder tracks with no
/// store id (so MusicKit is never asked to play anything) and nothing here touches the network.
@MainActor
final class CallsAudioCoordinatorTests: XCTestCase {
    private var ac: AudioCoordinator { AudioCoordinator.shared }
    private var savedSilent = false
    private var savedVideoSound = true

    /// A song with no store id: `trackIds` yields nil, so MusicPlayback.play bails before MusicKit.
    private let song = TrackRefFfi(catalogId: "0", title: "Song", artist: "Artist", artworkUrl: "", durationMs: 1000)
    /// What ShazamDetector attaches for the music already INSIDE a video: attribution, not a 2nd source.
    private let credit = TrackRefFfi(catalogId: "credit:0", title: "Credit", artist: "Artist", artworkUrl: "", durationMs: 1000)

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        ac.stop()
        ac.appBecameActive()
        ac.center(nil)
        savedSilent = SettingsStore.shared.silent
        savedVideoSound = SettingsStore.shared.videoSoundOn
        SettingsStore.shared.silent = false
        SettingsStore.shared.videoSoundOn = true
        // `dataSaverActive` reads the live network path: on a constrained or expensive link (a hotspot, Low Data
        // Mode) the viewer never takes the stage and these tests fail through no fault of the coordinator. Pin
        // the link to normal so the result doesn't depend on which network the Mac happens to be on.
        LowDataMonitor.shared.debugForce(.normal)
        SettingsStore.shared.superDataSaver = false
    }

    override func tearDown() async throws {
        ac.stop()
        ac.appBecameActive()
        ac.center(nil)
        SettingsStore.shared.silent = savedSilent
        SettingsStore.shared.videoSoundOn = savedVideoSound
        LowDataMonitor.shared.debugForce(nil)
    }

    private func player(volume: Float = 0.5) -> AVPlayer {
        let p = AVPlayer()
        p.volume = volume
        return p
    }

    func testCenterOnlyPublishesWhenThePostOrItsFeedChanges() {
        var fired = 0
        let bag = ac.objectWillChange.sink { _ in fired += 1 }
        defer { bag.cancel() }
        ac.center("a", container: "circle")
        XCTAssertEqual(ac.centeredPostId, "a")
        XCTAssertEqual(ac.centeredContainer, "circle")
        let afterFirst = fired
        XCTAssertGreaterThan(afterFirst, 0)
        ac.center("a", container: "circle")
        XCTAssertEqual(fired, afterFirst, "re-reporting the same centre is not a change")
        // The same post reported by a DIFFERENT scroll container is a change: two live cards must not both claim it.
        ac.center("a", container: "profile")
        XCTAssertEqual(ac.centeredContainer, "profile")
        XCTAssertGreaterThan(fired, afterFirst)
        ac.center(nil)
        XCTAssertNil(ac.centeredPostId)
    }

    func testAVideoWithNoSongPlaysItsOwnAudioWhenTheAuthorLeftItOn() {
        let p = player()
        ac.start(postId: "v1", track: nil, video: p)
        XCTAssertEqual(ac.activePostId, "v1")
        XCTAssertTrue(ac.videoUnmuted)
        XCTAssertEqual(p.volume, 1)
        XCTAssertTrue(ac.videoShouldBeAudible(forPost: "v1"))
        XCTAssertFalse(ac.videoShouldBeAudible(forPost: "someone-else"), "only the active post may sound")
    }

    func testTheAuthorsMuteTheGlobalSilenceAndTheVideoSoundSettingAllKeepAVideoQuiet() {
        let author = player()
        ac.start(postId: "muted-by-author", track: nil, video: author, muteVideo: true)
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertEqual(author.volume, 0)
        ac.stop()

        SettingsStore.shared.silent = true
        let silent = player()
        ac.start(postId: "silent", track: nil, video: silent)
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertEqual(silent.volume, 0)
        ac.stop()
        SettingsStore.shared.silent = false

        SettingsStore.shared.videoSoundOn = false
        let off = player()
        ac.start(postId: "video-sound-off", track: nil, video: off)
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertEqual(off.volume, 0)
    }

    func testASongSilencesTheVideoButACreditOnlyTagDoesNot() {
        let withSong = player()
        ac.start(postId: "song-post", track: song, video: withSong)
        XCTAssertFalse(ac.videoUnmuted, "the attached song plays, the clip stays muted")
        XCTAssertEqual(withSong.volume, 0)
        ac.stop()

        let credited = player()
        ac.start(postId: "credit-post", track: credit, video: credited)
        XCTAssertTrue(ac.videoUnmuted, "a credit-only track names the clip's own music and must not replace it")
        XCTAssertEqual(credited.volume, 1)
    }

    func testStartingTheSamePostAgainIsANoOpAndANewPostTakesTheStage() {
        let first = player(), second = player()
        ac.start(postId: "one", track: nil, video: first)
        first.volume = 0.25
        ac.start(postId: "one", track: nil, video: first)
        XCTAssertEqual(first.volume, 0.25, "an already-active post is left exactly as it was")
        ac.start(postId: "two", track: nil, video: second)
        XCTAssertEqual(ac.activePostId, "two")
        XCTAssertEqual(first.volume, 0, "the previous post's player is silenced")
        XCTAssertEqual(second.volume, 1)
    }

    func testARegisteredPlayerIsFoundWhenTheCallerPassesNone() {
        let p = player(volume: 0)
        ac.registerVideo(p, for: "reg")
        ac.start(postId: "reg", track: nil, video: nil)
        XCTAssertEqual(p.volume, 1, "the volume lands on the RESOLVED player, not on the nil parameter")
    }

    func testAPlayerBuiltAfterTheStartInheritsTheCurrentAudibility() {
        ac.start(postId: "late", track: nil, video: nil)
        XCTAssertTrue(ac.videoUnmuted)
        let late = player(volume: 0)
        ac.registerVideo(late, for: "late")
        XCTAssertEqual(late.volume, 1, "the indicator and the player must agree the moment the player exists")
        let other = player(volume: 1)
        ac.registerVideo(other, for: "not-active")
        XCTAssertEqual(other.volume, 1, "registering a non-active post's player does not touch it")
        ac.registerVideo(nil, for: "late")
        XCTAssertEqual(late.volume, 1, "clearing the registration leaves the live player alone")
    }

    func testToggleVideoAudioFlipsTheGlobalSettingAndLiftsASilence() {
        let p = player()
        ac.start(postId: "tog", track: nil, video: p)
        ac.toggleVideoAudio()
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertFalse(SettingsStore.shared.videoSoundOn, "the choice is global so it survives scrolling and loops")
        SettingsStore.shared.silent = true
        ac.toggleVideoAudio()
        XCTAssertTrue(ac.videoUnmuted)
        XCTAssertTrue(SettingsStore.shared.videoSoundOn)
        XCTAssertFalse(SettingsStore.shared.silent, "tapping the speaker is the intent to hear it")
        ac.toggleVideoAudio()   // fades down; the fade timer is cancelled by stop() in tearDown
        XCTAssertFalse(ac.videoUnmuted)
    }

    func testSetSilentDucksNowAndBringsTheClipBackWhenLifted() {
        let p = player()
        ac.start(postId: "sil", track: nil, video: p)
        ac.setSilent(true)
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.videoUnmuted)
        ac.setSilent(false)
        XCTAssertEqual(p.volume, 1, "no song queued: the active clip's own audio comes back")
        XCTAssertTrue(ac.videoUnmuted)
    }

    func testStopClearsEverythingAndMutesThePlayer() {
        let p = player()
        ac.start(postId: "stopme", track: nil, video: p)
        ac.stop()
        XCTAssertNil(ac.activePostId)
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.mediaViewerActive)
    }

    func testBackgroundingSilencesEveryRegisteredPlayerAndBlocksAutoAudio() {
        let active = player(), other = player()
        ac.registerVideo(other, for: "bg-other")
        ac.start(postId: "bg", track: nil, video: active)
        ac.center("bg")
        XCTAssertTrue(ac.videoMayLoop(forPost: "bg"))
        ac.pauseForBackground()
        XCTAssertEqual(active.volume, 0)
        XCTAssertEqual(other.volume, 0, "not only the active player: a looping one nobody paused plays on a locked phone")
        XCTAssertFalse(ac.videoMayLoop(forPost: "bg"), "a backgrounded video may not loop")
        XCTAssertFalse(ac.videoShouldBeAudible(forPost: "bg"))
        ac.stop()
        let fresh = player()
        ac.start(postId: "bg2", track: song, video: fresh)
        XCTAssertFalse(ac.videoUnmuted)
        ac.appBecameActive()
        ac.center("bg2")
        XCTAssertTrue(ac.videoMayLoop(forPost: "bg2"))
        XCTAssertFalse(ac.videoMayLoop(forPost: "bg"), "only the centred post loops")
    }

    func testAnOverlayMutesTheClipWithoutPausingItAndReleasesTheStage() {
        let p = player()
        ac.start(postId: "ov", track: nil, video: p)
        ac.stopPostAudioForOverlay()
        XCTAssertNil(ac.activePostId)
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.videoUnmuted)
    }

    func testAComposerStoryPreviewIsNeverStompedByAnOverlay() {
        let p = player()
        ac.start(postId: "prev", track: nil, video: p)
        havenStoryPreviewActive = true
        defer { havenStoryPreviewActive = false }
        ac.stopPostAudioForOverlay()
        XCTAssertEqual(ac.activePostId, "prev", "the live composer preview owns the shared player")
        ac.silenceForCapture()
        XCTAssertEqual(p.volume, 1)
    }

    func testCaptureSilencesAndHoldsTheFeedQuietUntilTheAppIsActiveAgain() {
        let p = player()
        ac.start(postId: "cap", track: nil, video: p)
        ac.silenceForCapture()
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.videoUnmuted)
        XCTAssertFalse(ac.videoShouldBeAudible(forPost: "cap"))
        ac.appBecameActive()
    }

    func testRingingOrDialingCutsFeedAudioImmediately() {
        let p = player()
        ac.start(postId: "call", track: nil, video: p)
        ac.silenceForCall()
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.videoUnmuted)
    }

    func testAnInboundCallKeepsEveryNewVideoQuiet() async {
        _ = await Harness.feed()
        let caller = Peer(byte: 0xA1, name: "Caller")
        await caller.befriend(FeedStore.shared)
        CallManager.shared.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        defer { CallManager.shared.endCall() }
        XCTAssertTrue(CallManager.shared.callInProgress)
        let p = player()
        ac.start(postId: "during-call", track: nil, video: p)
        XCTAssertFalse(ac.videoUnmuted, "call audio owns the stage")
        XCTAssertEqual(p.volume, 0)
        XCTAssertFalse(ac.videoShouldBeAudible(forPost: "during-call"))
        ac.toggleVideoAudio()
        XCTAssertFalse(ac.videoUnmuted, "the speaker button is inert mid-call")
        ac.setSilent(false)
        XCTAssertEqual(p.volume, 0, "lifting a silence mid-call must not raise feed audio")
    }

    func testTheMediaViewerKeepsTheSongAndHandsTheStageBackOnExit() {
        let p = player()
        ac.center("view")
        ac.start(postId: "view", track: nil, video: p)
        ac.enterMediaViewer(postId: "view", track: song)
        XCTAssertTrue(ac.mediaViewerActive)
        XCTAssertEqual(ac.activePostId, "view")
        XCTAssertEqual(p.volume, 0, "the inline clip behind the cover is muted")
        // A clip looping behind the cover must not raise the song or the clip.
        ac.videoFinished()
        XCTAssertEqual(p.volume, 0)
        ac.ensureMusicPlaying()
        ac.setViewerMusicAudible(false, track: song)
        ac.exitMediaViewer(musicStaysMuted: true)
        XCTAssertFalse(ac.mediaViewerActive)
        XCTAssertEqual(ac.activePostId, "view", "still the centred post, so it keeps the stage")
    }

    func testLeavingTheViewerOnAPostThatIsNotCentredStopsItsSong() {
        ac.center("elsewhere")
        ac.enterMediaViewer(postId: "half-offscreen", track: song)
        XCTAssertEqual(ac.activePostId, "half-offscreen")
        ac.exitMediaViewer(musicStaysMuted: false)
        XCTAssertNil(ac.activePostId, "the feed re-activates whatever is actually centred")
    }

    func testAPostWithNoPlayableSongFallsBackToTheOverlayRule() {
        let p = player()
        ac.start(postId: "plain", track: nil, video: p)
        ac.enterMediaViewer(postId: "plain", track: nil)
        XCTAssertFalse(ac.mediaViewerActive)
        XCTAssertNil(ac.activePostId)
        ac.enterMediaViewer(postId: "credit", track: credit)
        XCTAssertFalse(ac.mediaViewerActive, "a credit-only track is not a song to keep")
    }

    func testVideoFinishedKeepsTheViewersUnmuteAcrossALoop() {
        let p = player()
        ac.start(postId: "loop", track: nil, video: p)
        p.volume = 0.2
        ac.videoFinished()
        XCTAssertEqual(p.volume, 1, "a looped playback stays unmuted")
        ac.toggleVideoAudio()
        ac.videoFinished()   // muted + foreground: resumes the song path (nothing queued, nothing to play)
        XCTAssertFalse(ac.videoUnmuted)
    }

    func testAScrollDrivenSongStartIsDeferredAndCancelledByTheNextPost() {
        ac.start(postId: "flick-1", track: song, video: nil)
        ac.start(postId: "flick-2", track: song, video: nil)
        XCTAssertEqual(ac.activePostId, "flick-2")
        ac.start(postId: "tap", track: song, video: nil, immediateMusic: true)
        XCTAssertEqual(ac.activePostId, "tap")
        ac.toggleMusic(postId: "tap", track: song)
        ac.toggleMusic(postId: "new-via-toggle", track: song)
        XCTAssertEqual(ac.activePostId, "new-via-toggle", "toggling a post that is not active activates it first")
    }
}
