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
      description: 'iOS simulator tests (Haven scheme)',
    },

    // ── macOS: the native HavenMac scheme, on the macOS destination (no sim boot).
    macos: {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'apple/Haven.xcodeproj',
      scheme: 'HavenMac',
      destination: 'platform=macOS',
      description: 'macOS tests (HavenMac scheme)',
    },

    // ── Android: JVM unit tests always; instrumented (connected) tests only when
    //    an emulator is up (gracefully skipped otherwise). JAVA_HOME pinned to 17.
    android: {
      type: 'gradle',
      cwd: 'android',
      unit: 'testDebugUnitTest',
      connected: 'connectedDebugAndroidTest',
      javaHome: '/opt/homebrew/opt/openjdk@17',
      description: 'Android unit + (emulator) connected tests',
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
  },

  // `soren migrate Haven` runs these (the FFI migration harness rides in both).
  migration: ['migrate', 'core'],

  // Suites whose green is the release gate (documented in docs/QA.md).
  release: { requireGreen: ['core', 'ios', 'macos', 'android', 'desktop', 'desktop-ui'] },
};
