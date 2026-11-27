# Haven — App Store metadata

<!-- Edit, then sync: rocket meta Haven   (preview first: rocket meta Haven --dry-run) -->

## name
Haven Private Circles

## subtitle
Private, encrypted circles

## description
Haven is a private social network for the people who actually matter. No ads. No tracking. No algorithm deciding what you see. No company server holding your memories.

Everything you share is end-to-end encrypted with hybrid post-quantum cryptography and travels between your devices over the internet — directly, or through a relay that can't read it — or over Bluetooth and Wi‑Fi when you're together offline. Even we can't read it.

• Private circles — share with family and close friends in separate, invite‑only circles, and always see exactly who a post will reach
• Posts, photos, videos & stories — with a modern camera, easy captions, and a song
• Direct & group messages — with sender names, timestamps, and delivery checks, plus scheduled and screenshot‑protected secret messages
• Group voice & video calls — 1:1 and group, with screen sharing, peer‑to‑peer, no call server in the middle
• All your devices in sync — start on iPhone, pick up on iPad or Mac; your posts and messages follow you
• Disappearing posts — you decide how long things stick around
• Nearby sharing — works with no internet at all, phone to phone
• Your relay does the heavy lifting — photos and videos go up once to a relay you run and friends fetch them from there, so your phone stays cool; or keep memories on your own S3 bucket
• Stays out of your way — big transfers wait while you're on a call, or when your device is hot or in Low Power Mode
• No account, no phone number, no email — your identity lives only on your device

Haven is a stronghold for the people you love. It's built so that no one — not advertisers, not data brokers, not even the people who made it — can get between you and your circle.

## keywords
private,encrypted,family,friends,circle,secure,messaging,offline,stories,calls,no ads,quantum

## promotional_text
New in 2.0: your relay does the heavy lifting for photos and videos, so your phone stays cool — and you always see exactly who a post reaches. Still free.

## whats_new
2.2.4 — Sending older photos to a linked browser is more reliable.
• One relay that doesn’t answer no longer holds up the rest. Haven keeps asking about what it may hold, for up to three days, and sends everything else.
• Fixed: an offline relay could make Haven give up on some older photos and videos for good.
• Fixed: the iPhone screen stayed on while Haven waited for a relay that was away.

## whats_new_macos
2.2.4 — Sending older photos to a linked browser is more reliable.
• One relay that doesn’t answer no longer holds up the rest. Haven keeps asking about what it may hold, for up to three days, and sends everything else.
• Fixed: an offline relay could make Haven give up on some older photos and videos for good.
• A browser you link at haven.wemiller.com/app can now open older photos and videos. After updating, open Haven on your iPhone or Mac once and keep it open while it sends the browser access (a browser you linked earlier asks on its own). Then the browser loads them from your relay as you scroll.
• Friends’ recent photos and videos now open in a newly linked browser or device.
• A photo that failed to load in the browser is tried again.
• Fixed: “Sending history to your new device” stayed on screen after sending was done.

## whats_new_windows
2.2.4 — Sending older photos to a linked browser is more reliable.
• One relay that doesn’t answer no longer holds up the rest. Haven keeps asking about what it may hold, for up to three days, and sends everything else.
• Fixed: an offline relay could make Haven give up on some older photos and videos for good.

## whats_new_previous
2.0.2 — Optimized for iPhone Duo. Opened flat on a dual-screen phone, and on iPad, the feed and profile now sit in a centered column, so photos and videos are no longer huge and you scroll less.
• A finished call no longer leaves the next one saying "Connected" before the media is flowing.
• Calls over your relay keep playing when a single audio frame is lost, instead of freezing.
• Undo after deleting a relay now puts it back in its circles.
• An Instagram import interrupted by an update picks up where it stopped.

## marketing_url
https://wemiller.com/apps/haven/

## support_url
https://wemiller.com/

## privacy_policy_url
https://wemiller.com/privacy/

## review_notes
WHAT IS NEW IN 2.2.4
iPhone has 2.2.3; on Mac this version also replaces our 2.2.3 submission. Security-relevant feature, introduced in 2.2.3; no new permissions, entitlements or data collection.
- 2.2.3: a member's own linked browser, approved by name, never holds the account key. A device that does sends it each older item's own content key once, signed by the account and encrypted to that browser only (relays cannot read it). Each key opens one item; removing the browser stops all new access.
- 2.2.4: reliability only, no change to encryption or who can read anything. A silent relay no longer holds back other items (retried up to three days), an offline relay is not read as lacking an item, and on iPhone retries no longer keep the screen on.

Haven is a serverless, peer-to-peer, end-to-end encrypted social app for small private circles. There is no central server and no login.

HOW TO EXERCISE IT
On first launch the app generates a local identity (no account, phone number or email). Content is shared only between devices that have added each other, so review is easiest with two devices: on device A tap Connect → "Invite a friend" to show a QR/invite link; on device B choose Connect → scan the QR (or open the link). Posts, photos, stories, direct messages and voice calls then travel device-to-device, over the internet or over Bluetooth/Wi-Fi when nearby and offline. With one device the full UI is still navigable.

USER-GENERATED CONTENT & SAFETY (Guideline 1.2)
All content is end-to-end encrypted between members of a private, invite-only circle, on-device, before it leaves. The developer operates no server that can see content and logs nothing, so server-side content scanning is not possible. The app ships user REPORTING: a member can report another member, which files a circle-scoped report visible to that circle and sends the developer a content-free, signed notice carrying only the reported identity key, the action and an offense category. A user approves every person who joins (nothing arrives from strangers) and can BLOCK a member and REMOVE them from a circle at any time. Removal is cryptographically enforced: a removed member is excluded from the circle's new encryption epoch and cannot decrypt anything posted afterward.

ENCRYPTION / EXPORT COMPLIANCE
Haven uses only standard, published cryptographic algorithms (X25519 + ML-KEM-768 key exchange, Ed25519 + ML-DSA signatures, AES-256-GCM, HKDF-SHA256), no proprietary cryptography. Info.plist sets ITSAppUsesNonExemptEncryption = NO; the app qualifies for the standard exemption and no French declaration applies.

NOTIFICATIONS
Push uses a self-hosted relay (a Cloudflare Worker) that is BLIND: it forwards an already-encrypted payload it cannot read; a Notification Service Extension decrypts it on-device. No content is stored on any server.

NETWORK SERVER ENTITLEMENT (macOS — com.apple.security.network.server)
Haven is peer-to-peer, so the app must ACCEPT incoming connections:
1. Inbound P2P transport: the app binds a QUIC (UDP) endpoint and listens for connections from the user's own linked devices and invited circle members. This is how posts, messages and call signaling arrive.
2. The built-in circle relay (Settings → Storage → "Host a relay"): the user's Mac can act as their circle's always-on encrypted mailbox, accepting connections from circle members to store and forward end-to-end-encrypted envelopes, and serving an authenticated local HTTP interface (port 8674) for large media.
3. NAT traversal (hole-punching) requires receiving unsolicited inbound UDP packets.
To observe: enable "Host a relay" on the Mac, then post from a second device.

## review_first_name
Blaine

## review_last_name
Miller

## review_phone
+16616177188

## review_email
blaine@wemiller.com

## availability
<!-- Store policy — applied by: rocket territories "Haven" --apply   (_shared/rocket/docs/compliance.md)
     free app, no IAP — stays in the EU as a non-trader; France (ANSSI crypto filing) and China (ICP filing) are out -->
exclude: france, china
new_territories: yes

## price
<!-- Base-territory (USA) customer price — applied by: rocket price "Haven" --apply -->
free
