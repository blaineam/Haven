package com.blaineam.haven

import android.content.Context
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.Contact
import com.blaineam.haven.ui.AudienceComposerBar
import com.blaineam.haven.ui.ComposerAudience
import com.blaineam.haven.ui.replyPlaceholder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * The circle-audience flow on the feed composer: a post goes to EVERYONE in the circle, and the
 * composer must say so (chip, placeholder, labeled Post), ask once per circle before the first post,
 * and offer a private message instead — carrying the draft. iOS counterpart:
 * `apple/HavenUITests/AudienceUITests.swift`.
 *
 * Drives [AudienceComposerBar] directly (it is pure UI over its parameters), so no engine is needed;
 * the DM picker is swapped for a fake that "picks" Maya. Each test uses a fresh circle id, so the
 * persisted per-circle acknowledgement never leaks between tests or from a real identity's prefs.
 */
@RunWith(AndroidJUnit4::class)
class ComposerAudienceInstrumentedTest {

    @get:Rule val rule = createComposeRule()

    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun str(id: Int, vararg args: Any): String = context.getString(id, *args)

    private val maya = Contact(idHex = "aa".repeat(32), name = "Maya Quinn", verifyHex = "")

    private class Recorder {
        val posts = mutableListOf<String>()
        var privately: Pair<List<Contact>, String>? = null
    }

    /** The bar as CircleScreen hosts it: it owns the draft, "posts" by recording and clearing it. */
    private fun setBar(circleId: String, name: String = "Family", count: Int = 4): Recorder {
        val rec = Recorder()
        rule.setContent {
            var draft by remember { mutableStateOf("") }
            AudienceComposerBar(
                circleId = circleId, circleName = name, count = count,
                draft = draft, onDraftChange = { draft = it },
                canPost = draft.isNotBlank(),
                onPost = { rec.posts += draft.trim(); draft = "" },
                onSendPrivately = { picks, text -> rec.privately = picks to text; draft = "" },
                privatePicker = { _, onStart ->
                    Button(onClick = { onStart(listOf(maya)) }, modifier = Modifier.testTag("fakePickMaya")) {
                        Text("Maya Quinn")
                    }
                },
            )
            // Mirror of what the composer shows, so assertions can read the live draft.
            Text("draft=[$draft]", modifier = Modifier.testTag("draftMirror"))
        }
        return rec
    }

    private fun freshCircle() = "test-audience-${UUID.randomUUID()}"

    private fun typeDraft(text: String) {
        rule.onNodeWithTag("composeField").performTextInput(text)
        rule.onNodeWithTag("draftMirror").assertExists()
        rule.onNodeWithText("draft=[$text]").assertExists()
    }

    @Test
    fun chipPlaceholderAndPostLabelNameTheAudience() {
        setBar(freshCircle(), name = "Family", count = 6)
        val summary = str(R.string.composer_audience_everyone_count, "Family", str(R.string.composer_n_people, 6))
        assertEquals("Everyone in Family · 6 people", summary)
        rule.onNodeWithText(summary).assertIsDisplayed()
        rule.onNodeWithContentDescription(str(R.string.composer_audience_cd, summary)).assertIsDisplayed()
        rule.onNodeWithText("Post to everyone…").assertIsDisplayed()
        rule.onNodeWithText("Post").assertIsDisplayed()
        rule.onNodeWithContentDescription("Post to everyone in Family").assertIsDisplayed()
    }

    @Test
    fun chipDropsTheCountWhileUnknown() {
        setBar(freshCircle(), name = "Family", count = 0)
        rule.onNodeWithText("Everyone in Family").assertIsDisplayed()
    }

    @Test
    fun confirmationAsksOncePerCircleAndCancelKeepsTheDraft() {
        val circle = freshCircle()
        val rec = setBar(circle)

        // Cancel → nothing posted, draft kept, not acknowledged.
        typeDraft("hello all")
        rule.onNodeWithTag("composeSend").performClick()
        rule.onNodeWithText("Post to everyone in Family?").assertIsDisplayed()
        rule.onNodeWithTag("audienceConfirmCancel").performClick()
        rule.onNodeWithText("Post to everyone in Family?").assertDoesNotExist()
        assertTrue("Cancel must not post", rec.posts.isEmpty())
        rule.onNodeWithText("draft=[hello all]").assertExists()
        assertFalse(ComposerAudience.isAcknowledged(context, circle))

        // Asked again → Post to everyone → posted and acknowledged (persisted).
        rule.onNodeWithTag("composeSend").performClick()
        rule.onNodeWithTag("audienceConfirmPost").performClick()
        rule.waitForIdle()
        assertEquals(listOf("hello all"), rec.posts)
        assertTrue(ComposerAudience.isAcknowledged(context, circle))

        // Second post in the same circle goes straight out.
        typeDraft("second one")
        rule.onNodeWithTag("composeSend").performClick()
        rule.onNodeWithText("Post to everyone in Family?").assertDoesNotExist()
        rule.waitForIdle()
        assertEquals(listOf("hello all", "second one"), rec.posts)
    }

    @Test
    fun acknowledgementIsPerCircleAndSkipsSmallCirclesAndDms() {
        val a = freshCircle()
        val b = freshCircle()
        assertTrue(ComposerAudience.needsConfirmation(context, a, othersCount = 3))
        ComposerAudience.acknowledge(context, a)
        assertFalse(ComposerAudience.needsConfirmation(context, a, othersCount = 3))
        assertTrue("another circle still asks", ComposerAudience.needsConfirmation(context, b, othersCount = 3))
        assertFalse("one other person IS the one person", ComposerAudience.needsConfirmation(context, b, othersCount = 1))
        assertFalse("a DM never asks", ComposerAudience.needsConfirmation(context, "dm:$b", othersCount = 5))
    }

    @Test
    fun sendPrivatelyInsteadCarriesTheDraftAndPostsNothing() {
        val circle = freshCircle()
        val rec = setBar(circle)
        typeDraft("  just for you  ")
        rule.onNodeWithTag("composeSend").performClick()
        rule.onNodeWithTag("audienceConfirmPrivate").performClick()
        rule.onNodeWithTag("fakePickMaya").performClick()
        rule.waitForIdle()

        assertEquals(listOf(maya) to "just for you", rec.privately)
        assertTrue("nothing may be posted to the circle", rec.posts.isEmpty())
        assertFalse("sending privately is not an acknowledgement", ComposerAudience.isAcknowledged(context, circle))
        rule.onNodeWithTag("fakePickMaya").assertDoesNotExist()
        rule.onNodeWithText("draft=[]").assertExists()
    }

    @Test
    fun chipMenuSendPrivatelyOpensThePicker() {
        val rec = setBar(freshCircle())
        typeDraft("psst")
        rule.onNodeWithTag("composeAudience").performClick()
        rule.onNodeWithText("Send privately to someone…").performClick()
        rule.onNodeWithTag("fakePickMaya").performClick()
        rule.waitForIdle()
        assertEquals(listOf(maya) to "psst", rec.privately)
        assertTrue(rec.posts.isEmpty())
    }

    @Test
    fun replyPlaceholderNamesShortCirclesOnly() {
        rule.setContent {
            Text(replyPlaceholder("Family"), modifier = Modifier.testTag("short"))
            Text(replyPlaceholder("The Extended Weekend Crew"), modifier = Modifier.testTag("long"))
        }
        rule.onNodeWithText("Reply to everyone in Family…").assertExists()
        rule.onNodeWithText("Reply to everyone…").assertExists()
    }
}
