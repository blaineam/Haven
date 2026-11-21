# Web client

**Status: shipped in 2.2.0, served by a circle's relay. Served by a web site as well from the
release after it. See D21 in [`DECISIONS.md`](DECISIONS.md).**

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

**From a web site** (next section) the list changes rather than grows: the code then comes from
that site, its host and whatever sits in front of it, instead of from the relay host and the
tunnel. The relay still carries the sealed data and still cannot read it. The difference is who
could swap the code: one site for everyone who uses it, where a relay-served page puts each
circle in the hands of its own host. The page says which of the two it is on the link screen.

So the design bounds the damage instead of pretending it away: a compromised web session can read
and post **as that one device until it is revoked**. It never holds the master seed, cannot
authorize other devices, and loses access to new content when revoked (the epoch rotates). Native
apps remain the stronger client, and the UI says so. Two switches stand between a relay-served
browser and a circle's posts, both off by default: the relay's host has to offer the web client
at all, and **the circle has to allow web devices** — because it is the other members' posts
that become readable in that browser. A page served by a web site does not need the first: the
relay's host is not handing out any code, so there is nothing for that switch to withhold. The
second, the circle's, applies to every browser wherever its page came from, and it is the one
that decides who can read.

## From a web site

The same client can be served by an ordinary static web site: `web-client/build.sh` also writes
`web-client/dist-site/`, a Release carries it as `haven-web-site.tar.gz`, and the project's own
site can serve the build of the latest stable Release at `/app/` (a switch its owner holds, off
until set: [`DECISIONS.md`](DECISIONS.md) D24; `Scripts/verify-web-site.mjs` checks what a site
serves against a Release). It is for the person who cannot
reach, or does not know, their relay's address: one address that does not change, a code on the
screen, a phone to scan it.

What is different about such a page:

- **It starts out knowing no relay.** A relay-served page can be reached through the relay that
  served it. This one comes up on a rendezvous relay instead: the public ones every Haven app
  already falls back to when a circle has no relay of its own, or the ones the site's operator
  named when building it (`HAVEN_SITE_RENDEZVOUS`). Its code names whichever one it settled on.
- **The phone's side does not change.** The app answers the code through the relay the code
  names, as it always has, and the owner still has to approve the device by name.
- **The rendezvous relay carries the linking frames and nothing else it can read.** It sees two
  devices exchange a few sealed frames. It is not given the account, the circles or the posts.
- **Then the phone is not needed.** Once linked, the browser learns each of the account's relays
  and which circles it serves from the account itself (frame 37) and reads and writes those
  mailboxes directly, as a relay-served page does.

If you host it yourself: give it an origin of its own (a host name that serves nothing else). A
browser keeps what a page stores per origin, so any other page or script on the same origin could
reach what the client stores there. That is why the project serves it from Haven's own address
and the portfolio, which shares one origin among many pages, only redirects to it.

What has to be true for it to work, said plainly:

- **The relay must run 2.2.1 or later.** A page may read another origin's answers only if that
  origin says so, and older relays do not (`Access-Control-Allow-Origin`, and an answer to the
  browser's preflight). Against an older relay the browser links and then sits empty.
- **The relay must be on `https`.** A page on an `https` site cannot call a plain `http` relay;
  browsers block it. A relay behind a tunnel or its own domain is fine; one that is only an
  `http://` address on the home network is not reachable from a web site at all (it still is
  from the page that relay serves itself).
- **Letting pages read the relay's answers grants nothing.** Every mailbox request is authorized
  by a signature over the request, made with a member's device key. There is no cookie or session
  a browser could attach on a page's behalf, so a page from anywhere can do what any program on
  the internet can: ask, and be refused. The relay answers every origin the same way and never
  looks at which site asked (regression test:
  `a_page_from_another_origin_may_ask_but_still_needs_a_members_signature`).
- **A relay-served page gains from this too**: it can now read an account's *other* relays, which
  it could not while only its own origin was readable.

Proven by `web-client/smoke/site.mjs` (run in CI by the `web-client` workflow): a plain file
server on another origin than the relay serves the page; it shows a code though no relay served
it; the primary's answer links it; nothing arrives before the circle allows browsers; posts then
travel each way with every mailbox call crossing origins; the link survives leaving and coming
back. `SMOKE_RENDEZVOUS=public` runs the same with no relay named, over the public rendezvous
relays. `PHONE_SITE=1 … phone.mjs` does it against a real app.

## Which circles a browser can read

All of them. A linked browser is a device of your account like any other: once you approve it on
a device that holds the account, it reads every circle and conversation the account is in.
There is no per-circle switch (it was removed: [`DECISIONS.md`](DECISIONS.md), D22 withdrawn).

What that means, said plainly:

- The approval on your phone is the only gate. The approval screen marks the device as a browser.
- A browser never holds the account key and cannot sign for the account.
- Whoever serves the page's code could change it, and a changed page reads what your devices
  read, everywhere, until you remove that browser (You ▸ Devices). Removing it cuts it off from
  everything new and sends it back to its link screen.
- Other members of a circle are not asked and are not told.
- An app from before this change still applies the old rule to what it seals, so its posts reach
  a browser only if that circle had allowed browsers.

## What a browser cannot do

| Limit | Effect |
|---|---|
| No direct peer connections | Everything rides the circle relay: slower media, and the web client works only while that relay is online |
| Served by a web site | Needs the circle's relay on `https` and on 2.2.1 or later |
| No background life | Notifications with the tab closed come by Web Push (a content-free doorbell); nothing else runs |
| No Bluetooth / nearby mesh | Nearby delivery is unavailable |
| Cannot host a relay | Hosting stays on the native apps and `haven-relay` |
| Bring-your-own S3 | Each bucket needs CORS enabled |

## Where it lives

| Piece | Path |
|---|---|
| Client layer shared by desktop and browser (engine, stores, wire) | `core/haven-client` |
| Browser core: engine + relay-only transport (wasm32 only) | `core/haven-web` |
| Build → `web-client/pkg`, `dist/` (for a relay), `dist-site/` (for a web site) | `web-client/build.sh` |
| The page served by a web site, end to end | `web-client/smoke/site.mjs` |
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
      - A new frame, 37 (`wire::RELAY_INTERFACE`): the account's seed-holding device tells its own
        other devices each relay's URLs + token. A browser has no blob transport and holds no
        circle key yet, so it could not learn them any other way. Accepted only when signed by the
        account's own key — not a contact, not another linked device.
      - Each relay in that frame names the circles it serves (`circles`), and the receiving device
        assigns it to exactly those. The first build assigned every relay to every circle the
        device held, which put a private circle on a friend's relay: the release gate caught a
        private photo mirrored to two relays that serve only a shared circle (e2e `multirelay: no
        private circle's media on a friend's relay that doesn't serve it`). Never shipped.
        Regression test: `a_relay_interface_assigns_a_relay_only_to_the_circles_it_serves`, plus
        the sender-side tests on Apple and Android.
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
- [x] **Release packaging** (`.github/workflows/web-client.yml`). One job builds the web client
      into `haven-web-client.tar.gz` (for a relay) and `haven-web-site.tar.gz` (for a web site);
      run on its own it also drives the browser smokes, relay-served and site-served.
      - Desktop installers (`desktop.yml`, `release.yml`) unpack it into the app's resources and
        bundle it (`cargo tauri build --config '{"bundle":{"resources":["web-client/**/*"]}}'`),
        so the Web access switch appears in shipped Windows and Linux builds. To do the same
        locally: unpack a `web-client/dist` into `desktop/src-tauri/web-client/` first.
      - A Release carries the archive as an asset, for `haven-relay --web-app <dir>`.
      - The Mac app: `apple/ci_scripts/ci_post_clone.sh` builds it when the Xcode Cloud workflow
        sets `HAVEN_BUILD_WEB_CLIENT=1` (off by default: it costs build minutes).
      - None of it can hold a release back: called from an installer workflow the build step is
        allowed to fail, and an installer without the archive is a complete app with no switch.
      - Not verified until it has run: see the workflow's own runs.
- [x] Bundle size: the build runs Binaryen's `wasm-opt -Oz` on the module when it is installed,
      and CI requires it (`HAVEN_REQUIRE_WASM_OPT=1`), so the release archive is always the
      optimized one: 10.9 MB → 8.3 MB of WebAssembly, about 3.2 MB on the wire (the proxy gzips
      every bundle file once, at load, and serves that to browsers that accept it). The browser
      smoke in CI runs against the optimized module. A local build without `wasm-opt` is the same
      program, larger.
      - Decided, not done: a brotli variant (~2.3 MB measured before `wasm-opt`). The relay would
        need a brotli encoder, or a decoder to check a pre-compressed file against the body it
        claims to be — a new dependency in the relay and in every app that can host one, for
        about a megabyte on a first visit. A relay behind a CDN or tunnel that compresses
        responses may already get it; that was not measured.
- [x] ~~**Per-circle consent**~~ **withdrawn 2026-11-21** (D22 withdrawn; "Which circles a browser can
      read" above). What follows is the record of what was built; the engine no longer applies it.
      - The rule and the signed record: `core/haven-p2p/src/webpolicy.rs` (`CircleWebPolicy`,
        `web_allowed`), unit-tested and fuzzed. Records ride the circle's control lane as tag
        `0x0b`, persist with the circle, and merge per signer (a replayed older yes loses).
      - A web device is marked in its account-signed device NAME (`WEB_DEVICE_MARK`). The
        credential has no spare field, and changing its signed bytes would make every shipped app
        reject the roster; the name is already inside them. A relay cannot strip the mark, and a
        mark on the wrong device only ever removes access.
      - Engine (`core/haven-ffi`): a web device is left out of a circle's key commits, dial set,
        media wraps and both key trees unless `circle_allows_web`; the circle re-keys when the
        answer changes; a Removed web leaf is re-admitted by a later signed yes. A key OFFERED by a
        web device is refused where the circle has not agreed — devices of one account converge on
        the larger key, so without that a browser could hand its siblings the next key and read
        along (the first test run found exactly this).
      - UI on every platform: a switch in the circle's settings and in each conversation, with
        where the circle stands and who it is waiting on; in a browser, a notice on a circle that
        has not allowed it. Nine languages on Apple and Android, seven on desktop.
      - Tests: `core/haven-ffi/src/web_consent_tests.rs` (six, sender-key lane),
        `mls_a_web_device_is_a_leaf_only_while_the_circle_allows_web_devices` (v1 key tree), the
        v2 tree test below, the desktop UI tests, and the browser smoke (shut out when linked, keyed in when allowed).
      - Formal model: `docs/formal/haven_web_consent.spthy` — C1 a web device is keyed only with
        every member's yes; C2 a browser cannot pass as an app (`-DSTRIPPABLE`, the class outside
        the signature, falsifies it); C3 a circle key is read only by the device it was sealed to.
      - The v2 key tree has its own test
        (`a_web_device_is_a_v2_leaf_only_while_the_circle_allows_web_devices`): out, in, out, back
        in. It found that a Removed browser never asked to come back on that tree (a device does
        not re-offer a key package once it has been Removed); a web device now does when its
        circle allows web devices again.
      - The iPhone app's side of this has been run end to end (`web-client/smoke/phone.mjs`);
        its screens were driven through the QA channel, not tapped. Android and the Mac app:
        compiled, not run.
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
- [x] Media in a browser is bounded. Everything a tab stores lives in the page's memory (mirrored,
      encrypted, into its storage), so the media cache is capped at 256 MB
      (`Engine::WEB_MEDIA_BUDGET_BYTES`): the oldest blobs become "Download" placeholders, the same
      thing a storage limit does in the apps, and come back from the relay when asked for.
      - **A very large video is saved, not played.** In a browser, media over 64 MB
        (`Engine::WEB_LARGE_MEDIA_BYTES`) is not fetched on its own: it shows as a placeholder
        with its size and "Save to this computer". Asking for it fetches it once, decrypts it,
        hands it to the browser as a file in the person's downloads, and drops it again — it
        never becomes a player in the page and nothing that size stays in the tab or its storage.
        The relay only ever holds ciphertext, so it cannot serve the video to the browser to
        stream; decrypting has to happen in the page. Decided: no file-backed storage (OPFS) in
        the browser beyond this.
        Tested: the size rule (`a_browser_leaves_large_media_on_the_relay_until_it_is_asked_for`),
        the placeholder and its action (`desktop/ui-test`), and in a real browser by the smoke —
        the saved file is byte-identical and the tab holds nothing afterwards.
      - Still true, stated: while it is being saved, a large video passes through the page's
        memory once (roughly three times its size at the peak), so a video of several gigabytes
        can still fail in a browser; and POSTING a very large video from a browser has to fit in
        memory too. Use an app for those.
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
- [x] **Scan-to-link** — the browser shows a code and a device that has the account answers it
      (a borrowed computer usually has no camera, and nobody can type a ticket into it from a
      phone). Exercised end to end with the desktop engine, the iPhone app (simulator) and the
      Android app (emulator) answering the code. Not exercised: pointing a real phone's camera
      at the QR — the tests hand the code's text to the same function the scanner calls.
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
      - Decided against: the desktop app showing a code of its own when it is the new device. A
        device that links by showing a code is always enrolled as a WEB device — that is what
        stops a replaced page from passing itself off as an app. Letting a code say "I am an
        app" would give that page the same line to say. A desktop links by ticket.
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
- [x] **Through a real Cloudflare tunnel.** `HAVEN_SMOKE_TUNNEL=1` makes the smoke's native
      primary host its relay the shipping way — Haven starts `cloudflared` itself and announces the
      `trycloudflare.com` address — and the browser does everything through that address: the
      page, the DERP WebSocket, the mailbox, uploads. Passes repeatedly. Not hermetic (it uses
      Cloudflare), so it is not in CI; and never run it on a machine hosting a real relay, because
      starting a tunnel sweeps "leftover" Haven tunnel helpers. It found two bugs:
      - the tunnel helper was killed seconds after starting (its output stopped being read once
        the address was known) — fixed on `main`, it affected shipped desktop and `haven-relay`;
      - a circle's key that reached a browser just before the circle's yes was dropped for good —
        now held unopened and replayed (`a_key_that_reaches_a_browser_before_the_circles_yes_is_held_not_lost`).
- [x] **Against a real app as the primary** (`web-client/smoke/phone.mjs`, docs/QA.md): the
      iPhone app in a simulator, a standalone `haven-relay --web-app` it adopted, and a browser
      linked to it by the browser's own code. The app's Swift code answers the code, raises the
      confirmation with the device marked as a browser, keeps the browser out of the circle until
      its switch is turned on, and then posts flow each way. Passes repeatedly (~30 s). It found:
      - the app told a new browser how to reach the relay's mailbox ONCE, at the moment of
        linking — which is when the page reloads. A browser that missed it could only be reached
        live. Every platform now re-sends it (at most once a minute) whenever one of the
        account's own devices makes contact;
      - nothing else: scan answer, bound ticket, web mark, consent and re-keying worked first time.
      - **The Android app passes the same test** (3 of 3), in the `haven_phone` emulator, driven
        over adb (`PHONE_ADB_PKG=…`; the test's channel code is `web-client/smoke/qachannel.mjs`).
        Its Kotlin code answered the code, marked the browser, held it out of the circle and let
        it in, first time. The relay's ports are forwarded into the emulator with `adb reverse`.
      - **The Mac app as the web host passes it** (2 of 2). Run as the QA fleet's isolated Mac
        build (`Scripts/qa-e2e-build-stub.sh`: its own bundle id, container and keychain group, so
        it cannot reach a real account), built from this branch with the web client embedded,
        hosting its relay in-process with the front door in manual mode (no tunnel helper is
        started). The browser loads `/app/` from the Mac's own front door, shows its code, and
        the Mac app — primary and relay host at once — answers it, marks the browser, holds it
        out of the circle and lets it in. The switch itself, through the app's own code
        (`host_web_access`): off by default (`/app/` is 404), on serves it at once, off again
        stops it at once, and the rest of the front door stays up throughout.
      - **And behind its own Cloudflare tunnel** (2 of 2): the same build with the tunnel helper
        embedded and the front door left on automatic. The browser does everything through the
        `trycloudflare.com` address the Mac app announced. Worth knowing: switching Web access
        on or off restarts the front door, and a free tunnel gets a new address each time it
        starts — so a browser opened at the old address has to be reopened at the new one.
      - Seen once in about a dozen Android call runs and not reproduced: the app crashed with a
        Compose "reading a state that was created after the snapshot was taken" error during a
        call, on a heavily loaded machine. Not traced to anything in this work; recorded so it
        is not lost.
      - [ ] Not run: a physical device.
- [x] **Calls** (`web-client/smoke/call.mjs`): accounts that are contacts on one relay, each
      with a browser linked to it; one browser calls, the other rings and answers with its real
      Accept button, the peer connection comes up in both, audio flows both ways, and hanging up
      ends it on both. Passes repeatedly. It needs the internet (the two accounts find each
      other as real ones do), so it is run by hand, not in CI. It found three things:
      - **A call never rang on a device without the account key.** A call frame was sealed to
        the callee's ACCOUNT key, so a linked device that never received the seed — every
        browser, and any phone or tablet linked the seedless way — got it and could not open it
        (`SEEDLESS-ENROLLMENT-PLAN.md` already said calls "degrade" there). Callers now seal one
        copy to each device the callee's signed roster names, falling back to the account-sealed
        frame for a device whose key is unknown. Changed in the shared engine, the Apple app and
        the Android app; the Apple and Android changes are compiled, not run.
      - Two copies of one offer, handled at the same moment, made the second "set local answer"
        throw. Call events are now handled one at a time, and a duplicate offer or answer is
        ignored.
      - A re-sent invite made the offering side create a SECOND offer on a connection that
        already had one. One offer per connection now; a repeat re-sends the same one.
      - **Camera and screen sharing** are in the same test: the camera turned on mid-call shows
        up in the other browser (judged by the picture — a camera that is off still sends black
        frames at full rate, so a frame count proves nothing), both ways; a shared screen replaces
        it; stopping the share brings the camera back.
      - **A group call of three** is in it too: a third account's browser is added to the call
        in progress with the real "add" control, rings, answers, and every browser ends up
        connected to the other two with media arriving; one person leaving leaves the other two
        talking. Everyone in a group call has to be a contact of everyone else (a stranger's call
        frames are dropped), so the test makes all three pairs contacts first.
- [x] **Calls between browsers and a real app** (`web-client/smoke/phone-call.mjs`): the Android
      app in the emulator is one account; two more accounts become its contacts (and each
      other's) by invite link and each links a browser through the app's relay. Passes
      repeatedly, back to back:
      - a browser calls the app and the app answers — audio both ways;
      - **video**: the browser's camera, turned on mid-call, shows up in the app, and the app's
        camera shows up in the browser (judged by the picture);
      - **a group call**: the second browser is added mid-call with the real control, rings,
        answers, and the app and both browsers are all connected to each other; one leaving
        leaves the other two in the call;
      - hanging up on either side ends it on the other; the app calls back and the browser
        answers.
      This is the first run of the Android per-device call sealing: the app's invite rang in a
      browser that holds no account key. It found two bugs in the shipped Android app, both
      fixed on `main`:
      - **A call could hang itself up six seconds after a connection blip.** The check Android
        schedules when a link goes quiet never looked at whether the link had recovered, and a
        check left over from an ended call hung up the next call with the same person
        (`DisconnectGraceTest`); iPhone and Mac already had the guard.
      - **After a video call, the next call started with the camera already on.** The camera
        switch was never reset when a call ended, so the next call — one merely answered included
        — sent video from its first second
        (`a_call_that_ended_with_the_camera_on_leaves_the_next_call_starting_with_it_off`).
      - The emulator the QA fleet keeps is in airplane mode; the accounts find each other by
        public discovery, so the test needs it off (docs/QA.md).
      - **The iPhone app passes it too** (simulator): audio both ways, the browser's camera
        showing up in the app, the three-way group call, and a call placed from the app ringing
        and connecting in the browser — the first run of the iPhone's per-device call sealing.
        The app's own camera is skipped there and said so: a simulator has none.
      - **Found and fixed on `main`:** an iPhone that took the invite of an account with no
        relay of its own exchanged nothing with it for minutes. Answering a hello, Android sends
        the circle's relays along with its recent posts; Apple sent the posts only, and left the
        relays to a broadcast repeated every ten minutes on a phone. The answer now carries them
        (`testAnsweringAContactsHelloTellsThemWhereTheCirclesRelaysAre`), and the test passes on
        iPhone in both invite directions.
      - **Screen sharing from the browser to an app** is in the test: with the browser's camera
        off, its shared screen is shown by the app, and stopping takes the app back to the
        avatar. That found a desktop bug, fixed on `main`: the page announced "camera off"
        through a screen share, so phones drew an avatar over the shared screen.
      - [ ] Not tested: an app sharing ITS screen to a browser (Android needs the system's
            capture consent, an iPhone a broadcast extension — neither can be driven from this
            test), and a physical device.
- Decided: a browser does not publish itself to, or look people up in, public discovery (the
  native apps do, to find a contact's devices with no relay in common). A browser reaches the
  network through its circle's relay and nothing else — that is the point of it — so it learns
  device ids from signed rosters and from whoever writes to it, and it reaches a device only
  through a relay that device is also on. Someone who holds only your account id reaches your
  other devices, not your browser.
- [x] **Notifications while the tab is closed (Web Push)** — built; it starts working when the
      push worker is deployed with a key pair (`push/README.md`, "Browser wake-up via Web Push").
      Until then the switch says "not available right now".
      - Off by default. Settings → Privacy → "Notify me when Haven is closed", and only in a
        browser the person chose to stay linked in: a borrowed computer is never left ringing.
      - What arrives is a **doorbell with no content**: the worker sends an empty request to the
        browser's push endpoint; `web-client/sw.js` shows "Something new is waiting for you"; the
        page fetches and decrypts through the circle's relay when it is opened. The push service
        (Google, Mozilla, Apple or Microsoft) learns that this browser was rung and when — not by
        whom, about what, or which account. If a Haven page is already in front, nothing is shown.
      - The service worker has **no `fetch` handler**: it never serves, caches or rewrites a
        request, so the page still always loads exactly what the relay serves now.
      - A browser has no account key, so it registers with its DEVICE key plus the credential its
        account signed for it; the worker checks the account's signature, the web mark, and that
        the credential names the key that signed (D23). Filed under the account, so everyone who
        would wake the account's phones wakes the browser too, with no change on their side.
      - Unlinking or "Start over" unsubscribes and removes the service worker.
      - **Revoking a browser stops it.** The worker cannot see an account's device list, so the
        account tells it: when a browser is revoked from a device that holds the account key (the
        desktop app, an iPhone, iPad, Mac or Android phone), that device sends the worker a
        signed notice (`/unregister-web`). The worker drops the browser's endpoint and refuses
        its credential from then on. The notice is queued until the worker answers, so a
        revocation made offline is delivered later. **What is left:** until that device has
        been online once after the revocation, the browser can still be rung — it learns that
        something happened, nothing else. A registration also lapses by itself after 30 days.
      - Proved (`docs/formal/haven_web_push.spthy`): an endpoint is filed under an account only
        for a browser that account linked (R1), only the endpoint that browser asked for (R2), a
        phone's credential files nothing (R3), and only the account can bar a browser (R4). The
        window between revoking and the worker hearing of it is on record as a reachable trace,
        and R1–R3 are falsified for the looser rule that was not built (`-DNO_CREDENTIAL`).
      - Tested: the worker's contract (`push/worker.test.mjs`, including a registration built by
        the Rust core from a shared vector), the service worker (`web-client/sw.test.mjs`), the
        switch (`desktop/ui-test`), and in a real browser by the smoke as far as a harness can go
        (the relay serves the service worker, the browser accepts it, a refused switch subscribes
        nothing, Start over leaves no worker).
      - **A real push, end to end** (`web-client/smoke/push.mjs`): real Google Chrome links as
        a browser the person keeps and turns the switch on; the worker — `push/worker.js` itself,
        run inside the test with a throwaway key pair, the page's requests to the deployed
        worker's address intercepted so nothing reaches it — rings it through Google's push
        service, which accepts the empty push; with no Haven page open, the service worker shows
        "Haven — Something new is waiting for you."; switching it off unsubscribes, and the
        worker drops the endpoint the next time it tries it. Run by hand: it needs real Chrome
        and the internet.
      - [ ] Not tested: Firefox, Safari and Edge (their push services are on the allow-list;
            only Chrome's was exercised), and the DEPLOYED worker, which does not have this
            code or a key pair yet.
      - Not built: telling a call from a post in the notification (a push has no payload to say
        which), and Safari on iPhone, which only offers Web Push to a site added to the Home
        Screen.
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

- **Push from a browser** — settled with Web Push: the push worker now answers browsers
  (`Access-Control-Allow-Origin: *`; it has no cookies and every route that changes anything is
  authorized by a signature in the body), so a post made in a browser wakes the other members'
  phones the way a post from an app does. It takes effect when the worker is deployed.
- **Engine restart.** The engine has no shutdown; the desktop app relaunches after linking, and a
  tab reloads. Fine, but it means every "switch identity / unlink" path in a browser is a reload.

## History — why it was abandoned (2026-06-22)

Browsers cannot accept inbound connections or do raw UDP/QUIC, so a tab can never hole-punch into
the mesh. The only shape that could work was a thin client of a publicly-hosted WSS → iroh bridge,
which meant "a server everyone depends on" — the thing Haven exists to avoid. The `web/engine/`
client was removed, and `core/haven-wasm` was deleted in the 2026-07 security audit (it recommended
storing the seed in `localStorage`). The "open a tab to keep your circle warm" idea became the
in-app RelayHost and `haven-relay`; the second platform became native Android.
