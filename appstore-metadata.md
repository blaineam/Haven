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
Launch sale — 50% off through September 30 ($4.99, then $9.99). Bring your friends, set up your Relays, and build your Communities early. A private, end‑to‑end encrypted home for your closest people. No ads, no tracking, peer‑to‑peer.

## whats_new
1.1.0 — a reliability & polish release. Nothing to set up, nothing lost.

Stories & media reliably reach a relay
• A story now finishes uploading to your circle's relay even if you lock your phone right after posting — so friends' stories stop occasionally showing "failed to load." Your own media posts show an up-arrow while uploading and a check once it's safely on a relay.

Changes hold across your devices
• Removing a circle member, deleting a contact, a circle, or a DM, and editing your profile or settings now hold on every one of your devices — resolved by whichever change you made most recently, so nothing you removed comes back and your profile picture no longer ping-pongs between two devices.

Circles & stories
• Upgrading a circle no longer leaves a duplicate — the upgraded circle carries its history, and the old one collapses into it on every device (any duplicates from before this release tidy themselves up on the next launch).
• Story headers and story rings now show profile pictures instead of a frame of the story's own media.

Video stories, rebuilt
• Recording is far more reliable — clips no longer cut off, and the shutter keeps working take after take.
• Hold to record and it auto-splits into segments (up to 15s each); a story is up to 90 seconds. Tap for a photo, hold for video.
• A landscape shot keeps its full wide frame in the review screen, with a grid of filters to choose from.

Messages & feed
• Direct messages open at the newest message, including long group threads.
• Swipe left or right in the story viewer to jump between people's stories.
• Smoother, steadier feed — fast flicks no longer flash a half-loaded image or nudge your scroll position; images fade in cleanly.
• Interface polish throughout, including the You tab and the story editor.

Native on iPhone, iPad, and Mac. No ads, no tracking, no servers holding your data — same private Haven.

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
