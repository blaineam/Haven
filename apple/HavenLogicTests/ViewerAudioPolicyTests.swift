import XCTest
@testable import HavenLogicTests

/// The full-screen viewer's audio rule, as a table.
///
/// The behaviour this pins down cannot be reached from a unit test any other way: it takes a post
/// with an attached song, an Apple Music subscription, a catalog round trip and a real
/// `MPMusicPlayerController` (which does not exist in the simulator at all). So the DECISION is a
/// value type and this covers every branch of it; the transport is the coordinator's job.
final class ViewerAudioPolicyTests: XCTestCase {

    /// A photo page under a song: the song plays. This is the whole point — it used to stop dead the
    /// moment a photo opened full screen.
    func testPhotoPageKeepsTheSongPlaying() {
        let p = ViewerAudioPolicy(hasSong: true, onVideoPage: false)
        XCTAssertTrue(p.musicAudible)
        XCTAssertFalse(p.videoAudible)
        XCTAssertFalse(p.musicDucked)
    }

    /// A video page whose clip carries sound takes the stage automatically — without the user having
    /// ever turned the global video-sound toggle on, which is off by default.
    func testAudibleClipTakesTheStageFromTheSong() {
        let p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                                  globalVideoSoundOn: false)
        XCTAssertTrue(p.videoAudible)
        XCTAssertFalse(p.musicAudible)
        XCTAssertTrue(p.musicDucked)   // ducked, not muted — the chip must say so
    }

    /// ...and gives it straight back on the next photo.
    func testSongReturnsOnThePhotoAfterTheVideo() {
        var p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true)
        XCTAssertFalse(p.musicAudible)
        p.onVideoPage = false
        XCTAssertTrue(p.musicAudible)
    }

    /// A SILENT video — a screen recording, a time-lapse, a clip muted before posting — has nothing
    /// to offer, so it must not silence the song on its way past.
    func testSilentClipNeverTakesTheStage() {
        let p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: false)
        XCTAssertTrue(p.musicAudible)
        XCTAssertFalse(p.videoAudible)
    }

    /// The author muted this post's video: the song is the audio they chose.
    func testAuthorMutedClipNeverTakesTheStage() {
        let p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                                  authorMutedVideo: true)
        XCTAssertTrue(p.musicAudible)
        XCTAssertFalse(p.videoAudible)
    }

    /// The music chip mutes the song and nothing else — the clip on a video page is unaffected.
    func testMusicChipMutesOnlyTheSong() {
        let p = ViewerAudioPolicy(hasSong: true, musicMuted: true, onVideoPage: true,
                                  clipCarriesAudio: true)
        XCTAssertFalse(p.musicAudible)
        XCTAssertFalse(p.musicDucked)   // muted by the user, not ducked under the clip
        XCTAssertTrue(p.videoAudible)
    }

    /// An explicit tap on the speaker outranks the automatic duck, in both directions.
    func testExplicitSpeakerChoiceOutranksTheAutomaticChoice() {
        var p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                                  explicitVideoChoice: false)
        XCTAssertFalse(p.videoAudible)
        XCTAssertTrue(p.musicAudible)    // the user muted the clip → the song comes back

        p = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                              explicitVideoChoice: true)
        XCTAssertTrue(p.videoAudible)
        XCTAssertFalse(p.musicAudible)
    }

    /// With no song — a DM attachment, a comment photo, a post with no music — the viewer falls back
    /// to the plain global toggle it has always used. Muted by default, audible once tapped.
    func testNoSongFallsBackToTheGlobalToggle() {
        var p = ViewerAudioPolicy(hasSong: false, onVideoPage: true, clipCarriesAudio: true,
                                  globalVideoSoundOn: false)
        XCTAssertFalse(p.videoAudible)
        XCTAssertFalse(p.musicAudible)
        p.globalVideoSoundOn = true
        XCTAssertTrue(p.videoAudible)
    }

    /// The app-wide mute and a live call outrank every rule above.
    func testAppMuteAndCallAudioOutrankEverything() {
        let silent = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                                       explicitVideoChoice: true, appSilent: true)
        XCTAssertFalse(silent.musicAudible)
        XCTAssertFalse(silent.videoAudible)

        let call = ViewerAudioPolicy(hasSong: true, onVideoPage: true, clipCarriesAudio: true,
                                     explicitVideoChoice: true, callActive: true)
        XCTAssertFalse(call.musicAudible)
        XCTAssertFalse(call.videoAudible)
    }

    /// The song and the clip are NEVER both audible — the doubled-audio bug this whole rule exists
    /// to avoid. Checked across every combination rather than argued about.
    func testSongAndClipAreNeverBothAudible() {
        for hasSong in [true, false] {
        for musicMuted in [true, false] {
        for onVideoPage in [true, false] {
        for clipCarriesAudio in [true, false] {
        for authorMuted in [true, false] {
        for choice in [nil, true, false] as [Bool?] {
        for global in [true, false] {
        for silent in [true, false] {
        for call in [true, false] {
            let p = ViewerAudioPolicy(hasSong: hasSong, musicMuted: musicMuted,
                                      onVideoPage: onVideoPage, clipCarriesAudio: clipCarriesAudio,
                                      authorMutedVideo: authorMuted, explicitVideoChoice: choice,
                                      globalVideoSoundOn: global, appSilent: silent, callActive: call)
            XCTAssertFalse(p.musicAudible && p.videoAudible && p.clipWantsStage,
                           "song and its own clip both audible: \(p)")
        }}}}}}}}}
    }
}
