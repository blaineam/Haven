# Haven over LoRa / Meshtastic (off-grid radio transport)

> **Status — design spike, not built.** This is the full plan for carrying Haven messages over
> long-range sub-GHz radio (LoRa, via a Meshtastic-firmware node), so two people with no internet,
> no cellular and no Wi-Fi can still exchange text at kilometre range. It is **design only**; no
> product code accompanies it. It mirrors `docs/TREEKEM-DESIGN.md`, `docs/SEED-DROP-DESIGN.md` and
> `docs/RESILIENCE-DESIGN.md`: staged, with proof obligations, honest tradeoffs, and every claim
> about Haven grounded in the real code.
>
> **Locked framing (do not relitigate):**
> - **This is a transport, not a product pivot.** Haven stays what it is. LoRa is a fourth rung
>   below Bluetooth on the path ladder (`core/haven-p2p/src/transport.rs`), reached only when
>   nothing else is.
> - **Content confidentiality is untouchable.** Everything that crosses the radio is already sealed
>   under a circle epoch key (`docs/GROUP-KEYING.md`). Nothing here may add a plaintext path, a
>   key-holding participant, or a Meshtastic-channel-PSK "encryption" that replaces our own. The
>   radio carries opaque bytes exactly as the relay does.
> - **Signature authenticity is the one thing on the table, and only in a named profile.** §3.3 is a
>   maker decision, not an engineering default. It does not touch confidentiality.
> - **Text only, deliberately.** Media, calls, stories, history backfill and self-sync are
>   hard-rejected on this path (§6), not rate-limited. The bandwidth gap is three orders of
>   magnitude; there is no clever encoding that closes it.
> - **Supplementary, never a standalone client.** You cannot meet a stranger over LoRa (§7.1) and
>   you cannot recover a rotated epoch over LoRa (§7.2). Pairing stays QR/nearby.
> - **Parity applies.** Per the standing rule, Apple + Android + desktop land in the same wave, not
>   in three separate ones.

---

## 0. TL;DR + the byte budget

The plumbing is the easy part — the seam already exists and is already used by a non-IP transport.
The blocker is arithmetic: **a Haven "hi" is ~12 KB on the wire, and a Meshtastic packet carries
~200 usable bytes at ~1 kbps shared across the whole mesh.**

### 0.1 Where the 12 KB goes (a one-word DM, today)

A DM is an `EpochEnvelope` (`core/haven-p2p/src/groupkey.rs:134`), sealed by
`seal_event_in_epoch` (`:189`) or `seal_event_ratcheted` (`:239`):

| Field | Bytes (binary) | Note |
|---|---|---|
| `signature` — Ed25519(64) ‖ ML-DSA-65(3309) | **3,373** | `core/haven-p2p/src/identity.rs:81` |
| `ciphertext` — AEAD over the JSON `Event` | ~198 | 12 nonce + ~170 plaintext + 16 tag |
| `sender` (full node id) | 32 | |
| `salt` | 16 | |
| `circle_id` (string) | ~36 | |
| **binary subtotal** | **~3.6 KB** | |

Then `EpochEnvelope::to_bytes` is **`serde_json`** (`groupkey.rs:160`). `serde_json` renders every
`Vec<u8>` as an array of decimal numbers — `[104,105,…]` — at ~3.5 ASCII characters per byte. The
actual wire form is therefore **~12–13 KB**.

This is the same bloat that was already diagnosed and fixed for `SealedEnvelope`, which carries a
`HVE1` tag and a postcard body precisely because JSON turned a 48 MB video into a 167 MB blob
(`core/haven-p2p/src/social.rs:154-168`). `EpochEnvelope` never got that fix. **It is a live
inefficiency on every transport Haven has**, not a LoRa-specific one — see stage L0.

### 0.2 What the radio allows

Meshtastic modem presets, with time-on-air for a full-size packet computed at CR 4/5, BW 250 kHz:

| Preset | SF | Raw bitrate | ToA, 237 B packet | Range |
|---|---|---|---|---|
| `SHORT_FAST` | 7 | ~10.9 kbps | ~0.24 s | shortest |
| `MEDIUM_FAST` | 9 | ~3.5 kbps | ~0.66 s | middle |
| `LONG_FAST` (default) | 11 | ~1.07 kbps | ~2.0 s | longest |

Payload ceiling is ~237 bytes per packet before our own framing, so budget **~200 usable**. Every
packet is re-aired by every node that rebroadcasts it, up to `hop_limit` (default 3), so a packet's
true cost to the mesh is roughly its ToA times the number of rebroadcasters. In EU868 the 1%
duty-cycle limit is a *legal* ceiling: ~36 seconds of transmit per hour per device.

> **verify: needs a spike.** Preset table, `hop_limit` default, the 237-byte `DATA_PAYLOAD_LEN`, the
> `PRIVATE_APP` portnum and the BLE characteristic layout are all *external* facts about Meshtastic
> firmware, not facts about our code. Stage L1 re-verifies every one against the firmware actually
> flashed on the test radios before anything is built on them.

### 0.3 The gap, stated plainly

| | Today | After §3 | Target |
|---|---|---|---|
| "hi" on the wire | ~12,600 B | **~230 B** | ≤ 1–2 packets |
| Packets (200 B usable) | ~65 | **2** | |
| Airtime, `LONG_FAST` | ~130 s | **~4 s** | |
| × 3 hop rebroadcast | ~6.5 min of mesh occupancy | **~12 s** | |
| Messages/hour, EU 1% duty | ~0.3 | **~9** | |

At 12 KB, LoRa is not slow — it is *non-functional*, and would be antisocial to every other user of
a shared mesh. At 230 bytes it is a product. **The entire feasibility of this feature is a wire-format
question, and §3 is the load-bearing section of this document.** Everything else is ordinary work.

---

## 1. Goal and non-goals

### 1.1 The success criterion

> Two people who are already Haven contacts in an established circle, both out of cellular range,
> each carrying a phone and a ~$30 LoRa node, can exchange short text messages — and those messages
> appear in the same conversation, deduplicated, as the ones they sent each other over the internet
> yesterday.

Delivery is best-effort with repair (§4.2), not guaranteed. Latency is seconds-to-minutes, not
milliseconds. That is the honest product: a field radio, not a chat app.

### 1.2 Non-goals

- **Not a Meshtastic client.** Haven does not become a general Meshtastic app, does not join public
  channels, and does not interoperate with other Meshtastic users' messages.
- **Not media, not calls, not stories, not backfill.** §6.
- **Not onboarding.** §7.1.
- **Not a mesh router for strangers.** We are a Meshtastic *application*, riding the firmware's own
  mesh. We do not implement routing, and we do not carry other people's traffic beyond whatever the
  firmware does on its own.
- **Not RF anonymity.** §8 is explicit that this transport has a materially worse metadata posture
  than the blind relay, and the design does not pretend otherwise.

---

## 2. What exists to build on (verified against the code)

### 2.1 The frame seam is real and already carries a non-IP transport

Every Haven message on every path is `[type: u8][payload]` — `frame()` at
`apple/HavenApp/FeedView.swift:4814`, dispatched by `dispatchInboundFrame` at `:5038`. The frames
that matter here:

| Type | Meaning | LoRa? |
|---|---|---|
| 0 | hello / identity announce | slim variant only (§7.3) |
| 1 | sealed event (post, DM, reaction, comment) | **yes, text-only** |
| 3, 5 | media request / media chunk | **rejected** |
| 9 | mesh relay (an internet-connected phone forwards for a peer) | **rejected inbound; §5.4 gateway is the inverse** |
| 10–22, 30–33 | call signaling, WebRTC, media wanted/back | **rejected** |
| 23 | own-device self-sync | **rejected** |
| 24, 25 | device enrollment request / grant | **rejected** |

`NearbyTransport` (`apple/HavenApp/NearbyTransport.swift`) is the proof this seam works for a
non-IP link: MultipeerConnectivity carries "the exact same sealed protocol frames as the iroh path",
with its own token-bucket rate limiter, and the core never learns which wire the bytes came off.
**A LoRa transport is structurally the same object with a three-orders-of-magnitude smaller budget.**

### 2.2 The path ladder is trait-only

`core/haven-p2p/src/transport.rs` declares `Path::{Bluetooth, LocalWifi, Relay}`, a `priority()`
ordering and a `suits_bulk()` predicate — and nothing consumes it. Real path selection lives in the
app layer. Adding `Path::Lora` at priority 3 with `suits_bulk() == false` is a two-line change to a
module that currently decides nothing; the *actual* routing decision has to be made where the sends
are (`sendIroh`, `nearbyBroadcast` at `FeedView.swift:4906`, and the mailbox put).

This matters for sizing: the ladder is not a plug-in point we can drop a transport into. Stage L4
has to build the selection it implies.

### 2.3 The precedent for a degraded profile already shipped

`Identity::verify_ed25519_only` (`core/haven-p2p/src/identity.rs:116`) exists because Apple caps a
push at 4 KiB and "a 3,200-byte bundle plus a 3,373-byte signature is ~10 KiB once base64'd, so
EVERY push would be dropped." The notification path therefore verifies the classical half against
the bare 32-byte node id and accepts the loss of the post-quantum signature, in a narrowly-scoped
context, deliberately.

**LoRa is the same trade against a harder ceiling.** §3.3 is not a new idea in this codebase; it is
the second application of a decision already made and already documented once.

### 2.4 What the radio profile inherits for free

- **Deterministic sealing.** `seal_event_in_epoch` derives its salt as a PRF over the plaintext
  keyed by the epoch key (`groupkey.rs:208-215`), so re-sealing the same event reproduces the same
  bytes. Two copies of one message do not become two events.
- **An encoding-independent event id.** `Event.id = BLAKE3(author ‖ created_at ‖ kind)`
  (`social.rs:81-101`) — it is derived from the *event*, not from any envelope encoding. This is
  what makes cross-transport dedupe (§3.6) work at all.
- **A CRDT that tolerates loss and reordering.** Per `core/haven-net/src/livedelivery.rs`, absence
  is never information and merge is commutative/idempotent. A dropped LoRa packet is exactly the
  same condition as a sibling that missed a live push — a solved problem, not a new one.

---

## 3. The compact wire profile (the core section)

Three changes, in descending order of leverage. Only the second is a policy decision; the other two
are pure engineering.

### 3.1 L0 — postcard the `EpochEnvelope` container

**12 KB → 3.6 KB, on every transport.** Give `EpochEnvelope::to_bytes` the treatment
`SealedEnvelope` already has (`social.rs:163-181`): a 4-byte magic tag (`HVP1`) followed by a
postcard body, with `from_bytes` sniffing the tag and falling back to the legacy JSON parse forever.
A JSON envelope always starts with `{`, which no postcard encoding can produce, so the
discrimination is exact.

Two properties make this safe to land alone, before anything about LoRa is decided:

- **The signature is unaffected.** `EpochEnvelope::transcript` (`groupkey.rs:169-185`) hashes the
  *fields*, not their serialized form. Changing the container does not touch signing or verification.
- **The content address is unaffected**, for the same reason — so a re-sealed event still dedupes on
  the relay instead of accumulating a second copy.

This is worth doing whether or not LoRa is ever built. It cuts every mailbox put, every relay byte,
every nearby frame and every push by roughly 3.5×.

### 3.2 The residual after L0

| Field | Bytes | Share |
|---|---|---|
| signature | 3,373 | **93%** |
| ciphertext | ~198 | 5% |
| ids + salt + circle_id | ~84 | 2% |

3.6 KB is 18 packets, ~36 s of `LONG_FAST` airtime, ~1 message per 100 s in EU868. That is
borderline-unusable on the default preset and marginally usable on `SHORT_FAST` at close range.
**L0 alone does not deliver the feature.**

### 3.3 L1 — the signature decision (this is the whole ballgame)

Ninety-three percent of a post-L0 envelope is the ML-DSA-65 half of the hybrid signature. Dropping
it in a named radio profile takes 3,373 bytes to 64.

**What degrades, precisely:**

| Property | Over the relay | Over the radio profile |
|---|---|---|
| Content confidentiality | AES-256-GCM under an epoch key derived through the hybrid KEM | **unchanged** — the epoch key was distributed over the normal path, PQ intact |
| Harvest-now-decrypt-later resistance | yes | **unchanged** |
| Sender authenticity vs. a classical attacker | Ed25519 + ML-DSA | Ed25519 — **unchanged in practice** |
| Sender authenticity vs. a *future quantum* attacker | ML-DSA holds | **lost for radio-profile messages** |

The exposure is: an adversary with a cryptographically-relevant quantum computer could, *later*,
forge an Ed25519 signature and inject a fabricated message attributed to you — but only into the
radio path, only within RF range, and only for a message whose confidentiality is still intact.
They cannot read anything. This is strictly narrower than the exposure the push path already
accepts, and it is a **maker decision to record in `docs/SECURITY.md`, not an engineering default**.

Options, in order of preference:

1. **`sig_profile = classical` on radio frames only.** The envelope carries a one-byte profile tag;
   a receiver applies `verify_ed25519_only` for radio-profile frames and the full hybrid verify for
   everything else. A relay-delivered frame can never claim the classical profile — the profile is
   a property of the receiving transport, checked at the transport boundary, not a field the sender
   gets to assert.
2. **Send both, opportunistically.** The radio copy is classical; if the same event later arrives
   over the internet with its full hybrid signature, it supersedes and the conversation ends up
   fully PQ-authenticated after the fact. Free, given §3.6.
3. **Keep the hybrid signature and accept 18 packets.** Honest fallback if option 1 is rejected;
   the feature then only works on `SHORT_FAST` at short range and should be scoped and marketed as
   such rather than quietly shipped as "LoRa support".

**Do not** introduce a shorter post-quantum signature scheme to split the difference. Haven already
carries one novel construction that `knox.config.mjs` explicitly refuses to certify; a second is not
affordable.

### 3.4 L2 — container elision and trial decryption

With the signature at 64 bytes, the remaining ~84 bytes of ids matter again:

- **`circle_id`: string → 4-byte tag.** Not a truncation of the id (which would be a stable,
  cross-epoch linkability handle for any passive listener). Instead `tag = HMAC(epoch_key,
  "haven-lora-tag-v1")[..4]` — meaningless to anyone without the key, and it rotates with the epoch.
  §8.3 is honest that it is still a *within-epoch* correlation handle.
- **`sender`: 32 bytes → omitted.** The receiver trial-decrypts against its own known
  `(circle, epoch)` keys — derive the event key (`derive_event_key`, `groupkey.rs:120`) and let the
  GCM tag decide. A user holds dozens of candidate keys, not thousands, and the 4-byte tag prunes
  almost all of them first. The true sender is inside the sealed `Event.author` anyway; the outer
  `sender` field is redundant on this path. Smaller *and* better for metadata.
- **`epoch`: u64 → varint delta.** Single byte in practice.
- **`salt`: 16 → 12 bytes.** The salt is a keyed PRF over the plaintext; 96 bits of it is ample for
  per-event key diversification. Needs a written collision argument before it lands.
- **Plaintext: deflate with a shared static dictionary.** The `Event` JSON is ~170 bytes for "hi",
  and ~110 of those are the fixed key names and the 96 hex characters of `id` + `author`. A
  dictionary primed with the `EventKind` variant names and the JSON skeleton takes a short DM to
  ~60–80 bytes. **The plaintext encoding itself stays canonical `serde_json`** — compression is
  applied to the serialized bytes and reversed before parsing, so `Event.id` and the content address
  are untouched (§3.6 depends on this).

### 3.5 The resulting layout

```
┌────────┬────────┬───────┬──────┬────────────┬───────────┐
│ ver+   │ circle │ epoch │ salt │ ciphertext │ ed25519   │
│ profile│ tag    │ delta │      │ (deflated) │ signature │
│  1 B   │  4 B   │ 1–2 B │ 12 B │   ~90 B    │   64 B    │
└────────┴────────┴───────┴──────┴────────────┴───────────┘
                                          total ≈ 172–230 B
```

One packet for a short DM; two for a sentence or so. Against ~12,600 bytes today, that is a **~55×
reduction**, and it is the difference between a feature and a demo.

### 3.6 Dedupe across transports (why two paths do not make two messages)

`Event.id` is `BLAKE3(author ‖ created_at ‖ kind)` over the canonical JSON of `kind`
(`social.rs:93-101`). It is a property of the event, not of the envelope. Because §3.4 leaves the
plaintext encoding canonical and only compresses the serialized bytes, an event that arrives over
the radio and again over the relay presents **the same `Event.id` on both paths**, and the existing
ingest dedupe absorbs the second copy with no new code.

This is what makes §3.3 option 2 free: a classical-signed radio copy shows up now, the hybrid-signed
copy supersedes it when connectivity returns, and the user sees one message throughout.

**Proof obligation (L2):** a round-trip test that seals one event, encodes it in both the standard
and radio profiles, decodes both, and asserts byte-identical `Event` and identical `Event.id`.

---

## 4. The reliable-datagram layer

### 4.1 What Meshtastic does not give us

- **No fragmentation.** Over ~237 bytes, the application fragments or the message does not exist.
- **No ordering.** Flood routing delivers what it delivers, in whatever order.
- **No useful delivery guarantee for our shape of traffic.** The firmware's ack applies to direct
  packets; a multi-fragment application message has no notion of completeness that the radio knows
  about.
- **No backpressure.** Queueing faster than airtime allows silently drops, and floods a shared
  channel that other people are also using.

Contrast the current transports: `haven-net` reads up to `MAX_PAYLOAD = 256 * 1024 * 1024`
(`core/haven-net/src/lib.rs:53`) and `NearbyTransport` paces at 256 KB/s. This layer's budget is
about 200 bytes per two seconds.

### 4.2 Fragmentation + repair

A small, deliberately boring protocol:

- **Fragment header: 4 bytes.** 16-bit message id (random, per message), 6-bit index, 6-bit count,
  4 bits flags. Caps a message at 64 fragments ≈ 12 KB, which is far above the §6 policy ceiling and
  keeps the header honest.
- **Repair by NACK, not ACK.** The receiver, on a message it has partially seen and then gone quiet
  on for a preset-derived interval, sends one bitmap of missing indices. The sender re-airs only
  those. An all-ACK scheme doubles airtime for the common case where nothing was lost.
- **Bounded retries, then surface it.** Three repair rounds, then the message is marked
  `not delivered over radio` in the UI and left queued for whichever transport comes back first.
  Silent failure is not acceptable on a link this lossy.
- **Duplicate suppression.** A seen-set of `(message id, index)` with a short TTL — flood routing
  means a fragment legitimately arrives several times.
- **Reassembly TTL.** Partial messages expire; a mesh partition should not pin memory forever.

### 4.3 The airtime governor

The single most important component for not being hated by everyone else on the mesh, and the
direct descendant of the `NearbyTransport` token bucket (which exists because continuous Multipeer
at kpkt/s cooked a phone).

- Budget in **airtime, not bytes** — the same 200 bytes costs 0.24 s or 2.0 s depending on preset,
  so the bucket must be denominated in seconds of ToA and refilled from the negotiated preset.
- **Region-aware hard cap.** EU868 gets a 1% duty-cycle enforcement that the app will not exceed
  regardless of what the user asks for. This is a legal limit, not a courtesy.
- **Yield to the channel.** If the radio reports channel utilization above a threshold, defer.
- **Priority classes:** repair NACKs > new text > slim hello > everything else (of which there is
  nothing, per §6).

---

## 5. Radio attachment per platform

The radio is a separate device speaking Meshtastic protobufs. Haven talks to it; Haven is not it.

| Platform | Link | Implementation |
|---|---|---|
| iOS | BLE GATT | Swift/CoreBluetooth client, alongside `NearbyTransport`. Serial is impossible without MFi; BLE is not restricted. |
| Android | BLE GATT (USB serial optional) | Kotlin equivalent, alongside `NearbyTransport.kt`. |
| macOS / Windows / Linux | USB serial or TCP | The Rust `meshtastic` crate in `haven-net`, which is the only place a Rust radio client is usable at all. |

**Why not one Rust client everywhere:** on iOS, CoreBluetooth cannot live in the Rust core. The
existing precedent is exactly right — `NearbyTransport` is platform Swift/Kotlin handing opaque
frames across the FFI, and the core never learns the wire. LoRa follows it. The cost is that the
protobuf client is written approximately twice (Rust for desktop, Swift + Kotlin for mobile), which
is real and is priced into stage L4.

Frames ride a private portnum with `want_ack` off (our own repair layer is cheaper than the
firmware's), a configurable `hop_limit`, and no dependence on Meshtastic channel encryption — our
bytes are already sealed, and the channel PSK is not part of our security model in either direction.

**§5.4 — the gateway, deliberately deferred.** The inverse of frame 9 (an internet-connected phone
forwarding radio traffic to the relay for an off-grid peer) is a genuinely valuable feature and a
genuinely large one: it re-opens routing, trust and abuse questions that frame 9 answered for a
different topology. It is stage L6, after the basic link has soaked, and it is explicitly not
required for the §1.1 success criterion.

---

## 6. Policy: what may cross the radio

**Enforced as rejection at the transport boundary, not as a rate class.** Today
`nearbyBroadcast` (`FeedView.swift:4906`) reclassifies anything over 2 KB as bulk and paces it. On
LoRa there is no pacing that makes a 32 KB media chunk acceptable; there is only "no".

- **Allowed:** frame 1 carrying `Message`, `Comment` (text only), `Reaction`, `Vote`. A slim hello
  (§7.3). Repair NACKs.
- **Rejected, silently dropped outbound and ignored inbound:** frames 3, 5 (media), 9 (relay), 10–22
  and 30–33 (calls, WebRTC, media-wanted), 23 (self-sync), 24–25 (enrollment), and any frame 1 whose
  `EventKind` carries `media`, `music`, or `story`.
- **Hard size ceiling** on the encoded radio envelope, checked before fragmentation, with a real UI
  affordance: *"Too long to send over radio — 240 characters max out here."* Truncating silently or
  queueing something that will never send are both worse than saying it.
- **Visible transport state.** A message sent over radio is badged as such, and a message that could
  not be sent says so (§4.2). The user is standing on a mountain; ambiguity is expensive there.

---

## 7. What LoRa structurally cannot do

### 7.1 You cannot meet a stranger over the radio

An identity bundle is **3,200 bytes** — Ed25519(32) ‖ X25519(32) ‖ ML-KEM-ek(1184) ‖ ML-DSA-vk(1952)
(`identity.rs:126`). That is ~16 fragments needing perfect reassembly, roughly a minute of
`LONG_FAST` airtime each way, before a single word is exchanged. A first-contact handshake also
needs the KEM round trip on top.

**Decision: not supported.** Pairing stays QR / nearby / link. LoRa is for contacts you already have.
A "classical-only radio identity" (64 bytes) would fit and is **rejected** — it would create
non-PQ contacts as a side effect of a transport choice, which is exactly the kind of quiet security
regression the mandate exists to prevent.

### 7.2 You cannot recover a rotated epoch over the radio

If a circle rotated its epoch while you were off-grid, incoming radio messages are sealed under a
key you do not hold, and the `KeyCommit` that would give it to you is itself a multi-KB payload
delivered through the mailbox.

**Decision: pin to the last common epoch.** Each device tracks, per peer, the newest epoch it has
evidence the peer holds; radio sends seal under that epoch rather than the current one. When no
common epoch exists, the conversation is dark over radio until one party reaches the internet, and
the UI says so explicitly rather than dropping messages into a void.

This is a real, permanent limitation of putting forward-secret group keying underneath a 1 kbps
link, and it should be documented in the user-facing help, not just here.

### 7.3 Addressing needs a slim hello

Meshtastic node numbers are not Haven device ids. A slim hello binds an 8-byte Haven device-id
prefix to a Meshtastic node number, cached per radio session. **Eight bytes, not four** — Haven has
been bitten by id collisions before (own-device relay-id collision; the Multipeer same-identity
tie-break), and the full binding must be re-verified the next time the peer is reached over a
transport that carries a complete identity.

---

## 8. Security and metadata analysis (the new surface)

### 8.1 What does not change

Content confidentiality, the blindness of relays, the maker holding no keys, and the epoch-key
model are all untouched. The radio is a dumber, slower relay carrying the same opaque bytes.

### 8.2 What does change: RF is a broadcast medium

The relay path is a *blind* path — an untrusted party sees sealed bytes it cannot read. The radio
path is a *public* path: **anyone within RF range — kilometres, not metres — with a $30 receiver
sees every transmission.** They learn packet sizes, timing, transmission counts, the Meshtastic node
number, and (with a directional antenna) an approximate bearing to the transmitter.

For a threat model that includes "someone is looking for you in this valley", **turning on the radio
is a location beacon.** That is a strictly worse position than any existing Haven transport, and it
must be stated in `docs/THREAT-MODEL.md` and in the feature's own UI before first use, not buried.

### 8.3 The within-epoch correlation handle

The 4-byte circle tag (§3.4) is unlinkable across epochs and meaningless without the key, but within
one epoch it lets a passive listener group transmissions as "same conversation" and count them.
Omitting it entirely is possible — trial-decrypt everything — at the cost of a linear scan per
inbound packet and slightly more battery. **Recommendation: keep the tag, document the property.**
It is a weaker handle than the Meshtastic node number that the firmware puts in the clear anyway.

### 8.4 New attack surface

- **Fragment-reassembly DoS.** An attacker floods partial messages to exhaust reassembly buffers.
  Mitigated by bounded slots, TTL expiry, and per-source-node caps.
- **Repair amplification.** Forged NACKs make a victim re-air fragments and burn its duty-cycle
  budget. Mitigated by binding a NACK to a message id the sender actually sent, capping repair
  rounds at three, and charging repairs against the same airtime bucket.
- **Profile downgrade.** An attacker relays a classical-signed radio frame into the internet path
  hoping it is accepted there. Mitigated structurally: the accepted signature profile is a property
  of the *receiving transport*, decided at the transport boundary, never a field the sender asserts.
- **Replay.** A recorded packet re-aired later. The deterministic content address and `Event.id`
  make replay a no-op at ingest — it dedupes into the message that is already there.

---

## 9. Staged plan L0..L6 with proof obligations + sizing

Honest sizing: **~8–11 weeks** to text-only DMs across all three platforms, plus ~$100 of hardware
(two nodes minimum, four for a realistic multi-hop test). Smaller than the resilience v2, larger
than it looks, because §3 is delicate, §4 is a protocol, and the parity rule multiplies §5 by three.

| Stage | Scope | Proof obligation | Sizing |
|---|---|---|---|
| **L0. Postcard the `EpochEnvelope`** | `HVP1` tag + postcard body, JSON fallback forever. No LoRa content. Ships on its own merits. | Round-trip both encodings; signature and content address prove byte-identical to today (transcript hashes fields, `groupkey.rs:169`); a legacy JSON envelope still opens; mailbox dedupe unchanged under a re-seal sweep | **S** — mirrors a fix `SealedEnvelope` already has |
| **L1. Hardware spike + fact-check** | Two nodes flashed; desktop-only Rust `meshtastic` client; verify every external number in §0.2 against the actual firmware; measure real ToA and loss at range. | A byte round-trips desktop→radio→radio→desktop; the §0.2 table is either confirmed or corrected **in this document** before L2 starts | **S** — a week, and it is the cheapest possible de-risking |
| **L2. The radio wire profile** | `to_lora_bytes` / `from_lora_bytes` (§3.4), the deflate dictionary, the profile tag. **§3.3 decided and written into `docs/SECURITY.md` before code.** | §3.6 round-trip test (identical `Event`, identical `Event.id` across profiles); a fuzz corpus of malformed radio envelopes never panics; a measured "hi" is ≤ 2 packets; a classical-profile frame is **rejected** when presented on the internet transport | **M** — small surface, high care, one policy gate |
| **L3. Reliable-datagram layer** | Fragmentation, NACK repair, dup suppression, reassembly TTL, the airtime governor (§4). | Simulated-link harness (200 B MTU, per-preset ToA, configurable loss, duty cycle) delivers a 5-fragment message at 30% loss within three repair rounds; the governor provably never exceeds EU 1% under a flood; forged NACKs cannot exceed the airtime bucket | **M–L** — a protocol, not a feature |
| **L4. Platform radios + path selection** | Swift CoreBluetooth client; Kotlin client; desktop serial/TCP; `Path::Lora` and the *actual* selection logic the ladder only implies (§2.2); pairing/region/preset UI. | Two phones, two radios, no internet or Wi-Fi of any kind: a DM arrives on all three platforms; a radio unplugged mid-message surfaces a failure rather than hanging | **L** — three platforms, protobuf client written ~twice, per the parity rule |
| **L5. Policy, UX, docs** | The §6 allowlist as hard rejection; size ceiling + copy; transport badging; queued-and-undelivered states; §7.2 last-common-epoch pinning; `docs/THREAT-MODEL.md` §8.2 addition; `docs/SECURITY.md` profile note; user-facing help. | Every rejected frame type proves un-sendable on the LoRa path (not merely deprioritised); an over-long message shows the ceiling copy; a rotated-epoch peer shows the dark-conversation state instead of silently failing | **M** — mostly writing, and the writing is the safety |
| **L6. Field run + gateway (deferred)** | Real multi-hop range/loss/battery run; only then, the §5.4 internet gateway. | A four-node, two-hop field run over ≥1 km sustains a conversation for an hour within duty cycle; battery cost measured and published | **M–L** — the gateway is a design cycle of its own and must not be scoped in early |

**Sequencing logic (from risk, not convenience):** L0 is free, ships alone, and helps every user
whether or not this feature exists. L1 costs a week and either validates the §0.2 arithmetic this
entire document rests on or corrects it before anything is built — it is deliberately the *second*
stage, not the fifth. L2 is gated on a maker decision (§3.3) because writing the code first would
quietly make that decision. L3 is fully testable on a simulated link with no radios in the loop. L4
is where the money and the parity burden are, and it is last among the build stages for that reason.
L6 is deferred whole, because the gateway is a routing design and this document is a transport one.

---

## 10. What makes this hard, and what's genuinely out of reach (honest)

- **The bandwidth gap is three orders of magnitude and no encoding closes it.** §3 gets a text
  message to one packet. Nothing gets a photo there. A user who expects Haven-over-radio to be Haven
  will be disappointed unless the UI is unambiguous that this is a text-only field mode. That
  expectation-setting is a product problem, and it is harder than the protocol.
- **The signature decision is unavoidable and it is not mine to make.** Ninety-three percent of the
  payload is one field. Either it goes and the radio profile is classically authenticated, or it
  stays and the feature works only on the short-range preset. There is no third answer that keeps
  both the post-quantum signature and a usable link, and pretending otherwise would be the
  dishonest version of this document.
- **You cannot start a relationship out there.** §7.1 is permanent. The 3,200-byte identity bundle
  is what buys Haven its post-quantum property; it is also what makes radio onboarding impossible.
  Someone who buys a radio for a backcountry trip must pair *before* leaving, and if they do not,
  the feature is simply unavailable to them. Say it in the store copy, not in a support thread.
- **Forward secrecy and 1 kbps are in tension.** §7.2 means a circle that rotated while you were
  away is dark over radio. Every mitigation for that is a key-distribution payload that does not fit.
  This is a genuine cost of the epoch/TreeKEM model, correctly paid, and permanently visible here.
- **RF is a beacon.** §8.2. For most users this is irrelevant; for the users most likely to *want*
  an off-grid encrypted messenger, it may be disqualifying. Haven's whole pitch is that it does not
  leak who you are and where — and this transport leaks approximately where, to anyone listening,
  by physics. It must be opt-in, per-session, and honestly labelled.
- **It needs hardware, and hardware needs support.** Every user is now also a firmware updater, a
  region-setting configurer and a battery manager, on a device we do not make. Meshtastic firmware
  is a moving target with real breaking changes; "which firmware versions does Haven work with"
  becomes a matrix somebody maintains forever. That ongoing cost is larger than the build cost and
  is the strongest argument for scoping this narrowly or not at all.
- **There is no simulator.** L3's harness covers the protocol; it cannot cover antenna orientation,
  terrain, interference or a cheap board's clock drift. Every real bug in this feature will be found
  outdoors, by hand, and the QA fleet cannot help.

**Bottom line.** The transport work is ordinary and the seam is already there — `NearbyTransport`
proved the shape and frame 1 is the only frame that needs to cross. The feature is gated on one
arithmetic fact and one decision: a Haven message is ~12 KB because `EpochEnvelope` is JSON and 93%
of the binary is an ML-DSA signature. Fix the encoding (worth doing anyway) and name a classical
signature profile for the radio, and a DM fits in one packet. Do neither, and this is not buildable
at any effort level. **The recommendation is to land L0 on its own merits, spend a week on L1 to
verify the numbers, and gate everything after that on the §3.3 decision.**
