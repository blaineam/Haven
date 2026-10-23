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
Picking photos from your library now shows them being prepared.
• Each photo you choose gets a placeholder in the composer right away, and they fill in one by one in the order you picked them, so a big selection never looks like it failed.
• Post waits until every photo is ready, so a post never goes out with half its photos.
• Large photos, including 48 MP ProRAW, are now read and optimized in the background, so preparing them no longer freezes the composer or leaves your phone hot afterwards.

## whats_new_macos
Posting waits for your photos.
• Post stays dimmed until every photo you attached is ready, so a post never goes out with half its photos.

## whats_new_windows
2.0.2 — The feed and profile now sit in a centered column in wide windows, so photos and videos are no longer huge and you scroll less. The You screen follows the same column.
• The composer no longer disappears after you leave the Circle tab and come back.
• Posts with more than ten photos show their photos again.
• Settings ▸ Advanced ▸ Re-optimize media I already shared has its button back.
• Scrolling to the end of a feed now requests older posts, so a new friend's history fills in.
• An Instagram import interrupted by an update picks up where it stopped.

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
Haven is a serverless, peer-to-peer, end-to-end encrypted social app for small private circles. There is no central server and no login.

HOW TO EXERCISE IT
On first launch the app generates a local identity (no account, phone number, or email is required or collected). Because content is shared only between devices that have added each other, the easiest way to review is with two devices: on device A tap the Connect tab → "Invite a friend" to show a QR/invite link; on device B choose Connect → scan the QR (or open the invite link). Once connected, posts, photos, stories, direct messages, and voice calls travel directly device-to-device — over the internet, or over Bluetooth/Wi-Fi when nearby and offline. If only one device is available, the app still launches, generates an identity, and the full UI (feed, composer, camera, circles, settings) is navigable; peer features simply have no peer to talk to.

USER-GENERATED CONTENT & SAFETY (Guideline 1.2)
All content is end-to-end encrypted between members of a private, invite-only circle, and is encrypted on-device before it ever leaves. The developer operates no server that can see content and logs nothing, so there is no copy of user content for the developer to store or inspect — server-side *content* scanning is not possible in a zero-knowledge peer-to-peer system. The app nonetheless ships user REPORTING: a member can report another member, which files a circle-scoped report visible to that circle and also sends the developer a content-free, cryptographically signed notice carrying only the reported identity key, the action, and an offense category — never any content, and the reporter's key is verified but not stored. User safety is otherwise enforced client-side and is robust: a user approves every person who joins (nothing arrives from strangers), and can BLOCK a member and REMOVE them from a circle at any time. Removal/blocking is cryptographically enforced — a removed member is excluded from the circle's new encryption epoch and cannot decrypt anything posted afterward, not merely hidden. Developer contact info is published in the app and in this listing.

ENCRYPTION / EXPORT COMPLIANCE
Haven uses only standard, published cryptographic algorithms (X25519 + ML-KEM-768 key exchange, Ed25519 + ML-DSA signatures, AES-256-GCM, HKDF-SHA256) — no proprietary cryptography. Info.plist sets ITSAppUsesNonExemptEncryption = NO; the app qualifies for the standard exemption and no French declaration applies.

NOTIFICATIONS
Push uses a self-hosted relay (a Cloudflare Worker) that is BLIND: it forwards an already-encrypted payload and cannot read it; a Notification Service Extension decrypts it on-device into the banner. No content is stored on any server.

NETWORK SERVER ENTITLEMENT (macOS — com.apple.security.network.server)
Haven is peer-to-peer: every install is a network peer, so the app must ACCEPT incoming connections, not just make outgoing ones. The server entitlement is required for core functionality, in three ways:
1. Inbound P2P transport: the app binds a QUIC (UDP) endpoint and listens for incoming connections from the user's own linked devices and invited circle members — this is how posts, photos, direct messages, and call signaling arrive device-to-device (there is no cloud server to pull from).
2. The built-in circle relay (Settings → Storage → "Host a relay"): the user's Mac can volunteer as their circle's always-on encrypted mailbox. It accepts incoming connections from circle members to store-and-forward end-to-end-encrypted envelopes while recipients are offline, and serves an authenticated local HTTP interface (port 8674) for large media.
3. NAT traversal (hole-punching) requires receiving unsolicited inbound UDP packets.
Removing it would break all inbound peer connectivity and the app's core purpose. To observe: enable "Host a relay" on the Mac, then post from a second device — the Mac accepts the inbound connection and stores the sealed envelope.

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
