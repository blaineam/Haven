# Relay field run — 2026-07-15 (first true two-machine run)

The relay had never been run across two real machines. This is the log of the first one:
real machines, the **release binaries from `v0.1.0-beta.40`**, real traffic. It closes the
ROADMAP item "true two-machine field run" and contradicts several public promises in
[`RELAY-AND-DEPLOY.md`](RELAY-AND-DEPLOY.md) and [`relay/README.md`](../relay/README.md).

> **Scope note.** Everything below tests the **released beta.40 artifacts**, which predate the
> in-flight audit-F2 authorization rewrite in `core/haven-net/` + `core/haven-relay/`. Findings
> that land in those files are **reported, not fixed** (F2 work is owned elsewhere). Re-test after
> F2 lands — finding **A** in particular lives in exactly that code.

## Topology

| Role | Machine | Artifact |
|---|---|---|
| **Relay (A)** | Ubuntu 22.04, **aarch64** VM, `192.168.64.2` | `haven-relay-aarch64-unknown-linux-musl` (beta.40 release asset), installed by the **public one-liner** |
| **Client 1** | same Ubuntu box, headless GNOME on Xvfb `:99` | installed `haven-desktop` (.deb) |
| **Client 2 (B)** | Windows 11 **ARM64** VM, `192.168.64.3` | `Haven_0.1.0_x64_en-US.msi` release build (x64 under emulation) |
| Third machine | macOS host | reachability probes only — see "What we did not do" |

Relay node id `577ea83f…9052c` · Client 1 `b971565b…` · Client 2 `555eca06…` (WinFieldRun).

## What was proven

1. **The public one-liner works end to end.** `curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh`
   on real ARM64 Linux: resolved, downloaded the correct release asset, installed to
   `~/.local/bin`, and registered a **systemd user unit**.
2. **The relay serves all three roles.** Connection relay + local-disk blob mailbox over
   `haven/blob/1` + **plain-HTTP media on `0.0.0.0:8674`** with a generated token. Idle RSS
   **2.9 MB** (11 MB after reboot).
3. **Reachable from other machines.** From the **Mac** and from the **Windows VM**:
   `HTTP 401` — the daemon answered across the network *and* enforced auth. Unauthenticated
   strangers are refused.
4. **A real client on machine B adopted it.** The Windows client pasted the node id →
   **"Configured relays (1)"**, and the circle's settings showed the relay checked under
   "Relays for this circle".
5. **Real cross-machine traffic.** Both clients wrote sealed blobs to the Linux relay's store —
   e.g. `haven/devroster/555eca06…` and `haven/self/555eca06…/state/…` are the **Windows** client's
   bytes, written from Windows to the Linux VM over the network.
6. **Cross-machine pairing works through the network.** Windows → Ubuntu connect request arrived
   ("1 connection request · WinFieldRun"), was accepted, and both sides became mutual contacts.
7. **The mailbox survives restart AND reboot — the public promise holds.** `sudo systemctl reboot`
   on the relay box, **no login afterwards**: the unit came back `active` in ~4 s (linger *is*
   enabled by the installer), the store survived intact (12 keys / 280 KB), the **node id was
   stable**, and the Mac still got `401` from `:8674`. This claim is real.
8. **Offline-delivery transport works.** With the author's client **killed**, the Windows client
   started and **GET every mailbox entry off the relay** (proven by `atime` on the relay's store
   files moving to the exact moment Windows launched), then PUT its own. The bytes moved
   machine-to-machine with the author offline.

## What was NOT proven — and the bugs that stopped it

### A. Offline delivery silently does nothing unless the relay's circle tag *exactly* equals the client's circle id — and nothing tells you that

The first offline test moved **zero** bytes into the mailbox: 200 s of polling, no
`haven/mailbox/**` key, no error anywhere. Root cause, in
`core/haven-net/src/blobstore.rs` → `blob_forbidden()`:

```rust
if let Some(circle) = mailbox_circle(key) {          // "default" from haven/mailbox/default/<hash>
    ...
    return !a.members.get(circle).map(|m| m.contains(peer)).unwrap_or(false);
}
```

The relay authorizes `members[<circle tag from the link>]`. The desktop client's circle id is the
constant `DEFAULT_CIRCLE = "default"` (`desktop/src-tauri/src/engine.rs:27`), so it writes
`haven/mailbox/default/…`. I linked the relay with `--circle fieldrun` — a tag the docs explicitly
describe as arbitrary:

> *"a `circle` tag — an opaque label so one relay binary can serve several circles"* — `link.rs`

It is **not** arbitrary. `members.get("default")` → `None` → `unwrap_or(false)` → **every mailbox
PUT is `ERR forbidden`**. Meanwhile `devroster` PUTs are explicitly allowed and self-sync slots
land, so **the relay looks perfectly healthy**: adopted, "Configured relays (1)", fresh
`last_seen_ms`, blobs arriving. Only the one thing the relay exists for is dead.

**Proof it's the tag:** re-linked with `--circle default` and both members → mailbox entries
appeared in **under 10 seconds**. Same binary, same clients, one string changed.

A self-hoster cannot get this right today: the tag must equal an internal constant that appears
in no doc, and (finding **C**) the flow that would have supplied the correct tag automatically
doesn't exist on their platform.

### B. The receiving client fetches offline posts, marks them seen, and drops them — permanently

This is the more serious one. With the correct tag and the author's client dead, the Windows
client **fetched all three mailbox entries** (atime proof). Then:

| file (Windows client) | mtime | meaning |
|---|---|---|
| `mailbox-seen.txt` | **15:50:03** | keys recorded as seen |
| `haven_social_state.bin` | 15:38:34 (unchanged) | **events never ingested** |

The posts never appeared in the feed. The client consumed the envelopes, wrote them into the
**persisted seen-set**, and discarded them — and because `upload_event()` early-returns on
`seen_mailbox.contains(&key)` (`desktop/src-tauri/src/engine.rs:2541`), those events will **never
be re-fetched**. Offline delivery therefore fails *closed and silently, with permanent loss*, on
the one path the relay exists to serve.

The Windows client also never displayed the peer's posts **even after the author came back
online** (it sat on "Online — looking for your circle…"), so the ingestion failure is not
relay-specific. Whether the two clients ever actually shared a circle **key** (as opposed to being
mutual contacts) is the open question this run could not settle, and is where I'd start.

### C. No desktop or Android client can produce the `haven-relay://circle#…` link the docs are built around

`install.sh`, `relay/README.md`, `relay/docker/README.md`, `web/relay/index.html` and
`docs/LINUX.md` all tell the user: *the app shows you a relay link, paste it into
`haven-relay run --link`*. The daemon **refuses to start without it**:

```
Error: no --link given and no saved circle link in ~/.haven-relay —
run once with `--link <code>` (the code the Haven app shows you)
```

But the only code that builds that link is `apple/HavenApp/FeedView.swift:1694` and
`haven-desktop --headless` (`desktop/src-tauri/src/lib.rs:445`). The **desktop GUI never does** —
`engine.relay_link()` (`desktop/src-tauri/src/engine.rs:1777`) despite its name returns the **bare
node id**, and the UI's copy button toasts *"Relay id copied"*. Android has nothing.

So a Linux or Windows self-hoster following the published instructions **cannot complete them**.
The only route is the undocumented operator helper `haven-relay make-link --circle <tag> --member <hex>`,
which requires knowing both the magic tag (finding **A**) and every member's node hex.

### D. Three different, all-wrong UI paths for adopting a relay

| Source | Says |
|---|---|
| `relay/install.sh:111` | "You → Advanced → Relay → *Add a relay*" |
| `haven-relay run` banner | "Haven → Settings → **Storage** → *Connect a relay*" |
| `relay/README.md:179` | "Settings → **Storage** → *Connect a relay*" |
| **Actual shipped UI** | **Settings (gear) → Relays → paste node id → *Add Haven relay*** |

None of the three match. There is no "Advanced" and no "Storage" section.

### E. The relay's HTTP media path is never configured by the adoption flow

`RELAY-AND-DEPLOY.md` / project notes call plain-HTTP `:8674` the **default cross-NAT media path**.
After adopting by node id, the client's `relay_entries` shows:

```json
"http_urls": [], "http_token": ""
```

Node-id adoption carries **no HTTP URL and no token**, so the "default" media path is inert; the
daemon prints an `http token` that no UI ever asks for. **Media over the relay was not tested**
(blocked behind B) — this needs its own run.

### F. Smaller rough edges a real self-hoster hits

- **`install.sh` never prints the relay's node id** — the thing you must paste. It prints
  instructions for a link flow that doesn't exist (**C**). `haven-relay id` / `run` do print it.
- **The relay writes no logs, by design** ("▸ Haven relay starting (no logs are written)"). When
  authz silently rejects every PUT (**A**), the operator has **zero** diagnostics. Zero-logging is
  a privacy promise worth keeping, but a local "N puts refused: unknown circle <tag>" counter on
  stderr would have turned a multi-hour hunt into ten seconds.
- **The client UI reports a healthy relay as "retrying…"** — persistently, while
  `relay_entries.last_seen_ms` is seconds old and blobs are landing. During finding **A** this was
  the *only* visible signal and it was unreadable: it says the same thing when the relay is fine,
  when it's unreachable, and when it's refusing every write.
- **Windows opens a stray console window titled "Haven"** next to the GUI (`desktop/src-tauri/src/main.rs`
  deliberately omits `windows_subsystem = "windows"`). A stale one rendered as a **blank black
  window** and read exactly like a broken app. Every Windows user sees this.
- **Windows Firewall prompts on first launch.** I declined it (least privilege — it also models
  the NAT'd/no-inbound case relays exist for); the client still reached the relay and still
  completed pairing outbound, so nothing below depended on inbound.
- **`circle_id` is the constant `"default"` for every desktop install**, so every unrelated circle
  collides in the relay's `haven/mailbox/default/` namespace on any shared/community relay. Worth
  a look alongside F2.
- **Release-artifact gaps (beta.40):** no **arm64** Linux `.deb`/`.rpm`/AppImage (the relay ships
  aarch64 musl, but the Pi/ARM-server desktop does not); the Windows installer is **x64-only** (it
  ran under ARM64 emulation here); no macOS desktop artifact.

## What we did not do, and why

- **Media over the relay** — blocked behind **B**, and **E** shows the documented HTTP media path
  isn't wired by the node-id adoption flow anyway. Needs its own run once B is fixed.
- **The macOS host as a third participant.** `/Applications/Haven.app` holds the **real** account
  (real contacts' avatars, real feed). Attaching a test relay to a real circle would have pushed
  real sealed data to a throwaway relay and posted test content to real people. Deliberately not
  done; the Mac was used only for reachability probes.
- **The multi-relay mesh / anti-entropy** — one relay only.

## Verdict on relay self-registration to discovery (ROADMAP)

**Don't build it.** The field run made the case against it stronger, not weaker.

1. **It contradicts the product.** The pitch is "no central service; we host nothing". A discovery
   service that relays announce themselves to, and that clients "find and rank" them from, is a
   central service — one that must be funded, kept up, and defended, against a **HARD MANDATE of
   zero recurring cost**. Whoever runs it can enumerate the network's relays and, by extension,
   watch which relays appear and disappear. That is precisely the thing Haven doesn't have and
   shouldn't acquire.
2. **It's a targeting oracle.** Today a relay is known only to the circle that adopted it. A
   registry turns a private, adopted-by-invitation node into a public list of Haven infrastructure
   — free reconnaissance for DoS, blocking, or legal pressure, and a single point to poison for
   ranking manipulation. Auto-pooling (frame 19 / `RELAY_NODE`) already spreads a relay to a
   circle **without** anyone publishing anything, which is strictly better.
3. **It solves a problem the field run did not find.** Nothing here was hard because relays are
   hard to *discover*. Adoption is one paste of a node id and it worked first try on both
   machines. What's broken is everything *after* discovery: an authorization tag nobody can guess
   (**A**), a receive path that drops what it fetched (**B**), and a documented link flow that
   doesn't exist on two of three desktop platforms (**C**). Self-registration would make the
   *easy* step marginally easier while the actual failures stay exactly as they are.

**Recommendation:** strike "relay self-registration to discovery" from the ROADMAP rather than
leaving it as an unbuilt promise, and note in `RELAY-AND-DEPLOY.md` that it was **evaluated and
declined** on centralisation grounds — the same honest treatment `TOR.md` got. If ranked/known
relays are ever wanted, the non-central version already exists: let members share relay links
inside the circle and let auto-pooling do the fan-out.

## Suggested order of fixes

1. **B** — fetched-but-not-ingested, with a persisted seen-set that makes the loss permanent.
   This is the relay's entire reason to exist. Nothing else matters until offline delivery lands.
2. **A** — make the tag impossible to get wrong (derive it, or have the relay accept the tag from
   the roster/`RELAY_NODE` advertisement rather than the operator's typing), and make a refused PUT
   *visible* to the operator and the client.
3. **C/D** — either build the relay-link UI on desktop, or rewrite `install.sh` + README + the
   daemon banner + web/relay around the flow that actually ships (paste the node id). Today the
   published instructions cannot be followed on Linux or Windows.
4. **F: the "retrying…" indicator** — distinguish unreachable from refusing-writes. It was the
   only signal for a total delivery outage and it was silent about it.
