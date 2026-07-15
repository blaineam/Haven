# Releasing Haven

How Haven is versioned and how a release is cut. If you only read one thing:

> **One product, one version.** `MARKETING_VERSION` in `apple/project.yml` is the source of
> truth. The git tag is `v<that>`. `release.yml` fails the build if they disagree.

---

## The scheme

Haven is **one product** that happens to be compiled for six places (iPhone, iPad, Mac,
Android, Windows, Linux) out of **one core**. A feature lands in `core/` and ships everywhere
at once; the CHANGELOG has one entry for it, not six. So it gets one version number.

**Plain semver `X.Y.Z`. No `-beta`, no `-rc`, no `-alpha` suffixes.**

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
| `haven-relay` binary + `.deb` | **product** | `release.yml` stamps `core/haven-relay/Cargo.toml` |
| AUR `haven-desktop` / `haven-relay` `pkgver` | **product** | `release.yml`'s `aur` job stamps it from the tag |
| Flatpak / metainfo `<release version=…>` | **product** | hand-updated (see [Flathub](#flathub)) |

### What deliberately does NOT

| Thing | Version | Why |
|---|---|---|
| Android `versionCode` | `github.run_number` | Play only requires it to **increase**, and it must do so even for two builds of the same `versionName`. A monotonic CI counter is exactly right; deriving it from the version would be fragile for no gain. |
| `core/*` crates (`p2pcore`, `haven-net`, …) | `0.0.1`, unversioned | Never published to crates.io. They're internal to this repo and consumed by path. Versioning them would be ceremony with no consumer. (Also noted in `ROADMAP.md`.) |
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

## Cutting a release

1. **Land the work.** Update `CHANGELOG.md` (one entry, all platforms).
2. **Set the version.** Bump `MARKETING_VERSION` in `apple/project.yml` (all targets — they
   must agree; the gate rejects the file if they don't).
3. **Apple** — cut the build (see `_shared/rocket`), submit for review.
4. **Tag** — the same number, with a `v`:
   ```bash
   git tag v1.0.5 && git push origin v1.0.5
   ```
5. CI does the rest. `release.yml` → relay binaries + `.deb`s, desktop installers, Flatpak
   bundle + pinned manifest, the GitHub Release, and the AUR push. `android.yml` → APKs, AAB,
   and the Play internal-track upload. Both are gated: absent secrets skip cleanly instead of
   failing.

**Dry run:** `workflow_dispatch` on `release.yml` builds everything without publishing. Off a
branch with no input it builds whatever `MARKETING_VERSION` currently says.

**Relay-only hotfix:** tag `relay-v*` → `relay-release.yml` ships just the relay binaries.
⚠️ **Known gap:** that workflow does *not* stamp a version, so its `.deb`s come out as
`haven-relay_0.0.1-1_*.deb` — older than anything `release.yml` publishes, so apt will not
upgrade to them. Prefer a normal `v*` release until that's fixed.

### The version gate

`release.yml`'s `meta` job is the enforcement point. It fails the release if:

- the tag isn't a plain `vX.Y.Z` (so the `-beta` scheme can't come back by muscle memory), or
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

### Metainfo — what's actually missing

`desktop/flatpak/com.blaineam.haven.metainfo.xml` is close. Required fixes:

- **`<releases>` is stale** — says `version="0.1.0" date="2026-06-23"`. Must reflect the
  released version.
- **`project_license`** is `LicenseRef-proprietary=https://…`. Should be
  `LicenseRef-PolyForm-Noncommercial-1.0.0`, matching what the PKGBUILDs already declare.
- **No `<screenshots>`.** Not strictly required for publication — Flathub's quality guidelines
  are explicitly "not required for submission" — but no screenshots means no curation, no
  banner, and a bad store listing. `desktop/screenshots/linux/` already has six good captures
  (`feed`, `messages`, `thread`, `invite`, `you`, `editprofile`); they need hosting at a
  stable URL.
- **No `<developer id="…">`** block.

Fine as-is: app-id matches the `.desktop`/`identifier` (`com.blaineam.haven`) everywhere,
`launchable`, `content_rating`, `categories`, and both `url`s are present, and a 256px icon
exists.

### Permissions — should pass review

`finish-args` is already close to minimal and has **no `--filesystem=host`**, no `--talk-name=*`
wildcards, no `--device=all`. Camera and screen share go through portals rather than grabbing
`/dev/video*` raw, which is exactly what reviewers look for. Two notes:

- The four `--talk-name=org.freedesktop.portal.*` lines are **redundant** — portal access is
  granted to every Flatpak by default. Harmless, but a reviewer will likely ask you to drop
  them.
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

⚠️ **Android `versionCode` trap:** it's `github.run_number`, which is per-workflow-file.
**Renaming or replacing `.github/workflows/android.yml` resets it to 1**, and Play permanently
rejects a `versionCode` at or below one it has already seen. If that file ever has to be
renamed, switch `versionCode` to an explicit offset first. (It's at ~483 as of 1.0.5.)
