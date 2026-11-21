#!/usr/bin/env node
// Is a web site serving exactly the web client a Release published?
//
//   tar -xzf haven-web-site.tar.gz -C site/        # the asset of the Release you trust
//   node Scripts/verify-web-site.mjs site/ https://example.org/app/
//
// Fetches every file of the unpacked archive from the site and compares SHA-256. Exit 0 only if
// every file is byte-identical; each difference is listed. Anyone can run it, from anywhere.
//
// What it does and does not show: it shows what the site serves to THIS request. A site that
// wanted to could serve something else to one chosen visitor; nothing run from outside can rule
// that out. It is a check on honest drift and on wholesale replacement, not a proof.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const [dir, base] = process.argv.slice(2);
if (!dir || !base || !/^https?:\/\//.test(base)) {
  console.error("usage: verify-web-site.mjs <unpacked haven-web-site dir> <https://site/path/>");
  process.exit(2);
}
const root = base.endsWith("/") ? base : `${base}/`;
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
function* walk(d) {
  for (const name of readdirSync(d)) {
    const full = join(d, name);
    if (statSync(full).isDirectory()) yield* walk(full);
    else yield full;
  }
}

let bad = 0, n = 0;
for (const file of walk(dir)) {
  const rel = relative(dir, file).split(sep).join("/");
  n++;
  let got;
  try {
    const res = await fetch(new URL(rel, root), { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    got = sha(Buffer.from(await res.arrayBuffer()));
  } catch (e) {
    bad++;
    console.log(`MISSING  ${rel}  (${e.message})`);
    continue;
  }
  if (got !== sha(readFileSync(file))) {
    bad++;
    console.log(`DIFFERS  ${rel}`);
  }
}
console.log(bad ? `${bad} of ${n} files differ from the release` : `all ${n} files match the release`);
process.exit(bad ? 1 : 0);
