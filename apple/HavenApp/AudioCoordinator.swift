import SwiftUI
import AVFoundation
import MediaPlayer
import MusicKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Coordinates a post's audio: the attached song plays while its video stays muted.
/// When the viewer unmutes the video, the music fades down as the video fades up — a
/// clean crossfade — and back the other way on re-mute. Only one post is audible at a
/// time. No network, no data: this is local playback only.
@MainActor
final class AudioCoordinator: ObservableObject {
    static let shared = AudioCoordinator()

    private init() {
        // macOS has no scenePhase .background for a normal window; the reliable "user switched away from
        // Haven" signal is NSApplication.didResignActive (and it does NOT fire for in-app sheets/panels,
        // so it won't stop music in normal use). These observers live for the app's lifetime (singleton).
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioCoordinator.shared.pauseForBackground() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioCoordinator.shared.appBecameActive() }
        }
        #endif
        // Start from the REAL application state. A background LAUNCH (bg fetch / silent push after a
        // termination) builds the feed with no scenePhase change ever firing, so the default `false`
        // let a "centered" top post start its song out of nowhere — audibly, in the middle of the
        // night, because the system music player plays even when the app isn't on screen.
        #if os(macOS)
        backgrounded = !NSApplication.shared.isActive
        #else
        backgrounded = UIApplication.shared.applicationState != .active
        #endif
    }

    @Published private(set) var activePostId: String?
    @Published private(set) var videoUnmuted = false
    /// The post currently centered in the feed (drives which post's media plays).
    @Published var centeredPostId: String?

    /// Called by the feed as the user scrolls; one post is "centered" at a time.
    func center(_ id: String?) {
        guard centeredPostId != id else { return }
        centeredPostId = id
    }

    private var videoPlayer: AVPlayer?
    private var activeTrack: TrackRefFfi?   // the active post's song, so unmute can (re)start it
    private var fadeTimer: Timer?
    /// True while the app is backgrounded. Blocks AUTO playback — the system music player keeps playing
    /// even when the app is in the background, so a background feed refresh re-running syncPlayback was
    /// kicking the post song on out of nowhere. Cleared when the app is active again.
    private var backgrounded = false
    /// A call is ringing/connecting/in progress — call audio owns the stage: no post music, no video
    /// audio (videos keep playing, muted). Computed live so scroll-driven start() can't race a flag.
    private var callActive: Bool { CallManager.shared.callInProgress }

    /// Begin a post's audio. If a song is attached it plays (video muted). Otherwise the
    /// author's `muteVideo` choice decides: off → the video plays its own audio; on → silent.
    func start(postId: String, track: TrackRefFfi?, video: AVPlayer?, muteVideo: Bool = false) {
        if activePostId == postId { return }
        stop()
        activePostId = postId
        videoPlayer = video
        activeTrack = track
        // Play the video's own audio only when there's no song, the author left it unmuted, the app
        // isn't globally silenced, AND the viewer's GLOBAL video-sound toggle is on. The global flag is
        // what makes "tap one video to unmute" carry to every other video + survive loops.
        let playVideoAudio = (track == nil) && !muteVideo && !SettingsStore.shared.silent
            && SettingsStore.shared.videoSoundOn && !callActive
        videoUnmuted = playVideoAudio
        video?.volume = playVideoAudio ? 1 : 0
        // Never auto-start the song while backgrounded (the system music player would play it audibly even
        // though the app isn't on screen). It resumes via ensureMusicPlaying when we're foreground again.
        if let track, !backgrounded { MusicPlayback.shared.play(track) }
    }

    /// Tap-to-toggle a music-only post's sound (pause/resume the song).
    func toggleMusic(postId: String, track: TrackRefFfi?) {
        guard !SettingsStore.shared.silent, !callActive else { return }
        if activePostId != postId { start(postId: postId, track: track, video: nil) }
        if MusicPlayback.shared.isPlaying { MusicPlayback.shared.duck() }
        else { MusicPlayback.shared.resume() }
    }

    /// Globally mute/unmute the app (post music + video audio).
    func setSilent(_ on: Bool) {
        if on {
            MusicPlayback.shared.duck()
            videoPlayer?.volume = 0
            videoUnmuted = false
        } else {
            guard !callActive else { return }   // un-silencing mid-call must not raise feed audio
            // Unmute must actually (re)start audio for the active post — not just flip a flag.
            // If a song is attached but was never queued (play() bails while silent), there's
            // nothing to resume — so reissue a full play of the active post's track.
            if let track = activeTrack {
                MusicPlayback.shared.play(track)
            } else if MusicPlayback.shared.current != nil {
                MusicPlayback.shared.restartCurrent()
            } else {
                // No song: bring the active post's video audio back up (author/global allowing).
                videoPlayer?.volume = 1
                videoUnmuted = videoPlayer != nil
            }
        }
    }

    /// Toggle the video's own audio, crossfading against the song. Flips the GLOBAL video-sound toggle
    /// so the choice applies to every video and persists across loops/scroll (not just this one post).
    func toggleVideoAudio() {
        guard !SettingsStore.shared.silent, !callActive else { return }   // app muted / call owns audio
        let on = !videoUnmuted
        videoUnmuted = on
        SettingsStore.shared.videoSoundOn = on
        if on {
            MusicPlayback.shared.duck()              // music down
            fadeVideo(to: 1.0)                        // video up
        } else {
            fadeVideo(to: 0.0)                        // video down
            MusicPlayback.shared.unduck()             // music back up
        }
    }

    func stop() {
        fadeTimer?.invalidate(); fadeTimer = nil
        videoPlayer?.volume = 0
        videoPlayer = nil
        MusicPlayback.shared.stop()
        activePostId = nil
        videoUnmuted = false
    }

    /// Pause all feed playback when the app backgrounds (a call's own audio is separate).
    func pauseForBackground() {
        backgrounded = true
        MusicPlayback.shared.duck()
        videoPlayer?.pause()
    }

    /// A call just started (outgoing dial or incoming ring): cut feed audio IMMEDIATELY so the
    /// ring/voice never competes with a post song or a video's soundtrack. Videos keep playing,
    /// muted. While `callActive` is true every raise-audio path above is also gated, so nothing
    /// can sneak the volume back up mid-call; normal rules resume once the call tears down.
    func silenceForCall() {
        fadeTimer?.invalidate(); fadeTimer = nil
        MusicPlayback.shared.duck()
        videoPlayer?.volume = 0
        videoUnmuted = false
    }

    /// App returned to the foreground — allow playback again (it only actually resumes on the feed, via
    /// ensureMusicPlaying / a centered post, so returning to a non-feed tab stays silent).
    func appBecameActive() { backgrounded = false }

    /// Make sure the active post's song is playing — unless the viewer is intentionally
    /// listening to a video's audio. Called when a post stays active (e.g. after a video
    /// paused it) so the music resumes as long as you haven't scrolled past the post.
    func ensureMusicPlaying() {
        guard !videoUnmuted, !SettingsStore.shared.silent, !backgrounded else { return }
        MusicPlayback.shared.resume()
    }

    /// The active post's video looped. KEEP the viewer's unmute choice across the loop (it used to
    /// force re-mute every loop, which is exactly the bug). Only bring the song back if the video is
    /// muted; if the viewer is listening to the video, leave it up and don't resume the song.
    func videoFinished() {
        if videoUnmuted {
            videoPlayer?.volume = 1   // stay unmuted on the looped playback
        } else if !backgrounded {
            MusicPlayback.shared.resume()
        }
    }

    private func fadeVideo(to target: Float, duration: TimeInterval = 0.45) {
        guard let player = videoPlayer else { return }
        fadeTimer?.invalidate()
        let steps = 18
        let start = player.volume
        var i = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { timer in
            i += 1
            let p = Float(i) / Float(steps)
            Task { @MainActor in player.volume = start + (target - start) * p }
            if i >= steps { timer.invalidate() }
        }
    }
}

#if os(macOS)
/// Native macOS Apple Music playback via MusicKit's `ApplicationMusicPlayer` (macOS 14+).
/// `MPMusicPlayerController`/`MPMediaItem` don't exist on macOS, so we can only play CATALOG
/// songs (a store id) — there's no local-library item lookup. A shared song carries only its
/// catalog id; we queue that id so it plays through the viewer's own Apple Music subscription.
/// When the viewer unmutes a post's video the song pauses (duck) and resumes (unduck) on re-mute.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?
    private let player = ApplicationMusicPlayer.shared
    private var authed = false

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    /// NEVER start playback unless Haven is frontmost. Starting the player steals playback focus
    /// from whatever the user is listening to, and a background launch can reach these paths with
    /// no scenePhase change ever having fired.
    private var appFrontmost: Bool { NSApplication.shared.isActive }
    /// NEVER start/resume while a call is ringing/connecting/live — call audio has priority. Gated
    /// here at the chokepoint so every entry point (feed, stories, DM song pill) is covered.
    private var callActive: Bool { CallManager.shared.callInProgress }

    func play(_ track: TrackRefFfi) {
        current = track
        guard appFrontmost else { return }                   // background wake must stay silent
        guard !SettingsStore.shared.silent else { return }   // app is muted
        guard !callActive else { return }                    // call audio owns the stage
        let ids = trackIds(track.catalogId)
        // macOS can only play catalog songs — a store id is required (no MPMediaItem library).
        guard let store = ids.store, !store.isEmpty else { return }
        // Stories can pick a section of the song (start offset encoded as "start:<ms>").
        let startSeconds: Double? = {
            guard track.artworkUrl.hasPrefix("start:"),
                  let ms = Double(track.artworkUrl.dropFirst(6)), ms > 0 else { return nil }
            return ms / 1000
        }()
        Task { @MainActor in
            // Catalog playback needs MusicKit authorization (requested once).
            if !authed {
                _ = await MusicAuthorization.request()
                authed = true
            }
            // Bail if the track was swapped out or the app muted while we awaited auth.
            guard current?.catalogId == track.catalogId, !SettingsStore.shared.silent else { return }
            do {
                let id = MusicItemID(store)
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
                request.limit = 1
                let response = try await request.response()
                guard let song = response.items.first else { return }
                // Re-check after the network fetch; user may have scrolled / muted.
                guard current?.catalogId == track.catalogId, !SettingsStore.shared.silent else { return }
                player.queue = [song]
                try await player.play()
                if let startSeconds {
                    player.playbackTime = startSeconds
                }
            } catch {
                // Never crash on playback failure (no subscription, offline, etc.).
            }
        }
    }
    func duck() {
        if player.state.playbackStatus == .playing { player.pause() }
    }
    func unduck() {
        guard current != nil, appFrontmost, !callActive else { return }
        Task { @MainActor in try? await player.play() }
    }
    /// Resume the queued song if it's paused (e.g. a video had ducked it).
    func resume() {
        guard current != nil, appFrontmost, !callActive, player.state.playbackStatus != .playing else { return }
        Task { @MainActor in try? await player.play() }
    }
    /// Fully (re)queue and start the current track — used on unmute, when the song may never
    /// have been queued (play() bails while the app is silent, so resume() has nothing to do).
    func restartCurrent() {
        guard let track = current else { return }
        play(track)
    }
    func stop() {
        current = nil
        if player.state.playbackStatus == .playing { player.pause() }
    }
}
#else
/// Real Apple Music playback via the system music player. A shared song carries only
/// its catalog id; we queue that id so it plays through the viewer's own Apple Music
/// subscription — Haven never moves audio. When the viewer unmutes a post's video the
/// song pauses (duck) and resumes (unduck) on re-mute.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?
    private let player = MPMusicPlayerController.applicationMusicPlayer
    private var authed = false
    var isPlaying: Bool { player.playbackState == .playing }

    /// NEVER issue playback unless the app is frontmost. The application music player is a
    /// SYSTEM-side agent: it plays audibly even when Haven is backgrounded, and starting it steals
    /// playback focus from the user's own Music session (CarPlay pausing mid-drive; the 3am
    /// top-post song). A background LAUNCH (bg fetch / silent push) never fires a scenePhase
    /// change, so AudioCoordinator's backgrounded flag alone can't cover it — gate the chokepoint.
    private var appFrontmost: Bool { UIApplication.shared.applicationState == .active }
    /// NEVER start/resume while a call is ringing/connecting/live — call audio has priority. Gated
    /// here at the chokepoint so every entry point (feed, stories, DM song pill) is covered.
    private var callActive: Bool { CallManager.shared.callInProgress }

    func play(_ track: TrackRefFfi) {
        current = track
        guard appFrontmost else { return }                   // background wake must stay silent
        guard !SettingsStore.shared.silent else { return }   // app is muted
        guard !callActive else { return }                    // call audio owns the stage
        let ids = trackIds(track.catalogId)
        guard ids.store != nil || ids.pid != nil else { return }
        // Playing through the system player needs media-library authorization.
        if !authed {
            MPMediaLibrary.requestAuthorization { _ in }
            authed = true
        }
        if let pid = ids.pid, let item = librarySong(pid) {
            // Exact local song — queue just this one item (no neighbors).
            player.setQueue(with: MPMediaItemCollection(items: [item]))
        } else if let store = ids.store {
            // Catalog song (e.g. on a recipient's device) — queue by store id.
            player.setQueue(with: [store])
        } else {
            return
        }
        player.play()
        // Stories can pick a section of the song (start offset encoded as "start:<ms>").
        if track.artworkUrl.hasPrefix("start:"), let ms = Double(track.artworkUrl.dropFirst(6)), ms > 0 {
            player.currentPlaybackTime = ms / 1000
        }
    }
    func duck() {
        if player.playbackState == .playing { player.pause() }
    }
    func unduck() {
        if current != nil, appFrontmost, !callActive { player.play() }
    }
    /// Resume the queued song if it's paused (e.g. a video had ducked it).
    func resume() {
        guard current != nil, appFrontmost, !callActive, player.playbackState != .playing else { return }
        player.play()
    }
    /// Fully (re)queue and start the current track — used on unmute, when the song may never
    /// have been queued (play() bails while the app is silent, so resume() has nothing to do).
    func restartCurrent() {
        guard let track = current else { return }
        play(track)
    }
    func stop() {
        current = nil
        if player.playbackState == .playing { player.pause() }
    }
}
#endif
