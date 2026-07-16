//! On-device media store, byte-compatible with the iOS `MediaStore` and Android `LocalMedia`:
//! photos/videos/voice are content-addressed (sha-256 of the plaintext, so the ref is identical
//! on every device for the cross-device MediaReq/Chunk fetch) and kept **sealed at rest** to the
//! circle. Videos carry a `v:` ref prefix and voice notes an `a:` prefix so the feed renders the
//! right player; bare refs (or `i:`) are images.
//!
//! Being content-addressed was never enough on its own: nothing CHECKED that the bytes behind a ref
//! were the bytes it named, so a relay operator could serve one member's photo under another's ref
//! and it rendered. Refs are minted and verified through `haven_p2p::mediaref` now — one definition of
//! the address shared with iOS, Android and the relay-side tests, rather than three that can drift.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use haven_ffi::HavenSocial;
use haven_p2p::mediaref;
use sha2::{Digest, Sha256};

pub struct LocalMedia {
    dir: PathBuf,
}

/// What kind of media a ref points at — drives the ref prefix and the rendered player.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
}

impl MediaKind {
    fn prefix(self) -> &'static str {
        match self {
            MediaKind::Image => "",
            MediaKind::Video => "v:",
            MediaKind::Audio => "a:",
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn bare_id(reference: &str) -> &str {
    reference
        .strip_prefix("v:")
        .or_else(|| reference.strip_prefix("a:"))
        .or_else(|| reference.strip_prefix("i:"))
        .unwrap_or(reference)
}

/// Sniff an audio container so the WebView gets a playable `data:` MIME. MediaRecorder in
/// WebKitGTK/WebView2 emits WebM/Opus or Ogg/Opus; Safari/macOS emits MP4/AAC.
/// Sniff an image's real type from its magic bytes. Refs carry no format, only a kind prefix, so a
/// hardcoded `image/jpeg` mislabels every PNG we hold (attachments arrive from other platforms and
/// from the clipboard, not just the JPEG-producing picker).
pub fn image_mime(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if bytes.starts_with(b"GIF8") {
        "image/gif"
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        "image/heic"
    } else {
        "image/jpeg" // the picker's own output, and the safe default
    }
}

pub fn audio_mime(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(b"OggS") {
        "audio/ogg"
    } else if bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        "audio/webm"
    } else if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        "audio/mp4"
    } else if bytes.starts_with(b"ID3") || bytes.starts_with(&[0xFF, 0xFB]) {
        "audio/mpeg"
    } else {
        "audio/webm"
    }
}

impl LocalMedia {
    pub fn new(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        Self { dir }
    }

    pub fn is_video(reference: &str) -> bool {
        reference.starts_with("v:")
    }

    pub fn is_audio(reference: &str) -> bool {
        reference.starts_with("a:")
    }

    /// True if `reference` is a synthetic, non-fetchable attachment (e.g. a `geo:<lat>,<lon>,<label>`
    /// location pin) rather than real media bytes. Location shares ride inside a post's `media`
    /// array, but no peer or relay can EVER serve them — blobstore safe_path (core/haven-net) rejects
    /// ':' in a key component, so such a key was never storable — so the missing-media sweep would
    /// re-enqueue a doomed S3-404 + ~30s iroh dial for them every cycle and the pending count would
    /// never settle to 0. Real media refs are `img_`/`vid_`/`aud_` or a bare content hash; the legacy
    /// single-letter media schemes `v:`/`i:`/`a:` stay fetchable, so we key off a MULTI-char URI
    /// scheme (a ':' at index > 1) rather than a bare "contains ':'".
    pub fn is_synthetic(reference: &str) -> bool {
        reference.find(':').is_some_and(|i| i > 1)
    }

    /// Store plaintext bytes sealed to `circle_id` under a typed ref.
    pub fn store_kind(&self, social: &Arc<HavenSocial>, circle_id: &str, bytes: &[u8], kind: MediaKind) -> String {
        let hash = sha256_hex(bytes);
        let to_write = social
            .seal_circle_media(circle_id.to_string(), bytes.to_vec())
            .unwrap_or_else(|_| bytes.to_vec());
        let _ = fs::write(self.dir.join(&hash), &to_write);
        format!("{}{hash}", kind.prefix())
    }

    /// Store plaintext bytes sealed to `circle_id`; returns a media ref.
    pub fn store(&self, social: &Arc<HavenSocial>, circle_id: &str, bytes: &[u8], is_video: bool) -> String {
        self.store_kind(social, circle_id, bytes, if is_video { MediaKind::Video } else { MediaKind::Image })
    }

    /// Store a media FILE already on disk, sealed to `circle_id`, using the core's off-heap file→file
    /// seal (`seal_circle_media_file`) so the plaintext is NEVER loaded into a `Vec` here and the whole
    /// plaintext + whole sealed envelope are never co-resident in this process — a large video (hundreds
    /// of MB) otherwise doubled peak RAM through the `store` path (read whole file → seal whole → write).
    /// The content address is the sha-256 of the PLAINTEXT, STREAMED in 1 MB windows, so the ref is
    /// byte-identical to an in-memory `store` of the same bytes. Mirrors the iOS `seal_circle_media_file`
    /// backup path. Returns the media ref, or an IO error.
    pub fn store_file(
        &self,
        social: &Arc<HavenSocial>,
        circle_id: &str,
        src: &Path,
        kind: MediaKind,
    ) -> std::io::Result<String> {
        use std::io::Read;
        let mut hasher = Sha256::new();
        let mut f = fs::File::open(src)?;
        let mut buf = vec![0u8; 1024 * 1024];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let hash: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
        let dst = self.dir.join(&hash);
        let sealed = social.seal_circle_media_file(
            circle_id.to_string(),
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
        );
        if !sealed {
            // Fallback (unknown circle / IO error in the file seal): mirror `store_kind` — seal in
            // memory, or store plaintext if even that fails, so the media is at least available locally.
            let bytes = fs::read(src)?;
            let to_write = social
                .seal_circle_media(circle_id.to_string(), bytes.clone())
                .unwrap_or(bytes);
            fs::write(&dst, &to_write)?;
        }
        Ok(format!("{}{hash}", kind.prefix()))
    }

    /// Load + decrypt a stored media ref, or `None` if we don't have it — or if the bytes we hold
    /// are not the bytes the ref names.
    ///
    /// Verification lives on the READ side here, not the write side, because this store keeps media
    /// sealed at rest: the plaintext only exists at open time, so that's the one place it can be
    /// hashed without paying for an extra decrypt. It also means a blob is checked at the point it
    /// is USED, so tampering with the at-rest file is caught too, not just tampering in flight. The
    /// digest is a few ms against a decrypt of the same bytes we just did.
    pub fn load(&self, social: &Arc<HavenSocial>, circle_id: &str, reference: &str) -> Option<Vec<u8>> {
        let f = self.dir.join(bare_id(reference));
        let stored = fs::read(&f).ok()?;
        let opened = social
            .open_circle_media(circle_id.to_string(), stored.clone())
            .unwrap_or(stored);
        Self::checked(reference, opened)
    }

    /// Gate plaintext on it accounting for the ref that named it. `None` = a substitution: the seal
    /// opened, but these are not the bytes the signed post pointed at, so nothing may render them.
    /// Legacy (non-content-addressed) refs pass — see `haven_p2p::mediaref`.
    fn checked(reference: &str, plaintext: Vec<u8>) -> Option<Vec<u8>> {
        if mediaref::verify(reference, &plaintext) {
            Some(plaintext)
        } else {
            eprintln!(
                "media REJECTED {}: {} plaintext bytes do not match its content address",
                &reference[..reference.len().min(12)],
                plaintext.len()
            );
            None
        }
    }

    pub fn has(&self, reference: &str) -> bool {
        self.dir.join(bare_id(reference)).exists()
    }

    /// Load decrypted bytes trying every circle's key (for serving a media request). Verified too:
    /// we must never RE-SERVE a substituted blob onward as if it were the ref it claims — that would
    /// make every honest device a second-hop launderer for the relay's swap.
    pub fn load_any_circle(&self, social: &Arc<HavenSocial>, reference: &str) -> Option<Vec<u8>> {
        let f = self.dir.join(bare_id(reference));
        let stored = fs::read(&f).ok()?;
        for c in social.circles() {
            if let Some(open) = social.open_circle_media(c.id, stored.clone()) {
                return Self::checked(reference, open);
            }
        }
        Self::checked(reference, stored)
    }

    /// Store received plaintext bytes under an exact ref (sealed at rest to the circle). Bytes that
    /// don't account for `reference` are dropped at the door rather than sealed and kept.
    pub fn store_under_ref(&self, social: &Arc<HavenSocial>, circle_id: &str, reference: &str, bytes: &[u8]) {
        if !mediaref::verify(reference, bytes) {
            eprintln!(
                "media REJECTED {}: inbound bytes do not match its content address",
                &reference[..reference.len().min(12)]
            );
            return;
        }
        let to_write = social
            .seal_circle_media(circle_id.to_string(), bytes.to_vec())
            .unwrap_or_else(|_| bytes.to_vec());
        let _ = fs::write(self.dir.join(bare_id(reference)), &to_write);
    }

    /// The at-rest sealed blob for a ref — uploaded to the relay verbatim.
    pub fn raw_sealed(&self, reference: &str) -> Option<Vec<u8>> {
        fs::read(self.dir.join(bare_id(reference))).ok()
    }

    /// Write a sealed blob fetched from the relay straight to disk.
    pub fn write_raw_sealed(&self, reference: &str, blob: &[u8]) {
        let _ = fs::write(self.dir.join(bare_id(reference)), blob);
    }

    // ---- Chunked reassembly (large-media fix) -----------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB, so large sealed videos are transferred as 8 MB
    // chunks (see engine::upload_media / fetch_media_from_relay). On download we APPEND each chunk to a
    // temp file on disk — the full sealed blob is NEVER held in RAM at once — then adopt it.

    /// A fresh empty temp file to reassemble an incoming chunked (sealed) transfer for `reference`.
    pub fn new_sealed_part(&self, reference: &str) -> PathBuf {
        let p = self.dir.join(format!("incoming_{}.part", bare_id(reference)));
        let _ = fs::remove_file(&p);
        let _ = fs::File::create(&p);
        p
    }

    /// Append one sealed chunk's bytes to the temp reassembly file (streaming — no full blob in RAM).
    pub fn append_sealed_part(&self, part: &Path, bytes: &[u8]) -> bool {
        use std::io::Write;
        fs::OpenOptions::new()
            .append(true)
            .open(part)
            .and_then(|mut f| f.write_all(bytes))
            .is_ok()
    }

    /// Move a fully-reassembled sealed temp file into place under `reference`.
    pub fn adopt_sealed_part(&self, reference: &str, part: &Path) -> bool {
        let dst = self.dir.join(bare_id(reference));
        fs::rename(part, &dst).is_ok()
    }

    /// Delete every stored media file (part of "start over").
    pub fn clear(&self) {
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ref_kind_classification() {
        assert!(LocalMedia::is_video("v:abc"));
        assert!(!LocalMedia::is_video("a:abc"));
        assert!(!LocalMedia::is_video("abc"));
        assert!(LocalMedia::is_audio("a:abc"));
        assert!(!LocalMedia::is_audio("v:abc"));
        assert!(!LocalMedia::is_audio("abc"));
    }

    #[test]
    fn synthetic_excludes_geo_but_keeps_media() {
        // geo: location pins carry no bytes and were never relay-storable → skip in sweeps.
        assert!(LocalMedia::is_synthetic("geo:36.213,-118.687,Place Name"));
        // Real media refs stay fetchable — img_/vid_/aud_, bare hashes, and legacy v:/i:/a:.
        assert!(!LocalMedia::is_synthetic("img_deadbeef"));
        assert!(!LocalMedia::is_synthetic("vid_deadbeef"));
        assert!(!LocalMedia::is_synthetic("aud_deadbeef"));
        assert!(!LocalMedia::is_synthetic("deadbeefcafe"));
        assert!(!LocalMedia::is_synthetic("v:deadbeef"));
        assert!(!LocalMedia::is_synthetic("i:deadbeef"));
        assert!(!LocalMedia::is_synthetic("a:deadbeef"));
    }

    #[test]
    fn bare_id_strips_every_prefix() {
        assert_eq!(bare_id("v:deadbeef"), "deadbeef");
        assert_eq!(bare_id("a:deadbeef"), "deadbeef");
        assert_eq!(bare_id("i:deadbeef"), "deadbeef");
        assert_eq!(bare_id("deadbeef"), "deadbeef");
    }

    #[test]
    fn kind_prefixes() {
        assert_eq!(MediaKind::Image.prefix(), "");
        assert_eq!(MediaKind::Video.prefix(), "v:");
        assert_eq!(MediaKind::Audio.prefix(), "a:");
    }

    #[test]
    fn audio_mime_sniffing() {
        assert_eq!(audio_mime(b"OggS\x00\x02..."), "audio/ogg");
        assert_eq!(audio_mime(&[0x1A, 0x45, 0xDF, 0xA3, 0x01]), "audio/webm");
        assert_eq!(audio_mime(b"\x00\x00\x00\x20ftypM4A "), "audio/mp4");
        assert_eq!(audio_mime(b"ID3\x03..."), "audio/mpeg");
        assert_eq!(audio_mime(b"unknownbytes"), "audio/webm"); // safe default
    }

    #[test]
    fn image_mime_sniffing() {
        assert_eq!(image_mime(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]), "image/png");
        assert_eq!(image_mime(b"GIF89a..."), "image/gif");
        assert_eq!(image_mime(b"RIFF\x00\x00\x00\x00WEBPVP8 "), "image/webp");
        assert_eq!(image_mime(b"\x00\x00\x00\x18ftypheic"), "image/heic");
        assert_eq!(image_mime(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(image_mime(b"unknownbytes"), "image/jpeg"); // safe default
    }
}
