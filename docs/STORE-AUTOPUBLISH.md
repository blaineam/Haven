# Auto-publishing Haven to the app stores

Haven's CI can push every tagged release — **the signed binary *and* the store listing** — to
**Google Play** (Android), the **Microsoft Store** (Windows) and the **App Store** (iOS + macOS,
built by Xcode Cloud, submitted by `apple-store.yml`), and can promote Android all the way to
production. All three are **gated on secrets**: until you add them, the store steps skip and
tagged releases just produce the usual sideloadable artifacts. Nothing here costs a recurring fee
beyond the one-time developer-account registrations. Haven is **free** on every store (August
2026) — the only price-related step left is the one-time change in each console.

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

| Tag | Google Play | Apple | Microsoft Store |
|---|---|---|---|
| `v1.3.0-rc.1` | `internal` **and** `alpha` (closed testing) | TestFlight internal (Xcode Cloud, off the push — not the tag) | MSIX packaged, not submitted |
| `v1.3.0` | `production` | **submitted for review** (iOS + macOS) by `apple-store.yml` | `msstore publish` when `MSSTORE_PUBLISH=true` |

Promoting an rc is just tagging the same commit again without the suffix. Nothing is rebuilt from
different source; the number that was in testers' hands is the number that ships.

**The rc guard overrides everything, including you.** An rc tag is forced to `internal` even if
`PLAY_TRACK` or a manual `play_track` input asked for `production`, `beta` or `alpha`. Asking for
production while tagging a release *candidate* is a contradiction, and the safe reading of a
contradiction is "testers only".

**Apple's production step is automated from the same tag** — see below for what it does and how it is gated.

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

Xcode Cloud still does **every** Apple build — it is the only place Haven's iOS/macOS binaries come
from, and a push to `main` that touches `apple/`, `core/` or `ci_scripts/` lands on TestFlight
internal on its own. What the tag adds is the App Store **submission**:

| Step | Who | When |
|---|---|---|
| Build + upload to TestFlight **internal** | **Xcode Cloud** | every push to `main` — no tag involved |
| Create the App Store version, set What's New, attach the build, submit for review | **`apple-store.yml`** → `Scripts/asc-autosubmit.mjs` | a plain `vX.Y.Z` tag (an `-rc.N` tag does nothing on Apple) |

### What the job does (on every `vX.Y.Z` tag, once the secrets exist)

1. **Finds the Xcode Cloud run for the tagged commit** — by `sourceCommit`, not "newest". If XCC
   never ran it (auto-cancel ate it, or the commit touched nothing XCC watches) the job **starts
   one on the tag** (falling back to `main` when main's tip *is* that commit) and waits.
2. **Waits** for the run to `SUCCEEDED` and for both uploads (iOS + macOS) to reach `VALID` —
   confirmed on `/v1/builds/{id}`, never the list (the list can say VALID mid-processing).
3. **Version + notes.** Finds or creates the editable App Store version `X.Y.Z` per platform (an
   abandoned draft with another number and no build attached is renamed — ASC allows one editable
   version per platform). Sets **What's New** on every localization from
   `appstore-metadata.md` / `appstore-metadata.<locale>.md`.
   **Gate:** the en-US `## whats_new` must *start with* `X.Y.Z` — otherwise the job fails rather
   than ship last release's notes. A locale file still on an older version gets the English notes,
   with a warning in the run summary.
4. **Attaches** the build; if ASC still wants an export-compliance answer on it, answers **exempt**
   (matches `ITSAppUsesNonExemptEncryption = NO` in the Info.plist).
5. **Submits** through `reviewSubmissions`. Already `WAITING_FOR_REVIEW`/`IN_REVIEW` for this
   version = success; a wedged `UNRESOLVED_ISSUES` submission is reported with the fix, never
   reused.

Every step is idempotent — re-run a failed workflow and it picks up where it was. The run summary
lists the XCC run number, the build numbers, and the per-platform outcome.

### Secrets + variables

| Secret | What |
|---|---|
| `ASC_API_KEY_ID` | App Store Connect API key id (`AuthKey_<id>.p8`) — the key needs the **App Manager** role (Developer can't create a version or open a submission) |
| `ASC_API_ISSUER_ID` | the issuer id (Users & Access → Integrations) |
| `ASC_API_KEY_P8` | the `.p8` file contents — raw PEM or base64 |

Absent → the job prints a notice and skips; submit by hand with `Scripts/asc-new-version.mjs`
(below). Set them from the machine that holds the key:

```bash
gh secret set ASC_API_KEY_ID   --body "<key id>"
gh secret set ASC_API_ISSUER_ID --body "<issuer id>"
gh secret set ASC_API_KEY_P8   < ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8
```

| Variable | What |
|---|---|
| `APPLE_STORE_SUBMIT` | `false` → do everything except press submit (version + notes + build attached; you submit from ASC). Unset = submit. |

### Running it by hand

- **Dry run from your machine** (reads XCC + ASC, writes nothing):
  `Scripts/asc-autosubmit.mjs --version 1.6.1 --commit $(git rev-parse v1.6.1^{commit}) --dry-run`
- **Manual dispatch** on Actions ▸ apple-store with a version (and optionally a commit / dry run) —
  for re-submitting a tag that was pushed before the secrets existed.
- **The old by-hand path** still works:
  ```bash
  Scripts/asc-new-version.mjs --platform IOS    --version 1.3.0 --build latest --wait 30 \
      --notes-file whatsnew.txt --submit
  Scripts/asc-new-version.mjs --platform MAC_OS --version 1.3.0 --build latest --wait 30 \
      --notes-file whatsnew.txt --submit
  ```

### Why this is safe to automate now

The earlier reasoning — "an App Store version can't be reused, rewound, or un-submitted, so
submitting must be a decision, not a side effect of a tag" — still holds. What changed is that the
tag *is* the decision: `vX.Y.Z` already ships to Play production, and the two-hop `-rc.N` → plain
tag flow exists precisely so the candidate is exercised first. The remaining risks are fenced:
the notes gate stops stale release notes, the commit match stops shipping code the tag never
pointed at, `APPLE_STORE_SUBMIT=false` keeps a staged-not-submitted mode, and a submission can
still be pulled from App Store Connect (Remove from Review) before a reviewer picks it up.

### One-time manual setup (you must do this by hand)

These are Google's rules, not CI limitations — no API can do them:

1. **Play Console** → create the app `com.blaineam.haven` (one-time $25 lifetime fee).
   **Price: Free** (Monetize ▸ Products ▸ App pricing). Haven went free in August 2026 (switched in
   the console 2026-08-23); this is a one-way door on Play — a free app can never be made paid
   again — and there is no API for it, so it was a one-time console step.
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

CI packages an **MSIX** from the Tauri build, and — with the repo variable **`MSSTORE_PUBLISH`** set
to `true` — runs `msstore publish` on a plain `vX.Y.Z` tag: opens a new submission with the package,
commits it, and the Store runs certification automatically. Without the variable the MSIX is
packaged and a `::notice` reminds you to upload it by hand.

The Store re-signs the package on ingestion, so **no paid code-signing certificate is needed** — the
one-time developer fee (~$19 individual) is the only cost, and Store apps install with no SmartScreen
warning.

**Bundled `cloudflared.exe`:** the MSIX Pack step copies Tauri's `externalBin` helper next to
`Haven.exe` so Quick Tunnel works without a user-installed CLI. It is **not** Authenticode-signed
in CI — Partner Center re-signs every PE in the package on upload, the same as `Haven.exe`. Do not
add a `signtool` step for it.

### Turning the automation on (one-time)

`msstore publish` over GitHub Actions supports **free products only** (paid "in a future release"
per Microsoft). Haven is free now, so the step works — but only once the Partner Center listing
agrees:

1. **Partner Center** → Haven → **Pricing and availability** → Base price → **Free** → save and
   submit that change (it is its own submission; Partner Center allows **one open submission at a
   time**, so let it certify before tagging). *Done 2026-08-23.*
2. Repo → Settings ▸ Secrets and variables ▸ Actions ▸ **Variables** → `MSSTORE_PUBLISH` = `true`.
   *Set 2026-08-23 — the next `vX.Y.Z` tag publishes to the Store.*

The step is **not** `continue-on-error`: a Store-side failure goes red on the Windows leg. That is
deliberate — the previous wiring reported a green job while submitting nothing, and a release once
went to review believing the Store was done when it wasn't. The Linux app + relay CLI still publish
(the `publish` job only needs the artifacts, which are uploaded before this step).

### Submitting by hand (when `MSSTORE_PUBLISH` is not set)

1. **Partner Center** → Haven → **Packages** → upload the `Haven-<ver>.msixbundle` from the run's
   `desktop-windows` artifact (`gh run download -n desktop-windows`).
2. **Store listings (en-US)** → paste this version's **What's new**. **Clear the field first**, then
   paste and **Save** — Partner Center only re-validates on an *actual* change, so an identical
   re-paste is a no-op that can leave the section stuck **"Incomplete"** with no error shown.
3. **Submit for certification.**

### What `msstore publish` does and doesn't do

- It does **not** set listing text/screenshots per-field — there is no flag for description,
  screenshots, features, or age rating. Every package update **carries them forward unchanged**,
  so the What's-new text is either pasted in Partner Center or pushed with
  `rocket meta Haven --store ms` *between* package submissions.
- **The app must already be live** before an update can be pushed, and Partner Center allows only
  **one open submission at a time** — a listing edit in flight makes the publish step fail.

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
2. Once the app is live and the Partner Center price is Free, set `MSSTORE_PUBLISH=true`; every
   `vX.Y.Z` tag's `msstore publish` then pushes the new package → certification → live.
3. Listing-text changes remain the separate, on-demand `updateMetadata` flow above.

## TL;DR
- **Windows:** ship via the **Store** (free signing, no warnings). Package publish is automated
  behind `MSSTORE_PUBLISH`; listing text is Partner-Center-side.
- **Android:** the repo drives the **full listing** and the binary; promote `internal → closed →
  production` with a variable or a manual run.
- **macOS/iOS:** Xcode Cloud builds every push to `main` → TestFlight; a `vX.Y.Z` tag submits
  both platforms for review from that exact commit's build (`apple-store.yml`).
