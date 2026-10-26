package com.blaineam.haven

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.ui.PostTarget
import com.blaineam.haven.ui.PostToCirclesSheet
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The long-press checklist: current circle pre-checked, DMs absent, "Post to N circles". */
@RunWith(AndroidJUnit4::class)
class PostToCirclesSheetInstrumentedTest {
    @get:Rule val rule = createComposeRule()
    private val targets = listOf(PostTarget("a", "Family"), PostTarget("dm:x", "Sam"), PostTarget("b", "Work"))

    @Test fun checklistPostsToSelectedCircles() {
        var posted: List<String>? = null
        rule.setContent { PostToCirclesSheet(targets, "a", {}, { posted = it }) }
        rule.onNodeWithText("Sam").assertDoesNotExist()
        rule.onNodeWithText("Post to 1 circle").assertExists()
        rule.onNodeWithTag("postCircle:b").performClick()
        rule.onNodeWithText("Post to 2 circles").performClick()
        assertEquals(listOf("a", "b"), posted)
    }

    @Test fun anyCircleCanBeCheckedAndPostedToWithAttachments() {
        // The sheet no longer knows about attachments: every circle is selectable.
        var posted: List<String>? = null
        rule.setContent { PostToCirclesSheet(targets, "a", {}, { posted = it }) }
        rule.onNodeWithTag("postCircle:b").performClick()
        rule.onNodeWithText("Post to 2 circles").performClick()
        assertEquals(listOf("a", "b"), posted)
    }
}
