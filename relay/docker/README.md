# Haven relay in Docker (NAS / home server)

Run an always-on Haven relay for your circle in a container — it holds your circle's **sealed**
messages/media for friends who are offline and hands them over later. It only ever moves
ciphertext; it can't read a thing.

## Quick start

Setting up a relay is a two-step handshake: you give the relay your circle's **link** (which members
to forward toward), and you give the app the relay's **node id** (where to reach it). Both live in
the same place in the app.

1. Copy this folder (`Dockerfile`, `entrypoint.sh`, `docker-compose.yml`) to your NAS.

2. **In the Haven app, get your circle's relay link.** Go to
   **Settings ▸ Storage ▸ Advanced → "Connect an external relay"** and tap
   **"Copy this circle's relay link."** (On the Mac/desktop app it's the same
   *Advanced storage* screen.) It's a `haven-relay://circle#…` link.
   > Not the **Relays ▸ Add relay** sheet — that one is for step 5, pasting the node id *back*.

3. Put the link in a `.env` file next to `docker-compose.yml`:
   ```
   HAVEN_RELAY_LINK=haven-relay://circle#…
   ```

4. Build and start:
   ```sh
   docker compose up -d --build
   ```

5. **Grab the relay's node id and give it to the app.** Print it:
   ```sh
   docker compose exec haven-relay haven-relay id      # 64-hex node id
   docker compose logs -f                               # also shows it + the QR at startup
   ```
   Back in the app on that same *Connect an external relay* screen, **paste the node id** into
   *"Paste the daemon's node id"* and tap Connect. (Or use **Relays ▸ Add relay ▸ Haven relay** and
   paste it there.) Your whole circle now adopts this relay.

Every later start is just `docker compose up -d` — the link and identity live in the
`haven-relay-data` volume, so the container stays the **same** relay across restarts and updates.
Don't delete that volume unless you want a brand-new relay identity.

## Notes

- **Ports:** `8674` is the plain-HTTP media interface — the fast path peers use to pull media when
  they can reach this box (same LAN, or via a port-forward/reverse-proxy you set up). The relay
  also works with **no** inbound port at all: it dials out over Haven Net (iroh/QUIC + DERP) and is
  reachable through that even behind NAT.
- **Storage location:** to store the sealed-blob mailbox on a specific NAS share instead of a Docker
  volume, swap the volume line in `docker-compose.yml` for a bind mount, e.g.
  `- /volume1/docker/haven-relay:/data`.
- **Version:** the image pins a known-good relay build by default. Track the newest release by
  building with `--build-arg HAVEN_RELAY_VERSION=latest` (or set it under `build.args` in the
  compose file).
- **Architectures:** the image auto-selects the right static binary for `amd64`, `arm64`, or `arm`
  (armv7) from `TARGETARCH` — covering Intel/AMD NAS boxes, Apple-silicon-class ARM NAS, and
  Raspberry Pi.
- **Public URL (optional):** if you expose the HTTP interface behind a domain/reverse proxy, tell
  members the URL by appending `--http-url https://relay.example.com` — add it to the compose
  service as `command: ["--http-url", "https://relay.example.com"]` (extra args pass through to
  `haven-relay run`).

## What it can and can't see

The relay stores and forwards **sealed** frames and blobs. It never holds a key that can decrypt
your circle's content — a property covered by a test in the codebase where a relay stores a sealed
blob and is shown to be unable to open it. No logs are written.
