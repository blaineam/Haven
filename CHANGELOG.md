# Changelog

All notable changes to Haven are recorded here. Haven is in **alpha**; entries are grouped
by dated waves (a batch of work committed together and rolled into the next build). See
[`PROGRESS.md`](PROGRESS.md) for the live build/shipping status and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for milestones.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **Bundled Cloudflare Quick Tunnel for desktop + haven-relay.** Serious always-on relays can expose
  the HTTP media interface over a free `*.trycloudflare.com` HTTPS URL without port-forwarding or a
  user-installed `cloudflared` CLI. Desktop (Windows/macOS/Linux) ships the official Apache-2.0
  binary via Tauri `externalBin` (`tools/fetch-cloudflared.sh`); `haven-relay` downloads it next to
  itself on first tunnel use. Auto-on when no stable `--http-url` / public URL is set; `--no-tunnel`
  or a manual public URL disables it. Hostname is ephemeral (changes on restart).
- **Video posters ship with every video.** Attaching a video always cuts a compressed JPEG still and
  publishes it alongside the playable clip (`poster:<video>:<image>` marker). Super data saver and
  Places can render the card without downloading the video bytes.
- **Also send original.** Settings ▸ Also send original (or auto-optimize off) keeps the camera file
  as an `orig:` companion next to the optimized playable. Recipients see **Show original** in the
  post menu only when that companion exists.
- **File / folder attachments.** Posts and DMs accept arbitrary files and folders via Files… — they
  are zipped into a `file_` content-addressed blob and shared like any other media.
- **Super data saver** (Settings). No autoplay of video or attached music; feed prefetches posters /
  images / audio / files only; videos download when you tap play.
- **Public relay URL field** on the in-app relay toggle. Point friends at a Tailscale MagicDNS name
  or free tunnel to `:8674` so the plain-HTTP media path works without leaning on iroh for blobs.

### Fixed

- **Linked-device matrix harness (iOS sim + Tauri over HavenStub).** `Scripts/qa-linked-device-matrix.sh`
  links desktop to the sim account seed, injects stub HTTP mailbox prefs, and checks that
  photo/video/story posts land on both fleet devices. Stub host can load
  `qa-authorize-members.txt` (account + transport device hexes) so the mailbox is not only the
  host account. Cross-device mailbox still RED when membership auth fails (HTTP REFUSED) — calls
  over internet deferred while QA auth is fixed.

- **Matrix QA now attaches real photo/video media** (DEBUG). iOS `qa-cmd` / Android intents accept
  `media=photo|video` plus optional fixture paths; synthetic JPEG and 1s H.264 fixtures live under
  `Scripts/fixtures/`. Bidirectional `qa-peer-bundle` ingest seeds contacts without HELLO dial.
  Author-side post/story/DM with `img_`/`vid_`/`poster:` refs proven green on sim+emu; cross-device
  restore still needs a membership-authorized relay (stub REFUSED until roster lands).

- **Call shows Connected but no audio (iOS + Android).** ICE can complete while WebRTC playout stays
  off: iOS used CallKit `useManualAudio` with `isAudioEnabled=false` until `didActivate`, and if that
  never arrived (or arrived after media) the UI said Connected with silence both ways. Now enable
  and re-assert the playAndRecord/speaker session on mesh start, ICE connected, CallKit activate,
  and a 1.5s fail-open; mid-call CallKit deactivate recovers instead of muting forever. Android
  re-asserts `MODE_IN_COMMUNICATION` + speakerphone after start.
- **Mac host relay beachballs / multi‑GB RAM (field sample 4.6 GB).** Mesh anti-entropy ran every
  ~20s against every sibling (including dead NAS), listing the full store and pulling ≤256 MB blobs
  into memory; media backfill enqueued whole libraries and sealed them in one drain. Host mesh is
  now ≥5 min, only proven/public peers, ≤24 pulls/pass (mailbox first); media backup drains 5 jobs
  at a time with yields; host backfill caps enqueues; Mac sync interval stretches while serving.
- **Nearby videos abort mid-transfer (Apple).** Multipeer rate-limit (~64 KB/s + one 50 ms retry then
  `break`) finished photos (fit the burst) but **stopped multi‑MB videos after a few chunks**. Media
  serve now waits for tokens (`broadcastWaiting`), raises the bulk ceiling to ~256 KB/s, and soft-
  paces backlog instead of hard-aborting. Resume still fills any remaining holes; resume requests
  are no longer blocked for 25s by the serve throttle after a partial abort.
- **Push banner with empty feed (Apple).** Opening the app after a notification only drained the
  inline push inbox; if those envelopes failed to open (or the body never rode the push), the
  mailbox was never pulled. Foreground now always `syncBecauseOfPush`, and failed inbox opens still
  poll the mailbox.
- **Internet media stuck behind a dead NAS while Mac CF is live (Apple).** Media/mailbox dest order
  preferred pool order, so a long-dead NAS was probed (60s timeout) before the live Mac Cloudflare
  front door. Destinations are now sorted (own host → public HTTP → proven-alive → others), HTTP
  GET timeout is 20s, and all-URL failure records `RelayHealth` failure so dead relays drop down the
  list and stop looking "online" in Storage ("Listed · not proven online").
- **HTTP live-call lane when iroh dial is dead (Android + iOS).** Call invite / accept / SDP / ICE
  frames fan out under `haven/mailbox/<circle>/__live__/<dest>/` and poll every 2s, so two-way
  video still connects on HTTP-mailbox-only relays (HavenStub, free CF) instead of hanging forever
  on `dial backoff … unreachable`. Companion fixes: claim-before-dispatch markSeen (no double
  ingest), never markSeen on put (callee must still ingest), ignore duplicate remote answers once
  WebRTC is stable, and live dests are account + roster only (not every historical device hint).
- **Peer epoch keys update on re-seal (core).** `receive_key_commit` always adopts a successfully
  opened commit instead of first-wins `or_insert`, so a peer who re-sealed the same epoch after a
  membership change no longer permanently bricks reverse-path open of later posts/stories/DMs.
- **Video poster stills are not their own carousel slides (core + all UIs).** The poster rides with
  the video page so super data saver / Places tap downloads and plays the clip instead of zooming a
  dead still.
- **Android targets API 36** (`compileSdk` / `targetSdk`) so Play Console accepts new uploads.
- **Push banners name the real activity.** Reactions no longer say "Posted in the Circle", stories
  say "Shared a story…", DMs show a short message preview (or "Sent a photo" / voice note), and
  comments include a clipped preview. The NSE still only decrypts a tiny sealed JSON — richness is
  decided at send time (`PushBanner`) because the extension has no circle engine. Un-reacts and
  moderation flags stay silent so they don't spam the lock screen.
- **Lock-screen privacy for notification detail.** Senders seal both a full body and a private
  kind-only body; the recipient's NSE picks based on iOS Show Previews and a new Haven setting
  (Settings → Lock screen → Notification previews: full / name+type only / minimal). "When
  Unlocked" never quotes message text on the lock screen.
- **DM push inbox no longer leaves sibling devices with a banner and an empty thread.** Inline push
  events now fan out to the user's other online devices, fetch DM media, recompute DM badges, and
  still pull the mailbox for anything that didn't fit in the push payload.
- **Backup / "which relays hold this" sheet is a half-sheet on iOS** (medium detent), not a full-cover
  sheet — for both feed posts and DMs.
- **Device heat under thermal pressure.** Sync/poll cadence stretches further when the device is warm
  (or super data saver is on), on top of the existing idle multipliers.

### Added (prior unreleased)

- **"Re-optimize media I already shared" now works on Windows/Linux/macOS desktop** (Settings ▸
  Advanced ▸ Storage), alongside "Clean up unused media". The compression work above only ever
  applied to the *next* thing you post; everything already out there stayed exactly as big as it
  was, on every member's device. This is the lever for that: it re-encodes photos you shared, then
  re-shares them, so the whole circle gets the smaller copy. Two clicks by design — the first
  measures and tells you what it found, the second commits — and it does at most 25 items per click,
  can be stopped between items, and refuses to start if the disk is nearly full.
- **Desktop covers photos only, and says so.** The desktop app has no video encoder of its own: all
  its media processing happens in the WebView, whose only encoder produces WebM/VP8 — a format
  iPhone cannot play. Re-encoding a video here would take a clip every member can currently watch
  and replace it with one Apple devices cannot open, which is worse than leaving it alone. So videos
  and voice notes are *counted and reported* ("N videos can't be re-optimized on desktop — use
  Haven on your phone for those") but never rewritten. Photos have no such problem and are handled
  in full.

### Changed

- **Photos and videos you send are much smaller, on every platform.** "Auto-optimize" used to cap
  the *dimensions* of a video and then let the encoder pick its own bitrate — around 8 Mbps at
  1080p, an archival setting applied to something meant to cross a network. That is how a single
  clip reached 320 MB. All three platforms now encode to an explicit 4.5 Mbps, and photos to 1600px
  at JPEG q0.62 (was 2048 at q0.70). Measured on a 1080p test clip: 5.80 MB → 2.30 MB, same
  duration, same resolution, still upright. Android was the worst offender and did not look it: its
  "≈4 bits/pixel, clamped to 2–8 Mbps" formula works out to 8.3 Mbps at 1080p, so it pinned itself
  to the 8 Mbps ceiling on every single clip while appearing to adapt.
- **Videos longer than 15 minutes are refused when you attach them**, rather than quietly costing
  everyone in the circle the storage and transfer. Refused before anything is saved, so a refusal
  can never leave a post carrying an attachment with no video behind it.
- **Optimizing will no longer make a file bigger.** A clip already leaner than the target — a screen
  recording, something re-shared, anything already compressed — was being re-encoded *up* to
  4.5 Mbps, paying bytes and a generation of quality for it. Android now keeps the smaller original.

### Fixed

- **Editing a caption on desktop silently removed the post's photos, for everybody.** An edit event
  carries the post's whole attachment list and replaces what was there — it is not a patch — and the
  desktop client was sending an empty list. So fixing a typo detached every photo on the post, for
  every member of the circle. The current attachments are now re-sent unchanged; only the text moves.
- **Same bug on Android, in direct messages.** The circle-post editor was fixed alongside desktop,
  but the DM editor shared the same underlying call and did not pass anything through — so editing
  the text of a message deleted its photo, its video and its attached song, for both people in the
  thread, permanently. Editing a message's text is now text-only by construction: the attachments
  are read back off the message itself rather than handed over by whichever screen is doing the
  editing, so no editor can drop them by forgetting to mention them. Editing a muted video's caption
  also no longer un-mutes it for everyone.
- **A stopped or out-of-disk re-optimize run now tells you it stopped.** The run ends by
  re-measuring, and re-measuring cleared the message it had just set — so "Stopped." and "not enough
  free space to re-encode safely" were both wiped before they could be read.
- **Android and Windows/Linux desktop kept trying to reach a relay at an address that could not
  work.** A relay hosted inside the app announced every local network address it had. To someone on
  the same Wi-Fi those are the fast path; to everyone else a `192.168.4.x` address is simply
  unreachable — and because that path is tried *first* for photos and videos, every remote member
  paid a connection attempt and a timeout on it, per operation, before falling back to the slower
  route that works. Addresses on a network we aren't on are now discarded when they arrive, and a
  relay with a configured public address advertises only that, instead of appending local addresses
  behind it. (Apple already had this fix.)
- **A photo could stay broken forever on Android and desktop once a bad copy reached a relay.** If a
  relay held bytes that arrived but could not be decrypted, the app stored them anyway, decided it
  now had the media, and stopped asking — so the post kept an empty placeholder with nothing said
  about why. It now checks that a downloaded blob actually opens, says plainly when it doesn't,
  drops the bad copy rather than counting it as the media, and stops re-downloading the same
  unopenable bytes. The author's device still repairs it by re-uploading, and that repair is picked
  up on the next run.
- **Android's "backed up" tick counted this device's own relay.** Copying media to a relay running
  inside your own app is a local file copy that cannot fail, so posts showed a confident tick while
  nobody else could fetch them. It now means a relay someone else can read, with a distinct warning
  state for media that has only reached this device's own relay. (Apple parity.)
- **Dragging a photo or video onto the desktop app sent its GPS location and full resolution.** The
  file picker stripped location and downscaled; the drop target sealed the file straight off disk
  and did neither, so which of two identical-looking gestures you used decided whether your capture
  coordinates went to the circle. Drops now go through exactly the same processing as every other
  import.
- **A relay was frozen to whatever circles its link said on the day you set it up.** It read the
  link once at startup and refused everything else for the rest of its life — including every DM
  conversation, which is created the first time two people message and so can never be in a link
  pasted beforehand. Those conversations therefore had no relay holding messages for later at all:
  a DM only arrived if both devices happened to be awake at the same moment, which looked like
  "received DMs only show up on one of my devices". The link is now a one-time **pairing**: once a
  relay is serving you, your app tells it about new circles as you use them, and it remembers them
  across restarts. Nothing to re-paste.
- **A relay in Docker silently reverted itself on every restart.** `HAVEN_RELAY_LINK` in `.env` was
  re-applied each time the container came up, and it overwrites the saved link — so re-linking a
  relay by hand worked until the next restart quietly undid it, with nothing in the log to say so.
  The link is now applied only on a relay's first run; later starts keep the saved one and say so.
  Set `HAVEN_RELAY_LINK_FORCE=1` for one start to re-link on purpose.

### Added

- **You can now shrink media you already shared, for everyone (Apple, Android).** The compression rewrite only
  ever helped the next thing you posted — everything already out in your circles stayed as big as it
  was, and one device was carrying 1.3 GB with single videos at 320 MB. Settings ▸ Storage now
  measures what you shared before Haven learned to compress properly (or shared with auto-optimize
  off), re-encodes it through the same path new attachments use, and quietly re-shares the smaller
  copy so every member gets the space back. Captions, comments, timestamps and feed order are
  untouched, and only your own posts are eligible — nobody can rewrite someone else's. Measured on
  real files: 305.7 MB → 37.7 MB for a video, 10.9 MB → 2.8 MB across five photos. Runs in bounded
  batches, one encode at a time, and can be stopped mid-run. It sits alongside "Clean up unused
  media" rather than replacing it — the two solve opposite halves of the problem, since cleanup
  frees space on your device only while this frees it for everyone. A re-encode that doesn't come
  back clearly smaller is thrown away and the original kept, and the old copy is never deleted here:
  someone who is offline still has the pre-edit post, so those bytes retire through the ordinary
  weekly sweep instead. On Android the same button re-encodes photos and videos; voice notes are
  already recorded at the target and are left alone.
- **Haven's own relays can answer "where is node X".** Today every connection bootstraps through
  Number Zero's public DNS and relay fleet; if those stop, installs that can't hole-punch stop
  connecting. A node can now publish a short, signed record of where it can be reached to a relay it
  already trusts with its sealed mailbox. The relay is a shelf, not an authority: the record is
  signed by the node itself, so a hostile or seized relay can refuse to answer, but it cannot send
  you to the wrong person. Number Zero stays wired in as a fallback rather than the only path.
- **The push relay is no longer welded in at build time (Apple).** It can be pointed at a different
  server, or switched off entirely, on an already-installed app. With it off, Haven checks for
  messages when you open it and opportunistically in the background — slower, but nothing is lost.
- `docs/DECENTRALIZED-DISCOVERY.md` — the design, a full audit of every third-party dependency in
  the connection path, and the threat model.
- `docs/NOTIFICATIONS-FALLBACK.md` — how notifications work with no push server, and an honest
  account of what iOS will and won't deliver.
- `docs/SUCCESSION.md` — whether Haven could outlive its author, what a successor could and couldn't
  legally do with the source, and a checklist. Not legal advice.

## [1.1.4]

### Fixed

- **Linked iPhone missing newest Mac messages.** Own-device catch-up was iroh-only every 5 min.
  Host Mac now re-pushes the newest envelopes over silent APNs self-sync as well, on a 90s
  cadence while hosting (3 min otherwise).

- **Friends saw no available relays while the host showed them all enabled.** Frame-19 re-announce
  required proof-of-life within 5 min, so free-CF DNS flaps on the phone stopped re-advertising
  a live Mac host. Relays with a public HTTPS URL are announced even without a recent local proof,
  and announces are also written to the mailbox under `__relay__/` so friends learn them over HTTP
  LIST when iroh dial fails.

- **Notification taps only raised the app.** Local + remote notifications now carry a deep link
  (`haven://m/…` for DMs, `haven://p/…` for posts, `haven://c/…` for circles) so a tap opens the
  interaction directly.

- **Mac TestFlight builds silently had no push entitlement.** Native Mac App Store profiles grant
  APNs under `com.apple.developer.aps-environment`; the Mac entitlements file used the iOS short
  key `aps-environment`. codesign intersects by name and dropped push entirely (profile had
  production push; the signed app had none). Mac entitlements now use the Mac-form key so silent
  content-available pushes can register again.

- **Linked Mac host showed none of mom's activity while the iPhone got every notification.** The
  Mac was serving the relay and held hundreds of sealed DM blobs on disk, but peer epoch keys never
  stuck (or key commits were marked "seen" while still unopenable), so the feed never re-opened them.
  Host mailbox poll now re-tries key commits / device rosters even when already seen, prefers control
  plane before content, and after a newly opened key commit forgets that circle's seen cursor so
  events re-drain. One-shot linked-host repair clears stuck DM seen-cursors. Live contact delivery
  also `syncSelf`s to other linked devices (not only mailbox ingest / own sends), and DM live receive
  updates the Messages badge.

- **Friend DMs reached the host Mac but not a linked iPhone.** Mailbox poll on the host already
  live-delivered over iroh, but a sleeping or cellular phone often missed that path and only learned
  events via HTTP poll (flaky free Cloudflare DNS) or a silent APNs self-sync that only ran for
  *own* sends. Ingested mailbox events now call `syncSelf` so linked devices get the same silent
  push path as self-authored posts.

- **iPhone relay status cycling unreachable ↔ reachable.** HTTP mailbox success never stamped
  relay health (only iroh dial did), and a single dial/DNS blip zeroed proof-of-life. Free
  trycloudflare URL cool-down was also 120s. HTTP LIST/PUT success (and 403 roster refusal)
  now count as reachability; proof-of-life clears only after two consecutive failures; trycloudflare
  cool-down is ~25s and clears when a new public URL is announced. iOS mailbox poll base ~20s.

- **Opening the free Cloudflare URL in Safari often downloaded a 0 KB file.** Browsers hitting
  the media mailbox root (or a mis-hopped path) got `401 application/octet-stream` with an empty
  body — Safari saves that as a download. Path-proxy `/` now serves a small HTML status page for
  browsers; media non-API paths return HTML/text 404 instead of empty 401; proxy hops force
  `Connection: close` and rewrite `Host` so keep-alive cannot strand the next request.

- **Relay media URL vs DERP split (free Cloudflare).** After a fabric rebind, media was re-announced
  as LAN-only (`http://10.x:8674`) while iroh/DERP kept the public trycloudflare URL — so messaging
  and live fabric worked and media never reached remote peers. Media announce now always prefers the
  live tunnel / path-proxy public URL; reattach and health watch heal LAN-only wipes.

- **Cloud sync icon missing when a device knows no relay.** Own posts/stories/DM attachments hid the
  backup indicator unless a relay was already configured, so "not syncing" looked like "nothing to
  report." Always show the indicator; orange ⚠️ when no relay is known or upload is stuck.

- **Previous media never re-uploaded to a newly available relay.** Backfill skipped any blob already
  marked on *any* destination, including this device's own in-process relay (a local file copy).
  Backfill now requires confirmation on a relay others can read. Learning a public HTTPS media URL
  for a known relay also re-triggers event+media backfill.

- **Cloudflared diagnostics.** Free-tunnel logs and DNS checks write to
  `Application Support/Haven/logs/` (`cloudflared-main.log`, `cloudflared-dns.log`); Settings has
  "Open cloudflared logs". Tunnel hard-stop no longer crashes the app; free-tunnel DNS NXDOMAIN is
  diagnosed (system vs DoH) without thrashing restarts.

- **Faster cross-device catch-up while hosting.** Frame-19 reannounce every 45s when hosting (was 3 min);
  media backfill every 60s (was 2 min); post/DM with media publishes device roster and reannounces
  the host relay immediately.


## [1.1.3]

### Fixed

- **Hosting a relay made the app crawl — worst on the machines most likely to host one.** Turning on
  "be my circle's relay" left Haven pegging a CPU core and stuttering constantly; on an M1 Mac it piled
  up hangs within seconds of starting. Two separate causes, both the app doing the relay's file reads
  on the thread that draws the screen. Reading everything the relay had just been handed happened in
  one unbroken burst, so the app froze for as long as it took; and, separately, a routine check of
  which media the relay already held was reading every file in full merely to ask whether it existed.
  The first is now spread across passes and done off the drawing thread; the second asks the question
  without opening anything. A faster Mac hid this rather than escaping it.

- **Uploads that could never finish.** Sending a large photo or video to a relay restarted from the
  beginning every time it was interrupted — and on a phone, leaving the app *is* an interruption. Past
  a certain size nothing could ever complete: each attempt threw away what the last one achieved.
  Uploads now resume where they stopped, so a big video finishes over however many sessions it needs.

- **"Auto-optimize" quietly shipping the original.** If shrinking a video failed for any reason — the
  app backgrounded mid-export, low disk, an awkward recording format — Haven silently sent the full
  original instead, which for a 4K clip is hundreds of megabytes nobody asked to upload. It now retries
  at a smaller size first, and records what it actually sent.

### Added

- **You can see uploads progress now.** A post being stored on a relay showed one motionless arrow
  whether it was moving, crawling, or permanently stuck. It now shows a real progress ring, and turns
  orange when an upload has retried enough times to be worth your attention rather than your patience.

- **`haven-relay version`.** A relay is invisible while it seems to work, so a home server could sit on
  an old build indefinitely with no way to ask what it was running — while the symptoms of an outdated
  relay look like ordinary "my media won't load". It now answers, and the Docker image tracks the newest
  release instead of a pinned pre-1.0 one. Re-running the installer is also a working upgrade now: it
  used to fail outright when the relay was already running, and blamed a missing download for it.

## [1.1.2]

### Added

- **Big videos and photos pick up where they left off.** A large item could take a minute or more to
  arrive, and anything that interrupted it — locking your phone, a lift, a dropped signal, closing the
  app — threw away every byte and started again from the beginning. That is why large media often
  seemed to never load: it wasn't failing once, it was restarting forever, and a video that needed
  longer to arrive than you usually leave the app open could never finish at all. A part-finished
  download now survives being interrupted and even survives closing the app, and when it picks back up
  it asks only for the pieces it is still missing. An item that stopped one piece short now finishes in
  a moment instead of downloading all over again. Half-finished downloads that nothing has fed for a
  day clean themselves up, and a part-finished item is never mistaken for a complete one.

- **Android and desktop no longer load a whole video into memory to receive it.** Both used to hold
  every piece of an incoming item in memory until it was complete, which took several times the item's
  own size — so both refused anything past a fraction of available memory, on Android by silently
  discarding it. On a phone with little memory to spare, large videos weren't slow, they were quietly
  impossible, and nothing said so. Pieces are now written straight to storage as they arrive, so
  receiving a 500 MB video takes no more memory than a small photo and the size limits are gone
  entirely rather than merely raised. iPhone and Mac already worked this way.

### Fixed

- **A notification for a message that never appeared (iPhone, Mac).** You could get a banner for a
  message or a reaction in a conversation you were literally looking at, and the thing itself would
  never show up — not after waiting, not after force-quitting and reopening. A notification that
  arrives while you have Haven open is handled differently by the system than one that arrives while
  it's closed, and on that path Haven showed the banner and threw away the message that came with it.
  Nothing then went looking for it either, so it was simply gone. Notifications now hand the message
  over properly, and any notification prompts a check for anything else waiting — so a message can no
  longer be announced and lost at the same time. Reactions were the most affected: a missed message is
  obvious, while a missed reaction just quietly leaves your copy of a conversation wrong.

- **Setting a relay as your default served one circle and quietly refused the rest.** A relay only ever
  authorized what its link granted, and a link carried a single circle — but the apps let you pick a
  relay as the default for every circle. So you set it once, one circle worked, and every other circle
  was refused permanently. This is what "media isn't on any relay" has usually been: the relay holding
  the bytes and declining to hand them over. Relay links now carry every circle they grant. Existing
  links keep working and don't need re-pasting, and a new link pasted into an older relay still
  authorizes at least its first circle rather than failing outright.

- **Media that never arrived because it kept starting over.** Asking for a large item while it was
  already being sent started a *second* copy of the same transfer, then a third — each competing with
  the last, none of them finishing, so the item never landed and got asked for again. One transfer per
  item per recipient now, and a request that arrives mid-transfer is correctly ignored, because the
  bytes are already on their way. This was fixed on iPhone and Mac in the last release; Android and
  desktop have it now too.

- **Sending a large item no longer queues the whole thing up at once (Android, desktop).** Both used to
  hand every piece of a file to the network as fast as they could produce them, without waiting for any
  of it to actually go out — so sending a 200 MB video meant the entire video sat queued in memory,
  once per device it was going to, and the slower the connection the worse it got. Sending now keeps
  pace with the connection itself: one piece in hand at a time, as fast as the link will actually
  carry it.

## [1.1.1]

### Added

- **A story's song now plays on Android, and is named on desktop.** Attaching a song to a story only
  ever did anything on iPhone — everywhere else the story played in silence with nothing on screen to
  say a song was ever part of it. On Android the song now plays while you watch, the clip goes quiet
  underneath it, and a pill names the track and opens it in your own music app. What Android plays is
  a 30-second preview rather than the record: there is no music library for Haven to drive, so the
  song is matched by title and artist the same way the feed's song chip already does it. Desktop shows
  the same pill and deliberately plays nothing — it has neither a library to drive nor a licence to
  stream, and a player that sometimes made noise would be worse than an honest one that doesn't.
  Song chips across the app also stopped being dead links on iPhone-authored posts, where the song
  arrives as a catalog id rather than a web address.

- **Haven now yields the speakers like a normal app.** Nothing on Android had ever asked Android who
  owned the audio, so Haven would talk straight over a podcast, and a phone call arriving mid-story
  left the music playing underneath it. Every surface that makes noise now takes and gives back audio
  focus on one consistent rule: a call or an alarm **pauses** it and it resumes afterwards, a
  notification **ducks** the music out of the way, and another app taking over playback **stops** it
  for good. Voice messages pause rather than duck, because a ducked voice message is just an
  unintelligible one — they used to claim the speakers and then never react to losing them at all.

### Security

- **Link previews no longer load themselves.** A link in a message used to be fetched by *your* device
  the moment the message scrolled into view, without you touching it. That quietly told whoever sent it
  when you read it and what your IP address is — a read receipt you never agreed to — and pointed your
  device at whatever address they chose to name, including addresses on your own home network that only
  your device can reach. Previews now wait for you to tap **Load preview**, and before anything is
  fetched Haven refuses destinations that are not on the public internet: your own machine, your home
  network, and the link-local addresses used to reach cloud metadata. Redirects are re-checked at every
  hop on Android rather than followed blindly. The 256 KB limit on a page is now real — the whole page
  used to be pulled into memory and only *then* trimmed, so an endless reply could exhaust it — poster
  images are capped and size-checked before being drawn, and the preview cache is bounded instead of
  growing for as long as the app is open. See [`docs/SECURITY.md`](docs/SECURITY.md#link-previews-peer-supplied-urls).

### Fixed

- **A message could reach one of your devices and none of the others.** A friend's DM arrived on the
  tablet and never on the phone. Whoever sends you something dials the devices *their* copy of your
  device list resolves — often just one — and nothing passed it on from there, so anything a contact
  sent stopped wherever it happened to land. Now an event accepted from a contact is handed on to your
  own other devices, and a periodic catch-up repairs messages that were already stranded. Previously
  that catch-up only ran over the local network with a second device physically nearby, so two devices
  on different networks never reconciled at all; on Windows and Linux, which have no local-network
  transport, it never ran. The catch-up is deliberately bounded — at most 50 events per circle, no more
  than once every five minutes, one batch at a time — because it re-seals each message as it sends it.

- **"Keep" on a story re-posted it to everyone instead of keeping it.** It published the story again as
  a permanent post, so it reappeared in the circle feed as something new that everyone saw — which is a
  different thing from wanting to hold on to it yourself. Keep now holds the story on **your own
  profile** past the 24-hour window and leaves everyone else's story row on schedule, keeps the photo or
  video from being cleaned up (otherwise a kept story became a row of "no longer available"
  placeholders), reads Keep/Kept so you can tell at a glance whether it is on, and syncs across your own
  devices per story — keeping one thing on your phone and another on your tablet ends with both kept,
  and un-keeping something is not quietly undone by another device. Windows and Linux had no Keep at all.

- **Story controls that lit up and did nothing (Android).** Keep and Delete showed their press effect
  and then didn't fire: the swipe recognizer covering the whole screen was claiming the touch out from
  under them the moment your finger moved a few pixels. The gestures now sit on the story itself rather
  than above the buttons. Press-and-hold also *closed* the story instead of pausing it; it now pauses
  and reliably resumes. The ✕ was only tappable across the glyph itself and now has a real target.

- **A peer who turned their camera off froze on Windows and Linux.** Desktop never sent or understood
  the "my camera is off" signal, so switching your camera off left everyone looking at your last frame,
  and a phone doing the same left desktop looking at theirs. Both directions now show an avatar.

- **"Message the author" sent something you hadn't written (Android).** It immediately sent the post's
  photos and videos into a new conversation and dropped you into the wrong layout. It now opens the
  conversation with a link to the post waiting in the message box, unsent, for you to write around.

- **Haven links opened a web page inside Haven (Android).** Tapping a shared post link took you to the
  web version, which then offered an "Open in Haven" button that could do nothing — you were already in
  Haven. It now goes straight to the post. Where a link preview is shown, the raw URL no longer sits in
  the message text repeating what the preview card already says.

- **The story editor previewed a song against the wrong part of the clip (Android).** Picking a song
  while the video loop was partway through paired it with whatever moment happened to be on screen, so
  the pairing you approved wasn't the one that shipped. The clip now restarts with the song.

- **Android and desktop caught up with the call, media and roster fixes.** Everything above that was
  fixed on iPhone and Mac now behaves the same way on Android, Windows and Linux: a relay's refusal is
  told apart from an outage and self-heals, a contact's device list is *pulled* from the relay instead
  of only ever being announced (so a call between two home networks connects rather than sitting on
  "Calling"), a device that has fallen behind can re-authorize itself instead of being locked out
  forever, answering a call on one device stops your others ringing and joining behind your back, a
  friend's newly-linked device is recognized as theirs instead of arriving as a stranger, and the
  30 KB device list is no longer re-sent to every relay every couple of minutes.

- **Older media stopped being reachable — it was refused, not missing.** A relay now denies any device
  it hasn't been told about (a hardening fix), and media requests are covered by that check. The apps
  still assumed media was permission-free, so a `403 Forbidden` was handled as a transport error: the
  relay got backed off as if it were down, the fetch fell through to asking the author directly, and
  the whole thing was logged as "NOT FOUND on any relay/S3" — for blobs sitting on that relay's disk
  the entire time. That is why fresh media looked fine (the author was usually online to answer
  peer-to-peer) while anything a few days old appeared to have vanished, and why it followed the
  viewer rather than the network. A refusal is now told apart from an outage, reported as a refusal,
  and self-heals: the device re-publishes its signed roster to the relay that refused it and retries,
  so it authorizes itself instead of waiting for someone to notice.

- **Notifications work again — all of them.** Nothing was being delivered: no DMs, no post alerts, and
  no incoming-call ring, on any network, in any direction. The signed push envelope carried the sender's
  full hybrid post-quantum bundle (3,200 bytes) plus a hybrid signature (3,373 bytes), which base64'd to
  roughly 10 KB against Apple's 4 KB ceiling — so APNs rejected every push with `413 PayloadTooLarge`,
  and the push worker checked the response only for success and threw the reason away. That is also why
  calls never rang and no fallback banner appeared: the VoIP push blew its 5 KB limit, and the alert the
  worker fell back to blew the 4 KB one. The envelope now carries the sender's 32-byte node id — which
  already *is* their Ed25519 public key — and an Ed25519 signature, so the doorbell still proves who
  sent it and still can't be forged by anyone holding only your public key. Message *content* remains
  hybrid post-quantum sealed, as does call signalling, which has no size limit to respect. A test now
  asserts the envelope fits inside the APNs budget, and the worker logs the exact APNs rejection reason
  rather than discarding it.

### Added

- **Android and desktop caught up with tonight's four changes.** "Ask for it back" on swept media,
  private circle nicknames, "Message <author>", host-chosen relay media limits and the three named
  onboarding paths now work the same way on Android, Windows and Linux as they do on iPhone and Mac.
  Two things differ on purpose. The author side of "ask for it back" is *bounded* on the new platforms
  — a ten-minute per-blob cooldown and a one-upload-at-a-time guard — because serving one full upload
  per request, as written, lets anyone in your circle spend your bandwidth by asking repeatedly. And
  the desktop story composer still can't zoom out or rotate (it has no such gesture at all), though it
  now *displays* stories framed that way on a phone correctly, over their own blurred colors.

- **Ask a post's author to put media back.** "No longer available" used to be a dead end: relays sweep
  media on whatever retention their operator set, but the person who posted it almost always still has
  the original. Tapping "Ask for it back" now asks them, and it reaches them whenever they next open
  Haven — even a week later — because the request travels the same store-and-forward path your messages
  do. When they put it back you get a notification that opens the post, and the media fetches itself.
  Media now lasts as long as its author keeps a copy, rather than as long as a relay's retention window.
  Notifications on Android also finally open what they're *about* instead of just opening the app.

- **Your own name for a circle.** Renaming a circle renames it for everyone in it, which isn't the same
  as wanting your own name for it. There's now a private nickname alongside the rename: only you see it,
  it never leaves your device, and the circle's real name is still what everyone else sees.

- **Message a post's author.** A post's ⋯ menu offers "Message <name>": it opens (or reuses) your DM
  with them and carries the post's photos or videos, so they know which post you mean. Not the text —
  quoting someone's own words back at them reads like something they didn't write.

- **Relays can be told how much disk to use.** Hosting a relay meant volunteering your whole drive.
  You can now cap it by age and by size — 30 days and 32 GB by default, generous but finite — and
  either can be set to no limit independently. Undelivered messages are never swept, only media.

- **Onboarding says what each choice does to the device you already have.** Starting fresh, adding a
  second device, and moving your account to a new one used to read as the same kind of thing, with two
  of them tucked away as small links. All three are now named, each stating its consequence.

- **Share a post as a story.** A post's ⋯ menu now offers "Share as story": it opens the usual story
  composer (filters, caption, music, reframing) with the post's photos or videos already loaded, and the
  story it publishes links back to the original. Anyone watching sees a "View post" chip that opens the
  post right there in the app. The story goes to the same circle the post is in, so everyone who can see
  the story can already open the post — and if it's since been unsent, the tap lands on a plain "Post
  unavailable" card rather than doing nothing.

### Fixed

- **The website stops asking to open the Haven app.** Browsing wemiller.com/apps/haven — the home page,
  Features, Docs, Relays, the download section — kept offering to launch the app, including from
  ordinary in-page links like "Privacy" or "Download". Invite and post links now live on their own
  page, and that page is the only one the app answers for; everything else stays in the browser where
  it belongs. Links already shared still work: they open the page, which offers a button to continue
  into the app rather than jumping there by itself.
- **Tall, narrow photos get their blurred backdrop again.** A post whose photo is much taller than it is
  wide sometimes drew against flat grey instead of the soft blurred copy of its own colors. The backdrop
  was built from a 64-pixel thumbnail, and at that size a narrow photo shrinks to a sliver a couple of
  pixels across — stretching that far enough to fill the card produced a layer too large for the graphics
  system to draw, so it drew nothing at all. Narrow photos now use a larger source and a bounded fill, so
  the backdrop renders at every shape. Ordinary photos are unchanged.

## [1.1.0] — 2026-07-17

A reliability and polish release focused on multi-device sync and feed smoothness. Everything here
lands on **every** platform — iOS, macOS, Android, Windows, and Linux — sharing one wire format so
mixed-device accounts stay consistent.

### Fixed

- **A story you post reliably reaches a relay — even if you lock your phone right after.** Posting sends
  the post itself and its photo/video to the circle's relay on two separate paths; the media path wasn't
  as durable as the post path, so backgrounding the app before the upload finished could leave the media
  stranded — friends saw the story but its photo/video "failed to load." The media upload now survives
  backgrounding and app restarts and retries until it's confirmed on a relay. Your own media posts now
  show a small indicator: an up-arrow while it's uploading to a relay, a check once it's safely there.
- **Changes you make on one device now hold on all of them.** Removing a circle member, deleting a
  contact, deleting a circle or DM, editing your profile, and changing your synced settings are now
  reconciled by *who changed it last* rather than *who synced last*. Previously an additive merge
  could re-introduce something you'd removed, and two devices with different profile pictures could
  overwrite each other in a loop — both are fixed, across iOS, macOS, Android, Windows, and Linux.
- **Upgrading a circle no longer leaves a duplicate.** The upgraded circle carries its history, and
  the older circle collapses into it on every one of your devices instead of lingering as a second
  row (any duplicates from before this release heal themselves on the next launch).
- **Story screens and story rings show profile pictures.** A friend's story now shows their real
  profile photo in the header, and every story ring shows the sharer's avatar rather than a frame of
  the story's own media.
- **Direct messages open at the newest message** — including long group threads, which previously
  opened scrolled too far down.
- **Smoother feed scrolling.** The feed no longer jumps around as you scroll. Every card now knows its
  size before its photo or video loads, so nothing resizes underneath you: media dimensions are
  remembered between launches, and posts with a big photo grid, a video carousel, or a shared location
  no longer do heavy work while you're scrolling past them (a location post draws a cached map image
  instead of a live map). A post's song also starts only once you settle on it.
- **Interface polish:** the You tab no longer slides sideways on a scroll, and the macOS You tab opens
  cleanly. The story editor's controls sit properly against the screen edges — they were inset twice,
  leaving a band of wasted space above the top buttons and below the Share button.

### Sound

- **Music plays on profile feeds too.** Scrolling your You tab or a friend's profile now plays the
  centred post's song, and coming back to a circle no longer leaves the feed silent.
- **A camera never plays a post's music.** Opening any camera stops post audio outright rather than
  pausing it — previously it could come back by itself the moment a recording ended. Sheets and
  full-screen views that cover the feed (settings, circle membership, pickers) quieten it too.
- **The ring/silent switch is respected while the app is open**, not only at launch — flipping it now
  takes effect within a couple of seconds. Your own in-app mute still wins until the switch actually moves.
- **The story editor can play your story's sound.** A speaker button previews the story as it will
  actually play: the attached song, or the clip's own audio when there's no song. The clip keeps
  looping either way, and the preview no longer cuts out a moment after it starts.

### Camera & capture

- **Story video capture, rebuilt.** Recording is far more reliable — clips no longer cut off after a
  second, and the shutter keeps working take after take. A long hold **auto-splits** into segments (up to
  15s each), a story caps at **90 seconds** (or 8 segments), and the first shutter action locks the mode
  (tap = photo, hold = video). Recorded clips come out upright with sound, and the progress bar and zoom
  controls behave cleanly across each segment.
- **The camera preserves your framing.** A landscape shot keeps its **full wide frame** in the review
  screen (previewed at its true aspect instead of being cropped into portrait), and the extra space shows
  a full **grid of filters** to pick from.
- **Swipe between people's stories.** In the story viewer, a horizontal swipe jumps to the next (or
  previous) person's stories, instead of stepping through one story at a time.
- **Smoother, steadier feed.** Fast flicks no longer flash a half-loaded image or nudge the scroll
  position around — images fade in cleanly and the feed only redraws when something actually changed.

## [1.0.9] — 2026-07-17

Everything in 1.0.7 (below), plus the fixes for bugs caught right after it was submitted —
1.0.9 replaces 1.0.7/1.0.8 so no one receives the broken build.

### Fixed

- **Removing someone from a circle now sticks.** On an account with more than one of your own
  devices, a member you removed could reappear when your other device's still-has-them state synced
  back — circle membership merged additively, and the removal was only tracked in the app layer, not
  the engine that does the merge. The removal is now a durable engine-level tombstone: a removed
  member is never re-admitted by a sync/restore, and a deliberate re-add clears it.
- **A friend's photos and videos load again.** Posted media is signed and sealed so any authorized
  member opens it, regardless of device state (this changes nothing about who *can* open it — the
  media reference already lives inside the end-to-end-encrypted post, which gates access). Media
  posted before this fix could be stuck unopenable because a stored media file is cached once and
  never re-sealed; the next time each person opens Haven, their own affected media is quietly
  re-sealed and the stored copy is overwritten in place, so a friend's previously-stuck photos and
  videos start loading. The repair runs once in the background, only for media you still hold, and
  retries across launches until every reachable copy is refreshed.
- **"Keep on this device" is now in the post ⋯ menu.** The storage screen advertised it, but it was
  only reachable by long-pressing an individual photo. It now lives on each post's menu (pinning all
  of the post's photos/videos so no cleanup ever removes them), on every platform.
- **"Upgrade this circle" now actually appears on the circles that need it.** The offer was gated on a
  per-device record of which circles you created — which the pre-1.0.7 circles that need upgrading
  never had, so it never showed. It now appears on any circle with no verified owner yet; because no
  device can know who made a legacy circle, the offer is shown to every member and the follow prompt
  names each claimant so members pick the real creator.

## [1.0.7] — 2026-07-16

The security-and-polish release. It re-roots multi-device identity so a **linked device never has
to hold your master seed**, lands the entire machinery for **cryptographic device revocation** —
both rolling out **gradually and per-circle as everyone updates**, with nothing to do and nothing
lost — and builds in a next-generation **MLS-style group-encryption** layer for circles with a
**verified owner** (every circle you make from now on). Plus a real **storage-management** suite and
a fixed metadata leak.

> **Two honesty notes up front, because this is a security product.**
> 1. The new crypto activates **per circle, as every member's devices update** — a coexistence
>    (dual-seal) path keeps un-upgraded peers fully working the entire time. It is not an instant,
>    universal flip.
> 2. The MLS-style group layer is **enabled in this release, but it does not switch your existing
>    circles over by itself.** It applies to circles that have a **verified owner** — every circle you
>    make from now on. Circles you already have don't have one (nothing recorded who created them back
>    then), and an owner can't be added after the fact in a way anyone else could trust, so they keep
>    the encryption they already have — which still cuts off someone you remove. To carry an older
>    circle across, whoever made it offers an upgrade and **each member taps once to follow it**; we
>    show who's asking, because that's a judgement only a person can make. Even on a circle with an
>    owner it turns on only once everyone's devices have updated and joined, and it only ever changes
>    *which key* seals content, never *whether* content is encrypted. Its audit to date is an
>    **internal, AI-driven adversarial review** — 0 critical, 0 high — which is a strong first pass,
>    **not** a formal external audit; an independent cryptographer's review is planned and we don't
>    claim it's done. It is **MLS-*shaped*** (TreeKEM mechanisms on Haven's own post-quantum
>    primitives), **not** RFC-9420 wire-interoperable.

### Security

- **Seedless device linking (seed-drop, D16 Phase 2 · S2–S5 core).** Historically every device you
  linked held a *copy of your account master seed*, so revoking a device was a strong deterrent
  against a **lost/stolen** phone but only advisory against a genuinely **compromised** one (the
  seed it already held kept decrypting, and — because roster authority *was* the account key — a
  seed-holder could re-sign a higher-version device list and re-add itself). This release re-roots
  day-to-day operation on **per-device keys**: a device now authors and signs under its own keypair,
  carries an account-signed `DeviceCredential`, and content seals to authorized **device bundles**.
  A device enrolled through the new **seedless** flow holds *only* its device key + credential and
  **never receives the master seed**; the seed concentrates on one primary device
  (Secure-Enclave-wrapped) plus the existing SE-wrapped iCloud-Keychain escrow. Seedless-enrollment
  onboarding UI ships on **iOS, macOS, Android, and desktop**. See
  [`docs/SEED-DROP-DESIGN.md`](docs/SEED-DROP-DESIGN.md).
- **Revocation becomes a cryptographic cut — content *and* the account-state channel.** With the
  machinery above, revoking a device can now cut it off cryptographically: it is excluded from the
  circle's next key commit (can't read anything posted after) **and** the self-sync key is re-keyed
  on revocation, so a revoked device can no longer read or write your account-state stream
  (profile / contacts / circles / settings). A seedless device also **cannot forge** a higher-version
  roster to re-add itself, because roster authority is the account key it does not hold. Proven by
  the `s5` core test (a revoked seedless device can neither decrypt post-revocation content nor
  re-enter). **Rollout is per-circle:** the account-key seal is retired for a circle only once every
  member's devices affirmatively advertise capability (an all-present-positive signal, never inferred
  from absence), so until your circle finishes updating, revocation stays on the safe dual-seal path.
- **MLS-style group encryption — TreeKEM on Haven's own PQ primitives (D16 Phase 5, enabled for owner-verified circles).**
  A ratchet-tree group layer — propose/commit/welcome, O(log n) path updates, a one-way epoch
  schedule — that adds **post-compromise security** (a device that refreshes its leaf heals a past
  key exfiltration within the weekly rotation, without anyone noticing the compromise), a real
  **forward-secrecy deletion discipline**, and **per-message forward secrecy for DMs** (a sender
  ratchet). It reuses Haven's existing hybrid primitives (X25519+ML-KEM-768 → AES-256-GCM,
  Ed25519+ML-DSA-65) and the shipped epoch/content path unchanged — the tree only changes how the
  32-byte epoch key is *agreed*. It is deliberately **not** RFC-9420 interoperable (every ratified
  MLS ciphersuite is classical; interop would regress the post-quantum posture that is the product's
  headline). The core keying master switch **defaults off**, and the 1.0.7 clients **enable it** —
  but only for circles with a **verified owner**, i.e. circles created from 1.0.7 onward, whose id is
  cryptographically bound to their creator. **Circles that already exist do not switch over by
  themselves:** they have no owner (nothing recorded who created them), and an owner cannot be added
  after the fact in a way other members could trust, so they keep the encryption they already have —
  which still cuts off someone you remove. To carry an older circle across, whoever made it **offers
  an upgrade** and **each member taps once to follow it**; the app shows who is asking, because no
  signature can prove someone created a circle that never recorded an owner — that judgement is a
  person's. Even on a circle *with* an owner the layer activates only **once every member's devices
  have updated and joined** (an all-present/all-joined gate), and until then it stays byte-identical
  to the live sender-keys+epochs path — a device that falls behind reverts within one sync, and it
  only ever changes *which key* seals content, never *whether* content is encrypted. The crypto has had an
  internal, human-directed adversarial code review; a formal external cryptographer's review is
  planned and remains the gate before the core default flips on (design M7). See
  [`docs/TREEKEM-DESIGN.md`](docs/TREEKEM-DESIGN.md).

### Added

- **Storage management** (all clients). A media-cleanup screen lists everything you've downloaded,
  **sortable by size**, with multi-select delete; deleting media **keeps the metadata** and leaves a
  **re-downloadable placeholder**, so a freed photo/video comes back on demand and nothing about the
  post is lost. A per-item **"keep on this device"** pin protects anything you never want auto-swept.
- **Local + relay retention limits, that really delete.** You can cap on-device media by **age and/or
  size**; auto-delete now **actually removes the media bytes** (with a real blob GC — purge-linked
  deletion plus an orphan sweep — on iOS, Android, and desktop), not just hides the post. A relay
  operator can likewise choose **time and/or size** retention (least-space-wins), and expired content
  is genuinely deleted from the log, not merely masked.
- **Video compression** on posting (Android transcode landed; the optimize-vs-lossless toggle carries
  across), so clips cost less storage and bandwidth end-to-end.

### Changed

- **Stories: full cross-platform parity.** Story styling — including **media framing** — now travels
  intact between platforms, and desktop authors styled captions, so a story looks the same to
  everyone regardless of what they're on.
- **Automatic, in-place migration.** Existing accounts, circles, history, and contact with
  un-upgraded (1.0.x) peers are preserved throughout: devices keep reading older account-sealed
  content (dual-open), capability is negotiated peer-to-peer, and every transition is additive and
  gated on a positive signal — there is no flag day, no re-onboarding, and no new identity.

### Fixed

- **Metadata / GPS leak on video closed on the desktop export path** (the last platform where a video
  could carry EXIF/GPS), matching the iOS and Android strips already in place. A fixed
  plaintext-media-cache leak was also closed as part of the blob-GC work.

### Platforms

- **Windows is live on the [Microsoft Store](https://apps.microsoft.com/store/detail/9NKTFH1MF4LM)**
  (x64 & Arm64), no longer distributed via GitHub Releases. Linux GUI + the `haven-relay` daemon
  continue to ship free on GitHub Releases.

## [Unreleased] — 2026-07-14

### Added
- **Live device-to-device delivery** (multi-device D16, Phase 4b). A post authored on your phone now
  lands on your Mac *while you're looking at it*, instead of after its next mailbox poll — up to 120s
  on iOS, 30–180s on Android/desktop. The fan-out lists that reach your contacts deliberately exclude
  you, so your own devices previously had no direct path at all and depended on that poll (or, on iOS
  only, a push wake). Core: `haven_net::livedelivery`; wired on iOS/macOS + Android.
  **Strictly additive:** the mailbox upload is unchanged and unconditional, so live delivery only
  changes how *fast* a sibling learns, never *whether* — a sleeping device, or one you link tomorrow,
  gets exactly what it always did. Attempts are bounded (3s/device, 5s total) so a sleeping sibling
  never holds a post behind iroh's ~30s dial timeout, and never dial our own id (the self-connect
  path-discovery leak) or the account id (a contact handle that resolves to no endpoint under
  per-device transport seeds). Proven both ways in `core/haven-net/tests/live_delivery.rs`: delivery
  with **no relay in the test at all**, and the identical event still arriving when the direct path
  is dead.
- **Blurred media backdrop.** A tall photo or clip no longer sits in a narrow column with the card's
  grey either side — the page now spans the card and a blurred, cropped copy of the media fills the
  letterbox. All four clients. Video uses the poster still, not a second live layer: an `AVPlayer`
  only ever feeds one `AVPlayerLayer` (and `MediaPlayer`/`ExoPlayer` drive one surface), and behind a
  24pt blur a still is indistinguishable from a moving copy at zero extra decode.
- **Carousel for 2–10 items of any aspect**, replacing the two-row masonry for small mixed sets. Pages
  take the tallest item's shape (clamped) so nothing crops; the backdrop masks the difference.
- **Web-routed post links** — `https://wemiller.com/apps/haven/#p/<circle>.<post>`. The payload rides
  the URL **fragment**, so the host never learns which post is being read. Legacy `haven://p/…` still
  parses. Universal Links / App Links now verify against association files at the domain root.
- **Relay nudge**: a dismissable banner (>2 members, no relay of the circle's own) plus a walkthrough
  covering what a relay does and how the encryption works. All clients.
- **Android: inline feed autoplay** with a centered-post coordinator — exactly one player alive at a
  time (measured via `dumpsys media.player`), muted by default, capped at 128 MB per clip.

### Fixed
- **Docs promised an onion/Tor mode we won't build.** The threat model's IP promise ended in
  "optionally fully hidden", carried by a "planned, not yet shipped" opt-in onion mode — repeated
  across five docs, both marketing pages, and the relay README. The research spike (`docs/TOR.md`)
  concluded **don't recommend**: Tor is TCP-only, so iroh's QUIC/UDP data plane and WebRTC calls can
  never traverse it, and the one constructible variant deletes direct P2P and calling. It's now
  recharacterized as evaluated-and-declined, with VPN or a self-hosted relay/discovery node as the
  supported way to hide your IP from a node. Same honest-IP-guarantees discipline as D14 — an honest
  downgrade beats a stale promise.
- **"Never linked to you" was not true, and is gone** (closes audit **F8**). A configured relay
  authenticates each peer by its iroh node id — which *is* that peer's Haven public key
  (`blobstore.rs:537`) — because that check is what enforces circle membership (`:687-709`) and
  self-sync slot ownership (`:742-748`), and what stops a stranger who learns the relay id from
  enumerating a mailbox. So the relay holds `IP ↔ node id` in memory while it moves your bytes.
  `RELAY-AND-DEPLOY.md`'s "ephemeral rendezvous tokens, not Haven public keys" described a design
  that was never built, and contradicted `SECURITY.md`, which was already honest about it. The
  promise across the docs, both web pages and the relay README is now **never logged, never sold,
  never readable** — explicitly *not* "never seen" — and what a relay can't do is tie that key to a
  real-world you, since there's no account, name, email or phone in the system to tie it to.
- **Relay walkthrough claimed adding a member rotates the circle key. It doesn't** — rotation happens
  on removal/block, device-roster changes, and the periodic `rotate_circle`. The old wording implied a
  new member was cryptographically fenced off from earlier posts; they aren't. Traced to
  `GROUP-KEYING.md` saying "every membership change", which is now corrected at the source.
- **Unsent posts no longer clutter the feed** — and the profile/You screen now filters them too, which
  it never did while other people's profiles always had.
- **macOS: real Liquid Glass adopted throughout.** Sheets that rendered grey bands above and below the
  gradient (Connect, Edit profile, circle + circle settings, reaction detail, DM picker, new circle,
  edit post, connection requests, react picker, share screen, add-to-call, video trimmer) now use
  `HavenMacSheet`; ~20 controls that drew a custom circle/pill without a button style — including every
  emoji in the reaction grid — no longer get macOS's rectangular bezel behind them.
- **Reaction menu** no longer hides its quick emoji behind a submenu (a `ControlGroup` collapsed to
  `❤️ 😎 👍 ›` on macOS); the emoji react on tap.
- **macOS audio**: `silent` is device-local again. It was syncing, so a phone's ringer switch dictated
  the Mac's audio and a late-arriving synced value restarted a song you'd muted. macOS now starts
  muted; the async `play()` path got a real generation token; the speaker button was dead while muted;
  a looping video restarted the song on every loop.
- **macOS post camera** now tucks its filter strip behind a toggle, matching the story camera.
- **Desktop**: video backdrops captured a black frame (`loadeddata` fires before a frame is drawable)
  and `requestVideoFrameCallback` never fires for a paused video, so every video backdrop would have
  shipped black; the blur ran on a full-resolution bitmap (1152×2048 → now 36×64).
- **Android demo seed**: friend posts, stories and DM lines never landed — a bare `receive(envelope)`
  can't open an epoch-sealed event without the author's key commit, so the demo feed had 3 posts
  instead of 8 and every seeded reaction was a no-op. Ported Apple's `replayIntoMain`.

### Infrastructure
- **Xcode Cloud** could never build: `apple/*.xcodeproj`, `apple/Generated/` and `*.xcframework` are
  all generated and gitignored, and no `ci_scripts/` existed. Added `ci_post_clone.sh` that restores
  `HavenFFI.xcframework` from a GitHub Release keyed by the `core/` tree hash (build only on a miss),
  then runs XcodeGen — so a full Rust compile doesn't burn the free monthly compute allowance. Set
  `GITHUB_TOKEN` on the workflow to enable the cache.

## [0.1.0-beta.39] — 2026-07-13

### Fixed
- **Android & desktop parity** for the beta.38 relay/media fixes: media now mirrors to (and loads
  from) any reachable relay you share; each device publishes its account-signed roster so a headless
  relay authorizes it; deleted relays stay deleted across your own devices (timestamped last-writer-
  wins on delete-vs-re-add); and large media is sealed file-to-file to keep memory flat. iOS shipped
  these in beta.38 / App Store 1.0.4.

## [0.1.0-beta.38] — 2026-07-13

### Fixed
- **Deleted relays finally stay deleted.** Deleting a relay ("Delete now" or Deactivate) now writes a
  proper, timestamped tombstone that syncs across your devices, and *nothing* auto-resurrects it: a
  passive re-announce from any member (or your own relay reopening) no longer brings it back, a stale
  re-add can't beat a newer delete (last-writer-wins on the actual timestamp), and launch/bootstrap
  adopt skips relays you've deleted. A deleted relay returns ONLY when you explicitly re-add it. (Fixes
  a family of resurrection paths — the "I delete it and it keeps coming back" loop.)
- **Your own relay accepts your own devices.** A headless/NAS relay authorizes members by account id
  from its link, but a device connects as its device id, so it was rejecting your phone's messages
  (`ERR forbidden`). Your device now publishes its account-signed device roster to the relay, which
  verifies the signature and authorizes your device ids — messages and DMs flow through your own relay.
- **Media lands on any reachable relay** (permission-free), so a video reaches a hosted/NAS relay over
  iroh even when a circle's own relays are offline, and replicates from there.

## [0.1.0-beta.37] — 2026-07-13

### Fixed
- **Your own relay rejected your own devices ("ERR forbidden"), and deleted relays kept coming back.**
  Two symptoms, one cause: a device connects to a relay as its DEVICE id, but your devices didn't
  reliably learn each other's device ids, so each rejected the other — and relay-deletion tombstones
  (which ride the same channel) never propagated, so a device kept re-announcing relays you'd deleted.
  Two fixes: (1) each device now publishes its own device roster over self-sync, so your devices
  recognise each other over any relay they share; (2) a **headless/docker relay** — which only knows
  account ids from its invite link and so forbade every device — now accepts an **account-signed device
  roster** written to `haven/devroster/<account>`, verifies its hybrid signature without decrypting
  anything, and authorizes that account's device ids. Requires the relay AND the app on beta.37.
- **Media had nowhere to land is now mirrored to every reachable relay.** Media keys are permission-free
  on a relay (a relay can forbid a device's messages while still storing its media), so media is now
  mirrored to — and fetched from — every known relay, not just a circle's own. A video lands on any
  reachable relay (e.g. a hosted/NAS relay) even when the circle's own relays are offline, and mesh
  sync replicates it onto the circle's relays when they return.

## [0.1.0-beta.36] — 2026-07-12

### Fixed
- **Posting a large video crashed the app instantly.** Sealing a video for backup passed the whole
  sealed blob back across the Rust↔Swift boundary as one contiguous buffer; on a big clip that single
  allocation trapped (`EXC_BREAKPOINT`) and killed the app before anything synced. Large media is now
  sealed **file→file in native memory** (`seal_circle_media_file`, symmetric to the existing decrypt
  path) and streamed to the mailbox in 8 MB windows, so a 600 MB+ video posts without a memory spike.
- **DMs couldn't be stored on a shared relay.** A relay configured with any circle's membership
  rejected every direct-message operation with `ERR forbidden`, because DM conversations are never
  registered on a relay whose host isn't a DM participant — silently breaking offline DM delivery.
  DMs are now accepted from any known member of the relay (strangers still refused; DM bodies stay
  end-to-end sealed, so a relay can carry but never read them).
- **Media had nowhere to land when a circle's relays were unreachable.** Media is now mirrored to —
  and fetched from — any reachable relay you share (bootstrap relays, and any reachable known relay
  when the circle's own relays are down), not only the circle's configured relays. Content-addressed
  media replicates onto the circle's relays via mesh sync once they return.
- **"My posts sync again and again" heat/traffic.** Media that couldn't reach any relay was re-read,
  re-sealed and re-uploaded every 2 minutes forever. It now backs off exponentially (2 min → capped
  1 h) and clears the moment the blob lands anywhere.
- **Post camera: sideways portrait video + rough UX.** Portrait clips recorded sideways because the
  capture rotation was only set when the device rotated; it's now locked from the physical device
  orientation at record-start, so portrait records portrait. The camera is portrait-locked so the
  shutter never moves (always one-hand reachable) while rotating still captures landscape/portrait
  automatically; the filter strip is collapsed by default (a toggle reveals it, clear of the shutter);
  and pinch-to-zoom was copied over from the story camera.
- **One bad relay could stall all the others.** Relay operations now time out (12 s dial / 30 s op)
  so a single hung relay can't freeze the serial fan-out, and a relay is only reported reachable after
  a real operation succeeds — not merely because a client object was constructed.
- **Mac rang nonstop for 20+ minutes.** An incoming-call ring had no upper bound: if the caller's
  fire-and-forget hangup frame never arrived (caller offline, dropped frame, or a stale invite
  copy delivered late through a relay hop), the looping ringtone played forever. Ringing now
  always stops after 60s and records a missed call (a "Missed call" notification is also posted
  when the caller cancels before you answer). Declining can no longer be re-rung by the caller's
  in-flight invite retransmits (ended sessions are tombstoned past the ~30s retransmit burst),
  and group invites now carry a send timestamp — a copy older than 3 minutes never rings.
  The timestamp is a 4th length-prefixed field on frame 21; Android/desktop parsers already
  ignore trailing fields (locked in by new wire tests on both), so cross-platform calls are
  unaffected. Android/desktop should adopt the same bounded ring + timestamp next.
- **Relay-hosting Mac kept the display awake for days.** Hosting the in-app relay held a
  `PreventUserIdleDisplaySleep` power assertion (misleadingly named "Haven media playback") for
  the app's entire multi-day lifetime — observed at 69+ hours. The Mac assertion is now
  `PreventUserIdleSystemSleep` named "Haven relay hosting": the display sleeps normally while
  the machine stays awake to keep serving the mailbox. (iOS keeps the screen-on behavior — the
  app only relays while foregrounded.)

## [0.1.0-beta.35] — 2026-07-12

### Fixed
- **Deleted relays stop returning — now on Android & desktop too.** A relay you deleted came back
  when its owner reopened the app (their device re-announced it, and the old owner-gate reactivated
  it, ignoring your deletion). Relay tombstones are now timestamped last-writer-wins: a deleted relay
  reactivates only on a genuine re-add newer than your deletion, never on a mere reopen; a
  merely-deactivated (not deleted) relay still comes back when its owner re-announces it. The relay
  announce carries an `addedAt` adoption stamp, byte-compatible across iOS/Android/desktop. Legacy
  tombstones are migrated on load. Ships on Apple as 1.0.3; this brings the same fix to Android and
  the desktop app. (Re-delete any already-resurrected relay once on the fixed build; it then stays
  gone.)

## [0.1.0-beta.34] — 2026-07-10

### Fixed
- **Crash + runaway heat: iroh path-management out-of-memory — all platforms.** Upgraded the
  transport stack (iroh 1.0.0 → 1.0.2, QUIC engine noq 1.0.0 → 1.0.1) to fix an unbounded
  path-queue growth that OOM-crashed the app after minutes on a real network and drove the device
  heat. Full detail below (it was diagnosed from an iOS TestFlight crash, but the leaking code is in
  the shared core, so Android, desktop, and the relay all get the fix). See beta.33 notes.

## [0.1.0-beta.33] — 2026-07-09  ·  App Store 1.0.1

### Fixed
- **Crash + runaway heat: iroh path-management out-of-memory (the real dominant cause).** A
  TestFlight crash report showed a Rust `handle_alloc_error`/`rust_oom` abort deep in iroh's QUIC
  path manager — `VecDeque::grow` inside `open_path_on_conn` / `RemoteStateActor::open_path_on_all_conns`
  — i.e. an unbounded queue growing as the connection's network paths flapped open/abandoned, until
  the app ran out of memory (~6.5 min on a real network). This path-flap churn was also burning CPU,
  making it the dominant device-heat source above the UI issues fixed earlier this wave. Upgraded the
  transport stack — **iroh 1.0.0 → 1.0.2** and its QUIC engine **noq 1.0.0 → 1.0.1** — whose changelog
  specifically fixes "unbounded accumulation of pending path responses," `PATH_CIDS_BLOCKED` handling
  for abandoned paths, and an `active_connections` underflow: exactly this failure mode. (The path
  count can't be tuned down as a workaround — iroh ignores `max_concurrent_multipath_paths` below its
  recommended floor of 13 — and disabling multipath would regress cross-NAT media delivery.)
- **Random non-delivery of posts/stories/messages in circles — the big one.** A member could
  silently never receive a post even after everyone handshook and approved. Root cause: the relay
  mailbox marks a content key "seen" (persistently) the moment the bytes are fetched, but the
  buffer that holds an event waiting for its epoch key-commit or the sender's device roster
  (`pending_epoch`) was IN-MEMORY only — killing the app dropped it, and the mailbox never
  re-served the key (deterministic re-seal ⇒ same key ⇒ filtered by the seen-set). Now the buffer
  is **persisted** and re-drained on every key-commit AND roster arrival, and an "unknown sender"
  event (multi-device roster lag) is buffered instead of dropped. The engine state is also saved
  after a poll that only buffered, so nothing is lost on a kill. Regression test added: an event
  received before its key commit survives a restart and is recovered when the commit lands.
- **Media now pulls from the relay's stored copy first.** `requestMissingMedia` fired the direct
  peer-to-peer request alongside the relay restore, so an online author streamed the bytes
  device-to-device even though the relay already held them (heat + bandwidth on both ends). The
  relay/S3/own-store restore is tried first; the direct ask is a fallback only when there's no
  mailbox or the stored copy can't be fetched.
- **Relay copies no longer expire while people still want them.** A post was refreshed against the
  relay's 30-day GC only by its AUTHOR, so an author offline 30 days lost the post for everyone. Any
  active member now TOUCHes the mailbox keys it holds on the daily pass — any online reader keeps a
  post alive.
- **Device overheating — adaptive sync cadence.** The biggest heat source was a 20s timer blasting
  hello+roster to every contact across every circle, re-announcing relays, and mesh-dialing sibling
  relays — every 20s, forever, even with the app open and idle. Both sync timers are now adaptive:
  they keep a cheap heartbeat, but the expensive fan-out/poll only runs when due (20s/30s base,
  stretching to 60s/90s after 3 min idle, 120s/180s after 15 min). Any real activity — foreground, a
  post you send, a message arriving, a peer connecting — snaps the cadence back to tight instantly,
  and pushes still wake the app for immediacy. An open-but-idle phone no longer runs the radio hot.
  Now on **all three platforms**: iOS/macOS, Android (`HavenNet` sync loop), and the desktop Tauri
  engine (`engine.rs` mailbox loop) share the same base intervals, idle multipliers, and reset triggers.
- **No more re-downloading old posts on every launch (device heat).** The mailbox "seen" cursor was
  saved on a 2s debounce and lost if the app was killed during the initial sync burst, so the next
  launch re-fetched + re-verified the whole mailbox. It's now flushed synchronously on
  backgrounding. Idle churn cut too: the 50-event re-seal + media push for nearby catch-up run only
  when a nearby peer is actually connected, and multi-device self-sync is throttled from every 30s
  to ~2 min.
- **Calls: less lag, pixelation, and audio drop-out.** The video encoder now prefers **H264**
  (hardware on Apple) instead of possibly landing on software VP8/VP9 that pegs the CPU and starves
  audio; senders are bitrate-capped and set to **degrade gracefully** (resolution + framerate drop
  together under pressure) so audio wins the CPU fight.
- **A removed relay can be re-added again.** A removed relay could never be re-announced to members
  (the owner-gate can't recognize an external relay's owner). Relay tombstones are now timestamped
  LWW: a re-add newer than a member's "forgot" time reactivates and repopulates across the circle,
  while a stale echo (older adoption stamp) still loses — no zombie relays.
- **The Docker relay keeps its node id across restarts.** Set `HAVEN_RELAY_SEED` (64 hex,
  `openssl rand -hex 32`) to pin the relay's identity independent of the `/data` volume — a
  recreated container no longer mints a new node id the circle has to re-adopt. Documented in the
  compose file + relay README.

- **Choppy scrolling everywhere + device heating within seconds (the real cause).** Every inbound
  network frame — every peer hello, every media chunk — unconditionally set `@Published`
  `internetActive`/`nearbyActive = true` on `FeedStore`, the object the entire UI observes. Because
  `@Published` fires a change notification even when the value is unchanged, this re-rendered the
  WHOLE app on every packet: during a media transfer (~30–80 chunks/sec) or a post-background
  reconnection burst, that's dozens–hundreds of full-UI re-renders per second — the app-wide scroll
  jank and the "warm in seconds" heat, and worse after backgrounding (all contacts reconnect at
  once). Now it publishes only on the real false→true transition. Also: the "last seen" tracker
  serialized its whole dictionary to disk on the main thread on every DM message during a sync
  burst — now debounced to one write per few seconds. (A related earlier fix: the Messages-tab
  unread badge was decoding a full feed per DM conversation on the main thread inside the
  per-refresh hot path — now event-driven only.) Diagnosed from the device's own iroh connection
  trace (which ruled out a networking runaway) plus the frame-dispatch path.
- **Contact avatars re-decoded on every render (main-thread JPEG decode).** `PeerAvatar` looked up a
  contact's avatar in its `body` — which base64-decoded the string and built a brand-new `UIImage`
  (JPEG-decoded on the main thread at draw) on *every* render, for *every* avatar on screen, also
  defeating UIKit's own decoded-bitmap cache. On-device Time Profiler (over USB) showed this as the
  image-decode cost that spiked the main thread during render bursts. Decoded avatars are now cached
  per contact and invalidated when the photo changes — so scrolling and app-switcher snapshots no
  longer re-decode every face. (Profiling also confirmed the post-quantum signing crypto runs 100%
  off the main thread, so it costs battery during sync but never blocks scrolling.)

### Added
- **Storage usage + "keep my own posts".** Settings → Storage shows how much space synced media
  uses on this device. When auto-delete is on, a new "Always keep my own posts" toggle preserves
  your own posts in your feed as a personal archive (a sender-set expiry on your own post still
  applies). The auto-delete footer now states the semantics plainly: it only tidies YOUR view and
  never deletes anything for anyone else.

## [0.1.0-beta.32] — 2026-07-09

### Added
- **DM unread badges (Android + desktop).** Same feature as beta.31's Apple badges, ported:
  Android gets the pill on conversation rows (pinned rows included) plus a Messages tab badge;
  desktop gets it on thread rows, pinned tiles, and the sidebar Messages badge (which previously
  showed the *total* thread count — it now counts conversations with unread). All three
  platforms share the `setting:dmLastRead` self-sync key (JSON map circleId → unix-ms, per-key
  MAX merge), so reading a thread on any device clears its badge on every other, iPhone ↔
  Android ↔ PC alike. Android: `DmRead` (SharedPreferences); desktop: `Prefs.dm_last_read` + a
  `mark_dm_read` Tauri command. No core changes — self-sync keys are opaque pass-through.
  (Landed just after the beta.31 tag was cut, so it ships as its own release.)

## [0.1.0-beta.31] — 2026-07-09

### Fixed
- **Desktop/relay release builds restored.** The beta.30 `release` workflow failed to compile
  (`Engine::moderation_flag` used reqwest's `.json()` but the desktop crate builds reqwest with
  `default-features = false`, no `json` feature) — so the latest GitHub release shipped with no
  Windows/Linux/flatpak/relay assets and the website's download cards sat on "Building…". The
  ledger ping now serializes its body explicitly.

### Changed
- **Website reflects launch.** haven's landing page no longer says "free while in beta":
  iPhone/iPad/Mac are live on the App Store as a one-time $9.99 purchase; the Android and
  desktop betas remain free until they ship. Download section headline updated to match.

### Added
- **DM unread badges (Apple platforms).** Conversations now show an unread-count pill — on the
  row, on the pinned tile's avatar (iMessage-style), and on the Messages tab (which counts
  conversations with unread, not raw messages). Read state is a per-conversation watermark
  (`DMReadStore`): persistent across launches, advanced only by actually opening the thread —
  opening the Messages tab no longer clears anything. Watermarks self-sync across your devices
  with a per-key MAX merge (monotonic, so a fresh device can never "un-read" a sibling), and are
  seeded on first run so pre-existing history doesn't light every conversation up as unread.

## [0.1.0-beta.30] — 2026-07-06

### Added
- **Zero-tolerance terms of use gate (Apple platforms; App Review 1.2).** Agreeing to the terms
  is now the only door into Haven: new users agree as the final onboarding step ("I agree —
  enter Haven"), and anyone already past onboarding — upgraders, restored identities, linked
  devices (whose flows skipped onboarding's last step) — hits a standalone full-screen
  `TermsGateView` on next launch. The in-app summary spells out zero tolerance for
  objectionable content or abusive users, what's never allowed, circle enforcement
  (report/remove/block), and the content-free moderation ledger; the canonical text lives in
  `docs/TERMS.md` (linked in-app). Acceptance is versioned (`haven.terms.acceptedVersion`) so
  materially revised terms re-prompt everyone.
- **Decentralized content reporting (Apple platforms; App Review 1.2).** Haven circles have no
  owner and the developer holds no keys, so moderation belongs to the members: a new sealed
  `Report` event (`core`: `EventKind::Report`, `report()`/`reports()` FFI) broadcasts a report
  to the WHOLE circle — reporter, reported author (full node hex, resolvable even on devices
  that never received the post), offense category, and an optional note that never leaves the
  circle. Reporting hides the post for the reporter instantly and can block the author in the
  same motion; every other member sees a "Reported by …" banner on the post with their own
  actions (hide for me / remove from circle / block). Older clients drop the unknown event kind
  safely. Reports and blocks also append a **content-free entry to a permanent moderation
  ledger** on the push Worker (`/flag`): actor node id × subject node id × action × category —
  identity-vs-identity only, no content, no PII, so abuse patterns (many reporters × one
  identity) stay visible in a system where the developer can see nothing else.
- **Content reporting on Android and desktop (parity).** The same decentralized moderation UI on
  the other two platforms: Android gets a report sheet (`ui/ReportUI.kt` — the five Apple-identical
  categories, optional circle-only note, "also block" toggle, instant local hide via
  `HiddenStore`), the "Reported by …" banner with per-viewer actions (hide for me / remove from
  circle / block), and ledger pings (`core/Moderation.kt`); the Tauri desktop gets
  `report`/`reports` commands, the same report dialog + reported banner in the web UI, and a
  backend-side ledger ping (`Engine::moderation_flag`) that also covers every block. Category
  wording is identical across platforms so ledger entries aggregate cleanly.

### Fixed
- **macOS UI polish sweep: glass, pills, and single surfaces everywhere.** The Mac app's chrome
  had accumulated doubled control surfaces and stock-AppKit artifacts. New design vocabulary in
  `Theme.swift` — `havenGlass` (real Liquid Glass on macOS/iOS 26+, material fallback below),
  circular/pill glass button styles, a one-surface pill text-field style, and a `HavenMacSheet`
  scaffold that runs the brand gradient to a sheet's extreme edges with glass chrome. Applied
  across the app: the report sheet is a hand-rolled column (macOS Form's label column shifted
  everything right), every custom-shaped text field drops the system bezel that doubled inside it
  (onboarding name, edit profile, edit post, connect, restore, location label), the video mute
  chip no longer draws a rectangular bezel behind its circle, sheet toolbar text buttons are
  glass pills, the in-app browser header uses glass chips, and onboarding/terms/edit-profile/
  connect/device-link center a readable column instead of smearing across wide Mac windows.
  iOS keeps its shipped look (all chrome changes are macOS-conditional or visually identical).
- **Call audio has priority: no post music or video sound while a call is ringing, connecting,
  or live (all platforms).** Feed songs, story soundtracks, the DM song pill, and video audio
  could keep playing (or be started by scrolling) over an active call. Now a starting call
  silences whatever is playing immediately — the outgoing dial and the incoming ring both hook
  the same silencer — and every raise-audio path is gated for the whole call lifecycle, at the
  playback chokepoints so no entry point can sneak sound back in: Apple `MusicPlayback`
  play/resume/unduck + `AudioCoordinator` (feed videos stay playing, muted; stories mute their
  clip mid-call via the call state), Android `MusicPlayer.toggle` + `VideoTile` volume (feed +
  stories; recomposes on call state), desktop `syncFeedVideoSound()` (every `<video data-video>`
  forced muted from first ring to teardown). Normal sound rules resume when the call ends —
  nothing auto-blasts; playback comes back through the usual feed interactions.

## [0.1.0-beta.29] — 2026-07-06

### Fixed
- **Media backup no longer re-reads + re-seals whole video files just to discover nobody
  needs them.** `backup(ref:)` (iOS/macOS), `uploadMedia` (Android) and `upload_media`
  (desktop) loaded the ENTIRE media file into RAM — and on Apple re-sealed it (~2× the file
  size transient) — whenever ANY destination relay wasn't yet confirmed in the backup ledger,
  even if that relay was unreachable or in backoff. On macOS this meant a 522MB and a 673MB
  video were re-sealed on EVERY backfill pass (multi-GB RSS spikes every ~2 minutes, forever,
  for relays that were never coming back). The media key is content-addressed (independent of
  the sealed bytes), so all three platforms now run an existence-probe phase FIRST: confirmed
  blobs go straight into the ledger, and the file is only read + sealed when at least one
  destination is actually reachable AND missing it — a relay that's unreachable or inside its
  RelayHealth backoff window is skipped without touching the file. Desktop additionally gains
  the persisted `media-backed-up.txt` ledger it never had (iOS `MediaBackupLedger` / Android
  `backedUp` parity — it used to re-upload every blob to every relay every 2 minutes).
- **The build-174 runaway leak / watchdog kernel panic: dials are now single-flight per peer.**
  The Mac app hit 100% CPU on one background thread with footprint growing ~41MB/s
  (7.0→10.4GB in 88s, jetsam lifetimeMax ~170GB overnight, then a watchdog panic). Symbolicated
  hot stack: `iroh RemoteStateActor::open_path_on_all_conns` — per-peer path-actor churn.
  The iroh trace showed the driver: bursts of 4–10 **concurrent** `endpoint.connect` calls to
  the SAME offline device id, microseconds apart (~9 dials/sec sustained; 6,688 connecting
  events vs 387 connected in one 24-min session). The per-peer dial gate couldn't stop it:
  it's checked *before* `connect` but only updated when a dial *finishes* (~30s for a dead id),
  so every send queued inside that window opened its own doomed `Connecting`, each one churning
  iroh's path machinery. A busy sync cycle fans out dozens of sends per peer (account→device-id
  expansion, restored to FULL device lists by the beta.28 roster healing — why 174 tipped over).
  `conn_for` now holds a per-peer async lock across the dial: concurrent senders queue, then
  either reuse the winner's connection or bail on the gate the winner's failure just set. A
  burst to one dead id collapses to ONE dial (regression-tested: `dial_single_flight.rs`).
  Verified live on the Mac: connect volume dropped ~40× and RSS holds a flat ~1.4GB baseline
  where build 174 grew without bound.

## [0.1.0-beta.28] — 2026-07-05

### Fixed
- **iOS→iOS calls now ring with Haven backgrounded or killed.** The PushKit→CallKit pipeline
  existed end-to-end but four defects kept it from ever ringing in the background:
  1. **The PKPushRegistry was only created in SwiftUI `.onAppear`** — a VoIP push that
     launches a killed app in the BACKGROUND never renders a view, so no registry existed,
     the queued call push had nowhere to land, and the phone stayed silent until Haven was
     next foregrounded. PushKit requires the registry by the end of `didFinishLaunching`;
     it's created there now (synchronously).
  2. **One VoIP token slot per account on the push worker** — every launch of ANY linked iOS
     device overwrote `voip:<nodeId>`, so only whichever device registered last could ring.
     Now a token LIST (like `/register`), `/call` pushes every device, dead tokens pruned.
  3. **A push-rung call could never become a working call.** The VoIP push rings with a
     placeholder session (`push:<caller>`); when the real frame-21 invite caught up it was
     DROPPED (session-id mismatch), and every SDP frame then failed `validSession` — answering
     from the CallKit screen produced a dead call. The placeholder now ADOPTS the real session
     (from the invite, or from the first offer in the answer-before-invite ordering), and
     re-accepts under the real id if the user already picked up.
  4. **`/call` did NOTHING when no VoIP token was registered.** It now falls back to a loud
     time-sensitive alert push through the regular token path ("📞 Incoming call" via the NSE;
     macOS gets its silent-decrypt banner), and both paths carry `apns-expiration` (~45s) so a
     late-delivered doorbell can't ring a call that's already over.
  Requires `cd push && wrangler deploy` + shipping the app to BOTH parties.
- **The same notifications fired again and again (all platforms).** Three compounding causes:
  the local-notification dedupe set was in-memory only (every relaunch forgot what was already
  notified — and at its 3000-entry cap it wiped ENTIRELY, re-arming every past banner);
  "notify newest" fired on ANY change in a circle (history backfill, key commits, epoch-
  rotation re-seals of old events) and then described the newest EXISTING message rather than
  what actually arrived; and Android/desktop had no dedupe at all (desktop notified per
  changed envelope, including key commits). Now: the dedupe store is PERSISTED on every
  platform (iOS/macOS `haven-notified.txt`, Android prefs, desktop `notified.txt`), caps trim
  instead of wiping, and a banner only fires when the circle's newest inbound item is
  genuinely fresh (< 10 min) — an old message resurfacing is never worth a banner. (The
  roster-revocation fix above removes the biggest churn *generator*; this makes banners
  immune to any future re-delivery/churn source too.)

### Added
- **Relay mailbox garbage collection (all platforms + CLI relay).** Deterministic sealing
  stopped NEW duplicates, but the thousands of legacy ones (a random-sealed copy of every
  event per backfill run, plus a full stale copy per epoch rotation) sat on every relay
  forever: each 30s poll re-LISTed ~6,700 keys (~700 KB per list from a remote relay) for an
  88-event circle, and mesh sync re-circulated the dead entries between siblings for good.
  Entries are opaque to the relay and live keys are never re-PUT (`has()` hits skip the
  write), so a bare mtime TTL would have eaten live history, and a deletion on one relay
  would be resurrected by the next anti-entropy pass. Shipped as three cooperating parts
  (`core/haven-net/blobstore.rs`, identical over iroh `haven/blob/1` and the HTTP relay):
  1. **`TOUCH` (iroh `T` / `POST /t/<prefix>`)** — daily, each member sends the refs of every
     envelope it can deterministically re-seal (own events + current key commit + roster) in
     ONE batched request per relay; the relay bumps those entries' liveness (mtime) and
     replies with the keys it lacks, which the client re-PUTs — the refresh doubles as repair
     and self-heals a relay that GC'd a long-offline member's history. `HAS`/`HEAD` hits
     refresh too; the host's own in-process relay is touched locally (no iroh self-dial).
     Client wiring: iOS/macOS `SharedStore.refreshMailbox` off the daily backfill gate (now
     also re-checked on the 30s poll timer so an always-open Mac refreshes without a
     relaunch), Android `refreshMailboxKeys` off the persisted daily gate, desktop
     `Engine::refresh_mailbox` off a new daily gate in the 15s loop.
  2. **TTL sweep** — every relay host (CLI daemon, in-app RelayHost on iOS/Android/desktop,
     `BlobServer`) hourly deletes `haven/mailbox/**` entries idle > 30 days plus abandoned
     `.part` files; media and self-sync slots are never swept. A `.haven-gc-enabled` marker
     delays the first deletion by 48h so members get a refresh cycle in before anything goes
     (pre-GC stores have ancient mtimes on LIVE entries too).
  3. **Age-preserving mesh sync (`AGES` verb)** — anti-entropy now exchanges `(key, idle-age)`
     pairs, skips mailbox entries already past the TTL (never resurrect what's dying
     elsewhere), and back-dates pulled files by the peer's age, so dead entries age
     monotonically across the whole mesh instead of ping-ponging back with fresh mtimes.
     Falls back to plain `LIST` (everything fresh) against a pre-GC sibling.
  Net: legacy duplicates, stale-epoch copies, and retention-expired events all age out of
  every relay within one TTL; the 30s poll LIST shrinks to the live set. Authorization
  unchanged in spirit: TOUCH follows PUT's membership rules, broad prefixes are refused to
  non-relays, and a member can only keep entries alive — deletion is purely the relay's local
  TTL policy. Accepted tradeoff (documented): an author inactive on ALL devices for > 30 days
  drops off relays until their next refresh re-PUTs everything; devices stay the source of
  truth. Also pinned `RUSTC` in `android/build-rust.sh` (parity with the Apple script) so a
  Homebrew rust can't shadow rustup's Android-capable toolchain.

### Fixed
- **Own-device revocation flip-flop — posts not syncing between your own devices (all
  platforms).** The account's device roster had the Mac's own device id stuck in `revoked`
  (observed live: roster v54 with the Mac's transport id revoked), so siblings never dialed it
  directly and every roster exchange re-signed + rotated every circle's epoch (`my_epoch: 76`
  on an 88-event circle). Two compounding bugs: (1) `DeviceList` union-merge treated `revoked`
  as grow-only, so the explicit re-authorization `register_device` performs at launch was
  re-tombstoned by ANY older roster copy — un-revocation could never propagate. Where two
  account-signed copies now disagree about a revocation, the strictly-newer version's verdict
  wins (replays have lower versions; ties keep the revocation). (2) iOS and Android
  self-registered BEFORE importing persisted state, so the imported (higher-version) roster
  clobbered the registration every launch — registration now runs after import (desktop already
  did). Ship to ALL your devices: an un-updated device keeps re-adding the tombstone.
- **Deleted/deactivated relays stop resurrecting (all platforms).** Every member re-announces
  every relay it holds proof-of-life for, and ANY announce reactivated a deactivated/forgotten
  entry — so a relay you deleted but which is still running somewhere (an old docker container)
  bounced back within one sync tick, forever. Reactivating an existing tombstoned entry now
  requires the announce to come from the relay's OWNER (the announced id is one of the sender's
  authorized device ids, or their account id for legacy account-id relays), authenticated via
  the sealed announce's verified sender (new FFI `open_circle_media_sender`). Third-party
  echoes of a tombstoned relay are dropped; brand-new relays still auto-pool.
- **Posts now carry their key commit to the mailbox.** With the full-history backfill throttled
  to daily, a relay-only peer could receive an event sealed under a fresh epoch long before the
  commit that opens it (it sat undecryptable in the pending-epoch buffer). Every authored event
  now uploads the epoch head (roster + current key commit, new FFI `export_epoch_head`)
  alongside it — near-free, since the commit is cached until the epoch/recipient set changes
  and the persisted seen-set dedupes.
- **30-second cold start on the circle feed, root-caused and fixed (all platforms).** Two
  compounding bugs:
  1. **The mailbox seen-set wasn't persisted.** Every cold start treated the ENTIRE relay
     mailbox as new and re-downloaded + re-verified every envelope — a real circle had
     accumulated ~6,700 mailbox entries for 88 events, so launch burned 30+ seconds on hybrid
     signature verification of duplicates the engine then discarded. The ingestion cursor now
     persists across launches (iOS/macOS `haven-mailbox-seen.txt`, Android
     `haven_mailbox_seen.txt`, desktop `mailbox-seen.txt`), and a key is only marked seen once
     its bytes are actually in hand (a failed download is retried instead of skipped forever).
     Identity reset/adoption wipes the cursor. (First launch after this update re-scans once to
     seed the cursor; every launch after that is fast.)
  2. **The mailbox grew without bound.** Backfill re-sealed the whole history on every launch
     (iOS) / every 2 minutes (Android), and every re-seal produced fresh random bytes — so the
     content-addressed mailbox key was NEW each time and relays accumulated a copy of every
     event per run. Event envelopes now seal **deterministically** (salt is a PRF over the
     plaintext keyed by the epoch key; nonce derived from the per-plaintext event key; the
     hybrid signature was already deterministic), so a re-seal reproduces byte-identical
     envelopes, the relay's `has()` dedupe finally works, and the mailbox stays at one entry
     per event per epoch. An edit derives a fresh salt → fresh key + nonce, so AES-GCM never
     reuses a (key, nonce) pair across distinct plaintexts; no wire change — old receivers just
     read the carried salt/nonce. Key commits (necessarily KEM-random) are cached — and
     persisted with the engine state — per recipient-set, so backfills reuse the same commit
     bytes until the epoch/membership/device set actually changes.
- **Full-history event backfill throttled to daily.** New-relay adoption and share-history
  still backfill immediately; the launch-time (iOS/macOS) and 2-minute-tick (Android) sweeps
  now run at most once a day — the re-seal is a hybrid signature per event, and the daily run
  is a cheap no-op thanks to the persisted seen-set + deterministic envelopes. The iOS re-seal
  also moved off the main actor.
- **`iroh-trace.log` capped.** The connection-diagnostic log grew unbounded (370MB observed on
  a daily-driver Mac) and re-opened the file for every line; it now starts fresh past 16MB and
  reuses one handle.

## [0.1.0-beta.27] — 2026-07-05

### Fixed
- **The frozen feed, root-caused and fixed (iOS/macOS).** "Swiping on a tall video post doesn't
  scroll" turned out to be TWO bugs, both reproduced and verified fixed live in the simulator:
  1. **A main-thread DEADLOCK froze the entire app** — not just scrolling. The sync-status badge
     re-evaluates on a schedule and synchronously read `MCSession.connectedPeers`, which
     dispatches into MultipeerConnectivity's internal queue; while the nearby mesh was busy
     (media chunks streaming — e.g. right after a video post, or whenever your Mac's Haven is in
     Bluetooth range) that read deadlocked against MC's receive thread. The app kept rendering
     its last frame but every touch was dead. Peer state is now cached from the session delegate
     (the sanctioned path); nothing touches MCSession synchronously anymore.
  2. **The video scrub gesture blocked the feed's scroll pan** — on iOS 26 a SwiftUI DragGesture
     on the video surface eats vertical swipes even when attached as `simultaneousGesture`
     (bisect-verified). The scrub is now a UIKit pan recognizer on the player surface that
     REFUSES to begin unless the movement is horizontal — vertical swipes never engage it, so
     the feed scrolls natively; horizontal drags scrub exactly as before (verified: scrub bar
     live in the same session where vertical swipes scroll).

## [0.1.0-beta.26] — 2026-07-04

### Fixed
- **Vertical swipes on tall videos scroll the feed — for real this time (iOS/macOS).** beta.25
  fixed the scrub gesture but missed the second eater: hold-to-pause was a HIGH-PRIORITY
  long-press whose sequenced drag claimed the whole swipe whenever your finger rested for 0.2s
  before moving — exactly how deliberate scrolls start. It's now simultaneous (video posts have
  no context menu to out-prioritize); a slow scroll may briefly pause the video and it resumes
  on lift.
- **Dead relays stop resurrecting and posing as "Reachable" (all platforms).** beta.22 made every
  member re-announce every relay id they'd ever learned — an echo chamber: dead relays came back
  on every device (receivers deliberately reactivate announced relays), media uploads kept
  burning timeouts against ghosts ("keeps reporting it is sending"), and the storage UI showed
  green for anything that simply hadn't been dialed lately. Announces are now LIVENESS-GATED:
  a device only re-announces relays IT completed a successful operation against within the last
  5 minutes (plus the relay it hosts) — a live relay is re-proven constantly by the mailbox
  poll, a dead one goes silent everywhere and ages out. The relay list now shows "Reachable"
  only with a proven success in the last 15 minutes ("Not verified recently" / "Unreachable —
  retrying" otherwise), so the status finally reflects reality. Forgotten relays stay forgotten.

## [0.1.0-beta.25] — 2026-07-04

### Fixed
- **Tall videos no longer block feed scrolling (iOS/macOS).** The video scrub drag was attached
  at high priority, so it won the gesture race for ANY movement — including vertical — and its
  internal "is this horizontal?" bail-out couldn't give the gesture back: a tall video was a
  wall you couldn't scroll past. Now: vertical swipes always scroll the feed (single-video
  scrub is simultaneous + axis-checked; the carousel scrub strip is capped at 96 pt instead of
  a third of the video), horizontal swipes page a carousel or scrub, and the full-screen viewer
  pages off video items (its full-area scrub used to eat every horizontal drag) while
  swipe-down-to-dismiss now works on video pages.

## [0.1.0-beta.24] — 2026-07-04

### Fixed
- **Runaway memory growth that killed call audio (iOS build 167 jetsam at 2.3 GB).** Crash logs
  off the phone showed a single core thread at ~79% CPU growing the app 202 MB → 3 GB in under
  two minutes: iroh's per-peer path actor spinning close → re-open-path → close against a
  FLAPPING peer (a relay whose key was bound by two endpoints — the daemon bug fixed in
  beta.23), allocating fresh QUIC state each lap until the system started killing audio daemons
  mid-call. Defense on the app side: the per-peer dial backoff is now flap-aware — a connection
  that dies within 30 s counts as a dial FAILURE (30 s → 10 min cooldown) instead of resetting
  the backoff, so a flapping peer costs one short-lived connection per cooldown instead of a
  continuous churn loop. (Connections that live ≥ 30 s clear the backoff as before.)
- **Call audio now recovers instead of going permanently silent (iOS).** The app had no
  handlers for audio interruptions, route changes, or the system's "media services were reset"
  (mediaserverd dying — e.g. under the memory pressure above). Once that happened, WebRTC's
  mic/playout units stayed dead for the rest of the call and the speaker toggle did nothing.
  CallManager now reconfigures + reactivates the session, reapplies the speaker route, and
  bounces WebRTC's audio unit on media-services-reset and interruption-end; the speaker button
  also tracks the actual output route instead of showing a stale toggle.

## [0.1.0-beta.23] — 2026-07-04

### Fixed
- **Standalone relay daemon (NAS/Docker) no longer flaps "Unreachable — retrying".** The daemon
  ran its media store as a SECOND iroh endpoint under the SAME key as the connection relay
  (`BlobServer::spawn` beside `RelayNode::spawn`) — the same-key second-endpoint bug that caused
  the beta.13 internet outage in the apps: the two endpoints fight over the node id's DERP
  home-relay registration, so inbound dials flap between reachable and dead. The daemon now
  serves the blob mailbox on the relay's OWN endpoint (one node, two ALPNs — the same
  `enable_relay` path the in-app relays have used since beta.13). The opt-in S3 tunnel gets its
  own seed-derived identity for the same reason (its printed `volunteer_node_id` changes once).
  Relay identity, saved link, mailbox contents, and the HTTP media interface are all unchanged —
  update the container and the same relay id just becomes reliably dialable.

## [0.1.0-beta.22] — 2026-07-04

### Fixed
- **Adopted external relays (NAS / Docker daemon) now actually reach circle members (iOS/macOS +
  desktop).** Adding a relay announced it to the circle exactly ONCE, at adopt time; the periodic
  re-announce only ever covered the relay the device itself hosts. A member who was unreachable at
  that one moment never learned the external relay — "I shared my NAS relay with the circle but my
  friend doesn't see it." The periodic re-announce now covers EVERY active relay known for each
  circle (adopted external + all-circles default + self-hosted), over nearby, direct, and mesh
  paths — parity with Android, which already re-announced all circle relays per hello. Receivers
  were already idempotent (only a genuinely new relay triggers the backfill).

## [0.1.0-beta.21] — 2026-07-04

Stability wave: the add-friend handshake and re-adding a previously-removed friend now work
reliably over the internet, on every platform. **Update all of your own linked devices** — the
removal-record fix converges fleet-wide once each device runs this build.

### Fixed
- **Re-adding a removed friend finally sticks (all platforms).** Removal records synced between
  your own devices were grow-only and permanent: every self-sync pass re-applied the severance,
  so a friend you had once removed — then deliberately re-added via a new invite or approval —
  was silently removed again seconds later, their handshakes dropped and their posts hidden.
  This compounded with each release that made "removal sticks" stricter (iOS beta.10, Android
  beta.20) until whole friendships went mute. Removal records are now last-writer-wins per
  entry (`1` = removed, `0` = deliberately re-added): every deliberate re-add path — approving
  a request, scanning an invite, adding back to a circle — clears the tombstone locally AND
  publishes the clear so sibling devices stop re-severing. Desktop also gained the
  removed-member handshake guard (parity with iOS/Android).
- **Reply-path bootstrap now works on relay-hosting devices (core).** The beta.17 fix (learn a
  dialable device id from any direct hello) never worked on a device that hosts an in-process
  relay: the relay's inbound path zeroed the authenticated sender id before delivering bare
  payloads to the app. Since most devices host a relay, a fresh internet invite often left the
  initiator un-dialable by the invitee — "connected but mute". The sender id now survives the
  relay-hosting path; core tests assert it.
- **iOS/macOS: a freshly-approved friend is dialable immediately.** The 10s dial-target cache
  (beta.18) wasn't invalidated when you approved a connection request or when a handshake added
  a member — the very next sync tick could skip the brand-new friend. The cache now clears on
  every contact/membership change.
- **Android call screen: the share-screen and hang-up buttons are back.** All seven in-call
  controls sat in a single row wider than the screen, silently pushing the last buttons off the
  right edge once the speakerphone toggle landed (beta.20). The controls now match iOS: two
  rows — media toggles (mic / speaker / camera / flip-when-camera-on) above, call actions
  (share screen / add people / hang up) below.

## [0.1.0-beta.20] — 2026-07-04

### Fixed
- **Removing someone from a circle sticks (Android).** A removed member kept reappearing: they
  don't know they're gone and keep broadcasting Hellos, and `handleHello`'s "already a contact"
  branch silently re-added their bundle to the very circle you removed them from. It now honors
  the removal tombstone (parity with iOS); a deliberate re-add still un-bans them.

### Added
- **Android call screen: speakerphone toggle** (loudspeaker ⇄ earpiece via AudioManager, default
  on for video calls; a Bluetooth/wired headset still overrides) and the **add-people button is
  always visible** (dimmed when there's no one left to add) so the control row is stable.
- **Docker Compose for the relay** (`relay/docker/`) — run `haven-relay` on a NAS or home server
  in a container: pulls the static musl binary (amd64/arm64/armv7), persists identity + the sealed
  mailbox to a volume, exposes the `:8674` media interface.

## [0.1.0-beta.19] — 2026-07-04

Launch-polish wave alongside the 1.0.0 App Review submissions (iOS build 166, macOS build 167).

### Added
- **Deep-linked invites on Android + desktop.** Android registered `haven://` but dropped the
  link (ACTION_VIEW unhandled) — it now routes to the Connect screen and connects immediately,
  and a new intent filter offers "Open with Haven" for the invite web link. Windows/Linux
  desktop registers `haven://` at install time (Tauri deep-link) → connect-by-link + focus.

### Fixed
- **Story captions render identically on iOS, Android, and desktop.** Android photos baked the
  caption into pixels with an empty body (the author's position/typography never traveled) and
  used mismatched color/font index tables; desktop neither encoded nor decoded (raw control-char
  text). All platforms now speak the same normalized wire format and match fonts, colors,
  positions, and effect shadows.
- **macOS UI polish**: circular glass icon buttons replace the barely-visible rounded-rect
  chrome; sheets extend the brand gradient edge-to-edge instead of showing gray bands.

### Changed
- **macOS `.dmg` retired** — the Mac app ships on the App Store; all past release dmg assets
  removed and the CI leg deleted.

## [0.1.0-beta.18] — 2026-07-03

### Fixed
- **UI smoothness: the engine no longer runs on the main thread (iOS/macOS).** A main-thread audit
  found the heaviest engine work executing on the main actor: `exportState()` + the atomic state
  write after every post/ingest burst (100-500ms freezes), per-envelope `receive()` crypto during
  mailbox drains and event bursts, the full-feed `feed()` decode + O(posts) filter on every 20s
  tick, N×`deviceNodeIdsFor` FFI calls per sync fan-out, and an O(items×media) disk scan per
  sweep. All now run off-main via Swift structured concurrency: state persistence is serialized
  through an actor (ordered, coalesced), envelope batches ingest on a background task with one
  main-actor apply, the feed rebuild is detached with a stale-result generation guard, dial
  targets are cached 10s (invalidated by fresh rosters/hints), and the media scan is capped to
  once per 2s. Android already ingested off-main (Dispatchers.IO); desktop is Tokio-async.

## [0.1.0-beta.17] — 2026-07-03

### Fixed
- **New internet friends can now talk back ("we're connected but his DMs and profile never
  arrive").** Invite-link dial hints only bootstrap the direction that scanned the link: the
  invitee holds NO dialable id for the initiator, so their hello-back (which carries their
  name/profile), DMs, and posts depended on roster propagation that itself needs a working route —
  a timing lottery. The transport has always AUTHENTICATED each connection's remote endpoint id;
  it's now surfaced through the inbound callback (`InboundListener.on_inbound(from_hex, payload)`),
  and a hello received over a direct connection records the sender's device id as a dial hint for
  their account on all platforms. One successful delivery in either direction now bootstraps the
  reply path instantly; the signed device roster still supersedes hints.

## [0.1.0-beta.16] — 2026-07-03

### Fixed
- **DMs finally land in the relay mailbox ("the push showed her message but the app never
  did").** The relay store's path sanitizer rejected any key component containing `:` — and every
  DM circle id is `dm:<a>-<b>`, so no relay could EVER store a DM envelope: an offline recipient
  got the push banner (which travels via the blind worker) but the message itself had no
  store-and-forward path at all. Disk names are now escaped (`:`→`%3A`, Windows-safe) while keys
  keep their colons on the wire; existing stores are unaffected. Verified live: the first-ever DM
  mailboxes appeared on the relay within minutes of deploying, with history backfilled. Also fixed
  a trailing-slash LIST prefix failing the same sanitizer.

## [0.1.0-beta.15] — 2026-07-03

### Fixed
- **Haven no longer hijacks your music.** Post songs play through the SYSTEM-side application
  music player, which (a) keeps playing even when Haven isn't on screen and (b) steals playback
  focus from the user's own Apple Music session the moment it starts. A background LAUNCH (bg
  fetch / silent push after the app was terminated) builds the feed with no scenePhase change ever
  firing, so the existing "don't auto-play while backgrounded" flag stayed false — the top post's
  song could start playing on the nightstand at 3am, and background refreshes could repeatedly
  yank playback focus from CarPlay (music "self-pausing" mid-drive). Every playback-issuing path
  in `MusicPlayback` (play/resume/unduck, iOS + macOS) is now hard-gated on the app actually being
  frontmost, and the backgrounded flag initializes from the real application state.

## [0.1.0-beta.14] — 2026-07-03

### Fixed
- **Call accept works cross-NAT ("it rang her but she couldn't accept").** Call signaling
  (invite/accept/hangup/SDP/ICE) was DIRECT-only: the push notification rings the callee, but her
  ACCEPT needed a working direct dial back to the caller, with no fallback. Call frames now also
  hop LIVE through up to 3 adopted circle relays as a frame-9 forward (the relay host unwraps the
  inner frame and sends it onward over its own connections). Android and desktop additionally
  learned to process + forward frame 9 (previously iOS/macOS-only, so a phone- or desktop-hosted
  relay couldn't forward at all). Duplicate-tolerant handlers + msgId dedup guard loops.

## [0.1.0-beta.13] — 2026-07-03

THE internet-reliability fix. Every relay-hosting device was unreachable over pure-relay
(cross-NAT) paths — proven by dialing the Mac relay: a direct-addressed dial completed in ~5ms
while the identical relay-path dial timed out at 30s, every time.

### Fixed
- **Relay mesh sync no longer knocks its own node offline.** `sync_pull_from` /
  `relay_sync_from` (the ~20s mesh anti-entropy tick) built its client with
  `BlobClient::connect(self.secret, …)` — binding a FRESH iroh endpoint under the node's OWN id.
  Each tick that ephemeral clone (a) **stole the node's DERP relay registration** (the home-relay
  flapped true→false every cycle, ~2,000 times in one session log), (b) **refused every inbound
  handshake** while it lived (its ALPN list is empty), and (c) died ungracefully after dialing —
  usually a stale, undialable relay entry, burning a 30s timeout. Net effect: inbound relay-path
  connections to any relay-hosting device were a lottery that almost always lost — friends across
  the internet could not fetch posts, media, or call invites from a hosted relay. Mesh sync now
  reuses the node's long-lived endpoint (`BlobClient::over_endpoint`); `BlobClient::close()`
  learned endpoint ownership so a borrowed shared endpoint is never shut down. Verified: relay-path
  blob LIST against the Mac app went from 100% 30s-timeout to ~190ms, zero registration flaps.
- **Per-peer dial backoff at the transport chokepoint.** The 20s sync loop re-dialed every
  unreachable id (friends' pre-multidevice account ids — undialable by design — plus offline
  devices) forever, keeping ~10 doomed handshakes permanently in flight and spamming
  `MultipathNotNegotiated` path-close warnings (~3,300 log lines / 30s). Failed dials now back off
  30s → doubling → 10min cap, reset on success.
- **Standalone `haven-relay` daemon negotiates QUIC multipath** (parity with the in-app node) — a
  multipath-enabled client dialing a non-multipath relay died with `MultipathNotNegotiated` on
  cross-network paths.

### Added
- `haven-net examples/diag.rs` — transport diagnostic (home relay, n0 DNS publish check, timed
  blob dial by node id, `DIAG_DIRECT=ip:port` direct-address bisection) — the tool that isolated
  the ephemeral-endpoint bug.

## [0.1.0-beta.12] — 2026-07-03

Device-id reachability wave: every send site now dials friends by their DEVICE node ids, closing
the gaps that made calls, media, and internet delivery unreliable after the device-seed transport
flip (an account id no longer resolves to any node, so an unexpanded send silently reached nobody).

### Fixed
- **Android call signaling reaches the caller again.** `sendFrame` (which `sendCallFrame` and the
  media request/chunk paths ride) sent directly to the given hex with no account→device-id
  expansion — so a call ACCEPT/ICE/hangup addressed to the caller's *account* id was dropped at the
  iroh layer, even on the same LAN (iPhone rang Android, but Android's accept never came back).
  `sendFrame` now expands to the contact's authorized device ids at the transport edge, exactly
  like iOS `sendIroh` (identity for already-expanded/device-id inputs, so `dialTargets` callers
  stay correct).
- **Desktop dials device ids everywhere.** `send_frame` (posts, DMs, hellos, relay announces, call
  frames, media) gained the same transport-edge expansion; `authorize_membership` now authorizes
  circle members by their device ids too (a friend's device-seed phone was "forbidden" at a
  desktop-hosted relay).

### Changed
- **Desktop moved to the device-seed transport.** The Tauri app bound its iroh node to the ACCOUNT
  master seed (identity == transport address, the pre-flip design). It now mints/binds a per-device
  seed (`use_device_identity` + `register_device`, parity with iOS/Android), announces its signed
  device roster (frame 27) to contacts + circle relays every greet cycle, ingests contacts' rosters
  (re-authorizing its hosted relay), and dials relays over the **warm** long-lived endpoint instead
  of a cold per-fetch endpoint (the cross-NAT 30s-timeout class). The cold fallback and self-dial
  guards now use device ids (never the account id).

### Added
- **Invite links carry device-id dial hints (`?d=`).** The roster-bootstrap deadlock: a friend can
  only reach you after holding your signed device roster, but the roster itself travels over a path
  that needs a dialable id. Invite QR/links now embed the inviter's device node id(s) as a query
  placed *before* the `#` fragment (old parsers read only the fragment, so links stay compatible).
  The scanner stores the hints and dials them at every transport edge until the real signed roster
  arrives and supersedes them. Implemented on iOS/macOS (`InviteHints.swift`), Android
  (`InviteHints.kt`), and desktop.

## [0.1.0-beta.11] — 2026-07-02

Media-transport + LAN wave: direct local connections restored, large videos play on low-heap
Android, media stops re-uploading, and the relay gains a plain-HTTP interface.

### Added
- **Direct LAN connections restored.** The iroh transport had been forced *relay-only*
  (`clear_ip_transports` + a relay-pinning path selector) to dodge a cross-NAT datagram-drop — but
  that routed *every* connection through the n0 DERP cloud, so two devices on the same wifi never
  talked directly and Android↔iOS had no local path at all (Apple's Multipeer LAN mesh doesn't
  bridge to Android's Nearby Connections). Reverted to stock iroh (IP transport on, lowest-RTT path
  selection): same-subnet peers, including Android↔iOS, now connect **directly over the LAN**
  (verified: a direct `Ip(...)` path forms). Media rides the relay-HTTP/S3 transports now, so
  cross-NAT reliability no longer needs direct paths suppressed. (Note: a peer behind macOS firewall
  *stealth mode* stays on the relay path until it's allowed / stealth is off.)

### Fixed
- **Large videos play on low-heap Android.** A 250–650 MB video sealed to the circle couldn't be
  decrypted on a phone whose managed (ART) heap is capped ~512 MB — the whole plaintext came back as
  a `ByteArray` and OOM'd. Decryption now runs in **native (off-heap) memory** via a file-based FFI
  (`open_circle_media_file`) and writes the plaintext to a file the player streams from; bounded by
  physical RAM, not the heap cap. Verified playing at 1080p.
- **Squished video playback.** The player's `TextureView` stretched clips to its bounds; it now
  applies an aspect-fit transform so a 16:9 video is letterboxed instead of distorted.

### Added (relay HTTP)
- **Relay HTTP media interface — the default cross-NAT media transport.** The in-app relay host
  (and the standalone `haven-relay` daemon) now serves its blob store over ordinary HTTP/1.1
  (`core/haven-net/src/httprelay.rs`), alongside the iroh blob ALPN. Because plain HTTP traverses
  any NAT the moment the host is reachable, this is what makes cross-NAT media (videos, large
  photos) actually land — the iroh blob ALPN drops its datagrams over a pure-relay cross-NAT path
  (noq/iroh fork bug). Blobs are E2E-sealed before they hit the wire, so the interface carries only
  ciphertext; it's **bearer-token gated** (one token per relay, generated once and persisted), and
  the token is distributed to circle members ONLY inside the *sealed* frame-19 relay announce.
  `self/…` self-sync slots are never served over HTTP (they stay on the identity-verified iroh
  path). The host advertises its reachable URLs (LAN IPv4s + an optional operator-set public URL
  for port-forward / reverse-proxy / tunnel setups) in the announce; members fetch + upload media
  over HTTP first and fall back to the iroh blob dial only when no HTTP URL is reachable.
  `haven-relay` flags: `--http <bind>` (default `0.0.0.0:8674`), `--http-url <url>`, `--no-http`.
- **S3/HTTP bucket is now an opt-in BYO option, not the default.** A user-configured S3 bucket is
  still supported and still tried before the iroh blob dial, but the relay's own HTTP interface is
  the zero-config default so most users never touch S3.

### Fixed
- **Stop re-uploading media a relay already has.** The periodic (~2 min) media backfill re-enqueued
  every blob a device holds and, on Apple, only deduped via a live `has()`/`head()` network round-trip
  — which fails over a flaky transport and triggered a full re-upload every cycle; Android had no
  dedup at all and re-`put` every blob unconditionally. Now a **persistent per-(relay, ref) ledger**
  (`MediaBackupLedger` on Apple, a prefs-backed set on Android) records confirmed uploads. Since media
  keys are content-addressed (`haven/media/<ref>`) a blob never changes, so a confirmed upload is
  permanent — `backup()`/`uploadMedia()` now skip a blob for a relay it's already on, *before* reading
  and re-sealing the file. Cleared for a relay only when it's erased (so a wiped+re-added relay
  re-mirrors). This is "why does my phone constantly send media the relay already has."
- **Nearby mesh now actually starts + is visible (Android).** Nearby is default-on but its runtime
  permissions were only requested when the user toggled the (already-on) switch, so they were never
  granted and the mesh never ran. Request them once on launch; the connection chip now shows `· Nearby`
  when peers connect, a live "Syncing N" indicator during transfers, and a tappable detail with the
  active transports + honest nearby state. (Nearby bridges Android↔Android only — iPhone/Mac use
  Apple's incompatible nearby system, so cross-platform sync rides the relay.)
- **Android launch crash (OOM) on a large synced video.** Once cross-NAT sync started delivering
  big videos, the feed's `MediaImage` thumbnail read the *entire* decrypted file into a `ByteArray`
  for **every** media ref — including videos — so a ~423 MB video blew the Nokia's ~512 MB heap the
  instant the feed rendered, crashing the app on launch. Fixed: `MediaImage` now decodes IMAGES
  downsampled and renders a VIDEO poster frame via `MediaMetadataRetriever` (never decoding a video
  as a bitmap), and `LocalMedia` skips any media too large to decrypt in RAM on this device
  (`maxInMemoryBytes` guard) rather than OOM-crashing — it still lives sealed on disk + on the relay
  and plays on a higher-memory device.
- **Cross-NAT media sync (videos) now lands.** The iroh **blob** ALPN (`haven/blob/1`) drops its
  outbound datagrams over a pure-relay cross-NAT path (noq/iroh 1.0 fork bug, proven by two-sided
  connection traces) — so posts synced but videos/large photos timed out forever. Media upload +
  fetch now try the relay's **HTTP interface first**, then a configured S3 bucket, and the iroh blob
  dial last (as an opportunistic fast-path / the only path when nothing else is configured), on all
  platforms. Apple also stops gating the bucket leg on "no relays configured", and Apple + desktop
  skip un-dialable `s3:` pseudo relay entries in the dial loops. A reachable HTTP relay that answers
  404 for a key is treated as a real MISS (the iroh path serves the same store), so we don't waste a
  ~30 s doomed dial on it. See `docs/BYO-STORAGE.md` → "Media transport order".

## [2026-06-30]

Multi-device and Messages wave (iOS/iPadOS, macOS, Android, and desktop, all sharing the Rust core).

### Fixed
- **Own-device sync now converges.** The epoch group-keying overhaul left each device minting a
  *random* epoch key per circle, so a user's own devices (iPhone/iPad/Mac) could never open each
  other's events — posts and DMs never synced across devices. Fixed with **own-device epoch-key
  convergence**: when a device receives a key commit it authored itself, both devices deterministically
  adopt the numerically-larger epoch key + circle secret, so buffered events drain and future re-seals
  use the agreed key (`core/haven-ffi/src/lib.rs` `receive_key_commit`). Consistent across iOS/macOS,
  Android (shared `.so`), and desktop (links the crate directly).
- **DM-delete no longer restores old messages.** Deleting a conversation records a local "cleared
  before" **watermark** so re-starting the DM doesn't surface previously-deleted messages that a peer
  (or your other device) still holds. True network deletion is impossible in P2P — the watermark is a
  local clear, documented as such.
- **Missing media settles.** A **media-request throttle** stops absent media from being re-requested
  forever; the per-contact history re-send (the actual flood) is throttled to an occasional cadence.

### Added
- **Per-device transport identity.** Each client instance takes its own per-device transport/relay id
  (so any number of a user's devices can run under one account without colliding on iroh discovery),
  while the account seed stays the identity — the trust anchor and roster signer — never a transport
  address.
- **Messages: recency sorting + conversation pinning.** Conversations sort by most-recent activity;
  pin up to 6 (iMessage-style), with drag-to-rearrange on iOS/macOS. Pins **self-sync across your
  devices** via the account-state CRDT.
- **Group DMs: per-message metadata.** Each incoming message shows the sender's display name, a
  timestamp, and a delivery checkmark.

### Changed
- **Scroll / perf pass.** Image and video-poster decoding moved off the main thread and hot-path
  logging removed from scroll, for smoother feed and message-list scrolling.
- **Android + desktop parity.** The DM delete-watermark, group-DM sender/timestamp/checkmark rows,
  and pinned + recency-sorted messages were ported to the native Android client and the Tauri desktop
  client, alongside the shared own-device sync fix.

### Docs
- Swept README, `docs/ARCHITECTURE.md`, `docs/MULTI-DEVICE.md`, `docs/GROUP-KEYING.md`,
  `docs/ROADMAP.md`, `docs/ANDROID-PARITY.md`, `docs/MEDIA-AND-MUSIC.md`, and `docs/DECISIONS.md` to
  match current reality: macOS ships from the **native `HavenMac`** target (Mac Catalyst dropped
  2026-06-23), group keying (epoch sender-keys) + self-sync are shipped, own-device sync converges,
  and Android now has media chunks, WebRTC calls, notifications, nearby, and the DM parity wave.
