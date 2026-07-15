# Threat model & abuse resistance

## Who we protect, against whom

Haven is for small circles of real-world friends and family sharing private media. We
protect **content confidentiality, content integrity, and user anonymity** against:

| Adversary | What they can do | Our defense |
|---|---|---|
| Relay operator / network observer | See traffic timing & size; see `IP ↔ node id` for peers it serves; store ciphertext | Everything is E2E hybrid-PQ encrypted; a relay holds no key and never sees plaintext. It *does* see your node id — that is how membership authorization works. Nothing is logged or persisted |
| **Future quantum adversary** ("harvest now, decrypt later") | Store today's ciphertext, decrypt later | Hybrid X25519 + ML-KEM-768 key establishment — must break *both* |
| Active MITM on a shared link | Substitute their keys for the real recipient's | Link carries a verification hash; in-person QR is the strong anchor; new contacts are *approved*, with safety-phrase confirmation |
| Lost/stolen device | Read local content & keys | **Every on-device copy of the master seed is Secure-Enclave-wrapped** — the active seed, the NSE's shared-group push-decrypt mirror, and the device-local identity-recovery archive are each ECIES-sealed to a non-extractable P-256 Enclave key, so a raw Keychain dump yields nothing without the Enclave. (The one unsealed copy is the *opt-in* iCloud-synced archive, which must travel between devices and is protected by Apple's E2E iCloud Keychain instead.) Passphrase-encrypted backup; (planned) at-rest content encryption + remote disavow |
| Spammer using a public link | Flood connect requests | Requests are inert until approved; per-link expiring/single-use tokens; block list |
| A blocked user | Keep contacting you | Client-side refusal + removal from shared groups; no central account to reach you through |

## IP addresses (the honest version)

A relay or storage node **transiently handles your IP** — that is physically how it
moves bytes to you. So "no node ever sees your IP" is false and we don't claim it.
What we guarantee instead, enforced by default config (see `RELAY-AND-DEPLOY.md`):

- **Never logged / never persisted** — RAM-only, no access logs, provider logging off.
- **Seen with your node id, by design** — a relay authenticates the connecting peer by its
  iroh node id, which *is* your Haven public key (`core/haven-net/src/blobstore.rs:537`).
  It has to: membership authorization — the check that stops a stranger who learns the
  relay id from enumerating a circle's mailbox — is enforced by comparing that key against
  the circle's member set (`blobstore.rs:687-709`) and against self-sync slot ownership
  (`blobstore.rs:742-748`). So while it handles your bytes, a relay **can** associate your
  IP with your public key. It sees no content: bodies are circle-sealed and it holds no key.
  This is a deliberate trade — the alternative (an unauthenticated relay) is a relay anyone
  can enumerate. Run your own relay, or one run by a circle member, if that link matters to
  you. The storage mailbox is a Haven relay (the user's own or a volunteer's) or the user's
  own S3-compatible bucket, so there is no operator-funded quota to meter (per D15).
- **Hideable, by your own choice of path** — if you want a node to not see your real IP at
  all, run Haven behind your own VPN, or point it at a relay/discovery node you host
  yourself. Both work today, on every platform, without giving up direct P2P or calls.

We evaluated an opt-in onion/proxy (Tor) mode and **declined it** — see `TOR.md`. Tor is
TCP-only, so iroh's QUIC/UDP data plane and WebRTC calls can never traverse it; the only
constructible variant is relay-only and would delete direct P2P and calling. We are not
planning it, and we won't imply otherwise.

Promise: **never logged, never sold, never readable.** Not "never seen" — a relay
necessarily learns `IP ↔ node id` for as long as it is moving your bytes, and nothing
persists it.

## Explicit non-goals (for honesty)

- **Metadata-perfect anonymity vs. a global passive adversary, by default.** We hide
  content, and we log nothing — but a relay both *handles* your IP and *authenticates*
  your node id in order to route bytes and enforce membership, so the `IP ↔ node id`
  association is available to it in memory while you're connected. To keep a node from
  seeing your real IP, run Haven behind your own VPN or use a relay/discovery node you
  host yourself. There is no onion mode and none is planned (evaluated and declined —
  `TOR.md`).
- **Protecting against a fully compromised endpoint.** If malware owns the device, it
  owns the plaintext. Standard for any E2E system.
- **Moderating content centrally.** There is no server to moderate from (by design).

## Abuse resistance — the hard part of E2E social

A private, server-free, E2E network *will* attract "how do you stop bad content"
questions, especially CSAM. Our answers are structural, not bolted-on:

1. **No global discovery, ever.** Distribution is strictly friend-graph-bounded.
   There is no public feed, no stranger-reach, no virality mechanic. You can only
   send to people who approved you. This removes the broadcast vector entirely.
2. **On-device sensitive-content analysis.** Apple's `SensitiveContentAnalysis`
   flags nudity locally (nothing leaves the device); flagged media is blurred with
   tap-to-reveal. This is a *safety* feature for recipients, run with zero data
   collection. Honest limits: **the analyzer is Apple-only**, and it follows the
   *system* "Sensitive Content Warning" setting — there is no per-circle toggle
   (`apple/HavenApp/SensitiveContent.swift:18-22`). An Apple device that flags media
   federates a `SensitiveFlag` event to the circle, so peers blur it without running
   the analyzer themselves — but **only Apple clients currently render that blur**;
   Android and desktop receive the flag and ignore it. See `ROADMAP.md` → Outstanding.
3. **Approval + blocking as first-class.** Every contact is opt-in; blocking is
   immediate and complete.
4. **No anonymity for *abuse within a group*.** Posts are signed by identity keys, so
   members of a group can always attribute content to a member and remove/block them.

These are deliberately the same mechanisms that prevent the doomscroll dynamic the
product exists to avoid: small, bounded, consensual circles.

## Open questions to resolve before real users

- Key-recovery UX vs. security (escrow design).
- Per-link capability/revocation token format (see `LINK-SYSTEM.md`).
- Whether to support optional, *user-held* hash-matching against known-bad media
  sets without any server or reporting (privacy-preserving, controversial — needs
  thought).
