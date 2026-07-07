package com.blaineam.haven.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

// Decentralized moderation (docs/MODERATION.md, parity with apple/HavenApp/ReportUI.swift).
// Haven circles have no owner and the developer holds no keys, so moderation is the members':
// a report is sealed to the WHOLE circle and every member acts with the power they already hold.
// The only thing that ever leaves the circle is a content-free ledger entry — identity vs
// identity, action, offense category. No PII, no content.

/**
 * Fire-and-forget, content-free entries to the developer ledger on the push Worker. Node ids are
 * opaque public keys — the ledger records WHO acted against WHOM and WHY (category), never what
 * was said or shown. It makes abuse patterns (many reporters × one identity) visible without a
 * single byte of content.
 */
object ModerationLedger {
    const val RELAY = "https://haven-push.blaineams3.workers.dev"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun record(action: String, subject: String, reason: String) {
        if (subject.isEmpty()) return
        val body = JSONObject()
            .put("actor", HavenNet.engine.myNodeHex())
            .put("subject", subject)
            .put("action", action)
            .put("reason", reason)
            .toString()
        scope.launch {
            runCatching {   // fire and forget — never blocks moderation
                val c = (URL("$RELAY/flag").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"; doOutput = true; connectTimeout = 8000; readTimeout = 8000
                    setRequestProperty("Content-Type", "application/json")
                }
                c.outputStream.use { it.write(body.toByteArray()) }
                c.responseCode
                c.disconnect()
            }
        }
    }
}

/** The offense categories a reporter picks from — wording matches Apple exactly so categories
 *  aggregate in the ledger. The category travels BOTH ways: sealed to the circle (so members can
 *  judge) and to the ledger (so patterns are visible) — the free-text comment goes ONLY to the
 *  circle. */
val REPORT_REASONS = listOf(
    "Harassment or bullying",
    "Nudity or sexual content",
    "Violence or dangerous acts",
    "Spam or scam",
    "Something else",
)
