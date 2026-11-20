// The DEBUG QA channel of a real Haven app (docs/QA.md "qa-cmd v2"): one command dropped as
// `qa-cmd.json`, answered by a rewritten dump. Apple apps keep it in a directory on this machine
// (the simulator's app container); the Android app keeps it in its own `files/qa/`, reached over
// adb with `run-as`.
//
//   PHONE_QA_DIR="<app data container>/Library/Application Support"   (Apple)
//   PHONE_ADB_PKG=com.blaineam.haven   [ANDROID_SERIAL=…]             (Android)
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const QA = process.env.PHONE_QA_DIR, PKG = process.env.PHONE_ADB_PKG;
/** Is an app's channel configured at all? */
export const configured = !!(QA || PKG);
export const usage = 'PHONE_QA_DIR="<app container>/Library/Application Support"  or  PHONE_ADB_PKG=<android application id>';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export async function until(what, f, ms = 120000, every = 1500) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(every);
  }
}

/** The app's QA channel: a directory on this machine (Apple), or `files/qa/` over adb (Android). */
const channel = PKG ? adbChannel(PKG) : {
  drop(op) {
    const drop = join(QA, "qa-cmd.json");
    writeFileSync(`${drop}.tmp`, JSON.stringify(op));
    renameSync(`${drop}.tmp`, drop);
  },
  pending: () => existsSync(join(QA, "qa-cmd.json")),
  read: () => JSON.parse(readFileSync(join(QA, "qa-dump.json"), "utf8")),
};
function adbChannel(pkg) {
  const adb = (args) => spawnSync("adb", args, { encoding: "utf8", timeout: 30000 });
  const dir = "files/qa", scratch = mkdtempSync(join(tmpdir(), "haven-phone-"));
  process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
  let seq = 0;
  return {
    // Push to a shell-owned temporary file, copy it in as the app, then rename: the app sees the
    // whole command or none of it.
    drop(op) {
      const host = join(scratch, "qa-cmd.json"), tmp = `/data/local/tmp/haven-phone-${process.pid}-${++seq}.json`;
      writeFileSync(host, JSON.stringify(op));
      const inner = `umask 077 && mkdir -p ${dir} && cat ${tmp} > ${dir}/qa-cmd.json.tmp && mv -f ${dir}/qa-cmd.json.tmp ${dir}/qa-cmd.json`;
      const pushed = adb(["push", host, tmp]);
      const r = pushed.status === 0 ? adb(["shell", `run-as ${pkg} sh -c '${inner}'; rc=$?; rm -f ${tmp}; exit $rc`]) : pushed;
      if (r.status !== 0) throw new Error(`adb could not deliver "${op.op}": ${(r.stderr || r.stdout || "").trim().slice(0, 200)}`);
    },
    pending: () => adb(["shell", `run-as ${pkg} test -f ${dir}/qa-cmd.json && echo y`]).stdout?.trim() === "y",
    read() {
      const r = adb(["exec-out", `run-as ${pkg} cat ${dir}/qa-dump-${pkg}.json 2>/dev/null`]);
      try { return JSON.parse(r.stdout); } catch { return null; }
    },
  };
}
/** Drop one QA command and wait for the app to take it. */
export async function qa(op) {
  channel.drop(op);
  await until(`the app to take "${op.op}"`, () => !channel.pending(), 30000);
}
// The app deletes a command before it has acted on it and rewritten its dump, so a dump only
// counts once it is newer than the last one read (`ts_ms`; the Apple dump carries it too).
let lastDumpTs = 0;
export async function dump() {
  await qa({ op: "dump" });
  return until("a fresh dump from the app", () => {
    const d = channel.read();
    if (!d || !(d.ts_ms > lastDumpTs)) return null;
    lastDumpTs = d.ts_ms;
    return d;
  }, 30000);
}
