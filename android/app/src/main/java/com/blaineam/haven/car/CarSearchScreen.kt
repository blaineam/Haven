package com.blaineam.haven.car

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.constraints.ConstraintManager
import androidx.car.app.model.Action
import androidx.car.app.model.ItemList
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template
import com.blaineam.haven.R
import com.blaineam.haven.core.CarCalls

/**
 * Typed / spoken search over the callable contacts, for when the host cuts the A→Z list. Uses the same
 * tiered matcher as "call Tracy on Haven" ([CarCalls.search]); a tap dials, like every other row.
 */
class CarSearchScreen(carContext: CarContext, private val people: List<CarCalls.Person>) : Screen(carContext) {
    private var query = ""

    private fun limit(): Int = runCatching {
        carContext.getCarService(ConstraintManager::class.java).getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
    }.getOrDefault(6).coerceAtLeast(1)

    override fun onGetTemplate(): Template {
        val rows = CarCalls.search(people, query, limit())
        val items = ItemList.Builder().setNoItemsMessage(carContext.getString(R.string.car_empty_contacts))
        rows.forEach { e ->
            items.addItem(
                Row.Builder()
                    .setTitle(e.name)
                    .addText(carContext.getString(R.string.car_row_subtitle))
                    .setImage(CarAvatars.icon(e.hex, e.name), Row.IMAGE_TYPE_LARGE)
                    .setOnClickListener { CarCallPlacer.place(this, e) }
                    .build(),
            )
        }
        return SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) { query = searchText; invalidate() }
            override fun onSearchSubmitted(searchTerm: String) { query = searchTerm; invalidate() }
        })
            .setHeaderAction(Action.BACK)
            .setSearchHint(carContext.getString(R.string.car_search_hint))
            .setShowKeyboardByDefault(false)
            .setItemList(items.build())
            .build()
    }
}
