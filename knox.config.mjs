// Knox 🦊 audit config for Haven — a serverless, end-to-end-encrypted P2P social
// app. Resolved by `knox audit Haven`. This file lives WITH the repo so the
// audit surface travels with the code.
//
// Haven's security rests on: a Rust P2P/crypto core (haven-p2p, haven-ffi), an
// iroh-based transport (haven-net) with an untrusted+blind relay (haven-relay),
// and per-platform key storage (Apple Keychain/Secure Enclave, Android
// Keystore, desktop OS secret store). The audit concentrates there.

export default {
  project: 'Haven',
  root: '.',

  // In-scope subsystems. The crypto core + transport + client key storage.
  scope: [
    'core/haven-p2p/src',      // identity, device, crypto, groupkey, treekem, selfsync, enroll, social, transport
    'core/haven-ffi/src',      // the UniFFI boundary (memory ownership across FFI, seal/put paths)
    'core/haven-net',          // iroh transport (self-authenticating discovery, dial guards)
    'core/haven-relay',        // the UNTRUSTED, BLIND relay (must never see plaintext or keys)
    'apple/HavenApp/AccountStore.swift',   // Apple account-key storage (Keychain)
    'apple/HavenApp/DeviceRoster.swift',   // per-device identity + revocation state
    'android/app/src/main/java/com/blaineam/haven/core', // Android key/seed storage + core bridges
    'desktop/src-tauri/src/secret.rs',     // desktop OS secret store
    'desktop/src-tauri/src/store.rs',
  ],

  // Weight these domains heavily — they are Haven's crown jewels.
  focusAreas: [
    'crypto', 'key-management', 'data-in-transit', 'authz', 'authn',
    'memory-safety', 'business-logic', 'platform',
  ],

  threatModel: `
    Attacker capabilities:
      - A fully malicious RELAY operator (the relay is untrusted by design). It sees
        all routed frames and can drop, reorder, duplicate, or inject them. It must
        NEVER be able to read plaintext, keys, or link social-graph identities beyond
        what a blind forwarder inherently observes.
      - A network MITM on any transport hop (relay HTTP :8674, iroh/DERP, S3 media).
      - A malicious PEER: a friend, ex-friend, or stranger who can send crafted frames,
        roster updates, seed-drops, TreeKEM messages, and media refs.
      - A malicious PUSH provider (APNs relay on Cloudflare Workers) — a blind relay of
        sealed payloads; must not be able to read notification contents.
      - Theft of a device at rest (locked): key material must be protected by the OS
        keychain / Secure Enclave / Android Keystore and not recoverable.

    Trust boundaries:
      - The FFI boundary (haven-ffi UniFFI) between the Rust core and each client.
      - The relay and push provider are OUTSIDE the trust boundary (blind forwarders).
      - Each device holds its OWN identity; account id is a contact handle only, and
        device ids dial everywhere (Device-ID-Everywhere decision).

    Crown jewels:
      - The seed / root key material (all copies SE-wrapped; never plaintext at rest).
      - Group/circle keys, TreeKEM tree secrets, per-DM keys.
      - Forward secrecy + post-compromise security of the messaging ratchet.
      - Integrity of self-authenticating discovery (a peer id IS its key).
      - Correctness of revocation (removing a device/friend must actually cut access).
  `,

  // Known + ACCEPTED design decisions. Knox suppresses findings that merely
  // restate these — they are intentional, not vulnerabilities.
  acceptedRisks: [
    { id: 'accepted.relay-untrusted', note: 'The relay is untrusted and BLIND by design; it routes sealed frames and cannot read plaintext/keys. "Relay can see ciphertext/metadata it forwards" is expected — only flag it if the relay can actually recover plaintext, keys, or unintended identity linkage.' },
    { id: 'accepted.push-blind-relay', note: 'Push (APNs via Cloudflare Workers) is a BLIND relay of a sealed payload; the NSE decrypts client-side. Do not flag the push server seeing sealed bytes.' },
    { id: 'accepted.maker-holds-no-keys', note: 'Per the Kith security mandate, the maker/operator must NOT hold user keys and must not be a bypass target. Flag anything that would let the operator recover keys or impersonate users — that is IN scope, not accepted.' },
    { id: 'accepted.relay-plain-http', note: 'The relay media path is plain HTTP on :8674 with an auth token carried INSIDE the sealed frame (frame-19); payloads are already E2E-sealed. Flag only if the token or plaintext leaks outside the seal.' },
    { id: 'accepted.novel-crypto-treekem', note: 'TreeKEM is implemented on Haven\'s OWN post-quantum primitives (NOT RFC-interop). Knox is a first-line audit and must NOT certify this novel construction correct — flag correctness concerns as "needs specialist review" rather than passing them.' },
  ],

  // Design docs — read these first; audit the code AGAINST the intended design.
  contextDocs: [
    'docs/SEED-DROP-DESIGN.md',
    'docs/TREEKEM-DESIGN.md',
    'docs/RESILIENCE-DESIGN.md',
  ],
};
