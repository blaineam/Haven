# In-app camera, Apple Music on posts, and audio crossfade

Design **and security audit** for three linked features. Per the project's standing
rule, every step here is checked so the maker never holds keys and nothing leaks off
the device unsealed.

## 1. In-app camera (photos + video)

A simple, intuitive capture sheet (AVFoundation `AVCaptureSession`): tap for photo,
hold/record for video, flip camera, flash. Captured media lands in the app sandbox,
is shown in the composer, then is **sealed E2E before it ever leaves the device**.

**Security audit**
- **Permissions:** `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` with
  honest, plain-language strings. Capture only after the user taps — never in the
  background.
- **On-device only:** captured files live in the app's sandbox `tmp`/caches, are
  added to a post as a content-addressed blob, and are **encrypted with the hybrid-PQ
  content key (AES-256-GCM) before any transmission**. No frame, thumbnail, or file
  ever touches a server in the clear. (Same `haven-p2p::social` seal path as text.)
- **Metadata hygiene (design intent — *partially* met today):** strip GPS/EXIF location and
  identifying maker tags by default on capture/import. **Holds for photos on iOS + Android;
  video has real gaps** — see the per-platform table under "Metadata hygiene" below before
  relying on this. Stated as the goal, not as a shipped guarantee.
- **No analytics, no third parties:** the camera pipeline calls no SDK, logs nothing,
  and uploads nothing. Temp files are deleted after the post is sealed.
- **Maker holds nothing:** there is no server in this path, so there is nothing for
  the maker to be compelled to produce.

## 2. Apple Music on a post

The author can attach a song that plays alongside a photo/video. Near the post, a
small pill shows **artist + song title** with an **audio-playing animation** while it
plays. Each viewer hears it through **their own** Apple Music subscription.

**Security & licensing audit**
- **References only — never audio.** We attach a MusicKit catalog reference
  (`{catalogId, title, artist, artworkURL, durationMs}`), never the audio data. This
  is the *only* legal model (DRM) and it means **no redistribution, no piracy, no
  rights exposure**. A viewer without a subscription gets a 30s preview / tap-to-open.
- **The reference rides the E2E payload.** The track reference is a field on the
  social `Event`, sealed exactly like the rest of the post — a relay/storage node sees
  only ciphertext. No new plaintext channel, no new metadata leak.
- **No PII, no operator role.** MusicKit authorization is per-device and Apple-managed;
  Haven never sees the user's Apple ID, library, or listening data, and adds **no
  central component** — the "maker holds no keys" property is fully preserved.
- **Least privilege:** request MusicKit authorization only when the user chooses to
  attach/play a song; degrade gracefully (show the pill, disable playback) if denied.
- **Entitlement note:** the MusicKit capability + `com.apple.developer.musickit`
  entitlement are **granted on the App ID** — live Apple Music attach + playback is shipped.

### 2b. Song credits — naming the music already in a video (Shazam)

A video someone filmed usually has a song *in* it. Haven names it: when a video is posted with
audible sound, no chosen song and no mute, the app builds a short Shazam signature from the first
~11.5 s of the clip's audio and asks Apple's Shazam catalog what is playing. A match becomes a
**credit** chip — `title · artist` with the Shazam mark — attached by a silent edit seconds after
the post, and the video keeps its own audio (see `TrackRefFfi.creditPrefix`: a credit is encoded
in `catalogId`, so Android and desktop render it with no protocol change). Imported Instagram reels
get the same treatment (`docs/instagram-import.md`).

**Privacy & controls**
- **What leaves the device:** a Shazam audio *signature* (a fingerprint of ~11 s of audio) to
  Apple's Shazam service, under Apple's ShazamKit terms. Never the video, never the post, never a
  caption. The catalog answer is a track reference, like any other song on a post.
- **Default on, one switch off:** *Settings → Song credits → Name the song in my videos*. The
  Instagram import sheet has its own switch for reels.
- **Bounded:** one identification per post, paced (2–30 s between catalog requests), and a refused
  attempt (`matchAttemptFailed` / `internalError` / no answer) is retried from a persisted queue
  with exponential back-off — never a loop. "Not in catalog" is an answer and is not retried.
- **Maker holds nothing:** no Haven server is involved; the request goes device → Apple.
- **Older videos, on playback:** an own, untagged video (imported reels included) is scanned the
  first time it plays — after playback starts, off the main actor, through the same queue. A
  per-post ledger (`Application Support/haven-shazam-ledger.json`, written by a serialized actor)
  records `matched / notInCatalog / noAudio / tooShort / badSignature / transient / exhausted`, so a
  clip is fingerprinted at most once for a definitive answer and re-asked only after a back-off
  (30 min × 2ⁿ, four tries) for a transient one. *Settings → Song credits → Rescan imported videos*
  runs the backlog manually, one at a time, honouring the ledger. Only the author can attach a
  credit, so other people's posts are never scanned.

## 3. Audio crossfade (music ↔ video)

When a post has attached music, its **video plays muted** by default while the music
plays. If the viewer **unmutes the video**, the background music **fades out** as the
video audio **fades in** — a clean crossfade — and fades back the other way on re-mute
or scroll-away.

- One `AudioCoordinator` owns an `ApplicationMusicPlayer` (music) and the visible
  `AVPlayer` (video), ramping volumes over ~300–500ms. Only one post's audio is active
  at a time (scrolling hands off with a fade).
- **Security surface: none.** This is local playback only — no network, no data, no
  keys. The only guarantee we keep is **honoring the user's control** (muted by
  default; unmute is explicit; nothing autoplays audibly without a clear affordance).

## Data-model change (security-reviewed)

`haven-p2p::social::EventKind::Post` gains optional `media: [MediaRef]` (already present
as content refs) and `music: Option<TrackRef>`. `TrackRef` is non-secret reference
data, serialized inside the **already-sealed** event — no schema change weakens the
encryption boundary; it's just more sealed bytes.

## Status

**Implemented:**
- ✅ `TrackRef` + `music`/`media` on posts in `haven-p2p` + FFI (sealed-event payload).
- ✅ Feed media rendering + **now-playing pill with audio animation**.
- ✅ Composer attach: Photos/Videos picker (`PHPicker`), in-app **camera**
  (`AVCaptureSession`, tap=photo / hold=video / flip), **song picker**.
- ✅ `AudioCoordinator` + video-volume crossfade; muted-video-while-music model.
- ✅ Privacy usage strings (camera/mic/photos/Apple Music).
- ✅ **Real Apple Music**: the **MusicKit capability + `com.apple.developer.musickit`
  entitlement** are **granted on the App ID**; live catalog + library picker, attach, and
  playback are shipped.
- ✅ **Cross-device media send**: media is content-addressed (BLAKE3), sealed E2E, and moves
  peer-to-peer over iroh / nearby with the relay or the user's own S3 bucket as the offline
  backstop. A **media-request throttle** stops missing media from being re-requested forever,
  so requests settle. Two distinct chunking mechanisms are in play:
  - **In-band chunk frames** (type 5, direct P2P / nearby): **32 KB** on iOS
    (`apple/HavenApp/FeedView.swift:103`) and Android (`core/HavenNet.kt:2171`) — reduced from
    512 KB after a MultipeerConnectivity buffer overflow — but still **512 KB on desktop**
    (`desktop/src-tauri/src/engine.rs:141`). This doc previously claimed a flat "512 KB"; that
    is only true of desktop. The mismatch is interoperable (the receiver doesn't care) but the
    inconsistency is unintentional.
  - **Manifest chunking for large blobs** (relay/S3): blobs over **8 MB** split into 8 MB parts
    under an `HVCHUNK1` manifest (`engine.rs:144`, `:2994`), keeping each object under the
    256 MB `MAX_BLOB` cap. Byte-identical across iOS/Android/desktop
    (`SharedStore.swift:167`, `HavenNet.kt:2195`).

**Metadata hygiene — the honest, per-platform truth (2026-07-15):**

This was previously listed as a flat "⏭️ not done". That's wrong in both directions: photos are
handled, and one *video* path is a real leak.

| Path | EXIF/GPS stripped? | Evidence |
|---|---|---|
| iOS photo | ✅ yes — re-encode via `jpegData` drops EXIF | `apple/HavenApp/Media.swift:310-325` |
| Android photo | ✅ yes — re-encode from decoded bitmap | `core/LocalMedia.kt:344-393` |
| iOS video, auto-optimize **OFF** | ✅ yes — `export.metadata = []` | `Media.swift:364` |
| iOS video, auto-optimize **ON** (the **default**) | ⚠️ **likely NO** | `optimizeVideo` (`Media.swift:552-588`) never sets `export.metadata`; `AVAssetExportSession` copies source metadata when it's unset. **Needs an on-device confirmation** (inspect an exported file's metadata) — flagged from the API contract, not an observed leak |
| Android video | ❌ **no** — raw bytes, no transcode | `core/LocalMedia.kt:330-337` |
| Desktop | n/a — no strip code exists at all | no EXIF handling anywhere in `desktop/` |

So the deterrent-sounding "strip GPS/EXIF by default" principle at the top of this doc holds for
**photos only**. Fixing the iOS default path is a one-liner (`export.metadata = []` in
`optimizeVideo`); Android video needs a transcode or a metadata rewrite.

**Follow-ups (security-relevant):**
- ⏭️ **Close the video EXIF/GPS gaps** above (iOS default path; Android video).
- ⏭️ **Per-circle** `SensitiveContentAnalysis` toggles. *(The analyzer itself is **shipped** on
  Apple — `apple/HavenApp/SensitiveContent.swift` — and flags federate to peers as a
  `SensitiveFlag` event. But it follows the **system** Sensitive Content setting, there is no
  per-circle toggle, and **Android/desktop ignore the federated flag entirely** — they render
  flagged media unblurred.)*
