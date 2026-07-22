#!/usr/bin/env bash
# Link the Tauri desktop client to the iOS Simulator identity for multi-device QA.
#
# Architecture (matrix):
#   HavenStub  — isolated relay host (com.blaineam.kith.qa.stub), NOT a social peer
#   iOS sim    — primary account (posts/DMs/stories/calls)
#   Tauri mac  — SAME account as iOS (haven-seed link) so receive is verified on *two*
#                devices of the iPhone user, not only on the posting peer
#   Android emu — friend in the circle (cross-user path)
#
# Why: Android→iOS green does not prove multi-device delivery. Linking Tauri as a
# second device of the iOS account means every inbound post/DM/story should land on
# both iOS *and* desktop automatically. Failures show self-sync / device-roster /
# seal-to-all-devices gaps that single-device QA never sees.
#
# Fast path (this script): adopt iOS UserDefaults ephemeral seed via haven-seed:
# (legacy multi-device). Preferred production path is seedless enroll (haven-enroll:)
# once the primary can mint tickets in automation — not required for mailbox receive
# when both devices hold the account key.
#
# Prereqs:
#   - iOS sim booted with Haven launched at least once (writes haven.ephemeralSeed.v1)
#   - HavenStub relay up (optional here; wire step injects URLs if ports live)
#   - security / keyring writable for com.blaineam.haven
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${HAVEN_IOS_UDID:-}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
NODE="${HAVEN_STUB_NODE:-401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89}"
TOKEN="${HAVEN_STUB_TOKEN:-8e17157a4fd8f6eeef1c3accdd9fc1de}"
DATA_DIR="${HAVEN_DESKTOP_DATA:-$HOME/Library/Application Support/Haven}"
OUT="${HAVEN_QA_OUT:-$ROOT/build/live-drive-matrix-qa-20260721-154034}"
mkdir -p "$OUT"

if [[ -z "$SIM" ]]; then
  SIM="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')"
fi
[[ -n "$SIM" ]] || { echo "error: no booted iOS simulator" >&2; exit 1; }

APP_DATA="$(xcrun simctl get_app_container "$SIM" "$IOS_BUNDLE" data 2>/dev/null || true)"
[[ -n "$APP_DATA" ]] || { echo "error: iOS app data container missing — launch Haven on the sim first" >&2; exit 1; }
PLIST="$APP_DATA/Library/Preferences/${IOS_BUNDLE}.plist"
[[ -f "$PLIST" ]] || { echo "error: missing $PLIST" >&2; exit 1; }

# ---- 1) Extract iOS account seed (UserDefaults fallback used under unsigned sim) ----
SEED_B64="$(python3 - "$PLIST" <<'PY'
import plistlib, sys
from pathlib import Path
d = plistlib.load(open(sys.argv[1], "rb"))
# Prefer account ephemeral seed (primary identity). Device seed is transport-only.
for k in ("haven.ephemeralSeed.v1", "haven.accountSeed.v1"):
    v = d.get(k)
    if isinstance(v, str) and len(v) >= 40:
        print(v)
        raise SystemExit(0)
print("", end="")
raise SystemExit(2)
PY
)" || { echo "error: no haven.ephemeralSeed.v1 on iOS — open the sim app once" >&2; exit 1; }

SEED_URI="haven-seed:${SEED_B64}"
printf '%s\n' "$SEED_URI" > "$OUT/ios-to-tauri-haven-seed.txt"
# Derive expected account hex for verification (first 32 bytes of public bundle from seed via python+ctypes is hard;
# we store b64 and let desktop derive).
python3 - "$SEED_B64" <<'PY' > "$OUT/ios-to-tauri-seed-meta.txt"
import base64, sys, hashlib
b64 = sys.argv[1]
raw = base64.b64decode(b64)
assert len(raw) == 32, len(raw)
print(f"seed_bytes={len(raw)}")
print(f"seed_sha256_8={hashlib.sha256(raw).hexdigest()[:16]}")
print("note=account node hex is derived by Haven Account::from_seed on desktop boot")
PY
echo "iOS seed → $OUT/ios-to-tauri-haven-seed.txt"

# ---- 2) Install seed into desktop keyring + identities roster ----
# Uses the same service/account names as desktop/src-tauri/src/store.rs
python3 - "$SEED_B64" "$DATA_DIR" <<'PY'
import base64, json, os, subprocess, sys
from pathlib import Path

seed_b64, data_dir = sys.argv[1], Path(sys.argv[2])
seed = base64.b64decode(seed_b64)
assert len(seed) == 32
data_dir.mkdir(parents=True, exist_ok=True)

# macOS Keychain via `security` (generic password for com.blaineam.haven / master-seed)
# Desktop uses keyring crate → service "com.blaineam.haven", account "master-seed", password = base64 seed.
svc, acct = "com.blaineam.haven", "master-seed"
# Delete existing then add (idempotent for QA).
subprocess.run(
    ["security", "delete-generic-password", "-s", svc, "-a", acct],
    capture_output=True,
)
# -w password; -T "" allow any app in QA (unsigned tauri still needs access)
r = subprocess.run(
    [
        "security", "add-generic-password",
        "-s", svc, "-a", acct, "-w", seed_b64,
        "-T", "",  # open access for automation
    ],
    capture_output=True, text=True,
)
if r.returncode != 0:
    # Fallback: allow with default ACL
    r = subprocess.run(
        ["security", "add-generic-password", "-s", svc, "-a", acct, "-w", seed_b64],
        capture_output=True, text=True,
    )
if r.returncode != 0:
    print("warn: keychain write failed:", r.stderr or r.stdout, file=sys.stderr)
    print("warn: paste haven-seed from ios-to-tauri-haven-seed.txt in Tauri Link identity UI", file=sys.stderr)
else:
    print("keychain: com.blaineam.haven / master-seed written")

# Minimal identities.json so boot is not "fresh" if keychain read works
ids = {"active": "", "items": []}
# active node hex unknown until engine boots — empty active + seed still loads legacy path
(data_dir / "identities.json").write_text(json.dumps({"version": 1, "active": "", "identities": []}))
print(f"data_dir={data_dir}")
PY

# ---- 3) Inject HavenStub HTTP mailbox into desktop prefs.json ----
mkdir -p "$DATA_DIR"
python3 - "$DATA_DIR" "$NODE" "$TOKEN" <<'PY'
import json, sys, time
from pathlib import Path
root, node, token = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
prefs_path = root / "prefs.json"
prefs = {}
if prefs_path.exists():
    try:
        prefs = json.loads(prefs_path.read_text())
    except Exception:
        prefs = {}
now = int(time.time() * 1000)
entry = {
    "hex": node,
    "name": "HavenStub matrix",
    "active": True,
    "last_seen_ms": now,
    "is_s3": False,
    "http_urls": ["http://127.0.0.1:8674"],
    "http_token": token,
    "added_at_ms": now,
    "derp_url": "http://127.0.0.1:8675",
    "turn_urls": [],
    "turn_user": "",
    "turn_pass": "",
}
entries = prefs.get("relay_entries") or {}
if not isinstance(entries, dict):
    entries = {}
entries[node] = entry
prefs["relay_entries"] = entries
prefs["default_relay"] = node
relays = prefs.get("relays") or {}
if not isinstance(relays, dict):
    relays = {}
relays["default"] = [node]
prefs["relays"] = relays
# Avoid bad fabric DERP that disables n0 without a real RelayUrl
prefs.setdefault("fabric_derp_urls", [])
prefs_path.write_text(json.dumps(prefs, indent=2))
print(f"prefs → {prefs_path} (stub node {node[:12]}…)")
PY

# ---- 4) How to run Tauri ----
cat > "$OUT/TAURI_MULTI_DEVICE.md" <<EOF
# Tauri as second device of the iOS account (matrix QA)

## Topology
| Role | Identity | Job |
|------|----------|-----|
| HavenStub | \`com.blaineam.kith.qa.stub\` | Relay only (8674/8675/3340) |
| iOS Simulator | account seed in \`haven.ephemeralSeed.v1\` | Primary UI |
| **Tauri desktop** | **same account seed** (this script) | Second device — must show same feed/DMs/stories |
| Android emu | separate account | Friend posting into the circle |

## Why this matters
Cross-user Android→iOS can pass while **own-device fleet** still drops (device roster lag,
seal-to-devices, self-sync). Linking Tauri to the iPhone account is the check that
content arrives on *every* device of the receiver automatically.

## Seed installed
- Transfer code: \`$OUT/ios-to-tauri-haven-seed.txt\`
- Keychain: \`com.blaineam.haven\` / \`master-seed\` (if security write succeeded)
- Prefs: \`$DATA_DIR/prefs.json\` → stub HTTP mailbox

## Launch (no keychain prompt)
\`\`\`bash
# Ensure stub ports
lsof -nP -iTCP:8674 -sTCP:LISTEN

export HAVEN_QA_SEED_FILE=$OUT/ios-to-tauri-haven-seed.txt
cd $ROOT/desktop/src-tauri
# Prefer already-built binary after first cargo tauri dev:
./target/debug/haven-desktop
# or: cargo tauri dev
\`\`\`

\`HAVEN_QA_SEED_FILE\` / \`HAVEN_QA_SEED_B64\` skip the macOS keychain ACL dialog (matrix only).
If onboarding still shows Create/Link without the env var, paste the line from
\`ios-to-tauri-haven-seed.txt\` into **Link existing identity**.

## Prove multi-device receive
1. Android posts \`MtxDual_HHMMSS\` to the circle (with iOS + Android mutual contacts).
2. **Both** iOS sim feed and Tauri feed must show the post without opening the other device first.
3. Same for a story and a DM (DM circle must include both account devices via roster).

## Seedless (later)
Prefer \`haven-enroll:\` from iOS primary → Tauri \`onboard_link_seedless\` so desktop never holds
the account master seed. Automation: mint ticket on iOS (Link device QR), paste into Tauri.
EOF

echo ""
echo "Done. Next:"
echo "  1) Keep HavenStub up; wire iOS/Android as before"
echo "  2) cd desktop/src-tauri && cargo tauri dev"
echo "  3) Confirm account matches iOS (same node prefix as qa-my-bundle)"
echo "  4) Post from Android → must appear on iOS AND Tauri"
echo "Doc: $OUT/TAURI_MULTI_DEVICE.md"
