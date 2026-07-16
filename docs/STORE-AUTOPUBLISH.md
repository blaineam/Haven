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

### Track promotion — how you say "go to production"

**The safe default is `internal`.** A routine `v*` tag with nothing else configured *always* ships
to the internal track — it can never accidentally hit production. Promotion is a deliberate act, one
of two ways:

1. **One-off, per-release (recommended for prod):** Actions ▸ **android** ▸ *Run workflow* ▸ set
   **`play_track`** to `beta` or `production` (and optionally **`play_rollout`** to e.g. `0.1` for a
   10 % staged rollout). This rebuilds the current version and uploads it to that track *once*. A tag
   never reads these inputs, so this can't leak into routine releases.
2. **Standing, for every tag:** set the repo variable **`PLAY_TRACK`** (Settings ▸ Secrets and
   variables ▸ Actions ▸ Variables) to `alpha`/`beta`/`production`. *Every* subsequent tag then
   targets that track — persistent and deliberate. Optionally set **`PLAY_USER_FRACTION`** (e.g.
   `0.1`) for a standing staged rollout. Unset both to return to the safe `internal` default.

Resolution precedence (implemented in the *"Resolve Play version + track"* step):

```
workflow_dispatch play_track input   →   PLAY_TRACK variable   →   "internal"   (safe default)
```

A rollout fraction below `1.0` flips the release to `status=inProgress` (Play staged rollout); blank
or `1.0` publishes fully live (`status=completed`). With no variable set and no dispatch inputs, the
resolved target is exactly the pre-existing behaviour: **`track=internal, status=completed`.**

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

### What CI automates (on every `v*` tag, once the secrets exist)

CI packages an **MSIX** from the Tauri build and submits it with the **Microsoft Store Developer CLI**
(`msstore`):

```
msstore reconfigure --tenantId … --clientId … --clientSecret … --sellerId …
msstore publish "<Haven-x.y.z.msix>" --appId <StoreId> --verbose
```

`msstore publish` opens a **new submission** containing the package and **commits** it → the Store
runs **certification automatically**, and once cert passes the update goes **live**. The Store
re-signs the package, so **no paid code-signing certificate is needed** — the one-time developer
fee (~$19 individual) is the only cost, and Store apps install with no SmartScreen warning. The
submit step is **non-fatal**, so a Store hiccup never blocks the Linux/relay GitHub Release.

### What `msstore` genuinely will NOT do (be clear-eyed about this)

- **It does not set listing text/screenshots per-field.** `msstore publish` has *no* flag for
  description, screenshots, features, or age rating. Those are whatever you set in Partner Center on
  the first submission, and every package update **carries them forward unchanged.** That's why the
  listing content lives in Partner Center for Windows (unlike Android, where the repo drives it).
- **Paid products aren't supported through GitHub Actions *yet*.** Per Microsoft's own docs, "app
  update operations through GitHub Actions is currently supported for **free products only**. Paid
  products will be supported in a future release." If Haven's Store listing is paid, the `msstore
  publish` step may no-op until Microsoft ships that support — which is exactly why the step is
  `continue-on-error`. Watch the step's log; when it starts succeeding, Windows is fully automated.
- **The app must already be live** before the CLI can push an update, and Partner Center allows only
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
