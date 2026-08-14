import Foundation
import AVFoundation
import MusicKit

/// Optional: pick an Apple Music song to sit under an imported post that has no sound of its own.
///
/// The Instagram export carries no song identity — no title, no artist, no id, only a broad
/// `music_genre` on some videos (see `InstagramArchive`). So a song cannot be *recovered*. What this
/// does instead is *suggest*: something of roughly the right genre from roughly the right time, so a
/// silent photo post from 2023 comes back with something that sounds like 2023 rather than nothing.
///
/// **It never overrides real audio.** A reel that shipped with its soundtrack keeps it — the audio is
/// baked into the video file and is the actual thing the user chose. This only fills silence, which
/// in practice means photo posts and the occasional muted clip. That check is the whole reason this
/// is safe to run over a whole archive unattended.
///
/// Apple-only by nature (MusicKit), but the *result* is a plain `TrackRef` on the post, so it syncs
/// to Android and desktop like any other song.
enum ImportSongMatcher {

    /// Does this media have an audible track already? Photos never do; a video usually does.
    ///
    /// Checked on the STAGED file rather than guessed from the extension, because "video" and "has
    /// audio" are different questions — a screen recording, a time-lapse, or a clip the user muted
    /// before posting are all silent videos that deserve a song as much as a photo does.
    static func hasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            return false
        }
        // A track can exist and still be silent-by-construction (disabled, or zero-length).
        for t in tracks {
            let enabled = (try? await t.load(.isEnabled)) ?? true
            let duration = (try? await t.load(.timeRange).duration.seconds) ?? 0
            if enabled && duration > 0.1 { return true }
        }
        return false
    }

    /// Ask once, up front, rather than per post — 300 authorization prompts is not a feature.
    static func authorize() async -> Bool {
        await MusicAuthorization.request() == .authorized
    }

    /// A song for a post created at `createdAt`, optionally steered by the export's genre string.
    ///
    /// Apple Music has no "what charted in November 2023" API — `MusicCatalogChartsRequest` only
    /// serves TODAY's charts. So era is approximated the only way the catalog allows: search the
    /// genre, then prefer releases near the post's own year. It is a suggestion, not a lookup, and
    /// the UI says so.
    static func song(for createdAt: UInt64, genre: String?) async -> TrackRefFfi? {
        let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000))
        let term = searchTerm(genre: genre, year: year)
        guard let songs = try? await catalog(term) else { return nil }
        guard let pick = nearest(songs, to: year) else { return nil }
        return TrackRefFfi(catalogId: "\(pick.id.rawValue)~", title: pick.title, artist: pick.artistName,
                           artworkUrl: "", durationMs: UInt64((pick.duration ?? 0) * 1000))
    }

    private static func catalog(_ term: String) async throws -> [MusicKit.Song] {
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        req.limit = 25
        return Array(try await req.response().songs)
    }

    /// Instagram's genre strings are taxonomy lists — "Alternative & Punk Music, Pop Punk Music,
    /// Punk Rock Music". The first entry is the broadest and the only one Apple Music reliably
    /// knows, and the trailing " Music" is noise in a search term.
    static func searchTerm(genre: String?, year: Int) -> String {
        let head = genre?.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " Music", with: "") ?? ""
        return head.isEmpty ? "\(year) hits" : "\(head) \(year)"
    }

    /// Prefer a release from the post's own year, then the closest year available. Sorting by
    /// distance rather than filtering means a genre with nothing from that exact year still returns
    /// something, instead of silently leaving the post bare.
    private static func nearest(_ songs: [MusicKit.Song], to year: Int) -> MusicKit.Song? {
        func distance(_ s: MusicKit.Song) -> Int {
            guard let d = s.releaseDate else { return 999 }
            return abs(Calendar.current.component(.year, from: d) - year)
        }
        // Catalog order already reflects popularity, so a stable sort keeps the more popular of two
        // equally-close songs ahead of the other.
        return songs.enumerated()
            .min { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }?
            .element
    }
}
