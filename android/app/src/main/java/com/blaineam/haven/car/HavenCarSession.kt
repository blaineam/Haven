package com.blaineam.haven.car

import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.blaineam.haven.core.AppearancePrefs
import com.blaineam.haven.core.CarCallSource
import com.blaineam.haven.core.CarCalls
import com.blaineam.haven.core.CarConversationSource
import com.blaineam.haven.core.CarConversations
import java.util.concurrent.Executors

/**
 * One car connection. The head unit can start Haven with the app process COLD, so nothing here assumes
 * the engine is up: the screen draws a spinner at once and the contact list is loaded on a background
 * lane ([CarCallSource.people] boots the engine), then pushed back to the main thread.
 */
class HavenCarSession : Session() {
    private val main = Handler(Looper.getMainLooper())
    private val lane = Executors.newSingleThreadExecutor { r -> Thread(r, "haven-car-calls").apply { isDaemon = true } }
    private var screen: CarCallsScreen? = null

    override fun onCreateScreen(intent: Intent): Screen {
        AppearancePrefs.init(carContext)   // the palette tint for avatars — a cold car launch skips MainActivity
        val s = CarCallsScreen(carContext)
        screen = s
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) = reload()
            override fun onDestroy(owner: LifecycleOwner) { lane.shutdownNow() }
        })
        reload()
        return s
    }

    /** The Messages tab: hidden on a host without conversation items or while the switch is off. */
    private fun loadConversations(): CarConversations.Snapshot = runCatching {
        if (!CarConversations.TAB_IN_CALLS_SERVICE) return@runCatching CarConversations.Snapshot.Hidden   // Messages are their own entry
        val st = CarConversationSource.settings(carContext)
        if (!CarConversations.tabVisible(carContext.carAppApiLevel, st.carEnabled)) return@runCatching CarConversations.Snapshot.Hidden
        val threads = CarConversationSource.threads(carContext) ?: return@runCatching CarConversations.Snapshot.Hidden
        val limit = runCatching {
            carContext.getCarService(androidx.car.app.constraints.ConstraintManager::class.java)
                .getContentLimit(androidx.car.app.constraints.ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
        }.getOrDefault(CarConversations.MAX_THREADS)
        val rows = CarConversations.rows(threads, st.detail, st.carEnabled, carContext.getString(com.blaineam.haven.R.string.car_generic_message), limit)
        rows.forEach { runCatching { CarMessagesList.avatar(it) } }   // decode avatars here, off the main thread
        CarConversations.Snapshot.Ready(rows)
    }.getOrDefault(CarConversations.Snapshot.Hidden)

    /** Re-read the contact state (cheap after the first boot); the screen redraws when it lands. */
    private fun reload() {
        if (lane.isShutdown) return
        runCatching {
            lane.execute {
                val loaded = runCatching { CarCallSource.people(carContext) }
                // Decode the avatars here, off the main thread, so drawing the list never touches disk.
                loaded.getOrNull()?.let { CarAvatars.prefetch(CarCalls.contacts(it, CarCalls.MAX_ROWS)) }
                val convo = loadConversations()
                main.post {
                    val s = screen ?: return@post
                    s.showMessages(convo)
                    val list = loaded.getOrNull()
                    when {
                        loaded.isFailure -> s.show(CarCalls.Snapshot.NeedsSetup)
                        list == null -> s.show(CarCalls.Snapshot.NeedsSetup)
                        else -> s.show(CarCalls.Snapshot.Ready(list))
                    }
                }
            }
        }
    }
}
