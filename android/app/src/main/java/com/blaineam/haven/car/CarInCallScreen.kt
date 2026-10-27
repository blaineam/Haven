package com.blaineam.haven.car

import android.os.SystemClock
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.CarColor
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Template
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.blaineam.haven.R
import com.blaineam.haven.core.CallManager
import com.blaineam.haven.core.CarCalls
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * "Calling Tracy…" / "On a call with Tracy" with a Hang up button, drawn while a call placed from the
 * car is live. The call UI itself is Haven's own (and, on a head unit that surfaces self-managed
 * calls, the system's) — this screen only tells the driver what is happening and lets them end it.
 * It leaves by itself when the call ends, or when it never started ([CarCalls.phase]).
 */
class CarInCallScreen(carContext: CarContext, private val name: String) : Screen(carContext) {
    private var phase = CarCalls.Phase.CALLING
    private var everActive = false
    private val startedAt = SystemClock.elapsedRealtime()

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                owner.lifecycleScope.launch {
                    snapshotFlow { Triple(CallManager.ringing.value, CallManager.connecting.value, CallManager.inCall.value) }
                        .collect { (ringing, connecting, inCall) -> evaluate(ringing, connecting, inCall) }
                }
                // A call that shows no sign of life at all (Telecom refused, mic denied) must not leave us on "Calling…".
                owner.lifecycleScope.launch {
                    delay(CarCalls.CALL_START_GRACE_MS)
                    evaluate(CallManager.ringing.value, CallManager.connecting.value, CallManager.inCall.value)
                }
            }
        })
    }

    private fun evaluate(ringing: Boolean, connecting: Boolean, inCall: Boolean) {
        if (ringing || connecting || inCall) everActive = true
        val next = CarCalls.phase(ringing, connecting, inCall, everActive, SystemClock.elapsedRealtime() - startedAt)
        if (next == CarCalls.Phase.ENDED) { screenManager.remove(this); return }
        if (next != phase) { phase = next; invalidate() }
    }

    override fun onGetTemplate(): Template {
        val text = carContext.getString(
            if (phase == CarCalls.Phase.ON_CALL) R.string.car_in_call else R.string.car_calling, name,
        )
        val hangUp = Action.Builder()
            .setTitle(carContext.getString(R.string.car_hang_up))
            .setBackgroundColor(CarColor.RED)
            .setOnClickListener { CallManager.hangup() }
            .build()
        return MessageTemplate.Builder(text)
            .setTitle(carContext.getString(R.string.car_calls_title))
            .setHeaderAction(Action.BACK)
            .setIcon(CarAvatars.icon(CallManager.participants.firstOrNull().orEmpty(), name))
            .addAction(hangUp)
            .build()
    }
}
