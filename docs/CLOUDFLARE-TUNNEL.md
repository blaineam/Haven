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

### 7. Paste into Haven

**Public relay URL** = `https://haven-relay.example.com`

Leave Haven (or `haven-relay`) running with the local HTTP interface on 8674. The tunnel
is only a public front door; membership + bearer token still gate the store.

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

## Related

- [`BYO-STORAGE.md`](BYO-STORAGE.md) — media transport order (HTTP → S3 → iroh)
- [`HAVEN-NET-RELAY.md`](HAVEN-NET-RELAY.md) — iroh vs public host
- [`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) — daemon deploy
- In-app: Storage → circle relay → **Public relay URL**
