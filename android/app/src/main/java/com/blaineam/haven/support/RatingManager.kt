package com.blaineam.haven.support

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import com.blaineam.haven.BuildConfig
import com.google.android.play.core.review.ReviewManagerFactory
import java.util.concurrent.TimeUnit

/**
 * Decides *whether* to ask for a Play Store review — Android port of MillerKit's
 * RatingManager. Three rules, all learned the hard way:
 *
 * 1. **Attempts have a cooldown, they are not one-shot.** The In-App Review API may
 *    silently show nothing; burning a forever-flag on a suppressed call means never
 *    asking again for the life of the install.
 * 2. **Success paths only.** Never after an error, never on first launch. Here the
 *    only significant action is the user successfully publishing a post.
 * 3. **Earned, not timed.** Launches and days are necessary but not sufficient; the
 *    user must have completed things the app is *for*.
 */
object RatingManager {

    private const val PREFS = "haven.rating"
    private const val KEY_LAUNCHES = "rating.launches"
    private const val KEY_FIRST_LAUNCH = "rating.firstLaunchDate"
    private const val KEY_ACTIONS = "rating.significantActions"
    private const val KEY_LAST_ATTEMPT = "rating.lastAttemptDate"
    private const val KEY_ATTEMPTS = "rating.attemptCount"
    private const val KEY_LAST_VERSION = "rating.lastPromptedVersion"

    // Same gates as MillerKit's Gates.utility.
    private const val MINIMUM_LAUNCHES = 10
    private const val MINIMUM_DAYS = 7
    private const val MINIMUM_SIGNIFICANT_ACTIONS = 3
    private val COOLDOWN_MS = TimeUnit.DAYS.toMillis(120)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ── Recording ──

    /** Call once per cold start (Application.onCreate). */
    fun recordLaunch(context: Context) {
        val p = prefs(context)
        val e = p.edit()
        if (!p.contains(KEY_FIRST_LAUNCH)) e.putLong(KEY_FIRST_LAUNCH, System.currentTimeMillis())
        e.putInt(KEY_LAUNCHES, p.getInt(KEY_LAUNCHES, 0) + 1)
        e.apply()
    }

    /** Call when the user *completes* something the app exists to do. For Haven that is
     *  exactly one thing: a post successfully published. Not taps, not screen views, and
     *  never anything that failed. */
    fun recordSignificantAction(context: Context, count: Int = 1) {
        val p = prefs(context)
        p.edit().putInt(KEY_ACTIONS, p.getInt(KEY_ACTIONS, 0) + count).apply()
    }

    // ── Deciding ──

    fun launches(context: Context): Int = prefs(context).getInt(KEY_LAUNCHES, 0)
    fun significantActions(context: Context): Int = prefs(context).getInt(KEY_ACTIONS, 0)
    fun attemptCount(context: Context): Int = prefs(context).getInt(KEY_ATTEMPTS, 0)

    private fun daysSinceFirstLaunch(context: Context): Long {
        val first = prefs(context).getLong(KEY_FIRST_LAUNCH, 0L)
        if (first == 0L) return 0
        return TimeUnit.MILLISECONDS.toDays(System.currentTimeMillis() - first)
    }

    /** Every gate, evaluated. Read-only — safe to call from a debug screen. */
    fun shouldRequestReview(context: Context): Boolean {
        val p = prefs(context)
        if (launches(context) < MINIMUM_LAUNCHES) return false
        if (daysSinceFirstLaunch(context) < MINIMUM_DAYS) return false
        if (significantActions(context) < MINIMUM_SIGNIFICANT_ACTIONS) return false
        // Never twice for the same version: a second ask on the same build is just nagging.
        if (p.getString(KEY_LAST_VERSION, null) == BuildConfig.VERSION_NAME) return false
        val last = p.getLong(KEY_LAST_ATTEMPT, 0L)
        if (last != 0L && System.currentTimeMillis() - last < COOLDOWN_MS) return false
        return true
    }

    /** Records that an attempt was made — starts the cooldown. Call only alongside
     *  actually launching the review flow: the API never says whether a sheet showed. */
    fun recordAttempt(context: Context) {
        val p = prefs(context)
        p.edit()
            .putLong(KEY_LAST_ATTEMPT, System.currentTimeMillis())
            .putInt(KEY_ATTEMPTS, p.getInt(KEY_ATTEMPTS, 0) + 1)
            .putString(KEY_LAST_VERSION, BuildConfig.VERSION_NAME)
            .apply()
    }

    /** Call right after a publish succeeded: when every gate is met, burn one attempt
     *  and ask Play for the in-app review sheet (which it may or may not show).
     *  Accepts any Context and unwraps to the hosting Activity (Compose's LocalContext
     *  is often a ContextWrapper, not the Activity itself). */
    fun maybeAskAfterPublish(context: Context) {
        val activity = generateSequence(context) { (it as? ContextWrapper)?.baseContext }
            .filterIsInstance<Activity>().firstOrNull() ?: return
        if (!shouldRequestReview(activity)) return
        recordAttempt(activity)
        val manager = ReviewManagerFactory.create(activity)
        manager.requestReviewFlow().addOnCompleteListener { task ->
            if (task.isSuccessful && !activity.isFinishing && !activity.isDestroyed) {
                manager.launchReviewFlow(activity, task.result)
            }
        }
    }
}
