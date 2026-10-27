# Google Assistant: "send a message to Blaine on Haven" and "call Blaine on Haven" (Android)

Haven declares two Assistant **App Actions**: `actions.intent.CREATE_MESSAGE` so that
"Hey Google, send a message to Blaine on Haven" opens Haven on that conversation, and
`actions.intent.CREATE_CALL` so that "Hey Google, call Blaine on Haven" dials them (see
[Calling by voice](#calling-by-voice) below). Replying to a
message ("reply to Blaine, …") is a separate, older path that does not use App Actions: see
[ANDROID-AUTO.md](ANDROID-AUTO.md).

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

Needs the owner: confirm in Play Console that the app is linked to Assistant (App Actions are enabled
by uploading a build whose `shortcuts.xml` declares capabilities; there is no separate toggle for
BII-based actions) and run the App Actions Test Tool once with the account that owns the phone.

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
