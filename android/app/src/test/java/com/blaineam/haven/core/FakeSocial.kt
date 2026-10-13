package com.blaineam.haven.core

import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.ContactRosterWire
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.NoHandle
import uniffi.haven_ffi.OpenedCircleBlobFfi
import uniffi.haven_ffi.ProfileCardFfi
import uniffi.haven_ffi.SignedCallFrame
import uniffi.haven_ffi.TrackRefFfi
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

    // ---- identity, transport and ingest, scripted by the network-lane tests ----------------------
    // Each is `null`/empty by default, in which case the call fails exactly like a dead engine (the
    // generated binding throws), so a test only scripts what the path under test reads.
    var myNode: String? = null
    var myDevice: String? = null
    val deviceIds = HashMap<String, List<String>>()
    val accountOfDevice = HashMap<String, String>()
    /** Answers [receive]; unset = the engine refuses (a dead handle). */
    var receiveFn: ((String, ByteArray) -> Boolean)? = null
    val received = java.util.concurrent.CopyOnWriteArrayList<Pair<String, ByteArray>>()
    var openBlob: ((String, ByteArray) -> OpenedCircleBlobFfi?)? = null
    var sealMedia: ((String, ByteArray) -> ByteArray)? = null
    var epochMoved: List<String>? = null
    val epochHeads = HashMap<String, List<ByteArray>>()
    val syncEnvs = HashMap<String, List<ByteArray>>()
    var keyUnsaved = false
    var exported: ByteArray? = null
    var verifyHex: ((ByteArray) -> String?)? = null
    var profileName: String? = null
    var profileCard: ProfileCardFfi? = null
    var openCall: ((UByte, ByteArray) -> SignedCallFrame?)? = null
    var sealCall: ((String, UByte, ByteArray) -> ByteArray)? = null
    val sealedCalls = java.util.concurrent.CopyOnWriteArrayList<Triple<String, UByte, ByteArray>>()

    var ownRoster: List<ContactRosterWire>? = null
    var contactRosters: List<ContactRosterWire>? = null
    var myRosterWire: ByteArray? = null
    /** Answers [ingestRosterWireStatus]: -1 refused, 0 already current, 1 stored. */
    var rosterStatus: ((ByteArray) -> Byte)? = null
    val ingestedRosters = java.util.concurrent.CopyOnWriteArrayList<ByteArray>()
    /** Runs after a roster is ingested (so a test can model the engine now exporting the adopted version). */
    var onIngest: ((ByteArray) -> Unit)? = null
    val recentEnvelopes = HashMap<String, List<ByteArray>>()
    override fun `exportOwnRoster`(): List<ContactRosterWire> = ownRoster ?: super.`exportOwnRoster`()
    override fun `exportContactRosters`(): List<ContactRosterWire> = contactRosters ?: super.`exportContactRosters`()
    override fun `myDeviceRosterWire`(): ByteArray = myRosterWire ?: super.`myDeviceRosterWire`()
    override fun `ingestRosterWireStatus`(`wire`: ByteArray): Byte {
        ingestedRosters += wire
        val st = rosterStatus?.invoke(wire) ?: super.`ingestRosterWireStatus`(wire)
        onIngest?.invoke(wire)
        return st
    }
    override fun `ingestRosterWire`(`wire`: ByteArray): Boolean = (rosterStatus?.invoke(wire) ?: super.`ingestRosterWireStatus`(wire)) >= 0
    override fun `exportRecentEnvelopes`(`circleId`: String, `limit`: UInt): List<ByteArray> = recentEnvelopes[circleId] ?: super.`exportRecentEnvelopes`(circleId, limit)
    var bundle: ByteArray? = null
    var signedProfile: ByteArray? = null
    override fun `myBundle`(): ByteArray = bundle ?: super.`myBundle`()
    override fun `mySignedProfile`(`name`: String, `bio`: String, `link`: String, `avatar`: String, `emoji`: String): ByteArray =
        signedProfile ?: super.`mySignedProfile`(name, bio, link, avatar, emoji)
    override fun `myNodeHex`(): String = myNode ?: super.`myNodeHex`()
    override fun `myDeviceNodeHex`(): String = myDevice ?: super.`myDeviceNodeHex`()
    override fun `deviceNodeIdsFor`(`accountHex`: String): List<String> = deviceIds[accountHex] ?: super.`deviceNodeIdsFor`(accountHex)
    override fun `accountForDevice`(`deviceHex`: String): String? = if (accountOfDevice.containsKey(deviceHex)) accountOfDevice[deviceHex] else super.`accountForDevice`(deviceHex)
    override fun `receive`(`circleId`: String, `envelope`: ByteArray): Boolean {
        received += circleId to envelope
        return receiveFn?.invoke(circleId, envelope) ?: super.`receive`(circleId, envelope)
    }
    override fun `openCircleMediaSender`(`circleId`: String, `sealed`: ByteArray): OpenedCircleBlobFfi? =
        openBlob?.invoke(circleId, sealed) ?: super.`openCircleMediaSender`(circleId, sealed)
    override fun `sealCircleMedia`(`circleId`: String, `data`: ByteArray): ByteArray =
        sealMedia?.invoke(circleId, data) ?: super.`sealCircleMedia`(circleId, data)
    override fun `takeEpochMovedCircles`(): List<String> =
        epochMoved?.also { epochMoved = emptyList() } ?: super.`takeEpochMovedCircles`()
    override fun `exportEpochHead`(`circleId`: String): List<ByteArray> = epochHeads[circleId] ?: super.`exportEpochHead`(circleId)
    override fun `syncEnvelopes`(`circleId`: String): List<ByteArray> = syncEnvs[circleId] ?: super.`syncEnvelopes`(circleId)
    override fun `keyStateUnsaved`(): Boolean = keyUnsaved
    override fun `exportState`(): ByteArray = exported ?: super.`exportState`()
    override fun `bundleVerificationHex`(`bundle`: ByteArray): String = verifyHex?.invoke(bundle) ?: super.`bundleVerificationHex`(bundle)
    override fun `verifyProfile`(`bundle`: ByteArray, `blob`: ByteArray): String? = profileName ?: super.`verifyProfile`(bundle, blob)
    override fun `verifyProfileCard`(`bundle`: ByteArray, `blob`: ByteArray): ProfileCardFfi? = profileCard ?: super.`verifyProfileCard`(bundle, blob)
    /** When set, the circle-forming calls succeed (and are logged in [calls]) instead of failing like a dead engine. */
    var lenient = false
    override fun `createCircle`(`id`: String, `name`: String) { if (!lenient) super.`createCircle`(id, name) else calls += "create $id $name" }
    override fun `addContactBundle`(`circleId`: String, `bundle`: ByteArray): String =
        if (!lenient) super.`addContactBundle`(circleId, bundle) else { calls += "addBundle $circleId"; nodeHex(bundle) }
    override fun `setCircleLiveLane`(`circleId`: String, `on`: Boolean) { if (!lenient) super.`setCircleLiveLane`(circleId, on) else calls += "liveLane $circleId $on" }
    override fun `openCallFrame`(`frameType`: UByte, `blob`: ByteArray): SignedCallFrame? =
        openCall?.invoke(frameType, blob) ?: super.`openCallFrame`(frameType, blob)
    override fun `sealCallFrame`(`recipientNodeHex`: String, `frameType`: UByte, `data`: ByteArray): ByteArray {
        sealedCalls += Triple(recipientNodeHex, frameType, data)
        return sealCall?.invoke(recipientNodeHex, frameType, data) ?: super.`sealCallFrame`(recipientNodeHex, frameType, data)
    }
}
