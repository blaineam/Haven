package com.blaineam.haven.car

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.Header
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import com.blaineam.haven.R
import com.blaineam.haven.core.CarConversations

/**
 * The "Haven Messages" screen: a `ListTemplate` of conversations (spinner while the engine boots, a message
 * when the switch is off or setup is unfinished). What a row may contain is decided by [CarConversations.rows];
 * [CarMessagesList] maps them to `ConversationItem`s.
 */
class CarMessagesScreen(carContext: CarContext) : Screen(carContext) {
    private var snapshot: CarConversations.Snapshot = CarConversations.Snapshot.Loading

    fun show(next: CarConversations.Snapshot) {
        if (next == snapshot) return
        snapshot = next
        invalidate()
    }

    private fun str(id: Int) = carContext.getString(id)

    private fun header() = Header.Builder().setStartHeaderAction(Action.APP_ICON).setTitle(str(R.string.car_messages_title)).build()

    override fun onGetTemplate(): Template = when (val s = snapshot) {
        CarConversations.Snapshot.Loading -> ListTemplate.Builder().setHeader(header()).setLoading(true).build()
        CarConversations.Snapshot.NeedsSetup, CarConversations.Snapshot.Hidden ->
            MessageTemplate.Builder(str(R.string.car_setup_needed)).setHeader(header()).build()
        CarConversations.Snapshot.Off ->
            MessageTemplate.Builder(str(R.string.car_messages_off)).setHeader(header()).build()
        is CarConversations.Snapshot.Ready ->
            ListTemplate.Builder().setHeader(header()).setSingleList(CarMessagesList.list(carContext, s.rows, str(R.string.car_empty_messages))).build()
    }
}
