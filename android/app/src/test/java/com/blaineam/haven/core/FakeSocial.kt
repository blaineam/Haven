package com.blaineam.haven.core

import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.NoHandle
import uniffi.haven_ffi.ReportFfi
import uniffi.haven_ffi.TrackRefFfi

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
    override fun `blockMember`(`nodeHex`: String) { check(); calls += "block $nodeHex" }
    override fun `removeFromCircle`(`circleId`: String, `nodeHex`: String) { check(); calls += "removeMember $circleId $nodeHex" }

    /** What HavenNet asked the engine to author. The fake then REFUSES (throws), so HavenNet stops before its
     *  broadcast / upload legs — these tests are about what is asked, and nothing leaves the process. */
    class Authored(val verb: String, val circleId: String, val target: String = "", val body: String = "",
                   val media: List<String> = emptyList(), val music: TrackRefFfi? = null,
                   val muteVideo: Boolean = false, val retentionSecs: ULong? = null)
    val authored = java.util.concurrent.CopyOnWriteArrayList<Authored>()
    private fun refuse(a: Authored): Nothing { authored += a; throw IllegalStateException("engine refused ${a.verb}") }

    override fun `post`(`circleId`: String, `body`: String, `media`: List<String>, `music`: TrackRefFfi?, `retentionSecs`: ULong?,
                        `story`: Boolean, `muteVideo`: Boolean, `createdAt`: ULong): ByteArray =
        refuse(Authored(if (story) "story" else "post", circleId, body = body, media = media, music = music,
            muteVideo = muteVideo, retentionSecs = retentionSecs))
    override fun `react`(`circleId`: String, `target`: String, `emoji`: String, `createdAt`: ULong): ByteArray =
        refuse(Authored("react", circleId, target, body = emoji))
    override fun `unreact`(`circleId`: String, `target`: String, `emoji`: String, `createdAt`: ULong): ByteArray =
        refuse(Authored("unreact", circleId, target, body = emoji))
    override fun `comment`(`circleId`: String, `target`: String, `body`: String, `media`: List<String>, `createdAt`: ULong): ByteArray =
        refuse(Authored("comment", circleId, target, body, media))
    override fun `unsend`(`circleId`: String, `target`: String, `createdAt`: ULong): ByteArray =
        refuse(Authored("unsend", circleId, target))
    override fun `edit`(`circleId`: String, `target`: String, `body`: String, `media`: List<String>, `music`: TrackRefFfi?,
                        `muteVideo`: Boolean, `createdAt`: ULong): ByteArray =
        refuse(Authored("edit", circleId, target, body, media, music, muteVideo))
    override fun `report`(`circleId`: String, `target`: String, `reason`: String, `comment`: String, `createdAt`: ULong): ByteArray =
        refuse(Authored("report", circleId, target, reason + "|" + comment))
}
