# Haven fabric relay on your NAS (full path)

This is the **happy path** for a home/NAS box that should be the circle’s transport fabric:

| Role | Port | Purpose |
|---|---|---|
| **Media mailbox** | TCP **8674** (HTTPS via your tunnel/proxy) | Sealed media GET/PUT |
| **iroh DERP** | TCP **3340** (HTTPS via tunnel/proxy) | Live messaging NAT fallback — **replaces n0** for the circle |
| **TURN** | UDP **3478** | WebRTC calls without Google STUN |

When members paste the relay’s **interface JSON** (or learn it via frame 19), apps use:

- **Haven DERP only** for iroh (n0 off)
- **Circle TURN** for WebRTC ICE (Google STUN off)

n0 / Google STUN remain only if no Haven fabric is set up.

---

## What you need

1. An always-on box (Synology, TrueNAS, Unraid, Linux VM, Pi, etc.) with Docker **or** a plain Linux binary.
2. A way peers can reach it:
   - **Preferred:** reverse proxy / named Cloudflare tunnel for **HTTPS** (media + DERP), **and** UDP 3478 port-forward for TURN.
   - **LAN-only circle:** no public URL; use LAN IPs (friends off-LAN won’t get media/calls well).
3. Haven app (any member) to generate the **relay link** and later paste **interface JSON**.

> **trycloudflare free tunnels cannot front UDP TURN.** Media/DERP can use Cloudflare; TURN needs UDP 3478 open or peers only on LAN.

---

## Path A — Docker on NAS (recommended)

### 1. Copy the Docker package

From the repo (or release assets), copy:

```text
relay/docker/Dockerfile
relay/docker/entrypoint.sh
relay/docker/docker-compose.yml
```

to a folder on the NAS, e.g. `/volume1/docker/haven-relay/`.

### 2. Get the circle’s relay link (in the app)

1. Open Haven on your phone or Mac.  
2. **Settings → Storage → Advanced → “Connect an external relay”**.  
3. Tap **“Copy this circle’s relay link”** (`haven-relay://…`).

### 3. Create `.env` next to `docker-compose.yml`

```env
# Required on first run only (saved into the data volume afterward)
HAVEN_RELAY_LINK=haven-relay://circle#PASTE_YOUR_LINK

# Stable node id even if the volume is recreated (recommended)
HAVEN_RELAY_SEED=PASTE_64_HEX_FROM_openssl_rand_-hex_32

# How members reach MEDIA over HTTPS (or HTTP on LAN)
# Examples:
# HAVEN_RELAY_HTTP_URL=https://relay.example.com
# HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674
HAVEN_RELAY_HTTP_URL=https://relay.example.com

# Fabric (DERP + TURN) — public hostnames/IPs members use
# DERP is HTTP(S) to your proxy → container :3340
HAVEN_RELAY_DERP_URL=https://derp.example.com
# TURN is UDP — public IP or hostname:3478
HAVEN_RELAY_TURN_URL=turn:203.0.113.10:3478
HAVEN_RELAY_TURN_PUBLIC_IP=203.0.113.10

# Optional overrides (defaults are fine in Docker):
# HAVEN_RELAY_DERP_BIND=0.0.0.0:3340
# HAVEN_RELAY_TURN_BIND=0.0.0.0:3478
```

**LAN-only** (everyone on the same network):

```env
HAVEN_RELAY_LINK=haven-relay://…
HAVEN_RELAY_SEED=…
HAVEN_RELAY_HTTP_URL=http://192.168.1.50:8674
HAVEN_RELAY_DERP_URL=http://192.168.1.50:3340
HAVEN_RELAY_TURN_URL=turn:192.168.1.50:3478
HAVEN_RELAY_TURN_PUBLIC_IP=192.168.1.50
```

### 4. Build and start

**Until a release includes fabric (DERP/TURN), build from this branch** (one-time long compile on a fat machine, then load on the NAS if needed):

```sh
# On a desktop with Docker (faster than building on a small NAS):
cd relay/docker
export HAVEN_RELAY_SOURCE=1
export HAVEN_RELAY_REF=feature/iroh-relay-gossip   # or main once merged
docker compose build --no-cache
docker save haven-relay:local | gzip > haven-relay-local.tgz
# copy tgz to NAS, then: gunzip -c haven-relay-local.tgz | docker load

# On the NAS (with .env in place):
docker compose up -d
docker compose logs -f
```

When a release has fabric baked in:

```sh
docker compose build --no-cache   # downloads latest static binary
docker compose up -d
```

### 5. Open the ports / proxy

| Port | Protocol | Where |
|---|---|---|
| **8674** | TCP | Host → container (compose already maps it) |
| **3340** | TCP | Host → container (DERP) |
| **3478** | **UDP** | Host → container (TURN) |

**Reverse proxy / Cloudflare named tunnel (media + DERP only):**

- Public hostname `relay.example.com` → `http://127.0.0.1:8674` (media)  
- Public hostname `derp.example.com` → `http://127.0.0.1:3340` (DERP)  
- Or one host with path rules if you prefer  

**Router:** forward **UDP 3478** to the NAS for WAN calls.

### 6. Paste **interface JSON** into Haven (not only the node id)

```sh
docker compose exec haven-relay cat /data/interface.json
# or
docker compose logs | grep -A1 'paste this into Haven'
```

Example shape:

```json
{
  "node": "64hex…",
  "urls": ["https://relay.example.com"],
  "token": "…",
  "derp": "https://derp.example.com",
  "turn": ["turn:203.0.113.10:3478"],
  "turnUser": "haven",
  "turnPass": "…"
}
```

In the app: **Storage → Connect an external relay** → paste the **whole JSON** → Connect.

That one paste:

1. Adopts the relay node  
2. Learns media HTTP + token  
3. Learns DERP (iroh fabric)  
4. Learns TURN (WebRTC)  
5. Re-announces to the circle (frame 19)

Other members learn via gossip when they sync; they can also paste the same JSON.

### 7. Confirm

- **Messaging** works while both off LAN (fabric DERP).  
- **Media** uploads show HTTP success (not endless iroh timeout).  
- **Calls** between two off-LAN devices succeed with fabric TURN (UDP 3478 open).  
- Desktop toast may say fabric reconnected after rebind; that’s expected.

---

## Path B — Binary on Linux NAS (no Docker)

```sh
# Install latest release (or build from feature/iroh-relay-gossip until released)
curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh

# First run — paste your circle link from the app
haven-relay run --link 'haven-relay://…' \
  --data /var/lib/haven-relay \
  --http-url https://relay.example.com \
  --derp-url https://derp.example.com \
  --turn-url turn:YOUR.PUBLIC.IP:3478 \
  --turn-public-ip YOUR.PUBLIC.IP

# Logs print interface JSON — paste into the app
# Later: haven-relay run   (or systemd)
```

Ensure host firewall allows **TCP 8674, TCP 3340, UDP 3478**.

---

## What “done” looks like for fabric

| Check | OK when |
|---|---|
| `interface.json` has `derp` + `turn` + `turnUser`/`turnPass` | DERP/TURN started |
| App Storage shows the relay with HTTP + fabric | Paste/adopt worked |
| Cross-NAT DM/post without n0 outage panic | DERP reachable |
| Cross-NAT video call | UDP TURN reachable |

If media works but calls don’t: almost always **UDP 3478** not open.  
If messaging cross-NAT fails: **DERP HTTPS** not proxying to **:3340**.

---

## Updating

```sh
# Docker (release binary once published with fabric):
docker compose build --no-cache && docker compose up -d

# Docker (still on feature branch):
HAVEN_RELAY_SOURCE=1 HAVEN_RELAY_REF=feature/iroh-relay-gossip \
  docker compose build --no-cache && docker compose up -d
```

Data volume keeps identity + store; **node id stays the same**. New `interface.json` may get new trycloudflare names if you use free tunnels — re-paste or rely on frame 19 re-announce.

---

## Security notes

- Relay only stores **ciphertext**.  
- `turnPass` / `http` token travel only inside sealed announces and local `interface.json` — treat the data dir as private.  
- Prefer a dedicated seed in `HAVEN_RELAY_SEED` and back up `/data`.

---

See also: [`IROH-RELAY-GOSSIP.md`](IROH-RELAY-GOSSIP.md), [`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md), [`relay/docker/README.md`](../relay/docker/README.md).
