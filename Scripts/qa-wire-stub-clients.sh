#!/usr/bin/env bash
# Wire iOS Simulator + Android emulator to the isolated HavenStub macOS host
# (com.blaineam.kith.qa.stub) using host-reachable path-proxy + media ports.
#
# Does NOT use your personal com.blaineam.kith Mac account container.
# Free Cloudflare is optional — Tailscale MagicDNS often NXDOMAINs trycloudflare.
#
# Prereqs:
#   - HavenStub running (/tmp/matrix-haven-mac-stub/.../HavenStub.app) with relay on
#   - iOS sim booted with com.blaineam.kith installed
#   - Android emu with com.blaineam.haven installed
#   - adb available
set -euo pipefail

NODE="${HAVEN_STUB_NODE:-401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89}"
TOKEN="${HAVEN_STUB_TOKEN:-8e17157a4fd8f6eeef1c3accdd9fc1de}"
SIM="${HAVEN_IOS_UDID:-}"
IOS_BUNDLE="${HAVEN_IOS_BUNDLE:-com.blaineam.kith}"
AND_PKG="${HAVEN_AND_PKG:-com.blaineam.haven}"
LAN="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en7 2>/dev/null || true)"

if [[ -z "$SIM" ]]; then
  SIM="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')"
fi
if [[ -z "$SIM" ]]; then
  echo "error: no booted iOS simulator" >&2
  exit 1
fi
if ! pgrep -x HavenStub >/dev/null; then
  echo "error: HavenStub not running — launch isolated stub first" >&2
  exit 1
fi

# Confirm stub ports
for port in 8674 8675; do
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "error: nothing listening on :$port (is in-app relay up?)" >&2
    exit 1
  fi
done

# Emulator → host loopback for path proxy + media
adb reverse tcp:8674 tcp:8674 >/dev/null
adb reverse tcp:8675 tcp:8675 >/dev/null

IOS_MEDIA="http://127.0.0.1:8674"
IOS_DERP="http://127.0.0.1:8675"
AND_MEDIA_A="http://10.0.2.2:8674"
AND_MEDIA_B="http://127.0.0.1:8674"
AND_DERP_A="http://10.0.2.2:8675"
AND_DERP_B="http://127.0.0.1:8675"

echo "Wiring stub node=${NODE:0:12}… token=${TOKEN:0:8}… sim=$SIM lan=${LAN:-none}"

# ---- iOS ----
# Prefs go THROUGH the sim's cfprefsd (simctl spawn defaults write) — editing the plist
# file directly races the daemon's cache, which flushes stale values right back over the
# file on a fresh container (the silent no-relay wiring failure).
xcrun simctl terminate "$SIM" "$IOS_BUNDLE" 2>/dev/null || true
sleep 1
ENTRIES_JSON=$(python3 - "$NODE" "$TOKEN" "$IOS_MEDIA" "${LAN:-}" <<'PY'
import json, sys, time
node, token, media, lan = sys.argv[1:5]
urls = [media] + ([f"http://{lan}:8674"] if lan else [])
now = int(time.time() * 1000)
print(json.dumps({node: {"hex": node, "name": "HavenStub matrix", "active": True,
  "lastSeenMs": now, "isS3": False, "httpUrls": urls, "httpToken": token,
  "addedAtMs": now}}, separators=(",", ":")))
PY
)
ENTRIES_HEX=$(printf '%s' "$ENTRIES_JSON" | xxd -p | tr -d '\n')
SD() { xcrun simctl spawn "$SIM" defaults write "$IOS_BUNDLE" "$@"; }
SD haven.relay.entries -data "$ENTRIES_HEX"
SD haven.relay.default -string "$NODE"
SD haven.relay.relaysByCircle -dict default "(\"$NODE\")"
SD haven.fabric.derpUrls -array
SD haven.relay.httpToken -string "$TOKEN"
xcrun simctl spawn "$SIM" defaults delete "$IOS_BUNDLE" haven.relay.derpURL 2>/dev/null || true
xcrun simctl spawn "$SIM" defaults delete "$IOS_BUNDLE" haven.relay.suppressed 2>/dev/null || true
echo "iOS prefs → via cfprefsd (simctl spawn defaults)"
SIMCTL_CHILD_HAVEN_SKIP_ONBOARDING=1 xcrun simctl launch "$SIM" "$IOS_BUNDLE" >/dev/null
echo "iOS relaunched"

# ---- Android ----
adb shell am force-stop "$AND_PKG" >/dev/null 2>&1 || true
sleep 1
adb shell "run-as $AND_PKG cat shared_prefs/haven.contacts.xml" > /tmp/and-contacts-before.xml 2>/dev/null || echo '<?xml version="1.0"?><map></map>' > /tmp/and-contacts-before.xml
python3 - "$NODE" "$TOKEN" "$AND_MEDIA_A" "$AND_MEDIA_B" "$AND_DERP_A" "$AND_DERP_B" <<'PY'
import re, json, time, sys
from pathlib import Path
node, token, m1, m2, d1, d2 = sys.argv[1:7]
now = int(time.time() * 1000)
entries = [{
    "hex": node,
    "name": "HavenStub matrix",
    "active": True,
    "lastSeenMs": now,
    "isS3": False,
    "httpUrls": [m1, m2],
    "httpToken": token,
    "addedAtMs": now,
    "derpUrl": d1,
}]
relays = {"default": [node]}
raw = Path("/tmp/and-contacts-before.xml").read_text(errors="replace")

def set_string(xml, name, value):
    xml = re.sub(rf'<string name="{re.escape(name)}"[^>]*>.*?</string>\s*', "", xml, flags=re.S)
    xml = re.sub(rf'<string name="{re.escape(name)}"\s*/>\s*', "", xml)
    esc = (value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))
    insert = f'    <string name="{name}">{esc}</string>\n'
    if "</map>" not in xml:
        xml = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n"
    return xml.replace("</map>", insert + "</map>")

xml = raw if "<map" in raw else "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n"
xml = set_string(xml, "relayEntries", json.dumps(entries, separators=(",", ":")))
xml = set_string(xml, "relays", json.dumps(relays, separators=(",", ":")))
xml = set_string(xml, "relayDefault", node)
xml = set_string(xml, "relayHttpToken", token)
xml = set_string(xml, "relaysSuppressed", "[]")
Path("/tmp/and-contacts-after.xml").write_text(xml)
fabric = f"""<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <set name="derpUrls">
        <string>{d1}</string>
        <string>{d2}</string>
    </set>
    <set name="turnUrls" />
    <string name="turnUser"></string>
    <string name="turnPass"></string>
</map>
"""
Path("/tmp/android-fabric.xml").write_text(fabric)
print("android prefs patched")
PY
adb push /tmp/and-contacts-after.xml /data/local/tmp/haven.contacts.xml >/dev/null
adb push /tmp/android-fabric.xml /data/local/tmp/haven.fabric.xml >/dev/null
adb shell "run-as $AND_PKG cp /data/local/tmp/haven.contacts.xml shared_prefs/haven.contacts.xml"
adb shell "run-as $AND_PKG cp /data/local/tmp/haven.fabric.xml shared_prefs/haven.fabric.xml"
adb shell monkey -p "$AND_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo "Android relaunched"

echo
echo "Done. Both clients adopted HavenStub HTTP mailbox (host-reachable)."
echo "  iOS:  media=$IOS_MEDIA (n0 DERP — no custom fabric on sim)"
echo "  And:  media=$AND_MEDIA_A (or reverse $AND_MEDIA_B) derp=$AND_DERP_A"
echo "Circle membership (invite) is separate — use Connect → invite QR on each peer."
echo "Re-run: Scripts/qa-wire-stub-clients.sh"