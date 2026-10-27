# Haven calls as Android system calls (Telecom)

Haven's audio calls are registered with Android's **Telecom framework** as a *self-managed* phone account, the
counterpart of iOS's CallKit. The platform (and through it the car, Bluetooth headsets and the system call
controls) knows a Haven call exists, what state it is in and where its audio goes. Haven still draws its own
call screen and owns the media: the engine (`CallManager`) stays the single source of truth and Telecom is an
adapter around it, never a second state machine.

## Pieces

| File | Role |
|---|---|
| `core/TelecomPolicy.kt` | The pure rules, JVM-tested: end-cause mapping, route choice, `RouteArbiter`, `Session` (the connection state machine) and `Placer` (placement with a guaranteed fallback). No Android types. |
| `core/TelecomCalls.kt` | The coordinator. Registers the `PhoneAccount`, places calls (`TelecomManager.placeCall`), reports incoming ones (`addNewIncomingCall`), creates the connections, mirrors the audio route both ways. |
| `core/HavenTelecomService.kt` | The `android.telecom.ConnectionService` Telecom binds (`BIND_TELECOM_CONNECTION_SERVICE`), and `HavenConnection` (self-managed, VoIP, no hold). Do not confuse with `core/ConnectionService.kt`, Haven's "stay connected" foreground service. |
| `core/CallManager.kt` | The engine. `startCall` tries Telecom first (`startCallDirect` is the engine's own dial path); a handful of hooks report connect / end / incoming / route to `TelecomCalls`. |
| `AndroidManifest.xml` | `MANAGE_OWN_CALLS` and the service declaration. No `READ_PHONE_STATE` / `READ_PHONE_NUMBERS`: a self-managed account needs neither. |

## Flow

* **Outgoing** (phone UI, voice command, QA driver): `CallManager.startCall` -> `TelecomCalls.place` ->
  `TelecomManager.placeCall(haven:<contact hex>)` -> the system binds `HavenTelecomService` ->
  `onCreateOutgoingConnection` builds the `HavenConnection` (state **dialing**) and starts the engine
  (`startCallDirect`). When the far end accepts the engine reports active -> connection **active**.
* **Incoming**: the engine rings as before (full-screen incoming-call notification stays the UI), then
  reports it with `addNewIncomingCall` -> `onCreateIncomingConnection` -> connection **ringing**.
  `onShowIncomingCallUi` re-posts the same notification. Answer / reject from the car or a headset calls
  `CallManager.accept()` / `decline()`; answering in the app marks the connection active.
* **Ending**: every way a call ends (local hang-up, remote hang-up, decline, ring timeout) passes through
  `CallManager.teardown`, which reports an end cause (`LOCAL`, `REMOTE`, `REJECTED`, `MISSED`) to Telecom and
  destroys the connection. The echo of our own disconnect is guarded so it never loops into a second hang-up.
* **Busy**: a second incoming call while one is live is ignored by the engine (as on iOS: "startCall
  IGNORED") and a second `Connection` is refused with `BUSY`.
* **Telecom is an addition, never a dependency.** If the account can't be registered, `placeCall` throws,
  the system never hands the service a connection within 3 s, or it reports the call failed, the call dials
  the old direct way exactly once (`Placer`). A connection that arrives after the fallback fired is refused, so
  one tap can never become two calls. A refused incoming report leaves the notification as the UI.

## Audio route

The engine's existing routing (`setCommunicationDevice` / speakerphone, with `CallRoutePolicy`: a connected car,
Bluetooth or wired headset beats the speaker, an explicit speaker tap wins) is still what moves the audio. Telecom
is kept in step with it:

* when Haven picks a route (the media-start default, a device connecting or leaving, the speaker button) it
  asks Telecom for the matching route (`setAudioRoute`);
* when the system reports a route Haven did not ask for (the driver picks Bluetooth on the car, the system call
  controls), `RouteArbiter` adopts it as an explicit choice. It only adopts a report after the system has
  acknowledged a route Haven asked for, so Telecom's initial earpiece default can never flip a hands-free call.

`CallAudioState` is used for observation on every API level. Android 14's `CallEndpoint` callbacks are not used
(the deprecated callbacks are still delivered); that is a deliberate scope limit.

## Parity with iOS CallKit

| | iOS (CallKit) | Android (Telecom, self-managed) |
|---|---|---|
| System knows about the call | yes | yes |
| Answer / decline / end from car, headset, system controls | yes | yes |
| Native incoming-call UI | system call screen | **Haven's own** full-screen notification (self-managed apps draw their own) |
| Hold | not offered | not offered (no hold capability is advertised: the engine has no hold) |
| Audio route follows the car / headset | yes | yes (`CallRoutePolicy` + `RouteArbiter`) |
| Voice start ("call X on Haven") | Siri INStartCall | Google Assistant `CREATE_CALL` ([ASSISTANT.md](ASSISTANT.md)) |
| Missed call | CallKit cause | Telecom `MISSED` + Haven's own notification |
| Call shown on the car screen | CarPlay shows it through CallKit | **Unverified** (see below) |
| Contacts / Recents screen on the car | CarPlay Calls tab (tap a row: dials) | **Car App Library Calls screen** (tap a row: dials) — see "The Android Auto car app" |

## The Android Auto car app (Recents / Contacts)

Haven is also a **Car App Library** app in the **CALLING** category, so Android Auto lists Haven as a
templated app with a real screen — the counterpart of the CarPlay Calls tab. Before this, Haven in Android
Auto was notification-only (Android Auto shows its stock "No new messages during this drive" screen for a
messaging app that draws nothing).

| | CarPlay | Android Auto car app |
|---|---|---|
| Screen | tab bar: Messages / Calls | tabs: **Recents** / **Contacts** (a single two-section list on a host older than Car App API 6) |
| Tap a person | dials immediately, no contact card | dials immediately, no contact card |
| Who is listed | 1:1 contacts, never locked / blocked | the same rule as "call X on Haven" (`AssistantLaunch.callCandidates`): 1:1 contacts, never you, a blocked contact or a biometric-locked conversation |
| Recents | most recent conversations | most recent conversations (`HavenNet.lastActivity`) — no separate call log exists, so "recent" is conversation activity, as on iOS |
| Row content | name + avatar | name + round avatar (photo, else initials in the palette tint) — **never message text** |
| Long lists | list item limits | the host's item limit (`ConstraintManager`); when it cuts the A→Z list the first row is **Search all contacts** (typed or spoken, tiered matcher shared with voice calling) |
| Messages | Messages tab (Siri-managed rows) | **not on the screen**: messaging stays notification-based (read aloud + voice reply). The library has a Messaging category (`androidx.car.app.category.MESSAGING`, `ConversationItem`, Car API 7) but a service is declared in one category here; moving messages onto a templated screen is a separate decision, noted in "Not done" |
| Message text while driving | hidden in driving mode | never drawn at all (names only) |
| Locked / not set up | "Locked" | "Open Haven on your phone to finish setting up." until onboarding is done |

### Pieces

- `core/CarCalls.kt` — the pure rules (recents order, A→Z with accents folded, the host item limit, search,
  initials, what a tap does `Gate` = dial / busy / needs microphone, the in-call screen phase). JVM-tested.
- `core/CarCallSource.kt` — reads the live contact state (same filters as the Assistant call route). Boots the
  engine on a cold start, so it runs on a background lane.
- `car/HavenCarAppService.kt` + `HavenCarSession.kt` — the `CarAppService` (category CALLING) and its session.
  The head unit can start Haven with the app process cold: the screen shows the host spinner immediately, the
  list loads off the main thread and the screen redraws. It reloads on resume.
- `car/CarCallsScreen.kt`, `CarSearchScreen.kt`, `CarInCallScreen.kt`, `CarAvatars.kt`, `CarCallPlacer.kt`,
  `CarHosts.kt` — the templates, the dial action, the avatar renderer and the host allowlist.
- A tap goes through `CarCallPlacer` → `CallManager.startCall` → **Telecom first** (the same path as the in-app
  Call button and "call Tracy on Haven"), then the **in-call screen** ("Calling Tracy…" / "On a call with
  Tracy", a red **Hang up**). The screen closes by itself when the call ends, or after 15 s if the call never
  showed any sign of life (Telecom refused, microphone denied) so it can never strand the driver on "Calling…".
  If a call is already live, a tap shows that call instead of starting a second one. If the microphone isn't
  granted, the permission is requested **on the phone** (`CarContext.requestPermissions`) and the call is
  dialed once it is granted.
- Manifest: `.car.HavenCarAppService` (exported for the host, one intent filter: `androidx.car.app.CarAppService`
  + category `androidx.car.app.category.CALLING`), `androidx.car.app.minCarApiLevel` = 1;
  `automotive_app_desc.xml` now declares `notification` **and** `template`.
- **Host validation** (`CarHosts`): release builds accept only the signing certificates in the library's
  `hosts_allowlist_sample` (Android Auto's `com.google.android.projection.gearhead` and the Automotive OS
  templates host — Google's published list); a **debug** build accepts any host so the Desktop Head Unit and a
  sideload can connect. The leniency is keyed to the debuggable flag and a test pins that
  `ALLOW_ALL_HOSTS_VALIDATOR` appears nowhere else.

### Verified, and what needs the Desktop Head Unit / a car

Verified by unit tests (JVM): recents / contacts ordering and limits (including ties, duplicates, accents,
absurd limits), search (a prefix finds the contact, "Tracy" never offers Troy or Trey), initials, the dial gate
(busy / needs microphone / dial), the in-call phase and its start grace period, the manifest wiring (service
action + category, exported, one intent filter, min API level), the descriptor (`notification` + `template`),
that the allow-all host validator appears only inside the debug-guarded helper, that the car code never reads
message text, and that all nine locales carry the strings. The debug build compiles with the library, and the R8
(`minified`) build keeps it.

**NOT verified — needs the Desktop Head Unit or a real car:** how the host actually draws the tabs and rows
(spacing, avatar crop), the item limit your head unit returns, whether Android Auto lists Haven as a calling app
at all on your version (see Play, below), the dial → in-call round trip with real audio, and what Android Auto
adds on its own for a self-managed Telecom call.

### Testing on the Desktop Head Unit

1. `sdkmanager "extras;google;auto"` (the DHU lives in `$ANDROID_HOME/extras/google/auto`).
2. On the phone: Android Auto -> tap the version 10 times (developer mode) -> **Developer settings** ->
   enable **Unknown sources** (a sideloaded Haven is otherwise not presented) -> menu **Start head unit server**.
3. `adb forward tcp:5277 tcp:5277`, then run `./desktop-head-unit --config=config/default_1080p.ini` from the DHU
   folder. Keep its terminal input open (it exits on EOF).
4. In the DHU launcher open **Haven**: you should see **Recents** and **Contacts** tabs; tap a person — the call
   should start with no contact card in between, the in-call screen should show **Hang up**, and Haven's call
   should appear in `adb shell dumpsys telecom`.

### Play

Car App Library apps run only from a **Play** install (or a sideload with "Unknown sources" for testing), and
Play reviews them as an **Android for Cars** app. In Play Console open **Release -> Advanced settings ->
Android form factors -> Android for Cars** (the section appears once the bundle declares a car app) and
choose/confirm the **Calling** app category; upload to an **internal / closed testing** track first and run the
Car App Quality checklist (touch targets, no message text on the driving screen, driver-distraction rules —
this screen shows names and avatars only). **I could not verify Google's current policy for the Calling
category** (it has changed over the last releases and may be gated behind an opt-in form); check the Play
Console wording before shipping and tell me if it asks for anything else (a category declaration, a screenshot
set, a demo video). The messaging notification path needs none of this.

### Not done

- A Messages tab on the car screen (see the table above).
- Video calls and group calls from the car (Haven's voice calls are 1:1 audio).
- Voice-started calls ("call Tracy on Haven") already work through Assistant — see
  [ASSISTANT.md](ASSISTANT.md); the car screen is the touch path.

## Foreground service

The existing `ConnectionService` foreground service already carries the `microphone` type during a call, so
capture survives backgrounding. This work does **not** add the `phoneCall` foreground-service type: it would add
a permission and a type for no change in behaviour (a self-managed Telecom call already exempts the app from
background-start limits while it rings). Revisit if a device kills the mic mid-call.

## What is verified, and what needs a real device

Verified by unit tests (JVM, deterministic): the end-cause mapping against the platform constants, route choice
and the arbiter (initial default ignored, external change adopted, stale report ignored), the connection session
(answer / reject / hang up from the system, connect / end from the engine, nothing after the end, exactly-once
destroy), the placer (success, outright refusal, timeout, late connection, repeated refusal, superseded
placement), and manifest / registration guards (permission, the service's system-only bind permission, no phone
state permissions, every dial path through Telecom first, every engine event reported).

**Needs a real device or head unit** (none was available): that Telecom actually hands the service the
connection on the owner's phone (the fallback covers it if not), the lock-screen ring while the app is closed,
what Android Auto shows for a self-managed call, and routing to the car's speakers.

Desktop Head Unit steps: `sdkmanager "extras;google;auto"`, enable Android Auto developer mode on the phone
(tap the version 10 times) -> "Start head unit server", `adb forward tcp:5277 tcp:5277`, run
`$ANDROID_HOME/extras/google/auto/desktop-head-unit`. Then: place a Haven call from the phone, receive one from
another device and answer it from the DHU, hang up from the DHU, and note what the DHU screen shows for each
(native card / notification only / nothing). Inspect the registered account and live calls with:

```bash
adb shell dumpsys telecom
```

Expected during a call: a `PhoneAccount` for `com.blaineam.haven/.core.HavenTelecomService` and a call in state
DIALING / RINGING / ACTIVE with `SELF_MANAGED`.
