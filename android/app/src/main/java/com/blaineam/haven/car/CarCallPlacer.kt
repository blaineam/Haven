package com.blaineam.haven.car

import android.Manifest
import android.content.pm.PackageManager
import androidx.car.app.Screen
import androidx.core.content.ContextCompat
import com.blaineam.haven.core.CallManager
import com.blaineam.haven.core.CarCalls

/**
 * What a tap on a contact does: dial immediately through the same path as the in-app Call button and
 * "call Tracy on Haven" ([CallManager.startCall] → Telecom first), then show the in-call screen. The
 * decision ([CarCalls.gate]) is pure and unit-tested; this only applies it.
 */
object CarCallPlacer {
    fun place(screen: Screen, entry: CarCalls.Entry) {
        val ctx = screen.carContext
        val mic = ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        when (CarCalls.gate(CallManager.callInProgress, mic)) {
            CarCalls.Gate.BUSY ->
                // A call is already live: never start a second one — show it (with Hang up) instead.
                screen.screenManager.push(CarInCallScreen(ctx, CallManager.peerName.value.ifBlank { entry.name }))
            CarCalls.Gate.NEEDS_MIC ->
                // Asked ON THE PHONE (a car screen cannot show a permission dialog); dial once it is granted.
                ctx.requestPermissions(listOf(Manifest.permission.RECORD_AUDIO)) { granted, _ ->
                    if (granted.contains(Manifest.permission.RECORD_AUDIO)) dial(screen, entry)
                }
            CarCalls.Gate.DIAL -> dial(screen, entry)
        }
    }

    private fun dial(screen: Screen, entry: CarCalls.Entry) {
        CallManager.startCall(listOf(entry.hex), entry.name)
        screen.screenManager.push(CarInCallScreen(screen.carContext, entry.name))
    }
}
