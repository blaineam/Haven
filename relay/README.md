# Haven Bridge — be the always-on home for your circle

A **bridge** keeps your circle's messages flowing even when people aren't online at the
same time. It's a zero-knowledge store-and-forward **mailbox**: every post is uploaded
**sealed** (end-to-end encrypted to the circle), and any member downloads it whenever
*they* come online. The sender and receiver never have to overlap — and the bridge
**cannot read anything**. It only ever holds opaque, circle-sealed blobs.

Because the mailbox speaks the S3 API, "hosting a bridge" just means **running (or
renting) an S3-compatible bucket** and pointing Haven at it. No custom server, no
account on anyone's platform, no plaintext anywhere.

> **Two ways to run a bridge.** The classic way (below) is a public-ish S3 bucket you
> point Haven at. The new **`haven-relay`** binary is the *easiest* way: one command, no
> bucket, no ports, no domain — it links to your circle and serves **both** relay roles
> (live forwarding **and** the media mailbox) entirely over Haven Net. Jump to
> **[The easiest way: `haven-relay`](#the-easiest-way-haven-relay-link-to-your-circle-in-one-command)**.

## The easiest way: `haven-relay` — download → run → paste link → done

`haven-relay` is a **single static binary** (macOS / Linux / Windows) that anyone can
download, run, and link to their circle. By default it stores your circle's sealed media
on **its own local disk** and serves everything over **Haven Net** (iroh, which
NAT-traverses, so it works behind a home router with **no port-forwarding**). The result:
a fully **decentralized** mailbox — **zero cloud, zero OAuth, zero config, no single
tracking point, no provider keys.** Run it on any always-on machine you own (an old
laptop, a Raspberry Pi, a home server, a free cloud VM) and that machine becomes your
circle's mailbox.

Once linked it serves **both** relay roles while the device is online:

1. **Connection relay** — forwards sealed *mesh-relay frames* toward circle members who
   aren't reachable directly (offline-at-the-same-time, or behind NAT). It reads only a
   tiny cleartext routing header (destination node ids, a hop budget, and a random
   message id for de-duplication); the payload is an already-circle-sealed envelope it
   **cannot open**.
2. **Media store-and-forward** — by default a **local-disk blob mailbox**: sealed,
   content-addressed blobs are stored under `~/.haven-relay/store` and served over the
   Haven Net overlay (iroh, ALPN `haven/blob/1`) with **no public host, no port-forward,
   no domain, and no `rclone`**. The blobs are circle-sealed, so the relay host can't read
   the media.

### Run it — three steps

```sh
# 1. Install (one line). The installer also auto-sets-up start-on-restart for THIS OS
#    (systemd user unit / launchd agent / Task Scheduler / @reboot cron) — opt out with --no-service:
curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh

#    Want the sealed-blob store on a specific disk? Pass a custom storage path:
#    curl -fsSL …/install.sh | sh -s -- --store /mnt/bigdisk/haven-relay

# 2. The Haven app shows you a relay link for your circle (You → Advanced → Relay).
#    Paste it in. The relay derives its own identity, makes its store dir, and goes online.
#    (If you chose a custom --store path, add the same --data here.)
haven-relay run --link "haven-relay://circle#...."   # [--data /mnt/bigdisk/haven-relay]

# 3. That's it — it now auto-starts on every reboot. To restart by hand, no args needed:
haven-relay run
```

The installer registers the auto-start *before* you link, so it simply comes online on the
next login after step 2 (or run step 2 now and it starts immediately). Remove the auto-start
any time with `haven-relay service uninstall`. The auto-start command carries through your
`--data` path, so a custom storage location survives reboots.

On first run it prints a **QR + the link** (so you can re-add the relay in the app any
time), **persists its identity** so its node id is stable across restarts, and **persists
the circle link** so `haven-relay run` (zero-arg) just works. Reprint the link/QR any
time with `haven-relay link`.

### Storage backends — local disk is the default; cloud is optional

| Flag | Backend | Needs | Where the bytes live |
|---|---|---|---|
| *(default)* | **Local-disk blob mailbox** (`haven/blob/1`) | nothing | `~/.haven-relay/store` on this machine |
| `--s3` | `rclone serve s3` of a local dir (`haven/s3/1`) | `rclone` | `~/.haven-relay/store`, via the S3 API |
| `--rclone-remote <remote:path>` | **any rclone remote** (`haven/s3/1`) | `rclone` + a configured remote | wherever your rclone remote points |
| `--no-storage` | connection relay only | nothing | (no media mailbox) |

```sh
haven-relay run --link <code>                                # local disk (default)
haven-relay run --link <code> --rclone-remote mydrive:haven  # any rclone backend
haven-relay run --link <code> --s3 --s3-port 8333            # rclone serve s3 of a local dir
haven-relay run --link <code> --no-storage                   # relay only
haven-relay run --config relay.json                          # everything from a file
```

**Power-user note (rclone, ~70 backends, no Haven-held OAuth).** `--rclone-remote` lets
the store live on *any* of rclone's backends — your own cloud drive, another S3, SFTP,
WebDAV, etc. **rclone owns the provider auth** (it reads its own `rclone.conf`); neither
`haven-relay` nor the Haven app ever holds a provider OAuth token or refresh token. Point
at an explicit config with `--rclone-config /path/to/rclone.conf`. Local-disk stays the
default; rclone/S3 are strictly opt-in.

`relay.json`:

```json
{
  "link": "haven-relay://circle#....",
  "data_dir": "~/.haven-relay",
  "storage": "local",
  "rclone_remote": "mydrive:haven",
  "s3_port": 8333
}
```

`storage` is `"local"` (default), `"s3"`, `"rclone"` (requires `rclone_remote`), or
`"none"`. Setting `rclone_remote` selects the rclone backend automatically.

The relay generates and **persists its identity seed once** (`~/.haven-relay/identity.json`,
owner-only `0600`), so its **node id is stable across restarts** — the circle keeps
pointing at the same relay. Print it any time with:

```sh
haven-relay id          # -> the relay's node id (what the app stores as the relay / volunteer node)
```

> `haven-relay` needs `rclone` on `PATH` **only** for the `--s3` / `--rclone-remote`
> backends (pass `--rclone /path/to/rclone`). The default local-disk and relay-only modes
> have **zero external dependencies**.

### Keep it always-on — survives reboot on every OS

**The one command that does it for you (any OS):**

```sh
haven-relay run --link "<code>"   # attach to your circle once (Ctrl-C after it saves)
haven-relay service install       # ← wires up auto-start on login/reboot for THIS OS
#   Linux → systemd user unit (+ enable-linger), or crontab @reboot fallback
#   macOS → launchd LaunchAgent (RunAtLoad + KeepAlive)
#   Windows → Scheduled Task at logon
haven-relay service uninstall     # undo it
```

That's the easiest path. The per-OS manual recipes below are equivalent, if you prefer to set
them up by hand or tweak them.


| OS | Install | Auto-relaunch on reboot |
|---|---|---|
| **Linux** (x86-64 / Arm / Pi) | `curl -fsSL …/install.sh \| sh` | systemd unit (system service in the `.deb`/AUR, or the user unit below) |
| **macOS** (Intel / Apple Silicon) | `curl -fsSL …/install.sh \| sh` | launchd LaunchAgent (`setup-macos.sh`) |
| **Windows** (x86-64 / Arm64) | `irm …/install.ps1 \| iex` | Scheduled Task at logon — **set up automatically by the installer** |

> The shell `install.sh` is POSIX `sh` → **macOS + Linux**. **Windows** uses `install.ps1`
> (PowerShell), which downloads `haven-relay.exe` *and* registers the logon Scheduled Task in
> one step. All three cover both x86-64 and Arm.

**Windows — one line** (registers `haven-relay.exe` to start on every logon, no admin):

```powershell
irm https://wemiller.com/apps/haven/relay/install.ps1 | iex
haven-relay run --link "haven-relay://circle#...."   # paste once; it auto-starts thereafter
# start now:  schtasks /Run /TN HavenRelay   •   stop auto-start:  schtasks /Delete /TN HavenRelay /F
```

**macOS — one command** (installs a launchd LaunchAgent, starts at login, auto-restarts):

```sh
sh setup-macos.sh                  # daemonize the relay already on your PATH
sh setup-macos.sh --link <code>    # first attach to your circle, then daemonize
# stop:  launchctl bootout gui/$(id -u)/com.haven.relay && rm ~/Library/LaunchAgents/com.haven.relay.plist
```

**Linux — systemd user service** (`haven-relay.service` is in this folder):

```sh
mkdir -p ~/.config/systemd/user
cp haven-relay.service ~/.config/systemd/user/
loginctl enable-linger "$USER"     # keep running after logout
systemctl --user enable --now haven-relay
systemctl --user status haven-relay # node id is in the log

# or, dead-simplest (cron at reboot):
( crontab -l 2>/dev/null; echo "@reboot $HOME/.local/bin/haven-relay run >/dev/null 2>&1" ) | crontab -
```

**Then, in the app:** Settings → Storage → **Connect a relay** → paste the node id the daemon
prints (`haven-relay id`). Your whole circle adopts it as the always-on mailbox.

### Mesh several relays together (self-replicating mailbox)

Point relays at each other and they **replicate the mailbox among themselves** every ~30s —
each pulls any sealed blob a sibling holds that it lacks. The mailbox becomes a self-healing
set: a relay can **join** (one pass makes it a full replica) or **leave** (peers already have
copies) with zero loss, so the circle survives any relay coming or going.

```sh
# Tell this relay about its siblings (repeatable; or "peers": [...] in a --config JSON):
haven-relay run --link <code> --peer <sibling-node-id> --peer <another-node-id>
```

In the desktop app it's automatic: any relay you **host** auto-meshes with every other relay
your circle has adopted (Relay view) — no flags. Only the local-disk store meshes (S3/rclone
backends are external stores). Replication only ever moves ciphertext, like everything else.

### You don't even need the CLI — any official Haven app can be the relay

The standalone binary is the leanest option for a headless box, but it's **not the only way**.
Every official Haven client — iPhone, Mac, **Windows, Linux desktop** — can host the exact same
relay in-process. On the desktop app: **Relay → "Always-on relay (survives reboot)"** → tick
*Start Haven when I log in* + *Host the relay automatically on launch*, and that machine becomes
a reboot-surviving relay with no terminal at all. (`haven-desktop --headless` does the same with
no window — and also runs your scheduled-message dispatcher.) Adopt several — your phone-hosted
relay, a friend's Mac, and a Pi — for redundancy; the circle survives any one going down.

### How linking works (and why it's safe)

The app emits a **relay link** for a circle. Unlike a *reach-me* link (which points at a
person and carries a verification hash of their key bundle), a relay link carries **only
public routing data**:

```text
haven-relay://circle#<base32 json>      json = { "v":1, "c":"<circle tag>", "m":["<node-id-hex>", …] }
```

* `c` — an opaque **circle tag** (a label, not a key) so one relay can serve several
  circles with separate de-dup state.
* `m` — the circle's **member node ids** (32-byte Ed25519 routable ids, already public —
  they appear in every member's reach-me link). The relay forwards sealed frames *toward*
  these ids.

There is deliberately **no content key, no KEM key, and no roster secret** in the link —
so linking a relay can **never** turn it into a content reader or a bypass target
(Haven's #1 security mandate). Members auto-discover the relay by its node id (it is the
`volunteer_node_id` for storage and a dialable relay for forwarding) and start using it;
no per-device config.

### Exactly what the relay can and cannot see

| The relay **can** see | The relay **cannot** see |
|---|---|
| Destination **node ids** of frames it forwards (public ids) | Who is in which circle by name; circle content keys |
| A random **message id** + **hop count** (for loop/replay control) | The **content** of any post, comment, message, or media — all sealed E2E |
| That an iroh connection / S3 request happened, and the peer **IP** that made it | Which sealed blob is which post; any plaintext, ever |
| The opaque **byte size** of frames/blobs | Anything that would let it impersonate a member or read history |

**Metadata note — exactly what's observable.** The relay's local-disk blob mailbox
(`haven/blob/1`) and the S3 tunnel (`haven/s3/1`) both move only ciphertext. The relay
sees, per request: the **node id** of the peer talking to it (public routing data), the
**opaque content-addressed key** string (e.g. `mailbox/<circle>/<hash>`), the blob's
**byte size**, the **verb** (put/get/has/list), and **timing**. It never sees plaintext
media, any content key, or which sealed blob corresponds to which post. Keys are validated
and confined to the store directory (no `..`, no absolute paths), so a malicious peer
cannot read or write outside the store.

Hardened, **no-log** defaults: nothing is written to disk except the relay's own seed, the
saved circle link, and the (sealed) blob store; the de-dup set is RAM-only and bounded;
the blob store logs nothing; `rclone` (only when you opt into `--s3`/`--rclone-remote`)
runs at `--log-level ERROR` bound to loopback only. As with any relay, it transiently
handles your IP (that is physically how bytes reach you) — see `docs/RELAY-AND-DEPLOY.md`
for the honest IP-privacy promise, and for why VPN or a self-hosted relay — not an onion
mode — is the supported way to hide your IP from a node.

### Free / cheap always-on hosting

Local disk on a machine you already own (old laptop, Raspberry Pi, NAS, home server) is
the purest "no third party" option. If you'd rather not leave a machine on at home, any
always-on box works — `haven-relay` needs **no inbound ports**, so even free tiers behind
NAT are fine:

| Option | Cost | Notes |
|---|---|---|
| **Your own always-on box** | $0 | Pi / old laptop / NAS — fully decentralized, nothing rented |
| **Oracle Cloud Always-Free** | $0 forever | 4 Arm cores / 24 GB ARM VM (`aarch64-unknown-linux-musl` binary) |
| **Fly.io** | ~$0 (free allowance) | a tiny always-on machine; outbound-only, no public service needed |
| **Google Cloud `e2-micro` free tier** | $0 (one region) | small but enough for a relay |
| **A $5/mo VPS** (Hetzner, racknerd, etc.) | ~$5/mo | if you want a dedicated box; still no public host required |

Because there are **no inbound ports and no public endpoint**, you don't configure
firewalls, domains, or TLS — just install the binary and `haven-relay run`. The traffic is
already sealed and rides Haven Net's iroh overlay.

**Automating those deploys.** Each host's own provisioning is the right place to drop the
two commands (install + run) — e.g. a cloud-init `runcmd:` on Oracle/GCP, a one-line
`Dockerfile`/`fly.toml` `CMD ["haven-relay","run"]` on Fly.io, or an Ansible play that
templates the systemd unit above. A planned `haven-relay deploy --provider <oracle|fly|…>`
helper (see `docs/RELAY-AND-DEPLOY.md`) will wrap these so a non-technical user can stand
up a free always-free relay from one command; until it lands, the install-script +
`haven-relay run` pair is all any of these need.

---

## The classic way: one command (self-hosted bucket)

Runs `rclone serve s3` (rclone is **MIT-licensed**, a single cross-platform binary) on
your machine — a Pi, a NAS, an old laptop, or a cheap VPS — serving a plain folder over
the S3 API, and prints the exact settings to paste into Haven.

```sh
curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh --bucket
# or, from this folder:
sh install.sh --bucket            # Docker (any OS)
sh install.sh --bucket --native   # native rclone binary (Linux / macOS, no Docker)
```

> The same `install.sh` defaults to the easy `haven-relay` binary; pass `--bucket` for
> this classic self-hosted-S3 path.

Or with Docker Compose:

```sh
HAVEN_BRIDGE_KEY=you HAVEN_BRIDGE_SECRET='a-strong-password' docker compose up -d
mkdir -p data/haven    # the folder named 'haven' is the bucket
```

**Why rclone?** It's MIT, ubiquitous, and `serve s3` can expose *any* of rclone's 70+
backends — a local folder, your own cloud drive, another S3, SFTP — so your bridge
storage is whatever you already trust:

```sh
rclone serve s3 myremote:path --addr :8333 --auth-key "KEY,SECRET"
```

Then in the app: **You → Advanced → Storage → Custom S3 bucket**, paste the endpoint /
bucket / keys, and turn on **“Volunteer as tribute.”** That's it — your bucket is now
the circle's mailbox.

> To let people reach it from outside your home network, expose the port via a router
> port-forward, [Tailscale](https://tailscale.com), or a small VPS. The traffic is
> already sealed, so a plain HTTP endpoint is fine, but HTTPS (a reverse proxy) is nicer.

## The zero-maintenance way: a managed bucket

Don't want to run anything? Use any S3-compatible provider — you still hold the keys,
and the provider only ever sees sealed blobs:

| Provider | Endpoint example | Notes |
|---|---|---|
| **Cloudflare R2** | `<acct>.r2.cloudflarestorage.com` | no egress fees, generous free tier |
| **Backblaze B2** | `s3.us-west-004.backblazeb2.com` | cheap storage |
| **AWS S3** | `s3.amazonaws.com` | the original |
| **rclone serve s3** (self-host) | `your-host:8333` | the install script above |

Create a bucket, make an access key, paste into Haven, enable "Volunteer as tribute."

## Want full decentralization? IPFS

You can back the mailbox with **IPFS** instead of a bucket: sealed blobs are pinned and
addressed by CID, and members fetch by CID even when the poster is offline — as long as
something keeps them pinned (your own IPFS node here, or a pinning service like
web3.storage / Pinata). It's the most "no-company-storage" option; it's also heavier and
slower than S3, so it's offered as an alternative backend rather than the default.
*(IPFS backend: in progress.)*

## Why this is safe

- **The bridge never sees your messages.** Everything is sealed to the circle with hybrid
  post-quantum crypto before it leaves a device. The bucket stores ciphertext only.
- **No Haven server.** This is *your* bucket (or your friend's). We host nothing.
- **Keys stay on-device.** Your S3 credentials live only in your device Keychain.
- **Revocable.** Block or remove a member and rotate the bucket key any time.

## How it fits together

```
  you ──post(sealed)──▶  bucket/mailbox/<circle>/<hash>  ◀──poll+get──  mom (later, offline-friendly)
        (S3 / R2 / B2 / rclone / IPFS)   ← bridge holds only ciphertext
```

Every Haven client (iPhone, Mac, web) can both **write** to and **poll** the mailbox, so
any always-on device — even a browser tab left open — can be the bridge for its people.

## Building `haven-relay` from source

The binary lives in the monorepo at `core/haven-relay`. It composes the existing
`haven-net` (iroh transport, mesh-relay frame, the local-disk **blob mailbox**
`haven/blob/1`, and the S3-over-iroh tunnel `haven/s3/1`) and `haven-p2p` (crypto/identity)
crates — it reinvents nothing.

```sh
cd core
cargo build --release -p haven-relay        # single static binary at target/release/haven-relay
cargo test  -p haven-net -p haven-relay      # forwarding + blob-store + tunnel + link tests
```

The headline guarantee is proven by `core/haven-net/tests/blob_store.rs`: one node seals a
media blob and PUTs it to a relay that stores it on **local disk** over iroh; a *different*
node GETs it back and opens it with its own circle keys; and the test asserts the relay —
not a circle member — **cannot decrypt** the bytes it stored.

Cross-compile per-OS with the usual cargo targets (e.g.
`cargo build --release -p haven-relay --target x86_64-unknown-linux-musl` for a fully
static Linux binary, `--target x86_64-pc-windows-gnu` for Windows).

### Two-machine manual run

The integration tests prove forwarding, the local-disk blob mailbox, and the media tunnel
**in-process** (two iroh nodes + the relay on one host, dialing loopback directly, since
spinning up real public discovery in CI is flaky). The cross-machine path — discovery
resolving a relay's node id over the public n0 relays — still wants a real **two-machine
test**. To exercise it:

1. On the relay box: `haven-relay run --link "<relay link from the app>"`. Note the
   printed **relay node id**.
2. In the Haven app on each member device: add that node id as the circle's relay /
   storage volunteer (the app does this automatically from the same link). The relay
   resolves member node ids via iroh discovery (n0 public relays) — no inbound ports.
3. Post from one member while another is offline; bring the other online — the post
   arrives via the relay (live forward) or the media mailbox (store-and-forward).
