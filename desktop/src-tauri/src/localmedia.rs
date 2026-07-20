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

pub fn bare_id(reference: &str) -> &str {
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

    /// The on-disk path of the at-rest SEALED blob for a ref, when we hold it. For callers that must
    /// work off the file rather than read it into RAM (a several-hundred-MB video).
    pub fn sealed_path(&self, reference: &str) -> Option<PathBuf> {
        let p = self.dir.join(bare_id(reference));
        if p.exists() { Some(p) } else { None }
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

    // ---- Positional (peer-to-peer) reassembly ----------------------------------------------
    // The peer chunk path (frames 3/5/33) is different from the relay one above in two ways that
    // matter: its chunks are PLAINTEXT (each is opened on arrival) and they arrive OUT OF ORDER and
    // with gaps. So it can't append — it seeks to `index * chunkSize` and writes there, leaving a
    // sparse file with holes in exactly the right places. That is what makes a transfer resumable:
    // the partial is a real, restartable artifact rather than a `HashMap<u32, Vec<u8>>` in RAM that
    // dies with the process (which is what this replaced — along with its silent 1 GB cap, above
    // which a completed transfer was simply thrown away).
    //
    // Its scratch is named `incoming_p2p_…` — distinct from the sealed relay part for the same ref,
    // which would otherwise be the SAME file holding sealed bytes, and still `incoming_`-prefixed so
    // no sweep or inventory mistakes it for a stored blob. Nothing can name it as a storage key, so
    // `has(ref)` stays false until the whole thing is adopted.

    /// The scratch file name a peer reassembly of `reference` uses. Persisted (a NAME, not a path —
    /// the media dir differs per install) and matched by the orphan sweep's spare-list.
    pub fn part_name(reference: &str) -> String {
        format!("incoming_p2p_{}.part", bare_id(reference))
    }

    pub fn part_path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    /// A fresh, EMPTY part file for a peer reassembly starting from nothing. Truncating on purpose:
    /// leftovers from an abandoned transfer of the same ref would sit at offsets we never rewrite
    /// and fail the content-address check at adoption. Only ever called when no record exists —
    /// resuming an existing transfer must never come through here.
    pub fn new_plain_part(&self, reference: &str) -> PathBuf {
        let p = self.dir.join(Self::part_name(reference));
        let _ = fs::File::create(&p);
        p
    }

    /// Write one chunk's plaintext at its own offset. `false` on any IO failure, and the caller MUST
    /// treat that as "this chunk did not arrive": recording a chunk whose bytes aren't on disk is the
    /// one direction the persisted bitmap can be wrong in that leaves a permanent hole.
    pub fn write_part_at(&self, part: &Path, offset: u64, bytes: &[u8]) -> bool {
        use std::io::{Seek, SeekFrom, Write};
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(part)
            .and_then(|mut f| {
                f.seek(SeekFrom::Start(offset))?;
                f.write_all(bytes)
            })
            .is_ok()
    }

    /// Adopt a fully-reassembled PLAINTEXT part file as `reference`'s stored blob.
    ///
    /// The content address is verified BEFORE the seal and STREAMED, so a substituted or short
    /// partial is rejected without a hundreds-of-MB video ever landing in a `Vec` here — the same
    /// gate `store_under_ref` applies, minus its whole-file buffer. A rejected partial is deleted:
    /// its bytes can never become the ref they claim, so keeping them only strands the transfer.
    pub fn adopt_plain_part(
        &self,
        social: &Arc<HavenSocial>,
        circle_id: &str,
        reference: &str,
        part: &Path,
    ) -> bool {
        if !mediaref::verify_file(reference, part) {
            eprintln!(
                "media REJECTED {}: reassembled bytes do not match its content address",
                &reference[..reference.len().min(12)]
            );
            let _ = fs::remove_file(part);
            return false;
        }
        let dst = self.dir.join(bare_id(reference));
        let sealed = social.seal_circle_media_file(
            circle_id.to_string(),
            part.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
        );
        if !sealed {
            // Same fallback as `store_file` (unknown circle / IO error in the file seal): seal in
            // memory, or keep the plaintext, rather than losing media we just spent a transfer on.
            let Ok(bytes) = fs::read(part) else { return false };
            let to_write = social
                .seal_circle_media(circle_id.to_string(), bytes.clone())
                .unwrap_or(bytes);
            if fs::write(&dst, &to_write).is_err() {
                return false;
            }
        }
        let _ = fs::remove_file(part);
        true
    }

    /// Delete every stored media file (part of "start over").
    pub fn clear(&self) {
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let _ = fs::remove_file(e.path());
            }
        }
    }

    // ---- Deletion & GC ------------------------------------------------------------------
    // Blobs never deleted themselves: `purge_expired` drops the EVENTS but the sealed bytes lived
    // forever. Deletion is ref-driven — the engine hands back purged refs, the engine subtracts
    // anything a live event anywhere still names, and the rest is removed here. The orphan sweep
    // covers what purging can't reach (unsent/abandoned staging, stale `incoming_*.part` scratch).

    /// The on-disk file name a ref is stored under. Storage has always keyed on the LOCAL `bare_id`
    /// (desktop mints strip `v:`/`a:`/`i:`; inbound `img_`/`vid_`/`aud_` refs keep their prefix), so
    /// this is the one mapping both [`Self::delete`] and the sweep's keep-set must share.
    pub fn storage_name(reference: &str) -> String {
        bare_id(reference).to_string()
    }

    /// Remove a ref's blob from disk. Only call with refs no live event references — the caller
    /// owns the in-use check. Returns the bytes freed.
    pub fn delete(&self, reference: &str) -> u64 {
        if Self::is_synthetic(reference) {
            return 0;
        }
        let p = self.dir.join(bare_id(reference));
        let len = fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
        if fs::remove_file(&p).is_ok() {
            len
        } else {
            0
        }
    }

    /// Delete every stored file whose name is not in `keep` (built by the caller from every
    /// circle's feed + comments + scheduled sends via [`Self::storage_name`]). A GRACE window skips
    /// anything modified recently: media staged in a composer but not yet posted and an in-flight
    /// `incoming_*.part` reassembly have fresh mtimes and no referencing event YET — age, not
    /// referencedness, is what makes those safe to judge. Dot-files (the GC stamp) are never touched.
    ///
    /// `live_parts` (part file NAME → epoch secs of its last progress, from
    /// [`crate::mediaresume::ReassemblyIndex::live_parts`]) names the partials belonging to a
    /// RESUMABLE peer transfer. Those are 99%-complete downloads waiting for the rest, not leaked
    /// scratch, and deleting them was half of why large media never arrived: the transfer survived
    /// in principle, and then this sweep threw the bytes away. They are spared until ABANDONED — no
    /// progress in [`crate::mediaresume::EXPIRY_SECS`] — after which they expire here regardless of
    /// the (longer) mtime grace, so a stalled transfer can't accumulate disk either.
    ///
    /// Returns (bytes_freed, files_removed).
    pub fn sweep_orphans(
        &self,
        keep: &std::collections::HashSet<String>,
        grace_secs: u64,
        live_parts: &std::collections::HashMap<String, u64>,
    ) -> (u64, usize) {
        let cutoff = std::time::SystemTime::now()
            .checked_sub(std::time::Duration::from_secs(grace_secs));
        let abandoned = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
            .saturating_sub(crate::mediaresume::EXPIRY_SECS);
        let mut bytes = 0u64;
        let mut files = 0usize;
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let path = e.path();
                let Ok(md) = e.metadata() else { continue };
                if !md.is_file() {
                    continue;
                }
                let Some(name) = path.file_name().and_then(|n| n.to_str()) else { continue };
                if name.starts_with('.') || keep.contains(name) {
                    continue;
                }
                match live_parts.get(name) {
                    Some(&progressed) if progressed > abandoned => continue, // live transfer — spare it
                    // Abandoned: judged by its own 24h expiry, not the 48h grace.
                    Some(_) => {}
                    None => {
                        let fresh = match (md.modified().ok(), cutoff) {
                            (Some(m), Some(c)) => m > c,
                            _ => true, // unreadable mtime = treat as fresh (never judge it)
                        };
                        if fresh {
                            continue;
                        }
                    }
                }
                bytes += md.len();
                files += 1;
                let _ = fs::remove_file(&path);
            }
        }
        (bytes, files)
    }

    // ---- Cleanup screen (#1) + local-limit sweep (#4) -----------------------------------
    // Storage keys on the LOCAL `bare_id` (== `storage_name`), so a stored file's basename IS the
    // storage_name a ref maps to. Both the size-sorted cleanup inventory and the age/size limit sweep
    // walk the dir; the caller joins the names back to events (and to the pinned/in-use/evicted sets).

    /// Every stored media blob with its size + mtime (unix secs), for the size-sorted "Manage media"
    /// screen and as the raw material the caller joins to owning events. Skips in-flight reassembly
    /// scratch (`incoming_*.part`) and hidden/dot files (the `.gc-stamp`). Returns (name, bytes,
    /// mtime_secs). Mirrors iOS `MediaStore.storedBlobs`.
    pub fn stored_blobs(&self) -> Vec<(String, u64, u64)> {
        let mut out = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let Ok(md) = e.metadata() else { continue };
                if !md.is_file() {
                    continue;
                }
                let path = e.path();
                let Some(name) = path.file_name().and_then(|n| n.to_str()) else { continue };
                if name.starts_with('.') || name.starts_with("incoming_") {
                    continue;
                }
                let mtime = md
                    .modified()
                    .ok()
                    .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                out.push((name.to_string(), md.len(), mtime));
            }
        }
        out
    }

    /// The client sibling of the relay's retention: evict this device's cached blobs by AGE then SIZE
    /// (oldest first) until under the caps. Unlike the orphan sweep, a blob a live event still
    /// references IS eligible here — it just becomes a re-downloadable placeholder (the caller records
    /// such refs in the evicted set so the missing-media sweep doesn't auto-refetch them). `pinned`
    /// (device-pin storage names) and composer-staged / in-flight media (fresh mtime, grace window)
    /// are never touched. `in_use` (feed+comment storage names) decides which evicted refs to record.
    /// Returns (bytes_freed, files_removed, evict-map of referenced deleted names -> bytes). Mirrors
    /// iOS `MediaStore.performLimitSweep`.
    pub fn perform_limit_sweep(
        &self,
        max_days: u32,
        max_gb: u32,
        pinned: &std::collections::HashSet<String>,
        in_use: &std::collections::HashSet<String>,
        grace_secs: u64,
    ) -> (u64, usize, std::collections::HashMap<String, u64>) {
        // Convert the user-facing whole-day / whole-GB caps into the raw seconds / bytes the walk
        // uses (0 = that cap is off). Splitting the unit conversion out keeps the walk testable with
        // small values (whole-GB / whole-day caps can't express a KB-scale unit test otherwise).
        let max_age_secs = (max_days as u64).saturating_mul(86_400);
        let max_bytes = (max_gb as u64).saturating_mul(1_000_000_000);
        self.limit_sweep_raw(max_age_secs, max_bytes, pinned, in_use, grace_secs)
    }

    /// The unit-testable core of [`Self::perform_limit_sweep`]: caps expressed as raw seconds / bytes
    /// (0 = off). Same age-then-size, oldest-first, pinned-skip semantics.
    fn limit_sweep_raw(
        &self,
        max_age_secs: u64,
        max_bytes: u64,
        pinned: &std::collections::HashSet<String>,
        in_use: &std::collections::HashSet<String>,
        grace_secs: u64,
    ) -> (u64, usize, std::collections::HashMap<String, u64>) {
        let mut evict: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
        if max_age_secs == 0 && max_bytes == 0 {
            return (0, 0, evict);
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        struct Cand {
            path: PathBuf,
            name: String,
            bytes: u64,
            mtime: u64,
        }
        let mut cands: Vec<Cand> = Vec::new();
        let mut pinned_bytes = 0u64;
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for e in entries.flatten() {
                let Ok(md) = e.metadata() else { continue };
                if !md.is_file() {
                    continue;
                }
                let path = e.path();
                let Some(name) = path.file_name().and_then(|n| n.to_str()).map(|s| s.to_string()) else { continue };
                if name.starts_with('.') || name.starts_with("incoming_") {
                    continue;
                }
                let bytes = md.len();
                if pinned.contains(&name) {
                    pinned_bytes += bytes; // device-pinned: never evict, but still counts toward the size cap
                    continue;
                }
                // Unreadable mtime → treat as fresh (never judge it).
                let Some(mtime) = md
                    .modified()
                    .ok()
                    .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                else {
                    continue;
                };
                if mtime + grace_secs > now {
                    continue; // too fresh to judge (composer-staged / in-flight)
                }
                cands.push(Cand { path, name, bytes, mtime });
            }
        }
        let mut marked: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut order: Vec<usize> = Vec::new();
        // Age pass: anything older than the age cap.
        if max_age_secs > 0 {
            let age_cutoff = now.saturating_sub(max_age_secs);
            for (i, c) in cands.iter().enumerate() {
                if c.mtime < age_cutoff && marked.insert(i) {
                    order.push(i);
                }
            }
        }
        // Size pass: oldest-first until the (pinned + surviving) total is under the cap.
        if max_bytes > 0 {
            let cap = max_bytes;
            let mut survivors: Vec<usize> = (0..cands.len()).filter(|i| !marked.contains(i)).collect();
            survivors.sort_by_key(|&i| cands[i].mtime); // oldest first
            let mut total = pinned_bytes + survivors.iter().map(|&i| cands[i].bytes).sum::<u64>();
            let mut k = 0;
            while total > cap && k < survivors.len() {
                let i = survivors[k];
                if marked.insert(i) {
                    order.push(i);
                    total = total.saturating_sub(cands[i].bytes);
                }
                k += 1;
            }
        }
        let mut freed = 0u64;
        let mut files = 0usize;
        for i in order {
            let c = &cands[i];
            if fs::remove_file(&c.path).is_ok() {
                freed += c.bytes;
                files += 1;
                if in_use.contains(&c.name) {
                    evict.insert(c.name.clone(), c.bytes);
                }
            }
        }
        (freed, files, evict)
    }

    /// True when the persisted GC stamp is older than `min_interval_secs` (or absent) — gates the
    /// startup-throttled weekly sweep.
    pub fn gc_due(&self, min_interval_secs: u64) -> bool {
        let stamp = self.dir.join(".gc-stamp");
        match fs::metadata(&stamp).and_then(|m| m.modified()) {
            Ok(m) => std::time::SystemTime::now()
                .duration_since(m)
                .map(|d| d.as_secs() >= min_interval_secs)
                .unwrap_or(false),
            Err(_) => true,
        }
    }

    /// Record "a sweep just ran" (see [`Self::gc_due`]).
    pub fn touch_gc_stamp(&self) {
        let _ = fs::write(self.dir.join(".gc-stamp"), b"");
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

    // ---- #1/#4 cleanup + limit-sweep primitives -------------------------------------------

    use std::collections::HashSet;

    /// A LocalMedia backed by a fresh unique temp dir.
    fn tmp_media() -> (LocalMedia, PathBuf) {
        let base = std::env::temp_dir().join(format!(
            "haven-localmedia-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        (LocalMedia::new(base.clone()), base)
    }

    /// Write a `size`-byte blob whose mtime is `age_secs` in the past (portable via
    /// `File::set_modified`, stable since Rust 1.75).
    fn write_aged(dir: &Path, name: &str, size: usize, age_secs: u64) {
        let p = dir.join(name);
        fs::write(&p, vec![0u8; size]).unwrap();
        let when = std::time::SystemTime::now() - std::time::Duration::from_secs(age_secs);
        let f = fs::OpenOptions::new().write(true).open(&p).unwrap();
        f.set_modified(when).unwrap();
    }

    #[test]
    fn stored_blobs_lists_files_skipping_scratch_and_dotfiles() {
        let (m, dir) = tmp_media();
        fs::write(dir.join("aaaa"), vec![0u8; 1000]).unwrap();
        fs::write(dir.join("bbbb"), vec![0u8; 2000]).unwrap();
        fs::write(dir.join("incoming_cccc.part"), vec![0u8; 500]).unwrap(); // in-flight scratch → skip
        fs::write(dir.join(".gc-stamp"), b"").unwrap(); // dot-file → skip
        let mut blobs = m.stored_blobs();
        blobs.sort_by(|a, b| a.0.cmp(&b.0));
        let names: Vec<&str> = blobs.iter().map(|(n, _, _)| n.as_str()).collect();
        assert_eq!(names, vec!["aaaa", "bbbb"]);
        assert_eq!(blobs.iter().find(|(n, _, _)| n == "aaaa").unwrap().1, 1000);
        assert_eq!(blobs.iter().find(|(n, _, _)| n == "bbbb").unwrap().1, 2000);
        let _ = fs::remove_dir_all(&dir);
    }

    /// The half of the resume fix that lives here: the sweep that reclaims leaked scratch must not
    /// reclaim a 99%-complete download waiting for its last chunk — that was the second reason large
    /// media never arrived (the transfer survived, then the sweep threw the bytes away).
    #[test]
    fn sweep_spares_a_live_partial_and_expires_an_abandoned_one() {
        let (m, dir) = tmp_media();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        // Both are old enough for the 48h grace to judge them.
        write_aged(&dir, "incoming_p2p_live.part", 1000, 72 * 3600);
        write_aged(&dir, "incoming_p2p_dead.part", 1000, 72 * 3600);
        write_aged(&dir, "incoming_p2p_untracked.part", 1000, 72 * 3600);
        let live: std::collections::HashMap<String, u64> = [
            ("incoming_p2p_live.part".to_string(), now - 60), // progress a minute ago
            ("incoming_p2p_dead.part".to_string(), now - crate::mediaresume::EXPIRY_SECS - 60),
        ]
        .into_iter()
        .collect();
        let (_, files) = m.sweep_orphans(&HashSet::new(), 48 * 3600, &live);
        assert!(dir.join("incoming_p2p_live.part").exists(), "a live reassembly's bytes must survive");
        assert!(!dir.join("incoming_p2p_dead.part").exists(), "no progress in 24h = abandoned");
        // A partial with no record at all (e.g. the sealed relay reassembly) keeps the old 48h rule.
        assert!(!dir.join("incoming_p2p_untracked.part").exists());
        assert_eq!(files, 2);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_partial_is_never_mistaken_for_a_stored_blob() {
        // `has(ref)` must stay FALSE until every chunk is in, or the feed renders a hole and the
        // missing-media sweep stops asking for the rest. The part name is unreachable as a
        // storage key: storage keys are `bare_id(ref)`, which can never grow an `incoming_p2p_`
        // prefix or a `.part` suffix.
        let (m, dir) = tmp_media();
        let reference = "vid_deadbeef";
        let part = m.new_plain_part(reference);
        assert!(m.write_part_at(&part, 0, b"first chunk"));
        assert!(part.exists());
        assert!(!m.has(reference), "a partial must not answer has()");
        assert!(m.stored_blobs().is_empty(), "nor appear in the media inventory");
        // Built on the LOCAL `bare_id` (== `storage_name`), which strips only the legacy `v:`/`a:`/
        // `i:` schemes — so the part name is derived from exactly the string the finished blob would
        // be stored under, and the two can never collide.
        assert_eq!(LocalMedia::part_name(reference), "incoming_p2p_vid_deadbeef.part");
        assert_eq!(LocalMedia::part_name("v:deadbeef"), "incoming_p2p_deadbeef.part");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn positional_writes_fill_holes_in_any_order() {
        // Chunks arrive out of order and with gaps; the partial is a sparse file whose holes are in
        // exactly the right places, which is the whole basis of resuming one.
        let (m, dir) = tmp_media();
        let part = m.new_plain_part("img_x");
        assert!(m.write_part_at(&part, 8, b"CCCC")); // chunk 2 first
        assert!(m.write_part_at(&part, 0, b"AAAA")); // then chunk 0
        assert!(m.write_part_at(&part, 4, b"BBBB")); // then the hole between them
        assert_eq!(fs::read(&part).unwrap(), b"AAAABBBBCCCC");
        // A re-sent chunk is a rewrite of identical bytes at the same offset — never an append.
        assert!(m.write_part_at(&part, 4, b"BBBB"));
        assert_eq!(fs::read(&part).unwrap().len(), 12);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn limit_sweep_off_when_both_caps_zero() {
        let (m, dir) = tmp_media();
        write_aged(&dir, "aaaa", 1000, 100 * 86_400); // ancient, but caps off → untouched
        let (freed, files, evict) = m.perform_limit_sweep(0, 0, &HashSet::new(), &HashSet::new(), 0);
        assert_eq!((freed, files, evict.len()), (0, 0, 0));
        assert!(m.has("aaaa"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn limit_sweep_age_deletes_old_skips_fresh_and_pinned_records_evict() {
        let (m, dir) = tmp_media();
        write_aged(&dir, "old_ref", 1000, 40 * 86_400); // 40 days — older than the 30-day cap
        write_aged(&dir, "old_orphan", 1000, 40 * 86_400); // old, but not referenced
        write_aged(&dir, "old_pinned", 1000, 40 * 86_400); // old, but device-pinned
        write_aged(&dir, "fresh_ref", 1000, 1 * 86_400); // 1 day — under the cap
        let pinned: HashSet<String> = ["old_pinned".into()].into_iter().collect();
        let in_use: HashSet<String> = ["old_ref".into(), "fresh_ref".into()].into_iter().collect();
        // 30-day age cap, no size cap, small grace so nothing is "too fresh to judge".
        let (freed, files, evict) = m.perform_limit_sweep(30, 0, &pinned, &in_use, 3600);
        assert_eq!(files, 2); // old_ref + old_orphan
        assert_eq!(freed, 2000);
        assert!(!m.has("old_ref") && !m.has("old_orphan")); // both deleted
        assert!(m.has("old_pinned")); // pinned never touched
        assert!(m.has("fresh_ref")); // fresh never touched
        // Only the REFERENCED deletion is recorded evicted (→ "Download" placeholder); the orphan isn't.
        assert_eq!(evict.get("old_ref"), Some(&1000));
        assert!(!evict.contains_key("old_orphan"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn limit_sweep_size_evicts_oldest_first_and_skips_pinned() {
        let (m, dir) = tmp_media();
        // Use the raw (bytes/secs) core so a KB-scale size cap is expressible.
        write_aged(&dir, "oldest", 1000, 30 * 86_400);
        write_aged(&dir, "middle_pinned", 1000, 20 * 86_400);
        write_aged(&dir, "newest_ref", 1000, 10 * 86_400);
        let pinned: HashSet<String> = ["middle_pinned".into()].into_iter().collect();
        let in_use: HashSet<String> = ["oldest".into(), "newest_ref".into()].into_iter().collect();
        // Cap 1500 bytes: pinned (1000) counts toward the total, so 500 of budget remains for the two
        // candidates (2000 bytes). Oldest-first eviction removes "oldest" (1000) → total 2000 ≤ 1500? no.
        // total starts pinned(1000)+cands(2000)=3000; remove oldest → 2000; still > 1500 → remove
        // newest_ref → 1000 ≤ 1500 stop. Both candidates evicted; pinned retained.
        let (freed, files, evict) = m.limit_sweep_raw(0, 1500, &pinned, &in_use, 3600);
        assert_eq!(files, 2);
        assert_eq!(freed, 2000);
        assert!(m.has("middle_pinned")); // pinned never evicted
        assert!(!m.has("oldest") && !m.has("newest_ref"));
        assert_eq!(evict.get("oldest"), Some(&1000)); // referenced → recorded
        assert_eq!(evict.get("newest_ref"), Some(&1000));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn limit_sweep_size_under_cap_removes_nothing() {
        let (m, dir) = tmp_media();
        write_aged(&dir, "a", 1000, 30 * 86_400);
        write_aged(&dir, "b", 1000, 30 * 86_400);
        // 5000-byte cap, 2000 bytes on disk → nothing over cap.
        let (freed, files, evict) = m.limit_sweep_raw(0, 5000, &HashSet::new(), &HashSet::new(), 3600);
        assert_eq!((freed, files, evict.len()), (0, 0, 0));
        assert!(m.has("a") && m.has("b"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn limit_sweep_grace_protects_fresh_even_when_over_cap() {
        let (m, dir) = tmp_media();
        write_aged(&dir, "a", 1000, 10); // 10s old
        write_aged(&dir, "b", 1000, 10);
        // Tiny cap but a 1-day grace window → both are too fresh to judge, nothing removed.
        let (freed, files, _e) = m.limit_sweep_raw(0, 1, &HashSet::new(), &HashSet::new(), 86_400);
        assert_eq!((freed, files), (0, 0));
        assert!(m.has("a") && m.has("b"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn bare_id_matches_prefixed_and_bare_refs() {
        // The evicted/pinned matching in the engine keys on storage_name == bare_id.
        assert_eq!(LocalMedia::storage_name("v:deadbeef"), "deadbeef");
        assert_eq!(LocalMedia::storage_name("a:deadbeef"), "deadbeef");
        assert_eq!(LocalMedia::storage_name("i:deadbeef"), "deadbeef");
        assert_eq!(LocalMedia::storage_name("deadbeef"), "deadbeef");
        assert_eq!(bare_id("v:deadbeef"), "deadbeef");
        assert_eq!(bare_id("img_deadbeef"), "img_deadbeef"); // img_/vid_/aud_ keep their name
    }
}
