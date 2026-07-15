# Haven — App Store metadata

<!-- Edit, then sync: rocket meta Haven   (preview first: rocket meta Haven --dry-run) -->

## name
Haven 〇

## subtitle
Encrypted circles, no servers

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
A private, end‑to‑end encrypted home for your closest people. No ads, no tracking, no servers — just your people.

## whats_new
What's new:
• Photos and videos now fill the width of the feed, with a soft blurred version of the same shot behind them — no more tall photos squeezed into a sliver
• A post with several photos is now a swipeable carousel instead of a grid of thumbnails
• Share a post as a link that opens straight to it in Haven — on iPhone, iPad, Mac, or Android. The link is built so the website never learns which post it points to
• If your circle doesn't have a relay yet, Haven now offers to help you set one up, and explains plainly what a relay can and can't see
• Calls are opaque now — your feed no longer shows faintly through an active call
• The in‑call minimize button sits clear of the Dynamic Island and the screen's rounded corners

Native on iPhone, iPad, and Mac — with Android and Windows/Linux desktop apps too.

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
All content is end-to-end encrypted between members of a private, invite-only circle, and is encrypted on-device before it ever leaves. The developer operates no server that can see content and logs nothing, so there is no copy of user content to moderate or to report to — server-side filtering/reporting is not technically possible in a zero-knowledge peer-to-peer system. User safety is instead enforced entirely client-side and is robust: a user approves every person who joins (nothing arrives from strangers), and can BLOCK a member and REMOVE them from a circle at any time. Removal/blocking is cryptographically enforced — a removed member is excluded from the circle's new encryption epoch and cannot decrypt anything posted afterward, not merely hidden. Developer contact info is published in the app and in this listing.

ENCRYPTION / EXPORT COMPLIANCE
Haven uses only standard, published cryptographic algorithms (X25519 + ML-KEM-768 key exchange, Ed25519 + ML-DSA signatures, AES-256-GCM, HKDF-SHA256) — no proprietary cryptography. Info.plist sets ITSAppUsesNonExemptEncryption = NO; the app qualifies for the standard exemption and no French declaration applies.

NOTIFICATIONS
Push uses a self-hosted relay (a Cloudflare Worker) that is BLIND: it forwards an already-encrypted payload and cannot read it; a Notification Service Extension decrypts it on-device into the banner. No content is stored on any server.

NETWORK SERVER ENTITLEMENT (macOS — com.apple.security.network.server)
Haven is peer-to-peer: every install is a network peer, so the app must ACCEPT incoming connections, not just make outgoing ones. The server entitlement is required for core functionality, in three concrete ways:
1. Inbound P2P transport: the app binds a QUIC (UDP) endpoint and listens for incoming connections from the user's own linked devices and invited circle members — this is how posts, photos, direct messages, and call signaling arrive device-to-device (there is no cloud server to pull from).
2. The built-in circle relay (Settings → Storage → "Host a relay"): the user's Mac can volunteer as their circle's always-on encrypted mailbox. It listens for and responds to incoming connections from circle members to store-and-forward end-to-end-encrypted envelopes while recipients are offline, and serves an authenticated local HTTP interface (port 8674) so members can exchange large media.
3. NAT traversal (hole-punching) requires receiving unsolicited inbound UDP packets on the bound socket.
Removing the entitlement would break all inbound peer connectivity and with it the app's core purpose (a serverless social network). To observe it: enable "Host a relay" on the Mac, then post from a second device — the Mac accepts the inbound connection and stores the sealed envelope.

## review_first_name
Blaine

## review_last_name
Miller

## review_phone
+16616177188

## review_email
blaine@wemiller.com
