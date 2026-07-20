# #44 — Routing the relay over Haven Net (no public host)

Today a circle's shared store is an **S3 endpoint** (`rclone serve s3`, or a BYO S3
bucket). That works, but the volunteer model has a wart: `rclone serve s3` has to be
**reachable** — a public IP, a domain, a tunnel, or a paid bucket. That's a public-ish
host, which cuts against "no servers, nothing to find." #44 removes that requirement by
carrying the **same S3 traffic inside Haven Net** (iroh QUIC), so the volunteer's store is
reachable *only* over the authenticated P2P overlay — never on the open internet.

## The key realization

We already have an authenticated, encrypted, NAT-traversing transport between members:
**iroh**. A circle member who volunteers their storage doesn't need to expose anything
publicly — they just need other members to reach their *local* store **through the tunnel
they already have**. So the volunteer binds the store to `127.0.0.1` and we proxy.

## Design A — S3-over-iroh tunnel (keep S3, hide the host) ✅ recommended first

Smallest change; reuses the entire existing `S3Client` untouched.

```
 consumer device                              volunteer device
 ┌──────────────┐   iroh QUIC   ┌───────────────────────────────┐
 │ S3Client  ───┼──► local  ───►│ iroh accept (ALPN "haven/s3") │
 │ (SigV4 HTTP) │   127.0.0.1   │   └─► 127.0.0.1:<rclone s3>    │
 └──────────────┘   :PORT       └───────────────────────────────┘
```

- **Volunteer side (`haven-net`):** accept iroh connections on ALPN `haven/s3/1`. For each
  inbound bi-stream, open a TCP socket to the local `rclone serve s3` (`127.0.0.1:port`)
  and splice bytes both ways. Pure byte-pump — rclone never knows it's not a normal client.
- **Consumer side (`haven-net`):** run a tiny **loopback listener** on `127.0.0.1:<ephemeral>`.
  Each accepted connection opens an iroh bi-stream to the volunteer node (by `NodeId`) and
  splices. The app points `S3Client.endpoint` at `http://127.0.0.1:<ephemeral>`.
- **App side:** when the circle's storage is "via Haven Net," `mailboxClient()` returns an
  `S3Client` whose endpoint is the local loopback. **Zero changes** to SigV4, put/get/list,
  mailbox poll, or BYO-storage — they all just see a local endpoint.
- **Creds distribution:** unchanged. The `BucketConfig` frame (type 14) already ships the
  sealed S3 creds to the circle; we add the volunteer's `NodeId` + "reach me over iroh"
  flag to it. No endpoint URL needed — the NodeId *is* the address.

Pros: tiny, reuses S3Client + rclone + mailbox as-is, works for web too (see below).
Cons: still speaks S3 inside the tunnel (a little overhead); the volunteer must be online
to serve (already true today).

## Design B — native mailbox-over-iroh (drop S3 on the wire) — later

Skip the S3 protocol entirely. Define a request/response on ALPN `haven/mbx/1`:
`PUT(circle, hash, env)`, `GET(circle, hash)`, `LIST(circle)`. The volunteer stores
envelopes in *any* local KV (a directory, sled, even the same bucket) and answers directly.

Pros: no SigV4, no rclone dependency, smallest wire format, easiest to reason about for the
threat model. Cons: new code path replacing the mature S3 one; do it once Design A proves
the tunnel.

> **Shipped** as `core/haven-net/blobstore.rs` on ALPN `haven/blob/1` (verbs: PUT / GET /
> HAS / LIST, plus TOUCH + AGES for mailbox garbage collection, and ENROLL so a paired member
> can teach the relay a circle its link never mentioned — see the module docs and
> [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) "Mailbox garbage collection" / "Learning circles
> after the link"), with a plain-HTTP twin of the same store for the cross-NAT media path.

Both designs preserve the security model: envelopes are **already circle-sealed**, so the
volunteer (and the tunnel) only ever moves opaque bytes.

## ~~Where the web client fits~~ (obsolete — web client abandoned)

> **Obsolete (2026-06-22).** The web client was dropped (a browser can't be an iroh peer;
> see [`WEB-PARITY.md`](WEB-PARITY.md)), so the browser-transport tiers below no longer
> apply. The tunnel work is purely for **native** peers. Native Android (a real iroh peer)
> gets the `haven/mbx/1` request/response directly — no WebSocket-relay bridge needed.

## Build steps

1. `haven-net`: add the **splice proxy** (Design A) — `serve_s3_over_iroh(local_addr)` on the
   volunteer, `tunnel_to(node_id) -> local_loopback_addr` on the consumer. (~byte-pump, no
   protocol.)
2. Extend `BucketConfig` (frame 14) with `volunteer_node_id` + `via_haven_net: bool`.
3. App: `SharedStore.mailboxClient()` returns a loopback-pointed `S3Client` when `via_haven_net`.
4. Prove iPhone ↔ iPhone mailbox sync with the volunteer's rclone bound to `127.0.0.1` and
   **no inbound ports / no domain**.
5. Later: Design B (`haven/mbx/1`) + the web WebSocket-relay client → true no-host web sync.

## Cost: iroh is free — don't pay n0

The **iroh library is open source (Apache-2.0/MIT)** and compiled into the app — Haven pays
**nothing** to use it. The pricing at iroh.computer is for *optional hosted services*, not
the library:

- **Free, what we use:** the crate itself + **n0's public relay/discovery servers**
  (best-effort, free). Relays only engage when two devices can't connect directly, and they
  forward **encrypted bytes only** — never plaintext, just a NAT-traversal switchboard.
- **Paid (we do NOT need):** dedicated relay server **$199/mo**, Pro monitoring **$19/mo**,
  per-connection/metrics overages. These are for running iroh as a *monitored production
  service at scale* — irrelevant to an embedded P2P app.

If we ever want relay reliability **without** leaning on n0's free public tier (the one
third party that sees encrypted traffic + connection metadata in the fallback path), the
answer is **self-host an iroh relay, not pay n0**:

- The **relay server is also open source** — run `iroh-relay` on a ~$5/mo VPS (or the
  volunteer's always-on box) and point the app's relay config at it. Free software.
- This composes with everything above: a circle's volunteer can run *both* the localhost S3
  store **and** a private iroh relay, so the whole circle's transport — discovery, NAT
  traversal, and the mailbox tunnel — stays on infrastructure **the circle controls**, with
  no n0 and no public content host.

Net: today Haven costs **$0** (free crate + free public relays). The only reason to spend is
a self-hosted relay for *zero-third-party* purity, and that's a cheap VPS, not an iroh plan.

## Net effect

After step 4, a circle can run its shared store on someone's phone or laptop with the store
bound to localhost and **nothing exposed publicly** — reachable only by circle members who
already hold the sealed creds and the volunteer's NodeId. The "volunteer as tribute" model
finally needs *zero* public infrastructure.
