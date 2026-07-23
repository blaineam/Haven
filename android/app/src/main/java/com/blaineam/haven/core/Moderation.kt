package com.blaineam.haven.core

import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import uniffi.haven_ffi.Account
import java.net.HttpURLConnection
import java.net.URL

// Decentralized moderation (docs/MODERATION.md, parity with apple/HavenApp/ReportUI.swift).
// Haven circles have no owner and the developer holds no keys, so moderation is the members':
// a report is sealed to the WHOLE circle and every member acts with the power they already hold.
// The only thing that ever leaves the circle is a content-free ledger entry — identity vs
// identity, action, offense category. No PII, no content.

/** The blind push relay (a Cloudflare Worker) — one shared constant for BOTH the moderation
 *  ledger and the notify/wake push leg (parity with Apple `PushManager.defaultRelay`). The
 *  worker only ever sees node ids + ciphertext sealed to the recipient. */
const val PUSH_RELAY = "https://haven-push.blaineams3.workers.dev"

/**
 * Fire-and-forget, content-free entries to the developer ledger on the push Worker. Node ids are
 * opaque public keys — the ledger records only that an identity WAS REPORTED and for which
 * category, never what was said or shown.
 *
 * Only an explicit report comes here (audit F1). **Blocking never touches the network**: it is a
 * private, local decision to stop seeing someone, and it stays on the device.
 */
object ModerationLedger {
    const val RELAY = PUSH_RELAY
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Signed with the identity key (audit F1): the Terms attach real consequences to a ledger row,
     *  so an unsigned POST must not be able to plant one. The signature binds subject + action +
     *  category, so a captured flag can't be re-aimed at someone else. */
    fun report(account: Account, subject: String, reason: String) {
        if (subject.isEmpty()) return
        val category = reason.take(64)
        val ts = System.currentTimeMillis() / 1000
        val sig = account.signPushRegistration("flag-v1:$subject:report:$category", ts.toULong())
        val body = JSONObject()
            .put("actor", account.nodeIdHex())
            .put("subject", subject)
            .put("action", "report")
            .put("reason", category)
            .put("ts", ts)
            .put("sig", Base64.encodeToString(sig, Base64.NO_WRAP))
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
