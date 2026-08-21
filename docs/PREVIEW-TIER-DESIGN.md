# The preview tier: a 512px AVIF that arrives first and upgrades itself

> **Status — design, not built.** The plan for a fourth media tier small enough to cross a satellite
> bearer, so someone off-grid can send and receive real pictures, people can react to them before the
> full image exists, and everything reconciles on its own when service returns. Sibling of
> [`SATELLITE-DESIGN.md`](SATELLITE-DESIGN.md); it assumes low-data mode (shipped in 1.6.0) and the
> policy table in its §5.
>
> **Locked framing (do not relitigate):**
> - **Preview is a TIER, not a thumbnail setting.** It sits below `thumb:` in the existing marker
>   family (`thumb:` / `poster:` / `original:`), and it is the only media tier allowed to cross an
>   ultra-constrained link.
> - **Content confidentiality is untouchable.** A preview is media. It is sealed exactly as any other
>   blob is, under the same circle epoch key, with the same hybrid post-quantum protection. A smaller
>   picture is not a less-protected picture.
> - **Never a downgrade of what exists.** The preview is additive. It never replaces the optimized or
>   original copy, and a client that has the full bytes never shows the preview instead.
> - **Parity applies.** Apple + Android + desktop in the same wave.

---

## 0. TL;DR

A 512px AVIF preview costs **about 6 KB** — under two Haven messages. That is small enough to send
over satellite, which changes what off-grid means: not "text only" but "you can send a picture, and
it becomes the real picture later."

Everything needed to make it upgrade itself already exists. Media refs ride inside the event and are
tiny; blobs are content-addressed and fetched separately; a missing blob is already a graceful,
honest placeholder state (`FeedView.swift:1907` drives a "Waiting for sender…" placeholder with
chunk progress). The preview tier is the missing piece, not the plumbing.

---

## 1. Why AVIF, with numbers

Measured on 5 real 10–12 MB device photographs (`PanoOwlCorpus/device/crash-232mp-16frame`),
downscaled to 512px longest edge, encoded with ImageIO, and scored with PSNR against the
uncompressed downscale. **A compact Haven message is 3,632 B**, for scale.

| format | ~28 dB (soft, readable) | ~30 dB (genuinely fine) | ~32 dB (good) |
|---|---|---|---|
| JPEG | — (floor is 12,225 B @ 29.7 dB) | 13,889 B | 17,756 B |
| HEIC | 3,628 B | 7,031 B | 10,097 B |
| **AVIF** | **4,195 B** | **6,205 B** | **9,824 B** |

**JPEG cannot reach the target at all.** Its floor at 512px is ~12 KB even at quality 0.1, and it is
only 29.7 dB there. AVIF hits the same quality at half the bytes and keeps going down. Against the
existing `thumb:` contract of ≤32 KB, a 512px AVIF preview is a **5x** reduction *at a larger
display size*.

Two honest caveats. These are five frames of one outdoor scene; other content will vary, and the
spec below is therefore a **byte budget**, not a quality number. And PSNR systematically under-rates
AVIF and HEIC, which are perceptually tuned — the real advantage over JPEG is larger than the table
shows, not smaller.

### 1.1 Why not HEIC

HEIC is marginally smaller at the very bottom of the range and Apple encodes it in hardware. It
loses on the only axis that matters here: **desktop**. HEVC on Windows and Linux is a licensing and
packaging problem, where AV1 is royalty-free and already decodes in every webview Haven ships in.
A format only two of four platforms can handle is not a format.

---

## 2. Platform support — verified, not assumed

Every row below was checked rather than inferred. The distinction matters because **every client
must both READ and WRITE previews** — any device can be the sender.

| platform | decode | encode |
|---|---|---|
| iOS 17+ | ✅ native (iOS 16+) | ✅ **native ImageIO** — verified by running `CGImageDestinationCopyTypeIdentifiers()` on an iOS 26.5 simulator: `public.avif` is present, and a real encode returned bytes |
| macOS | ✅ native | ✅ native ImageIO (`public.avif` writable, confirmed on host) |
| Desktop — Windows | ✅ WebView2/Chromium, Edge 121+ (Jan 2024), evergreen runtime | ✅ **Rust `ravif`** — verified: 512×384 in **15–28 ms** |
| Desktop — Linux | ✅ WebKitGTK (WebKit AVIF since 2021; distro build must carry libavif) | ✅ same `ravif` path |
| Desktop — macOS | ✅ WKWebView / Safari 16+ | ✅ same |
| **Android 31+** | ✅ native | ⚠️ no public encoder API — needs a bundled library |
| **Android 29–30** | ❌ native | ❌ native |

Desktop encodes images in the webview today (`ui/app.js:2140`, `canvas.toDataURL("image/jpeg", 0.7)`),
and Chromium's canvas cannot write AVIF. So desktop's preview encode moves into Rust, where `ravif`
(rav1e, royalty-free, pure Rust) does it in tens of milliseconds. That is a better place for it
anyway: it makes desktop behave like the mobile clients instead of depending on webview capabilities.

### 2.1 The one real decision: Android's floor

`minSdk` is 29. AVIF is native from 31. Two options, and this is a maker call:

1. **Bundle a decoder+encoder** — `avif-coder` (libdav1d-based, API 24+) or libavif's own JNI
   bindings. Keeps every current device. Costs roughly 1–2 MB per ABI in the APK.
2. **Raise `minSdk` to 31.** Android 12 shipped October 2021; by now the excluded population is very
   small. Costs nothing technically, and drops whoever is left on Android 10/11.

Nothing else in this document depends on which is chosen.

### 2.2 Quality scales are not portable

ImageIO takes 0–1; `ravif` takes 0–100; they do not line up (ImageIO q0.3 ≈ 6.2 KB where ravif q40 ≈
9.3 KB on the same source). The spec is therefore **"512px longest edge, ≤8 KB, encoder tuned per
platform to hit it"** — never a raw quality number, which would silently mean three different things.

---

## 3. The tier

A new marker joining the existing family in `MediaVariants`:

```
preview:<content>:<preview>     alongside  thumb: / poster: / original:
```

Same shape, same parsing, same "old clients ignore an unknown marker" property that
`thumb:`/`poster:` already rely on. **Format is negotiated exactly like the compact wire container**:
a client advertises the preview formats it can decode in its account-signed profile card, and a
circle uses a format every member can read. Silence means no preview — never a format someone cannot
open. Identical all-present-positive gate to `circle_fully_compact_wire_capable`.

Policy (`haven_p2p::transport::allowance`) gains `Traffic::Preview`:

| link | Preview | Thumbnail | Media |
|---|---|---|---|
| Normal | Allow | Allow | Allow |
| Low | Allow | Allow | AskFirst |
| **Ultra** | **Allow** | Deny | AskFirst |

Preview is the *only* media that crosses at Ultra. At ~6 KB it is under two messages; the ≤32 KB
`thumb:` is nine, and a screenful of them is a third of a megabyte.

---

## 4. What this makes possible off-grid

### 4.1 Sending

On an ultra-constrained link the composer uploads **the preview only** and publishes the event. The
optimized and original blobs stay queued locally. The post is real, addressed, signed and sealed the
moment it goes; what is missing is bytes, not authenticity.

### 4.2 Receiving, and interacting before the picture exists

Recipients get the event, the refs, and a 6 KB picture. They can read it, react to it, comment on
it, and reply — **all of that is text**, all of it already allowed at Ultra, and none of it depends
on the full media existing. The full copy shows the placeholder that already exists today
(`FeedView.swift:1907`, "Waiting for sender…") rather than a broken tile.

This is the part worth being clear about: the interaction is not a degraded stand-in. A reaction to
a post is a reaction to *that post*, whichever bytes of it you have seen.

### 4.3 Reconciliation on return

When the link constraint drops back to `Normal`, the sender's queued blobs upload and the
recipients' deferred fetches run. Both halves already exist —
`prefetch_announced_media` on the receive side, the composer's upload queue on the send side. What
is missing is a **nudge on constraint improvement**: today the change is noticed on the next natural
feed refresh rather than at the moment service returns. That nudge is small and is stage P1 below.

### 4.4 "The thing you reacted to is here now"

If someone reacted to or commented on a post while only its preview existed, they get a
notification when the full media lands. Not for every completed upload — only for items that person
actually engaged with, which keeps it rare and meaningful.

This needs one new piece of local state: a per-item set of "I interacted with this before it was
complete", checked when a blob finishes downloading. It is device-local, needs no wire change, and
never leaves the device — nobody else learns what you looked at.

---

## 5. Super data saver uses it too

The preview is not satellite-only. With super data saver on, the feed shows the 512px preview in
place of the full image until an explicit tap, **aspect-fitted to exactly the footprint the full
image would occupy** so that loading the real copy causes no layout shift. That footprint is already
known before the bytes arrive — the ref→pixel-size map exists precisely so a card does not resize
when a poster loads (`Media.swift:1534`).

That turns today's data saver from "posters only, no autoplay" into "every picture, small," which is
a straightforwardly better experience on a metered link and costs 6 KB a post.

---

## 6. Staged plan

| Stage | What | Proof obligation |
|---|---|---|
| **P0** ✅ | `Traffic::Preview` in the policy table + FFI mirror | The cross-product sweep still passes; Preview is the only media Allowed at Ultra |
| **P1** ✅ | Prefetch nudge when `LinkConstraint` improves | Deferred fetches demonstrably run at the moment the constraint clears, not on the next refresh |
| **P2** ✅ | Encoders: ImageIO (Apple), `ravif` (desktop), bundled lib (Android) | All three produce ≤8 KB at 512px from the same source, and each decodes the other two's output |
| **P3** ✅ | `preview:` marker + format capability negotiation | An un-advertised member never receives a format it cannot decode |
| **P4** ✅ | Composer: preview-first upload at Ultra, rest queued | On an ultra link exactly one blob is uploaded; the remainder upload on return |
| **P5** ✅ | Interact-before-complete + completion notification | Reacting to a preview-only post produces a notification when the full media lands, and only for engaged items |
| **P6** ✅ | Super data saver renders preview at full footprint | No layout shift when the full copy replaces it |

**All stages landed in 1.6.0-rc.4.** Apple, Android and desktop all mint previews at attach time;
Apple and Android hold back everything but the preview on an ultra-constrained link and complete the
rest when service returns.

One caveat worth keeping visible: desktop does not gate its uploads by link constraint, because its
constraint is chosen rather than detected (§2 — there is no path monitor there). A desktop on a
satellite terminal will still attempt full media. Fixing that means either a real desktop path
monitor or honouring the manual low-data switch in the upload path.

---

## 7. What this does not do

- **It does not make video work off-grid.** A poster still is a picture and rides the same tier; the
  video does not, and no encoding closes that gap on this bearer.
- **It does not make the preview authoritative.** It is a smaller rendering of the same content,
  sealed the same way. It is never the copy that gets saved to Photos, exported, or re-shared.
- **It does not put media on LoRa.** [`LORA-DESIGN.md`](LORA-DESIGN.md) §6 rejects media at ~200
  bytes per packet, and 6 KB does not change that conclusion — this tier is for satellite, which
  carries IP.
