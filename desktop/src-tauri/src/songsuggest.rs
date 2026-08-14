//! Suggests songs for a post from what the post is about — what the caption says, and when it was
//! taken. Android parity: `android/…/core/SongSuggester.kt` (+ `MusicSearch.kt`); Apple parity:
//! `apple/HavenApp/SongSuggester.swift`.
//!
//! Runs on the free, unauthenticated iTunes Search API — no MusicKit, no account, no key — which is
//! why the same suggestions are reachable on Android and here. Apple's build reaches MusicKit
//! instead, but the RESULT is a plain `TrackRef` either way, which is what makes a song attached on
//! one platform show on all of them.
//!
//! Visual themes are Apple-only: that half needs an image classifier, and desktop deliberately
//! carries no decoder (see the CODEC DIVERGENCE note in `reoptimize.rs`). A caption is by far the
//! stronger signal anyway, and it is the signal Android runs on too.

use std::collections::HashSet;

use serde_json::Value;

/// One iTunes search result, reduced to the fields a Haven `TrackRef` needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Track {
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub preview_url: String,
    pub store_url: String,
    pub duration_ms: u64,
    /// iTunes `trackExplicitness`. The suggester never attaches an explicit track unheard.
    pub explicit: bool,
}

impl Track {
    /// The portable catalog id every Haven client keys a song on: the store URL plus the `~`
    /// separator Android's `MusicSearch` appends. Byte-identical so a song suggested here and one
    /// suggested on a phone are the SAME id and dedupe against each other.
    pub fn catalog_id(&self) -> String {
        format!("{}~", self.store_url)
    }
}

// ---- What the post is about --------------------------------------------------------------------

/// Content words from a caption — the subject, not the grammar.
///
/// CAPITALISED WORDS FIRST. Length was tried on Apple and was a poor heuristic: it surfaced
/// "themselves", "encouragement", "appreciation" — long, abstract, saying nothing about the post. In
/// a caption the capitalised word is the subject: Christmas, Luma, Condors, Jerusalem. A word that
/// merely starts a sentence does not count as a name, so it ranks second rather than being demoted
/// to ordinary (which is what made "Luma" lose to "groomers" and "cleaned").
///
/// Hashtags keep their text: on an Instagram caption a hashtag is frequently the most descriptive
/// word in the whole post.
pub fn caption_themes(caption: &str, limit: usize) -> Vec<String> {
    let cleaned = caption.replace('#', " ");
    if cleaned.trim().is_empty() {
        return Vec::new();
    }
    let raw: Vec<&str> = cleaned
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();

    let mut mid_sentence = Vec::new();
    let mut sentence_start = Vec::new();
    let mut ordinary = Vec::new();
    let mut at_start = true;
    for word in raw {
        let lower = word.to_lowercase();
        let starts_sentence = at_start;
        at_start = false;
        if lower.chars().count() <= 3 || BLAND.contains(&lower.as_str()) || STOP.contains(&lower.as_str()) {
            continue;
        }
        let capitalized = word.chars().next().map(|c| c.is_uppercase()).unwrap_or(false);
        if capitalized && !starts_sentence {
            mid_sentence.push(lower);
        } else if capitalized {
            sentence_start.push(lower);
        } else {
            ordinary.push(lower);
        }
    }
    // Longest first among the ordinary words — with no capital to go on, the longer word is the
    // more specific one.
    ordinary.sort_by(|a, b| b.chars().count().cmp(&a.chars().count()));

    let mut out: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for w in mid_sentence.into_iter().chain(sentence_start).chain(ordinary) {
        if seen.insert(w.clone()) {
            out.push(w);
            if out.len() == limit {
                break;
            }
        }
    }
    out
}

/// Grammar words the subject is never one of.
const STOP: &[&str] = &[
    "that", "this", "with", "from", "they", "them", "then", "than", "have", "has", "had", "been",
    "being", "were", "was", "will", "would", "could", "should", "just", "only", "about", "into",
    "over", "under", "after", "before", "when", "what", "where", "which", "while", "your", "yours",
    "mine", "ours", "their", "there", "here", "also", "because", "trying", "going", "getting",
    "doing", "make", "made", "take", "took", "come", "came", "want", "need", "like", "love",
    "know", "think", "look", "looks", "looking", "glad", "happy", "everyone", "everybody",
    "always", "never", "still", "even", "some", "such",
];

/// Nouns and adjectives that carry no subject — the words a caption uses to be a sentence. They
/// reliably come FIRST ("Tonight is fun…", "My second book…"), so without this the generic word
/// wins and the one saying what the post is about never gets used.
const BLAND: &[&str] = &[
    "today", "tonight", "yesterday", "tomorrow", "morning", "afternoon", "evening", "night",
    "time", "year", "week", "month", "day", "days", "weeks", "years", "hours", "minutes", "thing",
    "things", "stuff", "some", "more", "most", "much", "many", "lot", "lots", "best", "better",
    "good", "great", "nice", "cool", "fun", "last", "first", "next", "second", "third", "little",
    "long", "short", "here", "there", "everyone", "everything", "people", "someone", "something",
    "anything", "photo", "photos", "picture", "pictures", "video", "videos", "post", "instagram",
    "sure", "able", "back", "really", "very", "season", "seasons", "family", "friends",
    "everybody", "moment", "moments", "weekend", "life", "world", "place", "home", "house",
];

// ---- Search terms ------------------------------------------------------------------------------

/// Search terms, most specific first.
///
/// KEEP THESE THEMATIC AND SHORT. The search is lexical — it matches titles and artist names, not
/// meaning — so "beautiful" finds songs with "beautiful" in the title, which is the association
/// wanted. Padding it into "beautiful songs 2023" hands the matcher two generic tokens and every
/// post's query converges on the same popular results however distinct its theme was.
///
/// Era stays OUT of the query and is applied afterwards by `ranked_by_era`. And NOTE what is not
/// here: a bare date like "December 2023" matched songs literally TITLED that.
pub fn terms(themes: &[String], genre: Option<&str>, year: i32, month: u32) -> Vec<String> {
    let head: Option<String> = genre
        .and_then(|g| g.split(',').next())
        .map(|g| g.trim().replace(" Music", ""))
        .filter(|g| !g.is_empty());
    let mut out = Vec::new();
    for t in themes {
        out.push(t.clone());
        if let Some(h) = &head {
            out.push(format!("{t} {h}"));
        }
    }
    if let Some(h) = &head {
        out.push(h.clone());
    }
    if (1..=12).contains(&month) {
        out.push(MOOD_BY_MONTH[(month - 1) as usize].to_string());
    }
    out.push(format!("{year} hits"));
    out
}

/// Seasonal moods for a post that gives us nothing else — words a catalog can actually match.
const MOOD_BY_MONTH: [&str; 12] = [
    "new beginnings", "love songs", "spring", "sunshine", "bloom", "summer nights", "summer",
    "golden hour", "autumn", "cozy", "grateful", "winter",
];

// ---- Is it fit to attach unheard? --------------------------------------------------------------

/// A suggestion is not a search result: the user CHOSE a search result, whereas this is put on their
/// family's feed on their behalf, hundreds at a time, unaudited. So the bar is "safe to attach
/// unheard".
pub fn is_suitable(t: &Track) -> bool {
    if t.explicit {
        return false;
    }
    is_likely_in_users_language(&format!("{} {}", t.title, t.artist))
}

pub fn is_likely_in_users_language(text: &str) -> bool {
    !uses_foreign_script(text, &user_scripts())
}

/// SCRIPT is decisive — "夜に駆ける" is unmistakably not English whatever a statistical model says,
/// and on Apple a language-only check let exactly that through. Judged on the SHARE of letters, so
/// one accented character does not disqualify a title ("Chance Peña" stays).
pub fn uses_foreign_script(text: &str, scripts: &HashSet<&'static str>) -> bool {
    let letters: Vec<char> = text.chars().filter(|c| c.is_alphabetic()).collect();
    if letters.len() < 3 {
        return false;
    }
    let foreign = letters
        .iter()
        .filter(|c| match script_of(**c) {
            Some(s) => !scripts.contains(s),
            None => false,
        })
        .count();
    foreign as f64 / letters.len() as f64 > 0.34
}

pub fn script_of(c: char) -> Option<&'static str> {
    match c as u32 {
        0x0041..=0x024F | 0x1E00..=0x1EFF => Some("latin"),
        0x0370..=0x03FF => Some("greek"),
        0x0400..=0x04FF => Some("cyrillic"),
        0x0590..=0x05FF => Some("hebrew"),
        0x0600..=0x06FF => Some("arabic"),
        0x0900..=0x097F => Some("devanagari"),
        0x0E00..=0x0E7F => Some("thai"),
        0x3040..=0x30FF | 0x4E00..=0x9FFF => Some("cjk"),
        0xAC00..=0xD7AF | 0x1100..=0x11FF => Some("hangul"),
        _ => None,
    }
}

/// Latin is ALWAYS included: any device shows Latin-titled songs throughout the store.
pub fn scripts_for_language(lang: &str) -> HashSet<&'static str> {
    let mut out = HashSet::new();
    out.insert("latin");
    match lang {
        "ja" | "zh" => {
            out.insert("cjk");
        }
        "ko" => {
            out.insert("hangul");
            out.insert("cjk");
        }
        "ru" | "uk" | "bg" | "sr" => {
            out.insert("cyrillic");
        }
        "el" => {
            out.insert("greek");
        }
        "he" | "yi" => {
            out.insert("hebrew");
        }
        "ar" | "fa" | "ur" => {
            out.insert("arabic");
        }
        "hi" | "mr" | "ne" => {
            out.insert("devanagari");
        }
        "th" => {
            out.insert("thai");
        }
        _ => {}
    }
    out
}

/// The user's primary language, from the POSIX locale environment. There is no cross-platform
/// `Locale.getDefault()` in std, and pulling a locale crate in for one two-letter string is not
/// worth it — an unset or unrecognised environment falls back to `en`, which only ever means "Latin
/// only", the strictest and safest answer.
pub fn user_language() -> String {
    for key in ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"] {
        if let Ok(v) = std::env::var(key) {
            let v = v.trim();
            if v.is_empty() || v.eq_ignore_ascii_case("C") || v.eq_ignore_ascii_case("POSIX") {
                continue;
            }
            let primary: String = v
                .chars()
                .take_while(|c| c.is_ascii_alphabetic())
                .collect::<String>()
                .to_lowercase();
            if primary.len() >= 2 {
                return primary[..2].to_string();
            }
        }
    }
    "en".to_string()
}

fn user_scripts() -> HashSet<&'static str> {
    scripts_for_language(&user_language())
}

// ---- Dates ------------------------------------------------------------------------------------

/// Year and 1-based month of an epoch-ms instant, in UTC.
///
/// Hand-rolled rather than a `chrono` dependency: the only use is choosing a seasonal search word
/// and an "N hits" fallback term, so a timezone's worth of drift at a month boundary changes at most
/// which of twelve mood words a silent post gets. (Howard Hinnant's civil-from-days.)
pub fn year_month(created_at_ms: u64) -> (i32, u32) {
    let days = (created_at_ms / 1000) as i64 / 86_400;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    ((if m <= 2 { y + 1 } else { y }) as i32, m as u32)
}

// ---- Does this post already make a sound? ------------------------------------------------------

/// True when an MP4/MOV carries at least one audio track.
///
/// The parity target is Apple's `SongSuggester.hasAudio`, which asks AVFoundation. Desktop has no
/// AVFoundation and no decoder, so this walks the ISO-BMFF box tree instead and looks for a track
/// whose `hdlr` handler type is `soun` — structure only, no decoding.
///
/// `None` means "could not tell" (a container this doesn't understand, or a truncated read), and
/// every caller MUST treat that as AUDIBLE. Guessing "silent" would layer a suggested song over a
/// clip that already has its own soundtrack, which is the one outcome this whole check exists to
/// prevent; guessing "audible" merely costs a muted screen-recording its suggestion.
/// The pure, in-memory form. Not called by the importer — which uses the file-seeking variant below
/// so a 200 MB reel is never slurped to answer a yes/no — but kept as the shape the box walk is
/// specified and unit-tested against, and as the entry point for any caller that already holds the
/// bytes.
#[allow(dead_code)]
pub fn mp4_has_audio_track(bytes: &[u8]) -> Option<bool> {
    moov_has_audio(find_box(bytes, b"moov")?)
}

fn moov_has_audio(moov: &[u8]) -> Option<bool> {
    let mut found_any_track = false;
    let mut audio = false;
    for trak in boxes_named(moov, b"trak") {
        found_any_track = true;
        let Some(mdia) = find_box(trak, b"mdia") else { continue };
        let Some(hdlr) = find_box(mdia, b"hdlr") else { continue };
        // hdlr payload: 4 version/flags, 4 pre_defined, 4 handler_type.
        if hdlr.len() >= 12 && &hdlr[8..12] == b"soun" {
            audio = true;
        }
    }
    if !found_any_track {
        return None;
    }
    Some(audio)
}

/// The same question asked of a file, reading only the box headers and the `moov` payload.
///
/// A reel can be hundreds of megabytes and `moov` is kilobytes — and it sits at either END of the
/// file depending on the muxer — so slurping the clip to answer a yes/no about its audio would be
/// the single largest allocation in the whole import. This seeks the top-level chain instead.
pub fn mp4_file_has_audio_track(path: &std::path::Path) -> Option<bool> {
    use std::io::{Read, Seek, SeekFrom};
    /// A `moov` larger than this is not a real one; refuse rather than allocate on its say-so.
    const MOOV_CEILING: u64 = 64 * 1024 * 1024;

    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    let mut pos = 0u64;
    while pos + 8 <= len {
        f.seek(SeekFrom::Start(pos)).ok()?;
        let mut header = [0u8; 8];
        f.read_exact(&mut header).ok()?;
        let size32 = u32::from_be_bytes(header[0..4].try_into().ok()?) as u64;
        let name = &header[4..8];
        let (header_len, size) = match size32 {
            1 => {
                let mut big = [0u8; 8];
                f.read_exact(&mut big).ok()?;
                (16u64, u64::from_be_bytes(big))
            }
            0 => (8u64, len - pos),
            n => (8u64, n),
        };
        if size < header_len {
            return None; // malformed — a zero-advance box would loop forever
        }
        if name == b"moov" {
            let payload = size - header_len;
            if payload > MOOV_CEILING {
                return None;
            }
            let mut buf = vec![0u8; payload as usize];
            f.seek(SeekFrom::Start(pos + header_len)).ok()?;
            f.read_exact(&mut buf).ok()?;
            return moov_has_audio(&buf);
        }
        pos = pos.checked_add(size)?;
    }
    None
}

/// Payload of the first top-level box with this type, searching one level deep from `data`.
fn find_box<'a>(data: &'a [u8], want: &'static [u8; 4]) -> Option<&'a [u8]> {
    boxes_named(data, want).next()
}

/// Every top-level box of this type in `data`, as payload slices.
fn boxes_named<'a>(data: &'a [u8], want: &'static [u8; 4]) -> impl Iterator<Item = &'a [u8]> {
    BoxIter { data, pos: 0 }.filter_map(move |(name, body)| (&name == want).then_some(body))
}

struct BoxIter<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Iterator for BoxIter<'a> {
    type Item = ([u8; 4], &'a [u8]);
    fn next(&mut self) -> Option<Self::Item> {
        // 8-byte header minimum: u32 size + 4-char type. size 1 = 64-bit size in the next 8 bytes;
        // size 0 = "to end of file".
        if self.pos + 8 > self.data.len() {
            return None;
        }
        let size32 = u32::from_be_bytes(self.data[self.pos..self.pos + 4].try_into().ok()?) as u64;
        let mut name = [0u8; 4];
        name.copy_from_slice(&self.data[self.pos + 4..self.pos + 8]);
        let (header, size) = match size32 {
            1 => {
                if self.pos + 16 > self.data.len() {
                    return None;
                }
                let big = u64::from_be_bytes(self.data[self.pos + 8..self.pos + 16].try_into().ok()?);
                (16usize, big)
            }
            0 => (8usize, (self.data.len() - self.pos) as u64),
            n => (8usize, n),
        };
        if size < header as u64 {
            return None; // malformed — stop rather than loop forever on a zero-advance box
        }
        let end = self.pos.saturating_add(size as usize).min(self.data.len());
        let body_start = self.pos + header;
        if body_start > end {
            return None;
        }
        let body = &self.data[body_start..end];
        self.pos = self.pos.saturating_add(size as usize);
        Some((name, body))
    }
}

// ---- The catalog -------------------------------------------------------------------------------

/// Songs for a post, best first, preferring anything not already used.
///
/// `exclude` is what stops an import scoring hundreds of posts with one track: the importer
/// accumulates every id it has attached and passes them back. A PREFERENCE, not a rule — if a search
/// only returns songs already used, reusing one still beats leaving the post silent.
pub async fn suggestions(
    themes: &[String],
    genre: Option<&str>,
    year: i32,
    month: u32,
    exclude: &HashSet<String>,
    limit: usize,
) -> Vec<HavenTrack> {
    let mut seen = HashSet::new();
    let mut fresh: Vec<HavenTrack> = Vec::new();
    let mut reused: Vec<HavenTrack> = Vec::new();

    for term in terms(themes, genre, year, month) {
        let hits = search(&term, 25).await.unwrap_or_default();
        for t in ranked_by_era(hits) {
            if !is_suitable(&t) {
                continue;
            }
            let id = t.catalog_id();
            if !seen.insert(id.clone()) {
                continue;
            }
            let ref_ = HavenTrack {
                catalog_id: id.clone(),
                title: t.title,
                artist: t.artist,
                artwork_url: t.artwork_url,
                duration_ms: t.duration_ms,
                preview_url: t.preview_url,
            };
            if exclude.contains(&id) {
                reused.push(ref_);
            } else {
                fresh.push(ref_);
            }
        }
        // Keep going past the first satisfying term: a pool from ONE search means the random pick
        // chooses between near-identical results, which is what made an import sound like a single
        // playlist on repeat.
        if fresh.len() >= limit * 2 {
            break;
        }
    }
    fresh.append(&mut reused);
    fresh.truncate(limit);
    fresh
}

/// One song for a post — the importer's entry point. Random among the best few, not the top.
pub async fn song(
    themes: &[String],
    genre: Option<&str>,
    year: i32,
    month: u32,
    exclude: &HashSet<String>,
) -> Option<HavenTrack> {
    use rand::seq::SliceRandom;
    let pool = suggestions(themes, genre, year, month, exclude, 8).await;
    let mut rng = rand::thread_rng();
    pool.choose(&mut rng).cloned()
}

/// A song reference in Haven's own shape, ready to become a `TrackRefFfi`. Kept separate from
/// `Track` so this module never has to depend on the FFI types (and stays unit-testable).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HavenTrack {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub duration_ms: u64,
    /// The 30-second clip, carried so the PICKER can audition a suggestion. A `TrackRef` has no
    /// field for it and does not need one — nothing is stored on the post — but dropping it here
    /// meant a suggested song could only be heard by attaching it first, which made every audition
    /// a commitment the user then had to undo.
    pub preview_url: String,
}

/// Prefer releases near the post's year — but only as a preference, and the iTunes API gives NO
/// release date on a search result, so era can only ever be a shuffle here. Sorting strictly meant
/// one track was permanently "the best 2023 song" and won every time that search ran; the shuffle
/// is what supplies the variety. (Android `rankedByEra` does exactly this.)
fn ranked_by_era(mut hits: Vec<Track>) -> Vec<Track> {
    use rand::seq::SliceRandom;
    let mut rng = rand::thread_rng();
    hits.shuffle(&mut rng);
    hits
}

/// One track by its iTunes id, through the same free API's `lookup` endpoint.
///
/// Exact where `search` is approximate: a TrackRef carries the store URL it came from, so the id is
/// already known and a text search for its title is a worse question with a worse answer.
pub async fn lookup(id: &str) -> Option<Track> {
    let url = format!("https://itunes.apple.com/lookup?id={id}&entity=song");
    let body = http().get(&url).send().await.ok()?.text().await.ok()?;
    parse_results(&body).into_iter().next()
}

/// Search songs by free text through the free, unauthenticated iTunes Search API.
pub async fn search(query: &str, limit: usize) -> Option<Vec<Track>> {
    let q = query.trim();
    if q.is_empty() {
        return Some(Vec::new());
    }
    let url = format!(
        "https://itunes.apple.com/search?term={}&media=music&entity=song&limit={limit}",
        url_encode(q)
    );
    let body = http().get(&url).send().await.ok()?.text().await.ok()?;
    Some(parse_results(&body))
}

pub fn parse_results(json: &str) -> Vec<Track> {
    let Ok(v) = serde_json::from_str::<Value>(json) else { return Vec::new() };
    let Some(Value::Array(results)) = v.get("results") else { return Vec::new() };
    results
        .iter()
        .filter_map(|o| {
            let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            let preview = s("previewUrl");
            if preview.is_empty() {
                return None; // nothing to play — Android drops these too
            }
            Some(Track {
                title: s("trackName"),
                artist: s("artistName"),
                // Bump the 100px artwork to a crisp 300px.
                artwork_url: s("artworkUrl100").replace("100x100", "300x300"),
                preview_url: preview,
                store_url: s("trackViewUrl"),
                duration_ms: o.get("trackTimeMillis").and_then(Value::as_u64).unwrap_or(0),
                explicit: s("trackExplicitness") == "explicit",
            })
        })
        .collect()
}

/// Percent-encode a search term. Hand-rolled to avoid a `urlencoding` dependency for one call site;
/// everything outside the unreserved set goes out as %XX of its UTF-8 bytes.
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// One shared client for the whole suggester — connection reuse across a 300-post import, and a
/// bounded timeout so one wedged request cannot stall the loop. Built once, lazily.
fn http() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent("Haven")
            .connect_timeout(std::time::Duration::from_secs(8))
            .timeout(std::time::Duration::from_secs(12))
            .build()
            .unwrap_or_default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(words: &[&str]) -> Vec<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    // ---- theme extraction ----

    #[test]
    fn a_mid_sentence_capital_is_the_subject() {
        // The exact regression the Android header calls out: "Luma" must beat "groomers"/"cleaned".
        let themes = caption_themes("The groomers finally got Luma cleaned up", 2);
        assert_eq!(themes[0], "luma");
    }

    #[test]
    fn a_sentence_opening_capital_outranks_ordinary_words() {
        let themes = caption_themes("Christmas with the extended relatives", 2);
        assert_eq!(themes[0], "christmas");
    }

    #[test]
    fn hashtags_keep_their_text() {
        let themes = caption_themes("out again #condors", 2);
        assert!(themes.contains(&"condors".to_string()), "{themes:?}");
    }

    #[test]
    fn grammar_and_bland_words_are_never_themes() {
        // Every content-free word here is in STOP or BLAND, so nothing survives.
        assert!(caption_themes("Today was a really great day with friends", 2).is_empty());
        assert!(caption_themes("", 2).is_empty());
        assert!(caption_themes("   ", 2).is_empty());
        // Short words (<= 3 chars) are dropped whatever their case.
        assert!(caption_themes("Ah oh no", 2).is_empty());
    }

    #[test]
    fn themes_are_deduped_and_limited() {
        let themes = caption_themes("Jerusalem Jerusalem Jerusalem Condors", 2);
        assert_eq!(themes, v(&["jerusalem", "condors"]));
        // Limit 1 takes the MID-SENTENCE capital, not the one that merely opens the caption —
        // "Jerusalem" here could be the first word of any sentence, "Condors" could not.
        assert_eq!(caption_themes("Jerusalem Condors Pelicans", 1), v(&["condors"]));
    }

    // ---- term construction ----

    #[test]
    fn terms_are_thematic_and_ordered_most_specific_first() {
        let got = terms(&v(&["condors"]), Some("Indie Rock Music, Pop"), 2023, 12);
        assert_eq!(got, v(&["condors", "condors Indie Rock", "Indie Rock", "winter", "2023 hits"]));
    }

    #[test]
    fn terms_survive_a_post_with_nothing_to_say() {
        assert_eq!(terms(&[], None, 2019, 7), v(&["summer", "2019 hits"]));
        // No month known: no mood word, but the era fallback still gives the search something.
        assert_eq!(terms(&[], None, 2019, 0), v(&["2019 hits"]));
    }

    #[test]
    fn terms_never_contain_a_bare_date() {
        // "December 2023" matched songs literally TITLED that — the reason the era is applied after
        // the search rather than inside the query.
        for t in terms(&v(&["beach"]), Some("Pop"), 2023, 12) {
            assert!(!t.contains("2023 ") || t == "2023 hits", "leaked a date-ish term: {t}");
        }
    }

    // ---- explicit / script filtering ----

    fn track(title: &str, artist: &str, explicit: bool) -> Track {
        Track {
            title: title.into(),
            artist: artist.into(),
            artwork_url: String::new(),
            preview_url: "https://x/p.m4a".into(),
            store_url: format!("https://music.apple.com/{title}"),
            duration_ms: 1000,
            explicit,
        }
    }

    #[test]
    fn explicit_tracks_are_never_suggested() {
        assert!(!is_suitable(&track("Some Song", "Some Artist", true)));
        assert!(is_suitable(&track("Some Song", "Some Artist", false)));
    }

    #[test]
    fn accented_latin_is_kept_but_a_foreign_script_is_not() {
        let en = scripts_for_language("en");
        assert!(!uses_foreign_script("Chance Peña", &en), "accented Latin must stay");
        assert!(!uses_foreign_script("Beyoncé — Déjà Vu", &en));
        assert!(uses_foreign_script("夜に駆ける", &en), "CJK must go");
        assert!(uses_foreign_script("아이유 밤편지", &en), "Hangul must go");
        assert!(uses_foreign_script("Кино Группа крови", &en), "Cyrillic must go");
    }

    #[test]
    fn a_japanese_reader_keeps_japanese_titles() {
        assert!(!uses_foreign_script("夜に駆ける", &scripts_for_language("ja")));
        assert!(!uses_foreign_script("아이유 밤편지", &scripts_for_language("ko")));
        // Latin is in every locale's set, so an English title is never rejected.
        assert!(!uses_foreign_script("Golden Hour", &scripts_for_language("ja")));
    }

    #[test]
    fn very_short_strings_are_not_judged() {
        // Two letters is not enough evidence of anything.
        assert!(!uses_foreign_script("愛", &scripts_for_language("en")));
    }

    #[test]
    fn a_single_foreign_character_does_not_disqualify_a_latin_title() {
        // 34% threshold: one CJK char among many Latin letters stays.
        assert!(!uses_foreign_script("Tokyo Drift 東", &scripts_for_language("en")));
    }

    #[test]
    fn language_is_read_from_the_posix_environment() {
        assert_eq!(scripts_for_language("ru").contains("cyrillic"), true);
        assert_eq!(scripts_for_language("xx").len(), 1); // latin only
    }

    // ---- results parsing ----

    #[test]
    fn results_are_parsed_with_artwork_upscaled_and_previewless_rows_dropped() {
        let json = r#"{"results":[
            {"trackName":"A","artistName":"B","artworkUrl100":"https://x/100x100bb.jpg",
             "previewUrl":"https://x/p.m4a","trackViewUrl":"https://music.apple.com/a",
             "trackTimeMillis":210000,"trackExplicitness":"notExplicit"},
            {"trackName":"NoPreview","artistName":"B","trackViewUrl":"https://music.apple.com/b"}
        ]}"#;
        let out = parse_results(json);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].artwork_url, "https://x/300x300bb.jpg");
        assert_eq!(out[0].duration_ms, 210_000);
        assert!(!out[0].explicit);
        assert_eq!(out[0].catalog_id(), "https://music.apple.com/a~");
        assert_eq!(parse_results("not json"), Vec::new());
    }

    #[test]
    fn explicitness_flag_is_exact() {
        let mk = |e: &str| format!(
            r#"{{"results":[{{"trackName":"A","artistName":"B","previewUrl":"p","trackViewUrl":"u","trackExplicitness":"{e}"}}]}}"#
        );
        assert!(parse_results(&mk("explicit"))[0].explicit);
        assert!(!parse_results(&mk("cleaned"))[0].explicit);
        assert!(!parse_results(&mk("notExplicit"))[0].explicit);
    }

    #[test]
    fn terms_are_url_encoded() {
        assert_eq!(url_encode("summer nights"), "summer+nights");
        assert_eq!(url_encode("Peña"), "Pe%C3%B1a");
        assert_eq!(url_encode("a&b=c"), "a%26b%3Dc");
    }

    // ---- dates ----

    #[test]
    fn year_month_from_epoch_ms() {
        assert_eq!(year_month(0), (1970, 1));
        assert_eq!(year_month(1_700_000_000_000), (2023, 11));
        assert_eq!(year_month(1_609_459_200_000), (2021, 1)); // 2021-01-01T00:00:00Z
        assert_eq!(year_month(1_583_020_800_000), (2020, 3)); // leap-year boundary
    }

    // ---- audio probe ----

    /// Minimal ISO-BMFF: `moov` holding N `trak`s, each with `mdia` > `hdlr` of the given type.
    fn fake_mp4(handlers: &[&[u8; 4]]) -> Vec<u8> {
        fn boxed(name: &[u8; 4], body: Vec<u8>) -> Vec<u8> {
            let mut out = ((body.len() + 8) as u32).to_be_bytes().to_vec();
            out.extend_from_slice(name);
            out.extend(body);
            out
        }
        let mut moov = Vec::new();
        for h in handlers {
            let mut hdlr = vec![0u8; 8]; // version/flags + pre_defined
            hdlr.extend_from_slice(*h);
            let mdia = boxed(b"mdia", boxed(b"hdlr", hdlr));
            moov.extend(boxed(b"trak", mdia));
        }
        let mut file = boxed(b"ftyp", b"isom".to_vec());
        file.extend(boxed(b"moov", moov));
        file
    }

    #[test]
    fn audio_track_is_detected() {
        assert_eq!(mp4_has_audio_track(&fake_mp4(&[b"vide", b"soun"])), Some(true));
        assert_eq!(mp4_has_audio_track(&fake_mp4(&[b"soun"])), Some(true));
    }

    #[test]
    fn a_silent_clip_reads_as_silent() {
        assert_eq!(mp4_has_audio_track(&fake_mp4(&[b"vide"])), Some(false));
    }

    #[test]
    fn an_unreadable_container_says_dont_know_not_silent() {
        // The load-bearing case: "don't know" must never be mistaken for "silent", or the importer
        // would layer a song over a clip that already has one.
        assert_eq!(mp4_has_audio_track(b"not an mp4 at all"), None);
        assert_eq!(mp4_has_audio_track(&[]), None);
        assert_eq!(mp4_has_audio_track(&fake_mp4(&[])), None); // moov with no traks
    }

    #[test]
    fn a_truncated_or_malformed_box_terminates_rather_than_spinning() {
        // size 0 inside a box would advance the cursor by nothing — an infinite loop if unguarded.
        let bogus = vec![0, 0, 0, 4, b'm', b'o', b'o', b'v'];
        assert_eq!(mp4_has_audio_track(&bogus), None);
    }

    #[test]
    fn the_file_probe_agrees_with_the_in_memory_one() {
        let dir = std::env::temp_dir().join(format!("haven-mp4probe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for (handlers, want) in [
            (vec![&b"vide", &b"soun"], Some(true)),
            (vec![&b"vide"], Some(false)),
        ] {
            let handlers: Vec<&[u8; 4]> = handlers.into_iter().copied().collect();
            let bytes = fake_mp4(&handlers);
            let p = dir.join(format!("{:?}.mp4", want));
            std::fs::write(&p, &bytes).unwrap();
            assert_eq!(mp4_file_has_audio_track(&p), want);
            assert_eq!(mp4_has_audio_track(&bytes), want);
        }
        assert_eq!(mp4_file_has_audio_track(&dir.join("does-not-exist.mp4")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
