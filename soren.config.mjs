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
      destination: 'platform=iOS Simulator,name=iPhone 17 Pro',
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
      destination: 'platform=macOS',
      description: 'macOS build (HavenMac scheme)',
    },

    // ── Android: JVM unit tests always; instrumented (connected) tests boot the
    //    `haven_phone` AVD on demand (reusing a running emulator when present),
    //    poll for full boot, then run — gracefully skipped if it can't boot.
    //    JAVA_HOME pinned to 17; ANDROID_HOME + platform-tools/emulator are put
    //    on PATH by the runner (both are commonly unset in the shell). The
    //    emulator is LEFT RUNNING after the run for faster reruns (stopEmulator).
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
  },

  // `soren migrate Haven` runs these (the FFI migration harness rides in both).
  migration: ['migrate', 'core'],

  // Suites whose green is the release gate (documented in docs/QA.md).
  release: {
    requireGreen: ['core', 'fabric', 'ios', 'macos', 'android', 'desktop', 'desktop-ui'],
  },
};
