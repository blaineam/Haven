# Haven — App Store metadata

<!-- Edit, then sync: rocket meta Haven   (preview first: rocket meta Haven --dry-run) -->

## name
Haven 〇

## subtitle
Private, encrypted circles

## description
Haven is a private social network for the people who actually matter. No ads. No tracking. No algorithm deciding what you see. No company server holding your memories.

Everything you share is end-to-end encrypted with hybrid post-quantum cryptography and travels directly between your devices — over the internet, or over Bluetooth and Wi‑Fi when you're together offline. Even we can't read it.

• Private circles — share with family and close friends in separate, invite‑only circles
• Posts, photos, videos & stories — with a modern camera, easy captions, and a song
• Direct & group messages — with sender names, timestamps, and delivery checks, plus scheduled and screenshot‑protected secret messages
• Group voice & video calls — 1:1 and group, with screen sharing, peer‑to‑peer, no call server in the middle
• All your devices in sync — start on iPhone, pick up on iPad or Mac; your posts and messages follow you
• Disappearing posts — you decide how long things stick around
• Nearby sharing — works with no internet at all, phone to phone
• Bring your own storage — keep memories alive on your own S3 bucket or a relay you run
• No account, no phone number, no email — your identity lives only on your device

Haven is a stronghold for the people you love. It's built so that no one — not advertisers, not data brokers, not even the people who made it — can get between you and your circle.

## keywords
private,encrypted,family,friends,circle,secure,messaging,offline,stories,calls,no ads,quantum

## promotional_text
Free. A private, end‑to‑end encrypted home for your closest people — no ads, no tracking, no subscription. Peer‑to‑peer, post‑quantum, yours.

## whats_new
1.6.1 — Haven is now free. And the stability wave.

• Haven is free on every platform — no ads, no tracking, no subscription, no in‑app purchases. Nothing about how it works changed: your content still lives on your devices, end‑to‑end encrypted.
• Fixed a launch crash on iPhone and iPad that could kill the app on the first unlock after a restart.
• Fixed the circle key fork: a circle created from an account with several devices could leave members one step out of sync, unable to read each other's new posts in either direction. It can no longer happen, and a device that had fallen behind is brought back automatically.
• Roster changes no longer re‑seal every circle's history at once — adding or removing someone finishes in seconds instead of minutes, and your own devices catch up far faster.
• Satellite and low‑data links: photos now carry a tiny 512‑pixel preview (about six kilobytes), so a post gets through an ultra‑constrained connection and the full photo completes on its own once you're back in coverage.
• Fixed content that could arrive but stay unreadable forever after a contact's roster came in over a relay.
• Sideways photos: orientation is respected everywhere previews and thumbnails are made, so nothing arrives rotated or flips when the full‑resolution version lands.
• Feed videos no longer keep playing audio with the app in the background and the phone locked.
• Shared locations show their coordinates and an Open in Maps path when map tiles can't load — off‑grid is exactly when a pin matters.
• Calls: an unanswered outgoing call now ends after a minute instead of ringing forever on the other side.

## whats_new_previous
1.4.2 — Battery: stop multi-hour Background drain.

• Fixed a case where Haven could stay warm for hours in the Background with no messages or circle activity. A cold wake from push or background refresh no longer runs the full foreground sync/Multipeer path.
• Pocketed phones park timers and nearby discovery immediately so iOS can suspend the app after a quick empty poll.
• Continues the 1.4.1 battery work (slim push wakes, no media-backup re-arm loop while pocketed).

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
