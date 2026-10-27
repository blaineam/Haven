package com.blaineam.haven.car

import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.constraints.ConstraintManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.blaineam.haven.R
import com.blaineam.haven.core.AppearancePrefs
import com.blaineam.haven.core.CarConversationSource
import com.blaineam.haven.core.CarConversations
import java.util.concurrent.Executors

/**
 * One car connection to "Haven Messages". The head unit can start Haven with the app process COLD, so the
 * screen draws a spinner at once and the conversations are loaded on a background lane (boots the engine,
 * decodes avatars), then pushed back to the main thread. Re-read on every resume, so a conversation the
 * host just marked read (or a reply that was just sent) is reflected when the driver comes back to the list.
 */
class HavenMessagesSession : Session() {
    private val main = Handler(Looper.getMainLooper())
    private val lane = Executors.newSingleThreadExecutor { r -> Thread(r, "haven-car-messages").apply { isDaemon = true } }
    private var screen: CarMessagesScreen? = null

    override fun onCreateScreen(intent: Intent): Screen {
        AppearancePrefs.init(carContext)   // the palette tint for avatars — a cold car launch skips MainActivity
        val s = CarMessagesScreen(carContext)
        screen = s
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) = reload()
            override fun onDestroy(owner: LifecycleOwner) { lane.shutdownNow() }
        })
        reload()
        return s
    }

    private fun reload() {
        if (lane.isShutdown) return
        runCatching {
            lane.execute {
                val snap = load()
                main.post { screen?.show(snap) }
            }
        }
    }

    private fun load(): CarConversations.Snapshot = runCatching {
        val st = CarConversationSource.settings(carContext)
        if (!st.carEnabled) return@runCatching CarConversations.Snapshot.Off
        val threads = CarConversationSource.threads(carContext) ?: return@runCatching CarConversations.Snapshot.NeedsSetup
        val limit = runCatching {
            carContext.getCarService(ConstraintManager::class.java).getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
        }.getOrDefault(CarConversations.MAX_THREADS)
        val rows = CarConversations.rows(threads, st.detail, st.carEnabled, carContext.getString(R.string.car_generic_message), limit)
        rows.forEach { runCatching { CarMessagesList.avatar(it) } }   // decode avatars here, off the main thread
        CarConversations.Snapshot.Ready(rows)
    }.getOrDefault(CarConversations.Snapshot.NeedsSetup)
}
