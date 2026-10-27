package com.blaineam.haven.car

import android.content.Context
import androidx.car.app.CarContext
import androidx.car.app.messaging.model.CarMessage
import androidx.car.app.messaging.model.ConversationCallback
import androidx.car.app.messaging.model.ConversationItem
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarText
import androidx.car.app.model.ItemList
import androidx.core.app.Person
import com.blaineam.haven.R
import com.blaineam.haven.core.CarConversations
import com.blaineam.haven.core.CarHandlers
import com.blaineam.haven.core.CarMessaging
import com.blaineam.haven.core.EngineBoot

/**
 * The Messages tab's conversation list: one `ConversationItem` per DM thread. What may be shown is decided
 * by [CarConversations.rows] (privacy level, lock, switch); this only maps rows to the Car App Library's
 * messaging models. The HOST reads unread messages aloud on a tap, hides message text while the car moves,
 * and routes a spoken reply to [HavenConversationCallback] — the same [CarMessaging.execute] path as the
 * notification actions, so the lock and the switch are re-checked at the moment of sending.
 *
 * `ConversationItem` ids are the conversation's circle id, which is also its sharing-shortcut id
 * ([com.blaineam.haven.core.ShareShortcuts]) — the library requires them to match.
 */
object CarMessagesList {
    fun list(carContext: CarContext, rows: List<CarConversations.Row>, empty: String): ItemList {
        val me = Person.Builder().setName(carContext.getString(R.string.you_default_name)).setKey("self").build()
        val b = ItemList.Builder().setNoItemsMessage(empty)
        rows.forEach { b.addItem(item(carContext, me, it)) }
        return b.build()
    }

    private fun item(ctx: Context, me: Person, row: CarConversations.Row): ConversationItem {
        val persons = HashMap<String, Person>()
        fun person(m: CarConversations.Msg): Person = if (m.fromMe) me else persons.getOrPut(m.senderKey) {
            Person.Builder().setName(m.senderName.ifBlank { row.title }).setKey(m.senderKey).build()
        }
        val messages = row.messages.map { m ->
            CarMessage.Builder()
                .setSender(person(m))
                .setBody(CarText.create(m.text))
                .setReceivedTimeEpochMillis(m.timestampMs)
                .setRead(m.read)
                .build()
        }
        return ConversationItem.Builder(row.circleId, CarText.create(row.title), me, messages, HavenConversationCallback(ctx.applicationContext, row.circleId))
            .setGroupConversation(row.isGroup)
            .setIcon(avatar(row))
            .build()
    }

    fun avatar(row: CarConversations.Row): CarIcon = CarAvatars.icon(row.partnerHex ?: row.circleId, row.title)
}

/** A spoken reply / mark-as-read from the head unit's conversation screen. */
class HavenConversationCallback(private val app: Context, private val circleId: String) : ConversationCallback {
    override fun onMarkAsRead() {
        EngineBoot.background { CarMessaging.execute(CarMessaging.ACTION_MARK_READ, circleId, null, CarHandlers.real(app)) }
    }

    override fun onTextReply(replyText: String) {
        EngineBoot.background { CarMessaging.execute(CarMessaging.ACTION_REPLY, circleId, replyText, CarHandlers.real(app)) }
    }
}
