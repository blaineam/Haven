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

## The link is a one-time pairing, not a standing configuration

`HAVEN_RELAY_LINK` is applied **only on the first run**, while no link is saved in `/data` yet. On
every later start the entrypoint ignores it and says so in the log.

That is a deliberate change. `--link` persists, so re-applying the env value on every start silently
overwrote the relay's saved link — a user who re-linked their relay by hand, verified it worked, and
then restarted the container for an unrelated reason was quietly reverted to the stale link in
`.env`, with nothing in the log to explain it.

It is also no longer something you need to keep current: **a relay learns circles from the members
it is already paired with.** A circle created after you pasted the link — above all a new DM, which
is created the first time two people message — is registered by the member's own app the first time
it uses that relay, and the grant is saved in `/data` so it survives restarts. You do not re-paste a
link to add a circle.

To deliberately re-link (say, pairing this box with a different account):

```sh
HAVEN_RELAY_LINK_FORCE=1 docker compose up -d   # one start, overwrites the saved link
# or
docker compose exec haven-relay rm /data/link.json && docker compose up -d
```

The startup log shows what the relay is serving:

```
  circles    : 1
  learned 3 additional circle(s) from paired members:
    · dm:1a2b3c4d-5e6f7a8b (2 members)
    …
  serving 4 circle(s): 1 from the link + 3 learned.
```

> **Relays built before this change** cannot learn: they authorize only what their link granted, at
> startup, forever. (`haven-relay version` ≤ 1.1.4, or a startup log that says
> `authorized N circle(s) from the link` with no `serving …` line after it.) On such a relay every circle created after the link was pasted answers `ERR forbidden` —
> including every DM circle, which is why DMs had no store-and-forward and only arrived when both
> devices happened to be online at once. Rebuild to fix it.

## Public media URL / cloudflared (shipped in the image)

**Media cannot cross NAT without a reachable public URL.** Messaging may still work over iroh;
media needs the plain-HTTP interface on `:8674` (or the path proxy) advertised as something peers
can open from the internet.

The Docker image **ships official `cloudflared`**. Behaviour:

| Env | What happens |
|---|---|
| *(default — both unset)* | Free Cloudflare Quick Tunnel (`*.trycloudflare.com`). Auto-starts. Hostname **changes on restart**; apps re-learn via frame 19. |
| `HAVEN_RELAY_HTTP_URL=https://…` + `HAVEN_RELAY_TUNNEL_TOKEN=…` | Named Cloudflare tunnel (stable domain). Zero Trust origin → `http://127.0.0.1:8674` (or `:8675` path proxy). |
| `HAVEN_RELAY_HTTP_URL=https://…` only | You run the tunnel/proxy yourself; relay only **announces** the URL. |
| `HAVEN_RELAY_NO_TUNNEL=1` | No cloudflared. LAN / port-forward only. |

```sh
# .env — free auto tunnel (default): leave HTTP_URL unset

# .env — stable custom domain (recommended for always-on NAS):
# HAVEN_RELAY_HTTP_URL=https://relay.example.com
# HAVEN_RELAY_TUNNEL_TOKEN=<install token from Cloudflare Zero Trust>

# .env — LAN only:
# HAVEN_RELAY_NO_TUNNEL=1
# HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674
```

On a healthy free-tunnel start you should see:

```text
▸ cloudflared: /usr/local/bin/cloudflared (…)
✓ cloudflare quick tunnel: https://….trycloudflare.com
  public URL : https://….trycloudflare.com
```

If you only see `reachable at http://<this-host>:8674` with no `public URL`, the tunnel did not
start — check `/data/logs` inside the container and rebuild so the image includes cloudflared.

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

## Haven fabric (DERP + TURN) — n0 / Google only as fallback

Full walkthrough: **[`docs/NAS-FABRIC-RELAY.md`](../../docs/NAS-FABRIC-RELAY.md)**.

| Port | Role |
|---|---|
| TCP **8674** | Media mailbox (HTTPS via your proxy) |
| TCP **3340** | iroh DERP fabric |
| UDP **3478** | WebRTC TURN (not via free trycloudflare) |

In `.env` set `HAVEN_RELAY_HTTP_URL`, `HAVEN_RELAY_DERP_URL`, `HAVEN_RELAY_TURN_URL`,
`HAVEN_RELAY_TURN_PUBLIC_IP`, then paste **`/data/interface.json`** (not only the node id) into
the app. Until a release ships fabric, build with
`HAVEN_RELAY_SOURCE=1` and `HAVEN_RELAY_REF=feature/iroh-relay-gossip`.

## Notes

- **Ports:** `8674` media, `3340` DERP, `3478/udp` TURN. Messaging can still fall back to n0 if
  DERP is not public; fabric is the path that makes **your** box primary.
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
