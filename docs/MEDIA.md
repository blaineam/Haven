# Media pipeline (compression + privacy)

How a picked photo/video becomes the bytes a circle receives, per platform. The goals are the same
everywhere: **strip identifying metadata (GPS above all) always**, and **shrink media when
"optimize" is on** so a peer can't inflate everyone's storage or the transfer with a 4K original.

Media is content-addressed (`img_`/`vid_`/`aud_` + sha-256 of the **plaintext** bytes) and sealed at
rest. The ref is minted from the *final* encoded bytes we store and send, so all compression/strip
happens **before** the ref exists.

## What "optimize" means

`optimize` (a.k.a. auto-optimize) is **on by default**, resolved per circle (a circle override falls
back to the app-wide default). It controls **compression only** — metadata stripping is unconditional.

| Setting | Apple | Android | Desktop |
| --- | --- | --- | --- |
| App-wide default | `SettingsStore.autoOptimize` | `ProfileStore.autoOptimize` | (always on for images/videos) |
| Per-circle override | `CircleSettingsStore.autoOptimize(circle)` | `CircleSettings.optimize(circle)` | — |

Desktop has no user-facing optimize toggle today: images are always canvas-re-encoded and videos are
always transcoded (both strip metadata as a side effect).

## The targets, and where they live

Each platform keeps **one** constants block, so the three can be diffed at a glance:

| Platform | File |
| --- | --- |
| Apple | `apple/HavenApp/MediaOptimizationTarget.swift` + `apple/HavenApp/VideoEncoder.swift` |
| Android | `android/app/src/main/java/com/blaineam/haven/core/MediaTargets.kt` |
| Desktop | `MEDIA_TARGETS` in `desktop/ui/app.js` |

| Target | Value | Apple | Android | Desktop |
| --- | --- | --- | --- | --- |
| Video long edge | 1920 | ✅ | ✅ | ✅ |
| Video bitrate | **4.5 Mbps, explicit** | ✅ | ✅ | ✅ |
| Video codec | H.264 | ✅ | ✅ | ❌ VP8/9 (WebM) |
| Faststart (`moov` first) | required | ✅ | ✅ (muxer already does it) | ❌ n/a to WebM |
| Rotation | upright on arrival | ✅ baked into pixels | ✅ MP4 display matrix | decoder-handled |
| Audio-in-video | AAC 128 kbps | ✅ | ⚠️ copied through | ✅ |
| Stills | 1600px, JPEG q0.62 | ✅ | ✅ | ✅ |
| Standalone audio | AAC 96 kbps, channels preserved (≤2) | ✅ | n/a (no import path) | ✅ |
| Length cap | 15 min, refused at import | ✅ | ✅ | ✅ |

**Why an explicit bitrate at all.** Both the old Apple and old Android paths capped *dimensions* and
let the encoder choose its own rate — ~8 Mbps at 1080p. Apple got that from
`AVAssetExportSession` presets; Android computed "≈4 bits/pixel clamped to 2–8 Mbps", which at
1920×1080 is 8.3 Mbps and therefore pinned to its own 8 Mbps ceiling on every clip — adaptive in
appearance only. That is why a real device was holding 53 items / 1.3 GB with single videos at
320 MB. Dimensions alone do not target a size; a bitrate does.

Measured after the rewrite — Apple, real library videos: 305.7 MB → 37.7, 191.5 → 47.0, 179.9 → 22.4.
Android, `VideoTranscodeTargetTest` on a 1080p fixture: **5.80 MB / 12,170 kbps → 2.30 MB /
4,822 kbps (40%)**, H.264, duration and rotation intact.

### Known divergences (decisions, not oversights)

- **Android does not bake rotation into pixels.** Apple bakes it because its writer emits a
  transform tag some Android decode paths ignore, so a portrait iPhone clip arrived sideways. The
  reverse is not a problem: `MediaMuxer.setOrientationHint` writes the standard MP4 `tkhd` display
  matrix, honoured by AVFoundation, ExoPlayer and Chrome. Baking it would mean replacing the
  decoder→encoder-surface path with an EGL/SurfaceTexture pass (~250 lines) to fix a bug Android
  does not have. If it is ever needed, `Mp4Composer.rotation()` from the mp4compose dependency the
  app already ships for story filters is the cheap route.
- **Android copies the audio track through instead of re-encoding to 128 kbps.** The source is
  virtually always already AAC from the camera; re-encoding costs a second decode/encode pair and a
  class of interleaving bug for a few hundred KB.
- **Desktop cannot emit H.264/MP4.** `MediaRecorder` produces VP8/VP9 + Opus in WebM and there is no
  encoder on the Rust side. Desktop matches every dimension, bitrate and cap exactly, and diverges
  on container/codec only. Closing it means a real encoder in `src-tauri` and moving transcode out
  of the WebView — a project, not a patch.
- **Android has no audio-file import path**, so `STANDALONE_AUDIO_BITRATE` has no call site yet;
  every `aud_` ref comes from the in-app recorder, which writes mono AAC at 64 kbps (already below
  the 96 kbps ceiling, so it is deliberately *not* raised to "meet" the target).

### Never inflate

`VIDEO_BITRATE` is a target, not a ceiling on the source. A clip already leaner than 4.5 Mbps — a
screen recording, something re-shared, anything a sender already compressed — would otherwise be
re-encoded *up* to the target, paying bytes **and** a generation of quality. Android compares the
transcoded output against the source and falls through to the lossless strip-remux when the
"optimized" bytes are not actually smaller (`readVideoBytes`). Caught by measurement, not review: a
720p fixture went in at 0.48 MB and came out at 0.59 MB before the guard existed.

## Parameters in effect

### Images

| | optimize ON | optimize OFF |
| --- | --- | --- |
| **Apple** (`MediaStore.addImage`) | long edge ≤ 1600px, JPEG q0.62 | original size, JPEG q0.95 |
| **Android** (`loadAndDownscale`) | long edge ≤ 1600px, JPEG q62 | long edge ≤ 4096px, JPEG q95 |
| **Desktop** (`imageToJpegBase64`) | long edge ≤ 1600px, JPEG q0.62 | (same — no "off") |

All three re-encode from a decoded bitmap, which bakes in EXIF orientation and **drops all EXIF
(orientation, GPS, device)**. So images never leak location, on any platform, in any mode.

Avatars: 192px JPEG q0.70 (rides the signed profile card) — Apple `Profile.avatarBase64`, Android
`loadAvatarB64`.

### Video

| | optimize ON | optimize OFF |
| --- | --- | --- |
| **Apple** (`MediaStore.addVideo` → `VideoEncoder.encode`) | ≤1080p H.264 @ 4.5 Mbps + AAC 128k, faststart, rotation baked | passthrough remux (same codec/quality), faststart |
| **Android** (`readVideoBytes` → `transcodeVideo`) | ≤1080p H.264 @ 4.5 Mbps + copied audio, faststart, rotation as display matrix | passthrough remux (same codec/quality) |
| **Desktop** (`handleFiles` → `optimizeVideoStrippingMetadata`) | ≤1080p @ 4.5 Mbps via canvas+MediaRecorder (VP8/9 WebM) | (same — no "off") |

Apple's ladder falls back preset-export → passthrough remux if the bitrate encode fails, so a clip
it cannot handle is still shareable rather than lost. Android's falls back to the strip-remux, which
is also where the never-inflate guard sends already-lean clips.

Metadata handling (GPS) is **always** applied, in every mode:

- **Apple** — every `AVAssetExportSession` calls `stripIdentifyingMetadata()`
  (`metadata = []` **and** `metadataItemFilter = .forSharing()`; the filter is the one that actually
  removes the QuickTime `loci` UserData box — `metadata = []` alone does not). The optimize path bakes
  camera rotation into pixels (Android ignores the rotation track tag). The OFF path is a
  `AVAssetExportPresetPassthrough` remux that still strips + faststarts.
- **Android** — `transcodeVideo` writes a **new** `MediaMuxer` container, which emits no `loci`/`udta`
  userdata unless `setLocation` is called (it never is), so GPS is gone. The OFF/fallback path
  (`stripVideoMetadata`) is an extractor→muxer passthrough remux with the same guarantee — no
  re-encode, samples copied verbatim. Rotation is preserved as a muxer **orientation hint** (display
  geometry, not identity), so nothing is baked and no OpenGL pass is needed. On any transcode
  failure/stall, it falls back to the strip remux; the raw bytes are the last resort only when BOTH
  fail (an unprocessable asset).
- **Desktop** — `optimizeVideoStrippingMetadata` re-encodes through a canvas + `MediaRecorder`, which
  produces an entirely new container so no source metadata survives. If `MediaRecorder` is
  unavailable in the webview, the attachment is **rejected with a user warning** — it never silently
  ships the located original. (Prior behavior: `fileToBase64` sent the raw file bytes with GPS intact —
  the desktop leak this closes.)

  **Drag-and-drop used to bypass all of that.** The drop handler called a Rust `add_media_path` that
  sealed the file straight from disk — no decode, no downscale, no strip — so a dragged photo or clip
  shipped its capture GPS at full resolution while the file picker beside it was clean. Drops now go
  through `read_media_file_b64` (extension allowlist + size cap enforced in Rust) into the same
  `sanitizeMediaFile` chokepoint every other import uses. Every desktop import path is now processed;
  there is no unprocessed route left.

#### Android transcode specifics (`transcodeVideo`)

- Pipeline: `MediaExtractor` → hardware `MediaCodec` decoder → **encoder's input Surface** → AVC
  encoder → `MediaMuxer`. Feeding the decoder straight into the encoder's input surface scales frames
  to the encoder's configured (downscaled) size via the BufferQueue — no GL. Audio track copied through
  verbatim.
- Target size: fit within 1920×1080 (long×short edge), preserve aspect, never upscale, even dims.
- Target bitrate: an **explicit** `MediaTargets.VIDEO_BITRATE` (4.5 Mbps), never above the source's
  declared bitrate, and never producing output larger than the source (see "Never inflate" above).
- Faststart: `Mp4Faststart.relocate` moves `moov` ahead of `mdat` and fixes the `stco`/`co64` chunk
  offsets. Measured on API 35, `MediaMuxer` already emits `ftyp moov free mdat`, so this is a no-op
  on the ordinary path; it is kept because that reservation is best-effort and OEM muxers are not
  obliged to make it. It returns null (keep the muxer's bytes) for anything already correct or not
  fully understood — a slightly worse stream beats a corrupted one.
- Off-heap by construction (frames live in native codec buffers/surface), so it does not reintroduce
  the large-media OOM the sealed store avoids. A 20s no-progress stall guard converts a wedged codec
  into a fallback rather than a hang.
- 60 MB attachment cap is applied **after** transcode (a shrunk clip is checked at its final size).

Stories/trim/mute/filter video exports on Apple all go through `AVAssetExportSession` and call
`stripIdentifyingMetadata()` too, so derived clips carry no location either.

## Size caps

- **Length: 15 minutes, all three platforms, refused at import** before any ref is minted. A product
  limit, not a technical one: without it a person can hand their circle a feature film and every
  member's device pays to store and move it. Apple's `addVideo` returns `""` and every call site
  skips it; Android's `readVideoBytes` returns null, which every call site already treats as "skip";
  desktop refuses in `sanitizeMediaFile` with a toast. A refusal must never become a ref with no
  bytes behind it.
- Android picked video: 60 MB, applied after transcode/remux (`readVideoBytes`).
- Cross-device transfer: blobs > 256 MB move as 8 MB chunks (`HVCHUNK1` manifest); see the chunked-media
  notes.

## Shipped: "Re-optimize media I already shared" (Apple, Android)

Settings ▸ Storage. Everything above only ever applied to the *next* thing you post; this is the
lever for what is already out there. Apple `MediaReoptimize.swift` + `MediaOptimizationTarget.swift`;
Android `MediaReoptimizer.kt` + `MediaOptimizationTarget.kt`. Read Apple's header comment first — it
is the spec, including why the two obvious alternatives are wrong.

The constraint is the same one the deferred section below runs into: **a ref is `sha256(plaintext)`**,
so re-encoding produces a NEW address and there is no way to shrink a blob in place. The three
options were an alias table (rejected: whoever controls the table controls what a signed post shows),
keeping both copies (rejected: nothing can ever be swept, so the saving is imaginary), and **editing
the post** to name the new ref — which is what shipped. An Edit already carries a full media array,
keeps the item's id, author, thread position and original timestamp, and is author-signed.

Consequences that are load-bearing rather than incidental:

- **Only your own posts and comments are eligible.** An Edit is signed by the author; the reducer
  (`haven-p2p/src/social.rs`) drops one whose signer isn't the item's author. So this shrinks what
  you put *into* your circles. Media others sent you is the deferred feature below.
- **The old blob is not deleted here.** A member who is offline still holds the pre-edit post naming
  the old ref; deleting the bytes hands them a permanently broken post. The old copy retires through
  the weekly orphan sweep, which already skips anything a live event references.
- **Nothing notifies or reorders.** Apple broadcasts with a `silent` flag so no push banner is
  sealed. Android's author path sends no push at all, and the recipient's `notifyInbound` is gated on
  a <10-minute-old newest inbound item that hasn't already been notified under its (unchanged) event
  id — so a re-shared old post cannot raise a banner there either.
- **Never keep a re-encode that isn't smaller.** `requiredShrinkFactor` / `keepsNewEncode` (0.90)
  compares the real output against the real source. The bitrate target is not a ceiling on the
  source, so an already-lean clip inflates; the original is kept and the ref added to a persisted,
  bounded skip set so it is never offered again.
- **Bounded by construction.** No timer, no launch hook, no background scheduling — a button is the
  only caller. 25 items per tap, cancellable between items, one encode in flight, and a disk-headroom
  refusal before each item.
- **Convergence is the safety property.** The probe's ceilings carry headroom over the encoder's
  nominal rates so the encoder's *own* output re-probes as at-target; otherwise the scan re-offers
  what the last run produced, forever. Measured on device (`MediaReoptimizeInstrumentedTest`):
  12170 kbps in → 4822 kbps out against a 6016 kbps trigger; a 3000px q95 still, 5.4 MB → 259 KB.

Android-only divergences:

- **Probing costs a decrypt**, because Android keeps media sealed at rest while Apple keeps it
  plaintext. The interest floor is applied to the sealed file length first (free), videos decrypt
  off-heap via `openCircleMediaFile`, and a plaintext cache the scan *created* is deleted again.
- **A swap only applies in the circle its new blob was sealed to.** `LocalMedia.store` seals to one
  circle and there is one file per ref, so rewriting a second circle's post to the same new ref would
  leave that circle naming a blob the device cannot open. The other circle keeps the old ref.
- **Audio is never a candidate.** Android has no audio-file import path, so every `aud_` ref it
  authored came from the recorder at 64 kbps mono AAC — provably already at target.

## Deferred: "Optimize media from others" (recompress-on-receive)

Not yet shipped. The intent is an anti-abuse control (default ON) that recompresses media **received**
from other users to the local optimize target before storing/displaying it, with a per-item "Download
original" affordance to re-fetch the full-quality blob on demand.

This is deferred because it conflicts with the just-stabilized content-addressed store and must not be
half-landed:

- The ref is `sha256(plaintext)` and is **verified on every read/inbound store** (Apple
  `MediaStore.verify` / `store` / `adopt`; Android `LocalMedia.checked` / `verifiesRef` /
  `storeUnderRef` / `adoptSealedPart`). Recompressed bytes do **not** hash to the original ref, so they
  cannot be stored under it — the verifier would (correctly) reject them and the media would go blank.
- Doing it right therefore needs a **dual-key** model: keep the original sealed blob addressable by its
  content ref (so "Download original" via the existing missing-media fetch still works — engine
  `request_missing_media` / `HavenNet` media request), and store the recompressed copy under a
  **derived local key**, with the render/thumbnail entry points on all three platforms consulting the
  derived key first. That touches the inbound chokepoints and the whole render path and risks
  corrupting inbound media, so it wants its own pass.

### Concrete plan / code paths when picked up

1. **Setting** — add `optimizeOthers` (default true) next to the existing media prefs:
   Apple `SettingsStore` + `CircleSettingsStore` (mirror the `autoOptimize` plumbing) and the
   `CircleSettingsView` "Media in this circle" section; Android `ProfileStore` (`KEY_*`) +
   `CircleSettings` (`boolOverride`/resolved getter) and the settings UI; desktop settings + UI.
2. **Recompress-on-receive** — at each inbound chokepoint, when the sender ≠ me and `optimizeOthers` is
   on and the payload exceeds target: after verifying+storing the original under its content ref,
   produce a downscaled derived copy (reuse `optimizeVideo`/`transcodeVideo`/`imageToJpegBase64` and the
   still-image downscalers) and record `originalRef → derivedLocalKey`. Decode failure ⇒ keep original
   only (never corrupt).
   - Apple: `MediaStore.store(_:_:)` and `MediaStore.adopt(_:from:)`.
   - Android: `LocalMedia.storeUnderRef` and `LocalMedia.adoptSealedPart`.
   - Desktop: this lives in `desktop/src-tauri/src` (Rust; out of scope here) — the receive/store path
     there needs the same derived-key logic. **TODO (backend):** add a Rust-side downscale/derived-key
     store, or forward received blobs to the JS layer for canvas recompression before sealing.
3. **Render** — `item`/`thumbnail`/`imageBitmap`/`videoFile` prefer the derived key when present.
4. **Download original** — a per-item action that drops the derived copy and re-fetches the original ref
   through the existing missing-media path.
