# Releasing Haven

How Haven is versioned and how a release is cut. If you only read one thing:

> **One product, one version.** `MARKETING_VERSION` in `apple/project.yml` is the source of
> truth. The git tag is `v<that>`. `release.yml` fails the build if they disagree.

---

## The scheme

Haven is **one product** that happens to be compiled for six places (iPhone, iPad, Mac,
Android, Windows, Linux) out of **one core**. A feature lands in `core/` and ships everywhere
at once; the CHANGELOG has one entry for it, not six. So it gets one version number.

**Plain semver `X.Y.Z`, plus one permitted pre-release suffix: `-rc.N`.** No `-beta`, no
`-alpha`, no build metadata. `-rc.N` earns its exception by being a *channel*, not a version
universe: `v1.3.0-rc.1` and `v1.3.0` are the same code and the same `MARKETING_VERSION`, and the
suffix only says who is allowed to see it (see [Cutting a release](#cutting-a-release)). The
`-beta` line is what created two version universes, and it stays gone.

### Why the Apple number wins

The number is set by `apple/project.yml` → `MARKETING_VERSION`, because App Store Connect is
the **slowest and least forgiving publisher in the set**: a version there is consumed by
review, can't be reused, can't be rewound, and is visible to users for as long as the build
lives. Every other channel (GitHub Releases, Play, the AUR, a `.deb`) can be re-cut in
minutes. So Apple sets the pace and everyone else follows — never the reverse.

This is the drift that motivated the scheme: as of `v0.1.0-beta.40` the **same commit** was
published as `0.1.0-beta.40` on GitHub and `1.0.4` on the App Store. Two version universes,
one product. A user on Linux and a user on iPhone could not say "I'm on Haven X" and mean the
same code. That's fixed by the gate in `release.yml`, not by convention.

### What carries the product version

| Thing | Version | Set by |
|---|---|---|
| App Store / TestFlight | **product** | `apple/project.yml` `MARKETING_VERSION` — **the source of truth** |
| git tag → GitHub Release | **product** | you: `git tag v<X.Y.Z>` |
| Android `versionName` | **product** | `android.yml`, from the tag (`${GITHUB_REF_NAME#v}`) |
| Desktop `.msi`/`.exe`/`.deb`/`.rpm`/AppImage/MSIX | **product** | `release.yml` stamps `desktop/src-tauri/tauri.conf.json` |
| `haven-relay` binary + `.deb` | **product** | `release.yml` (and `relay-release.yml`) stamps `core/haven-relay/Cargo.toml` |
| AUR `haven-desktop` / `haven-relay` `pkgver` | **product** | `release.yml`'s `aur` job stamps it from the tag |
| Flatpak / metainfo `<release version=…>` | **product** | `release.yml`'s `flatpak` job stamps `desktop/flatpak/com.blaineam.haven.metainfo.xml` from the tag |

### What deliberately does NOT

| Thing | Version | Why |
|---|---|---|
| Android `versionCode` | `github.run_number` | Play only requires it to **increase**, and it must do so even for two builds of the same `versionName`. A monotonic CI counter is exactly right; deriving it from the version would be fragile for no gain. |
| `core/*` crates (`haven-p2p`, `haven-net`, …) | `0.0.1`, unversioned | Never published to crates.io. They're internal to this repo and consumed by path. Versioning them would be ceremony with no consumer. (Also noted in `ROADMAP.md`.) |
| `desktop/src-tauri/Cargo.toml` `version` | `0.1.0`, cosmetic | `tauri.conf.json`'s `version` takes precedence for every bundle Tauri produces, and CI stamps that. The Cargo value is never user-visible. |

### Should the desktop app and the relay have their own versions?

They were genuinely arguable. Both follow the product version, for different reasons:

- **Desktop GUI — follows.** It is not a different product; it's Haven, compiled for
  Windows/Linux. Same core, same features, same CHANGELOG entry, released off the same tag on
  the same day. Giving it a private number would recreate exactly the two-universe problem
  this scheme exists to kill. (Nothing structural changes here — `release.yml` already
  stamped the tag into `tauri.conf.json`; it just gets an honest number now.)
- **Relay daemon — follows, because it's protocol-coupled.** This is the interesting one. The
  relay looks like a separate product: separate deliverable, separate audience (admins, not
  App Store users), separate release path (`relay-v*`). The case for its own version is real.
  It loses to one fact: **the relay and the clients that talk to it must be the same
  release.** The CHANGELOG says so outright — beta.37's roster change "Requires the relay AND
  the app on beta.37." When an admin has to answer "is my relay new enough for everyone's
  app?", a shared number answers it by inspection and a private number requires a
  compatibility table nobody will maintain. Shared version wins.

**Where this bites:** a Linux- or relay-only fix still bumps `MARKETING_VERSION`, because the
gate demands the tag match it. That's cheap — bumping the number costs nothing until you
actually submit to Apple, and you don't have to. It is deliberately *not* worth a second
version universe to avoid.

### The old tags

`v0.1.0-beta.1` … `v0.1.0-beta.40` **stay exactly as they are.** They're immutable published
history with real download counts against them. Nothing rewrites or deletes them. `1.0.5` is
simply the next tag; the `0.1.0-beta.*` line just ends. `1.0.5 > 0.1.0.beta.40` under both
dpkg and semver ordering, so `apt upgrade` and every installer upgrade path is monotonic
across the switch — verified, not assumed.

---

## Release channels — what goes where

Haven ships to six places, but they are not all the same *kind* of channel. Three of them are
**app stores that expect to be the distribution point**; two of them have **no store** and the
GitHub Release *is* their distribution point. (Haven is **free** on every store as of August
2026 — the channel policy is about *where* a platform's build comes from, not price.)

> **The GitHub Release carries ONLY the things that have no store: the Linux desktop app
> (`.deb` / `.rpm` / AppImage + `haven.flatpak`) and the `haven-relay` CLI for every arch.**
> iOS/macOS, Android, and Windows go through the App Store, Google Play, and the Microsoft
> Store. They must **not** accumulate a GitHub Release history.

| Platform | Proper channel | On the GitHub Release? |
|---|---|---|
| iPhone · iPad · Mac | **App Store** (TestFlight via Xcode Cloud; review submitted by `apple-store.yml` on a `vX.Y.Z` tag) | No — never was |
| Android | **Google Play** | No (once Play is public) — *stopgap until then* |
| Windows | **Microsoft Store** (live) | No — [live on the Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM) |
| Linux desktop GUI | *(no store)* → GitHub Release | **Yes** — `.deb` / `.rpm` / AppImage / `haven.flatpak` |
| Relay daemon (all arches, incl. Windows/macOS) | *(admin CLI, no store)* → GitHub Release | **Yes** — `haven-relay-<target>` + `.deb`s |

Note the relay row: `haven-relay-*-pc-windows-*.exe` is a self-host CLI for admins, **not** the
Store app, so it stays on the Release even after Windows comes off. The policy strips only the
Haven **desktop GUI** Windows installers (`.msi` / NSIS `-setup.exe` / `.msix`).

### Build vs. attach — the important distinction

The policy is about what gets **attached** to the public Release, **not** what CI builds. CI
**always builds** the Windows installers and the Android APK/AAB — the compile check depends on
it, the Microsoft-Store MSIX-submit and Google-Play-upload steps consume the artifacts, and both
stay available as normal CI artifacts (`desktop-windows`, `haven-android-apk`) for a manual store
upload. Only the *attach-to-Release* step is gated.

### Current state — the flip is DONE (both variables set to `false`)

Both paid GUI platforms have moved off GitHub Releases. The attach for each is governed by a
**repo variable** (repo → *Settings ▸ Secrets and variables ▸ Actions ▸ **Variables***), and
**both are now set to `false`**:

| Repo variable | Governs | Current value | Effect |
|---|---|---|---|
| `PUBLISH_WINDOWS_TO_GH` | Windows `.msi`/`.exe`/`.msix` on the Release (`release.yml` `publish` job) | **`false`** (set) | Stripped — Microsoft Store is the channel |
| `PUBLISH_ANDROID_TO_GH` | Android `.apk`/`.aab` on the Release (`android.yml`) | **`false`** (set) | Not attached — Google Play is the channel |

**Windows is live on the [Microsoft Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM).**
**Android is in Google Play review** (closed testing), so it is not a public store link yet but
goes live soon. iOS/macOS are genuinely live on the App Store, so they were never on GH and
nothing changes there.

Because the GUI installers are off the public Release *before* the store links are public, the
interim way to grab a build is the **short-retention CI artifact**, not a Release asset:

- **Windows** — `desktop-windows` artifact on the `release.yml` run (Actions → the run → Artifacts).
- **Android** — `haven-android-apk` artifact on the `android.yml` run.

These are private (repo-collaborator) downloads with a short retention, used for the Store/Play
submissions and manual testing — not a public distribution channel.

### What the variables do

1. **Windows** (`PUBLISH_WINDOWS_TO_GH = false`) — `release.yml`'s `publish` job runs
   `rm -f dist/*.msi dist/*.msix dist/*setup.exe` before publishing, so Windows GUI installers
   don't ride the Release. The Windows relay `.exe`, all Linux artifacts, and everything else
   are untouched.
2. **Android** (`PUBLISH_ANDROID_TO_GH = false`) — `android.yml` skips both "Attach … to the
   GitHub Release" steps; the Play upload and the CI `haven-android-apk` artifact continue.

Each is a single repo-variable value — no code edit, no re-tag of old releases. Old tags keep
whatever assets they were published with; the switch only affects future releases.

---

## Cutting a release

Releases go out in **two hops: candidate, then promote.** Testers get the exact build that ships.

1. **Land the work.** Update `CHANGELOG.md` (one entry, all platforms).
2. **Set the version.** Bump `MARKETING_VERSION` in `apple/project.yml` (all targets — they
   must agree; the gate rejects the file if they don't).
3. **Push to `main`.** Xcode Cloud builds it and ships it to **TestFlight internal** on its own —
   no tag needed.
4. **Tag a candidate** and let people use it:
   ```bash
   git tag v1.3.0-rc.1 && git push origin v1.3.0-rc.1
   ```
   → Play **internal + closed (alpha)** testing. **Nothing goes to production, on either store** —
   the rc guard forces it, and it can't be overridden by a repo variable or a manual input.
5. **Promote** when the candidate holds up — tag the *same commit* without the suffix:
   ```bash
   git tag v1.3.0 && git push origin v1.3.0
   ```
   → Play **production**.
6. **Apple** — the same `vX.Y.Z` tag runs `apple-store.yml`, which submits **iOS + macOS** for
   review from the **Xcode Cloud build of that exact commit**: it finds the XCC run whose source
   commit is the tag's (starting one on the tag if auto-cancel ate it), waits for the run and for
   both uploads to finish processing, creates the App Store version, sets What's New on every
   localization from `appstore-metadata*.md`, attaches the build, and opens + submits the review
   submission. It is gated on three repo secrets (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`,
   `ASC_API_KEY_P8` — the key needs **App Manager**) and skips with a notice until they exist.

   **The notes gate:** `appstore-metadata.md`'s `## whats_new` must **start with the version**
   (`1.6.1 — …`) or the job fails instead of shipping last release's notes. A locale file that is
   still on an older version gets the English notes, loudly (summary + log) — translate first
   with `rocket loc translate Haven --locale big8 --provider claude` if you want it clean.

   Set the repo variable `APPLE_STORE_SUBMIT=false` to have the job do everything **except**
   press submit (version + notes + build attached; you submit from ASC). Every step is
   idempotent, so a failed run is just re-run; a version already `WAITING_FOR_REVIEW` is success.

   By hand, the old way still works (and is the fallback when the secrets aren't set):
   ```bash
   Scripts/asc-new-version.mjs --platform IOS    --version 1.3.0 --build latest --wait 30 \
       --notes-file whatsnew.txt --submit
   Scripts/asc-new-version.mjs --platform MAC_OS --version 1.3.0 --build latest --wait 30 \
       --notes-file whatsnew.txt --submit
   ```
   Or locally with the same CI script: `Scripts/asc-autosubmit.mjs --version 1.3.0 --commit
   $(git rev-parse v1.3.0^{commit}) --dry-run` to see what it *would* do.

7. **Windows** — with the repo variable `MSSTORE_PUBLISH=true` the same tag also opens and
   commits the Microsoft Store submission (`msstore publish`, free products only — Haven is
   free, so it works). Until that variable is set the MSIX is packaged and a notice reminds you
   to upload it in Partner Center.

Everything else rides the same tag. `release.yml` → relay binaries + `.deb`s, desktop installers,
Flatpak bundle + pinned manifest, the GitHub Release, and the AUR push. `android.yml` → APKs, AAB,
and the Play upload. All of it is gated: absent secrets skip cleanly instead of failing. Per the
**channel policy above**, the GitHub Release carries Linux + relay; the Windows/Android builds
live in their stores (see the `PUBLISH_*_TO_GH` toggles).

> **Nothing forces the two-hop.** Tagging `v1.3.0` directly still works and ships straight to
> production on every store — Play, the App Store review queue, and (when enabled) the Microsoft
> Store — it just skips the step where somebody else finds the problem first.

See `docs/STORE-AUTOPUBLISH.md` for the full track table and the overrides.

**Dry run:** `workflow_dispatch` on `release.yml` builds everything without publishing. Off a
branch with no input it builds whatever `MARKETING_VERSION` currently says.

**Relay-only hotfix:** tag `relay-v<X.Y.Z>` → `relay-release.yml` ships just the relay binaries
and `.deb`s. It stamps `core/haven-relay/Cargo.toml` from the tag exactly as `release.yml` does,
so `relay-v1.0.6` yields `haven-relay_1.0.6-1_amd64.deb` and `apt upgrade` moves users onto it.
The tag must be plain semver — same gate, same reason as below.

Unlike `release.yml` this path does **not** fail on drift from `MARKETING_VERSION`; shipping a
relay ahead of the App Store number is the entire point of it. It warns instead. Because the
relay is protocol-coupled to the clients, fold the hotfix number into the next `v*` release
rather than letting a relay-only line accumulate.

### The version gate

`release.yml`'s `meta` job is the enforcement point. It fails the release if:

- the tag isn't `vX.Y.Z` or `vX.Y.Z-rc.N` (so the `-beta` scheme can't come back by muscle
  memory — `-rc.N` is the only pre-release suffix that passes), or
- the tag doesn't match `apple/project.yml` `MARKETING_VERSION` (so the two universes can't
  drift apart again), or
- `apple/project.yml`'s targets disagree with each other about `MARKETING_VERSION`.

Fix by bumping `MARKETING_VERSION` and re-tagging — never by loosening the gate.

---

## AUR

`packaging/aur/haven-desktop` and `packaging/aur/haven-relay` are complete, tag-pinned
PKGBUILDs. `release.yml`'s `aur` job stamps `pkgver` from the tag, regenerates `.SRCINFO`,
lints with `namcap`, and pushes to `aur.archlinux.org` on every `v*` tag.

**Neither package exists on the AUR yet**, and CI cannot create them unattended — publishing
requires a personal AUR account. Until the secret below is set, the `aur` job skips cleanly
and the job stays green.

### What you must do by hand (one time)

1. **Make an AUR account** — <https://aur.archlinux.org/register>. This is *your* identity as
   maintainer; it can't be a bot or a shared credential.
2. **Make an SSH key for it** (a dedicated one, not your personal key):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/aur -C "aur@haven-ci" -N ""
   ```
3. **Add the public key** (`~/.ssh/aur.pub`) to your AUR account → *My Account* → *SSH Public
   Key*.
4. **Add the private key** (`~/.ssh/aur`, the whole file including the BEGIN/END lines) to
   GitHub → *Settings* → *Secrets and variables* → *Actions* → **`AUR_SSH_PRIVATE_KEY`**.

That single secret is the only one. There's no AUR username/token — the SSH key *is* the
authentication, and the `aur` user is universal.

5. **Verify** on the next tag: the `aur` job should push, and
   `git ls-remote https://aur.archlinux.org/haven-desktop.git` should return refs (today it
   returns nothing — that's how you know it isn't published).

The first push **creates** the package: cloning a nonexistent AUR package yields an empty
repo, and pushing to it registers the name. So no manual bootstrap is needed — but if you'd
rather claim the names by hand first:

```bash
git clone ssh://aur@aur.archlinux.org/haven-desktop.git && cd haven-desktop
cp -r /path/to/haven/packaging/aur/haven-desktop/. .
makepkg --printsrcinfo > .SRCINFO      # mandatory on the AUR; CI regenerates it
git add -A && git commit -m "haven-desktop 1.0.5" && git push origin HEAD:master
```

### Why the recipes look the way they do

- **Pinned to the tag** (`#tag=v$pkgver`), never a moving `HEAD`. A package without a `-git`
  suffix must build one specific reproducible revision — the old recipe tracked HEAD, which
  meant `pkgver=0.1.0` could build literally anything.
- **`sha256sums=('SKIP')` is correct here.** For a git source the tag is the integrity anchor.
  It would be *wrong* to switch to GitHub's auto-generated tag tarballs and checksum those —
  GitHub does not guarantee those archives are byte-stable, and AUR packages have broken on
  exactly that before.
- **`prepare()` runs `cargo fetch --locked`** so `build()` can run `--frozen` (offline,
  lockfile-exact) — the standard Arch Rust pattern. The old recipe's
  `cargo build --frozen 2>/dev/null || cargo build` silently fell back to an unlocked network
  build, which is not reproducible.
- **`LICENSE` is installed** to `/usr/share/licenses/$pkgname/` — required by Arch policy for
  a non-standard license (PolyForm Noncommercial is `LicenseRef-`, not a common SPDX id).
- **A 256×256 icon ships.** Tauri's `128x128@2x.png` *is* the 256px icon; the old recipe
  installed only 32 and 128, so icon themes had nothing to scale from.

---

## Flathub

**Status: packaging is done, submission is not — and the current manifest is not
submittable as-is.** This is not a small gap; see the blocker.

What already works: `release.yml` builds a real `haven.flatpak` and publishes a version-pinned
`desktop/flatpak/com.blaineam.haven.yml` with the real `.deb` sha256. That is a **sideload**
path — `flatpak install haven.flatpak` — and it's genuinely useful on the Steam Deck. It is
not a Flathub submission.

### There is no popularity gate

Worth stating because it's a common misconception (that's Homebrew's rule, not Flathub's).
Flathub has **no user-count or reputation threshold**. It does ask for "a meaningful history
of development or existence, evidence of real-world use and a clear commitment to ongoing
maintenance," and warns that apps "that have only existed for a very short period of time will
generally not be accepted." Haven clears that: shipping on the App Store since 1.0.0, 40
tagged releases, an active CHANGELOG. **Not a blocker.**

### The blocker: must build from source

Flathub requires that "**all source available submissions must be built entirely from source
code**." `com.blaineam.haven.yml` does `ar x haven.deb` — it unpacks a prebuilt binary. That
is a hard reject.

The `extra-data` escape hatch does **not** apply. It exists for *non-redistributable* sources;
Flathub's own docs note that an upstream author submitting their own app doesn't need it,
because redistribution permission is implicit. Haven's source is public — so the
build-from-source rule binds, regardless of PolyForm Noncommercial not being an OSI license.
(Flathub does host proprietary apps; that changes nothing about this rule.)

**The work required**, roughly in order:

1. A **second manifest** that builds from source (keep the `.deb` one for sideloading — it's
   doing a different job). Swap the `simple` module for a `cargo` build of
   `desktop/src-tauri`, pointing `frontendDist` at the in-tree static `ui/`. No Node toolchain
   needed in the sandbox — the UI is already static, which is a real advantage here.
2. **Vendor the crates offline.** Flathub builders have **no network access** during build.
   Generate `cargo-sources.json` with
   [`flatpak-cargo-generator`](https://github.com/flatpak/flatpak-builder-tools/tree/master/cargo)
   against `desktop/src-tauri/Cargo.lock` and add it as a source. This regenerates on every
   dependency bump — wire it into CI or it *will* go stale.
3. Confirm the **GNOME 47 runtime** still carries the WebKitGTK the Tauri WebView needs when
   building from source rather than consuming the `.deb`'s deps.

### Metainfo — done

`desktop/flatpak/com.blaineam.haven.metainfo.xml` is submission-ready; the four gaps that were
listed here are closed. What changed and what to keep in mind:

- **`<releases>` is stamped by CI.** It said `0.1.0` for 40 releases because it was
  hand-maintained. `release.yml`'s `flatpak` job now rewrites the `<release>` line from the tag
  before `flatpak-builder` runs, exactly like `tauri.conf.json`. The number in-tree only has to
  be right for local builds. That job also runs `appstreamcli validate` and **fails the
  release** on bad AppStream data — flatpak-builder only warns, a Flathub reviewer won't.
- **`project_license`** is now `LicenseRef-PolyForm-Noncommercial-1.0.0`, matching the
  PKGBUILDs and the actual LICENSE.
- **`<developer id="com.blaineam">`** is present.
- **`<screenshots>`** references three captures — `feed`, `thread`, `you`.
  ⚠️ **The hosting is the fragile part.** `desktop/screenshots/linux/` is **gitignored**
  capture scratch, so those files have no URL and can't be referenced. The copies that the
  metainfo actually points at live in **`web/assets/screenshots/linux/`**, which
  `static.yml` deploys to GitHub Pages (`https://blaineam.github.io/haven/assets/…`).
  **Re-capturing does not update the listing** — copy the new PNGs into `web/` too.
  (Not `https://wemiller.com/apps/haven/…`: that's the portfolio page, and it does not serve
  this repo's assets — the paths 404.)

Three of the six captures are deliberately **not** published:

| Capture | Why not |
|---|---|
| `invite` | Renders a real invite QR + `haven://invite?d=…#<key material>`. It's a throwaway demo identity, but a permanent public URL for a live invite link is not a thing to publish without a reason. |
| `editprofile` | Capture artifact — a stray "Edit profile" tooltip sits over the avatar. |
| `messages` | ~80% empty space at 1280×805; `thread` shows messaging properly. |

Fine as-is: app-id matches the `.desktop`/`identifier` (`com.blaineam.haven`) everywhere,
`launchable`, `content_rating`, `categories`, and both `url`s are present, and a 256px icon
exists.

### Permissions — should pass review

`finish-args` is already close to minimal and has **no `--filesystem=host`**, no `--talk-name=*`
wildcards, no `--device=all`. Camera and screen share go through portals rather than grabbing
`/dev/video*` raw, which is exactly what reviewers look for. Two notes:

- The four `--talk-name=org.freedesktop.portal.*` lines were **redundant** — portal access is
  granted to every Flatpak by default — and have been **dropped**. `org.freedesktop.secrets`
  and `org.kde.StatusNotifierWatcher` stay; those are not portals and are not default.
- `--filesystem=xdg-download` is justifiable (saving media) but a reviewer may push toward the
  file-chooser portal instead. Easy to defend or concede.

### Submitting (your call — not automated, and CI must not do it)

PR to [`flathub/flathub`](https://github.com/flathub/flathub) against the **`new-pr` branch**
(*not* `master`), titled `Add com.blaineam.haven`. Review is volunteer-run and batched, so
timing is unpredictable. Once merged, Flathub builds on **their** infrastructure from that
manifest — which is why step 2 above is non-negotiable.

---

## Notification / store secrets

Every publish step is gated on a secret and skips cleanly when absent, so a fresh clone builds
green with zero setup.

| Secret | Gates | Absent → |
|---|---|---|
| `AUR_SSH_PRIVATE_KEY` | AUR push | `aur` job skips |
| `ANDROID_KEYSTORE_BASE64` + `_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | signed APK/AAB | debug-signed APK instead |
| `PLAY_SERVICE_ACCOUNT_JSON` | Play internal track | upload skipped |
| `STORE_*` (8) | Microsoft Store MSIX | MSIX + submit skipped |
| `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8` | App Store submission (`apple-store.yml`) | job skips with a notice; submit by hand |

Separate from these secrets, two **repo variables** control the channel policy (see
[Release channels](#release-channels--what-goes-where)) — **both are now set to `false`**, so the
Windows and Android GUI builds no longer ride the public Release (they come off as short-retention
`desktop-windows` / `haven-android-apk` CI artifacts instead):

| Repo variable | Effect when `false` |
|---|---|
| `PUBLISH_WINDOWS_TO_GH` | Windows `.msi`/`.exe`/`.msix` no longer attached to the GitHub Release |
| `PUBLISH_ANDROID_TO_GH` | Android `.apk`/`.aab` no longer attached to the GitHub Release |

Two more variables gate the store submissions themselves:

| Repo variable | Default | Effect |
|---|---|---|
| `APPLE_STORE_SUBMIT` | unset (= submit) | `false` → `apple-store.yml` attaches the build and sets notes but does **not** press submit |
| `MSSTORE_PUBLISH` | unset (= manual) | `true` → `release.yml` runs `msstore publish` on a `vX.Y.Z` tag (set it after the Partner Center price is Free) |

⚠️ **Android `versionCode` trap:** it's `github.run_number`, which is per-workflow-file.
**Renaming or replacing `.github/workflows/android.yml` resets it to 1**, and Play permanently
rejects a `versionCode` at or below one it has already seen. If that file ever has to be
renamed, switch `versionCode` to an explicit offset first. (It's at ~483 as of 1.0.5.)
