#!/usr/bin/env node
// `soren run Haven android-cov` — JVM unit-test line coverage of the Android app.
// Runs createDebugUnitTestCoverageReport (JaCoCo; enableUnitTestCoverage on the debug build type),
// then reads the XML report and prints `soren-coverage:` for Haven's OWN sources only: the
// generated UniFFI Kotlin (uniffi/) and test sources are excluded. Emulator/instrumented tests are
// not part of this number. Env HAVEN_COV_SKIP_RUN=1 re-reads an existing report without running.
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const androidDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'android');
const report = join(androidDir, 'app/build/reports/coverage/test/debug/report.xml');

if (!process.env.HAVEN_COV_SKIP_RUN) {
  const r = spawnSync('./gradlew', ['--console=plain', ':app:createDebugUnitTestCoverageReport'], {
    cwd: androidDir, stdio: 'inherit',
    env: {
      ...process.env,
      JAVA_HOME: process.env.JAVA_HOME || '/opt/homebrew/opt/openjdk@17',
      ANDROID_HOME: process.env.ANDROID_HOME || '/opt/homebrew/share/android-commandlinetools',
    },
  });
  if (r.status !== 0) process.exit(r.status ?? 1);
}
if (!existsSync(report)) { console.error(`missing ${report}`); process.exit(2); }

const xml = readFileSync(report, 'utf8');
const excluded = (pkg) => pkg.startsWith('uniffi') || pkg.includes('/test') || pkg.startsWith('androidx');
let covered = 0, executable = 0;
const byFile = [];
for (const pm of xml.matchAll(/<package name="([^"]+)">([\s\S]*?)<\/package>/g)) {
  if (excluded(pm[1])) continue;
  for (const sm of pm[2].matchAll(/<sourcefile name="([^"]+)">([\s\S]*?)<\/sourcefile>/g)) {
    const m = sm[2].match(/<counter type="LINE" missed="(\d+)" covered="(\d+)"\/>/);
    if (!m) continue;
    const miss = +m[1], cov = +m[2];
    covered += cov; executable += miss + cov;
    byFile.push({ name: `${pm[1]}/${sm[1]}`, covered: cov, executable: miss + cov });
  }
}
if (process.env.HAVEN_COV_FILES) {
  for (const f of byFile.sort((a, b) => (b.executable - b.covered) - (a.executable - a.covered)))
    console.log(`${String(f.covered).padStart(5)}/${String(f.executable).padEnd(5)} ${f.name}`);
}
console.log(`android-cov: ${covered}/${executable} lines (${(100 * covered / executable).toFixed(1)}%)`);
console.log(`soren-coverage: ${JSON.stringify({ covered, executable, targets: [{ name: 'Android app (JVM unit tests)', covered, executable }] })}`);
