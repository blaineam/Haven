package com.blaineam.haven.car

import android.content.Context
import androidx.car.app.validation.HostValidator

/**
 * Which car hosts may bind to [HavenCarAppService].
 *
 * Release builds accept only Android Auto's and the Automotive OS templates host's signing
 * certificates — the library's own `hosts_allowlist_sample`, which is Google's published list. A
 * DEBUG build accepts any host so the Desktop Head Unit (and a sideloaded build) can connect; that
 * leniency must never ship, so it is keyed off the debuggable flag and covered by a test.
 */
object CarHosts {
    /** Allow every host? Only for a debuggable build. */
    fun allowAnyHost(debuggable: Boolean): Boolean = debuggable

    fun validator(context: Context, debuggable: Boolean): HostValidator =
        if (allowAnyHost(debuggable)) HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        else HostValidator.Builder(context.applicationContext)
            .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
            .build()
}
