# CarPlay and Siri messaging (iOS)

Haven appears on CarPlay in Apple's **Communication** category: a list of your direct-message
conversations on the car's display, and hands-free read / reply / send / call through Siri. Nothing is
typed or scrolled in the car; the list is a launch surface for Siri.

Entitlement: `com.apple.developer.carplay-communication` (granted 2026-10). iOS only; it is deliberately
absent from every macOS entitlement file.

## Architecture

```
 car display ─────────► CarPlaySceneDelegate ──► CarPlayTemplates ──► CPListTemplate of CPMessageListItem
   (CPTemplateApplicationScene,                     ▲
    same process as the phone UI)                   │ rows
                                          CarPlayConversations   (pure: order, truncate, unread, privacy)
                                                    ▲
                                          MessagingThreads (FeedStore, DMReadStore, CircleSettingsStore)

 "Hey Siri / tap a row" ► HavenIntents.appex (own process, NO engine, NO seed)
        read ............ INSearchForMessagesIntent ── reads ─┐
        send ............ INSendMessageIntent ───────── reads ─┤  App Group "Messaging/snapshot.json"
        mark read ....... INSetMessageAttributeIntent ─ queues ┤  (CarPlayBridge.publish, privacy-filtered)
        call ............ INStartCallIntent ──.continueInApp   │
                                          SiriRequestQueue  ◄──┘  App Group "SiriRequests/*.json"
                                                    │ Darwin doorbell (SiriRequestSignal.request)
                                                    ▼
                                          CarPlayBridge.drain (app) ──► FeedStore.sendMessage / DMReadStore.markRead
                                                    │ Darwin ack (SiriRequestSignal.ack)
                                                    ▼
                                          extension answers Siri "sent" ONLY after the ack

 incoming DM push ► HavenNotificationService ► donate INSendMessageIntent + content.updating(from:)
                    (communication notification: Siri announce + voice reply)
```

Key files (all under `apple/`):

| Piece | File |
|---|---|
| Scene delegate (root `CPListTemplate`, debounced refresh) | `HavenApp/CarPlaySceneDelegate.swift` |
| `CPMessageListItem` / states construction | `HavenApp/CarPlayTemplates.swift` |
| Row model: ordering, truncation, unread, time label | `HavenApp/CarPlayConversations.swift` |
| Live stores -> `MessagingThread` | `HavenApp/MessagingThreads.swift` |
| Privacy rules, snapshot, App Group store, Siri request queue | `Shared/MessagingSnapshot.swift` |
| Darwin doorbell/ack | `Shared/SiriRequestSignal.swift` |
| App-side publish + drain | `HavenApp/CarPlayBridge.swift` |
| Siri call routing | `HavenApp/SiriCallTarget.swift`, `HavenApp/SiriCallRouter.swift` |
| Intents extension | `HavenIntents/IntentHandler.swift`, `HavenIntents/Intents.entitlements` |
| Communication notifications | `HavenNotificationService/NotificationService.swift`, `NotificationPayload.swift` (`communicationPlan`) |
| Setting | Settings -> Car and Siri -> "CarPlay and Siri messages" (`SettingsStore.carPlayAndSiri`) |

### Scene manifest

`project.yml` (`Haven:` -> `info.properties.UIApplicationSceneManifest`) declares
`UIApplicationSupportsMultipleScenes = true` and ONLY a `CPTemplateApplicationSceneSessionRoleApplication`
configuration (`CarPlaySceneDelegate`). There is **no** `UIWindowSceneSessionRoleApplication` entry: SwiftUI's
`WindowGroup` keeps supplying the phone window, exactly as before. SwiftUI needed no explicit
`UIWindowScene` configuration; `FeedUITests` and `AudienceUITests` (13 tests) pass unchanged with the manifest.
Do not add a window-role entry - it would replace SwiftUI's scene delegate.

### How a row behaves

Messages-tab rows are plain `CPListItem`s: a tap opens the **conversation screen** (below). They were
Siri-managed `CPMessageListItem`s before; those never call the app, so every tap on a read conversation ended
at Siri's "what would you like to send?". The conversation screen keeps exactly ONE Siri-managed row - **Reply**
- whose `conversationIdentifier` is the DM circle id: Siri reads any unread messages
(`INSearchForMessagesIntent`) and takes the reply (`INSendMessageIntent`); the extension resolves the id against
the snapshot, a group DM by its title, locked conversations are refused.

### The conversation screen (tap a row)

`CarPlayConversations.detail` (pure, unit-tested) -> `CarPlayTemplates.conversationScreen`. A `CPListTemplate`:

* **Messages (parked)** - the newest 8 (200 characters each) in **chat order, oldest first**, so the newest sits
  right above the reply row. Each row has a small round picture: **their** messages show the contact's avatar
  (or a left, grey bubble), **yours** show YOUR profile picture (photo, else your emoji, else your initials -
  the tinted right-hand bubble glyph only when you have no profile data at all); the subtitle is "You . 3:41 PM"
  (group: the author). A tap reads that message aloud. A new message refreshes an open screen in place.
* **Reply** - the one Siri-managed `CPMessageListItem`, below the messages like a composer; the Siri flow
  described above (reads unread, takes the reply).
* **Read to me** / **Read new** and **Call** - real buttons in the navigation bar, drawn as SF Symbol icons:
  a speaker with sound waves (`speaker.wave.2.fill`; with unread messages the badged
  `speaker.badge.exclamationmark.fill`) for reading aloud and the handset (`phone.fill`) for calling. A
  `CPBarButton` built from an image has no title, so the names above are what the actions are called in the code
  and tests; CarPlay offers no accessibility-label property for it.
* **Colours** follow Settings > Appearance: the reply mic, unread dots, the own-message bubble and the avatar
  fallback circles all use the selected palette (tint stop; Neutral = grey). The car's scene reads the SAVED
  choice at connect (`PaletteStore.current` is seeded from the stored value - it used to start at the Sunset
  default until the phone UI had created the store, so a CarPlay-only launch drew pink whatever was selected) and
  redraws when the palette or your profile changes.
  Read aloud uses Haven's own `AVSpeechSynthesizer` (`CarPlaySpeaker`: spoken-audio session that ducks other
  audio and hands it back, never over an active call): "N new messages from Tracy M." then each unread one
  oldest first (attachment-only messages are spoken as "Sent a photo"), or the latest few when nothing is
  unread. Heard messages are marked read. Call opens the same contact card as the Calls tab (it never dials on
  one tap).

#### Parked vs. driving - message text is only shown when parked

CarPlay has **no public parked/driving API**. The one signal an app gets is
`CPSessionConfiguration.limitedUserInterfaces`: a vehicle that restricts long lists and/or the keyboard while it
moves reports `.lists` / `.keyboard` through `CPSessionConfigurationDelegate`, and clears them when parked.
Haven treats **any reported limit as DRIVING** and **no limit as PARKED** (`CarPlayDriveMode`, a pure,
unit-tested decision). While driving:

* the conversation screen shows **no message text** - a "Messages are hidden while driving" line ("Park to read
  them, or tap Read to me.") plus the Reply row and the Read/Call buttons (reading ALOUD stays available);
* the Messages-tab rows show **names and unread counts only** ("3 unread"), never a preview;
* when the car starts or stops moving the Messages list and any open conversation are **rebuilt immediately**.

Honest limit: a car (or the CarPlay simulator) that **never reports limits looks parked**, so it will show
message text even while moving. There is nothing more to go on; the app cannot read speed or the handbrake.

#### What CarPlay does and does not allow here

CarPlay draws every screen itself. A third-party Communication app gets a fixed set of templates (list, tab bar,
contact, alert / action sheet); there are **no custom views, so no free-form chat bubbles, no sticky footer and
no in-list buttons**. What Haven built is the closest the platform permits: chat ordering, per-message bubble
glyphs, a composer-style Reply row at the bottom, and real buttons in the navigation bar (a list template shows
at most two). `CPInformationTemplate` has three real bottom buttons, but it is not documented as available to
Communication apps and CarPlay raises on an unsupported template, so it is deliberately **not used** (it could not
be verified without a car). The iOS 26.4 `CPListTemplateDetailsHeader` (header with action buttons) is likewise
documented around media content and was not adopted for the same reason.

#### Read-aloud voice

The voice was previously `AVSpeechSynthesisVoice(language:)`, which returns the **default-quality** voice for the
language - not the one chosen in Settings. iOS exposes **no API to read the voice picked in Settings >
Accessibility > Spoken Content**. So `CarPlayVoice`:

1. **Match system** (default): when VoiceOver / Speak Screen / Speak Selection is on, the utterance sets
   `prefersAssistiveTechnologySettings` and the system applies the user's assistive speech settings; otherwise Haven
   picks the **best installed voice** (premium > enhanced > standard) for the message's own language (detected on
   device, only when confident) and falls back to the system language. Novelty voices (Bubbles, Zarvox...) and
   Personal Voices are never picked automatically.
2. **A specific voice** can be chosen in Haven Settings > Car and Siri > Read-aloud voice (it plays a sample on
   tap). A chosen voice always wins; Personal Voice appears there only once the user has authorized Haven for it in
   iOS Settings (Haven does not prompt for it).

Not verified on a device: what `prefersAssistiveTechnologySettings` resolves to for a given Spoken Content
configuration (Apple does not document it beyond "assistive technology settings"), and how a given premium voice
sounds over the car's audio route.

Privacy is identical to the list: a locked conversation shows only "Locked" (no buttons, no reply row content);
with the notification-privacy setting below Full there is no read-aloud and the lines show the capped phrases
("Sent you a message"), with a line saying why.

## Privacy rules (enforced in one place: `MessagingPrivacy`)

* **Biometric-locked conversations** (`CircleSettingsStore.biometricRequired`) show only "Locked": no text, no
  time, no unread dot; no messages are written to the snapshot; Siri refuses to read, send, mark read, or call
  them. The check ignores "unlocked this session" because nobody can authenticate on a head unit and a dashboard
  is visible to passengers. The extension re-checks live against the shared-keychain locked set
  (`SharedLockedCircles`), so a lock applied after the last snapshot still wins.
* **Notification privacy** (`SharedNotificationPrivacy`): `Full` shows the message; `Name and type only` shows
  "Sent you a message" and Siri reads nothing; `Minimal` shows "New activity" (unread only). The extension
  applies the stricter of the snapshot's level and the live setting. The NSE additionally honours iOS Show
  Previews before it will put text in an intent.
* The snapshot is the only message text outside the app's own store: at most 12 conversations x 6 messages, file
  protection `completeUntilFirstUserAuthentication` (Siri must work with the phone locked in a pocket), wiped on
  factory reset and when the "CarPlay and Siri messages" setting is turned off.
* The identity seed and the Rust engine never enter the extension.
* Communication notifications are produced only for a plain inbound DM at effective privacy level `Full`, never
  for a locked circle, call, reaction, or story.

## What the owner must do in the Apple Developer portal

1. **Account holder:** the CarPlay Communication entitlement is already granted to the team. In Certificates,
   Identifiers & Profiles -> Identifiers -> `com.blaineam.kith` (Haven), enable **CarPlay Communication**
   (it appears under Capabilities once granted).
2. On the same App ID enable **Siri** and **Communication Notifications**.
3. Register the new App ID **`com.blaineam.kith.Intents`** (HavenIntents) and enable **App Groups** with
   `group.com.blaineam.kith`. (Automatic signing creates it on first device build; a distribution
   build via Xcode Cloud needs it to exist.) The shared keychain group
   (`<TEAM>.com.blaineam.kith.shared`) needs no portal step.
4. **Regenerate provisioning profiles** (development and App Store) for Haven (`com.blaineam.kith`),
   HavenIntents (`com.blaineam.kith.Intents`), and re-validate the NotificationService, ShareExtension and
   Broadcast profiles (unchanged capabilities, but their parent app's profile changed). The app will not
   sign until Haven's profile contains `com.apple.developer.carplay-communication`,
   `com.apple.developer.siri` and `com.apple.developer.usernotifications.communication`.
5. In App Store Connect nothing else is required for Communication; CarPlay apps are reviewed as part of the
   normal submission. No separate "CarPlay" build.

Verify a signed build carries the entitlements:

```
codesign -d --entitlements - Haven.app | grep -E 'carplay-communication|siri|usernotifications.communication'
codesign -d --entitlements - Haven.app/PlugIns/HavenIntents.appex | grep -E 'application-groups|keychain'
```

## App Store review notes (paste into the submission)

> Haven supports CarPlay in the Communication category. The CarPlay screen lists the user's direct-message
> conversations; selecting one starts a Siri-managed read or reply flow. Messages are handled by the app's
> SiriKit Intents extension (send, search, mark as read, start call) and by communication notifications.
> Conversations the user has locked with Face ID or Touch ID show only "Locked" and cannot be read,
> replied to or called from the car. To test: connect to a CarPlay head unit or the Simulator CarPlay
> display, open Haven, and say "Hey Siri, read my Haven messages". The "CarPlay and Siri messages" switch in
> Settings turns the feature off and deletes the data Siri uses.

(The notes name no other platforms, per the App Store copy rule.)

## Verification

Automated (no CarPlay hardware needed):

```
# pure logic + notification policy (macOS, host-less)
xcodebuild test -scheme HavenLogicTests -destination 'platform=macOS'
# Siri handler + CarPlay template construction (iOS simulator, host-less)
xcodebuild test -scheme HavenIntentsTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# the phone window scene still launches (needs a SIGNED simulator build, as all HavenUITests do)
xcodebuild test -scheme Haven -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HavenUITests/FeedUITests -only-testing:HavenUITests/AudienceUITests
```

Manual, in the Simulator CarPlay window (this part has NOT been exercised by automation):

1. Run Haven on an iPhone simulator with `-UITestMode` (demo cast: Maya / Theo DMs).
2. Simulator -> **I/O -> External Displays -> CarPlay**. A CarPlay window opens; the Haven icon is on its
   home screen. Open it.
3. Expect a "Haven" list: Maya and Theo rows (names, latest message, time); an unread row has the dot.
4. Lock Maya's thread in the phone UI (circle settings -> Face ID): within ~1 s the row reads "Locked".
5. Settings -> Notifications detail -> "Name and type only": rows read "Sent you a message".
6. Tap a row: Siri takes over (needs Siri enabled in the Simulator); read/reply flows go through
   `HavenIntents`. Check the log: `log stream --predicate 'subsystem == "com.blaineam.haven.diag"' | grep -i carplay`.
7. Settings -> Car and Siri -> off: the list shows "Turned off" and the App Group `Messaging/` folder is gone.
8. "Hey Siri, call Maya on Haven" starts the call through CallKit.

Real-car checks that the Simulator cannot do: Siri announcing a communication notification over the car
speakers, CallKit in-call UI on the head unit, locked-phone behaviour (file protection), wireless CarPlay
reconnects.

## Field-test follow-ups (carplay2)

### Avatars

CarPlay draws a `CPMessageListItem` leading image exactly as supplied (it only scales down when larger than
`CPMaximumMessageItemImageSize`); it applies no circle mask and no aspect fill, so a raw contact photo showed as
an uncropped rectangle. `CarPlayAvatarRenderer` now bakes a square canvas (side = the smaller dimension of
`CPMaximumMessageItemImageSize`, drawn at the car display's `displayScale`), a circle mask, and an aspect-FILL
photo. Without a photo: the contact's profile emoji on a gradient from the active palette, else up to two
initials, else a neutral disc. Locked conversations and the Minimal privacy level always get the neutral disc
(the banner for Minimal says only "Haven"). Decisions are pure (`CarPlayAvatar`, unit-tested); drawing is
cached and runs off the main thread; the list shows its text first and swaps the images in. Group DMs use the
first member with a photo, else the title's initials. (Circle posts are not part of the car UI.)

### Name matching (Siri)

`Shared/ContactMatching` scores a spoken name against each conversation's title and aliases (your nickname vs
the name they signed): case, diacritics, fullwidth/halfwidth and hiragana/katakana are folded; emoji and
punctuation ignored; tokens match as equal, prefix, one-letter initial ("Miller" = "M"), or near-miss spelling
("Tracey"); CJK names match by containment. "Tracy" and "Tracy Miller" both find "Tracy M".

Matches are TIERED and only the best tier present is considered, so a sloppier match can never join a list with
or outvote a better one: exact name > every spoken word is a word of the name ("Tracy" -> "Tracy M") > prefix /
initial ("Tracy Miller" -> "Tracy M") > near-miss spelling. "Tracy" with contacts Tracy M, Troy, Trey resolves
straight to Tracy M; the spelling guess "Tracey" is only offered when nothing better exists. Only genuine ties
(two Tracys) disambiguate, and only between the tied people. One resolver serves messages and calls.
Outcome per request (send recipients, read-from sender, call contact):

| Situation | Siri result |
|---|---|
| exact name, or the only strong candidate | success |
| several equally good ("Tracy" with Tracy M / Tracy Zhang) | disambiguation (Siri asks which) |
| one weak candidate ("Tracey") | confirmationRequired ("Tracy M?") |
| nothing plausible | unsupported |

A locked winner is never swapped for a look-alike for calls (locked "Maya" does not become "Maya Chen").

### Calls from the car

* **Siri:** "call Tracy on Haven" -> `INStartCallIntent` -> `HavenIntents` resolves (fuzzy, locked refused) and
  answers `.continueInApp` with the conversation id and `havenAudioOnly = true` -> `SiriCallRouter` ->
  `CallManager.startCall`. The extension ALSO queues a `.call` request in the App Group and rings the app: when
  Siri launches Haven in the background (phone locked in a pocket) there is no phone window for the continuation
  activity, so the queue (drained wherever the app runs - `CarPlayBridge.drain`) is what places the call. The two
  paths de-duplicate (same conversation within 20 s) and a request older than 90 s is dropped.
* **Why "call Tracy M" failed while messaging it worked:** Siri resolves the spoken name BEFORE the extension,
  against the user's Contacts plus whatever the app taught it. Messages worked because share-suggestion
  donations had taught Siri the thread titles; calls had nothing, so Siri fell back to phonetic Contacts
  neighbours ("Tracy / Troy / ..."). `SiriContactVocabulary` now registers the titles, aliases and first names as
  user-specific `contactName` vocabulary (`INVocabulary`, `MessagingVocabulary`) and donates `INStartCallIntent`
  interactions for the 8 most recent unlocked conversations (and on every call placed). Locked conversations
  contribute nothing; switching CarPlay and Siri messages off or resetting the account erases both.
* **Screen:** the CarPlay root is a tab bar (Messages | Calls) when the entitlement allows 2+ tabs
  (`CPTabBarTemplate.maximumTabCount`). A Calls row opens a `CPContactTemplate` (system `CPContactCallButton`);
  that button starts the same call. A tap on a row never dials by itself.
* **Audio only:** `CallManager.startCall` begins with the camera off (`videoOn == false`) and requests the
  CallKit call with `CXStartCallAction.isVideo = false`, so every Haven call from the car starts audio-only,
  including when Siri asked for video (the activity carries `havenAudioOnly`). Video can be switched on from the
  phone later.
* **Incoming calls:** `CallManager` reports them through CallKit (`CXProvider`), which CarPlay presents
  natively with its own answer/decline UI. Haven draws nothing extra.
* **Verification level:** the intent resolution, the audio-only flag, the call-list/contact template
  construction and the locked/unknown refusals are unit-tested (`IntentHandlerTests`, `CarPlayTemplatesTests`,
  `SiriCallTargetTests`). The path from `SiriCallRouter` into `CallManager`/CallKit, the head-unit answer UI,
  and real-car behaviour are NOT covered by any automated test and are unverified here. (The simulator uses
  Haven's in-app call UI instead of CallKit by design.)

### Announcing incoming messages while driving (how to enable)

Haven posts incoming DMs as **communication notifications**: the notification service extension donates an
`INSendMessageIntent` (sender `INPerson` with photo, `content`, `conversationIdentifier` = the DM id, and a
`speakableGroupName` for group DMs) and calls `content.updating(from:)`. That is what lets Siri announce the
message and take a spoken reply (the reply comes back to `HavenIntents` as an `INSendMessageIntent`; the sender
person we donate carries the conversation id so it resolves exactly). Requirements, all in place:

* Communication Notifications entitlement on the app (portal capability + profile; see above);
* the NSE runs on the push (`mutable-content`), which is the existing path;
* effective privacy level **Full** (Haven's lock-screen detail setting, tightened by iOS Show Previews);
  otherwise the notification stays an ordinary banner and nothing is donated, so Siri cannot read it;
* never for a biometric-locked circle, calls, reactions, stories, or circle posts/comments.

Group DMs announce ("Tracy in Book Club says ..."); circle posts and comments do NOT - they are not messages
and Siri has no conversation to reply into. Haven does not mark messages time-sensitive (that needs a separate
entitlement and bypasses Focus); communication notifications are announced on their own merits.

Owner test steps (iPhone, iOS 26+ wording may vary slightly):

1. Settings -> Notifications -> **Announce Notifications**: turn **Announce Notifications** on.
2. Same screen -> choose where: **Headphones**, **CarPlay** (turn on), and optionally "Speaker". Under
   "Announce Notifications From" Haven appears after its first communication notification is delivered and
   must be on (Messaging apps are listed there by name).
3. Settings -> Notifications -> **Haven**: Allow Notifications on, Banners/Sounds on, and *Announce* shown
   (it only appears once the first communication notification has arrived).
4. Settings -> Siri: Siri on; "Allow Siri When Locked" on if the phone is locked in the car.
5. Haven Settings -> Notifications: lock-screen detail = **Full previews** (anything else is deliberately silent).
6. From another device send a DM. In the car / with headphones Siri says the sender and message, then
   offers "reply?"; speak the reply, Siri confirms, and it appears in the thread.

What the Simulator and this repo's tests can show: that a plain DM at Full yields a plan with sender, text and
group name, and that locked/non-DM/Private/Minimal yield none (`NotificationPayloadTests`). Whether iOS actually
speaks it depends on system settings and the car, and has not been observed here.

### Photos in incoming messages

* A photo-only DM is spoken/shown as **"Sent a photo"** (also video, voice note, file, song) in the device's
  language: the NSE rewrites the sender's stock banner line into the recipient's language and the CarPlay list
  and Siri reading use the same phrases (`Shared/Messaging.xcstrings`; six languages). Real caption text is read
  as written.
* **Describing the image is not done.** Findings: (a) Apple documents no image description for third-party
  communication notifications. Attachments on an `INSendMessageIntent` only support audio message files;
  a `UNNotificationAttachment` image is shown, not described, and I found no documented Announce behaviour that
  reads it - unverified on a device. (b) An on-device description in the NSE is not feasible: Haven's media
  reaches the NSE as ciphertext sealed to the circle (`SharedPushPrefetch` stores the sealed bytes; opening
  them needs the engine and circle key, which the NSE deliberately never holds), the NSE memory ceiling is small
  for a classification model, there is no sensitive-content (SCA) gate in the NSE path, and the photo is often
  not on the device yet. So the honest fallback above is where it stops. A future option, not built: have the
  app (which does hold the decrypted photo, with more memory) describe it after ingest and put that text in the
  Siri snapshot, behind the sensitive-content check - only when the app runs while the phone is in the car.

### Parked conversation browsing

What Apple's CarPlay SDK offers a Communication app (from the SDK headers; the web docs could not be fetched in
this environment):

* `CPMessageListItem` selection is Siri-managed: the app gets no callback. Unread rows -> Siri reads; read rows
  -> Siri composes a reply. (Haven now uses it for the single Reply row only; see "The conversation screen".)
* There is **no "parked" signal** for non-navigation apps. `CPSessionConfiguration` exposes only
  `limitedUserInterfaces` (keyboard/lists limited by the car) and `contentStyle`; nothing reports vehicle motion.
* Haven can show lists, a tab bar and a contact card (what it uses). Scrolling message history in an app-drawn
  screen is not something the Communication category provides, and the SDK offers no way to detect that the car
  is parked to unlock one.

What Haven does instead, using only sanctioned surfaces: Siri **"read my messages from Tracy"** (reads unread),
and **"read earlier messages from Tracy"** / "...containing lunch": `INSearchForMessagesIntent` honours the
date bounds and search terms Siri sends and returns the newest page that matches before the bound, 10 at a
time. To make that possible without exposing more than needed, the three most recently active conversations keep
20 messages in the Siri snapshot (the rest 6). Locked conversations and privacy levels below Full return nothing.
Browsing a long history by eye is a phone feature.

Update (field test): Messages-tab rows now open an app-drawn conversation screen (recent messages as list
items plus read-aloud, reply and call; reshaped into a chat-order list with nav-bar buttons, parked-only text and
a voice setting in the round-3 pass below). Apple's Communication guidance leans on Siri for message content, so this
is the item most worth a second look at App Review; it uses only `CPListTemplate`/`CPListItem`, and the content
obeys the same privacy tiers as the rows.

## Verification status of the follow-ups

Proven by automated tests (this branch): name scoring and resolution (including the "Tracy M" report), intent
resolution kinds and refusals, audio-only call activity, avatar geometry and real rendered pixels (circle mask,
aspect fill), tab/list/contact template construction, localized phrase tables, search paging, communication
plans. Not verified by any test or run: real CarPlay rendering of the new avatars and tabs, Siri speech, Announce
Notifications, CallKit on the head unit.

Field-test round 2 (conversation screen, call resolution, matcher tiers): proven by automated tests -
tiered resolution ("Tracy" never offers Troy; "Tracy M"/"Tracy Miller"/"Tracy" all resolve a call), conversation
detail + spoken script (privacy tiers, caps, ordering), template construction including the mixed
`CPListItem` + `CPMessageListItem` conversation screen, the queued call request, vocabulary rules, localized
strings. NOT verified without a car/CarPlay simulator: how the screen renders, `AVSpeechSynthesizer` over the
car audio route, that Siri now maps "Tracy M" to Haven after the vocabulary/donations settle (Siri can take a
few minutes after the first launch to learn them), and the background-launch call path.

Field-test round 3 (chat layout, drive mode, voice): proven by automated tests - parked vs. driving decision
(`CarPlayDriveMode`, any reported limit = driving), conversation screen in each mode (no message text while
driving, Reply and buttons kept, locked/hidden-text variants), Messages-row subtitles (names + unread counts only
while driving), chat ordering and bubble art, nav-bar button wiring, voice ordering (premium > enhanced > standard,
no novelty/Personal by default, explicit choice wins, message language first), plus an iOS build with the Settings
picker. NOT verified without a car: how the nav-bar buttons and bubble glyphs look on a real head unit, whether a
given car reports `limitedUserInterfaces` at all, and the speech voice over the car audio route.

Round 4 (icons, own picture, palette): proven by automated tests - nav-bar buttons are icon buttons with the right
symbols (plain vs. unread-badged speaker, handset), my rows prefer my own picture over the bubble, the glyph tint
is the palette's tint stop (Neutral = grey, malformed stops = grey), and a saved palette is read without the store
existing. NOT verified without a car: how the icons and the own-photo rows look on a real head unit.

## Known limits

* CarPlay shows at most `CPListTemplate.maximumItemCount` rows (head-unit dependent); Haven uses min(12, that).
* Siri send needs the app process alive to seal and send. With CarPlay connected the scene keeps it running; with
  no ack within 4 s (app not running) the extension answers "needs the app" and the request stays queued,
  sending when Haven next launches. A message is never reported sent before the app took it.
* Only direct messages, not circle posts, are exposed to the car.
* Incoming Haven calls already use CallKit (`CallManager`), which CarPlay presents natively; this work adds no
  call UI of its own. Video calls are audio-only on the head unit (iOS behaviour).
