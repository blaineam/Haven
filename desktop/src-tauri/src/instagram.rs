//! Reads an Instagram "Download your information" export (JSON format) and turns it into the list
//! of posts Haven should author. Parsing only — no staging, no publishing, no side effects — so the
//! import preview can show the user exactly what they are about to publish before anything happens.
//!
//! Apple parity: `apple/HavenApp/InstagramArchive.swift`. Android parity:
//! `android/…/core/InstagramArchive.kt`. The traps encoded here were each found against a real
//! 1.28 GB export and cost a debugging cycle, so they are restated rather than rediscovered.
//!
//! Validated against that export: 372 items (203 posts, 85 reels, 84 stories) over 1129 media
//! files, with every referenced file resolving inside the archive.
//!
//! Like Android (and unlike Apple, which carries its own reader) this needs no bespoke ZIP code:
//! the `zip` crate is random-access over a `File`, so an entry is read by seeking to it rather than
//! by holding a 1.28 GB archive in memory.

use std::collections::HashSet;
use std::fs::File;
use std::path::Path;

use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Post,
    Reel,
    Story,
}

#[derive(Clone, Debug, Serialize)]
pub struct Item {
    pub kind: Kind,
    /// Original capture time in MILLISECONDS (Instagram exports SECONDS — converted here).
    pub created_at: u64,
    pub body: String,
    /// Zip entry names, in album order. A carousel keeps all its photos in ONE item.
    pub media_names: Vec<String>,
    /// The only music signal the export carries — a genre list, and only on some videos. There is
    /// no song title or artist anywhere in an Instagram export.
    pub music_genre: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Summary {
    pub items: Vec<Item>,
    pub media_count: usize,
    pub total_bytes: u64,
    /// Referenced entry names that are NOT in the archive — a partial download. Far better to say
    /// so in the preview than to publish a post whose photo can never arrive.
    pub missing: Vec<String>,
}

impl Summary {
    pub fn count(&self, k: Kind) -> usize {
        self.items.iter().filter(|i| i.kind == k).count()
    }
    pub fn earliest(&self) -> Option<u64> {
        self.items.iter().map(|i| i.created_at).min()
    }
    pub fn latest(&self) -> Option<u64> {
        self.items.iter().map(|i| i.created_at).max()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Unreadable,
    HtmlExport,
    NoContent,
}

impl Failure {
    /// The one instruction that actually fixes each case. Apple `InstagramArchive.Failure` parity —
    /// the desktop UI shows these verbatim.
    pub fn message(self) -> &'static str {
        match self {
            Failure::Unreadable => "That file isn't a readable Instagram archive. Pick the .zip exactly as it downloaded, without unzipping it first.",
            Failure::HtmlExport => "That's an HTML export. Haven needs the JSON format — request a new download from Instagram and choose JSON.",
            Failure::NoContent => "That archive has no posts, stories or reels in it. If you narrowed the export, request a new one covering all of your information.",
        }
    }
}

/// Random-access reader over the archive, kept open across the whole import so a 372-item run does
/// not reopen (and re-scan the central directory of) a 1.28 GB zip 372 times.
pub struct Archive {
    zip: zip::ZipArchive<File>,
}

impl Archive {
    pub fn open(path: &Path) -> Result<Self, Failure> {
        let file = File::open(path).map_err(|_| Failure::Unreadable)?;
        let zip = zip::ZipArchive::new(file).map_err(|_| Failure::Unreadable)?;
        Ok(Self { zip })
    }

    pub fn names(&self) -> Vec<String> {
        self.zip.file_names().map(|s| s.to_string()).collect()
    }

    /// Uncompressed size of every entry, by name — what the preview's byte total is summed from.
    pub fn sizes(&mut self) -> std::collections::HashMap<String, u64> {
        let mut out = std::collections::HashMap::new();
        for i in 0..self.zip.len() {
            if let Ok(f) = self.zip.by_index(i) {
                out.insert(f.name().to_string(), f.size());
            }
        }
        out
    }

    pub fn read(&mut self, name: &str) -> Option<Vec<u8>> {
        use std::io::Read;
        let mut f = self.zip.by_name(name).ok()?;
        let mut buf = Vec::with_capacity(f.size().min(256 * 1024 * 1024) as usize);
        f.read_to_end(&mut buf).ok()?;
        Some(buf)
    }

    /// Stream one entry straight to `dest`, never holding it in memory.
    ///
    /// This is how videos leave the archive. A reel can be hundreds of megabytes and the sealing
    /// path already has an off-heap file→file variant (`add_local_media_file`), so decompressing
    /// into a `Vec` first would be the single largest allocation of the whole import, for bytes
    /// that go straight back out to disk.
    pub fn extract_to(&mut self, name: &str, dest: &Path) -> bool {
        let Ok(mut entry) = self.zip.by_name(name) else { return false };
        let Ok(mut out) = File::create(dest) else { return false };
        std::io::copy(&mut entry, &mut out).is_ok()
    }

    fn json(&mut self, name: &str) -> Option<Value> {
        let raw = self.read(name)?;
        serde_json::from_slice(&raw).ok()
    }
}

// ---- Entry point -----------------------------------------------------------------------------

pub fn read(path: &Path) -> Result<Summary, Failure> {
    let mut zip = Archive::open(path)?;
    let names = zip.names();

    // An HTML export contains no `your_instagram_activity/media/*.json` at all. Detecting it by its
    // own shape gives the user the one instruction that fixes it, instead of a generic "couldn't
    // read this".
    let has_json = names
        .iter()
        .any(|n| n.starts_with("your_instagram_activity/") && n.ends_with(".json"));
    if !has_json {
        return Err(if names.iter().any(|n| n.ends_with(".html")) {
            Failure::HtmlExport
        } else {
            Failure::Unreadable
        });
    }

    let mut items = Vec::new();
    items.extend(posts(&mut zip));
    items.extend(stories(&mut zip));
    items.extend(reels(&mut zip));
    items.retain(|i: &Item| i.created_at > 0 && !i.media_names.is_empty());

    // Deterministic order, not merely sorted. A resumed import skips the first N items by INDEX, so
    // two runs over the same archive must produce the same sequence — items sharing a timestamp (a
    // carousel and a story posted in the same second) must not be able to swap places between runs
    // and be imported twice or skipped. The media name breaks the tie and is unique per entry.
    items.sort_by(|a, b| {
        a.created_at
            .cmp(&b.created_at)
            .then_with(|| first_name(a).cmp(first_name(b)))
    });
    if items.is_empty() {
        return Err(Failure::NoContent);
    }

    // Resolve every referenced name against the archive up front.
    let sizes = zip.sizes();
    let mut missing = Vec::new();
    let mut total_bytes = 0u64;
    let mut media_count = 0usize;
    for i in &items {
        for n in &i.media_names {
            media_count += 1;
            match sizes.get(n) {
                Some(b) => total_bytes += *b,
                None => missing.push(n.clone()),
            }
        }
    }
    Ok(Summary { items, media_count, total_bytes, missing })
}

fn first_name(i: &Item) -> &str {
    i.media_names.first().map(|s| s.as_str()).unwrap_or("")
}

// ---- Sources ---------------------------------------------------------------------------------

/// `posts.json` is AUTHORITATIVE — deliberately not `posts_1.json`.
///
/// `posts_1.json` is the easier parse and a strict SUBSET: on the validation archive it carried 851
/// media names against posts.json's 979, so reading it silently drops 128 photos. posts.json also
/// carries the `Draft` flag, the only way to avoid republishing something never published.
fn posts(zip: &mut Archive) -> Vec<Item> {
    let Some(Value::Array(arr)) = zip.json("your_instagram_activity/media/posts.json") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in &arr {
        if is_draft(entry) {
            continue;
        }
        // Album members are NESTED. Only the carousel COVER sits under the top-level "Media" label;
        // photos 2..N hang off a nested dict chain, so taking the label alone truncates every
        // carousel to one image (372 media instead of 1129 on the validation archive).
        let media = collect_media(entry);
        if media.is_empty() {
            continue;
        }
        let created = num(entry.get("timestamp"))
            .filter(|t| *t > 0)
            .or_else(|| num(media[0].get("creation_timestamp")))
            .unwrap_or(0);
        if created <= 0 {
            continue;
        }
        let body = {
            let top = ig_text(entry.get("title"));
            if top.is_empty() { ig_text(media[0].get("title")) } else { top }
        };
        out.push(Item {
            kind: Kind::Post,
            created_at: created as u64 * 1000,
            body,
            media_names: media.iter().filter_map(|m| uri(m)).collect(),
            music_genre: media.iter().find_map(|m| genre(m)),
        });
    }
    out
}

fn stories(zip: &mut Archive) -> Vec<Item> {
    let Some(obj) = zip.json("your_instagram_activity/media/stories.json") else {
        return Vec::new();
    };
    let Some(Value::Array(arr)) = obj.get("ig_stories") else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|m| {
            let uri = uri(m)?;
            let ts = num(m.get("creation_timestamp")).filter(|t| *t > 0)?;
            Some(Item {
                kind: Kind::Story,
                created_at: ts as u64 * 1000,
                body: ig_text(m.get("title")),
                media_names: vec![uri],
                music_genre: genre(m),
            })
        })
        .collect()
}

fn reels(zip: &mut Archive) -> Vec<Item> {
    let Some(obj) = zip.json("your_instagram_activity/media/reels.json") else {
        return Vec::new();
    };
    let Some(Value::Array(arr)) = obj.get("ig_reels_media") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for r in arr {
        let Some(Value::Array(media)) = r.get("media") else { continue };
        for m in media {
            let (Some(uri), Some(ts)) = (uri(m), num(m.get("creation_timestamp")).filter(|t| *t > 0))
            else {
                continue;
            };
            out.push(Item {
                kind: Kind::Reel,
                created_at: ts as u64 * 1000,
                body: ig_text(m.get("title")),
                media_names: vec![uri],
                music_genre: genre(m),
            });
        }
    }
    out
}

// ---- Shape helpers ---------------------------------------------------------------------------

/// The `Draft` flag lives in `label_values`, alongside the "Media" label the album walk ignores.
fn is_draft(entry: &Value) -> bool {
    let Some(Value::Array(lvs)) = entry.get("label_values") else { return false };
    lvs.iter().any(|lv| {
        lv.get("label").and_then(Value::as_str) == Some("Draft")
            && lv
                .get("value")
                .and_then(Value::as_str)
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false)
    })
}

/// Recursively gather every media object under an entry, in first-seen order, deduped by uri.
/// Subtitle sidecars (`.srt`/`.vtt`) are companions of a video, not post media.
pub fn collect_media(root: &Value) -> Vec<&Value> {
    let mut out = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    fn walk<'a>(v: &'a Value, out: &mut Vec<&'a Value>, seen: &mut HashSet<&'a str>) {
        match v {
            Value::Object(map) => {
                if let Some(u) = map.get("uri").and_then(Value::as_str) {
                    if !u.is_empty()
                        && !u.ends_with(".srt")
                        && !u.ends_with(".vtt")
                        && seen.insert(u)
                    {
                        out.push(v);
                    }
                }
                for child in map.values() {
                    walk(child, out, seen);
                }
            }
            Value::Array(items) => {
                for child in items {
                    walk(child, out, seen);
                }
            }
            _ => {}
        }
    }
    walk(root, &mut out, &mut seen);
    out
}

fn uri(m: &Value) -> Option<String> {
    m.get("uri")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn num(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        _ => None,
    }
}

fn genre(m: &Value) -> Option<String> {
    m.get("media_metadata")?
        .get("video_metadata")?
        .get("music_genre")?
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Instagram double-encodes captions: real UTF-8 bytes re-emitted as latin-1, so "Peña" arrives as
/// "PeÃ±a". Round-tripping through latin-1 restores it; a string that was already clean either has
/// a scalar above U+00FF (so it cannot be latin-1 bytes at all) or fails UTF-8 validation, and is
/// returned untouched in both cases.
pub fn ig_text(v: Option<&Value>) -> String {
    let s = v.and_then(Value::as_str).unwrap_or("");
    repair_mojibake(s)
}

pub fn repair_mojibake(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    let mut bytes = Vec::with_capacity(s.len());
    for c in s.chars() {
        let code = c as u32;
        if code > 0xFF {
            return s.to_string(); // not representable as latin-1 — already clean text
        }
        bytes.push(code as u8);
    }
    match String::from_utf8(bytes) {
        Ok(fixed) => fixed,
        Err(_) => s.to_string(),
    }
}

/// `mp4`/`mov`/`m4v` are the only video containers an Instagram export ships. Apple
/// `InstagramImporter.isVideo` parity.
pub fn is_video(name: &str) -> bool {
    matches!(ext(name).as_str(), "mp4" | "mov" | "m4v")
}

pub fn ext(name: &str) -> String {
    match name.rsplit_once('.') {
        Some((_, e)) if !e.is_empty() && !e.contains('/') => e.to_lowercase(),
        _ => "mp4".to_string(),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mojibake_is_repaired() {
        // "Peña" mangled the way Instagram emits it: the UTF-8 bytes C3 B1 re-read as latin-1.
        assert_eq!(repair_mojibake("PeÃ±a"), "Peña");
        // An em dash (U+2014 = E2 80 94) mangled the same way. NOTE the two C1 control characters —
        // this is latin-1, not CP-1252, so it is NOT the "â€”" seen in a browser. Round-tripping
        // through CP-1252 is deliberately not attempted: Apple and Android both use latin-1, and a
        // second guess here would repair strings the phones leave alone.
        assert_eq!(repair_mojibake("Chance PeÃ±a \u{e2}\u{80}\u{94} live"), "Chance Peña — live");
    }

    #[test]
    fn clean_text_is_untouched() {
        assert_eq!(repair_mojibake("Peña"), "Peña"); // ñ is U+00F1 but "ñ" alone is invalid UTF-8
        assert_eq!(repair_mojibake("plain ascii"), "plain ascii");
        assert_eq!(repair_mojibake("夜に駆ける"), "夜に駆ける"); // scalars > U+00FF: bail early
        assert_eq!(repair_mojibake(""), "");
    }

    #[test]
    fn album_members_are_collected_from_the_nested_chain() {
        // The shape that matters: the cover under the top-level "Media" label, members 2..N hanging
        // off a nested dict. A label-only read finds one; the walk must find all three.
        let entry = json!({
            "title": "carousel",
            "label_values": [{ "label": "Media", "value": "" }],
            "media": [{
                "uri": "media/posts/a.jpg",
                "creation_timestamp": 1600000000,
                "media_metadata": {
                    "photo_metadata": { "exif_data": [{ "scene_capture_type": "standard" }] },
                    "nested": { "more": [{ "uri": "media/posts/b.jpg" }, { "uri": "media/posts/c.jpg" }] }
                }
            }]
        });
        let media = collect_media(&entry);
        let uris: Vec<String> = media.iter().filter_map(|m| uri(m)).collect();
        assert_eq!(uris, vec!["media/posts/a.jpg", "media/posts/b.jpg", "media/posts/c.jpg"]);
    }

    #[test]
    fn subtitle_sidecars_and_duplicates_are_dropped() {
        let entry = json!({
            "media": [
                { "uri": "media/posts/a.mp4" },
                { "uri": "media/posts/a.srt" },
                { "uri": "media/posts/a.vtt" },
                { "uri": "media/posts/a.mp4" }
            ]
        });
        let uris: Vec<String> = collect_media(&entry).iter().filter_map(|m| uri(m)).collect();
        assert_eq!(uris, vec!["media/posts/a.mp4"]);
    }

    #[test]
    fn drafts_are_recognized() {
        assert!(is_draft(&json!({ "label_values": [{ "label": "Draft", "value": "true" }] })));
        assert!(is_draft(&json!({ "label_values": [{ "label": "Draft", "value": "True" }] })));
        assert!(!is_draft(&json!({ "label_values": [{ "label": "Draft", "value": "false" }] })));
        assert!(!is_draft(&json!({ "label_values": [{ "label": "Media", "value": "x" }] })));
        assert!(!is_draft(&json!({})));
    }

    #[test]
    fn genre_is_read_from_video_metadata_only() {
        let m = json!({ "media_metadata": { "video_metadata": { "music_genre": "Pop, Indie" } } });
        assert_eq!(genre(&m).as_deref(), Some("Pop, Indie"));
        assert_eq!(genre(&json!({ "media_metadata": { "video_metadata": {} } })), None);
        assert_eq!(genre(&json!({})), None);
    }

    #[test]
    fn video_extensions() {
        assert!(is_video("media/posts/clip.MP4"));
        assert!(is_video("media/posts/clip.mov"));
        assert!(is_video("media/posts/clip.m4v"));
        assert!(!is_video("media/posts/photo.jpg"));
        assert!(!is_video("media/posts/photo.heic"));
        assert_eq!(ext("media/posts/photo.JPG"), "jpg");
        assert_eq!(ext("noextension"), "mp4");
    }

    /// The real 1.28 GB export, when it is present. The numbers are the contract: 372 items
    /// (203 posts, 85 reels, 84 stories), 1129 media, 0 unresolved references. Skipped rather than
    /// failed when the archive isn't on this machine, so CI stays green without a 1.28 GB fixture.
    #[test]
    fn real_archive_matches_the_validated_counts() {
        let Some(path) = validation_archive() else {
            eprintln!("skipping: no instagram-*.zip in ~/Downloads");
            return;
        };
        let s = read(&path).expect("archive parses");
        assert_eq!(s.items.len(), 372, "total items");
        assert_eq!(s.count(Kind::Post), 203, "posts");
        assert_eq!(s.count(Kind::Reel), 85, "reels");
        assert_eq!(s.count(Kind::Story), 84, "stories");
        assert_eq!(s.media_count, 1129, "media files");
        assert!(s.missing.is_empty(), "unresolved: {:?}", s.missing);
        // Captions come out REPAIRED. This archive holds one real double-encoded caption — a right
        // single quote (U+2019 = E2 80 99) re-emitted as latin-1 — so a parse that skipped the
        // repair would leave "Godâ\u{80}\u{99}s" in a published post. Assert on the mojibake
        // SIGNATURE rather than the sentence, so the check survives a different export.
        let bodies: String = s.items.iter().map(|i| i.body.as_str()).collect();
        assert!(!bodies.contains('\u{fffd}'), "a caption decoded to a replacement character");
        assert!(!bodies.contains("\u{e2}\u{80}"), "an unrepaired UTF-8-as-latin-1 caption survived");
        assert!(
            s.items.iter().any(|i| i.body.contains('\u{2019}')),
            "the repaired right single quote should now be present"
        );

        // The sort is a total order, so a second parse must produce the identical sequence — the
        // property a resumed import's `done` index depends on.
        let again = read(&path).expect("archive parses twice");
        let a: Vec<&str> = s.items.iter().map(first_name).collect();
        let b: Vec<&str> = again.items.iter().map(first_name).collect();
        assert_eq!(a, b, "item order is deterministic");
    }

    /// Pull real reels out of the archive and ask the audio probe about them.
    ///
    /// The unit tests above build synthetic ISO-BMFF by hand, which proves the walk but not that
    /// real Instagram output has the shape it assumes — and the probe is what decides whether a post
    /// gets a suggested song layered over its own soundtrack. So this runs it over actual export
    /// bytes, streamed out through the same `extract_to` the importer uses.
    #[test]
    fn real_reels_stream_out_and_answer_the_audio_probe() {
        let Some(path) = validation_archive() else {
            eprintln!("skipping: no instagram-*.zip in ~/Downloads");
            return;
        };
        let summary = read(&path).expect("archive parses");
        let mut zip = Archive::open(&path).expect("archive opens");
        let clips: Vec<String> = summary
            .items
            .iter()
            .filter(|i| i.kind == Kind::Reel)
            .filter_map(|i| i.media_names.first().cloned())
            .filter(|n| is_video(n))
            .take(5)
            .collect();
        assert!(!clips.is_empty(), "the validation archive has reels");
        let dir = std::env::temp_dir().join(format!("haven-igreal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in &clips {
            let dest = dir.join("clip.mp4");
            assert!(zip.extract_to(name, &dest), "extract {name}");
            let size = std::fs::metadata(&dest).unwrap().len();
            assert!(size > 0, "{name} extracted empty");
            let audio = crate::songsuggest::mp4_file_has_audio_track(&dest);
            // The contract is that a REAL clip is decidable — `None` means the probe could not read
            // Instagram's own containers, which would silently disable the whole silent-post rule.
            assert!(audio.is_some(), "probe could not read {name} ({size} bytes)");
            eprintln!("  {name}: {size} bytes, audio={audio:?}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    pub(crate) fn validation_archive() -> Option<std::path::PathBuf> {
        let dir = dirs::home_dir()?.join("Downloads");
        let mut hits: Vec<_> = std::fs::read_dir(dir)
            .ok()?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.extension().map(|e| e == "zip").unwrap_or(false)
                    && p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.starts_with("instagram-"))
                        .unwrap_or(false)
            })
            .collect();
        hits.sort();
        hits.pop()
    }
}
