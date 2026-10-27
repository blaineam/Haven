package com.blaineam.haven.car

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.constraints.ConstraintManager
import androidx.car.app.model.Action
import androidx.car.app.model.CarIcon
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SectionedItemList
import androidx.car.app.model.Tab
import androidx.car.app.model.TabContents
import androidx.car.app.model.TabTemplate
import androidx.car.app.model.Template
import androidx.core.graphics.drawable.IconCompat
import com.blaineam.haven.R
import com.blaineam.haven.core.CarCalls

/**
 * The Haven screen on the head unit: Recents / Contacts tabs (a single two-section list on a host too
 * old for tabs), spinner while the engine boots, a "finish setup on your phone" message before an
 * account exists. A row is a name and an avatar — never message text — and a tap dials
 * ([CarCallPlacer]). The pure decisions live in [CarCalls]; this only builds templates.
 */
class CarCallsScreen(carContext: CarContext) : Screen(carContext) {
    private var snapshot: CarCalls.Snapshot = CarCalls.Snapshot.Loading
    private var activeTab = CarCalls.TAB_RECENTS

    fun show(next: CarCalls.Snapshot) {
        if (next == snapshot) return
        snapshot = next
        invalidate()
    }

    /** The host's per-template item limit; a conservative default if it cannot be read. */
    private fun limit(): Int = runCatching {
        carContext.getCarService(ConstraintManager::class.java).getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
    }.getOrDefault(DEFAULT_LIMIT).coerceAtLeast(1)

    private fun str(id: Int) = carContext.getString(id)

    override fun onGetTemplate(): Template = when (val s = snapshot) {
        CarCalls.Snapshot.Loading ->
            ListTemplate.Builder().setTitle(str(R.string.car_calls_title)).setHeaderAction(Action.APP_ICON).setLoading(true).build()
        CarCalls.Snapshot.NeedsSetup ->
            MessageTemplate.Builder(str(R.string.car_setup_needed)).setTitle(str(R.string.car_calls_title)).setHeaderAction(Action.APP_ICON).build()
        is CarCalls.Snapshot.Ready -> ready(s.people)
    }

    private fun ready(people: List<CarCalls.Person>): Template {
        val max = limit()
        return if (carContext.carAppApiLevel >= CarCalls.TAB_TEMPLATE_API_LEVEL) tabbed(people, max) else sectioned(people, max)
    }

    // ---------------------------------------------------------------------------- tabs

    private fun tabbed(people: List<CarCalls.Person>, max: Int): Template {
        fun icon(res: Int) = CarIcon.Builder(IconCompat.createWithResource(carContext, res)).build()
        val tabs = TabTemplate.Builder(object : TabTemplate.TabCallback {
            override fun onTabSelected(tabContentId: String) {
                activeTab = tabContentId
                invalidate()
            }
        })
            .setHeaderAction(Action.APP_ICON)
            .addTab(Tab.Builder().setTitle(str(R.string.car_tab_recents)).setIcon(icon(R.drawable.ic_car_recents)).setContentId(CarCalls.TAB_RECENTS).build())
            .addTab(Tab.Builder().setTitle(str(R.string.car_tab_contacts)).setIcon(icon(R.drawable.ic_car_contacts)).setContentId(CarCalls.TAB_CONTACTS).build())
        val content = if (activeTab == CarCalls.TAB_CONTACTS) contactsList(people, max) else recentsList(people, max)
        return tabs
            .setTabContents(TabContents.Builder(ListTemplate.Builder().setSingleList(content).build()).build())
            .setActiveTabContentId(if (activeTab == CarCalls.TAB_CONTACTS) CarCalls.TAB_CONTACTS else CarCalls.TAB_RECENTS)
            .build()
    }

    // ---------------------------------------------------------------------------- one list (older hosts)

    private fun sectioned(people: List<CarCalls.Person>, max: Int): Template {
        val recents = CarCalls.recents(people, max / 2)
        val rest = (max - recents.size).coerceAtLeast(1)
        return ListTemplate.Builder()
            .setTitle(str(R.string.car_calls_title))
            .setHeaderAction(Action.APP_ICON)
            .addSectionedList(SectionedItemList.create(list(recents, str(R.string.car_empty_recents)), str(R.string.car_tab_recents)))
            .addSectionedList(SectionedItemList.create(contactsList(people, rest), str(R.string.car_tab_contacts)))
            .build()
    }

    // ---------------------------------------------------------------------------- lists

    private fun recentsList(people: List<CarCalls.Person>, max: Int): ItemList =
        list(CarCalls.recents(people, max), str(R.string.car_empty_recents))

    /** A→Z; when the host's limit cuts the list, the FIRST row is "Search all contacts" so nobody is unreachable. */
    private fun contactsList(people: List<CarCalls.Person>, max: Int): ItemList {
        val truncated = CarCalls.truncated(people, max)
        val rows = CarCalls.contacts(people, if (truncated) max - 1 else max)
        val b = ItemList.Builder().setNoItemsMessage(str(R.string.car_empty_contacts))
        if (truncated) {
            b.addItem(
                Row.Builder()
                    .setTitle(str(R.string.car_search_all))
                    .setOnClickListener { screenManager.push(CarSearchScreen(carContext, people)) }
                    .setBrowsable(true)
                    .build(),
            )
        }
        rows.forEach { b.addItem(row(it)) }
        return b.build()
    }

    private fun list(entries: List<CarCalls.Entry>, empty: String): ItemList =
        ItemList.Builder().setNoItemsMessage(empty).apply { entries.forEach { addItem(row(it)) } }.build()

    private fun row(e: CarCalls.Entry): Row =
        Row.Builder()
            .setTitle(e.name)
            .addText(str(R.string.car_row_subtitle))
            .setImage(CarAvatars.icon(e.hex, e.name), Row.IMAGE_TYPE_LARGE)
            .setOnClickListener { CarCallPlacer.place(this, e) }
            .build()

    private companion object { const val DEFAULT_LIMIT = 6 }
}
