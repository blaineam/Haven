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
2.2.2 — A linked browser now shows everything.
• A browser you link at haven.wemiller.com/app now reads all your circles and messages, like any device you link. The per-circle “Web browsers” switch is gone: approving the browser is the only approval. A browser is weaker than the app, so remove it in Settings → Devices when you are done.
• A newly linked device shows other people's recent posts right away: your other devices hand it the keys they hold.
• Removing a device now tells it, and a removed browser erases itself.
• Fixed: scanning a device's code could fail and keep failing for minutes.
• Videos you share are much smaller (15 minutes is under 300 MB), and HDR video is converted so it looks right for everyone.
• A linked browser shows your newest posts first instead of downloading your whole history.

## whats_new_macos
2.2.2 — A linked browser now shows everything.
• A browser you link at haven.wemiller.com/app now reads all your circles and messages, like any device you link. The per-circle “Web browsers” switch is gone: approving the browser is the only approval. A browser is weaker than the app, so remove it in Settings → Devices when you are done.
• A newly linked device shows other people's recent posts right away: your other devices hand it the keys they hold.
• Removing a device now tells it, and a removed browser erases itself.
• Fixed: scanning a device's code could fail and keep failing for minutes.
• Videos you share are much smaller (15 minutes is under 300 MB), and HDR video is converted so it looks right for everyone.
• A linked browser shows your newest posts first instead of downloading your whole history.

## whats_new_windows
2.2.2 — A linked browser now shows everything.
• A browser you link at haven.wemiller.com/app now reads all your circles and messages, like any device you link. The per-circle “Web browsers” switch is gone: approving the browser is the only approval. A browser is weaker than the app, so remove it in Settings → Devices when you are done.
• A newly linked device shows other people's recent posts right away: your other devices hand it the keys they hold.
• Fixed: QR codes were drawn too small to scan, and profile pictures set on a phone did not show.
• Catching up from a relay is much faster.
• Fixed: scanning a device's code could fail and keep failing for minutes.
• Videos you share are much smaller (15 minutes is under 300 MB).
• A linked browser shows your newest posts first instead of downloading your whole history.

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
WHAT IS NEW IN 2.2.2
How a linked web browser is treated changed. No new permissions, entitlements or data collection. Security-relevant.
- A member can link a WEB BROWSER as one more device of their own account : Settings → Devices → link a device → "Scan its code", then confirm the device by name. The page comes from a relay the circle's members run or from a web site. The app loads no web content.
- CHANGED: a linked browser now reads what the account's other devices read. The per-circle "Web browsers" switch is removed; approving the browser is the only approval. It is marked as a browser in the device list and removable there. Stated to users: a tampered page could read that account's circles until removed.
- NEW: devices of ONE account hand each other the content keys they hold, sealed to the receiver, signed by the sender, only within that account's signed device list.
- Fix: scanning a device's code could fail for minutes.
- A linked browser can optionally be notified by an empty Web Push message (no content); see NOTIFICATIONS.

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
