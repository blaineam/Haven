# Android Auto messaging (Android)

Haven appears in Android Auto as a **messaging app**: new direct messages are read aloud on the car's
display, and the driver can reply by voice or mark the thread read. This is the Android counterpart of the
iOS CarPlay/Siri work in [`CARPLAY.md`](CARPLAY.md). There is no templated car UI: Android Auto has none for
messaging apps. It mirrors the phone's notifications.

## How Android Auto messaging works (and what Haven does)

Android Auto draws nothing for a messaging app. It surfaces a phone notification when ALL of these hold:

1. the app declares itself car-capable (`com.google.android.gms.car.application` meta-data ->
   `res/xml/automotive_app_desc.xml` with `<uses name="notification"/>`);
2. the notification is `NotificationCompat.MessagingStyle`;
3. it has a **REPLY** semantic action (with a `RemoteInput`, `setShowsUserInterface(false)`) and a
   **MARK_AS_READ** semantic action (`setShowsUserInterface(false)`).

A notification missing any of that is simply not shown on the car. Haven relies on this for privacy: see below.

```
 inbound DM -> HavenNet.notifyInbound
                  |  CarMessaging.plan(...)       pure rules, JVM-tested (core/CarMessaging.kt)
                  +- Plan.Messaging -> CarNotifications.post   MessagingStyle + Person/sender, shortcut id,
                  |                                             CATEGORY_MESSAGE, REPLY + MARK_AS_READ
                  +- Plan.Plain     -> Notifications.notify     ordinary banner (invisible to the car)

 car "reply" / "mark read" -> broadcast PendingIntent -> CarActionReceiver (not exported)
                  CarMessaging.execute -> re-checks lock + switch -> HavenNet.sendDm  /  DmRead.markRead
                  -> cancels the notification (clears the car's spinner)
```

| Piece | File |
|---|---|
| Declaration | `res/xml/automotive_app_desc.xml`, `AndroidManifest.xml` (meta-data + receiver) |
| Rules: privacy plan, reply/mark-read routing, executor | `core/CarMessaging.kt` |
| MessagingStyle builder, PendingIntents | `core/CarNotifications.kt` |
| Reply / mark-read receiver | `core/CarActionReceiver.kt` |
| Sharing shortcut per DM (Assistant resolution) | `core/ShareShortcuts.kt` (`ensure`) |
| Wiring into inbound notifications | `core/HavenNet.kt` (`notifyInbound`, `unreadInboundMessages`) |
| Setting | Settings -> Privacy -> Car -> "Android Auto messages" (`ProfileStore.androidAutoMessages`) |
| Tests | `CarMessagingTest`, `AndroidAutoDeclarationTest` |

Sending a reply uses the same `HavenNet.sendDm` as the in-app composer, so a reply from the car is an ordinary
sealed DM. The receiver boots the engine itself (idempotent, as `SyncWorker` does) because a broadcast can be
the first thing to run in a cold process.

## Privacy rules (parity with iOS, enforced in one place: `CarMessaging`)

* Only a **plain inbound DM** is built as a car conversation. Calls, reactions, comments, stories, edits and
  circle posts never are.
* Only at the **Full** notification-preview level. `Name and type only` (private) and `Minimal` post an ordinary
  banner, which Android Auto does not show, so the car shows no text and no sender. An unknown level fails closed.
* **Biometric-locked circles** (`CircleLock`) never reach the car, whatever the preview level. The lock check
  ignores "unlocked this session" (nobody can authenticate on a head unit). A locked circle's PHONE banner is
  also demoted to the iOS copy "Haven - New activity in a locked circle". Before this change the Android banner for a locked DM
  carried the sender and text; that was a leak, fixed here for all clients of that path.
* The **"Android Auto messages"** switch (default on, like iOS "CarPlay and Siri messages") off = no
  MessagingStyle, no reply/mark-read actions, nothing on the car. A notification already posted stays in the tray
  until it is dismissed.
* A reply or mark-read is **re-checked at execution time**: if the circle was locked, or the switch turned off,
  after the notification was posted, nothing is sent, and the notification is withdrawn.
* Smart-reply suggestions are disabled (`setAllowGeneratedReplies(false)`): nothing is composed on a driver's
  behalf.
* No message text is stored for the car. Unlike iOS (whose Siri extension needs an App Group snapshot), Android
  Auto reads the notification itself, so there is no extra data file to protect or wipe. The conversation's
  sharing shortcut (name + avatar only) is published only while "Suggest conversations" is on, and never for a
  locked circle.
* Known gap vs. the lock screen: a MessagingStyle notification at Full previews shows its text on the phone lock
  screen per the system's own lock-screen notification setting (Haven does not set a redacted public version;
  iOS Show Previews has no Android equivalent beyond that system setting). Users who do not want text on a locked
  phone should pick Name and type only / Minimal, which also removes it from the car.

## Starting a message by voice ("send a message to Blaine on Haven")

That is the Assistant App Action, separate from the reply path above: it opens Haven on the
conversation with the text staged and never sends by itself. See [ASSISTANT.md](ASSISTANT.md) for what
it does, what a sideloaded build can and cannot test, and the `adb` commands.

## Calls

Haven's calls are **system calls** on Android: a self-managed Telecom phone account and `HavenTelecomService`
register every Haven call with the platform, the counterpart of iOS's CallKit. Architecture, parity with
CallKit and what still needs a real head unit are in [ANDROID-CALLS.md](ANDROID-CALLS.md). In short: the car,
Bluetooth headsets and the system call controls know a Haven call exists, can answer / reject / hang it up,
and drive its audio route; Haven keeps drawing its own call screen and the incoming-call notification.

**The Calls screen on the head unit.** Haven is also a Car App Library app (category CALLING): Android Auto
lists it as a templated app with **Recents** and **Contacts** tabs where tapping a person dials them — the
counterpart of CarPlay's Calls tab. Messaging itself stays notification-based (read aloud + voice reply), so
the stock "No new messages during this drive" screen is Android Auto's messaging surface and not Haven's own.
See [ANDROID-CALLS.md](ANDROID-CALLS.md#the-android-auto-car-app-recents--contacts) for the design, the Desktop
Head Unit steps and the Play requirements.

**What Android Auto actually shows for a self-managed call is not verified.** Self-managed calls are the
app's own UI by design; whether a given Android Auto version / head unit adds its own in-call card for them
varies. Do not promise a native car call screen until it has been seen on a head unit (steps below). What is
certain: the call is registered with Telecom, so the OS treats it as a call (audio focus, no second call
over it, headset / car answer and hang-up buttons).

## What the owner must do in Play Console

0. **Calls screen (Car App Library)**: a templated Android for Cars app is reviewed separately from the
   notification path. Open Play Console -> Release -> Advanced settings -> Android form factors -> **Android
   for Cars**, confirm the **Calling** category, ship to a testing track first and run the Car App Quality
   checklist. Details and the unverified points are in [ANDROID-CALLS.md](ANDROID-CALLS.md#play).
1. **App content / Declarations**: nothing new is a *policy* requirement for a notification-based messaging
   app. There is no form to apply for, unlike CarPlay's entitlement. If the Play Console shows an "Android for
   Cars" section, open it and confirm the app type is **Messaging**; Play reads this from the
   `automotive_app_desc.xml` in the uploaded bundle.
2. Release the new build to a track (the declaration only takes effect from the build that contains it).
   Android Auto messaging apps are reviewed as part of the normal review; Google may test with a Desktop Head
   Unit, so use the review notes below.
3. **Review notes** (paste into the release / App access notes, naming no other platform):
   > Haven supports Android Auto messaging. Direct messages arrive as Android Auto message notifications that
   > can be heard and replied to by voice. Conversations the user locked with biometrics, and any message when
   > notification previews are set to anything but Full, never appear in the car. Calls and reactions never
   > appear. The "Android Auto messages" switch in Settings turns the feature off. To test, connect to Android
   > Auto or the Desktop Head Unit, have a contact send a direct message, and use the car's reply action.
4. **Data safety**: no change. The car path reads the app's own notifications and sends through the existing
   messaging path; nothing new is collected or shared.
5. Android Auto only presents apps installed from **Play (or via developer mode "Unknown sources")**. A
   sideloaded build works for testing only with Android Auto's Developer settings -> "Unknown sources" enabled.

## Verification

Automated (JVM, no device): `./gradlew --offline :app:testDebugUnitTest --tests '*CarMessagingTest' --tests '*AndroidAutoDeclarationTest'`
(plus the full unit suite, including `TestFlakeGuardTest`).

On a device/emulator (hermetic, offline runner):
`ANDROID_SERIAL=<serial> ./gradlew --offline :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.blaineam.haven.CarNotificationsInstrumentedTest`
posts the real notification and asserts, from `NotificationManager.getActiveNotifications()`, that it is
MessagingStyle with `CATEGORY_MESSAGE`, a REPLY (RemoteInput) and a MARK_AS_READ semantic action neither
showing UI, then fires the posted reply PendingIntent with a RemoteInput result and checks the text lands in the
thread via `HavenNet.sendDm`, and that mark-as-read withdraws the notification.

### Verification status (2026-10-26)

Verified: JVM rules (`CarMessagingTest`, `AndroidAutoDeclarationTest`, full unit suite), debug build and manifest
merge, and the instrumented test above on an API 35 emulator (arm64, google_apis).

NOT verified, because it cannot be on this setup: any real Android Auto or Desktop Head Unit session. The
emulator images here have no Play Store and carry only the stub `com.google.android.projection.gearhead`
(1.2.542030-stub), not the real Android Auto app the DHU needs. So what Android Auto *does* with the notification
(card rendering, Assistant read-out, voice reply UX, the notification-listener allow-list for third-party
messaging apps) is taken from the platform documentation, not observed. `lintDebug` could not run offline
(an uncached lint-checks dependency).

### Manual, on a real head unit or the Desktop Head Unit (NOT exercised by automation)

1. Phone: install the build, open Haven, make sure notifications are allowed and Settings -> Privacy ->
   "Notification previews" is **Full**, and "Android Auto messages" is on.
2. Phone: Android Auto -> Settings -> Notifications -> Messaging apps: Haven should be listed; leave "Show
   message notifications" on. Connect to the car (or `desktop-head-unit`, see below).
3. From a second device send a DM. Expect: a message card on the car; Assistant offers to read it; "Reply" opens
   a voice reply; the sent message arrives on the other device; the card disappears.
4. Mark as read from the card: the thread's unread badge clears on the phone.
5. Switch previews to Name and type only: a new DM produces no car card (the phone banner still appears).
6. Lock the conversation (circle lock), send a DM: no car card, the phone banner reads "New activity in a locked circle".
7. Turn the switch off: no car card for new DMs.
8. Group DM: the card carries the group title and the sender's name per message.
9. Calls: place a Haven call from the phone while connected to the head unit (or the DHU): the call
   should appear on the car (answer / hang-up controls, call audio on the car speakers). Receive one from
   another device: it rings the phone and the car; answering from the car connects it. Report what the
   car screen shows (a native in-call card, only the notification, or nothing) - this is the unverified
   part. See [ANDROID-CALLS.md](ANDROID-CALLS.md).

Desktop Head Unit: `sdkmanager "extras;google;auto"`, then on the phone enable Android Auto developer mode
(tap the version 10 times) -> "Start head unit server"; `adb forward tcp:5277 tcp:5277`; run
`$ANDROID_HOME/extras/google/auto/desktop-head-unit`.
