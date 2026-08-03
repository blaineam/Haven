package com.blaineam.haven.core

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * Per-circle Face/fingerprint lock (parity with the iOS biometric circle lock). A locked circle's
 * feed is hidden until the user authenticates; unlock lasts for the session (re-locks on relaunch).
 */
object CircleLock {
    private lateinit var prefs: android.content.SharedPreferences
    private val unlocked = HashSet<String>()           // session-unlocked circle ids
    val version = mutableStateOf(0)                     // bump to recompose gated screens

    fun init(context: Context) {
        if (this::prefs.isInitialized) return
        prefs = context.applicationContext.getSharedPreferences("haven.locks", Context.MODE_PRIVATE)
    }

    private val ready get() = this::prefs.isInitialized
    private fun locked(): MutableSet<String> =
        if (!ready) mutableSetOf() else prefs.getStringSet("locked", emptySet())!!.toMutableSet()

    fun isLocked(circleId: String): Boolean = ready && locked().contains(circleId)
    fun needsUnlock(circleId: String): Boolean = isLocked(circleId) && !unlocked.contains(circleId)

    fun setLocked(context: Context, circleId: String, on: Boolean) {
        if (!ready) return
        val s = locked()
        if (on) s.add(circleId) else { s.remove(circleId); unlocked.add(circleId) }
        prefs.edit().putStringSet("locked", s).apply()
        version.value++
        // A circle that just became locked must drop out of the share sheet's Direct Share row for
        // the same reason it drops out of search: a locked circle hides that it exists, which a tile
        // bearing its name in every other app's share sheet would not.
        if (on) ShareShortcuts.remove(context, circleId) else ShareShortcuts.refresh(context)
    }

    fun markUnlocked(circleId: String) { unlocked.add(circleId); version.value++ }

    /** True if the device can do biometric (or device-credential) auth. */
    fun canAuth(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        ) == BiometricManager.BIOMETRIC_SUCCESS

    /** Prompt for biometric/device-credential auth; calls [onSuccess] when the user passes. */
    fun authenticate(activity: FragmentActivity, circleId: String, onSuccess: () -> Unit) {
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    markUnlocked(circleId); onSuccess()
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock this circle")
            .setSubtitle("Haven locked this circle on this device")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            .build()
        runCatching { prompt.authenticate(info) }
    }

    fun reset() {
        unlocked.clear()
        if (this::prefs.isInitialized) prefs.edit().clear().commit()
        version.value++
    }
}
