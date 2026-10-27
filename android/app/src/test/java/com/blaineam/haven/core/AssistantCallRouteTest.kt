package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Hey Google, call Tracy on Haven" — who gets dialed, and when it must NOT dial (docs/ASSISTANT.md). */
class AssistantCallRouteTest {
    private fun c(name: String, hex: String = name.lowercase().replace(" ", "") + "0".repeat(64)) =
        AssistantCallRoute.Candidate("dm:$hex", hex, AssistantRoute.recipientNames(name))

    private val tracyM = c("Tracy Miller", "a1".repeat(32))
    private val troy = c("Troy Hall", "b2".repeat(32))
    private val trey = c("Trey Fox", "c3".repeat(32))
    private val blaine = c("Blaine", "d4".repeat(32))
    private val all = listOf(tracyM, troy, trey, blaine)

    private fun plan(name: String?, format: String? = null, trusted: Boolean = true, busy: Boolean = false,
                     cands: List<AssistantCallRoute.Candidate> = all) =
        AssistantCallRoute.plan(name, format, trusted, busy, cands)

    // ---- resolving the name ----
    @Test fun aTrustedLaunchDialsTheOneMatchImmediately() {
        assertEquals(AssistantCallRoute.Plan.Dial(tracyM.hex, tracyM.circleId), plan("Tracy Miller"))
    }

    @Test fun tracyResolvesToTracyMillerWithoutOfferingTroyOrTrey() {
        assertEquals(AssistantCallRoute.Plan.Dial(tracyM.hex, tracyM.circleId), plan("Tracy"))
    }

    @Test fun tracyMInitialResolves() {
        assertEquals(AssistantCallRoute.Plan.Dial(tracyM.hex, tracyM.circleId), plan("Tracy M"))
    }

    @Test fun theSpokenNameIsCaseAndAccentInsensitive() {
        assertEquals(AssistantCallRoute.Plan.Dial(blaine.hex, blaine.circleId), plan("  BLAINE "))
    }

    @Test fun aShortcutIdHandedBackByAssistantWinsOutright() {
        assertEquals(AssistantCallRoute.Plan.Dial(troy.hex, troy.circleId), plan(troy.circleId))
    }

    @Test fun twoTracysAreAGenuineTieAndAskInsteadOfGuessing() {
        val other = c("Tracy Smith", "e5".repeat(32))
        val p = plan("Tracy", cands = all + other) as AssistantCallRoute.Plan.Pick
        assertEquals(setOf(tracyM.circleId, other.circleId), p.tied.toSet())
    }

    @Test fun aNameThatMatchesNobodyOpensTheListNeverAGuess() {
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), plan("Zebulon"))
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), plan("Tracie Hallman Junior"))
    }

    @Test fun noNameAtAllOpensTheList() {
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), plan(null))
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), plan("   "))
    }

    @Test fun tracyNeverReachesTroy() {
        val onlyTroy = plan("Tracy", cands = listOf(troy, trey))
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), onlyTroy)
    }

    // ---- the safety rules ----
    @Test fun anUntrustedLaunchNeverDialsItOpensTheConversation() {
        assertEquals(AssistantCallRoute.Plan.Open(tracyM.circleId), plan("Tracy", trusted = false))
    }

    @Test fun aVideoRequestIsNeverAutoDialedEvenFromAssistant() {
        assertEquals(AssistantCallRoute.Plan.Open(tracyM.circleId), plan("Tracy", format = "Video"))
        assertEquals(AssistantCallRoute.Plan.Open(tracyM.circleId), plan("Tracy", format = " video "))
    }

    @Test fun anAudioOrAbsentFormatIsAnAudioCall() {
        assertEquals(AssistantCallRoute.Plan.Dial(tracyM.hex, tracyM.circleId), plan("Tracy", format = "Audio"))
        assertEquals(AssistantCallRoute.Plan.Dial(tracyM.hex, tracyM.circleId), plan("Tracy", format = ""))
        assertFalse(AssistantCallRoute.isVideo(null)); assertTrue(AssistantCallRoute.isVideo("VIDEO"))
    }

    @Test fun aLiveCallIsNeverReplacedItIsBroughtToTheFront() {
        assertEquals(AssistantCallRoute.Plan.Busy, plan("Tracy", busy = true))
    }

    @Test fun anAmbiguousNameStillAsksWhileBusyOrUntrusted() {
        val other = c("Tracy Smith", "e5".repeat(32))
        assertTrue(plan("Tracy", busy = true, cands = all + other) is AssistantCallRoute.Plan.Pick)
        assertTrue(plan("Tracy", trusted = false, cands = all + other) is AssistantCallRoute.Plan.Pick)
    }

    @Test fun lockedAndBlockedContactsAreNeverCandidatesSoTheyCannotResolve() {
        // AssistantLaunch.callCandidates() drops them; with them absent the name matches nobody.
        assertEquals(AssistantCallRoute.Plan.Pick(emptyList()), plan("Tracy", cands = listOf(troy, trey, blaine)))
    }

    // ---- who launched it ----
    @Test fun theGoogleAppAndAssistantAreTrusted() {
        assertTrue(AssistantCallRoute.isTrustedReferrer("android-app://com.google.android.googlequicksearchbox"))
        assertTrue(AssistantCallRoute.isTrustedReferrer("android-app://com.google.android.apps.googleassistant"))
        assertTrue(AssistantCallRoute.isTrustedReferrer("android-app://com.google.android.googlequicksearchbox/https/www.google.com"))
    }

    @Test fun everyoneElseIsNot() {
        for (r in listOf(
            null, "", "   ", "not a uri",
            "android-app://com.android.shell",
            "android-app://com.evil.app",
            "android-app://com.google.android.googlequicksearchbox.evil",
            "https://com.google.android.googlequicksearchbox",
            "android-app:///com.google.android.googlequicksearchbox",
            "http://www.google.com/?android-app://com.google.android.googlequicksearchbox",
        )) assertFalse("referrer $r must be untrusted", AssistantCallRoute.isTrustedReferrer(r))
    }
}
