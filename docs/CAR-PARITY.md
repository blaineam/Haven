# Haven in the car: CarPlay vs Android Auto (parity audit)

Verified from code on `main` (the files named in each row), not from memory. Last audit: 2026-10-27.

Status key: **parity** (same user-visible capability), **platform** (the platform does not allow it; why is
given), **gap** (buildable, not built), **beta** (works, but only on internal / closed testing in Play).

## The owner's question: "why can't it be like CarPlay and have tabs for either?"

Short answer: it can have **both**, and as of this change Android Auto shows **two Haven entries**:

| Entry | Class | Category | Screen |
|---|---|---|---|
| **Haven Calls** | `car/HavenCarAppService` | `androidx.car.app.category.CALLING` | `TabTemplate`: **Recents** / **Contacts**, tap = dial |
| **Haven Messages** | `car/HavenMessagesCarAppService` | `androidx.car.app.category.MESSAGING` | `ListTemplate` of `ConversationItem`s (unread state, host read-out, voice reply) |

Evidence (library 1.7.0 jar in the Gradle cache, and Google's docs):

* **The category constants exist in the 1.7.0 jar** (`CarAppService`: `CATEGORY_CALLING_APP` =
  `androidx.car.app.category.CALLING`, `CATEGORY_MESSAGING_APP` = `androidx.car.app.category.MESSAGING`), and so
  do the messaging models: `androidx.car.app.messaging.model.ConversationItem`, `CarMessage`,
  `ConversationCallback` (`onMarkAsRead()`, `onTextReply(String)`), `ConversationCallbackDelegate`, and
  `androidx.car.app.messaging.MessagingServiceConstants`.
* **One service CAN declare both categories.** Google's templated-messaging guide says: "If the app supports
  both messaging and calling, include both `androidx.car.app.category.CALLING` and
  `androidx.car.app.category.MESSAGING` in the same intent filter" (developer.android.com/training/cars/
  communication/templated-messaging). So "one service, one `TabTemplate`, Messages + Calls tabs" is legal at the
  manifest level.
* **But the documented `ConversationItem` shape is a top-level `ListTemplate`** (same page: "Header + ItemList of
  ConversationItem"). Google does not document `ConversationItem` rows inside a `TabTemplate`'s tab content, so
  we do not ship that as the primary design: an undocumented nesting can be rejected by a host at runtime with no
  way for us to see it (the host throws on its side), and we cannot run a real head unit here.
* **Two entries from one package** is the shape Google's docs allow for separate categories (each
  `CarAppService` has its own label and icon, which is what the two `<service android:label/icon>` entries
  provide). The docs do not say how a given Android Auto version lays out two services of one package; that is
  the one thing to look at on the Desktop Head Unit (below). **Fallback if a head unit shows only one Haven
  entry:** set `CarConversations.TAB_IN_CALLS_SERVICE = true` and add the `MESSAGING` category placeholder
  to the Calls service's intent filter (both are one-line changes; the Messages tab is built, tested and
  wired in `CarCallsScreen`/`HavenCarSession`, just switched off so a driver never sees the same
  conversations twice).
* **Both categories are a Google BETA.** Google's docs: anyone can publish communication apps with templated
  messaging / calling "to internal testing and closed testing tracks"; "open testing and production will be
  allowed at a later date", and "submissions containing builds with this support on open testing or production
  tracks **will be rejected**" (templated-messaging page; the calling page says the same for calling). Haven
  therefore builds the car categories **only for the internal and closed (alpha) tracks**: see "Play and the
  beta" below. This is why a plain-tag production release has no car app (it still has Telecom calls, voice
  calls, and notification-based Android Auto messaging).
* **Templated messaging apps must still post `MessagingStyle` notifications** (the guide says so), and
  Haven does ([`CarNotifications`](../android/app/src/main/java/com/blaineam/haven/core/CarNotifications.kt)),
  so Android Auto's read-aloud-on-arrival and voice reply keep working on every build, beta or not.

## Feature table

| Capability | CarPlay (iOS) | Android Auto (Android) | Status |
|---|---|---|---|
| Messages list with unread state | Messages tab (`CarPlayTemplates`, `CarPlayConversations`): conversation rows, unread dot, 12 x 6 snapshot | **Haven Messages** entry: `ConversationItem` per DM thread (1:1 and group), unread from `DmRead` watermark, <= 10 threads x 5 messages (`CarConversations`, `CarMessagesList`) | parity (beta on Android) |
| Conversation screen with recent messages | App-drawn chat-order screen: last 8 messages, own + contact avatars in palette tint | The **host** draws the conversation from the `ConversationItem` (our messages, 5 max). A third-party app cannot draw its own conversation screen in Android Auto | platform |
| Read the unread aloud on tap | `CarPlaySpeaker` (AVSpeech) in driving mode: unread read directly; none unread -> Siri compose | Host reads the unread of a tapped `ConversationItem`; Android Auto also reads each new `MessagingStyle` notification aloud on arrival | parity |
| Read-aloud voice choice | Voice picker, "Match system" (`CarPlayVoice`) | None: Android Auto speaks with the system / Assistant voice, apps cannot pick it | platform |
| Voice reply | Siri-managed `CPMessageListItem` row (compose by voice) | `ConversationCallback.onTextReply` and the notification `REPLY` semantic action, both through `CarMessaging.execute` -> `HavenNet.sendDm` | parity |
| Mark as read | After read-aloud, and Siri `INSetMessageAttribute` | `ConversationCallback.onMarkAsRead` and the notification `MARK_AS_READ` action -> `DmRead.markRead` (also clears the badge on other devices via self-sync) | parity |
| Driving mode hides message text | `CarPlayDriveMode` from `CPSessionConfiguration.limitedUserInterfaces`; driving rows show names/counts only | The head unit hides text while the car moves for `ConversationItem` (the reason the model exists); Haven never draws text on the Calls screens (`CarAppDeclarationTest` source-scans for it) | parity (host-enforced on Android) |
| Locked (biometric) conversations | Shown as a non-tappable "Locked" row; never read, sent or marked | **Omitted entirely** (a `ConversationItem` has no inert state): no row, no name, never decoded (`CarConversationSource`); reply / mark-read re-check the lock at send time | parity (stricter) |
| Notification privacy levels | Full / Name+type only / Minimal (`MessagingPrivacy`) | `full` / `private` / `minimal`: only `full` hands real texts to the host or the car notification; the others list the thread with the generic "New message" (`CarConversations.rows`, `CarMessaging.plan`) | parity |
| Calls tab, tap to dial | Calls tab rows dial immediately | **Haven Calls** Recents / Contacts rows dial immediately, no contact card (`CarCalls`, `CarCallsScreen`) | parity (beta on Android) |
| In-call experience | CallKit; CarPlay presents the call natively | Telecom self-managed `ConnectionService` (`HavenTelecomService`) + car in-call screen with Hang up; Android Auto shows its own call view | parity (different mechanism) |
| Ring / incoming call | CallKit | Own CallStyle notification + looping ring that follows the ringer (`d3b4a472`) | parity |
| Voice: send a message | Siri `INSendMessageIntent`, vocabulary donations | Assistant `CREATE_MESSAGE` App Action -> composer staged, user taps Send (`AssistantRoute`); needs a Play-installed build | parity, **Play-only** |
| Voice: call | Siri `INStartCallIntent` | Assistant `CREATE_CALL` -> dials only when launched by the Google app (`AssistantCallRoute`); Play-only | parity, **Play-only** |
| Fuzzy contact matching ("Tracy M") | `ContactMatching` tiered matcher | `AssistantRoute.match` (same four tiers; "Tracy" never offers "Troy"); also used by the car search row | parity |
| Incoming message read aloud | Communication notifications + Announce Notifications (user setting) | Android Auto reads `MessagingStyle` notifications aloud; no user setting needed | parity |
| Late (backfilled) messages announced | Notification path | DM threads use a 24 h freshness window, circle posts keep 10 minutes (`InboundNotifyPolicy`, `37def092`), so a DM that lands late still posts its car notification | parity |
| Image description for received photos | Not done (documented in `CARPLAY.md`: no Apple API; NSE cannot hold the key) | Not done: no on-device image-captioning dependency in the app and no Android Auto API to attach a description; a photo reads as "Sent a photo" | parity (both absent); post-release idea: describe in-app after ingest behind the sensitive-content check |
| Palette tint | Avatars, glyphs, Reply mic | Initials avatars use the palette's tint stop (`CarAvatars`); host-drawn chrome (tabs, icons) is the host's colour | parity where Android lets apps colour |
| My profile photo on my messages | Yes (`CarPlayAvatar`, own-photo rows) | The `self` person of a `ConversationItem` carries no icon; the host decides how to show "me" | gap (small; needs a DHU check that the host uses `Person.icon`) |
| "Call" shortcut inside a conversation | Nav-bar Call button | Not on the `ConversationItem` (the model supports `addAction`; Google's guide shows no call example and the host may only honour reply / mark-read) | gap (needs DHU confirmation) |
| Two entries / one entry | One Haven app, tab bar | Two entries (Calls, Messages), one process, shared data sources | by design |

## What remains platform-limited (and why)

1. **No app-drawn conversation screen, no chat bubbles, no custom voice** on Android Auto: the Car App Library
   exposes fixed templates and models (`ConversationItem`, `ListTemplate`, `TabTemplate`...). The host owns
   the conversation UI, the read-aloud voice and the driving restriction.
2. **Production Play builds cannot carry the car app yet** (beta, above). Calls through Telecom, "call X on
   Haven" and notification messaging do ship to production.
3. **Assistant App Actions** (voice send / voice call) only run for a **Play-installed** build with the
   `shortcuts.xml` capability processed; a sideload can be tested with Android Studio's App Actions Test Tool.

## Play and the beta (what the build does, what the owner does)

* `android/app/build.gradle.kts` turns the two category names into manifest placeholders. `HAVEN_CAR_APP`
  (env) or `-PhavenCarApp` (Gradle) = `false` swaps them for inert names (`com.blaineam.haven.category.
  CAR_APP_OFF_*`) and sets both services `android:enabled="false"`, so the manifest carries no
  CALLING / MESSAGING category at all. **Default is on** (local, debug, DHU testing).
* `.github/workflows/android.yml` sets `HAVEN_CAR_APP` for the bundle build from the Play track the same step
  already resolved: **internal and alpha (closed testing) -> on; production and beta (open testing) -> off.**
  An rc tag goes to internal + alpha, so release candidates ship the car app to testers; a plain release tag
  goes to production, which strips it. `CarAppDeclarationTest` pins all of this (the placeholders, the
  defaults, the workflow expression).
* Owner, in Play Console: open **Release -> Advanced settings -> Android form factors -> Android for Cars**
  and confirm the **Calling** and **Messaging** categories for the internal/closed track; Google also offers an
  early-access programme form for communication apps (linked from the templated-messaging page). When Google
  opens the categories to production, flip the workflow expression to include `production` (one line).
* Not verified here: Google's current policy wording for each category; check it in the Console.

## Testing on the Desktop Head Unit (DHU) with the Nokia

1. Nokia: Android Auto settings -> **Developer settings** (tap the version 10 times if hidden) -> enable
   **Unknown sources**; three-dot menu -> **Start head unit server**.
2. Mac: `adb -s <nokia> forward tcp:5277 tcp:5277`, then run `desktop-head-unit` (the DHU keeps stdin open:
   `tail -f /dev/null | ./desktop-head-unit --config=config/default_1080p.ini`).
3. In the DHU launcher look for **two** Haven entries: **Haven Calls** (green handset) and **Haven Messages**
   (blue bubble). If only one appears, use the fallback above and tell us what the DHU showed.
4. Haven Messages: needs "Android Auto messages" on (Haven Settings), a signed-in account and at least one DM
   with a message. Expect the host's conversation list; tap one: the host should read the unread aloud
   (and offer reply). A reply must arrive as an ordinary sealed DM on the iPhone; marking read clears the
   thread's unread badge in Haven.
5. Check the redaction: Haven Settings -> notification detail -> **Private** or **Minimal**: each thread
   should now read as "New message" (the real texts never leave Haven); lock a DM with biometrics: it
   disappears from the list.
6. Haven Calls: Recents / Contacts tabs, tap a person, the call dials and the in-call screen shows Hang up.
7. Release build parity: `./gradlew :app:processReleaseMainManifest -PhavenCarApp=false` and check the merged
   manifest has no `androidx.car.app.category.*` (the unit tests assert the placeholders; this proves the merge).

## Tests

`CarConversationsTest` (privacy / ordering / caps / unread), `CarAppDeclarationTest` (two services, categories,
labels + icons, host validator, API level 7, gating in Gradle and the workflow, strings in 9 locales, the
Calls screens never read message text), `CarMessagingTest` / `CarCallsTest` (unchanged rules).
