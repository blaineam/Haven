# Relays, storage, and the deployment tool

Haven has **no central service**. What little infrastructure exists is federated,
swappable, hardened-by-default, and runnable by anyone. This doc defines the two
relay roles, the storage model, the IP-privacy guarantees (honestly), and the
multi-cloud deployment tool.

## Two relay roles — keep them separate

| | **Connection relay** | **Storage relay** ("mailbox") |
|---|---|---|
| Purpose | Forward live packets when two *online* peers can't NAT-punch directly | Hold an encrypted blob for an *offline* peer until pulled |
| Shape | Stateless running service (TURN/DERP-style, RAM-only) | Mostly **object storage** (S3/R2/B2/GCS) + a thin stateless broker |
| Sees | Ciphertext + the two IPs it bridges | Ciphertext + uploader/downloader requests |
| Best for | Real-time (calls, both-online transfers) | **Offline delivery + large/lossless files** |
| Cost | ~$5/mo VPS, or per-GB TURN | Storage + egress only; can be the user's *own* bucket |

A peer with no route at all falls through the chain from `ARCHITECTURE.md`:
**sender-online → group-gossip cache → storage relay (BYO or quota'd)**. The
connection relay is only for the live-but-NAT-blocked case.

## Redundancy & graceful fallback

A circle isn't limited to one relay. Each client keeps an **ordered set of relays per circle**
and degrades gracefully:

- **Redundancy (mirrored writes):** every post + sealed-media blob is `put` to *all* of the
  circle's relays (and the BYO S3 bucket). Keys are content-addressed, so re-puts are
  idempotent and the same envelope on N relays is harmless.
- **Fallback (fan-out reads):** the mailbox poll reads from *all* relays and dedups by the
  content key, so a message present on **any one reachable** relay still arrives. Media fetch
  tries each relay in turn and takes the first hit.
- **Health-aware skipping:** a relay that fails to connect/put/list is put into **exponential
  backoff** (5s → 5m cap) and skipped until it's due for a retry, so a dead relay never blocks
  the others; when it recovers it's picked up automatically.
- **Auto-pooling:** when a circle member advertises their relay (frame 19 / `RELAY_NODE`),
  peers **add** it to their set rather than replacing — so adopting one relay each gives the
  whole circle several, with no manual fan-out.
- **Layered delivery:** relays are one tier of the chain above — if every relay is down, direct
  P2P (online peers) and the BYO S3 bucket still carry traffic.

Adopt several relays (one hosted on your always-on box, one on a friend's, a community one) and
the circle keeps working through any single failure. The desktop client surfaces each relay's
reachability (● online / retrying) with add/remove in **Relay**; per-relay backoff is
unit-tested (`relayhealth.rs`).

### Relay mesh — self-replicating mailboxes (implemented)

On top of the client-driven redundancy above, relays now **replicate among themselves** so
**any relay holds the whole circle mailbox**, a relay can **join and pull the full set** from
peers, and one can **leave with zero loss** because others already have copies. Clients then
only need to reach *one* relay. This is naturally a **CRDT set-union**: blobs are
content-addressed and sealed, so replication is idempotent and conflict-free — no node ever
sees content, only that a key exists.

It's a small, well-shaped change on top of the existing `haven/blob/1` store, because a relay
is **already both** a `BlobServer` (serves clients) and able to be a `BlobClient` (dial another
relay). The pieces:

1. **Peer set.** Each relay learns its sibling relays for the circle. Two sources: the relay
   `Config`/link gains an optional `peers: [node_hex]`, and — since a client already knows every
   relay it adopted — the client advertises the set to each relay (reuse the `RELAY_NODE`
   channel). Relays can also gossip newly-learned peers transitively.
2. **Anti-entropy loop.** Every ~30s each relay, for each reachable peer: `BlobClient.connect`
   → `list("haven/")` → diff against its local store (`has`) → `get` + write the missing blobs
   (and optionally push its own). Bidirectional pull ⇒ eventual consistency; the existing
   per-relay backoff handles a peer that's down.
3. **Join/leave = free.** A new relay starts empty, runs one anti-entropy pass, and is now a
   full replica. A leaving relay needs no handoff — the set already lives on its peers.
4. **Surfaces (shipped):** `core/haven-net/blobstore.rs` — `BlobServer::sync_pull_from(peer)`
   over the existing put/get/has/list, with a pure unit-tested `keys_to_pull` (set-difference +
   namespace-confinement) and a `MAX_SYNC_PULL` cap; `core/haven-relay` — `config.peers`
   (repeatable `--peer <hex>` flag or `"peers"` in the JSON config) + a 30s anti-entropy loop on
   the local-disk backend; `RelayServerHandle::sync_from` so the **in-app** relay meshes too —
   the desktop engine auto-syncs its hosted relay from every adopted sibling (health-aware, so a
   down peer is skipped). Every official client can be a full mesh node, not just the CLI.

### Media scope — a sibling holds only the media of circles it serves (implemented)

Siblings are scoped per circle (a friend's relay that shares ONE circle with us replicates only that
circle's mailbox), but a media ref names no circle, so media used to replicate to every sibling.

1. **Marker, not a new layout.** Before uploading `haven/media/<ref>` to a relay, the uploader PUTs a
   content-free marker `haven/media/<ref>.c/<circle>` (same circle id the mailbox key carries). The
   blob keys are unchanged, so every reader, restore, history handoff and frame-32 relay-first hint
   works as before, and old clients/relays read, write and store both as ordinary media.
2. **Gate.** A marker is gated like its circle's mailbox: only a member may write it (a relay that
   doesn't serve the circle answers 403 — the uploader then skips that relay for this circle's media,
   no heal/backoff), and only the circle's members/siblings may list or read it.
3. **Mesh.** A LIST/AGES answer hides a ref whose markers name no circle the caller may see; the puller
   takes a scoped ref only if it serves one of its circles (markers read from the peer's inventory
   AND its own store, so an older sibling that lists everything can't fill it either), pulls markers
   first and writes the served ones before the blob. A reshared ref carries one marker per circle and
   replicates to each circle's relays.
4. **Legacy.** A ref with no marker (an old client's upload) replicates as before — refusing it would
   strand old clients' media; it stops as those clients update. Retention keeps a marker as long as
   its blob and prunes orphans (idle > 1h).

### Learning circles after the link — the ENROLL op (implemented)

A relay used to read its circle list **once**, from the link the operator pasted, and never change
it: `authorized 1 circle(s) from the link`, then `ERR forbidden` on everything else forever. Any
circle created afterwards was unservable, and `dm:` circles are *always* created afterwards — they
are minted the first time two people message. So DM conversations had **no store-and-forward at
all**: a message landed only if both devices were online simultaneously, reported as "received DMs
only show up on one of my devices". The only fix was re-pasting a link, which the Docker entrypoint
then reverted on the next container start (`HAVEN_RELAY_LINK` was re-applied every run and `--link`
persists).

The link is now a **pairing handshake**, not a policy. After it, the relay and its members talk both
ways: `ENROLL haven/enroll/<circle>` + a newline-joined member list widens the relay's authorization
at runtime. The rule (`RelayAuth::learn`, with the reasoning in comments):

1. **The caller must already be a member of some circle this relay serves.** This is the pairing —
   the operator's link is what established it. Anyone else is refused by `blob_forbidden` before the
   body is read, so an arbitrary node cannot enroll anything and a relay never becomes free storage
   for strangers.
2. **The caller must name ITSELF** among the members. Otherwise a trusted member could aim the relay
   at a circle of pure strangers and walk away. Self-inclusion keeps every learned circle anchored to
   a node the operator already serves.
3. **An existing circle may only be extended from the inside** — the caller must already be in *that*
   circle. Without this, a member of one circle could insert themselves into another (including an
   operator-granted one) and read its mailbox.

Learning is **additive** (union, never replace) and bounded (1024 circles, 1024 members/circle, 256
per request). Accepted grants persist to `<data-dir>/enrolled-circles.json` — deliberately *outside*
the `haven/` namespace so members can't read it and mesh sync can't replicate one relay's policy into
another's — and are re-merged **on top of** the link grants at every startup and reconfigure
(`rehydrate_learned_grants`), because `authorize()` replaces a circle's member set.

Compatible both directions: an older relay answers `ERR verb` and the client carries on with whatever
the link authorized (today's behaviour); an older client never sends ENROLL and is unaffected. On the
client side `put`/`list`/`touch` answer a policy refusal by enrolling themselves into that key's
circle and retrying once, at most once per circle per process. ENROLL is iroh-only: the HTTP twin has
a closed route set and cannot widen a relay's policy.

### Mailbox garbage collection — TOUCH + TTL + age-preserving sync (implemented)

Before deterministic event sealing (see [`GROUP-KEYING.md`](GROUP-KEYING.md)), every backfill
re-sealed history into fresh bytes, so mailboxes accumulated a copy of every event per run —
a real circle held **~6,700 entries for 88 events**. The persisted seen-set fixed cold-start
re-ingestion, but every 30s poll still `LIST`ed all keys (~700 KB per list from a remote
relay) and mesh sync circulated the dead entries forever. Entries are **opaque** to the relay
and live keys are never re-PUT (`has()` hits skip the write), so a naive mtime TTL would eat
live history; and a deletion on one relay would be resurrected by the next anti-entropy pass.
GC therefore has three cooperating parts (all in `core/haven-net/blobstore.rs`, served
identically over iroh `haven/blob/1` and the plain-HTTP interface):

1. **Client-declared liveness (`TOUCH` / `POST /t/<prefix>`).** Daily, each member re-seals
   what it can deterministically reproduce (its OWN events + current key commit + roster) and
   sends the refs in ONE batched TOUCH per relay. The relay bumps those entries' mtimes and
   replies with the keys it does NOT hold; the client re-PUTs the misses — the refresh doubles
   as repair (and self-heals a relay that GC'd a returning member's history). `HAS` hits
   refresh too. Own hosted relays are touched locally (no iroh self-dial).
2. **TTL sweep (`gc_sweep`).** Every relay host — CLI daemon, in-app RelayHost (iOS/Android/
   desktop), `BlobServer` — hourly deletes `haven/mailbox/**` entries idle > **30 days**
   (`MAILBOX_TTL`), plus abandoned `.part` files. Media and self-sync slots are NEVER swept.
   A `.haven-gc-enabled` marker delays the first deletion by **48h** after the store first
   runs GC-aware code, so every member gets a daily-refresh cycle to stamp live entries
   (pre-GC stores have ancient mtimes on live keys too).
3. **Age-preserving mesh sync (`AGES` verb).** Anti-entropy now reads `(key, idle-age)` pairs,
   **skips mailbox entries already past the TTL** (never resurrect what's dying elsewhere),
   and back-dates a pulled file's mtime by the peer's age — dead entries age monotonically
   mesh-wide instead of ping-ponging between siblings with fresh mtimes. Against a pre-GC
   peer that only speaks `LIST`, everything counts as fresh (old behavior, transitional).

Net effect: legacy duplicates, stale-epoch copies, and retention-expired events all stop
being touched and age out of every relay within one TTL; the 30s poll shrinks back to the
live set. Accepted tradeoff: an author inactive on ALL devices for > 30 days falls off the
relays until they return (their next refresh re-PUTs everything); members' devices remain
the source of truth — the relay is a mailbox, not an archive. Authorization: TOUCH follows
the PUT rules (circle members + sibling relays only, once membership is configured), broad
TOUCH/AGES prefixes are refused to non-relays, and a member can at most keep entries alive —
it can never delete (deletion is purely the relay's local TTL policy).

**Control-plane entries have their own retention (2.0.0).** Two kinds of mailbox key are not
posts: durable relay announces (`<circle>/__relay__/<relay>/<id>`) and HTTP live-lane call frames
(`<circle>/__live__/<dest>/<hash>`). Apple devices TOUCH every key they have ingested, these
included, so under rule 1 none of them ever expired: one NAS relay held 194k announces and 208k
call frames next to 65k posts, and a sibling whose copies stayed fresh mesh-fed back whatever its
TTL sweep deleted. Now (`ControlClass` / `sweep_control` in `blobstore.rs`):

- TOUCH and HAS report them held but never refresh their mtime — it stays their write time;
- call frames are deleted after **1 hour**, and the mesh replicates only frames under 2 minutes old;
- per `(circle, relay)` the newest **4** announces are kept regardless of age (past the 30-day TTL,
  so a relay announced once stays discoverable), plus any younger than **2 days**; the rest go;
- the mesh pulls only a sibling's newest 4 announces per `(circle, relay)`, so a sibling that still
  refreshes superseded ones cannot feed them back;
- apps from 2.0.0 also leave control keys out of their keep-alive TOUCH (`MailboxKeepAlive`), and
  the client splits a TOUCH into ≤ 256 KB requests (a big circle's single TOUCH used to be refused,
  so its posts were never refreshed on remote relays).

**Listings are served from a directory cache (2.0.0).** LIST, AGES and the mesh pass used to walk
the whole store with two or three `stat` calls per file on every request, on the async workers.
`dircache.rs` remembers each directory's entry names, revalidated by one `stat` of the directory
(its mtime moves on every create / rename / unlink in it; a directory changed in the last 2 s is
never cached, and nothing is trusted for longer than 5 minutes). LIST costs one `stat` per
directory; AGES still reads each file's mtime (TOUCH moves it without touching the directory).
All of it runs on `spawn_blocking`.

**Security note (review before relying on it in production):** replication never widens content exposure —
adopting a relay already hands it the full (sealed) mailbox, so a peer relay holding the same
ciphertext is no new disclosure. The review items are (a) **amplification/DoS** — cap peer
fan-out, rate-limit `list`/`get`, and bound store size per circle; (b) **poisoning** — a peer
can only add content-addressed blobs (a bad key simply never matches a real ref and is inert,
but still counts against quota → needs a cap); (c) **membership authz** — only relays a circle
actually adopted should mesh (gossiped peers must trace back to a `RELAY_NODE` advertisement
sealed to the circle, not arbitrary node ids). This touches the security-audited core shared by
iOS/Android, so it lands as a reviewed, cross-platform change — not a desktop-only tweak.

## Storage model

> **Updated per DECISIONS D15 (zero operator cost).** Media lives on a **Haven relay
> mailbox** or the user's **own S3-compatible bucket**; there is **no operator-funded
> bucket** and therefore **no quota system, blind tokens, or storage subscription**.
> A relay is the user's own or a *voluntary, community-run* node, never something the
> operator must fund.

1. **Haven relay mailbox (default).** Sealed blobs park on a **Haven relay's local
   disk** — the in-app relay any official client can host, or the standalone
   `haven-relay` daemon. The relay is run by the user or a community volunteer, so it
   is $0 to the operator. Any client can pull from a relay mailbox, so it works
   cross-platform.
2. **BYO bucket.** Any user can point Haven at their own **S3-compatible bucket** (AWS
   S3, Cloudflare R2, Backblaze B2, MinIO) — their storage, their cost. Also works for
   cross-platform offline delivery.

Blobs are E2E-encrypted and content-addressed (BLAKE3) before leaving the device, and
get a **lifecycle expiry** (auto-delete after N days) so nothing lingers.

**The broker (only for BYO-served buckets).** You can't hand arbitrary clients
raw bucket credentials, so a **thin, stateless broker** mints **scoped presigned
URLs** (PUT/GET for one content hash). It is small — but it is *the* component where
the no-log discipline must be absolute (see below). A Haven relay serves its own
mailbox directly, so the broker is only needed for the BYO-bucket path.

## IP privacy — what is and isn't guaranteed

**A relay or storage node transiently handles your IP — that is physically how bytes
reach you.** "No node ever sees your IP" is false for direct access and we will not
claim it. What we *do* guarantee, enforced by the deploy tool's default config:

- **Zero logging / zero persistence.** RAM-only operation, no access logs, no disk
  spill, provider-side request logging disabled where the provider allows it.
- **No linkage to a real-world identity — but the relay does see your node id.** Peers
  authenticate **to each other** end-to-end for *content*, and the relay never holds a
  content key. It does, however, authenticate the connecting peer by its iroh node id,
  which **is** that peer's Haven public key (`core/haven-net/src/blobstore.rs:537`): that
  check is what enforces circle-membership authorization (`blobstore.rs:687-709`) and
  self-sync slot ownership (`blobstore.rs:742-748`), and it's the reason a stranger who
  learns the relay id can't enumerate a circle's mailbox. So `IP ↔ node id` is available
  to the relay in memory while it moves your bytes; nothing persists it. What it cannot do
  is tie that key to a real-world you — there is no account, name, email or phone in the
  system to tie it to. Run your own relay, or a circle member's, if that link matters.
- **No operator-funded quota.** Storage is a Haven relay mailbox (the user's own or a
  volunteer's) or the user's own S3-compatible bucket, so there is no metered allotment
  to enforce (the earlier blind-signed quota-token model was deleted per D15).
- **Hiding your IP is your choice of path.** The only way a node genuinely cannot see your
  IP is to not connect to it directly. Run Haven behind your own VPN, or stand up a
  relay/discovery node you host yourself — both work today and keep direct P2P and calls
  intact. An opt-in onion/proxy (Tor) mode was evaluated and **declined**: Tor is TCP-only
  and can't carry iroh's QUIC/UDP data plane or WebRTC calls, and the only constructible
  variant is relay-only with no direct P2P and no calling (see `TOR.md`).

Summary of the honest promise: **never logged, never sold, never readable.** Not "never
seen" — a relay necessarily learns `IP ↔ node id` for as long as it is moving your bytes,
and nothing persists it.

## Self-updating relays — signed releases (implemented)

A standalone `haven-relay` keeps itself current from **GitHub Releases** — $0 infrastructure, no
update server. Operator docs: `relay/README.md` ▸ "Automatic updates"; code:
`core/haven-relay/src/update/`.

**Signing.** Release CI (`release.yml` `publish`, `relay-release.yml` `release`) builds the tiny
`haven-relay-sign` tool (`core/haven-relay-sign`, no net stack) and writes `<asset>.sig` next to
every `haven-relay-<target>[.exe]` asset. A `.sig` is text (`haven-relay-sig v1`, version, asset,
sha256, key id, sig); the Ed25519 signature covers
`"haven-relay/release-signature/v1\0" ‖ version ‖ 0 ‖ asset-name ‖ 0 ‖ sha256(file)`. The verifier
rebuilds that message from what IT expects (the version it chose, its own target's asset name, the
hash it computed), so cross-asset and version replays can't verify. The signature format module
(`update/sig.rs`) is compiled into both the signer and the relay.

- **Secret:** `RELAY_SIGNING_KEY` = base64 of the 32-byte Ed25519 seed. CI **fails closed**: no
  secret → the publish job errors before uploading anything; a key whose public half isn't in the
  relay's `TRUSTED_KEYS` is refused too; every `.sig` is re-verified before upload. Branch/PR
  builds never sign (they never publish).
- **Trusted keys** live in `core/haven-relay/src/update/sig.rs` (`TRUSTED_KEYS`, a list).
  Rotation: add the new public key, ship a release signed with the OLD key (every relay learns the
  new key through a trusted update), switch the secret, and drop the old key a release or two
  later. Keep an offline spare key in the list so a leaked key can be revoked without stranding
  relays.
- **Version:** CI stamps the FULL tag version (incl. `-rc.N`) into the binary via
  `HAVEN_RELAY_BUILD_VERSION`; `haven-relay version` reports it and the signature binds it.

**Channels.** `stable` = newest non-prerelease release (`vX.Y.Z`, `relay-vX.Y.Z`); `rc` = newest
including prereleases (`vX.Y.Z-rc.N`). Semver ordering with `rc.N < final`; never a downgrade; a
version that failed after install is recorded in `<data>/update/state.json` and never re-offered.

**Install + rollback.** Docker: into the data volume, run by the entrypoint supervisor (which
restarts on exit code 75 and has its own crash-loop rollback). systemd/launchd/cron-loop: atomic
in-place `rename`, previous kept as `.prev`, exit 75 → service manager restarts. apt-owned
`/usr/bin`, Windows tasks, hand-started relays: notify only. A fresh binary is on probation: it
must write a healthy `<data>/health.json` (HTTP answers, iroh endpoint bound, store readable)
within `HAVEN_RELAY_UPDATE_HEALTH_SECS` (180 s) and survive ≤ 3 starts, else it restores `.prev`
and marks itself bad. Node identity and store are never touched.

**Privacy.** Anonymous GETs of public GitHub data only — no node id, no telemetry, fixed
User-Agent; the updater logs only version events (the no-logs rule is unchanged).

**Self-maintenance.** Disk guard (`--min-free`, default 1 GiB): below the floor, HTTP PUTs get
`507` and iroh PUTs `ERR insufficient storage` (small ≤ 64 KiB writes still accepted until ¼ of the
floor), mesh pulls pause; GC keeps running and service resumes when space frees. The hourly GC
also reaps stale `.part` temps store-wide. HTTP interface memory is bounded (1024 connections,
1 GiB of buffered bodies).

## The deployment tool (`haven-relay`)

Goal: anyone can stand up a compliant relay on any major cloud in one command, with
privacy-hardened defaults they can't accidentally turn off.

- **Artifact:** the relay is a single **static Rust binary** + a container image,
  no runtime dependencies.
- **IaC:** **OpenTofu** (open-source Terraform) modules, one per provider:
  **AWS, GCP, Azure, Hetzner, Fly.io, DigitalOcean, Cloudflare R2, Oracle (free
  tier), bare VPS/Docker.**
- **CLI:**
  ```sh
  haven-relay deploy --provider hetzner --role both       # connection + storage
  haven-relay deploy --provider cloudflare-r2 --role storage   # bucket + broker only
  haven-relay deploy --provider oracle --role connection       # free-tier TURN/DERP
  ```
  Each run: provisions the box and/or bucket, gets auto-TLS, applies the
  **hardened no-log config by default**, sets blob lifecycle expiry, and
  **self-registers to discovery** so clients can find and rank it.
- **Storage-only needs no compute** — a Tofu module that provisions just a bucket +
  scoped creds + auto-expiry + the broker. The cheapest possible relay.
- **Defaults are the product.** No-logging and RAM-only operation are *on by default and
  hard to disable*, so a casual operator can't accidentally run a surveilling relay. (What
  they are *not* is blind to node ids — the membership check needs them; see the IP-privacy
  section above.)

## Status

**Implemented:** the relay itself ships in two forms — an **in-app RelayHost** (FFI,
runs in-process; the Mac runs it as an *invisible background relay* via accessory
activation policy) and a **standalone `haven-relay` daemon** (single static Rust binary;
`relay/` packages it for macOS launchd, Linux systemd, and Docker; it **self-updates from
signed GitHub releases** with health-checked rollback). It serves both roles
(connection relay + media store-and-forward) over Haven Net with no public host. The
storage mailbox also supports a **pre-signed-URL** model (`PresignStore`) so members never
hold bucket credentials.

**Still design-only:** the multi-cloud OpenTofu deploy modules (`haven-relay deploy
--provider …`) and self-registration to discovery.
