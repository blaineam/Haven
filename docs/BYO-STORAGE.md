# Bring-your-own storage (Haven relay or your own S3), no secrets you host

Users can keep their media on **their own** storage — and you (the maker) never host
an API key or client secret for any of it. This is core to the "clean hands" rule:
nothing you hold can be used to bypass a user's storage.

## Options (Settings → Storage)

The only two media-storage backends are a **Haven relay mailbox** and the user's **own
S3-compatible bucket**:

| Option | How | What you host |
|---|---|---|
| **Haven relay mailbox** (default) | sealed blobs park on a Haven relay's local disk — the in-app relay any official client can host, or the standalone `haven-relay` daemon | nothing (relay is user/community-run) |
| **Custom S3 bucket** | user enters endpoint + region + bucket + access key + secret; stored only in the device **Keychain** | nothing |

The S3 path works with **AWS S3, Cloudflare R2, Backblaze B2, MinIO**, rclone serve s3,
etc.

## Media transport order (relay HTTP first, then S3, iroh blob last)

Media transfers (upload mirror + fetch) try transports in this order, per relay, on
every platform (iOS/macOS, Android, desktop):

1. **The relay's own plain-HTTP interface** — the zero-config **default**. A relay host
   (in-app or the `haven-relay` daemon) serves its sealed blob store over HTTP/1.1
   (`/k/<key>`, bearer-token gated); plain HTTP traverses any NAT the moment the host is
   reachable. Members learn the relay's URLs + token from the *sealed* frame-19 announce.
2. **A user-configured S3/HTTP bucket** — the opt-in BYO-storage option (rare). Still
   plain HTTPS, so it also traverses any NAT.
3. **The iroh blob ALPN (`haven/blob/1`)** — an opportunistic fast-path (own hosted
   relay's local store, LAN peers) and the only path when nothing above is configured.

Rationale: the iroh blob ALPN currently drops its outbound datagrams over a pure-relay
cross-NAT path (noq/iroh fork bug — see `reference_haven_multipath_drop`), stalling
~30 s per attempt even though *messaging* works over the same DERP path. The HTTP paths
sidestep it entirely. A reachable HTTP relay that answers 404 for a key is a real MISS
(the iroh path serves the same store), so we don't waste a doomed dial on it.
Events/mailbox polling are unchanged.

The relay HTTP interface is **on by default**. Blobs are E2E-sealed before they touch
the wire, so the interface only ever moves ciphertext; expose it to the internet behind
TLS (reverse proxy / tunnel) and pass the public URL to the daemon with `--http-url`
(the LAN address is advertised automatically for same-network members). Free Cloudflare
setup (quick tunnel, own domain, or a shared `*.net.haven…` namespace design) is in
[`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md).

- Media is **end-to-end encrypted before it is stored** anywhere — the storage
  backend (a Haven relay or the user's own bucket) only ever holds ciphertext.
- S3 keys live **only in the device Keychain**
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never synced to you.
- You cannot read, enumerate, or revoke a user's storage — you hold no credentials.

## Status

- ✅ Storage settings UI; **functional Custom S3 config** (saved to Keychain);
  backend selection.
- ✅ **Working S3 path**: a real SigV4 `S3Client` does encrypted-blob put/get/list against
  a BYO bucket; the per-circle mailbox uses **pre-signed URLs** (`PresignStore`) so members
  never hold the bucket credentials. Circle-sealed media is stored + re-served peer-to-peer.
- ✅ **Haven relay mailbox**: sealed blobs park on the relay's local disk (in-app
  `RelayHost` or the standalone `haven-relay` daemon) and are pulled by other members.
