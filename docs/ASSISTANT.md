# Google Assistant: "send a message to Blaine on Haven" (Android)

Haven declares one Assistant **App Action** (`actions.intent.CREATE_MESSAGE`) so that
"Hey Google, send a message to Blaine on Haven" opens Haven on that conversation. Replying to a
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

* **Calls** (`actions.intent.CREATE_CALL`): not declared. A voice-launched call rings someone, and the
  same any-app-can-fire-it argument applies without a confirmation step Haven does not have yet.
* **Sending without a tap** from "send a message to Blaine saying …": see above. Assistant opens Haven
  with the text ready; one tap sends.
* The message text is not kept if the recipient is ambiguous (the user is asked to pick, then types).

## What can and cannot be verified

Assistant only fulfils App Actions for an app that **Google Play has registered**: the capability is
read from `shortcuts.xml` when a build is uploaded to Play Console and linked to the Assistant
integration. So:

| | Debug / sideloaded build | Play build (internal test track or later) |
|---|---|---|
| "Hey Google, send a message to Blaine on Haven" | **Does not work.** Assistant has never registered the capability. | Works once Play has processed the upload (can take hours; Google may also gate surfacing on quality). |
| Android Studio **Google Assistant plugin** > App Actions Test Tool | Works: it creates a preview for the signed-in Google account on the device, so this is the way to try the real voice path before release. | n/a |
| The receiving side (resolution, staging, opening the thread) | Fully testable with `adb`, see below. | Same. |
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

Inspect the published shortcuts and their capability bindings:

```bash
adb shell dumpsys shortcut com.blaineam.haven
```

Expected: one entry per recent DM with `categories=[com.blaineam.haven.category.SHARE_TARGET, android.shortcut.conversation]`,
a `locusId`, and a `capabilityBindings` entry for `actions.intent.CREATE_MESSAGE` listing the names.

## Tests

* `AssistantRouteTest`: tiered matching (Tracy / Troy / Trey, "Tracy M", ties, accents, group vs 1:1,
  shortcut id), text sanitising, and that a plan can only be open or pick, never send.
* `AssistantShortcutsDeclarationTest`: parses `shortcuts.xml` and checks the capability, the intent
  action and package/class, the parameter keys against what `MainActivity` reads, that no parameter is
  required (so the single intent is also the fallback), the manifest meta-data on every launcher
  entry, and the dynamic shortcut's capability binding and conversation markers.
