#!/usr/bin/env node
// android-minified — run the R8-MINIFIED Android build on an emulator (Soren suite, release gate).
//
// Every other Android suite tests the debug build, which R8 never touches. Release is shrunk and
// obfuscated, and Haven's FFI (JNA + UniFFI) and its JNI entry point find classes, fields and
// methods BY NAME — a missing keep rule in android/app/proguard-rules.pro is a release-only crash
// that no debug test can see. This builds the `minified` build type (release's exact R8 config,
// debug-signed, its own applicationId so the QA fleet's debug install is never touched), installs
// it with its androidTest APK (`-PhavenTestBuildType=minified`), and runs, each on a CLEARED install:
//
//   MinifiedSmokeTest#onboarding_feed_post_photo_settings   identity, feed, text + photo post, settings
//   MinifiedSmokeTest#demo_feed_dm_and_call                 demo friends, DM thread + send, call start/end
//   ConnectionServiceTimeoutTest                             Android 15 dataSync budget (API 35+ only)
//
// then fails on any R8 signature in the app's logcat (ClassNotFound / NoSuchMethod / NoSuchField /
// UnsatisfiedLink / NoClassDefFound / ExceptionInInitializer / AbstractMethod, or a FATAL crash),
// retraced through the build's mapping.txt so the report names real classes.
//
// Emulator: reuses a running one; otherwise boots $HAVEN_AVD (default haven_phone) and shuts it
// down again at the end. Exit code 0 only when every test passed and logcat is clean.
//
// Usage: node Scripts/android-minified-smoke.mjs [--skip-build]
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ANDROID = join(ROOT, 'android');
const ANDROID_HOME = process.env.ANDROID_HOME || '/opt/homebrew/share/android-commandlinetools';
const JAVA_HOME = process.env.JAVA_HOME && existsSync(process.env.JAVA_HOME) ? process.env.JAVA_HOME : '/opt/homebrew/opt/openjdk@17';
const ADB = join(ANDROID_HOME, 'platform-tools', 'adb');
const EMULATOR = join(ANDROID_HOME, 'emulator', 'emulator');
const AVD = process.env.HAVEN_AVD || 'haven_phone';
const PKG = 'com.blaineam.haven.minified';
const TEST_PKG = `${PKG}.test`;
const RUNNER = `${TEST_PKG}/com.blaineam.haven.HavenTestRunner`;
const env = {
  ...process.env, ANDROID_HOME, ANDROID_SDK_ROOT: ANDROID_HOME, JAVA_HOME,
  PATH: `${join(ANDROID_HOME, 'platform-tools')}:${join(JAVA_HOME, 'bin')}:${process.env.PATH}`,
};
const skipBuild = process.argv.includes('--skip-build');

const log = (...a) => console.log('[android-minified]', ...a);
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', env, maxBuffer: 64 << 20, ...opts });
const adb = (...args) => run(ADB, args);
const sh = (cmd) => (adb('shell', cmd).stdout || '').trim();

function fail(msg) { console.error(`[android-minified] FAIL: ${msg}`); process.exitCode = 1; }

// ── Emulator ──────────────────────────────────────────────────────────────────────────────
// Several emulators can be up at once (other projects' sessions boot their own AVDs), so prefer the
// one running $HAVEN_AVD and pin every adb call to it with ANDROID_SERIAL.
function runningEmulator() {
  const out = run(ADB, ['devices']).stdout || '';
  const serials = out.split('\n').map((l) => l.trim()).filter((l) => /^emulator-\d+\s+device$/.test(l)).map((l) => l.split(/\s+/)[0]);
  const avdOf = (s) => (run(ADB, ['-s', s, 'emu', 'avd', 'name']).stdout || '').split('\n')[0].trim();
  const serial = serials.find((s) => avdOf(s) === AVD) || null;
  if (serial) env.ANDROID_SERIAL = serial;
  return serial;
}

async function ensureEmulator() {
  const serial = runningEmulator();
  if (serial) { log(`reusing ${serial}`); return { serial, booted: false }; }
  log(`booting AVD ${AVD}…`);
  const child = spawn(EMULATOR, ['-avd', AVD, '-no-snapshot-save', '-no-boot-anim', '-no-audio'], { env, detached: true, stdio: 'ignore' });
  child.unref();
  const deadline = Date.now() + 240_000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 3000));
    const s = runningEmulator();
    if (s && sh('getprop sys.boot_completed') === '1') { log(`booted ${s}`); return { serial: s, booted: true }; }
  }
  throw new Error(`emulator ${AVD} did not boot within 240s`);
}

// ── Build ─────────────────────────────────────────────────────────────────────────────────
function build() {
  log('gradle :app:assembleMinified :app:assembleMinifiedAndroidTest (R8)…');
  const r = run('./gradlew', [':app:assembleMinified', ':app:assembleMinifiedAndroidTest', '-PhavenTestBuildType=minified'],
    { cwd: ANDROID, stdio: 'inherit' });
  if (r.status !== 0) throw new Error(`gradle exited ${r.status}`);
}

function apks() {
  const abi = sh('getprop ro.product.cpu.abi') || 'arm64-v8a';
  const out = join(ANDROID, 'app', 'build', 'outputs', 'apk');
  const app = [join(out, 'minified', `app-${abi}-minified.apk`), join(out, 'minified', 'app-universal-minified.apk')].find(existsSync);
  const test = join(out, 'androidTest', 'minified', 'app-minified-androidTest.apk');
  if (!app || !existsSync(test)) throw new Error(`minified APKs missing (abi ${abi}) — build first`);
  return { app, test };
}

// ── Tests ─────────────────────────────────────────────────────────────────────────────────
const PERMS = ['android.permission.CAMERA', 'android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS',
  'android.permission.BLUETOOTH_ADVERTISE', 'android.permission.BLUETOOTH_CONNECT', 'android.permission.BLUETOOTH_SCAN',
  'android.permission.NEARBY_WIFI_DEVICES', 'android.permission.ACCESS_FINE_LOCATION', 'android.permission.ACCESS_COARSE_LOCATION'];

// R8 failure signatures. Matched only in the app's own log lines (its uid), never system noise.
const R8_SIGNS = /ClassNotFoundException|NoSuchMethodError|NoSuchMethodException|NoSuchFieldError|NoSuchFieldException|UnsatisfiedLinkError|NoClassDefFoundError|ExceptionInInitializerError|AbstractMethodError|IncompatibleClassChangeError|VerifyError|FATAL EXCEPTION|com\.sun\.jna\.|Native\.register/;

function instrument(target) {
  sh(`pm clear ${PKG}`);
  for (const p of PERMS) adb('shell', 'pm', 'grant', PKG, p);   // some are SDK-dependent; failures are fine
  adb('logcat', '-c');
  log(`▶ ${target}`);
  const r = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'haven_smoke', '1', '-e', 'class', target, RUNNER);
  const out = (r.stdout || '') + (r.stderr || '');
  const ok = /OK \(\d+ tests?\)/.test(out) && !/FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed/.test(out);
  // -4 = assumption failure (skipped). Fine for ConnectionServiceTimeoutTest below API 35; never for
  // the smoke flows, which must actually run.
  const skippedAll = /OK \(0 tests\)/.test(out) || /INSTRUMENTATION_STATUS_CODE: -4/.test(out);
  if (ok && skippedAll && target.includes('MinifiedSmokeTest')) { fail(`${target} was skipped — it must run`); return false; }
  if (!ok) {
    const stack = out.split('\n').filter((l) => /INSTRUMENTATION_STATUS: stack=|^\s+at |Error|Exception|FAIL/.test(l)).slice(0, 40).join('\n');
    fail(`${target}\n${stack}`);
  } else log(`✓ ${target}${skippedAll ? ' (skipped on this API level)' : ''}`);
  return ok;
}

function logcatScan(label, mapping) {
  const uid = (sh(`pm list packages -U ${PKG}`).match(/uid:(\d+)/) || [])[1];
  const lines = (uid ? adb('logcat', '-d', '--uid', uid) : adb('logcat', '-d')).stdout || '';
  const bad = lines.split('\n').filter((l) => R8_SIGNS.test(l) && (uid || l.includes(PKG)));
  if (!bad.length) { log(`✓ logcat clean (${label})`); return; }
  // Retrace through the mapping so the failure names real classes.
  const full = (uid ? adb('logcat', '-d', '--uid', uid) : adb('logcat', '-d')).stdout || '';
  let text = bad.join('\n') + '\n\n' + full.split('\n').filter((l) => /AndroidRuntime|\tat |Caused by/.test(l)).slice(0, 80).join('\n');
  const retrace = join(ANDROID_HOME, 'cmdline-tools', 'latest', 'bin', 'retrace');
  if (existsSync(retrace) && existsSync(mapping)) {
    const f = join(mkdtempSync(join(tmpdir(), 'haven-r8-')), 'stack.txt');
    writeFileSync(f, text);
    const rt = run(retrace, [mapping, f]);
    if (rt.status === 0 && rt.stdout) text = rt.stdout;
  }
  fail(`R8 signatures in the app's logcat after ${label}:\n${text}`);
}

async function main() {
  const { booted } = await ensureEmulator();
  try {
    if (!skipBuild) build();
    const { app, test } = apks();
    log(`install ${app.split('/').pop()} + ${test.split('/').pop()}`);
    for (const apk of [app, test]) {
      const r = adb('install', '-r', '-t', '-g', apk);
      if (!/Success/.test(r.stdout || '')) throw new Error(`install ${apk} failed: ${r.stdout}${r.stderr}`);
    }
    const mapping = join(ANDROID, 'app', 'build', 'outputs', 'mapping', 'minified', 'mapping.txt');
    for (const t of [
      'com.blaineam.haven.MinifiedSmokeTest#onboarding_feed_post_photo_settings',
      'com.blaineam.haven.MinifiedSmokeTest#demo_feed_dm_and_call',
      'com.blaineam.haven.ConnectionServiceTimeoutTest',
    ]) {
      instrument(t);
      logcatScan(t.split('.').pop(), mapping);
    }
  } finally {
    sh(`pm clear ${PKG}`);
    if (booted) { log('shutting the emulator down (we booted it)'); adb('emu', 'kill'); }
  }
  if (process.exitCode) console.error('[android-minified] FAILED'); else log('all green');
}

main().catch((e) => { fail(e.message); });
