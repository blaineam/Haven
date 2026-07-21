# Cloudflare Tunnel for the Haven relay HTTP interface

The in-app / `haven-relay` mailbox serves sealed media over plain HTTP on port **8674**.
That path is the reliable cross-NAT media transport (see [`BYO-STORAGE.md`](BYO-STORAGE.md)).
On a home connection it is usually only reachable on the LAN — friends off your network
time out unless you either:

1. port-forward / put the box on a public IP, or
2. run a **tunnel** that gives the HTTP interface a public HTTPS hostname.

This doc is the free Cloudflare path: no VPS of yours, no port-forward, optional domain.

> **What is and is not "your infrastructure"**
>
> - **Data path (media bytes):** peer → Cloudflare's edge → the volunteer's `cloudflared`
>   process → `localhost:8674`. Bytes never hit a Haven server you run. Blobs are
>   **already E2E-sealed** before they leave the app, so Cloudflare only ever moves
>   ciphertext + sees connection metadata (who dialed which hostname, sizes, timing).
> - **Control path (DNS names):** whoever owns the DNS zone can create/delete hostnames.
>   If that zone is `haven.wemiller.com`, that control plane is *yours* even when the
>   data path is not. That distinction matters for the shared-subdomain design below.

---

## What Haven needs at the end

One stable (or semi-stable) HTTPS base URL pasted into:

- **In-app relay:** Storage / circle relay → **Public relay URL**
  (`UserDefaults` key `haven.relay.publicURL`), or
- **Daemon:** `haven-relay run --http-url https://…`

Haven re-announces that URL to the circle (frame 19). Peers try it first for media.
No other Haven server is involved.

---

## Scope: Cloudflare is not a full iroh replacement

Saved for later product/architecture decisions (2026-07).

Cloudflare Tunnel only fronts the relay **plain-HTTP mailbox** on port **8674**:

```text
peer  →  Cloudflare edge  →  cloudflared  →  localhost:8674
```

That is the reliable **cross-NAT sealed-media / store-and-forward** path. It is **not**
a substitute for the whole Haven transport stack.

| Capability | Covered by CF HTTP tunnel? | Who does it today |
|---|---|---|
| Cross-NAT **media mailbox** (sealed GET/PUT) | **Yes** — primary purpose | HTTP `:8674` + tunnel / Manual front door |
| Live DMs / posts / reactions as **direct peer frames** | No | iroh QUIC |
| Peer discovery (node id → address) | No | iroh / n0 DNS / later gossip |
| Hole-punch / DERP-style NAT for live links | No | iroh relays |
| `haven/blob/1` over the P2P overlay | No | iroh |
| S3-over-iroh tunnel | No | iroh |
| Nearby mesh (Multipeer / Bluetooth) | No | local only (independent of both) |

`haven-relay` is dual-faced: **iroh overlay + HTTP mailbox**. Cloudflare (or Manual)
only makes the HTTP face publicly reachable.

### Failure modes (honest limits)

1. **n0 / public iroh flaky** — CF still helps **media** (HTTP can skip iroh). Live
   peer frames may still struggle until discovery/self-hosted iroh relays improve
   (see [`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md)).
2. **Cloudflare blocks free/token tunnels** — **Manual** front door still works
   (same HTTP mailbox, your nginx/Caddy/Tailscale/etc.).
3. **“Turn iroh off forever”** — would be a **different architecture** (everything
   store-and-forward over HTTPS to relays). Haven is not built that way; CF was
   added so media does **not** lean hard on iroh, not so iroh can be deleted.

**Bottom line:** CF can carry sealed-media mailbox traffic even when direct iroh media
is bad. It cannot alone cover every feature that currently rides iroh.

### Later: embed open-source iroh-relay *behind* the same tunnel

iroh is open source (Apache-2.0/MIT). The **peer** path is UDP/QUIC; the **relay** path
(iroh-relay / DERP-style) is **HTTPS + WebSocket** — the same kind of TCP-friendly
service cloudflared already fronts. So a Haven volunteer box can, in principle, host
three roles on one machine and one public front door:

```text
peer A ──QUIC direct──► peer B          (still preferred when it works)
   │                         ▲
   └──HTTPS/WSS──► cloudflared ──► localhost iroh-relay ──► (relayed bytes) ──┘
                         │
                         └── also :8674 HTTP mailbox (what CF does *today*)
```

| Role | Today | With embedded iroh-relay |
|---|---|---|
| Blob / HTTP mailbox (`:8674`) | CF / Manual front door | unchanged |
| App mesh switchboard (`HVR1`) | Haven already | unchanged |
| iroh DERP (NAT fallback for live frames) | n0 public relays | **circle-hosted** via custom `RelayMap` |

**Client side** (on `feature/iroh-relay-gossip`): when frame 19 carries a `derp` URL (or the
operator pastes `haven-relay`'s interface JSON), clients call `apply_derp_urls` and build
`RelayMode::Custom` — **n0 is disabled** for that process until no Haven DERP remains.
WebRTC likewise drops Google STUN when fabric is active. See [`IROH-RELAY-GOSSIP.md`](IROH-RELAY-GOSSIP.md).

**Why this works with Cloudflare (and what it still is not)**

- **Works:** iroh-relay is reverse-proxy friendly; CF/Manual terminate TLS and forward to
  localhost. Bytes stay E2E-encrypted; the edge still only sees ciphertext + metadata.
- **Works:** surviving **n0 DERP outage** for circles that run ≥1 reachable Haven
  iroh-relay — live-frame fallback no longer hard-depends on n0.
- **Does not:** replace **direct QUIC** (UDP hole-punch still preferred when possible;
  CF does not carry peer UDP through the tunnel).
- **Does not:** solve **discovery** (node id → address). That stays n0 DNS/pkarr until
  Haven gossip / self-hosted discovery lands (see [`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md) §4).
- **Does not:** mean “delete iroh.” It means **self-host the open-source relay role**
  so media *and* live fallback can ride circle infrastructure.

**Practical constraints**

1. **Stable hostname** — `*.trycloudflare.com` dies on restart; bad as a `RelayMap`
   entry. Named tunnel or **Manual** domain is the real product path for DERP.
2. **Bootstrap** — peers must learn the circle’s iroh-relay URL(s) (announce, signed
   list, enroll ticket, …). n0 is hardcoded today; custom map needs a bootstrap story
   ([`RESILIENCE-DESIGN.md`](RESILIENCE-DESIGN.md) §3.2).
3. **Long-lived WebSockets** — soak-test CF free edge idle timeouts / rate limits.
4. **Implemented on `feature/iroh-relay-gossip`** — R0/R1/R2: `haven_endpoint_builder()`,
   embedded `iroh-relay` in CLI `haven-relay` (`--derp`), frame-19 `derp` gossip, client
   Haven-first map + WebRTC policy. Scar guard: DERP is a **server socket other nodes
   connect to**, not a second iroh *endpoint under the relay’s node key*.
5. **Scale** — fine for a family/circle home host; not a global free tier for strangers.

| Goal | CF media tunnel only (shipped) | CF + embedded iroh-relay (planned) |
|---|---|---|
| Cross-NAT **media** mailbox | Yes | Yes |
| Cross-NAT **live frames** when direct fails | Relies on n0 (or fails) | Can ride **your** iroh-relay |
| Survive n0 DERP outage | Partial (HTTP media) | Much better for live P2P fallback |
| “Turn iroh off forever” | No | Still no — still iroh, self-hosted relay |

**Bottom line (extension):** Yes — embed open-source iroh-relay behind the same
cloudflared/Manual front door. That is how CF grows from “media mailbox only” toward
“circle-hosted NAT fallback,” without pretending Cloudflare replaces iroh.

---

## Path A — Zero account: Quick Tunnel (fastest try)

Good for: "prove media works for a friend tonight." Bad for: always-on, because the
hostname **changes every time** `cloudflared` restarts.

### 1. Install `cloudflared`

```sh
# macOS
brew install cloudflared

# Linux (Debian/Ubuntu) — or grab the latest .deb from Cloudflare's GitHub releases
# https://github.com/cloudflare/cloudflared/releases
```

### 2. Point it at the local relay HTTP port

With Haven's in-app relay **on** (or `haven-relay` listening on 8674):

```sh
cloudflared tunnel --url http://127.0.0.1:8674
```

After a few seconds the log prints something like:

```text
https://random-words-here.trycloudflare.com
```

### 3. Paste into Haven

**Public relay URL** = that `https://…trycloudflare.com` string (no trailing slash).

Friends on other networks can now fetch sealed media over HTTPS. When you stop the
process or reboot, run it again and **update** the public URL — old trycloudflare
names die with the process.

### App-side "almost automatic" later

A future "Start free tunnel" button would:

1. ensure `cloudflared` is installed (or ship/download a helper),
2. spawn `tunnel --url http://127.0.0.1:8674`,
3. scrape the printed `https://*.trycloudflare.com` URL,
4. write `haven.relay.publicURL` and re-announce.

No Cloudflare account, no domain, no Haven backend. Tradeoff: ephemeral hostname.

---

## Path B — Own Cloudflare account + domain (stable, free, recommended)

Good for: a Mac / NAS / Pi you leave on as the circle's mailbox. Free on Cloudflare's
tunnel + DNS free tier for a domain you already own (or a cheap one you buy).

### 1. Cloudflare account

1. Create an account at [dash.cloudflare.com](https://dash.cloudflare.com).
2. **Add your domain** (or use one already on Cloudflare).
3. If it's new, set the domain's nameservers to the two Cloudflare assigns, wait until
   the zone is **Active**.

You do **not** need Cloudflare Workers, R2, or a paid plan for this.

### 2. Install and log in `cloudflared` on the relay machine

```sh
brew install cloudflared          # or Linux package
cloudflared tunnel login          # opens a browser; authorize the zone
```

That stores a cert under `~/.cloudflared/` — only on this machine.

### 3. Create a named tunnel

```sh
cloudflared tunnel create haven-relay
# note the Tunnel ID (UUID) printed
cloudflared tunnel list
```

### 4. Route a hostname to it

Pick a name you control, e.g. `haven-relay.example.com` or `relay.family.example.com`:

```sh
cloudflared tunnel route dns haven-relay haven-relay.example.com
```

That creates a CNAME in **your** zone:  
`haven-relay.example.com` → `<tunnel-id>.cfargotunnel.com`.

### 5. Config file

`~/.cloudflared/config.yml`:

```yaml
tunnel: <tunnel-id-or-name>
credentials-file: /Users/YOU/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: haven-relay.example.com
    service: http://127.0.0.1:8674
  - service: http_status:404
```

### 6. Run as a service (survives reboot)

```sh
# macOS
sudo cloudflared service install
sudo launchctl start com.cloudflare.cloudflared

# Linux (systemd)
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Confirm:

```sh
curl -sI https://haven-relay.example.com/ | head
# expect an HTTP response from the relay (auth may 401/403 — that's fine; TLS is up)
```

### 7. Easy path: paste domain + install token into Haven (bundled cloudflared)

You do **not** need to install `cloudflared` as a system service yourself. Haven ships the
binary and can run a **named** connector when you give it both:

| Field | Value |
|---|---|
| **Custom domain URL** | `https://haven-relay.example.com` |
| **Tunnel token** | Install token from Zero Trust → Networks → Tunnels → your tunnel → **Install connector** |

**In the Cloudflare dashboard** (Zero Trust → Tunnels → Configure):

1. Public hostname: `haven-relay.example.com`
2. Service: `http://127.0.0.1:8674` (exact — Haven’s media port)

**In Haven**

| Surface | Where |
|---|---|
| Desktop | Settings → Relays → **Public HTTPS (Cloudflare)** |
| HavenMac | Circle storage → Relay → custom domain + tunnel token |
| `haven-relay` CLI | `--http-url https://haven-relay.example.com --tunnel-token <token>` |

Then start hosting / run the relay. Haven spawns bundled `cloudflared tunnel run --token …`
and announces your domain to the circle.

**Front-door modes (first-class — pick one):**

| Mode | When to use | Haven spawns cloudflared? |
|---|---|---|
| **Auto** | First-run convenience | Free trycloudflare if no URL |
| **Bundled** | Stable domain, Haven runs the connector | Yes (`tunnel run --token`) |
| **Manual** | You (or NAS/Pi) run the tunnel/proxy | **No** — announce URL only |

**Manual is the durable escape hatch.** If Cloudflare ever restricts free trycloudflare or
token install, set **Manual**, put `https://your.domain` as the public URL, and forward TLS to
`http://127.0.0.1:8674` with whatever still works (self-hosted cloudflared, Caddy, nginx,
Tailscale Funnel, a VPS reverse proxy, …). Membership + sealing are unchanged; only the path
to port 8674 changes.

| Public URL | Tunnel token | Inferred if mode is Auto |
|---|---|---|
| empty | empty | Free trycloudflare |
| set | set | Bundled named |
| set | empty | **Manual** announce-only |
| empty | set | Error |

### 8. Manual front door (external tunnel / reverse proxy)

This is a **supported product mode**, not a workaround:

1. Terminate TLS at your edge for `https://relay.example.com`
2. Proxy to `http://127.0.0.1:8674` on the machine running Haven / `haven-relay`
3. In Haven: front door = **Manual**, public URL = `https://relay.example.com`  
   CLI: `haven-relay run --http-url https://relay.example.com` (no `--tunnel-token`)

Haven will **not** spawn cloudflared. It only announces that URL to the circle.

### Optional: API-token automation (for a future in-app wizard)

Create a Cloudflare API token with **least privilege**:

| Permission | Level | Resource |
|---|---|---|
| Account → Cloudflare Tunnel | Edit | This account |
| Zone → DNS | Edit | Only the zone you use |

The app (or a small script) can then:

1. `POST /accounts/{id}/cfd_tunnel` → create tunnel, receive credentials JSON  
2. write credentials + config locally  
3. `POST` DNS CNAME for `haven-relay.<your-zone>`  
4. start `cloudflared` as a user agent  
5. set `haven.relay.publicURL`

Still **no Haven server** — the token lives only on the volunteer's device (Keychain).

---

## Path C — Shared namespace: `*.net.haven.wemiller.com`

You asked whether a subdomain like:

```text
https://<random-id>.net.haven.wemiller.com
```

could be a public hostname any volunteer's tunnel uses, **without** routing media through
your machines.

### Short answer

**Yes for the data path. Partially for the name path.**

| Layer | Who | Sees media plaintext? |
|---|---|---|
| Cloudflare edge | Cloudflare | No (ciphertext only) |
| Your VPS / push worker / site | — | **Not on this path** if done right |
| Your Cloudflare **zone** | Your CF account | No content; yes hostname lifecycle + CF analytics |
| Volunteer's Mac | Them | They already host the sealed store |

So this is **not** "traffic through Blaine's infra" in the sense of your Mac mini or a
Docker host. It **is** "Blaine's Cloudflare account is the DNS + tunnel control plane for
that name." That is a real dependency (you can revoke names; CF outage hits everyone on
that zone) but it is not a media proxy you operate.

### How it would work (control plane only)

One-time zone setup on `haven.wemiller.com` (or a dedicated zone):

1. Delegate or create the zone in Cloudflare.
2. Prefer a dedicated label: `net.haven.wemiller.com` as the parent for volunteer hostnames
   (`<id>.net.haven.wemiller.com`).

**Per volunteer (automated):**

1. Haven (or a tiny **broker** you run only for minting names) calls Cloudflare API with
   **your** account token:
   - create a named tunnel (or issue a tunnel token),
   - create DNS: `<id>.net.haven.wemiller.com` → `<tunnel-uuid>.cfargotunnel.com`.
2. Return to the app: tunnel credentials + public URL  
   `https://<id>.net.haven.wemiller.com`.
3. App writes credentials locally, starts `cloudflared` (or an embedded equivalent), sets
   `haven.relay.publicURL`, re-announces.

Media path after that:

```text
friend  ──HTTPS──►  Cloudflare edge  ──tunnel──►  volunteer's cloudflared  ──►  127.0.0.1:8674
```

Your site, push worker, and S3 never see those bytes.

### What you must accept if you offer this

- **You can shut someone off** by deleting their DNS/tunnel (power and liability).
- **Cloudflare sees** hostname + connection metadata for every volunteer on that zone
  (same as Path B for a user who uses CF themselves — but aggregated under your account).
- **Abuse:** someone could point a tunnel at something other than Haven if they get a
  token; mitigate with short-lived tokens, rate limits on mint, and optional challenge.
- **Cost:** CF tunnels are free at this scale; your cost is operational (API token
  security, mint endpoint, abuse). Not bandwidth on a box you own.
- **App Store:** shipping `cloudflared` or a tunnel helper is fine as optional; forcing
  a dependency on your domain for basic messaging is not — keep iroh + LAN working with
  no tunnel.

### Broker design (minimal, not media)

If you add this later, keep the broker **stupid**:

```text
POST /v1/tunnel/mint   →  { hostname, tunnel_token, expires_at }
DELETE /v1/tunnel/{id} →  revoke DNS + tunnel
```

- Auth: the volunteer's Haven node signs the mint request (or a one-time link from the app).
- Store: only `id → tunnel_uuid, created_at` (no media keys).
- Host: Cloudflare Worker is enough (ironic but fine — still not a media path).
- Rate-limit per account / IP; captcha if abused.

**Do not** proxy `/k/…` through the Worker. That would put ciphertext on your Worker and
defeat the point. The Worker only mints names and tokens.

### Wildcard myth

A single wildcard DNS record alone does **not** attach every random hostname to every
user's tunnel. Each Cloudflare Tunnel needs its own route/CNAME (or a tunnel token
scoped to that hostname). Automation is "create record + tunnel per volunteer," not
"one `*.net` CNAME and done."

---

## Comparison

| Path | Account | Domain | Stable URL | Your infra involved | Best for |
|---|---|---|---|---|---|
| **A Quick Tunnel** | none | none (`*.trycloudflare.com`) | no | none | demos, testing |
| **B Own CF domain** | user's CF | user's | yes | none | real always-on relays |
| **C Shared `*.net.haven…`** | none for user | yours | yes | **CF API control plane only** | zero-config public URL for non-technical users |

Recommendation for the product:

1. **Ship Path A guidance now** (this doc + UI link) — zero cost, proves the HTTP path.
2. **Document Path B** as the power-user stable setup (Mac mini, NAS, Pi).
3. **Design Path C** only if you want "tap Enable public URL" without the user owning a
   domain — and treat the mint Worker as **namespace infrastructure**, not a media relay,
   with a clear privacy note in Settings.

---

## Security notes (all paths)

- Blobs on 8674 are **circle-sealed**. The tunnel and Cloudflare cannot open them.
- The HTTP interface is still **membership + token gated** (same as LAN). A public URL
  does not make the mailbox world-readable.
- Prefer **HTTPS** hostnames (all CF tunnel hostnames are). Don't paste bare `http://`
  public IPs into Public relay URL unless you know what you're doing.
- Keep `cloudflared` updated; run it as a user service when possible.
- Revoking access for a lost device is still **Haven device revocation / epoch rotate**,
  not "turn off the tunnel."

---

## Checklist — friend can't fetch media off-LAN

1. Relay hosting is **on** and serving (`:8674` up).
2. `cloudflared` (or Path B service) is running and healthy.
3. **Public relay URL** is set to the **https** hostname (no path, no trailing slash).
4. Host re-announced (toggle relay off/on, or reopen Haven after setting the URL).
5. Friend is a circle member and has learned the announce (force sync / reopen).
6. Friend is not stuck on a stale LAN-only URL (private addresses are filtered for
   remote peers — see `RelayAddress`).

---

## Embedding: no external `cloudflared` CLI for the user

Ephemeral trycloudflare is the preferred product path for "one tap, public HTTP."
The open question is whether Haven can ship the tunnel **inside** the app so the user
never installs Cloudflare's CLI.

### What "inside the binary" can mean

| Approach | User installs CLI? | Literally one process? | Platforms | Effort / risk |
|---|---|---|---|---|
| **A. Bundle `cloudflared` as an app helper** and spawn it | No | No (child process) | macOS, Linux, Windows desktop; **not iOS** | Low — official client, parse stdout for URL |
| **B. Link a Go c-shared / third-party embed of cloudflared** into `haven-ffi` | No | Yes | Desktop + maybe Android; iOS painful (Go runtime) | Medium–high — size, build matrix, App Store |
| **C. Reimplement quick-tunnel protocol in Rust** | No | Yes | All (including iOS in-process) | High — protocol is undocumented, breaks when CF changes it |
| **D. Depend on system `cloudflared`** | Yes | No | Dev machines | Rejected for product |

**Recommended for Haven: A on desktop-class hosts, skip trycloudflare on iOS for now.**

Why A wins:

1. **cloudflared is Apache-2.0** — redistributable with attribution.
2. Quick tunnels are a first-class CLI mode:  
   `cloudflared tunnel --url http://127.0.0.1:8674`  
   which already prints `https://….trycloudflare.com`. The app only needs to spawn, scrape, set `haven.relay.publicURL`, re-announce, and kill the child when the relay stops.
3. Registration is a simple unauthenticated POST (shape verified live):

   ```http
   POST https://api.trycloudflare.com/tunnel
   Content-Type: application/json

   {}
   ```

   Response includes `hostname`, `id`, `secret` — then the **client** must speak the
   argotunnel/QUIC (or HTTP/2) edge protocol. That second half is the hard part; the
   official binary already does it. Reimplementing (C) means owning breakage every time
   Cloudflare ships a connector change. They document quick tunnels as *testing-only*
   with no SLA ([CF docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)).

4. **iOS cannot honestly "exec a helper binary"** the way macOS can. App Store apps do not
   get a general `Process` to launch nested unsigned tools. Options on iPhone are B/C
   (heavy) or "iOS hosts LAN-only; Mac/desktop does public HTTP" — which already matches
   Haven's copy that a Mac is best for always-on relay.

### What ships today (Path A — implemented)

| Surface | How cloudflared arrives | Auto quick tunnel |
|---|---|---|
| **Desktop (Tauri)** — Windows MS Store / macOS DMG / Linux | `tools/fetch-cloudflared.sh` → `desktop/src-tauri/binaries/`; Tauri `externalBin`. **MSIX** also copies `cloudflared.exe` next to `Haven.exe` in `release.yml` Pack | ON when hosting and no stable `relay_public_url` |
| **HavenMac (App Store / Xcode Cloud)** | `ci_post_clone` fetches → `apple/Helpers/cloudflared`; HavenMac **post-build** copies to `Contents/Helpers/` and **codesigns** with `EXPANDED_CODE_SIGN_IDENTITY` (`apple/Scripts/embed-cloudflared.sh`) | ON when hosting and no `haven.relay.publicURL` (`CloudflaredTunnel`) |
| **`haven-relay` CLI** | First tunnel use downloads official binary **next to** the CLI (or into `<data>/bin`) | ON by default when no `--http-url`; `--no-tunnel` / `--tunnel` |

Pinned version: `2026.7.2` (see `haven_net::cfquicktunnel::CLOUDFLARED_VERSION` and the fetch script).

### Updating the pin (and signing — fully automatic)

**You never hand-sign cloudflared after a version update.**

1. Edit **one** string: `CLOUDFLARED_VERSION` in `core/haven-net/src/cfquicktunnel.rs`.
2. Push / tag as usual. Every pipeline re-downloads that pin and signs as follows:

| Channel | Who signs | Your action after a pin bump |
|---|---|---|
| **Microsoft Store (`.msix` / `.msixbundle`)** | Partner Center re-signs the **whole package** on upload | None (upload the new msixbundle when you release) |
| **Mac App Store (Xcode Cloud)** | HavenMac post-build: `codesign` with `EXPANDED_CODE_SIGN_IDENTITY` | None — next XCC Archive does fetch + sign |
| **Local Debug** | Ad-hoc or PATH fallback | Optional local fetch only |

```sh
# Optional local check — CI does this for you on every build
tools/fetch-cloudflared.sh --all
tools/fetch-cloudflared.sh --apple-helpers
```

`tools/fetch-cloudflared.sh` **reads** `CLOUDFLARED_VERSION` from the Rust source (no second pin to keep in sync).

Lifecycle when hosting with auto-tunnel:

1. Start local HTTP on 8674.
2. Spawn bundled/neighbor `cloudflared tunnel --url http://127.0.0.1:8674 --no-autoupdate --protocol http2`.
3. Scrape `https://….trycloudflare.com` from logs.
4. Announce that URL on the circle's relay HTTP interface (frame 19).
5. On stop: kill the child (hostname dies — expected for ephemeral).

Size: ~20–40 MB per arch. Not shipped on iOS.

### Legal / product notes

- Cloudflare's terms apply when the connector runs (CF License + Terms + Privacy). Surface
  a one-time "uses Cloudflare's free tunnel edge; ephemeral URL; not for production SLA"
  disclosure when the user enables Auto public URL.
- Quick tunnels: **200 concurrent requests** hard limit; no SSE; hostname dies with the
  process. Fine for a family circle's sealed media, bad for a public website.
- Do **not** log the tunnel secret. The public hostname is shareable; credentials are not.

### Why not "compile cloudflared into the Rust binary"

Go and Rust do not produce a single mixed binary without a separate Go artifact (c-archive /
c-shared) linked at the end. That is still "two runtimes in one process," not a pure Rust
rewrite. For Haven's already-heavy `haven-ffi` xcframework, spawning a **signed helper**
keeps crash domains separate (tunnel dies ≠ app jetsam) and matches how many desktop apps
ship `ffmpeg`, `git`, etc.

A pure-Rust client (C) is only worth it if iOS public HTTP becomes a hard requirement.
Until then, Mac/desktop helper is the product fit: the always-on mailbox is already
desktop-class.

---

## Related

- [`BYO-STORAGE.md`](BYO-STORAGE.md) — media transport order (HTTP → S3 → iroh)
- [`HAVEN-NET-RELAY.md`](HAVEN-NET-RELAY.md) — iroh vs public host
- [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) — daemon deploy
- In-app: Storage → circle relay → **Public relay URL**
