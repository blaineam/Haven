package com.blaineam.haven

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.HistoryHandoff
import com.blaineam.haven.ui.HistoryHandoffCard
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The transfer banner: progress while sending, "Cancel transfer" behind a confirmation, and the
 *  dismissible "cancelled" card. Apple: `HistoryHandoffBanner.swift`. */
@RunWith(AndroidJUnit4::class)
class HistoryHandoffBannerInstrumentedTest {

    @get:Rule val rule = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun s(id: Int, vararg args: Any) = context.getString(id, *args)

    private var cancels = 0
    private var dismissals = 0

    private fun show(status: HistoryHandoff.Status) {
        rule.setContent { HistoryHandoffCard(status, onCancel = { cancels++ }, onDismiss = { dismissals++ }) }
    }

    @Test fun cancel_transfer_asks_first() {
        show(HistoryHandoff.Status(HistoryHandoff.Phase.SENDING, done = 40, total = 120, mediaDone = 3, mediaTotal = 9))
        rule.onNodeWithText(s(R.string.handoff_sending_title)).assertIsDisplayed()
        rule.onNodeWithText(s(R.string.handoff_both_fmt, 40, 120, 3, 9)).assertIsDisplayed()
        rule.onNodeWithText(s(R.string.handoff_keep_open)).assertIsDisplayed()
        rule.onNodeWithText(s(R.string.handoff_cancel)).performClick()
        rule.onNodeWithText(s(R.string.handoff_confirm_keep)).performClick()
        assertEquals(0, cancels)
        rule.onNodeWithText(s(R.string.handoff_cancel)).performClick()
        rule.onNodeWithText(s(R.string.handoff_confirm_stop)).performClick()
        assertEquals(1, cancels)
    }

    @Test fun older_media_keys_count_photos_and_videos() {
        show(HistoryHandoff.Status(HistoryHandoff.Phase.SENDING, mediaDone = 40, mediaTotal = 900))
        rule.onNodeWithText(s(R.string.handoff_media_fmt, 40, 900)).assertIsDisplayed()
    }

    @Test fun a_cancelled_transfer_says_who_stopped_it_and_can_be_dismissed() {
        show(HistoryHandoff.Status(HistoryHandoff.Phase.CANCELLED, cancelledRemotely = true))
        rule.onNodeWithText(s(R.string.handoff_cancelled_title)).assertIsDisplayed()
        rule.onNodeWithText(s(R.string.handoff_cancelled_there)).assertIsDisplayed()
        rule.onNodeWithText(s(R.string.handoff_cancel)).assertDoesNotExist()
        rule.onNodeWithContentDescription(s(R.string.handoff_dismiss)).performClick()
        assertEquals(1, dismissals)
    }
}
