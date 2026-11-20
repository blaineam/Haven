# Haven push relay (Cloudflare Worker)

A **blind** APNs sender: it only maps `nodeId → device token` and forwards **encrypted**
payloads. Content is decrypted on-device by the app's Notification Service Extension. APNs
is free; the Worker is free to 100k req/day (~$5/mo at 10M). No third-party SDK, no content.

## Deploy (≈5 min)
1. Apple Developer → Keys → create an **APNs Auth Key** (.p8). Note the **Key ID** + your **Team ID**.
2. `npm i -g wrangler && wrangler login`
3. `wrangler kv namespace create TOKENS` → paste the `id` into `wrangler.toml`.
4. Secrets:
   ```
   wrangler secret put APNS_KEY      # paste the .p8 file contents
   wrangler secret put APNS_KEY_ID   # 10-char Key ID
   wrangler secret put APNS_TEAM_ID  # 8ZVSPZYSVF
   ```
5. `wrangler deploy` → note the `https://haven-push.<you>.workers.dev` URL.

## API
- `POST /register { nodeId, token, sandbox? }` — the app calls this with its APNs token.
- `POST /notify { nodeId, ciphertext }` — sender/mailbox calls this to wake an offline peer;
  `ciphertext` = base64 of the circle-sealed blob the NSE will decrypt.

## App side (still to wire — see docs/NOTIFICATIONS.md)
- Add a **Notification Service Extension** target that decrypts `e` via the Rust core and
  rewrites the alert. Needs a **Keychain access group / app group** so the extension can read
  the identity seed.
- `registerForRemoteNotifications`, POST the token to `/register`.
- Call `/notify` on the mailbox-upload path (offline recipient).

Dev builds use the sandbox: register with `sandbox: true`.

## Android wake-up via FCM (optional)

Android has no APNs, so a pocketed phone that the OS has killed only hears about a DM when the app is
reopened. The worker can ring it with a **content-free FCM data message** — a doorbell, nothing else.
The app then pulls and decrypts the real message from its relay. Google sees timing + the device's push
token, never content (the same level of metadata Apple sees for APNs).

- `POST /register { nodeId, token, platform:"android", ts, sig }` — `token` is the FCM registration token;
  `sig` is the identity signature over `fcm-v1:<token>` (the prefix keeps it disjoint from APNs/`/flag`).
- `/notify` and `/call` send `{ w:"1" }` (`c:"1"` for a call, 45 s TTL) at high priority to Android tokens.
  A dead token (FCM `UNREGISTERED`/404/`INVALID_ARGUMENT`) is pruned automatically.
- **Off until configured:** with no `FCM_SERVICE_ACCOUNT` secret the worker never calls FCM and Android
  simply stays on its foreground service.

### Owner setup
1. Firebase console → create a project (no Analytics) → add an **Android app** `com.blaineam.haven`.
2. Project settings → Service accounts → **Generate new private key** (JSON).
3. `wrangler secret put FCM_SERVICE_ACCOUNT < key.json` then `wrangler deploy`.
4. Build the Android app with the Firebase web-app values (Project settings → Your apps): Gradle
   properties `havenFcmProjectId`, `havenFcmAppId`, `havenFcmApiKey`, `havenFcmSenderId`, or the env vars
   `HAVEN_FCM_PROJECT_ID`, `HAVEN_FCM_APP_ID`, `HAVEN_FCM_API_KEY`, `HAVEN_FCM_SENDER_ID` (CI secrets).
   No `google-services.json` and no Gradle plugin are used.
5. In the app: Settings ▸ Connection ▸ **Push wake-up (Google)** (default off; hidden when the build has no
   Firebase values or the phone has no Play services).

## Browser wake-up via Web Push (optional)

A browser linked to an account (the web client, `docs/WEB-PARITY.md`) can be rung while its tab is
closed. Like the Android wake, it is a **doorbell with no content**: the worker POSTs an empty,
VAPID-signed request to the browser's push endpoint, the browser's service worker shows "something
new is waiting", and the page fetches and decrypts the real thing from the circle's relay when it
is opened. The push service (Google, Mozilla, Apple or Microsoft, depending on the browser) learns
that this browser was rung and when — never by whom, about what, or which Haven account it is.

- `GET /webpush` → `{ key }`, the VAPID public key a browser subscribes with. 404 until configured.
- `POST /register { nodeId, platform:"web", token, deviceId, cred, credSig, ts, sig }` — `token` is
  the subscription's endpoint URL. A browser holds **no account key**, so this registration is
  authorized differently from a phone's: `cred` is the credential the account signed for this
  device (its signed bytes; `credSig` the Ed25519 half of the account's signature), and `sig` is the
  **device** key's signature over `webpush-v1:<endpoint>`. The worker checks that the account signed
  the credential, that the credential marks the device as a browser, that it names the key that
  signed, and that the endpoint belongs to a known push service. Filed under the account's node id,
  so `/notify` and `/call` ring it with no change on the sender's side.
- A registration lasts 30 days; a live browser renews it on every visit. A dead endpoint (404/410)
  is pruned.
- Every route answers with `Access-Control-Allow-Origin: *`: the web client is served from each
  circle's own relay, so its origin is not known in advance. That is safe here — the worker has no
  cookies and no ambient authority; every route that changes anything is authorized by a signature
  in the body.
- `POST /unregister-web { nodeId, deviceId, ts, sig }` — the ACCOUNT revokes a browser: `sig` is
  the account key's signature over `webpush-revoke-v1:<deviceId>`. The worker drops that browser's
  endpoint and remembers the device id (up to 64 per account), so its credential files nothing
  again. The apps send this when a browser is revoked, and keep sending until the worker answers.
- **Limit:** the worker cannot see an account's device list, so until that notice arrives a
  revoked browser can still be rung — it learns that something happened, nothing else.
- **Off until configured:** with no VAPID keys the worker never speaks Web Push, and the web
  client's switch says "not available right now".

### Owner setup
1. Make a key pair: `npx web-push generate-vapid-keys` (prints a public and a private key, both
   base64url).
2. ```
   wrangler secret put VAPID_PRIVATE_KEY   # the private key
   wrangler secret put VAPID_PUBLIC_KEY    # the public key (not secret; kept beside its pair)
   wrangler secret put VAPID_SUBJECT       # a contact the push services can reach: https://… or mailto:…
   ```
3. `wrangler deploy`.

Changing the key pair later invalidates every browser's subscription; each one re-subscribes the
next time its owner opens Haven with the switch on.
