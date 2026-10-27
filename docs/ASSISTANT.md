# Google Assistant: "send a message to Blaine on Haven" and "call Blaine on Haven" (Android)

Haven declares two Assistant **App Actions**: `actions.intent.CREATE_MESSAGE` so that
"Hey Google, send a message to Blaine on Haven" opens Haven on that conversation, and
`actions.intent.CREATE_CALL` so that "Hey Google, call Blaine on Haven" dials them (see
[Calling by voice](#calling-by-voice) below). Replying to a
message ("reply to Blaine, …") is a separate, older path that does not use App Actions: see
[ANDROID-AUTO.md](ANDROID-AUTO.md).

## Status of Google's voice stack (read this first) — checked against Google's pages, October 2026

Production Haven on Android relies on two things Google supports today:

1. **Notification-based messaging in Android Auto** (read aloud, voice reply, mark as read): not in beta.
   Requirements are listed in [Android Auto messaging notifications](#android-auto-messaging-notifications-checklist).
2. **Voice commands to the phone's assistant** through **App Actions** (`CREATE_CALL`, `CREATE_MESSAGE`).

What Google says, and what it does not say (each line cites the page it came from; none of this could be
exercised from a debug build, because App Actions are registered by Google Play):

| Question | Answer | Source (retrieved 2026-10-27) |
|---|---|---|
| Are App Actions still supported? | **Yes.** "Assistant's App Actions let users launch and control Android apps with their voice"; Android 5+, phones only, not Android Go. Page last updated 2026-07-16. | [App Actions overview](https://developer.android.com/develop/devices/assistant/overview) |
| Does that include Gemini? | **Partly documented.** The overview page and the build guide only say "Assistant". The *cars* page says drivers "can use Gemini or Google Assistant to control Android apps" and that "Gemini or Google Assistant matches the query to a built-in intent (BII) declared in your app's `shortcuts.xml`". Press reports say Assistant is being removed from Android from **2026-09-04** and replaced by Gemini; Google's developer pages do not describe what changes for communication BIIs. **Unverified for CREATE_CALL / CREATE_MESSAGE under Gemini.** | [App Actions for cars](https://developer.android.com/develop/devices/assistant/cars) (updated 2026-10-23); press: [implicator.ai](https://www.implicator.ai/google-sets-september-4-date-to-replace-assistant-with-gemini-on-android/) |
| Do `CREATE_CALL` / `CREATE_MESSAGE` still exist, with what parameters? | **Yes.** `call.participant.name` / `.telephone` / `.identifier`, `call.callFormat` (Audio, Video); `message.text`, `message.recipient.name` / `.telephone` / `.email`, `message.disambiguatingDescription`. None is required. User invocation and the Test Tool preview are **en-US only**. Reference pages last updated 2024-09-04. | [CREATE_CALL](https://developer.android.com/reference/app-actions/built-in-intents/communications/create-call), [CREATE_MESSAGE](https://developer.android.com/reference/app-actions/built-in-intents/communications/create-message) |
| Is a Play upload enough? | **No. Google must review and approve.** "App Actions aren't available to users of your published apps or open test releases until they're reviewed and approved." Steps: accept the App Actions terms in Play Console (**Advanced settings > App Actions**), upload a build whose `shortcuts.xml` declares the capabilities, Google emails you; internal/closed testers see unapproved actions only after joining the *App Actions Development Program* Google Group (up to ~3 h). Redeployed versions are reviewed again. (Earlier versions of this file said there is no separate step; that was wrong.) | [Build App Actions](https://developer.android.com/develop/devices/assistant/get-started) (updated 2026-02-26) |
| Do App Actions work for phone apps projected to Android Auto? | **Not documented.** Google's "App Actions for cars" page documents only the parking and charging BIIs, for Car App Library apps in the POI category. Communication BIIs are not mentioned for cars. Whether Assistant/Gemini in the car hands `CREATE_CALL` to the *phone's* app is **unverified**; Haven's calls themselves are visible to the car through Telecom (docs/ANDROID-CALLS.md). | [App Actions for cars](https://developer.android.com/develop/devices/assistant/cars) |
| AppFunctions (the Gemini-native route)? | **Experimental, Android 16+, Gemini integration in private preview.** "As of May 2026, AppFunctions integration with Gemini is in a private preview with trusted testers"; callers need `EXECUTE_APP_FUNCTIONS`; an Early Access Program exists and registering "does NOT automatically" grant access. Jetpack `androidx.appfunctions:*:1.0.0-alpha10`, KSP, `compileSdk 36`. **Haven does not ship it** (see below). | [AppFunctions overview](https://developer.android.com/ai/appfunctions) (updated 2026-10-22), [Add AppFunctions](https://developer.android.com/ai/appfunctions/add-appfunctions) |
| Android Auto messaging notifications | Documented, **not** beta; `MessagingStyle` + `SEMANTIC_ACTION_REPLY` + `SEMANTIC_ACTION_MARK_AS_READ`. The page does not mention "send a message to X" by voice. | [Messaging notifications](https://developer.android.com/training/cars/communication/notification-messaging) (updated 2026-10-23) |

### Why AppFunctions is not in this release

* Gemini's use of third-party AppFunctions is invitation-only today, so shipping it would not change what a user
  can say to Gemini.
* The Jetpack library is an **alpha** (`1.0.0-alpha10`) and needs the KSP compiler plugin, which this project does
  not use; neither is in the offline Gradle cache, and an alpha compiler plugin in the production build is a risk
  with no user benefit yet.
* When it opens up, the work is small and the routing already exists: `callContact(name)` would call
  `AssistantCallRoute` and `sendMessage(name, text)` would call `AssistantRoute` (staging, never sending), gated by
  `SDK_INT >= 36`. Apply to the Early Access Program from the AppFunctions page when ready.

### What this means for the owner

* "Hey Google, call Blaine on Haven" and "…send a message to Blaine on Haven" can only work on a **Play-installed**
  build whose `shortcuts.xml` Google has **approved**, in **en-US**, and only if Gemini honours App Actions for these
  intents (documented for Assistant and, for cars, for Gemini; not documented for communication BIIs).
* The part that does not depend on any of that: a **message notification** is read aloud in the car and answered by
  voice, and a Haven **call** placed or answered from the car is a real Telecom call (the car shows and controls it).

## What it does

1. Assistant launches `MainActivity` with an explicit intent: action
   `com.blaineam.haven.action.ASSISTANT_MESSAGE`, extras `name` (the spoken recipient) and `text`
   (the message, if the user said one). Declared in `android/app/src/main/res/xml/shortcuts.xml`.
2. `AssistantRoute` (pure Kotlin, JVM-tested) resolves the recipient against the user's contacts and
   group threads with the same tiered idea as Apple's `ContactMatching`: exact name, then "every word
   spoken is a word of the name", then a prefix or initial ("Tracy M"), then a one-letter spelling
   slip. The best tier present wins and only a genuine tie asks, so "Tracy" never offers "Troy". A
   first name is an alias that can never outrank a contact literally named that.
3. One match: Haven opens that conversation with the text **staged in the composer**. No match, no
   name, or a tie: Haven opens the Messages list to pick.

### It never sends from the intent

An explicit intent to an exported activity can be fired by **any** app on the phone (and `haven://`
links by any web page), so nothing that arrives this way may speak as the user without a tap. The
text is staged; the user presses Send. Sending *by voice* is the notification REPLY action (Android
Auto, Assistant "reply to …"), whose PendingIntents only Haven itself can fire.

### Never for a locked conversation

Biometric-locked circles are not candidates: a voice command cannot confirm one exists, open it, or
stage text into it, and no shortcut for one is ever published.

### Dynamic shortcuts (the contact inventory)

`ShareShortcuts` publishes the six most recent DM threads as long-lived dynamic shortcuts carrying a
`Person`, a `LocusId`, `android.shortcut.conversation` and `setIsConversation()`, plus a capability
binding of the contact's full and first name to `message.recipient.name`. When Assistant matches a
shortcut it hands Haven the shortcut id (the `dm:` circle id), which wins outright. When it doesn't,
it passes the spoken name and `AssistantRoute` matches it against **all** contacts. These are the
same shortcuts as the share sheet's Direct Share row, so they follow the same Settings switch
("Share suggestions"): off removes them, and Assistant then falls back to the spoken name.

## What is not covered

* **Video calls by voice**: a `call.callFormat` of Video is never auto-dialed (Haven's voice calls are
  audio; the thread opens so the user taps the call button).
* **Sending without a tap** from "send a message to Blaine saying …": see above. Assistant opens Haven
  with the text ready; one tap sends.
* The message text is not kept if the recipient is ambiguous (the user is asked to pick, then types).

## Calling by voice

"Hey Google, call Tracy on Haven" (also delivered by Assistant in the car) launches `MainActivity` with action
`com.blaineam.haven.action.ASSISTANT_CALL` and extras `callName` (`call.participant.name`) and `callFormat`
(`call.callFormat`), declared next to the message action in `shortcuts.xml`. `AssistantCallRoute` (pure Kotlin,
JVM-tested) resolves the person with **the same tiered matcher as messages** (it calls `AssistantRoute.match`),
so "Tracy", "Tracy M" and "Tracy Miller" reach the same contact and "Tracy" never offers "Troy".

Unlike a message, a call **does start from the intent** (that is the point of a voice command in a car), so the
safety comes from *who launched it* and *what it would call*:

| Situation | What Haven does |
|---|---|
| Launched by the Google app / Assistant (`com.google.android.googlequicksearchbox`, `com.google.android.apps.googleassistant`), one 1:1 contact matches, no call active, microphone granted | **Dials immediately** through Telecom ([ANDROID-CALLS.md](ANDROID-CALLS.md)); the in-app call screen with Hang up appears and the ring is cancellable |
| Any other launcher (adb, another app, unknown) | Opens that contact's conversation; the user taps Call. **Never dials.** |
| Microphone permission not granted | Opens the conversation (a voice launch from the background cannot show the prompt); tapping Call runs it |
| Genuine tie ("Tracy" with two Tracys) | Opens the Messages list to pick |
| No match / no name | Opens the Messages list. No guessing, no dissimilar names |
| A group conversation, a locked or a blocked contact | Never a candidate: cannot be dialed, confirmed to exist or opened by voice |
| A call is already active | Brings the live call to the front; starts nothing |
| `call.callFormat` Video | Never auto-dialed; opens the conversation |

The launch is trusted by the **system-provided referrer** (`Activity.getReferrer()`: the package that launched
the activity), compared by scheme and package only - never an intent extra the sender wrote. The trusted set is the
Google app and the Assistant package. If Assistant in some car or Android version launches from a different
package the call falls back to "opens the conversation" (safe), and the package can be added to
`AssistantCallRoute.TRUSTED_PACKAGES` once observed in `adb logcat`. The shortcuts published for 1:1 threads also
bind the contact's names to `call.participant.name`; group threads are never bound for calling.

The Android Auto path is the same intent: Assistant in the car hands the BII to the phone. The phone may need
to be unlocked for the activity to come up; the call itself then rides Telecom, so the car shows and controls it.

## What can and cannot be verified

Assistant only fulfils App Actions for an app that **Google Play has registered**: the capability is
read from `shortcuts.xml` when a build is uploaded to Play Console and linked to the Assistant
integration. So:

| | Debug / sideloaded build | Play build (internal test track or later) |
|---|---|---|
| "Hey Google, send a message to Blaine on Haven" | **Does not work.** Assistant has never registered the capability. | Works once Play has processed the upload (can take hours; Google may also gate surfacing on quality). |
| Android Studio **Google Assistant plugin** > App Actions Test Tool | Works: it creates a preview for the signed-in Google account on the device, so this is the way to try the real voice path before release. | n/a |
| The receiving side (resolution, staging, opening the thread) | Fully testable with `adb`, see below. | Same. |
| "Hey Google, call Blaine on Haven" | **Does not work** by voice (same reason). | Works once Play has processed the upload, with the same caveats. |
| The call receiving side (resolution, trust check, dial) | Testable with `adb`: **an adb launch is untrusted by design and only opens the thread** - the dial path itself is covered by unit tests and by the App Actions Test Tool (whose launch comes from the Google app). | Same. |
| "Reply to Blaine" from a message notification | Works on any build (it is a notification action). | Same. |

Needs the owner (Google's process, from [Build App Actions](https://developer.android.com/develop/devices/assistant/get-started)):

1. Play Console > **Advanced settings > App Actions**: accept the terms.
2. Upload a build that contains `shortcuts.xml` (internal or closed testing first).
3. Google reviews `shortcuts.xml` separately from app review and emails the result. Until it is approved, internal
   and closed testers must join the *App Actions Development Program* Google Group to see the actions (allow up
   to three hours), and open testing / production users do not get them at all.
4. Run the Android Studio **Google Assistant plugin > App Actions Test Tool** once with the Google account that
   owns the phone (en-US).
5. Voice-trigger only to demonstrate: Google recommends the Test Tool for routine testing.

### Proving the receiving side with adb (works on a debug build)

Spoken name and text (opens Blaine's thread with the text in the composer, not sent):

```bash
adb shell am start -n com.blaineam.haven/.MainActivity -a com.blaineam.haven.action.ASSISTANT_MESSAGE --es name "Blaine" --es text "On my way"
```

An ambiguous or unknown name (opens the Messages list):

```bash
adb shell am start -n com.blaineam.haven/.MainActivity -a com.blaineam.haven.action.ASSISTANT_MESSAGE --es name "Zed"
```

A call request (an adb launch is **untrusted**, so this opens the conversation and does not dial - the
documented safe fallback; the voice path dials):

```bash
adb shell am start -n com.blaineam.haven/.MainActivity -a com.blaineam.haven.action.ASSISTANT_CALL --es callName "Blaine" --es callFormat "Audio"
```

Inspect the published shortcuts and their capability bindings:

```bash
adb shell dumpsys shortcut com.blaineam.haven
```

Expected: one entry per recent DM with `categories=[com.blaineam.haven.category.SHARE_TARGET, android.shortcut.conversation]`,
a `locusId`, and `capabilityBindings` entries for `actions.intent.CREATE_MESSAGE` (and, for 1:1 threads,
`actions.intent.CREATE_CALL`) listing the names.

## Tests

* `AssistantRouteTest`: tiered matching (Tracy / Troy / Trey, "Tracy M", ties, accents, group vs 1:1,
  shortcut id), text sanitising, and that a plan can only be open or pick, never send.
* `AssistantShortcutsDeclarationTest`: parses `shortcuts.xml` and checks the capability, the intent
  action and package/class, the parameter keys against what `MainActivity` reads, that no parameter is
  required (so the single intent is also the fallback), the manifest meta-data on every launcher
  entry, and the dynamic shortcut's capability binding and conversation markers.
* `AssistantCallRouteTest`: the same matching for calls, trusted vs untrusted referrers (incl. look-alike
  packages and spoofed URIs), ambiguous, video, busy, locked/blocked exclusion, and that an untrusted launch can
  only open, never dial.
* `AssistantShortcutsDeclarationTest` also parses the `CREATE_CALL` capability (action, package/class, keys vs
  what `MainActivity` reads, no phone number bound, optional parameters), that `MainActivity` checks the
  referrer before dialing, and that only 1:1 shortcuts are bound for calling.

## Trusted launchers and how to see which one Gemini uses

A call is dialed only when the launcher package is in `AssistantCallRoute.TRUSTED_PACKAGES`: the Google app
(`com.google.android.googlequicksearchbox`, which hosts Assistant and Gemini's voice entry on most phones), the
standalone Assistant app (`com.google.android.apps.googleassistant`) and the Gemini app
(`com.google.android.apps.bard`, added defensively: Google does not document which package launches App Action
fulfilment under Gemini). Every assistant call launch logs the referrer package, nothing else:

```bash
adb logcat -s HavenAssistant
```

Expected: `call launch referrer=com.google.android.googlequicksearchbox trusted=true`. If a voice command opens the
conversation instead of dialing, this line shows the package that launched it; add it to `TRUSTED_PACKAGES` only
if it is a Google-signed package.

## Android Auto messaging notifications checklist

Verified against [Messaging notifications](https://developer.android.com/training/cars/communication/notification-messaging)
(updated 2026-10-23) and implemented in `CarNotifications.kt`; the pure rules (what may reach the car, privacy,
locked threads) are in `CarMessaging.kt` and covered by `CarMessagingTest`.

| Requirement (Google) | Haven |
|---|---|
| `<uses name="notification" />` in `automotive_app_desc.xml` | yes (the car-app `template` entry is added only in builds with the car categories, see CAR-PARITY.md) |
| `MessagingStyle` with a `Person` per sender (unique `key`), `setGroupConversation` set **after** the title | yes; group flag now set after the title |
| `setLargeIcon` = the conversation image in Android Auto | **added**: the contact's picture for a 1:1 thread; none for a group |
| Reply: `SEMANTIC_ACTION_REPLY`, `setShowsUserInterface(false)`, exactly one `RemoteInput`, mutable `PendingIntent` | yes (`FLAG_MUTABLE` on API 31+) |
| Mark as read: `SEMANTIC_ACTION_MARK_AS_READ`, no UI, no `RemoteInput` | yes |
| Unique PendingIntent / notification ids per conversation; repeated calls for one conversation return the same id | notification id is a stable hash of the conversation; PendingIntents are now made distinct by the Intent **data** (`CarMessaging.actionData`), because PendingIntents ignore extras and a request-code xor could collide |
| Actions handled by a background component, never an Activity | yes (`CarActionReceiver`, a broadcast receiver) |
| Message history only from notifications during the car session | inherent to notification messaging |

Haven-specific privacy (not required by Google): only a plain inbound DM at the **Full** preview level, never a locked
thread, only while "Android Auto messages" is on; private/minimal levels and circle posts stay ordinary banners that
the car does not read.

## Owner test script (Play internal testing build)

1. Play Console: accept the App Actions terms, upload this build to the **internal testing** track, join the
   *App Actions Development Program* Google Group with the phone's Google account, wait up to three hours.
2. Install from Play (not a sideload). Open Haven once so the conversation shortcuts are published.
3. Set the phone's assistant language to English (US). Say "Hey Google, send a message to <contact> on Haven": Haven
   should open that conversation with the text ready. Say "Hey Google, call <contact> on Haven": the call should ring
   out. Watch `adb logcat -s HavenAssistant` to see the launcher package.
4. In the car (or the Desktop Head Unit with "Unknown sources" on): have the iPhone send a DM. The notification should
   be read aloud, and "reply" by voice should send. Mark as read should clear it.
5. Result matrix to report back: (a) phone voice works / does not, (b) car voice works / does not, (c) the launcher
   package from the log. If (a) fails on a Play build under Gemini, App Actions are not honoured for these intents
   there and the next step is the AppFunctions Early Access Program.
