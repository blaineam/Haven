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
https://wemiller.com/apps/haven/#p/<circleId>.<postId>
                    └─ static page ─┘  └─ never leaves the browser ─┘

haven://p/<circleId>/<postId>            (legacy / custom-scheme form — still accepted)
```

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
