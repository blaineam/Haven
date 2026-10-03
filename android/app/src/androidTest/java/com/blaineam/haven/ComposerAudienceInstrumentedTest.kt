package com.blaineam.haven

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
import com.blaineam.haven.ui.AudienceComposerBar
import com.blaineam.haven.ui.replyPlaceholder
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The circle-audience cues on the feed composer: a post goes to EVERYONE in the circle, and the
 * composer's own form says so (a placeholder naming the circle, a labeled Post pill) — with no
 * audience menu and no confirmation, so Post goes straight out. iOS counterpart:
 * `apple/HavenUITests/AudienceUITests.swift`.
 *
 * Drives [AudienceComposerBar] directly (it is pure UI over its parameters), so no engine is needed.
 */
@RunWith(AndroidJUnit4::class)
class ComposerAudienceInstrumentedTest {

    @get:Rule val rule = createComposeRule()

    /** The bar as CircleScreen hosts it: it owns the draft, "posts" by recording and clearing it. */
    private fun setBar(name: String = "Family"): MutableList<String> {
        val posts = mutableListOf<String>()
        rule.setContent {
            var draft by remember { mutableStateOf("") }
            AudienceComposerBar(
                circleName = name,
                draft = draft, onDraftChange = { draft = it },
                canPost = draft.isNotBlank(),
                onPost = { posts += draft.trim(); draft = "" },
            )
            // Mirror of what the composer shows, so assertions can read the live draft.
            Text("draft=[$draft]", modifier = Modifier.testTag("draftMirror"))
        }
        return posts
    }

    private fun typeDraft(text: String) {
        rule.onNodeWithTag("composeField").performTextInput(text)
        rule.onNodeWithText("draft=[$text]").assertExists()
    }

    @Test
    fun placeholderAndPostLabelNameTheAudience() {
        setBar(name = "Family")
        rule.onNodeWithText("Post to everyone in Family").assertIsDisplayed()
        rule.onNodeWithText("Post").assertIsDisplayed()
        rule.onNodeWithContentDescription("Post to everyone in Family").assertIsDisplayed()
        rule.onNodeWithTag("composeAudience").assertDoesNotExist()
    }

    @Test
    fun longCircleNamesFallBackToTheGenericPlaceholder() {
        setBar(name = "The Extended Weekend Crew")
        rule.onNodeWithText("Post to everyone…").assertIsDisplayed()
        rule.onNodeWithContentDescription("Post to everyone in The Extended Weekend Crew").assertIsDisplayed()
    }

    @Test
    fun postGoesStraightThroughWithoutConfirmation() {
        val posts = setBar()
        typeDraft("hello all")
        rule.onNodeWithTag("composeSend").performClick()
        rule.waitForIdle()
        assertEquals(listOf("hello all"), posts)
        rule.onNodeWithText("Post to everyone in Family?").assertDoesNotExist()
        rule.onNodeWithText("draft=[]").assertExists()

        typeDraft("second one")
        rule.onNodeWithTag("composeSend").performClick()
        rule.waitForIdle()
        assertEquals(listOf("hello all", "second one"), posts)
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
