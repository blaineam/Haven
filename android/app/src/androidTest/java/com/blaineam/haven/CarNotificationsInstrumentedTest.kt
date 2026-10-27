package com.blaineam.haven

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.CarMessaging
import com.blaineam.haven.core.CarNotifications
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.HavenNet
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What Android Auto actually requires of a Haven message notification, checked against the REAL
 * posted notification (not the builder): MessagingStyle, CATEGORY_MESSAGE, a REPLY semantic action
 * with a RemoteInput and a MARK_AS_READ semantic action, neither showing UI; and that firing the
 * posted reply PendingIntent reaches HavenNet.sendDm, and mark-as-read withdraws the notification.
 * A real head unit is not involved (see docs/ANDROID-AUTO.md).
 */
@RunWith(AndroidJUnit4::class)
class CarNotificationsInstrumentedTest {
    private val ctx: Context = ApplicationProvider.getApplicationContext()
    private val nm get() = ctx.getSystemService(NotificationManager::class.java)
    private val peerHex = "ab".repeat(32)
    private lateinit var circleId: String

    @Before fun setUp() {
        // POST_NOTIFICATIONS (API 33+) is a runtime grant; the shell can hand it to the target app.
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("pm grant ${ctx.packageName} android.permission.POST_NOTIFICATIONS").close()
        HavenNet.init(ctx)
        circleId = HavenNet.startDm(Contact(peerHex, "Maya", ""))
    }

    @After fun tearDown() { nm.cancelAll() }

    private fun plan() = CarMessaging.plan(
        CarMessaging.Input(
            circleId = circleId, kind = "dm", locked = false, detail = "full", carEnabled = true,
            title = "Maya",
            messages = listOf(
                CarMessaging.Msg(peerHex, "Maya", "are you driving?", 1_000L),
                CarMessaging.Msg(peerHex, "Maya", "call me when you park", 2_000L),
            ),
        ),
    ) as CarMessaging.Plan.Messaging

    private fun posted(p: CarMessaging.Plan.Messaging): Notification {
        CarNotifications.post(ctx, p, null)
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            nm.activeNotifications.firstOrNull { it.id == p.notificationId }?.let { return it.notification }
            SystemClock.sleep(50)
        }
        error("notification ${p.notificationId} was not posted")
    }

    @Test fun postedNotificationMeetsTheAndroidAutoContract() {
        val n = posted(plan())
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
        assertNotNull("must be MessagingStyle", style)
        assertEquals(listOf("are you driving?", "call me when you park"), style!!.messages.map { it.text.toString() })
        assertEquals("Maya", style.messages.first().person?.name)
        assertEquals(peerHex, style.messages.first().person?.key)
        assertEquals(false, style.isGroupConversation)
        assertEquals(Notification.CATEGORY_MESSAGE, n.category)

        val byType = n.actions.associateBy { it.semanticAction }
        val reply = byType[Notification.Action.SEMANTIC_ACTION_REPLY]
        val read = byType[Notification.Action.SEMANTIC_ACTION_MARK_AS_READ]
        assertNotNull("REPLY semantic action", reply)
        assertNotNull("MARK_AS_READ semantic action", read)
        assertTrue("reply carries a RemoteInput", reply!!.remoteInputs?.any { it.resultKey == CarMessaging.KEY_REPLY_TEXT } == true)
        val compat = (0 until NotificationCompat.getActionCount(n)).map { NotificationCompat.getAction(n, it)!! }
            .associateBy { it.semanticAction }
        assertEquals(false, compat[NotificationCompat.Action.SEMANTIC_ACTION_REPLY]!!.showsUserInterface)
        assertEquals(false, compat[NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ]!!.showsUserInterface)
        assertNotNull(read)
    }

    @Test fun replyFromTheCarReachesTheSendPath() {
        val n = posted(plan())
        val reply = n.actions.first { it.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY }
        val fill = Intent()
        RemoteInput.addResultsToIntent(
            arrayOf(RemoteInput.Builder(CarMessaging.KEY_REPLY_TEXT).build()), fill,
            Bundle().apply { putCharSequence(CarMessaging.KEY_REPLY_TEXT, "parked, calling now") },
        )
        reply.actionIntent.send(ctx, 0, fill)

        val deadline = SystemClock.uptimeMillis() + 15_000
        var seen = false
        while (SystemClock.uptimeMillis() < deadline && !seen) {
            seen = HavenNet.messages(circleId).any { it.isMe && it.body == "parked, calling now" }
            if (!seen) SystemClock.sleep(100)
        }
        assertTrue("the spoken reply must arrive in the thread as my own DM", seen)
        val gone = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < gone && nm.activeNotifications.any { it.id == plan().notificationId }) SystemClock.sleep(50)
        assertTrue("the notification is withdrawn after a send", nm.activeNotifications.none { it.id == plan().notificationId })
    }

    @Test fun markAsReadWithdrawsTheNotification() {
        val n = posted(plan())
        n.actions.first { it.semanticAction == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ }.actionIntent.send()
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SystemClock.uptimeMillis() < deadline && nm.activeNotifications.any { it.id == plan().notificationId }) SystemClock.sleep(50)
        assertTrue(nm.activeNotifications.none { it.id == plan().notificationId })
    }
}
