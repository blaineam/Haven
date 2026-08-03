# The reach-me link / QR system

## The core idea

**Your public key is your permanent address.** You don't need a server to "host
you": iroh's discovery publishes a *signed* record of your current network location
to the **mainline DHT** (the decentralized DHT BitTorrent uses — no central
directory), keyed by your Ed25519 public key. Anyone who has your key can always find
your current address, even as you move between networks. So a link can be permanent
with zero backend.

## Anatomy

```
https://haven.link/u/<base32-id>#<base32-verify>
        └─ Universal Link ─┘     └─ stays in the fragment ─┘

haven://u/<base32-id>#<base32-verify>     (deep link / QR form)
```

| Part | Bytes | Purpose |
|---|---|---|
| `id` | 32 | Ed25519 public key = routable node id; resolved to a live address via DHT discovery |
| `verify` (fragment) | 16 | BLAKE3 hash of the *full* hybrid key bundle (Ed25519 + X25519 + ML-KEM); tamper/MITM check |

Three deliberate properties:

1. **The id is the whole address.** No lookup table, no account row. Works forever.
2. **The sensitive part lives in the `#fragment`**, which browsers never send to the
   server — so even the page hosting the link sees nothing. Honors "collect no data"
   at the protocol level.
3. **Graceful degradation.** On a phone with the app → opens the app (Universal Link
   / App Link). Without the app → a static **invite-landing page** (`web/index.html`)
   that promotes installing the native app. (There is no web *client* — a browser can't
   be an iroh peer; see [`WEB-PARITY.md`](WEB-PARITY.md).)

## Post links

Sharing a post produces a **web** link, so it crosses the iOS/Android boundary and
survives being pasted into any chat app:

```
https://wemiller.com/apps/haven/open/#p/<circleId>.<postId>
                    └─ landing page ──┘  └─ never leaves the browser ─┘

haven://p/<circleId>/<postId>            (legacy / custom-scheme form — still accepted)
```

`/open` is the **dedicated deep-link landing page** and the only path the apps claim — see
"Which pages open the app" below. Links in the older `/apps/haven/#…` shape are still *parsed*
(every platform matches on the wider `/apps/haven` prefix), so anything already shared keeps
resolving; those just no longer auto-launch the app.

Same rules as the identity link, for the same reasons:

* **The payload is in the `#fragment`.** A browser never sends the fragment to the
  server, so wemiller.com's logs — and every CDN and proxy on the way — see only
  `GET /apps/haven/`. They cannot learn *which* post was opened, or by whom. A path
  form (`/apps/haven/p/<circle>/<post>`) would hand the host a readership map: reader
  IP × circle × post. That map is precisely what Haven exists not to create. **Do not
  "tidy" the fragment into a path.**
* **The link is a pointer, not a capability.** It carries no key. Access is governed
  entirely by circle membership in the core: a device already in the circle decrypts
  the post as usual, and everyone else — including anyone who intercepts the link —
  gets "post not found". Nothing about the link grants access, so a leaked link leaks
  only the fact that *some* post exists.
* **Locked circles stay locked.** A post link into a biometric-locked circle routes to
  the lock screen, never to the post.
* **Graceful degradation.** With the app installed the link opens it directly
  (Universal Link / App Link). Without it, the static page shows an "open in Haven /
  get Haven" card. The page resolves the fragment client-side and bounces to
  `haven://p/…`; no server-side compute anywhere.

The delimiters are `p/` and `.`, matching the invite link's `<id>.<verify>`. Both
tokens are percent-encoded with `.` and `/` excluded from the allowed set, so the split
is exact regardless of what an id contains.

## Post links *inside* the app: sharing a post as a story

Sharing a post **as a story** does not use a URL at all. A URL would be the wrong tool: it would have to
be parsed, percent-decoded, and round-tripped through the OS just to move between two screens of the same
app. Instead the story's own `body` carries a structured reference, `StoryEmbed`
(`apple/HavenApp/StoryEmbed.swift`):

```
⁣haven-embed:v1|<circleId>|<postId>|<musicStartMs>⁣<visible caption>
└ U+2063 ┘                                        └ U+2063 ┘
```

* **No engine or FFI change.** A story is already an ordinary post with `story: true`; the embed is a
  body convention, so it rides the existing wire format and every platform can adopt it independently.
* **U+2063 (INVISIBLE SEPARATOR)** wraps the token so it never renders, and delimits it exactly.
* **It nests OUTSIDE `StoryCaptions`.** The composer emits a `StoryCaptions` body (`\u{1}spec\u{1}text`)
  and the embed wraps that whole thing. So every read of a story body must call `StoryEmbed.strip(_:)`
  *before* `StoryCaptions.decode(_:)` — `StoryCaptions` falls back to "the entire string is the caption"
  on input it doesn't recognize, so skipping the strip renders the raw token on screen.
* Tapping "View post" routes through the **same** internal route as a link
  (`DeepLinkRouter.openPost(circleId:postId:)`), so there is one code path for "show me this post",
  biometric-lock check included.

### Why this doesn't leak anything

Same rule as the web post link: **the ref is a pointer, not a capability.** It carries no key, and access
is still decided entirely by circle membership in the core.

The audiences also line up by construction. A story is published to the **active circle**
(`FeedStore.post`), and "Share as story" is only offered on a post in that same circle — so everyone who
can see the story is already in the circle that holds the post. There is no case where the embed widens
who can read something.

Two deliberate consequences:

* **The chip is drawn from the token alone, with no pre-flight access check.** Checking first would make
  the chip's presence a membership/existence oracle. The tap instead always lands somewhere honest.
* **`PostLinkView` gives ONE failure message** — "Post unavailable" — for deleted, unsent, and
  not-yours alike. Distinguishing them would answer "does this post exist?" for someone who shouldn't be
  able to ask. It waits ~1.5s before saying so, because the story and its source post can sync in either
  order.

### A post id in a link may name a COMMENT

`react`/`comment` in the core target **any event id**, so a reaction on (or a reply to) a comment
produces an activity row and a push whose `p` is the **comment's** id — and comments are not
top-level feed items, they live inside their parent. Resolution therefore has two steps, and every
client does both (`FeedStore.post` on Apple, `PostLinkScreen` on Android, `openPostLink` on desktop):

1. the item whose `id` matches, else
2. the item that **carries** a comment with that id.

Doing it in the lookup rather than at each call site is deliberate: activity rows, notification taps,
story embeds and pasted web links all funnel through it, so they cannot disagree. The linked comment
is then shown (never collapsed behind "show all N comments") and marked. Fixing it at the link-BUILD
end instead would have been strictly worse — every row and push already in the wild would stay broken.

## Which pages open the app

**Exactly one: `/apps/haven/open/`.** Everything else on the site — the marketing home page,
`/features/`, `/docs/`, `/relay/`, the download section — is ordinary web content and stays in the
browser.

This was not always true, and the bug it caused was very visible: the site *constantly* offered to
open Haven, on pages with nothing to do with app content. Two independent causes, one per platform:

| | What it matched | Why that misfired |
|---|---|---|
| **iOS / macOS** (AASA) | `/apps/haven/*` with `"#": "?*"` — *any* non-empty fragment | The site is full of its **own** in-page anchors: a `#main` skip link on every page, plus `#download`, `#privacy`, `#security`, `#pricing`, `#circles`, `#stories`, `#setup`… Every one of those looked exactly like a payload. |
| **Android** (App Links) | `pathPrefix="/apps/haven"` | Android App Links match on **scheme/host/path only — a fragment is never visible to the matcher**. The `"#"` gate that was supposed to save iOS simply does not exist here, so the whole subtree was claimed outright. |

A dedicated path is the only rule both platforms can express, so that is the fix:

* `web/.well-known/apple-app-site-association` → `/apps/haven/open*` (fragment gate kept as
  defense in depth).
* `android/app/src/main/AndroidManifest.xml` → `pathPrefix="/apps/haven/open"`.
* `web/open/index.html` → the landing page itself. It has **no nav and no in-page anchors**, by
  design: on this path every fragment is treated as a payload, so adding an anchor would
  reintroduce the bug. It also never navigates to `haven://` on load — only on an explicit tap.

**The payload still rides in the fragment.** `/open` is a *constant*, so wemiller.com's logs learn
only "some Haven link was opened" — which they already learned from the bare page load. They still
never learn *which* post, circle, or invite. Do not be tempted to put the payload in the path now
that there is a dedicated one; that would build the readership map this whole design avoids.

`assetlinks.json` is unchanged and stays host-wide (`handle_all_urls`) — that file is Android's
*ownership* proof for the domain, and path scoping is the manifest's job, not its.

> **Emitting vs. matching.** Each platform keeps these separate: it **emits** `/apps/haven/open`
> and **matches** the wider `/apps/haven` prefix. Narrowing the match too would orphan every link
> already pasted into someone's chat history.
> `apple/HavenApp/ConnectView.swift ▸ HavenSite`, `android/…/core/DeepLink.kt ▸ LINK_PATH`,
> `desktop/ui/app.js ▸ HAVEN_SITE`.

## Hosting the association files

Two static files make the phones open the app instead of the browser:

| File | Serves | Notes |
|---|---|---|
| `web/.well-known/apple-app-site-association` | iOS / macOS Universal Links | JSON, **no extension**, must be served as `application/json`, scoped to `/apps/haven/*` |
| `web/.well-known/assetlinks.json` | Android App Links (`autoVerify="true"`) | needs the **Play App Signing** SHA-256 fingerprint |

Both must be served from the **domain root** — `https://wemiller.com/.well-known/…` —
not from `/apps/haven/.well-known/…`. Apple and Google only ever look at the root. Since
this repo's `web/` is mirrored into the portfolio site *under `/apps/haven/`*, the two
files have to land at the root of whatever serves `wemiller.com` (see
`.github/workflows/notify-portfolio.yml`). They're kept here as the source of truth.

`.nojekyll` sits alongside them because GitHub Pages' Jekyll pass drops dotfiles, which
would silently delete `.well-known/` from the published site.

### Why `assetlinks.json` lists TWO fingerprints
>
> Android verifies the cert that signed the **installed** app. Haven reaches devices two
> ways, signed by two different keys, so `sha256_cert_fingerprints` lists both — drop
> either and that audience silently falls back to the "open with" chooser:
>
> | Install path | Cert on the device | Fingerprint |
> |---|---|---|
> | Google Play | Google's **app-signing** cert (Play strips the upload signature and re-signs) | `62:24:04:7F:…` |
> | Direct APK — the `haven-android-apk` CI artifact (no longer a public GitHub download) | the **release keystore** | `F7:22:EF:7C:…` |
>
> The release keystore and the Play **upload** key are the SAME key here: both
> `assembleRelease` (→ the CI-artifact APK) and `bundleRelease` (→ the Play AAB) sign
> with `ANDROID_KEYSTORE_BASE64` in `.github/workflows/android.yml`. So Play Console's
> "Upload key certificate" is also the direct-artifact APK's cert — which is why it
> belongs here even though Play itself never serves it. (Android is now store-only: the
> APK/AAB were removed from GitHub Releases, so the only direct build is the private CI
> artifact used for testing and the Play upload.)
>
> **Do not paste Play Console's generated Digital Asset Links JSON verbatim.** It lists
> only the app-signing cert, because Google has no idea Haven is also built as a
> direct APK. It is correct-but-incomplete for us.
>
> To re-derive either, UI-independently:
> ```
> # release keystore / upload key (the F7:22 one)
> keytool -list -v -keystore <release.keystore> -alias <alias> | grep -A1 'SHA256:'
>
> # Play app-signing cert (the 62:24 one), read off a build installed FROM PLAY
> adb shell pm path com.blaineam.haven      # → /data/app/.../base.apk
> adb pull <path> /tmp/play.apk
> apksigner verify --print-certs /tmp/play.apk | grep -i 'SHA-256'
> ```
> A *sideloaded* APK reports the keystore cert, not Google's — so that second one only
> works on a genuine Play install. In the console, SEARCH for "app signing" rather than
> following a menu path; the layout moves.
>
> Verification happens at INSTALL time, so existing installs won't re-verify until they
> update. Check with `adb shell pm get-app-links com.blaineam.haven` — you want
> `verified` beside wemiller.com. Anything else usually means the file isn't reachable at
> the domain root, or the installed build's cert isn't in the list.

## On your own website

Just drop an `<a href="https://yoursite/u/...#...">`. No backend. The only static
infra anywhere is a tiny `apple-app-site-association` / `assetlinks.json` file (zero
data, ~free static hosting) telling phones the domain opens the app. Host it on a
default `haven.link` domain *or* on your own site for your own links. Custom scheme
`haven://` is the no-domain fallback (loses the graceful web landing).

## Trust & the approval flow

A QR scanned in person is a strong anchor (nobody can MITM a screen you're looking
at). A link shared over the internet is weaker, so link-connects are **never
automatic**:

1. Someone uses your link → creates a **pending connection request**, inert until you
   approve. (Also the spam/abuse defense for a public link: anyone can knock, nobody
   gets in without you opening the door.)
2. On approval, both sides compare a **short verification phrase** derived from the
   `#fragment` — Signal's "safety number," made friendly — to confirm no tampering.

Implemented today in `link.rs`: encoding both forms, parsing, requiring the
verification fragment, and `HavenLink::matches()` (the tamper check against the
identity fetched from discovery).

## Two flavors of link

| | **Identity link** (on your website) | **Invite link** (private, scoped) |
|---|---|---|
| Carries | just your id | a signed, optionally expiring / single-use token |
| Use | "anyone can request to reach me" | "this link joins *the Miller Family* group, once" |
| Revoke | block per-requester | invalidate the token — link dies, key stays safe |
| Privacy | permanent (the point) | rotate / expire freely |

The identity link is permanent and safe because requests are inert until approved;
private invites are revocable capabilities you can hand out and kill individually.
Both are just bytes in a URL — no server holds them.

*(Invite-link tokens are designed but not yet implemented; `HavenLink` currently
covers the identity link. Token format is an open item in `THREAT-MODEL.md`.)*
