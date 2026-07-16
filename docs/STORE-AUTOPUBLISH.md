# Auto-publishing Haven to the app stores

Haven's CI can submit every tagged release to **Google Play** (Android) and the **Microsoft
Store** (Windows) automatically. Both are **gated on secrets** — until you add them, the store
steps skip and tagged releases just produce the usual sideloadable artifacts. Nothing here costs
a recurring fee beyond the one-time developer-account registrations.

Tag a release as today (`git tag v0.1.1 && git push --tags`); the store jobs light up once the
secrets below exist.

---

## Google Play (Android → `.github/workflows/android.yml`)

Builds a signed **AAB** on `v*` tags and publishes it to the **internal** track.

### One-time setup (yours)
1. **Play Console** → create the app `com.blaineam.haven` (one-time, $25 lifetime fee).
2. **Generate an upload keystore** (if you don't have one):
   ```bash
   keytool -genkey -v -keystore haven-upload.keystore -alias haven \
     -keyalg RSA -keysize 2048 -validity 10000
   ```
   Enroll it under **Play App Signing** (Console asks on first upload).
3. **First release must be manual.** Google won't let the API create an app's *very first*
   release — upload one AAB by hand to the internal track in the Console. After that, CI takes over.
4. **Play Developer API access:** Console → *Setup ▸ API access* → link a Google Cloud project →
   create a **service account** → grant it *Release* permissions (Admin → Users & permissions, add
   the service-account email with "Release to testing tracks"). Download its **JSON key**.

### Secrets to add (repo → Settings ▸ Secrets ▸ Actions)
| Secret | What |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i haven-upload.keystore` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | e.g. `haven` |
| `ANDROID_KEY_PASSWORD` | key password |
| `PLAY_SERVICE_ACCOUNT_JSON` | the full service-account JSON (paste the file contents) |

The keystore must be the **same one** Play App Signing was enrolled with. `versionCode` is set to
the workflow run number per release, so it always increases. To promote internal → production,
change `track: internal` in `android.yml` (or promote in the Console).

---

## Microsoft Store (Windows → `.github/workflows/release.yml`, `desktop` job)

Packages an **MSIX** from the Tauri build on `v*` tags and submits it via the **Microsoft Store
Developer CLI**. The Store re-signs the package, so **no paid code-signing certificate is needed** —
the one-time developer-account fee (~$19 individual) is the only cost, and Store apps install with
no SmartScreen warning.

### One-time setup (yours)
1. **Partner Center** → register as a developer → **reserve the app name** "Haven". Note the
   **Product identity** (Product management ▸ Product identity):
   - `Package/Identity/Name` → `STORE_IDENTITY_NAME`
   - `Package/Identity/Publisher` (the `CN=…` string) → `STORE_PUBLISHER`
   - `Publisher display name` → `STORE_PUBLISHER_DISPLAY`
   - the **Store ID** (the app's ID) → `STORE_APP_ID`
2. **Azure AD app for the submission API:** Partner Center ▸ *Account settings ▸ User management ▸
   Azure AD applications* → add an app → grant it **Manager** role → create a client secret.
   Collect: **tenant ID**, **client ID**, **client secret**, and your **seller ID** (Account
   settings ▸ legal info / partner account).
3. **First submission may need to be manual** — create the app's first submission in Partner Center
   (listing, age rating, etc.). The API updates subsequent submissions.

### Secrets to add
| Secret | What |
|---|---|
| `STORE_IDENTITY_NAME` | Package identity Name from Partner Center |
| `STORE_PUBLISHER` | `CN=…` publisher string |
| `STORE_PUBLISHER_DISPLAY` | Publisher display name |
| `STORE_APP_ID` | the app's Store ID |
| `STORE_TENANT_ID` | Azure AD tenant ID |
| `STORE_CLIENT_ID` | Azure AD app client ID |
| `STORE_CLIENT_SECRET` | Azure AD app client secret |
| `STORE_SELLER_ID` | Partner Center seller ID |

The MSIX manifest is generated in CI from `desktop/msix/AppxManifest.xml.in` (nothing
identity-specific is committed). The `.msix` is attached to the GitHub Release **only as a
stopgap** while the Store listing isn't public yet: per Haven's channel policy the GitHub
Release carries just the Linux app + relay CLI, so once the Store is live, set the repo
variable `PUBLISH_WINDOWS_TO_GH = false` and the `.msi`/`.exe`/`.msix` stop riding the Release
(the Store becomes the sole Windows channel). See
[`RELEASING.md`](RELEASING.md#release-channels--what-goes-where).

> **Note:** the MSIX/Store path is new and can't be fully exercised without a Partner Center
> account, so expect to shake out the first tagged run (makeappx output, `msstore` flags, manifest
> identity). The Android/Play path is the more battle-tested of the two.

---

## TL;DR for a free 90-day launch
- **Windows:** ship via the **Store** (free signing, no warnings). Skip paid certs entirely.
- **Android:** **internal/closed** Play track during the free beta; flip to production when ready.
- **macOS/iOS:** TestFlight + the notarized direct-download `.dmg` (already wired).
