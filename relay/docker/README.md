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

## If members reach this relay over the internet, set `HAVEN_RELAY_HTTP_URL`

**Media cannot cross NAT without it.** The plain-HTTP interface is not an optimisation — it is the
only working media transport between networks. The iroh blob path drops its datagrams over a
pure-relay cross-NAT route, so a blob dial that must cross a NAT stalls ~30s and dies, *while
messaging keeps working*. That asymmetry is exactly what the failure looks like from outside: posts
and messages arrive normally, media never does, and the log says only `relay put timed out`.

The relay advertises this interface by enumerating its own addresses — under Docker that is the
container's `172.x.y.z`, which nobody can reach, and a LAN address is no better for a remote member.
Set it to the address members actually use:

```sh
# .env next to docker-compose.yml
HAVEN_RELAY_HTTP_URL=https://relay.example.com     # reverse proxy / tunnel — preferred
# HAVEN_RELAY_HTTP_URL=http://203.0.113.10:8674    # or port-forward 8674 to this box
# HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674    # LAN-only relay, no remote members
```

then `docker compose up -d`. Within a minute the members' logs should show `http-put OK` instead of
`relay put timed out`.

Everything served is already end-to-end sealed, so plain HTTP carries ciphertext only — but if you
have a reverse proxy, TLS is the tidier answer. `network_mode: host` fixes only the
container-address half; a remote member still needs a publicly reachable URL.

## Building from source (test a relay fix without cutting a release)

Source mode fetches the repo at a branch, tag or commit and builds the relay inside the image — so a
fix can be tried on the box that actually has the problem. It downloads the source itself, so
**nothing but this folder needs to be on the NAS**:

```sh
# .env next to docker-compose.yml
HAVEN_RELAY_SOURCE=1
HAVEN_RELAY_REF=main        # or a tag, or a commit sha

docker compose build --no-cache && docker compose up -d
docker compose exec haven-relay haven-relay version
```

or without touching `.env`:

```sh
docker compose build --build-arg HAVEN_RELAY_SOURCE=1 --build-arg HAVEN_RELAY_REF=main
docker compose up -d
```

The binary is statically linked against musl exactly like the released one. Note that
`haven-relay version` reports the crate version it was built from, so a source build of an
unreleased `main` still shows the last version bump — trust the ref you passed, not just the number.

> **This is a real Rust build.** The relay pulls in iroh and the whole networking stack: minutes on a
> fast machine, considerably longer on a NAS CPU, and it wants a couple of GB of RAM. If your NAS is
> short on either, build the image on a desktop and `docker save` / `docker load` it across. Set
> `HAVEN_RELAY_SOURCE=0` to go back to the plain release download, which needs no toolchain at all.

## Updating

There is no published image to `docker compose pull` — the image is built locally from a release
binary, so an update means **rebuilding**:

```sh
docker compose build --no-cache      # re-fetches the newest haven-relay release
docker compose up -d
docker compose exec haven-relay haven-relay version
```

Your relay keeps its identity, circle link and sealed store (they live in the volume), so the node
id is unchanged and nobody has to re-adopt it.

> **If you set this up before, check your version.** The Dockerfile used to default to
> `v0.1.0-beta.23`, so a NAS built from the old instructions is running a pre-1.0 relay and will
> keep running it forever — a relay is invisible while it works, so nothing ever asks you to
> rebuild. That matters: a relay older than 1.1.2 authorizes only the ONE circle its link granted,
> so if you made it the default relay for every circle it serves one and refuses the rest, which
> looks exactly like "my media isn't on any relay".

> **Pin the node id (recommended).** If the `/data` volume is ever lost or the container is recreated
> without it, the relay generates a brand-new node id and your circle has to re-adopt it. To make the
> id permanent regardless of the volume, set a fixed seed: run `openssl rand -hex 32` once and put
> `HAVEN_RELAY_SEED=<that 64-hex value>` in the `.env` next to the compose file. `HAVEN_RELAY_SEED`
> takes precedence over `/data/identity.json`, so the same node id survives restarts, image rebuilds,
> and even a wiped volume. Keep the seed secret — it *is* the relay's identity.

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
