package com.blaineam.haven.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import androidx.compose.runtime.mutableStateOf
import uniffi.haven_ffi.Allowance
import uniffi.haven_ffi.LinkConstraint
import uniffi.haven_ffi.Traffic
import uniffi.haven_ffi.lowDataAllowance
import uniffi.haven_ffi.setLinkConstraint

/**
 * Low data mode: watch the network, tell the core how constrained it is, and answer
 * "may I send this?". Mirrors iOS `LowDataMode.swift`.
 *
 * The POLICY is not here. `haven_p2p::transport::allowance` is the single table both clients ask
 * (`docs/SATELLITE-DESIGN.md` §5); this object only classifies the current network and forwards the
 * result. A policy decision written in Kotlin is a bug — it is how the two platforms drift apart.
 *
 * Detection uses `NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED` and `TRANSPORT_SATELLITE`, both API 36
 * (Android 16). `minSdk` is 29, so every use is behind a version gate and older devices fall back to
 * the metered check, which is the strongest signal they have.
 */
object LowDataMonitor {
    /** What the user asked for, independent of what the network is doing. */
    enum class Preference(val raw: Int) {
        /** Follow the network — on when the OS says the link is constrained. The default. */
        AUTOMATIC(0),
        /** Always save data, even on good Wi-Fi. */
        ALWAYS(1),
        /** Never save data. Honoured except on a satellite bearer, which is not a preference. */
        OFF(2);

        companion object {
            fun of(raw: Int): Preference = entries.firstOrNull { it.raw == raw } ?: AUTOMATIC
        }
    }

    private const val PREFS = "haven.lowdata"
    private const val KEY_PREF = "preference"

    // Named constants from the compileSdk 36 platform, so a future platform renumbering cannot
    // silently point these at the wrong capability. `minSdk` is 29, so every USE is behind an
    // SDK_INT gate — referencing the constant is compile-time only and safe on older devices.
    @Suppress("NewApi")
    private val CAP_NOT_BANDWIDTH_CONSTRAINED = NetworkCapabilities.NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED
    @Suppress("NewApi")
    private val TRANSPORT_SATELLITE = NetworkCapabilities.TRANSPORT_SATELLITE

    private var prefs: android.content.SharedPreferences? = null
    private var cm: ConnectivityManager? = null

    /** What the OS reports for the current network, before the user's preference applies. */
    val detected = mutableStateOf(LinkConstraint.NORMAL)
    /** What is actually in force — what the core is told and what the UI describes. */
    val effective = mutableStateOf(LinkConstraint.NORMAL)

    var preference: Preference = Preference.AUTOMATIC
        set(v) {
            field = v
            prefs?.edit()?.putInt(KEY_PREF, v.raw)?.apply()
            recompute()
        }

    /**
     * Start watching. Idempotent; call from `Application.onCreate` so the first send is classified
     * correctly rather than being treated as unconstrained.
     */
    fun init(ctx: Context) {
        if (cm != null) return
        prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        preference = Preference.of(prefs!!.getInt(KEY_PREF, 0))
        val manager = ctx.getSystemService(ConnectivityManager::class.java) ?: return
        cm = manager

        // A constrained network is only offered to callers that ASK for one — the same opt-in shape
        // Apple uses. Without removing the capability from the request the callback never fires for
        // the network we most need to know about.
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .apply {
                if (Build.VERSION.SDK_INT >= 36) removeCapability(CAP_NOT_BANDWIDTH_CONSTRAINED)
            }
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                apply(classify(caps, manager))
            }

            override fun onLost(network: Network) {
                apply(LinkConstraint.NORMAL)
            }
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= 31) {
                manager.registerBestMatchingNetworkCallback(request, callback, android.os.Handler(ctx.mainLooper))
            } else {
                manager.registerNetworkCallback(request, callback)
            }
        }

        // Seed from whatever is active right now, so nothing sends before the first callback.
        val active = runCatching { manager.getNetworkCapabilities(manager.activeNetwork) }.getOrNull()
        apply(if (active != null) classify(active, manager) else LinkConstraint.NORMAL)
    }

    /**
     * Map capabilities to a constraint level, strongest signal first.
     *
     * A satellite transport is ultra-constrained. A network merely missing
     * `NOT_BANDWIDTH_CONSTRAINED`, or a metered one, is the softer Low profile.
     */
    private fun classify(caps: NetworkCapabilities, manager: ConnectivityManager): LinkConstraint {
        if (Build.VERSION.SDK_INT >= 36) {
            if (runCatching { caps.hasTransport(TRANSPORT_SATELLITE) }.getOrDefault(false)) {
                return LinkConstraint.ULTRA
            }
            val unconstrained =
                runCatching { caps.hasCapability(CAP_NOT_BANDWIDTH_CONSTRAINED) }.getOrDefault(true)
            if (!unconstrained) return LinkConstraint.LOW
        }
        val metered = runCatching { manager.isActiveNetworkMetered }.getOrDefault(false)
        return if (metered) LinkConstraint.LOW else LinkConstraint.NORMAL
    }

    private fun apply(level: LinkConstraint) {
        detected.value = level
        recompute()
    }

    private fun recompute() {
        val d = detected.value
        val resolved = when (preference) {
            Preference.AUTOMATIC -> d
            // "Always on" must never WEAKEN a genuinely ultra-constrained link down to Low.
            Preference.ALWAYS -> if (d == LinkConstraint.ULTRA) LinkConstraint.ULTRA else LinkConstraint.LOW
            // Opting out is honoured — except on satellite, which the OS enforces regardless. Better
            // to stay at ultra and explain than to fail mysteriously.
            Preference.OFF -> if (d == LinkConstraint.ULTRA) LinkConstraint.ULTRA else LinkConstraint.NORMAL
        }
        effective.value = resolved
        runCatching { setLinkConstraint(resolved) }
    }

    /** May this traffic go out right now with no further prompting? */
    fun permits(traffic: Traffic): Boolean =
        runCatching { lowDataAllowance(traffic) }.getOrDefault(Allowance.ALLOW) == Allowance.ALLOW

    /** The full ruling, for call sites that can offer an explicit "send anyway". */
    fun allowance(traffic: Traffic): Allowance =
        runCatching { lowDataAllowance(traffic) }.getOrDefault(Allowance.ALLOW)

    /** True when media must not be fetched without the user tapping this specific item. */
    val mediaNeedsExplicitTap: Boolean
        get() = allowance(Traffic.MEDIA) != Allowance.ALLOW

    /** True when low-data behaviour applies at all. */
    val active: Boolean
        get() = effective.value != LinkConstraint.NORMAL
}
