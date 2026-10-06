package com.blaineam.haven.ui

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import androidx.compose.runtime.mutableStateOf
import com.blaineam.haven.core.CallManager

/**
 * Picture-in-picture for a live call: leave Haven (Home, a notification, another app) with a call up
 * and the call keeps showing in a small floating window instead of vanishing behind the launcher.
 *
 * Lifecycle (MainActivity drives it):
 *  - A call that is connecting or connected makes the activity PiP-ELIGIBLE. On API 31+ that is
 *    `setAutoEnterEnabled(true)`, so the system animates straight from the call into PiP on Home;
 *    below 31 `onUserLeaveHint` enters it by hand. A ringing call never auto-enters — answering or
 *    declining must not happen in a window you didn't open.
 *  - In PiP the call surface is the remote video ONLY ([CallOverlay] → `PipCall`): no controls, no
 *    self-preview, nothing tappable. PiP windows are too small for controls and Android forwards no
 *    touches to the content anyway — the system's own expand/close buttons are the controls.
 *  - Expanding the window returns to the full call screen (un-minimizes it). Closing the window is
 *    the same as leaving the app today: the call carries on under its foreground service.
 *  - The call ending while in PiP closes the window ([onEligibilityChanged]) — a PiP window of the
 *    feed is not a thing anyone asked for.
 *
 * Apple has no call PiP yet; Android's is the platform-standard behaviour Play recommends.
 */
object CallPip {
    /** True while the activity is in picture-in-picture mode (set from onPictureInPictureModeChanged). */
    val active = mutableStateOf(false)

    /** Whether the device offers PiP at all (some Go / automotive builds don't, and users can turn it
     *  off per app — in which case enter… throws, so every call site also runCatching-guards). */
    fun supported(activity: Activity): Boolean =
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** A call worth floating: connecting or connected, and not merely ringing. */
    fun eligible(): Boolean {
        val live = CallManager.inCall.value || CallManager.connecting.value
        val onlyRinging = CallManager.ringing.value && !CallManager.inCall.value
        return live && !onlyRinging
    }

    /** A peer's screen share is landscape content; a face is portrait. */
    fun showingScreenShare(): Boolean = CallManager.remoteScreen.values.any { it != null }

    /** The PiP window's shape: 16:9 for a shared screen, 9:16 for a phone camera (the common case —
     *  both ends hold their phones upright, and SCALE_ASPECT_FILL crops anything else to it). */
    fun aspect(screenShare: Boolean): Rational = if (screenShare) Rational(16, 9) else Rational(9, 16)

    fun params(eligible: Boolean, screenShare: Boolean): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(aspect(screenShare))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(eligible)
            // Video content: let the system resize it smoothly rather than cross-fading.
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    /** Re-publish the params whenever eligibility or the content's shape changes; close the window
     *  if the call just ended while floating. */
    fun onEligibilityChanged(activity: Activity, eligible: Boolean, screenShare: Boolean) {
        if (!supported(activity)) return
        runCatching { activity.setPictureInPictureParams(params(eligible, screenShare)) }
        if (!eligible && active.value) {
            // Ending the call (hang up here or on their side) dismisses the PiP window; the task goes
            // to the background exactly as if the user had closed it.
            val moved = activity.moveTaskToBack(false)
            android.util.Log.i("CallPip", "call ended in PiP — moveTaskToBack=$moved")
        }
    }

    /** API < 31: auto-enter isn't available, so the Home press (onUserLeaveHint) enters by hand. */
    fun enterOnLeaveHint(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return   // setAutoEnterEnabled handles it
        if (!supported(activity) || !eligible()) return
        runCatching { activity.enterPictureInPictureMode(params(true, showingScreenShare())) }
    }
}
