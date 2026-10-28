#!/usr/bin/env python3
"""Ask Google Play whether it now accepts Haven's templated Android Auto car app (Calls / Messages screens)
on PRODUCTION. The templates are a Google beta that Play rejects outside internal/closed testing; there is no
announcement to watch, so this asks Play itself: open an edit, upload a bundle that declares the car
categories, put it on a draft production release and run edits.validate. Nothing is ever committed — the edit
is deleted at the end whatever happened.

  play-car-app-probe.py <bundle.aab> <package> <versionCode>

Reads the service-account JSON from $PLAY_SERVICE_ACCOUNT_JSON. Exit 0 = Play accepted it, 3 = Play refused
(the reason is printed), anything else = the probe itself failed (auth, network) and says nothing about Play's policy.
"""
import json, os, sys, urllib.request, urllib.error
from google.oauth2 import service_account
from google.auth.transport.requests import Request

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"

def main(aab, pkg, vcode):
    info = json.loads(os.environ["PLAY_SERVICE_ACCOUNT_JSON"])
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/androidpublisher"])
    creds.refresh(Request())
    auth = {"Authorization": f"Bearer {creds.token}"}

    def call(method, url, body=None, raw=None, ctype="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method, headers={**auth, "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                txt = r.read().decode()
                return r.status, (json.loads(txt) if txt else {})
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            try: return e.code, json.loads(txt)
            except Exception: return e.code, {"raw": txt}

    code, edit = call("POST", f"{API}/{pkg}/edits", {})
    if code != 200:
        print(f"probe: could not open an edit ({code}): {edit}"); return 2
    eid = edit["id"]
    try:
        with open(aab, "rb") as f:
            blob = f.read()
        code, up = call("POST", f"{UPLOAD}/{pkg}/edits/{eid}/bundles?uploadType=media", raw=blob,
                        ctype="application/octet-stream")
        if code != 200:
            print(f"PLAY REFUSED THE BUNDLE at upload ({code}): {json.dumps(up)[:1500]}"); return 3
        code, tr = call("PUT", f"{API}/{pkg}/edits/{eid}/tracks/production",
                        {"track": "production", "releases": [{"status": "draft", "versionCodes": [str(up["versionCode"])]}]})
        if code != 200:
            print(f"PLAY REFUSED THE PRODUCTION RELEASE ({code}): {json.dumps(tr)[:1500]}"); return 3
        code, val = call("POST", f"{API}/{pkg}/edits/{eid}:validate")
        if code != 200:
            print(f"PLAY REFUSED AT VALIDATION ({code}): {json.dumps(val)[:1500]}"); return 3
        print("Play accepted a production draft that declares the car app."); return 0
    finally:
        call("DELETE", f"{API}/{pkg}/edits/{eid}")

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
