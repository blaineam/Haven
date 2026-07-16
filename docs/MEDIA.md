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

## Parameters in effect

### Images

| | optimize ON | optimize OFF |
| --- | --- | --- |
| **Apple** (`MediaStore.addImage`) | long edge ≤ 2048px, JPEG q0.70 | original size, JPEG q0.95 |
| **Android** (`loadAndDownscale`) | long edge ≤ 2048px, JPEG q70 | long edge ≤ 4096px, JPEG q95 |
| **Desktop** (`imageToJpegBase64`) | long edge ≤ 2048px, JPEG q0.82 | (same — no "off") |

All three re-encode from a decoded bitmap, which bakes in EXIF orientation and **drops all EXIF
(orientation, GPS, device)**. So images never leak location, on any platform, in any mode.

Avatars: 192px JPEG q0.70 (rides the signed profile card) — Apple `Profile.avatarBase64`, Android
`loadAvatarB64`.

### Video

| | optimize ON | optimize OFF |
| --- | --- | --- |
| **Apple** (`MediaStore.addVideo` → `optimizeVideo`) | re-encode to ≤1080p H.264 + AAC, faststart | passthrough remux (same codec/quality), faststart |
| **Android** (`readVideoBytes` → `transcodeVideo`) | re-encode to ≤1080p H.264 + copied audio | passthrough remux (same codec/quality) |
| **Desktop** (`handleFiles` → `optimizeVideoStrippingMetadata`) | re-encode to ≤1080p via canvas+MediaRecorder | (same — no "off") |

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

#### Android transcode specifics (`transcodeVideo`)

- Pipeline: `MediaExtractor` → hardware `MediaCodec` decoder → **encoder's input Surface** → AVC
  encoder → `MediaMuxer`. Feeding the decoder straight into the encoder's input surface scales frames
  to the encoder's configured (downscaled) size via the BufferQueue — no GL. Audio track copied through
  verbatim.
- Target size: fit within 1920×1080 (long×short edge), preserve aspect, never upscale, even dims.
- Target bitrate: ≈4 bits/pixel clamped to 2–8 Mbps, and never above the source's declared bitrate.
- Off-heap by construction (frames live in native codec buffers/surface), so it does not reintroduce
  the large-media OOM the sealed store avoids. A 20s no-progress stall guard converts a wedged codec
  into a fallback rather than a hang.
- 60 MB attachment cap is applied **after** transcode (a shrunk clip is checked at its final size).

Stories/trim/mute/filter video exports on Apple all go through `AVAssetExportSession` and call
`stripIdentifyingMetadata()` too, so derived clips carry no location either.

## Size caps

- Android picked video: 60 MB, applied after transcode/remux (`readVideoBytes`).
- Cross-device transfer: blobs > 256 MB move as 8 MB chunks (`HVCHUNK1` manifest); see the chunked-media
  notes.

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
