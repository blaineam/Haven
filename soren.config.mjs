// soren.config.mjs — QA suites for Haven.
//
// Run locally:   node ../_shared/soren/soren.mjs run Haven
//                node ../_shared/soren/soren.mjs run Haven core
//                node ../_shared/soren/soren.mjs migrate Haven
//                node ../_shared/soren/soren.mjs doctor Haven
//
// Soren (🦉, the QA counterpart to Rocket) lives in _shared/soren and is pluggable
// per project via this file. See _shared/soren/docs/config.md for every field.
//
// `root` defaults to this file's directory (the Haven repo), so all `cwd` paths
// below are relative to the repo root.
export default {
  name: 'Haven',
  suites: {
    // ── The Rust core workspace: haven-p2p, haven-ffi (incl. the FFI migration
    //    harness), haven-net, haven-relay, haven-s3, demo. `--workspace` runs every
    //    member's tests. The cargo runner prepends ~/.cargo/bin (Homebrew-rustup fix)
    //    and sweeps iCloud conflict copies before building.
    core: {
      type: 'cargo',
      cwd: 'core',
      args: ['--workspace'],
      description: 'Rust core workspace (p2p + ffi migration harness + relay + s3)',
      tags: ['migration'],
    },

    // ── The migration/regression harness specifically: haven_ffi carries the
    //    upgrade/migration tests another agent is adding under core/haven-ffi/tests.
    //    `soren migrate Haven` runs this; it's also reachable as a named suite.
    migrate: {
      type: 'cargo',
      cwd: 'core',
      package: 'haven_ffi',
      description: 'haven_ffi migration/regression harness',
      tags: ['migration', 'regression'],
    },

    // ── iOS: the Haven scheme's test action (HavenUITests) on a booted simulator.
    //    Signing is disabled; a real run needs macOS + Xcode + an available sim.
    ios: {
      type: 'xcodebuild-test',
      project: 'apple/Haven.xcodeproj',
      scheme: 'Haven',
      xcodegen: true,          // apple/Haven.xcodeproj is generated + gitignored — regenerate so the
                               // compiled source list is the tree's, never a previous run's
      // By UDID, not name: 'name=iPhone 17 Pro' resolves to whichever runtime is installed first —
      // with the OS 27 beta present that was the iOS 27.0 device even under Xcode 26.6.
      // This is the iOS 26.5 iPhone 17 Pro (see `xcrun simctl list devices available`).
      destination: 'platform=iOS Simulator,id=80289DC4-7E50-4C99-BE07-FDDCF3FF0CCF',
      // Release toolchain, explicitly: xcode-select points at the OS 27 beta on this Mac, and its
      // iOS 27 simulator classifies glass buttons as PopUpButton / drops identifiers the UI tests
      // query by, so the gate went red on the runtime the store build does not even use.
      env: { DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' },
      // These UI tests drive the REAL keychain-backed identity; an unsigned build has no
      // data-protection keychain entitlement, so the seed never persists and the social engine
      // never builds. Sign with the team so the identity path actually runs.
      signing: { team: '8ZVSPZYSVF' },
      description: 'iOS simulator tests (Haven scheme)',
    },

    // ── macOS: the native HavenMac scheme has no XCTest target (its logic is covered by the core
    //    Rust suite), so the meaningful gate is that it compiles cleanly on the macOS destination.
    macos: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'apple/Haven.xcodeproj',
      scheme: 'HavenMac',
      xcodegen: true,          // apple/Haven.xcodeproj is generated + gitignored — regenerate so the
                               // compiled source list is the tree's, never a previous run's
      destination: 'platform=macOS',
      env: { DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' },
      description: 'macOS build (HavenMac scheme)',
    },

    // ── Android: JVM unit tests always; instrumented (connected) tests boot the
    //    `haven_phone` AVD on demand (reusing a running emulator when present),
    //    poll for full boot, then run — gracefully skipped if it can't boot.
    //    JAVA_HOME pinned to 17; ANDROID_HOME + platform-tools/emulator are put
    //    on PATH by the runner (both are commonly unset in the shell). The
    //    emulator is LEFT RUNNING after the run for faster reruns (stopEmulator).
    // ── Android NATIVE library. This has to run before `android`, and it is in the release gate,
    //    because NOTHING else rebuilds it: `compileDebugKotlin` and `testDebugUnitTest` compile
    //    Kotlin against the GENERATED BINDINGS and never look at the .so those bindings call into.
    //
    //    That is not hypothetical. The preview work added FFI functions, the Kotlin bindings were
    //    regenerated, the Android suite went green — and the app died on every launch with
    //    `UnsatisfiedLinkError: undefined symbol: uniffi_haven_ffi_fn_func_link_constraint`,
    //    because the jniLibs .so was three weeks old. A compile-only gate cannot see that; it is a
    //    launch crash, not a build error, and the class-init failure is cached so every subsequent
    //    attempt is rejected too.
    'android-native': {
      type: 'cmd',
      cmd: 'bash',
      args: ['build-rust.sh'],
      cwd: 'android',
      description: 'Android jniLibs (libhaven_ffi.so) are rebuilt from the current core',
    },

    android: {
      type: 'gradle',
      cwd: 'android',
      unit: 'testDebugUnitTest',
      connected: 'connectedDebugAndroidTest',
      javaHome: '/opt/homebrew/opt/openjdk@17',
      androidHome: '/opt/homebrew/share/android-commandlinetools',
      avd: 'haven_phone',
      // bootEmulator: true (default) — set false to only use an already-running one.
      // stopEmulator: false (default) — leave the emulator up between runs.
      description: 'Android unit + (emulator) connected tests',
    },

    desktop: {
      type: 'cargo',
      cwd: 'desktop/src-tauri',
      description: 'Tauri desktop Rust tests',
    },
    'desktop-ui': {
      type: 'node-check',
      files: ['desktop/ui/app.js'],
      description: 'desktop web UI syntax check',
    },

    // ── Desktop (Tauri) BINARY. `desktop` above runs the crate's tests and `desktop-ui` is a JS
    //    syntax check — neither of them ever produces the app. A crate whose tests pass can still
    //    fail to link an actual binary (a native dependency that resolves for `cargo test` but not
    //    for the bin target, a missing system lib), and until this suite existed the Tauri app was
    //    never built by any gate: `macos` builds the NATIVE HavenMac app, which is a different
    //    product entirely. Debug, because that is what the e2e fleet runs.
    'desktop-build': {
      type: 'cmd',
      cmd: 'cargo',
      args: ['build', '--bin', 'haven-desktop'],
      cwd: 'desktop/src-tauri',
      description: 'Tauri desktop binary actually links (haven-desktop)',
    },

    // ── Full cross-device E2E: iOS sim + Android emu + macOS HavenStub (relay
    //    host + friend account) + Tauri desktop on one fleet account. Exercises
    //    every in-app action (posts/stories/DMs/reactions/comments/files/music/
    //    captions/profile/circles), asserts convergence on EVERY device, and
    //    gates on propagation-latency budgets with a run-over-run regression
    //    check (build/e2e-history.jsonl). The mac leg is ALWAYS the isolated
    //    HavenStub — the personal account/container is never touched.
    //    Needs: DEBUG builds of all four clients (see docs/QA.md "qa-cmd v2").
    e2e: {
      type: 'cmd',
      cmd: 'node',
      args: ['Scripts/qa-e2e-full.mjs'],
      description: 'Full cross-device E2E (iOS+Android+macStub+Tauri) with perf gates',
      tags: ['e2e', 'relay', 'perf'],
    },

    // ── The e2e harness's OWN unit tests. Only one piece of that harness can invent a failure
    //    rather than find one — the dump-channel freshness decision — so it is the piece that gets
    //    tested here, off the fleet, in under a second. It is in the release gate for the same
    //    reason `e2e` is: a check that can fail a release must not itself be unverified, and this
    //    one needs no simulator, no emulator and no relay to run.
    'qa-harness': {
      type: 'cmd',
      cmd: 'node',
      args: ['--test', 'Scripts/lib/dump-freshness.test.mjs'],
      description: 'e2e harness unit tests (dump-channel freshness decision)',
      tags: ['e2e'],
    },

    // ── Fabric / path-proxy / WebSocket hairpin (Mac host + sim/emu consumers).
    //    Automated gate for Haven-first policy + free-CF-compatible call hairpin.
    //    Multi-device (iOS sim / Android emu / Mac) points at the Mac host path proxy;
    //    this suite proves the server side without requiring a physical device farm.
    fabric: {
      type: 'cargo',
      cwd: 'core',
      package: 'haven-net',
      args: ['--test', 'path_proxy_hairpin'],
      description: 'Path proxy + WebSocket hairpin + Haven-first DERP policy',
      tags: ['fabric', 'relay'],
    },

    // (Run LAST — see the note above: the VMs stay off the box while the e2e fleet needs the cores.)
    // ── Desktop acceptance VMs (UTM). These LAUNCH the VM and report it up; there
    //    is no in-guest test agent wired yet, so success = "VM launched" (honestly
    //    labelled). When a guest smoke agent exists, add a `guest: { host, user,
    //    cmd }` block and the leg will ssh in and run it. See docs/QA.md. Driven by
    //    UUID (two VMs can share a name). Missing UTM/VM ⇒ the leg SKIPS, not hangs.
    'vm-linux': {
      type: 'utm',
      vm: '5B499FD3-0839-46A8-8D7A-35CCBEE35D31', // "haven-linux"
      description: 'Launch the Linux desktop VM (haven-linux) — launch-only for now',
    },
    'vm-windows': {
      type: 'utm',
      vm: '3EEB5FD1-0FEA-404C-8C36-D90488168294', // "Windows"
      description: 'Launch the Windows desktop VM — launch-only for now',
    },

    // ── Desktop (Tauri): the Rust side tests + a JS syntax gate on the web UI.
  },

  // `soren migrate Haven` runs these (the FFI migration harness rides in both).
  migration: ['migrate', 'core'],

  // Suites whose green is the release gate (documented in docs/QA.md).
  release: {
    // `e2e` is a gate, not a nice-to-have. It sat broken at bootstrap for long enough that nothing
    // in it had run — a suite nobody notices is dead is worse than no suite, and the only way it
    // gets noticed is by blocking a release.
    //
    // `desktop-build` is here because `desktop` (crate tests) and `desktop-ui` (JS syntax) between
    // them never produce the Tauri app, and `macos` builds the native HavenMac app, which is a
    // different product.
    requireGreen: [
      'core', 'fabric', 'ios', 'macos', 'android-native', 'android',
      'desktop', 'desktop-ui', 'desktop-build', 'qa-harness', 'e2e',
    ],
  },
};
