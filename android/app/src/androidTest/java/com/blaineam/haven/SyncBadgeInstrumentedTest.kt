package com.blaineam.haven

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.SyncBadgeState
import com.blaineam.haven.ui.SyncBadgePill
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The composer sync pill renders what the upload queue says — real counts, "Retrying (N waiting)"
 * during backoff — and follows state changes (Sending → Synced) without a poll.
 */
@RunWith(AndroidJUnit4::class)
class SyncBadgeInstrumentedTest {
    @get:Rule val rule = createComposeRule()
    private val res = InstrumentationRegistry.getInstrumentation().targetContext.resources

    @Test fun sending_then_synced_follows_the_state() {
        var state by mutableStateOf<SyncBadgeState>(SyncBadgeState.Sending(1, 3))
        rule.setContent { SyncBadgePill(state) {} }
        rule.onNodeWithText(res.getString(R.string.sync_badge_sending, 1, 3)).assertIsDisplayed()
        state = SyncBadgeState.Sending(3, 3)
        rule.onNodeWithText(res.getString(R.string.sync_badge_sending, 3, 3)).assertIsDisplayed()
        state = SyncBadgeState.Synced
        rule.onNodeWithText(res.getString(R.string.sync_badge_synced)).assertIsDisplayed()
    }

    @Test fun retrying_shows_the_waiting_count() {
        rule.setContent { SyncBadgePill(SyncBadgeState.Retrying(2)) {} }
        rule.onNodeWithText(res.getString(R.string.sync_badge_retrying, 2)).assertIsDisplayed()
    }

    @Test fun local_says_device_only_and_the_pill_is_tappable() {
        var taps = 0
        rule.setContent { SyncBadgePill(SyncBadgeState.Local) { taps++ } }
        rule.onNodeWithText(res.getString(R.string.circle_device_only)).assertIsDisplayed()
        rule.onNodeWithTag("syncBadge").performClick()
        assertEquals(1, taps)
    }
}
