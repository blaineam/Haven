# Web client — in development (reopened 2026-11-19)

**Status: being built on `feat/web-client`. Not shipped. See D21 in [`DECISIONS.md`](DECISIONS.md).**

The web client was abandoned on 2026-06-22 (history at the bottom). The reason then was
structural: a browser cannot be a Haven peer, and the only workable shape needed a public server
every circle would depend on. That reason no longer holds, because of things that shipped since:

- **A circle-hosted HTTPS front door.** The relay's path proxy serves the sealed-media mailbox,
  the iroh relay (DERP, a WebSocket) and the call hairpin on one hostname
  ([`CLOUDFLARE-TUNNEL.md`](CLOUDFLARE-TUNNEL.md)). A tab needs only outbound HTTPS/WSS to it, and
  it is the circle's own relay, not a server of Haven's.
- **Seedless enrollment (1.0.7).** A linked device holds a device key and a credential and never
  receives the master seed ([`MULTI-DEVICE.md`](MULTI-DEVICE.md)). The deleted `haven-wasm` crate
  wanted the seed in `localStorage`; a browser device never has it at all.
- **iroh runs in a browser** as a relay-only endpoint.

## What a web device is

A **seedless linked device** like any other, enrolled from one of your existing devices and
revocable from them. It is a real node on the same protocol — the same engine compiled to
WebAssembly, the same `haven/social/0` wire, the same signed-HTTP mailbox — with one difference:
its only network path is the circle relay. Nothing in the protocol or the relay's authorization is
special-cased for it.

Two session modes are planned:

| Mode | Device key | Needs |
|---|---|---|
| **My computer** | Persists, wrapped by a non-extractable browser key | A stable relay hostname (a named tunnel or your own domain — a quick tunnel's hostname changes on every restart and takes the browser's storage with it) |
| **Public computer** | In memory only; revoked when the tab closes | — |

There is **no web sign-up**. Creating an account in a browser would put the master seed there. A
web device is always linked from an existing device.

## What the web client trusts (read this before using one)

The page's code has to come from somewhere, and whoever delivers it can change it. For a web
session that is **the relay host, the tunnel provider in front of it (it terminates TLS), and
any network that inspects TLS** — which includes exactly the locked-down networks a web client is
for. Sealed data survives all three; code does not. Nothing in a browser fully closes this.

So the design bounds the damage instead of pretending it away: a compromised web session can read
and post **as that one device until it is revoked**. It never holds the master seed, cannot
authorize other devices, and loses access to new content when revoked (the epoch rotates). Native
apps remain the stronger client, and the UI will say so. Web access is off unless a circle's
owner turns it on, because other members' posts become readable in that browser.

## What a browser cannot do

| Limit | Effect |
|---|---|
| No direct peer connections | Everything rides the circle relay: slower media, and the web client works only while that relay is online |
| No background life | Notifications with the tab closed need Web Push; nothing else runs |
| No Bluetooth / nearby mesh | Nearby delivery is unavailable |
| Cannot host a relay | Hosting stays on the native apps and `haven-relay` |
| Bring-your-own S3 | Each bucket needs CORS enabled |

## Where it lives

| Piece | Path |
|---|---|
| Client layer shared by desktop and browser (engine, stores, wire) | `core/haven-client` |
| Browser core: engine + relay-only transport (wasm32 only) | `core/haven-web` |
| Build → `web-client/pkg` | `web-client/build.sh` |
| Transport smoke (headless Chromium vs. the native wire) | `web-client/smoke/smoke.mjs`, `core/haven-net/examples/web_peer.rs` |
| Engine smoke (the shared engine in a tab ↔ the same engine natively) | `web-client/smoke/engine.mjs`, `core/haven-client/examples/web_primary_engine.rs` |
| Durable storage for a tab (IndexedDB write-behind) | `web-client/storage.js` |
| Request signing shared by relay, native clients and browser | `core/haven-p2p/src/httpauth.rs` |

`haven_ffi` (the engine) now builds for `wasm32-unknown-unknown`: its native-only parts — the iroh
node, relay/DERP/path-proxy hosting, the S3 client — are compiled out there, and the browser
supplies the transport. `web/` is still only the static invite-landing site.

## Progress

Done and proven (each line names what proves it):

- [x] The engine and crypto core compile to WebAssembly; the engine self-test passes in Chromium
      (`web-client/smoke/smoke.mjs`).
- [x] Relay-only node in a tab: reaches a native node and is reached by one through a circle DERP,
      sender ids authenticated, 2 MiB frames (`smoke.mjs`, `core/haven-net/examples/web_peer.rs`).
- [x] The client layer is one crate, `core/haven-client`, shared by the desktop app and the browser:
      the engine, its stores, wire, self-sync, roster, media and relay policy. The desktop app keeps
      its Tauri glue, commands, QA, demo and Instagram import. Native: 347 tests there + 108 in
      desktop.
- [x] That whole crate builds for wasm32, behind five seams (see its `lib.rs`): `rt` (tasks,
      timers), `host` (UI events, notifications), `fs` (std::fs | an in-memory tree), `secrets`
      (OS keyring | a corner of `fs`), `transport`/`net` (native node + hosting | relay-only node,
      no hosting).
- [x] **The real engine runs in a tab** (`web-client/smoke/engine.mjs` against the same engine
      running natively, `core/haven-client/examples/web_primary_engine.rs`): a fresh tab holds no
      identity; it links with a `haven-enroll:` ticket and the primary's approval; the linked state
      survives a reload (IndexedDB, `web-client/storage.js`); a post authored in the tab is opened
      by the primary and attributed to the account.

Next, in order:

- [x] **The relay serves the page, and the tab uses its mailbox.** `engine.mjs` now loads the web
      client from a hosting relay's own front door and asserts posts in BOTH directions.
      - The path proxy serves a bundle under `/app/` from memory (`haven_net::webbundle`): a fixed
        set of names, exact-match lookup, a closed list of content types, CSP and no-sniff headers,
        ETag revalidation; its digest is in `/_haven`. The proxy still never touches the
        filesystem (it has a test for that).
      - A hosting engine hands it the bundle (`HostingOptions.web_app`) only while the
        `relay_web_access` setting is on — **off by default**.
      - A new frame, 36 (`wire::RELAY_INTERFACE`): the account's seed-holding device tells its own
        other devices each relay's URLs + token. A browser has no blob transport and holds no
        circle key yet, so it could not learn them any other way. Accepted only when signed by the
        account's own key — not a contact, not another linked device.
      - Fixed on the way: the proxy stripped `Connection: Upgrade` from WebSocket upgrades, which
        every browser rejects (native clients never checked).
- [x] **Hosts can offer it.**
      - `haven-relay run … --web-app <web-client/dist>` (or `"web_app"` in its JSON config) loads
        the bundle into memory and serves it; without the flag there is no web access. Checked
        against the real daemon.
      - The desktop app hands its hosted relay the bundle it finds among its resources
        (`web-client/`, or `HAVEN_WEB_APP_DIR` in development) and shows a **Web access** switch in
        Settings ▸ Relays — off by default, with the trust warning on the card and the address
        members open (`<front door>/app/`) once it is on.
      - Media works each way (the smoke posts a picture from the tab and one to it).
      - The Mac app's relay host does the same through the FFI
        (`PathRouterHandle.spawn_with_web_app`, `web_app_digest`; tests in
        `core/haven-ffi/tests/web_app_host.rs`): `RelayHost.setWebAccess`, a **Web access** switch
        under the front-door controls with the same warning and address, in all nine languages.
        The build copies `web-client/dist` into `Contents/Resources/web-client` when it exists
        (`apple/Scripts/embed-web-client.sh`); without it the app has no switch. Turning it on or
        off restarts the front door, so "off" is true the moment it is shown.
      - Phones do not host it. The iPhone/iPad and Android in-app relays have no public front
        door (no path proxy, no tunnel helper), so there is nothing for a browser to open. They DO
        take part in linking: a phone that approves a browser, or re-announces its relay, teaches
        the account's other devices the relay's address with frame 37 (`FeedStore.swift`,
        `HavenNet.kt`), exactly as the desktop does.
- [ ] Release packaging: no shipped build includes `web-client/dist` yet. The desktop installers
      and the Mac app's Xcode Cloud build both need the wasm toolchain (rustup wasm32 target, an
      LLVM clang for ring, the pinned `wasm-bindgen`) in CI before the switch appears anywhere.
- [ ] Bundle size: ~10.8 MB of WebAssembly, ~3.5 MB on the wire (the proxy gzips every bundle
      file once, at load, and serves that to browsers that accept it). `wasm-opt` and a brotli
      variant (~2.3 MB measured) would cut it further; neither is done.
- [ ] Per-circle consent. Web access is a host-level switch today. "This circle allows web
      devices" needs a device class in the credential and members refusing to seal to a web device
      a circle has not allowed — a protocol change, to be modelled before it is built.
- [x] **The UI.** The browser runs the desktop frontend (`desktop/ui`) unchanged, with a host shim
      in place of Tauri (`web-client/web-host.js`).
      - 141 of the desktop app's 164 commands need only the engine and moved to
        `haven_client::commands`, behind one dispatcher both hosts call (`engine_invoke` on
        desktop, `WebApp.invoke` in a tab). The other 23 belong to the application; the browser
        answers the ones that make sense there and refuses the rest.
      - A browser is offered linking and nothing else: no "new to Haven", no "move my account",
        and a `haven-seed:` code is refused before it goes anywhere.
      - Responsive layer (`web-client/responsive.css`): the desktop layout from 1025px up; on a
        tablet, sheets sized to the screen; on a phone the tabs become a bottom bar with the
        composer floating above it, and sheets cover both bars.
      - `web-client/build.sh` assembles the bundle a relay serves in `web-client/dist`.
      - `smoke/engine.mjs` now drives this real UI: paste the ticket, get approved, reload, post
        both ways, see both posts rendered. `SMOKE_SHOTS=<dir>` saves phone/tablet/desktop shots.
- [x] Settings that cannot work in a browser are hidden there (identities, hosting a relay and
      its front door, start at login, the Instagram importer).
- [x] Drag-and-drop of pictures and videos onto the page. A browser hands the page `File`s, not
      paths, so the drop goes straight into the picker's own sanitize pipeline (re-encode, no
      EXIF/GPS) — the same function the desktop's path-based drop now calls. Every file drag is
      cancelled window-wide, because a browser otherwise navigates to the dropped file and the
      session is gone. Checked by the smoke.
- [ ] Media in a browser: the cache lives in the in-memory tree today, which is fine for text and
      wrong for video. It needs a blob store of its own (OPFS / Cache API).
- [x] The engine's delayed save works in a page. It started an OS thread, which a browser cannot
      do: the first post received over the network crashed the task handling it and nothing
      network-driven was saved again (posts still showed, because the live state was intact).
      It runs on the page's event loop now; a Rust panic is reported in the console with its
      message; and the smoke fails on any uncaught page error instead of passing around it.
- [x] **Storage modes** (`web-client/storage.js`), chosen on the link screen before anything is
      written. Every record is AES-GCM ciphertext with its path as associated data.
      - *Shared or public computer* (the default): a randomly named database whose key lives only
        in the tab's sessionStorage. Leaving the page by anything but a reload discards the session;
        its database is deleted on the next visit.
      - *This is my computer*: one database under a non-extractable WebCrypto key.
      - *Start over* erases every Haven database in the browser.
      - The smoke asserts all four: no plaintext in any record, nothing left after leaving a
        shared session, the remembered link survives with a non-extractable key, Start over wipes.
      - What this does NOT do: protect an open session on a compromised machine, or protect
        "my computer" storage from someone using that browser profile. A browser's own "reopen
        closed tab" may also bring a shared session back until the window is closed.
- [ ] **Scan-to-link** — the browser shows a code and a device that has the account answers it
      (a borrowed computer usually has no camera, and nobody can type a ticket into it from a
      phone). Core, browser, desktop and both phones' scanners are written; see the last items
      for what has and has not been exercised.
      - [x] Codec, in the crypto core so every platform agrees on the bytes
            (`core/haven-p2p/src/pair.rs`, FFI in `haven-ffi/src/enroll.rs`, fuzzed with the other
            wire parsers). A `haven-pair:` code holds the new device's id, the 16-byte check of
            its full key bundle, a one-time secret, a timestamp and the relay it is listening on —
            nothing about any account. Ten-minute life, replaced on screen every eight.
      - [x] The answer is **frame 38** (`PAIR_OFFER`): an ordinary enrollment ticket, sealed
            under the code's secret, sent through the relay the code names
            (`send_to_node_via` on both node kinds). After it, linking is frames 28/29 unchanged,
            including the person's Approve.
      - [x] The ticket minted for a scanned code is **bound to the device the code names**: a
            request under it from any other device is refused
            (`a_ticket_minted_for_a_scanned_code_enrolls_only_the_device_it_names`). So reading
            the code off a screen is not enough to get a device onto the account — stricter than
            a pasted ticket, which enrolls whoever holds it.
      - [x] The waiting device (`core/haven-client/src/pairing.rs`) has no account and takes
            exactly one kind of frame from anyone: an offer that opens under the code on screen.
            Nothing is stored while the code shows; the storage choice ("is this your computer?")
            is applied when an offer arrives.
      - [x] Browser: the link screen shows the QR and the text. Desktop: Devices ▸ Add a device ▸
            "Scan its code" (camera) or paste. The smoke links a browser this way end to end.
      - [x] iPhone/iPad and Mac (`FeedStore.answerPairCode`, "Scan its code" in Link a device)
            and Android (`HavenNet.answerPairCode`, Settings ▸ Devices ▸ "Link a browser or device
            that shows a code"): scan with the camera or paste, in nine languages, each with the
            same bound-ticket check in its own enrollment handler. COMPILED on both; NOT yet run on
            a device or simulator against a real browser — the end-to-end proof so far is the
            desktop engine and the browser.
      - [ ] The desktop app as the NEW device still links by pasted ticket only; it does not show
            a code of its own.
      - [x] Formal model: `docs/formal/haven_pair.spthy`, in `verify.sh` / `EXPECTED.txt`. With
            the network and relays hostile, adversary-owned devices around, and the code READ by
            the adversary: P1 only the scanned device is enrolled; P2 the ticket is learned only by
            reading that code; P3 an unread code is answered only by whoever scanned it. The
            `-DUNBOUND` variant (an ordinary, unbound ticket — NOT built) falsifies P1. The limit
            below is in the model too, as a reachable trace. The person's Approve tap is not
            modelled, so none of this depends on someone reading a device name correctly.
      - What it does not protect against, stated plainly: someone who can read the code off the
        screen can answer it first with a ticket for THEIR account, so that browser joins their
        account instead (the person sees the wrong name and an empty feed; nothing of theirs is
        exposed). The first answer wins.
- [ ] The same against a shipping native app, and through a real Cloudflare tunnel.
- [ ] Calls (WebRTC + the relay hairpin), Web Push.
- [ ] Account → device discovery in a browser (resolve/publish are stubs; rosters and inbound
      frames supply device ids for now).
- [x] **Formal model** — `docs/formal/haven_web_device.spthy`, re-proved by `docs/formal/verify.sh`
      (and so by the `security-proofs` workflow) against `EXPECTED.txt`. With the network, the
      relay and any number of linked devices in the adversary's hands:
      - W1: a device learns a relay's address only from its own account's key (frame 37);
      - W2: a compromised linked device cannot enrol another device;
      - W3: the account key is never learned from a linked device;
      - W4: the relay token is readable only by the device it was sealed to.
      The `-DDEVICE_SPEAKS` variant models the looser rule that was NOT built ("any credentialed
      device may send frame 37") and W1 is falsified there, on record. The code side of W1 is the
      unit test `a_relay_interface_is_learned_only_from_the_accounts_own_key`. A symbolic model:
      it says nothing about a browser that is compromised while a session is open, which stays
      the stated limit of a web session.

## Open questions

- **Which relays a tab uses.** A tab reaches a peer only through a relay that peer is registered
  on. Today it is given the circle's DERP alone. Native devices also keep n0's public relays in
  their map and may be homed on one, so the tab should probably carry them too where the network
  allows, and fall back to the mailbox where it does not.

- **Push from a browser.** The engine wakes other devices through the push worker. A page cannot
  call it today (no CORS), so a web device relies on the mailbox poll and live frames. Allowing it
  means the worker accepting browser origins — a decision about maker-run infrastructure.
- **Engine restart.** The engine has no shutdown; the desktop app relaunches after linking, and a
  tab reloads. Fine, but it means every "switch identity / unlink" path in a browser is a reload.

## History — why it was abandoned (2026-06-22)

Browsers cannot accept inbound connections or do raw UDP/QUIC, so a tab can never hole-punch into
the mesh. The only shape that could work was a thin client of a publicly-hosted WSS → iroh bridge,
which meant "a server everyone depends on" — the thing Haven exists to avoid. The `web/engine/`
client was removed, and `core/haven-wasm` was deleted in the 2026-07 security audit (it recommended
storing the seed in `localStorage`). The "open a tab to keep your circle warm" idea became the
in-app RelayHost and `haven-relay`; the second platform became native Android.
