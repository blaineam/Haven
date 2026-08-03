# Auto-publishing Haven to the app stores

Haven's CI can push every tagged release — **the signed binary *and* the full store listing** — to
**Google Play** (Android) and the **Microsoft Store** (Windows), and can promote Android all the
way to production. Both are **gated on secrets**: until you add them, the store steps skip and
tagged releases just produce the usual sideloadable artifacts. Nothing here costs a recurring fee
beyond the one-time developer-account registrations.

Tag a release as usual (`git tag v1.0.5 && git push --tags`); the store jobs light up once the
secrets below exist.

> **The one honest caveat up front.** No CI can do the *very first* submission on either store, and
> neither store lets an API answer the compliance questionnaires (Play **Data Safety** + **content
> rating**; the Store **age rating**). Those are one-time, by-hand steps. Do them once (the
> [checklists below](#one-time-manual-setup-you-must-do-this-by-hand)), and from then on CI keeps
> both the binary and the listing in sync and can promote to production on demand.

---

## Google Play (Android → `.github/workflows/android.yml`)

### What CI automates (on every `v*` tag, once the secrets exist)

| Thing | How | Tool |
|---|---|---|
| Signed **AAB** upload | to the resolved track | `r0adkll/upload-google-play@v1` |
| **What's-new** (release notes) | `changelogs/<versionCode>.txt` → falls back to `changelogs/default.txt` | same action, `whatsNewDirectory` |
| **Title, short + full description** | `android/fastlane/metadata/android/en-US/*.txt` | `fastlane supply` |
| **Feature graphic + screenshots** | `…/en-US/images/` (`featureGraphic.png`, `phoneScreenshots/`) | `fastlane supply` |
| **Track promotion** (`internal`→`alpha`/`beta`→`production`) | a repo variable or a manual run | `r0adkll` `track` |
| **Staged production rollout** | `userFraction` + `status=inProgress` | `r0adkll` `userFraction` |

The listing text/images all live under **`android/fastlane/metadata/android/en-US/`** — one source of
truth, edited in the repo. (`r0adkll` itself only uploads the binary + release notes; it has *no*
inputs for title/description/graphics, so `fastlane supply` — which reads that exact fastlane layout —
does the rest. Both run in the same job.)

> Google caps the "what's new" note at **500 characters per language**. `changelogs/default.txt` is
> kept under that; a longer note makes the upload step warn (it's non-fatal) rather than publish.

### The tag decides the channel

**A release candidate goes to testers. A release goes live.** That is the whole policy, and the
`-rc.N` suffix on the tag is what says which one this is — on *both* stores, so an rc can't be live
on one platform and in testing on the other.

| Tag | Google Play | Apple |
|---|---|---|
| `v1.3.0-rc.1` | `internal` **and** `alpha` (closed testing) | TestFlight internal, via Xcode Cloud |
| `v1.3.0` | `production` | App Store review, via `apple-store.yml` |

Promoting an rc is just tagging the same commit again without the suffix. Nothing is rebuilt from
different source; the number that was in testers' hands is the number that ships.

**The rc guard overrides everything, including you.** An rc tag is forced to `internal` even if
`PLAY_TRACK` or a manual `play_track` input asked for `production`, `beta` or `alpha`. Asking for
production while tagging a release *candidate* is a contradiction, and the safe reading of a
contradiction is "testers only". The same gate is the first thing `apple-store.yml` checks — an rc
tag never opens an App Store submission at all.

Two overrides remain, for the off-schedule cases (neither can defeat the rc guard):

1. **One-off:** Actions ▸ **android** ▸ *Run workflow* ▸ set **`play_track`** (and optionally
   **`play_rollout`** to e.g. `0.1` for a 10 % staged rollout). This re-uploads the *current*
   version to that track once. A tag never reads these inputs.
2. **Standing:** set the repo variable **`PLAY_TRACK`** (Settings ▸ Secrets and variables ▸ Actions
   ▸ Variables). *Every* subsequent tag is then pinned to that track instead of choosing its own.
   Optionally set **`PLAY_USER_FRACTION`** for a standing staged rollout. Unset both to return to
   "the tag decides".

Resolution precedence (implemented in the *"Resolve Play version + track"* step):

```
workflow_dispatch play_track   →   PLAY_TRACK variable   →   the tag's own channel (rc ? internal : production)
                                                             …then the rc guard, which nothing overrides
```

A rollout fraction below `1.0` flips the release to `status=inProgress` (Play staged rollout); blank
or `1.0` publishes fully live (`status=completed`).

---

## Apple (iOS + macOS → `.github/workflows/apple-store.yml`)

Apple's pipeline is split between two systems, and it helps to know which does what:

| Step | Who | When |
|---|---|---|
| Build + upload to TestFlight **internal** | **Xcode Cloud** | every push to `main` |
| Create the App Store version, attach the build, set "What's New", submit for review | **`apple-store.yml`** | a plain `v*` tag only |

So testers are served by Xcode Cloud with no tag at all — which is why an rc tag has nothing to do
on Apple, and the workflow's first step is to notice the `-rc.` and stop.

The build number can't be known in advance (Xcode Cloud assigns it from its own counter, minutes
after the push), so the submit doesn't try to guess: `Scripts/asc-new-version.mjs --build latest
--wait 60` polls App Store Connect for the newest **VALID** build of that marketing version and
attaches whatever XCC produced. If none appears within the window the job fails loudly rather than
submitting something else.

Release notes come from the *same* file Play's do
(`android/fastlane/metadata/android/en-US/changelogs/default.txt`), so the two stores can't describe
the same release differently.

### Secrets

| Secret | What |
|---|---|
| `ASC_API_KEY_ID` | App Store Connect API key id |
| `ASC_API_ISSUER_ID` | its issuer id |
| `ASC_API_PRIVATE_KEY` | the `.p8` contents, verbatim (`-----BEGIN PRIVATE KEY-----` …) |

Missing any of them and the job skips with a notice; the release still stands and can be submitted
by hand with the same script. The key needs the **App Manager** role — Developer can't create an
App Store version or open a review submission.

> Apple still owns the parts no API can do: export compliance answers that aren't already declared
> in the plist, a first submission of a brand-new app, and anything review comes back asking for.

### One-time manual setup (you must do this by hand)

These are Google's rules, not CI limitations — no API can do them:

1. **Play Console** → create the app `com.blaineam.haven` (one-time $25 lifetime fee).
2. **Upload keystore + Play App Signing.** Generate an upload keystore if you don't have one:
   ```bash
   keytool -genkey -v -keystore haven-upload.keystore -alias haven \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
   Enroll it under **Play App Signing** (the Console asks on first upload). CI must use this *same*
   keystore.
3. **First release must be manual.** Google won't let the API create an app's *very first* release —
   upload one AAB by hand to the internal track in the Console. After that, CI takes over uploads.
4. **Data Safety form** (App content ▸ Data safety) — **manual, one-time.** Haven collects nothing,
   but you still have to declare that. The API cannot answer it; an unanswered form blocks *all*
   releases from going live.
5. **Content rating questionnaire** (App content ▸ Content ratings) — **manual, one-time.** Same
   deal: no API path, and an unrated app can't be promoted to production.
6. **Other App-content declarations** (target audience, ads, news, COVID, government) — **manual,
   one-time.** In particular the **advertising-ID** declaration, if unset, is a common cause of the
   Play upload step failing (it's non-fatal, so the GitHub Release still stands, but the Play release
   won't).
7. **Play Developer API access:** Console ▸ *Setup ▸ API access* → link a Google Cloud project →
   create a **service account** → grant it *Release* permissions (Users & permissions → add the
   service-account email, role "Release to production, exclude devices, and use Play App Signing", or
   at minimum "Release to testing tracks" for non-prod). Download its **JSON key**.

> The service-account role gates promotion: to have CI publish to **production**, the account needs
> the production release permission, not just testing-track access.

### Secrets + variables

| Secret (Settings ▸ Secrets ▸ Actions) | What |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i haven-upload.keystore` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | e.g. `haven` |
| `ANDROID_KEY_PASSWORD` | key password |
| `PLAY_SERVICE_ACCOUNT_JSON` | the full service-account JSON (paste the file contents) |

| Variable (Settings ▸ Variables ▸ Actions) — all optional | What |
|---|---|
| `PLAY_TRACK` | standing track for tags: `internal` (default if unset) / `alpha` / `beta` / `production` |
| `PLAY_USER_FRACTION` | standing staged-rollout fraction `0.0`–`1.0` (blank = full) |
| `PUBLISH_ANDROID_TO_GH` | **now set to `false`** — the APK/AAB are no longer attached to the GitHub Release. Google Play is the channel; the interim build is the short-retention `haven-android-apk` CI artifact. |

`versionCode` is the workflow run number (always increasing); `versionName` is the tag (or, on a
manual run, `apple/project.yml`'s `MARKETING_VERSION`).

---

## Microsoft Store (Windows → `.github/workflows/release.yml`, `desktop` job)

### What CI automates (on every `v*` tag)

CI packages an **MSIX** from the Tauri build and attaches it to the **GitHub Release**. That is all
it does for the Store — **submission is manual** (see below).

The Store re-signs the package on ingestion, so **no paid code-signing certificate is needed** — the
one-time developer fee (~$19 individual) is the only cost, and Store apps install with no SmartScreen
warning.

**Bundled `cloudflared.exe`:** the MSIX Pack step copies Tauri's `externalBin` helper next to
`Haven.exe` so Quick Tunnel works without a user-installed CLI. It is **not** Authenticode-signed
in CI — Partner Center re-signs every PE in the package on upload, the same as `Haven.exe`. Do not
add a `signtool` step for it.

### Submitting the update (MANUAL — do this by hand in Partner Center)

`msstore publish` is **not run in CI**, because it only supports **free** products over GitHub
Actions and **Haven is a paid listing** — the command exits non-zero and does nothing. It was
previously wired with `continue-on-error: true`, which reported a **green** job while submitting
nothing; a release once went to review believing the Store was done when it wasn't. So the step now
just prints a `::notice` reminder, and a human finishes it:

1. **Partner Center** → Haven → **Packages** → upload the `Haven-<ver>.msixbundle` from that tag's
   GitHub Release.
2. **Store listings (en-US)** → paste this version's **What's new**. **Clear the field first**, then
   paste and **Save** — Partner Center only re-validates on an *actual* change, so an identical
   re-paste is a no-op that can leave the section stuck **"Incomplete"** with no error shown.
3. **Submit for certification.**

Re-enable CI automation **only** once Microsoft ships paid-product support for `msstore publish` in
Actions (they've said "in a future release"). At that point, restore the submit step from git
history and drop its `continue-on-error` so a genuine failure goes **red** instead of false-green.

### Why `msstore publish` isn't wired (be clear-eyed about this)

- **Paid products aren't supported through GitHub Actions *yet*.** Per Microsoft's own docs, "app
  update operations through GitHub Actions is currently supported for **free products only**. Paid
  products will be supported in a future release." Haven is paid, so the command **exits non-zero
  and does nothing** — this is why submission is manual today, not a config we can fix.
- **Even when it works, it does not set listing text/screenshots per-field.** `msstore publish` has
  *no* flag for description, screenshots, features, or age rating. Those are whatever you set in
  Partner Center, and every package update **carries them forward unchanged** — which is why the
  What's-new text still has to be pasted by hand each release (Android, by contrast, drives listing
  text from the repo).
- **The app must already be live** before an update can be pushed, and Partner Center allows only
  **one open submission at a time.**

### Editing the Microsoft Store listing (optional, advanced, deliberately not wired)

`msstore` *can* update listing text non-interactively, but only via a JSON blob you first capture
from the live app — and because a metadata submission and a package submission can't be open at once,
it must not run in the same release. So it's left as a **separate, on-demand flow** rather than baked
into the tag pipeline:

```pwsh
# 1. Capture the current submission JSON (once), commit it as e.g. desktop/msix/store-listing.json:
msstore submission get <StoreId> | Out-File -Encoding utf8 store-listing.json
# 2. Edit the description/screenshots fields in that JSON.
# 3. Push the edit (its own submission → its own certification):
$md = Get-Content -Raw store-listing.json
msstore submission updateMetadata <StoreId> $md
msstore submission publish <StoreId>
```

Do this only when you actually want to change the listing text, and never while a package submission
is still in certification.

### One-time manual setup (you must do this by hand)

1. **Partner Center** → register as a developer → **reserve the app name** "Haven". Note the
   **Product identity** (Product management ▸ Product identity):
   - `Package/Identity/Name` → `STORE_IDENTITY_NAME`
   - `Package/Identity/Publisher` (the `CN=…` string) → `STORE_PUBLISHER`
   - `Publisher display name` → `STORE_PUBLISHER_DISPLAY`
   - the **Store ID** → `STORE_APP_ID`
2. **Azure AD (Entra) app for the submission API:** Partner Center ▸ *Account settings ▸ User
   management ▸ Microsoft Entra applications* → add an app → grant it the **Manager** role → create a
   client secret. Collect **tenant ID**, **client ID**, **client secret**, and your **seller ID**
   (Account settings ▸ identifiers / partner account).
3. **First submission must be manual** — create the app's first submission in Partner Center: the
   listing (description, screenshots, features), pricing, and the **age rating** questionnaire (no
   API path for the rating). The app must be **published and live** before CI can update it.

### Secrets

| Secret | What |
|---|---|
| `STORE_IDENTITY_NAME` | Package identity Name from Partner Center |
| `STORE_PUBLISHER` | `CN=…` publisher string |
| `STORE_PUBLISHER_DISPLAY` | Publisher display name |
| `STORE_APP_ID` | the app's Store ID |
| `STORE_TENANT_ID` | Entra tenant ID |
| `STORE_CLIENT_ID` | Entra app client ID |
| `STORE_CLIENT_SECRET` | Entra app client secret |
| `STORE_SELLER_ID` | Partner Center seller ID |

| Variable | What |
|---|---|
| `PUBLISH_WINDOWS_TO_GH` | **now set to `false`** — `.msi`/`.msix`/`setup.exe` are no longer attached to the GitHub Release. The Microsoft Store is the channel; the interim build is the short-retention `desktop-windows` CI artifact. |

The MSIX manifest is generated in CI from `desktop/msix/AppxManifest.xml.in` (nothing
identity-specific is committed). With `PUBLISH_WINDOWS_TO_GH = "false"` the Windows GUI installers
no longer ride the GitHub Release — the [Microsoft Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM)
(now live) is the channel, and the `desktop-windows` CI artifact is the interim download. See
[`RELEASING.md`](RELEASING.md#release-channels--what-goes-where).

> **Reality check:** the MSIX/Store path is newer than the Play path and can't be fully exercised
> without a Partner Center account + a first live submission, so expect to shake out the first tagged
> run (makeappx output, manifest identity, and the paid-product limitation above). The Android/Play
> path is the more complete of the two — it drives the full listing from the repo today.

---

## Straight-to-prod, once the one-time vetting is done

The user's goal is "straight to prod pipelines" after the initial vetting. Here's the exact path:

**Android**
1. Do the one-time manual setup above (first internal release by hand, Data Safety, content rating,
   App-content declarations, service account with **production** release permission).
2. Pass Play's **closed-testing** requirement (Play now requires a period of closed testing before a
   personal developer account can open production).
3. Then either set `PLAY_TRACK=production` (every tag ships to prod) **or** run the workflow by hand
   with `play_track=production` (+ `play_rollout` for a staged rollout) per release. Done — CI builds,
   uploads, syncs the listing, and rolls out.

**Windows**
1. Do the one-time manual setup (name reservation, Entra app, first live submission with listing +
   age rating).
2. Once the app is live, every `v*` tag's `msstore publish` pushes the new package → certification →
   live automatically **(subject to Microsoft enabling paid-product GitHub-Actions publishing; until
   then this step may no-op — the GitHub Release is unaffected).**
3. Listing-text changes remain the separate, on-demand `updateMetadata` flow above.

## TL;DR for a free launch
- **Windows:** ship via the **Store** (free signing, no warnings). Package publish is automated;
  listing text is Partner-Center-side.
- **Android:** the repo drives the **full listing** and the binary; promote `internal → closed →
  production` with a variable or a manual run.
- **macOS/iOS:** TestFlight + the notarized direct-download `.dmg` (already wired).
