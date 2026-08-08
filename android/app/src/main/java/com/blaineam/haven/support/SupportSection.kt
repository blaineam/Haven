package com.blaineam.haven.support

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.ui.HavenTheme
import com.blaineam.haven.ui.havenCard
import java.util.Locale

/**
 * "This app reads badly in my language — let me help fix it."
 *
 * Android port of MillerKit's TranslationFeedback.swift: shown only when the app is
 * actually displaying a non-English localization, and gated on being able to hold the
 * conversation in English — a translation fix is a back-and-forth, not a drive-by.
 */
object TranslationFeedback {
    /** Languages Haven actually ships translations for (see res/values-*). */
    private val supported = setOf("ja", "de", "es", "ko", "pt", "it")

    /** The locale whose translation the app is displaying right now, or null when the
     *  app is effectively running in English (nothing to report). */
    fun activeTranslation(context: Context): Locale? {
        val locales = context.resources.configuration.locales
        for (i in 0 until locales.size()) {
            val l = locales[i]
            if (l.language == "en") return null      // English won — the row is noise
            if (l.language in supported) return l
        }
        return null
    }

    /** Native name of the running localization — asking in terms of "Deutsch" reads
     *  far better than "de". */
    fun languageName(locale: Locale): String =
        locale.getDisplayLanguage(locale).replaceFirstChar { it.uppercase(locale) }

    fun composeEmail(
        context: Context,
        locale: Locale,
        screen: String,
        currentWording: String,
        suggestedWording: String,
        notes: String,
    ) {
        val code = locale.toLanguageTag()
        val language = languageName(locale)
        val appName = context.getString(R.string.app_name)
        val subject = "$appName — " + context.getString(R.string.tf_subject, code)

        var body = context.getString(R.string.tf_email_intro, language, appName)
        body += "\n"
        body += context.getString(R.string.tf_label_where) + "\n$screen\n\n"
        body += context.getString(R.string.tf_label_current) + "\n$currentWording\n\n"
        body += context.getString(R.string.tf_label_suggested) + "\n$suggestedWording\n\n"
        if (notes.isNotBlank()) {
            body += context.getString(R.string.tf_label_notes) + "\n$notes\n\n"
        }
        body += context.getString(R.string.tf_confirm_line)
        body += "\n\n" + SupportMail.diagnosticsFooter(context)
        body += "\n" + context.getString(R.string.tf_label_displaying) + " $language ($code)"

        SupportMail.compose(context, subject, body)
    }
}

/**
 * Drop-in support block for the Settings screen — the Android take on MillerKit's
 * SupportSection + LoveThisAppSection. One import, one call, identical wording in
 * every app, which is the point.
 */
@Composable
fun SupportSettingsSection() {
    val context = LocalContext.current
    val activeLocale = remember { TranslationFeedback.activeTranslation(context) }
    var showTranslationForm by remember { mutableStateOf(false) }

    // Back inside the translation form returns to the support rows, not out of Settings.
    BackHandler(enabled = showTranslationForm) { showTranslationForm = false }

    if (showTranslationForm && activeLocale != null) {
        TranslationFeedbackForm(activeLocale) { showTranslationForm = false }
        return
    }

    // ── Feedback & Support ──
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.support_header), color = HavenTheme.textPrimary,
            fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(8.dp))
        SupportRow(Icons.Default.BugReport, stringResource(R.string.support_report_issue)) {
            SupportMail.composeFeedback(context, FeedbackKind.BUG)
        }
        SupportRow(Icons.Default.Lightbulb, stringResource(R.string.support_suggest_feature)) {
            SupportMail.composeFeedback(context, FeedbackKind.FEATURE)
        }
        SupportRow(Icons.Default.HelpOutline, stringResource(R.string.support_ask_question)) {
            SupportMail.composeFeedback(context, FeedbackKind.QUESTION)
        }
        if (activeLocale != null) {
            SupportRow(Icons.Default.Translate,
                stringResource(R.string.tf_row_title, TranslationFeedback.languageName(activeLocale))) {
                showTranslationForm = true
            }
        }
        Spacer(Modifier.height(8.dp))
        // The ask, stated plainly: a solo developer does not already know the app is broken.
        Text(stringResource(R.string.support_footer), color = HavenTheme.textSecondary, fontSize = 12.sp)
    }

    Spacer(Modifier.height(16.dp))

    // ── Enjoying Haven? ── (separate card on purpose: a rating ask sitting next to a
    // bug-report button reads as asking a favour from someone who came to complain)
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.support_enjoying_header), color = HavenTheme.textPrimary,
            fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(8.dp))
        SupportRow(Icons.Default.Star, stringResource(R.string.support_rate),
            subtitle = stringResource(R.string.support_rate_subtitle), iconTint = Color(0xFFFACC15)) {
            openPlayListing(context)
        }
        SupportRow(Icons.Default.GridView, stringResource(R.string.support_other_apps),
            subtitle = stringResource(R.string.support_other_apps_subtitle)) {
            SupportMail.openOtherApps(context)
        }
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.support_love_footer), color = HavenTheme.textSecondary, fontSize = 12.sp)
    }
}

private fun openPlayListing(context: Context) {
    val id = context.packageName
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$id"))
    val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$id"))
    runCatching { context.startActivity(market) }
        .onFailure { runCatching { context.startActivity(web) } }
}

@Composable
private fun SupportRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    iconTint: Color = HavenTheme.pink,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clickable { onClick() }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = iconTint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = HavenTheme.textPrimary, fontSize = 15.sp)
            if (subtitle != null) {
                Text(subtitle, color = HavenTheme.textSecondary, fontSize = 12.sp)
            }
        }
        Icon(Icons.Default.Email, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(16.dp))
    }
}

/**
 * Gate, then form (MillerKit TranslationFeedbackView). The gate is not a hoop for its
 * own sake: it sets the expectation that this is the start of a conversation, which is
 * what makes the difference between a report you can act on and one you can't.
 */
@Composable
private fun TranslationFeedbackForm(locale: Locale, onClose: () -> Unit) {
    val context = LocalContext.current
    val language = remember(locale) { TranslationFeedback.languageName(locale) }

    var readsEnglish by remember { mutableStateOf(false) }
    var willIterate by remember { mutableStateOf(false) }
    var screen by remember { mutableStateOf("") }
    var currentWording by remember { mutableStateOf("") }
    var suggestedWording by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }

    val prerequisitesMet = readsEnglish && willIterate
    val canSend = prerequisitesMet && screen.isNotBlank() && suggestedWording.isNotBlank()

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.tf_row_title, language), color = HavenTheme.textPrimary,
                fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onClose) {
                Text(stringResource(R.string.common_close), color = HavenTheme.pink, fontSize = 13.sp)
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.tf_intro, language), color = HavenTheme.textSecondary, fontSize = 12.sp)

        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.tf_before_start), color = HavenTheme.textPrimary,
            fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        GateSwitch(stringResource(R.string.tf_gate_english), readsEnglish) { readsEnglish = it }
        GateSwitch(stringResource(R.string.tf_gate_iterate), willIterate) { willIterate = it }
        Spacer(Modifier.height(4.dp))
        // Say plainly why the gate exists, so it doesn't read as gatekeeping.
        Text(stringResource(R.string.tf_gate_footer), color = HavenTheme.textSecondary, fontSize = 12.sp)

        if (prerequisitesMet) {
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.tf_what_needs_fixing), color = HavenTheme.textPrimary,
                fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Spacer(Modifier.height(8.dp))
            TfField(screen, stringResource(R.string.tf_where_placeholder)) { screen = it }
            TfField(currentWording, stringResource(R.string.tf_current_placeholder)) { currentWording = it }
            TfField(suggestedWording, stringResource(R.string.tf_suggested_placeholder, language)) { suggestedWording = it }
            TfField(notes, stringResource(R.string.tf_notes_placeholder)) { notes = it }

            Spacer(Modifier.height(8.dp))
            TextButton(
                onClick = {
                    TranslationFeedback.composeEmail(context, locale, screen, currentWording, suggestedWording, notes)
                    onClose()
                },
                enabled = canSend,
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, null,
                    tint = if (canSend) HavenTheme.pink else HavenTheme.textSecondary,
                    modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(8.dp))
                Text(stringResource(R.string.tf_send),
                    color = if (canSend) HavenTheme.pink else HavenTheme.textSecondary, fontSize = 14.sp)
            }
            // Nothing leaves the device until the user hits send in their own mail app.
            Text(stringResource(R.string.tf_send_footer), color = HavenTheme.textSecondary, fontSize = 12.sp)
        }
    }
}

@Composable
private fun GateSwitch(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink))
    }
}

@Composable
private fun TfField(value: String, placeholder: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, color = HavenTheme.textSecondary, fontSize = 13.sp) },
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        shape = RoundedCornerShape(10.dp),
        keyboardOptions = KeyboardOptions.Default,
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = HavenTheme.textPrimary,
            unfocusedTextColor = HavenTheme.textPrimary,
            focusedBorderColor = HavenTheme.pink,
            unfocusedBorderColor = HavenTheme.textSecondary,
            cursorColor = HavenTheme.pink,
        ),
    )
}
