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

### How a row behaves (Apple's Siri-managed model)

`CPMessageListItem` selection does not call the app. The row's `conversationIdentifier` is the DM circle id.
An **unread** row makes Siri read the conversation (`INSearchForMessagesIntent`); a **read** row starts a
reply (`INSendMessageIntent`). The extension resolves the id against the snapshot. A group DM resolves by its
title. Locked conversations are refused.

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

## Known limits

* CarPlay shows at most `CPListTemplate.maximumItemCount` rows (head-unit dependent); Haven uses min(12, that).
* Siri send needs the app process alive to seal and send. With CarPlay connected the scene keeps it running; with
  no ack within 4 s (app not running) the extension answers "needs the app" and the request stays queued,
  sending when Haven next launches. A message is never reported sent before the app took it.
* Only direct messages, not circle posts, are exposed to the car.
* Incoming Haven calls already use CallKit (`CallManager`), which CarPlay presents natively; this work adds no
  call UI of its own. Video calls are audio-only on the head unit (iOS behaviour).
