package com.blaineam.haven.core

import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.NoHandle
import uniffi.haven_ffi.ReportFfi

/**
 * A JVM stand-in for the Rust engine's social handle. It answers the READ calls HavenNet makes
 * (circles, feed, admins, upgrade offers) from plain data, and is built on the generated binding's own
 * test constructor (`NoHandle`), so every call it does NOT override still fails exactly like a dead
 * engine would (the bindings throw). [failReads] makes the overridden reads throw too, which is how the
 * tests prove HavenNet degrades instead of crashing when the engine misbehaves.
 */
class FakeSocial : HavenSocial(NoHandle) {
    var circleList: List<CircleInfoFfi> = emptyList()
    val feeds = HashMap<String, List<FeedItemFfi>>()
    val admins = HashMap<String, List<String>>()
    val offers = HashMap<String, List<CircleUpgradeOffer>>()
    @Volatile var failReads = false
    val feedAsks = java.util.concurrent.CopyOnWriteArrayList<Pair<String, ULong?>>()

    private fun check() { if (failReads) throw IllegalStateException("engine unavailable") }

    override fun `circles`(): List<CircleInfoFfi> { check(); return circleList }
    override fun `feed`(`circleId`: String, `nowMs`: ULong, `viewerRetentionSecs`: ULong?): List<FeedItemFfi> {
        check(); feedAsks += circleId to viewerRetentionSecs; return feeds[circleId] ?: emptyList()
    }
    override fun `circleAdmins`(`circleId`: String): List<String> { check(); return admins[circleId] ?: emptyList() }
    override fun `pendingCircleUpgrades`(`circleId`: String): List<CircleUpgradeOffer> { check(); return offers[circleId] ?: emptyList() }

    val members = HashMap<String, List<String>>()
    var superseded: List<String> = emptyList()
    val successors = HashMap<String, String>()
    val reportList = HashMap<String, List<ReportFfi>>()
    /** Every circle-changing call HavenNet made, in order, as "verb arg arg". */
    val calls = java.util.concurrent.CopyOnWriteArrayList<String>()

    override fun `contactNodeIds`(`circleId`: String): List<String> { check(); return members[circleId] ?: emptyList() }
    override fun `supersededCircleIds`(): List<String> { check(); return superseded }
    override fun `circleSuccessor`(`circleId`: String): String? { check(); return successors[circleId] }
    override fun `reports`(`circleId`: String): List<ReportFfi> { check(); return reportList[circleId] ?: emptyList() }
    override fun `renameCircle`(`id`: String, `name`: String) { check(); calls += "rename $id $name" }
    override fun `leaveCircle`(`id`: String) { check(); calls += "leave $id" }
    override fun `clearCircleRemoval`(`circleId`: String, `nodeHex`: String) { check(); calls += "clearRemoval $circleId $nodeHex" }
    override fun `addExistingToCircle`(`circleId`: String, `nodeHex`: String) { check(); calls += "add $circleId $nodeHex" }
}
