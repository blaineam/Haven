package com.blaineam.haven.support

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import com.blaineam.haven.BuildConfig
import com.blaineam.haven.R
import java.util.Locale

/**
 * What the person is writing in about. Each kind gets its own guided template,
 * because "email me if you have a problem" reliably produces "it doesn't work"
 * and a guided form reliably produces something reproducible.
 *
 * Android port of MillerKit's Feedback.swift.
 */
enum class FeedbackKind { BUG, FEATURE, QUESTION }

object SupportMail {
    const val SUPPORT_EMAIL = "blaine@wemiller.com"
    const val PORTFOLIO_URL = "https://wemiller.com/apps/"

    private fun appName(context: Context): String = context.getString(R.string.app_name)

    /** Subject line: "Haven — Bug Report" / "Haven — Feature Request" / "Haven — Question". */
    fun subject(context: Context, kind: FeedbackKind): String {
        val suffix = when (kind) {
            FeedbackKind.BUG -> context.getString(R.string.support_subject_bug)
            FeedbackKind.FEATURE -> context.getString(R.string.support_subject_feature)
            FeedbackKind.QUESTION -> context.getString(R.string.support_subject_question)
        }
        return "${appName(context)} — $suffix"
    }

    /** Guided body template plus the diagnostics footer, so a report arrives actionable
     *  instead of needing three rounds of "which version are you on?". */
    fun body(context: Context, kind: FeedbackKind): String {
        val template = when (kind) {
            FeedbackKind.BUG -> context.getString(R.string.support_body_bug, appName(context))
            FeedbackKind.FEATURE -> context.getString(R.string.support_body_feature, appName(context))
            FeedbackKind.QUESTION -> context.getString(R.string.support_body_question, appName(context))
        }
        return template + "\n\n" + diagnosticsFooter(context)
    }

    /** App/OS/device/locale block appended to every support email. */
    fun diagnosticsFooter(context: Context): String = context.getString(
        R.string.support_diag_footer,
        BuildConfig.VERSION_NAME,
        BuildConfig.VERSION_CODE.toString(),
        Build.VERSION.RELEASE ?: "?",
        Build.VERSION.SDK_INT.toString(),
        "${Build.MANUFACTURER} ${Build.MODEL}",
        Locale.getDefault().toLanguageTag(),
    )

    /** Open the user's email app with a pre-filled message. `mailto:` via ACTION_SENDTO
     *  targets real mail apps only (no share-sheet noise), matching MillerKit's mailto URL. */
    fun compose(context: Context, subject: String, body: String) {
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:")
            putExtra(Intent.EXTRA_EMAIL, arrayOf(SUPPORT_EMAIL))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
        }
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, context.getString(R.string.support_no_email_app), Toast.LENGTH_SHORT).show()
        }
    }

    fun composeFeedback(context: Context, kind: FeedbackKind) =
        compose(context, subject(context, kind), body(context, kind))

    /** Open the developer's portfolio page in the browser. */
    fun openOtherApps(context: Context) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PORTFOLIO_URL))) }
    }
}
