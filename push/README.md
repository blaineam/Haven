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
