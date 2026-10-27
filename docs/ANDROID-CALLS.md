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
