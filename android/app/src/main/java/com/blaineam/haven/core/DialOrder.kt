package com.blaineam.haven.core

/**
 * The dial set for one account, best-first (iOS `DialOrder` parity): invite-link hints (the ids a
 * brand-new friend actually answers on), then roster device ids, then the bare ACCOUNT id.
 *
 * The account id is DROPPED when the account came with invite hints: only per-device builds mint
 * hints, and under per-device transport the account id resolves to no endpoint — dialing it bought
 * a guaranteed connect timeout plus a dial-gate strike on every send to a new friend. With a roster
 * but no hints it stays, LAST (the core keeps it in `device_node_ids_for` on purpose: dropping it
 * once stranded pre-multidevice peers). Sends are concurrent, so a dead id no longer delays the rest.
 */
object DialOrder {
    fun targets(account: String, resolved: List<String>, hints: List<String>): List<String> {
        val acct = account.lowercase()
        val out = LinkedHashSet<String>()
        for (h in hints) { val l = h.lowercase(); if (l.isNotEmpty() && l != acct) out.add(l) }
        val hinted = out.isNotEmpty()
        for (d in resolved) { val l = d.lowercase(); if (l.isNotEmpty() && l != acct) out.add(l) }
        if (!hinted || out.isEmpty()) out.add(acct)
        return out.toList()
    }
}
