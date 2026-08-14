import Foundation

/// Reads an Instagram "Download your information" export (JSON format) and turns it into the list
/// of posts Haven should author. Parsing only — no staging, no publishing, no side effects — so the
/// import preview can show the user exactly what they are about to publish before anything happens.
///
/// Validated against a real 1.28 GB export: 372 items (203 posts, 85 reels, 84 stories) over 1129
/// media files, with every referenced file resolving inside the archive.
enum InstagramArchive {

    struct Item: Identifiable {
        enum Kind: String { case post, reel, story }
        let id = UUID()
        let kind: Kind
        /// Original capture time, MILLISECONDS (Instagram exports seconds — converted here).
        let createdAt: UInt64
        let body: String
        /// Zip entry names, in album order. A carousel keeps all its photos in ONE item.
        let mediaNames: [String]
        /// The only music signal the export carries — a genre list, and only on some videos.
        /// There is no song title or artist anywhere in an Instagram export.
        let musicGenre: String?
    }

    struct Summary {
        let items: [Item]
        let mediaCount: Int
        let totalBytes: UInt64
        let missing: [String]
        var isEmpty: Bool { items.isEmpty }
        var earliest: UInt64? { items.map(\.createdAt).min() }
        var latest: UInt64? { items.map(\.createdAt).max() }
        func count(_ k: Item.Kind) -> Int { items.filter { $0.kind == k }.count }
    }

    enum Failure: LocalizedError {
        case unreadable
        case htmlExport
        case noContent

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a readable Instagram archive. Pick the .zip exactly as it downloaded, without unzipping it first."
            case .htmlExport:
                return "That's an HTML export. Haven needs the JSON format — request a new download from Instagram and choose JSON."
            case .noContent:
                return "That archive has no posts, stories or reels in it. If you narrowed the export, request a new one covering all of your information."
            }
        }
    }

    // MARK: - Entry point

    static func read(_ url: URL) throws -> Summary {
        guard let zip = ZipReader(url: url) else { throw Failure.unreadable }
        defer { zip.close() }

        // An HTML export contains no `your_instagram_activity/media/*.json` at all. Detecting it by
        // its own shape gives the user the one instruction that actually fixes it, instead of a
        // generic "couldn't read this".
        let hasJSON = zip.entries.contains { $0.name.hasPrefix("your_instagram_activity/") && $0.name.hasSuffix(".json") }
        if !hasJSON {
            let looksHTML = zip.entries.contains { $0.name.hasSuffix(".html") }
            throw looksHTML ? Failure.htmlExport : Failure.unreadable
        }

        var items: [Item] = []
        items += posts(zip)
        items += stories(zip)
        items += reels(zip)
        // Deterministic order, not merely sorted. A resumed import skips the first N items by
        // INDEX, so two runs over the same archive must produce the same sequence — and Swift's
        // sort is not stable, so items sharing a timestamp (a carousel and a story posted in the
        // same second) could swap places between runs and be imported twice or skipped. The media
        // name breaks the tie and is unique per entry.
        items.sort {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt
                                         : ($0.mediaNames.first ?? "") < ($1.mediaNames.first ?? "")
        }
        guard !items.isEmpty else { throw Failure.noContent }

        // Resolve every referenced name against the archive up front. A missing entry means a
        // partial download, and it is far better to say so in the preview than to publish a post
        // whose photo can never arrive.
        var byName: [String: ZipReader.Entry] = [:]
        for e in zip.entries { byName[e.name] = e }
        var missing: [String] = []
        var bytes: UInt64 = 0
        var mediaCount = 0
        for i in items {
            for n in i.mediaNames {
                mediaCount += 1
                if let e = byName[n] { bytes += e.uncompressedSize } else { missing.append(n) }
            }
        }
        return Summary(items: items, mediaCount: mediaCount, totalBytes: bytes, missing: missing)
    }

    // MARK: - Sources

    /// `posts.json` is AUTHORITATIVE — deliberately not `posts_1.json`.
    ///
    /// `posts_1.json` is the easier parse and a strict SUBSET: on the validation archive it carried
    /// 851 media names against posts.json's 979, so reading it silently drops 128 photos. posts.json
    /// also carries the `Draft` flag, the only way to avoid republishing something never published.
    private static func posts(_ zip: ZipReader) -> [Item] {
        guard let raw = zip.data(named: "your_instagram_activity/media/posts.json"),
              let arr = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            var labels: [String: Any] = [:]
            for lv in entry["label_values"] as? [[String: Any]] ?? [] {
                if let l = lv["label"] as? String, l != "Media" { labels[l] = lv["value"] ?? "" }
            }
            if let draft = labels["Draft"] as? String, draft.lowercased() == "true" { return nil }

            // Album members are NESTED. Only the cover sits under the top-level "Media" label;
            // photos 2..N hang off a nested dict chain, so taking the label alone truncates every
            // carousel to one image (372 media instead of 1129 on the validation archive).
            let media = collectMedia(entry)
            guard !media.isEmpty else { return nil }
            let created = (entry["timestamp"] as? Double)
                ?? (media.first?["creation_timestamp"] as? Double) ?? 0
            guard created > 0 else { return nil }
            let body = decode(entry["title"] as? String) ?? decode(media.first?["title"] as? String) ?? ""
            return Item(kind: .post, createdAt: UInt64(created) * 1000, body: body,
                        mediaNames: media.compactMap { $0["uri"] as? String },
                        musicGenre: media.compactMap { genre($0) }.first)
        }
    }

    private static func stories(_ zip: ZipReader) -> [Item] {
        guard let raw = zip.data(named: "your_instagram_activity/media/stories.json"),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let arr = obj["ig_stories"] as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let uri = m["uri"] as? String, let ts = m["creation_timestamp"] as? Double, ts > 0 else { return nil }
            return Item(kind: .story, createdAt: UInt64(ts) * 1000, body: decode(m["title"] as? String) ?? "",
                        mediaNames: [uri], musicGenre: genre(m))
        }
    }

    private static func reels(_ zip: ZipReader) -> [Item] {
        guard let raw = zip.data(named: "your_instagram_activity/media/reels.json"),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let arr = obj["ig_reels_media"] as? [[String: Any]] else { return [] }
        var out: [Item] = []
        for r in arr {
            for m in r["media"] as? [[String: Any]] ?? [] {
                guard let uri = m["uri"] as? String, let ts = m["creation_timestamp"] as? Double, ts > 0 else { continue }
                out.append(Item(kind: .reel, createdAt: UInt64(ts) * 1000,
                                body: decode(m["title"] as? String) ?? "",
                                mediaNames: [uri], musicGenre: genre(m)))
            }
        }
        return out
    }

    // MARK: - Shape helpers

    /// Recursively gather every media dict under an entry, in first-seen order, deduped by uri.
    /// Subtitle sidecars (`.srt`/`.vtt`) are companions of a video, not post media.
    private static func collectMedia(_ any: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if let uri = d["uri"] as? String,
                   !uri.hasSuffix(".srt"), !uri.hasSuffix(".vtt"), seen.insert(uri).inserted {
                    out.append(d)
                }
                for v in d.values { walk(v) }
            } else if let a = o as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(any)
        return out
    }

    private static func genre(_ m: [String: Any]) -> String? {
        ((m["media_metadata"] as? [String: Any])?["video_metadata"] as? [String: Any])?["music_genre"] as? String
    }

    /// Instagram double-encodes captions: real UTF-8 bytes re-emitted as latin-1, so "Peña" arrives
    /// as "PeÃ±a". Round-tripping through latin-1 restores it; strings that were already clean fail
    /// the conversion and are returned untouched.
    static func decode(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return s }
        guard let bytes = s.data(using: .isoLatin1),
              let fixed = String(data: bytes, encoding: .utf8) else { return s }
        return fixed
    }
}
