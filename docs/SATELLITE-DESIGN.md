# Haven over carrier satellite (T-Satellite / direct-to-cell)

> **Status — design plan, not built.** This is the full plan for making Haven usable over
> carrier direct-to-cell satellite data (T-Mobile's T-Satellite with Starlink, and the
> equivalent bearers arriving on other carriers), so someone with no terrestrial signal can
> still send and receive Haven text. It is **design only**; no product code accompanies it.
> It is a sibling of [`docs/LORA-DESIGN.md`](LORA-DESIGN.md) and shares that document's
> compact-wire-profile stages verbatim — the two transports have the same disease and the
> same cure, three orders of magnitude apart.
>
> **Locked framing (do not relitigate):**
> - **This is a transport profile, not a product pivot.** Haven stays what it is. Satellite is
>   a degraded mode of the existing relay rung (`core/haven-p2p/src/transport.rs`), not a new
>   rung and not a new product.
> - **Content confidentiality is untouchable.** Everything that crosses the satellite bearer is
>   already sealed under a circle epoch key ([`GROUP-KEYING.md`](GROUP-KEYING.md)). The carrier
>   carries opaque bytes exactly as a relay does. Nothing here adds a plaintext path.
> - **Text only, deliberately.** Media, calls, stories, history backfill and self-sync are
>   hard-rejected on this path (§5), not rate-limited.
> - **Parity applies.** Per the standing rule, Apple + Android land in the same wave.
> - **The carrier gate is not an engineering problem and must not be engineered around.** §4 is
>   a maker decision about what Haven is willing to become in exchange for admission. If the
>   answer is no, stages S0–S3 still ship and still pay for themselves.

---

## 0. TL;DR — two gates and a byte budget

Satellite is a far better fit for Haven than LoRa: the bearer carries **real IP**, so the relay
lane, the mailbox, the sealed-envelope format and the delivery buffer all work unmodified. There
is no fragmentation layer to write and no addressing scheme to invent.

Three things stand between Haven and working over T-Satellite, in ascending order of difficulty:

1. **The platform gate — solved, and cheaper than expected.** Apple and Google both shipped the
   satellite-awareness APIs already. Apple's landed in **iOS 26.0**, not the rumoured iOS 27
   framework (§2.3). Both are opt-in: traffic does not touch the satellite bearer unless the app
   explicitly asks. Cost: days.
2. **The byte budget — real work, already scoped.** A one-word Haven DM is **~12 KB on the wire**
   ([`LORA-DESIGN.md` §0.1](LORA-DESIGN.md)). That is survivable on satellite where it was fatal
   on LoRa, but it is still roughly 60× a comparable SMS and it is mostly waste. Stages S0–S2
   below are the LoRa spike's L0–L2, unchanged. Cost: weeks.
3. **The carrier gate — the actual blocker, and not technical.** T-Mobile admits apps to satellite
   data by private allowlist, negotiated over email. Haven's egress is by design unbounded — iroh
   dialling arbitrary peer IPs, user-run relays on arbitrary hosts, cloudflared quick tunnels. That
   is exactly what an allowlist cannot express (§4). Cost: a product decision.

### 0.1 The shape of the answer

Build satellite mode for its own sake. It is the correct behaviour on any ultra-constrained path,
it is measurable, and it is what makes a carrier submission a data-backed pitch rather than a cold
ask. Admission to T-Satellite is then a separate negotiation that Haven either wins or does not,
with the engineering already banked either way.

### 0.2 What has landed (as of 1.6.0)

The mode exists and is on by default in its automatic setting. Concretely:

* **The compact container (S0), read and write.** Measured **12,953 B → 3,632 B**, a 3.57x
  reduction, on a one-word DM — and circles now actually emit it. The write is gated on
  `circle_fully_compact_wire_capable`: every member must have affirmatively advertised `cw` in their
  account-signed profile card before a circle flips, because a client that cannot parse the
  container loses the message outright and there is no renegotiation once bytes are in the mailbox.
  A single unadvertised member keeps the whole circle on JSON. Silence means legacy, never
  downgraded.

  The marker is learned from **both** profile entry points — `verify_profile_card`, which is what
  iOS and Android call, and `profile_seed_drop_version`, which is what desktop calls. Learning it in
  only one was a real bug caught in review: the gate would have opened on desktop and stayed shut
  forever on the two platforms that matter, failing silently as a permanent 3.5x overspend rather
  than as an error. `both_profile_entry_points_open_the_gate` is the regression test.
* **The constraint signal (S3).** `haven_p2p::transport::LinkConstraint` — normal / low / ultra —
  fed by `NWPath.isUltraConstrained` + `linkQuality` on Apple and
  `NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED` + `TRANSPORT_SATELLITE` on Android, both behind
  availability gates against the iOS 17 / `minSdk` 29 floors.
* **The policy table (S4).** `haven_p2p::transport::allowance` is §5 as code, and it is the *single*
  table all three clients consult. Apple and Android reach it over UniFFI; the Tauri desktop links
  `haven-p2p` directly and calls it with no FFI hop at all. A test sweeps every link-by-traffic cell
  and requires the FFI mirror to agree with the source, because a hand-written mirror is the one
  thing that can silently rot.
* **User control.** A three-way preference — automatic (follow the network), always on, off — on all
  three platforms. "Off" is honoured everywhere except a genuinely ultra-constrained bearer, which
  is not a preference: the OS will refuse the traffic regardless, so the mode stays on and the UI
  explains rather than letting sends fail mysteriously.

* **Android's satellite declaration.** `android.telephony.PROPERTY_SATELLITE_DATA_OPTIMIZED` is in
  the manifest, which is what gets Haven access when satellite is the only network and what lists it
  under the system's satellite-app settings.

Still open, and one of them is load-bearing:

* **Apple's satellite eligibility — RESOLVED, and the earlier reading here was wrong.** This
  document previously said the Apple opt-in did not obviously map onto Haven's data path, because
  `nw_parameters_set_allow_ultra_constrained` is per-`NWConnection` and Haven's mailbox traffic is
  iroh QUIC and HTTP from Rust over ordinary sockets. That is not the mechanism. Eligibility comes
  from two **entitlements**, which apply process-wide:

  ```xml
  <key>com.apple.developer.networking.carrier-constrained.app-optimized</key><true/>
  <key>com.apple.developer.networking.carrier-constrained.appcategory</key>
  <array><string>messaging-8001</string></array>
  ```

  iOS/iPadOS 26.0+, 22 valid categories (`messaging-8001`, `maps-8002`, `voip-8006`,
  `emergency-8007`, `light-social-8008`, …). Per Xcode's own portal capability record
  (`CARRIER_CONSTRAINED_NETWORK_CAT_OPT`) it is **self-serve** —
  `distributionApprovalRequired: false` — but the capability must be enabled on each App ID before
  the entitlement will sign, and a locally cached provisioning profile minted before that change
  will fail with "doesn't include the Carrier-Constrained Network Category and Optimized
  capability" until it is regenerated.

  The evidence is Signal, which is on T-Satellite: their entire satellite implementation is two
  commits — a one-line Android manifest declaration and a 36-line, **code-free** iOS entitlements
  change across app, NSE and share extension. No low-data mode, no governor, no link-quality
  handling. If a per-connection opt-in were required, that commit could not have worked.

  Haven now carries the same keys on the iPhone app, the NSE and the share extension. Not on macOS
  (Apple lists the entitlement for iOS/iPadOS only) and not on the broadcast extension (screen share
  for calls, which are refused on a satellite link anyway).

* **The governor (§6.3)** — burst-and-idle scheduling, per-pass byte ceilings, quality-aware drain
  depth.
* **The push question in §7** — whether APNs reaches a third-party app over satellite at all.

---

## 1. Goal and non-goals

### 1.1 The success criterion

> Two people in a Haven circle, one of them with no terrestrial signal and an iPhone or Android
> handset attached to a carrier satellite bearer, can exchange text with each other within one
> satellite pass, and the off-grid participant can tell from the UI exactly what is and is not
> going to work before they try it.

Note what this does *not* say. It does not say Haven is on T-Mobile's supported-apps list. That is
§9, it is out of Haven's unilateral control, and the feature is worth building without it — an
ultra-constrained path is also what you get on a saturated festival cell, a rural EDGE fallback,
and a metered hotspot in a dead zone.

### 1.2 Non-goals

- **Not a satellite SDK integration.** There is no satellite framework to link (§2.3). This is
  a policy layer over the existing transport.
- **Not media.** Not photos, not video, not voice notes, not stories, not link previews, not
  avatars. `MAX_BLOB` on the relay is 256 MB (`core/haven-net/src/httprelay.rs:92`) and the media
  chunk size is 8 MiB (`apple/HavenApp/SharedStore.swift:543`). Neither number belongs anywhere
  near this bearer.
- **Not calls.** WebRTC on a bearer with pass-scale availability is not a degraded call, it is a
  failed call that consumes the whole budget failing.
- **Not enrolment or pairing.** A full identity is ~3.2 KB of post-quantum key material
  ([`LORA-DESIGN.md` §7.1](LORA-DESIGN.md)). Meeting someone new stays QR/nearby, same as LoRa.
- **Not epoch recovery.** If a circle rotated keys while you were off-grid, that conversation
  stays dark until you reach real internet. Same conclusion as [`LORA-DESIGN.md` §7.2](LORA-DESIGN.md).
- **Not a bypass.** If the carrier does not admit Haven, Haven does not disguise its traffic to
  get admitted anyway. That is both a policy line and an operational one.

---

## 2. What the platforms give us (verified against the shipped SDKs)

Everything in this section was read out of the installed SDKs, not from documentation or press.

### 2.1 Apple — the ultra-constrained path family

Apple did not ship a satellite framework. It extended `Network.framework` with a third tier below
`isExpensive` and `isConstrained`, and **it shipped in iOS 26.0** — it is available today:

| API | Availability | Header |
|---|---|---|
| `nw_path_is_ultra_constrained` / `NWPath.isUltraConstrained` | macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0 | `Network/path.h:199` |
| `nw_parameters_set_allow_ultra_constrained` | same | `Network/parameters.h:581` |
| `nw_parameters_get_allow_ultra_constrained` | same | `Network/parameters.h:597` |
| `NWPath.LinkQuality` — `.unknown` / `.minimal` / `.moderate` / `.good`, plus `NWPath.linkQuality` | same | `Network.swiftinterface:821` |
| `URLRequest.allowsUltraConstrainedNetworkAccess` | macOS 26.1, iOS 26.1 | `Foundation/NSURLRequest.h:248` |
| `URLSessionConfiguration.allowsUltraConstrainedNetworkAccess` | macOS 26.1, iOS 26.1 | `Foundation/NSURLSession.h:1367` |
| `NSURLErrorNetworkUnavailableReasonUltraConstrained` | macOS 26.1, iOS 26.1 | `Foundation/NSURLError.h:80` |

Two consequences matter more than the rest.

**It is opt-in, and the default is off.** From `parameters.h:583`, verbatim: *"Explicitly allow
connectivity over ultra-constrained interfaces. Without this being set, connections are not
allowed to use these interfaces."* This is the mechanism behind the press narrative that Apple is
discouraging satellite reliance. It is not discouragement so much as a refusal to let an app
consume a scarce bearer by accident, and it is the right default. Haven must set the flag
deliberately, per connection, and only for connections that satellite mode has approved.

**`LinkQuality` is a better signal than the boolean.** `.minimal` versus `.moderate` lets the
governor (§6.3) distinguish "a pass is open, drain the queue" from "we have a sliver, send the one
queued message and stop". Nothing else exposes this.

**Deployment-target note.** `apple/Haven.xcodeproj/project.pbxproj` sets
`IPHONEOS_DEPLOYMENT_TARGET = 17.0` and `MACOSX_DEPLOYMENT_TARGET = 14.0`. All of the above needs
`if #available(iOS 26, macOS 26, *)` with a graceful pre-26 fallback that treats
`isConstrained` as the strongest available hint. No target bump is required and none should happen
for this.

### 2.2 Android — constrained networks and a manifest declaration

Android's equivalent is older and blunter, and adds one thing Apple has no analogue for: an
explicit self-identification tag the platform reads.

- **Detection:** `NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED` (API 36 /
  Android 16) is present by default and **removed** on constrained networks. Also check
  `NetworkCapabilities.TRANSPORT_SATELLITE`, because the capability may survive on an
  unconstrained satellite network that still deserves the degraded profile.
- **Access:** a constrained network must be requested explicitly —
  `NetworkRequest.Builder().addCapability(NET_CAPABILITY_INTERNET).removeCapability(NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED)`
  then `registerBestMatchingNetworkCallback`. Same opt-in shape as Apple.
- **Declaration:** the app self-identifies in `AndroidManifest.xml` with
  `<meta-data android:name="android.telephony.PROPERTY_SATELLITE_DATA_OPTIMIZED" android:value="com.blaineam.haven" />`.
  This is what gets Haven access to a satellite network when it is the only network available, and
  what makes Haven discoverable in the system's satellite-app settings. Google is explicit that
  only the app may add this tag, never a library — so it belongs in `android/app/src/main/`, never
  in a Rust-side manifest merge.
- **Push:** FCM accepts `android.bandwidth_constrained_ok: true` per message to permit delivery
  over a constrained network. Haven does not use FCM today (see §7).

`android/app/build.gradle.kts` already sets `compileSdk = 36`, so the constants compile. `minSdk`
is 29, so every call site needs an API-level guard.

### 2.3 What is *not* there — the iOS 27 satellite API

The reporting through late 2025 and 2026 described a forthcoming "satellite API for third-party
apps" in iOS 27, alongside Maps-over-satellite and photos-in-Messages-over-satellite. **It is not
in the iOS 27 beta SDK.** Diffed `iPhoneOS26.5.sdk` against `iPhoneOS27.0.sdk`:

- No framework, class, or symbol containing `satellite` or `nonTerrestrial` anywhere in the
  networking or telephony surface. The only `satellite` hits SDK-wide are unrelated — HomeKit
  satellite speakers, `MKMapType.satellite`, GPS EXIF keys, `INRadioType`, Matter clusters.
- `Network.framework/Headers/path.h` differs from 26.5 by exactly two lines: a copyright year and
  `typedef enum` → `typedef enum: uint8_t`. Cosmetic.
- `CoreTelephony/CTTelephonyNetworkInfo.h` differs by one blank line. The only new CoreTelephony
  header is `CTQuickSwitch.h`, which is unrelated to satellite.

The conclusion is the useful part: **there is nothing to wait for.** The satellite API Haven needs
already shipped as the ultra-constrained family in iOS 26, and building against it now costs
nothing if a richer iOS 27 API appears later. Anyone revisiting this doc should re-run the diff
against the shipping iOS 27 SDK before assuming it still holds.

---

## 3. What exists in Haven to build on

### 3.1 The relay lane is already store-and-forward

Satellite gives passes, not a link, and Haven's relay lane is already the right shape for that: a
peer PUTs a sealed blob, the recipient LISTs and GETs when it can. Nothing about the mailbox model
assumes both parties are online simultaneously. This is the single biggest reason satellite is
tractable where LoRa was not.

### 3.2 The conditional mailbox list already exists

`core/haven-net/src/httprelay.rs:434` already implements a digest-conditional LIST — a client that
echoes back the `x-haven-list-digest` it last received gets a bodiless `204` instead of the same
key list again. The comment in the source calls it a "radio saver". It was written for LoRa and it
is worth just as much here: an unchanged mailbox costs a response header instead of a key list.

### 3.3 The precedent for a degraded profile shipped already

`SealedEnvelope` carries an `HVE1` tag and a postcard body precisely because JSON turned a 48 MB
video into a 167 MB blob (`core/haven-p2p/src/social.rs:154-168`). The pattern for "this container
gets a compact binary encoding" is established, reviewed and in production. S0 applies it to the
container that never got it.

### 3.4 The transport seam is trait-only

`core/haven-p2p/src/transport.rs` documents a three-rung ladder — Bluetooth, LocalWifi, Relay — and
the `Path` enum is trait-only with concrete impls still to land. Satellite does **not** add a
fourth rung. It is a *constraint annotation* on the existing Relay rung, because the bytes go to
the same relay over the same HTTP interface. Modelling it as a rung would wrongly imply the
selector could prefer it over LocalWifi.

---

## 4. The egress problem (read this before §5)

This is the part that decides whether Haven can ever be a T-Satellite app, and it is not solvable
by writing better code.

T-Mobile admits apps by allowlist, negotiated privately via `SatelliteApps@T-Mobile.com`. The
current roster — WhatsApp, X, AllTrails, AccuWeather, CalTopo, Google Maps, onX, Gaia, plus
Apple's first-party apps — shares one property: **a small, fixed, enumerable set of backend
endpoints**. WhatsApp is allowlistable because WhatsApp talks to Meta.

Haven, by design, talks to:

- arbitrary peer IPs, dialled over iroh QUIC after resolution through signed DHT records;
- user-run relays on arbitrary hostnames and ports, including plain HTTP on `:8674`
  (`core/haven-net/src/discovery.rs:319`);
- cloudflared quick tunnels with ephemeral hostnames (`core/haven-net/src/cfquicktunnel.rs`);
- NAS fabric relays that did not exist when the allowlist was written
  ([`NAS-FABRIC-RELAY.md`](NAS-FABRIC-RELAY.md)).

An allowlist cannot enumerate destinations that will not exist until a user stands one up. That is
not an oversight in Haven's design; it is the design.

### 4.1 The open question to ask T-Mobile first

**Is admission enforced by app identity alone, or by destination?** Everything downstream depends
on the answer, and it is not publicly documented:

- **If by app identity** (the manifest tag / a per-app policy in the packet core), Haven's existing
  egress is fine as-is, and this whole section evaporates. Satellite mode is then purely the byte
  budget of §6.
- **If by destination**, satellite mode must speak *only* to a fixed, declarable Haven-operated
  relay set, with direct P2P and user relays disabled while on the bearer.

Ask before building. One email saves the entire §4.2 argument.

### 4.2 If it is destination-based: what admission would cost

A "satellite egress profile" means: while on an ultra-constrained path, Haven uses only the
community relay set at known hostnames, and refuses direct peer dials and user-supplied relays.

The honest accounting:

- **What it does not cost:** confidentiality. Blobs are sealed before they reach any relay; a
  fixed relay set sees the same opaque bytes an arbitrary one does. Everything in
  [`THREAT-MODEL.md`](THREAT-MODEL.md) holds unchanged.
- **What it does cost:** the metadata story, and only on this bearer. A fixed relay set is a fixed
  observation point for who-talks-to-whom timing, where today the set is diffuse. It also means
  that in the one situation Haven markets itself hardest for — off-grid, infrastructure-hostile —
  Haven depends on infrastructure the maker runs.
- **The mitigating fact:** the alternative on this bearer is *no Haven at all*, and the user is
  already fully legible to the carrier and to Starlink regardless of which relay is on the far
  end. Satellite is not a private bearer and should never be described as one.

This is a maker call, not an engineering default. If the answer is no, S0–S3 still ship.

---

## 5. Policy: what may cross the satellite bearer

Modelled directly on [`LORA-DESIGN.md` §6](LORA-DESIGN.md). These are hard rejections at the policy
layer, not rate limits, because a rate-limited 8 MiB chunk is still an 8 MiB chunk eventually.

The table below is the **`Ultra`** tier — a satellite bearer. The implementation also has a softer
**`Low`** tier for a metered hotspot or a bandwidth-constrained cell, where a conversation still
feels like a conversation: text, reactions, typing and calls all continue, thumbnails still load,
and what stops is the speculative and the bulky (stories, link previews, history backfill,
self-sync). `haven_p2p::transport::allowance` is the authoritative version of both tiers; a test
asserts the policy can never be *more* permissive at `Ultra` than at `Low`.

| Traffic | On satellite | Why |
|---|---|---|
| Text messages (send + receive) | **Allowed** | The entire point. |
| Reactions, read receipts, typing indicators | **Rejected** | Typing indicators in particular are the worst byte-per-meaning ratio Haven has. |
| Media upload / download (photo, video, voice note) | **Rejected**, with explicit per-item override | 8 MiB chunks (`apple/HavenApp/SharedStore.swift:543`); `MAX_BLOB` is 256 MB. |
| Thumbnails and avatars | **Rejected** | Cache before departure; show initials. **Allowed on the softer `Low` tier** — they are small, and a feed with no pictures is a broken feed rather than a thrifty one. The aggregate only matters at satellite scale. |
| Link previews | **Rejected** | Already tap-to-load by design. |
| Stories | **Rejected** | Media by definition. |
| Calls (WebRTC) | **Rejected** | Pass-scale availability is not a call. |
| History backfill / lazy older-message fetch | **Rejected** | Unbounded by construction. |
| Self-sync between own devices | **Rejected** | The other device will reconcile on real internet. |
| Circle roster / epoch-key convergence | **Allowed, deferred** | Small, and required for correctness — but queued behind text. |
| Enrolment, seed-drop, pairing | **Rejected** | ~3.2 KB identities; see §1.2. |
| Presence / heartbeat | **Rejected** | Nothing is more wasteful than telling a satellite you are still alive. |

The per-item media override matters: a user who genuinely needs one photo out should be able to
send it, having been shown what it will cost and how long it will take. Silent refusal is worse
than an informed expensive choice. Everything else on the reject list has no override.

---

## 6. The byte budget

### 6.1 Where a message's bytes go today

Unchanged from [`LORA-DESIGN.md` §0.1](LORA-DESIGN.md), because it is the same envelope: an
`EpochEnvelope` (`core/haven-p2p/src/groupkey.rs:134`) carrying a one-word DM is **~3.6 KB binary**,
of which **3,373 bytes is the Ed25519 ‖ ML-DSA-65 signature** (`core/haven-p2p/src/identity.rs:81`)
and ~198 bytes is the actual sealed payload. `EpochEnvelope::to_bytes` then serialises through
`serde_json` (`groupkey.rs:160`), which renders every `Vec<u8>` as decimal ASCII at ~3.5 characters
per byte, producing **~12–13 KB on the wire**.

Against a bearer built for text-scale payloads, spending 12 KB to deliver 170 bytes of plaintext is
not a rounding error, and — the point worth repeating — **it is not a satellite problem**. Haven
pays this on cellular and Wi-Fi today. S0 is worth shipping on its own schedule.

### 6.2 The stages that fix it

S0–S2 are L0–L2 of the LoRa spike, adopted wholesale rather than restated. In summary:

- **S0 — postcard the `EpochEnvelope` container.** ~12 KB → ~3.6 KB. No cryptographic change, no
  policy change, benefits every transport. Ships independently of everything else in this document.
- **S1 — the signature decision.** After S0, ~93% of the residual is the ML-DSA-65 half of the
  signature. This is the same maker decision as [`LORA-DESIGN.md` §3.3](LORA-DESIGN.md) and is
  explicitly *not* an engineering default; it touches authenticity, never confidentiality. On
  satellite the case is weaker than on LoRa, because 3.6 KB is survivable here and the whole point
  of Haven's PQ posture is that it does not get traded away for convenience. **Default position:
  do not take S1 for satellite.** It is listed for completeness and because S0's arithmetic makes
  it visible.
- **S2 — container elision and trial decryption.** Drop fields the recipient can reconstruct.

Realistic target without S1: **~3.6 KB per message**, roughly 3× the LoRa spike's post-L2 figure
and entirely workable on a bearer that carries IP.

### 6.3 The governor

Satellite mode needs an explicit scheduler, not just smaller messages:

- **Burst, then idle.** Wake on a satisfied ultra-constrained path, drain the outbound text queue,
  do one conditional mailbox LIST (§3.2), GET only what is new and text, close. Do not hold a QUIC
  session open with keepalives across a pass gap — the keepalives cost more than the messages.
- **Quality-aware depth.** `NWPath.linkQuality == .minimal` sends the single oldest queued message
  and stops. `.moderate` or `.good` drains the queue and reconciles roster state.
- **A hard byte ceiling per pass,** surfaced in the UI, with the counter visible. Google's guidance
  warns that the system may cut off an app that does high-bandwidth transfers on a constrained
  network; self-limiting is cheaper than being cut off.
- **Cold-start suppression.** Haven's mailbox cold start and delivery buffer already exist; on this
  path they need a satellite variant that fetches headers before bodies and never speculatively
  prefetches.
- **Pre-establish before departure.** Cache peer key bundles and warm sessions when the user is
  still on real internet, so a pass is not spent on a handshake. A PQ handshake on a cold session
  can cost more than the conversation it enables.

---

## 7. Push on satellite

Haven's notification path is a blind APNs relay on Cloudflare Workers (`push/worker.js`), sending
`alert` and `background` / `content-available` pushes, with the ciphertext carried in the payload
as `e` so the NSE (or the running Mac app) can decrypt in-process.

**Open question, to be answered empirically, not assumed:** does APNs traverse a T-Satellite bearer
for third-party apps at all? Apple's own Messages works over satellite, but that is not evidence
about third-party push. Android has an explicit answer — FCM's `bandwidth_constrained_ok` flag —
and Apple has published no equivalent. There is no `apns-` header in the iOS 27 SDK headers
suggesting one exists.

Two branches:

- **If push traverses:** Haven's design is already close to ideal. The ciphertext rides in the push
  payload, so a text message can be *delivered and displayed* without any fetch at all. That is the
  best possible outcome on this bearer and should be the headline of the T-Mobile submission.
- **If push does not traverse:** satellite mode needs a foreground poll — a user-initiated "check
  for messages" that runs the §6.3 burst — and the UI must say plainly that notifications do not
  arrive off-grid. Do not silently degrade to a background poll; that burns the budget invisibly.

Test this before writing any of S4.

---

## 8. Staged plan, with proof obligations

| Stage | What | Proof obligation | Ships alone? |
|---|---|---|---|
| **S0** ✅ | Postcard the `EpochEnvelope` container (= LoRa L0) — **landed, read AND write** | Done: 12,953 B → 3,632 B measured (3.57x); the hybrid signature is byte-identical across containers; writes gated on `circle_fully_compact_wire_capable` so one unadvertised member keeps the circle on JSON | **Yes** — done |
| **S1** | Signature profile decision (= LoRa L1) | Not recommended for satellite; see §6.2 | Deferred |
| **S2** | Container elision + trial decryption (= LoRa L2) | Trial-decrypt cost bounded at realistic circle sizes | Yes |
| **S3** ✅ | Constrained-path signal into core — **landed** | `NWPath.isUltraConstrained` + `linkQuality` (iOS 26+, guarded) and `NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED` + `TRANSPORT_SATELLITE` (API 36+, guarded) plumbed through FFI to a single `TransportConstraint` in `haven-net`; unit tests for the pre-26 / pre-36 fallback paths | Yes — useful on bad cellular immediately |
| **S4** ✅ | Satellite-mode policy layer (§5) — **landed** | Every rejected category has a test proving it does not emit bytes when the constraint is set; the media override shows a cost estimate before sending | No — needs S3 |
| **S5** | The governor (§6.3) | Measured bytes per pass against a hard ceiling; conditional LIST verified to produce `204` on an unchanged mailbox; no keepalives observed across an idle window | No — needs S4 |
| **S6** | Platform opt-in + UI | `nw_parameters_set_allow_ultra_constrained` set only on satellite-approved connections; Android manifest `PROPERTY_SATELLITE_DATA_OPTIMIZED`; a banner stating the mode and a live byte counter; `NSURLErrorNetworkUnavailableReasonUltraConstrained` handled as a real state, not a generic failure | No — last |

**Sizing.** S0 and S3 are each a few days. S4–S6 are the bulk — call it three to four weeks across
core, Apple and Android given the parity rule. S1 and S2 are independent and optional.

**Do S3 before S0 if the goal is a demo,** and S0 before S3 if the goal is the byte budget. They do
not depend on each other.

---

## 9. The T-Mobile submission

Only attempt this after S6, with numbers in hand. The submission is an email to
`SatelliteApps@T-Mobile.com` and should contain:

1. **The answer to §4.1** — ask the destination-vs-identity question explicitly, up front. Do not
   guess and build.
2. **Measured byte figures**: bytes to send one text, bytes to receive one text, bytes to cold-start
   a session from nothing, worst case per pass. Post-S0, not today's numbers.
3. **The policy table** from §5 as evidence that Haven refuses, rather than throttles, the
   expensive categories.
4. **The push answer** from §7 — if the ciphertext rides in the push payload, say so loudly; it
   means a delivered Haven message can cost approximately zero bearer bytes on the receive side.
5. **A demo build** on both platforms with the mode forced on.
6. **The identity mismatch flagged deliberately.** Apple bundle IDs are still `com.blaineam.kith*`
   (pre-rename) while Android is `com.blaineam.haven`. An allowlist keyed on app identity will need
   both, spelled correctly, and a reviewer who sees "Kith" on one platform and "Haven" on the other
   will ask. Get ahead of it.

**Expectation setting.** The current roster is large-brand. Approval is discretionary, undocumented,
and there is no published SLA or appeals path. Treat a yes as upside, not as the plan.

---

## 10. What is out of reach, honestly

- **Meeting someone new off-grid.** ~3.2 KB of PQ identity, and buying the post-quantum property is
  precisely what makes it too large. Same conclusion as LoRa, for the same reason.
- **Recovering a rotated epoch off-grid.** If a circle rotated while you were away, that thread
  stays dark until real internet. This is correct behaviour, not a gap.
- **Privacy on this bearer.** Satellite is a carrier network with a satellite operator in the middle.
  Haven's confidentiality holds — the bytes are sealed — but Haven must never imply that satellite
  is a *private* path. If §4.2 is taken, the metadata surface narrows further. Say so in the UI.
- **Background delivery, possibly.** Pending the §7 answer, off-grid Haven may be a foreground,
  user-initiated experience. That is a legitimate product shape and should be designed as one
  rather than apologised for.
- **Admission itself.** Haven can control its byte budget, its policy layer and its egress profile.
  It cannot control whether a carrier chooses to list it. Build the parts that are Haven's.
