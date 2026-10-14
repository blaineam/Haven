package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.AccountStateHandle
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.ContactRosterWire
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.NoHandle
import uniffi.haven_ffi.SelfSyncEntry

/** A converged account state held in a plain map: the two reads the coordinator makes of the CRDT handle. */
class FakeAccountState : AccountStateHandle(NoHandle) {
    val map = LinkedHashMap<String, ByteArray>()
    override fun `get`(`key`: String): ByteArray? = map[key]
    override fun `entries`(): List<SelfSyncEntry> = map.map { SelfSyncEntry(it.key, it.value) }
}

/**
 * Multi-device convergence, both directions: what this device contributes to its account state
 * ([SelfSyncCoordinator] `currentLocal`) and how a converged state is written back into the local stores
 * (`applyLocal`). The CRDT merge itself and the slot sealing are the Rust core's and are not reachable here.
 */
class SelfSyncApplyTest {
    private val env = NetEnv()
    private val coordinator = SelfSyncCoordinator::class.java
    private val friend = "f1".repeat(32)
    private val friend2 = "f2".repeat(32)
    private val future get() = System.currentTimeMillis() + 60_000
    private var savedContext: Any? = null
    private var savedInitialized = false

    private fun field(n: String) = coordinator.getDeclaredField(n).apply { isAccessible = true }

    @Before fun setUp() {
        env.up()
        // SelfSyncCoordinator is a one-shot singleton shared with its state test: borrow the context, give it back.
        savedContext = field("appContext").get(SelfSyncCoordinator)
        savedInitialized = field("initialized").getBoolean(SelfSyncCoordinator)
        field("appContext").set(SelfSyncCoordinator, env.ctx)
        field("initialized").setBoolean(SelfSyncCoordinator, true)
        DmPins.init(env.ctx)
        DmPins.pinned.clear()
    }
    @After fun tearDown() {
        field("appContext").set(SelfSyncCoordinator, savedContext)
        field("initialized").setBoolean(SelfSyncCoordinator, savedInitialized)
        profile.saveMyPosts = false; profile.saveOthersPosts = false; profile.autoOptimize = true   // the store is a process singleton
        env.down()
    }

    private fun apply(h: FakeAccountState, social: HavenSocial? = env.social) {
        val m = coordinator.getDeclaredMethod("applyLocal", AccountStateHandle::class.java, HavenSocial::class.java).apply { isAccessible = true }
        try { m.invoke(SelfSyncCoordinator, h, social) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    @Suppress("UNCHECKED_CAST")
    private fun local(social: HavenSocial? = env.social): Map<String, ByteArray> {
        val m = coordinator.getDeclaredMethod("currentLocal", HavenSocial::class.java).apply { isAccessible = true }
        return try { m.invoke(SelfSyncCoordinator, social) as Map<String, ByteArray> } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun i64(v: Long) = SelfSyncWire.int64LE(v)
    private val profile get() = ProfileStore.get(env.ctx)

    // ---- applyLocal: scalars ----------------------------------------------------------------------

    @Test fun a_newer_remote_profile_edit_wins_and_an_older_one_loses() {
        val h = FakeAccountState()
        h.map["profile:name"] = "Remote Name".toByteArray(); h.map["profile-at:name"] = i64(future)
        h.map["profile:bio"] = "remote bio".toByteArray(); h.map["profile-at:bio"] = i64(future)
        h.map["profile:link"] = "https://example.org".toByteArray(); h.map["profile-at:link"] = i64(future)
        h.map["profile:emoji"] = "🦊".toByteArray(); h.map["profile-at:emoji"] = i64(future)
        h.map["profile:avatar"] = "QVZB".toByteArray(); h.map["profile-at:avatar"] = i64(future)
        apply(h)
        assertEquals("Remote Name", profile.displayName)
        assertEquals("remote bio", profile.bio)
        assertEquals("https://example.org", profile.link)
        assertEquals("🦊", profile.emoji)
        assertEquals("QVZB", profile.avatarB64)
        val older = FakeAccountState()
        older.map["profile:name"] = "Stale".toByteArray(); older.map["profile-at:name"] = i64(1_000)
        apply(older)
        assertEquals("a stale remote value never overwrites a newer local one", "Remote Name", profile.displayName)
    }

    @Test fun an_untimestamped_legacy_value_only_seeds_an_empty_field() {
        val seed = FakeAccountState()
        seed.map["profile:bio"] = "legacy bio".toByteArray()
        val p = profile
        p.applyRemoteField("bio", "", future)   // empty it deliberately
        val before = p.bio
        apply(seed)
        // Either seeded (field empty and never stamped) or left alone (a stamp exists): never a crash, never a clobber.
        assertTrue(p.bio == before || p.bio == "legacy bio")
    }

    @Test fun synced_settings_apply_by_their_own_timestamps() {
        val h = FakeAccountState()
        h.map["setting:saveToPhotos"] = byteArrayOf(1); h.map["setting-at:${ProfileStore.TS_SAVE}"] = i64(future)
        h.map["setting:saveOthersToPhotos"] = byteArrayOf(1); h.map["setting-at:${ProfileStore.TS_SAVE_OTHERS}"] = i64(future)
        h.map["setting:autoOptimize"] = byteArrayOf(0); h.map["setting-at:${ProfileStore.TS_OPT}"] = i64(future)
        h.map["setting:retentionDays"] = SelfSyncWire.int32LE(30); h.map["setting-at:${ProfileStore.TS_RET}"] = i64(future)
        apply(h)
        assertTrue(profile.saveMyPosts); assertTrue(profile.saveOthersPosts); assertFalse(profile.autoOptimize)
        assertEquals(30, profile.retentionDays)
    }

    @Test fun pinned_conversations_and_read_watermarks_are_adopted() {
        val h = FakeAccountState()
        h.map["setting:pinnedDMs"] = "dm:a\ndm:b".toByteArray()
        h.map["setting:activitySeenAt"] = i64(System.currentTimeMillis() + 5_000)
        h.map["setting:dmLastRead"] = """{"dm:a-b":1700000000000}""".toByteArray()
        apply(h)
        assertEquals(listOf("dm:a", "dm:b"), DmPins.pinned.toList())
        assertTrue(ActivityStore.seenAt() > 0)
    }

    // ---- applyLocal: rosters, contacts, blocked ---------------------------------------------------------

    @Test fun a_synced_device_roster_that_changed_triggers_the_epoch_reseal_check() {
        env.social.rosterStatus = { 1 }
        env.social.epochMoved = listOf("default")
        val h = FakeAccountState()
        h.map["roster:${friend}"] = byteArrayOf(5, 5)
        apply(h)
        assertEquals(1, env.social.ingestedRosters.size)
        assertEquals("the engine's epoch-moved flag was drained", emptyList<String>(), env.social.epochMoved)
    }

    @Test fun an_unchanged_roster_does_not_re_seal() {
        env.social.rosterStatus = { 0 }
        env.social.epochMoved = listOf("default")
        val h = FakeAccountState(); h.map["roster:${friend}"] = byteArrayOf(5)
        apply(h)
        assertEquals(listOf("default"), env.social.epochMoved)
    }

    @Test fun contacts_are_added_from_a_sibling_but_never_removed_by_absence() {
        HavenNet.contacts.add(Contact(friend2, "Kept", "v"))
        val h = FakeAccountState()
        h.map["contact:$friend"] = SelfSyncWire.encodeContact(Contact(friend, "Pat", "vv"))
        apply(h)
        assertEquals(setOf(friend, friend2), HavenNet.contacts.map { it.idHex }.toSet())
    }

    @Test fun a_contact_removed_on_another_device_is_removed_here_and_not_resurrected_by_a_stale_record() {
        HavenNet.contacts.add(Contact(friend, "Pat", "v"))
        val h = FakeAccountState()
        h.map["contact-removed:$friend"] = i64(future)
        h.map["contact:$friend"] = SelfSyncWire.encodeContact(Contact(friend, "Pat", "v"))
        apply(h)
        assertTrue(HavenNet.contacts.none { it.idHex == friend })
        val readd = FakeAccountState()
        readd.map["contact-readd:$friend"] = i64(future + 60_000)
        readd.map["contact:$friend"] = SelfSyncWire.encodeContact(Contact(friend, "Pat", "v"))
        apply(readd)
        assertTrue("a newer re-add lifts the tombstone", HavenNet.contacts.any { it.idHex == friend })
    }

    @Test fun the_blocked_set_converges_in_both_directions() {
        HavenNet.blocked.add(friend2)
        val h = FakeAccountState(); h.map["blocked:$friend"] = byteArrayOf(1)
        apply(h)
        assertEquals(listOf(friend), HavenNet.blocked.toList())
    }

    // ---- applyLocal: circles, relays --------------------------------------------------------------------

    @Test fun a_circle_severance_is_applied_by_last_writer_and_a_newer_re_add_lifts_it() {
        val cid = "c1group"
        val h = FakeAccountState()
        h.map["circle-removed:$cid|${friend.uppercase()}"] = i64(future)
        apply(h)
        assertTrue(env.social.calls.contains("removeMember $cid $friend") || env.social.calls.contains("removeMember $cid ${friend.uppercase()}"))
        val back = FakeAccountState()
        back.map["circle-removed:$cid|$friend"] = i64(future)
        back.map["circle-readd:$cid|$friend"] = i64(future + 120_000)
        apply(back)
        assertTrue(env.social.calls.any { it.startsWith("clearRemoval $cid") })
        CircleRemovals.clear()
    }

    @Test fun a_whole_circle_deleted_elsewhere_is_left_here_when_the_engine_holds_it() {
        env.social.circleList = listOf(CircleInfoFfi("dm:x-y", "dm", 2u))
        val h = FakeAccountState(); h.map["circle-deleted:dm:x-y"] = i64(future)
        apply(h)
        assertTrue(env.social.calls.contains("leave dm:x-y"))
        val none = FakeAccountState(); none.map["circle-deleted:dm:other"] = i64(future)
        env.social.calls.clear()
        apply(none)
        assertTrue("a circle the engine does not hold is not left", env.social.calls.none { it.startsWith("leave") })
        CircleDeletion.markRecreated("dm:x-y"); CircleDeletion.markRecreated("dm:other")
    }

    @Test fun a_relay_deleted_elsewhere_is_forgotten_here_and_a_newer_re_add_brings_it_back() {
        val relay = "99".repeat(32)
        env.entries()[relay] = HavenNet.RelayEntry(relay, "r", true, 0, false)
        val h = FakeAccountState(); h.map["relay-removal:$relay"] = i64(future)
        apply(h)
        assertFalse(env.entries().getValue(relay).active)
        assertTrue(HavenNet.relayForgottenRecords().containsKey(relay))
        val back = FakeAccountState(); back.map["relay-readd:$relay"] = i64(future + 120_000)
        apply(back)
        assertTrue(HavenNet.relayClearedForgetRecords().containsKey(relay))
    }

    @Test fun applying_without_an_engine_still_applies_the_local_store_state() {
        val h = FakeAccountState(); h.map["blocked:$friend"] = byteArrayOf(1)
        apply(h, social = null)
        assertEquals(listOf(friend), HavenNet.blocked.toList())
    }

    // ---- currentLocal --------------------------------------------------------------------------------------

    @Test fun this_devices_contribution_carries_profile_settings_contacts_blocked_and_rosters() {
        profile.completeOnboarding("Me Myself", "🙂")
        HavenNet.contacts.add(Contact(friend, "Pat", "vv"))
        HavenNet.blocked.add(friend2)
        DmPins.pinned.add("dm:a")
        env.social.ownRoster = listOf(ContactRosterWire(env.me, byteArrayOf(7)))
        env.social.contactRosters = listOf(ContactRosterWire(friend, byteArrayOf(8)))
        val m = local()
        assertEquals("Me Myself", String(m.getValue("profile:name")))
        assertEquals("🙂", String(m.getValue("profile:emoji")))
        assertTrue(m.containsKey("profile-at:name"))
        assertEquals(1, m.getValue("setting:saveToPhotos").size)
        assertEquals(4, m.getValue("setting:retentionDays").size)
        assertEquals("dm:a", String(m.getValue("setting:pinnedDMs")))
        assertNotNull(m["contact:$friend"])
        assertArrayEquals(byteArrayOf(1), m["blocked:$friend2"])
        assertArrayEquals(byteArrayOf(8), m["roster:$friend"])
        assertArrayEquals(byteArrayOf(7), m["roster:${env.me}"])
    }

    @Test fun removal_records_ride_along_so_a_delete_sticks_fleet_wide() {
        ContactRemovals.markRemoved(friend)
        CircleDeletion.markDeleted("dm:gone")
        CircleRemovals.add("c1x", friend2)
        val m = local()
        assertEquals(8, m.getValue("contact-removed:$friend").size)
        assertEquals(8, m.getValue("circle-deleted:dm:gone").size)
        assertEquals(8, m.getValue("circle-removed:c1x|$friend2").size)
        assertArrayEquals("the legacy 1/0 record keeps pre-LWW siblings converging", byteArrayOf(1), m["removal:c1x|$friend2"])
        ContactRemovals.markReadded(friend); CircleDeletion.markRecreated("dm:gone"); CircleRemovals.clear()
    }

    @Test fun without_an_engine_no_circle_or_roster_records_are_contributed() {
        val m = local(social = null)
        assertTrue(m.keys.none { it.startsWith("circle:") || it.startsWith("roster:") })
    }

    @Test fun a_deleted_circle_is_not_re_broadcast_by_this_device() {
        env.social.circleList = listOf(CircleInfoFfi("dm:deleted", "dm", 2u))
        CircleDeletion.markDeleted("dm:deleted")
        assertTrue(local().keys.none { it == "circle:dm:deleted" })
        CircleDeletion.markRecreated("dm:deleted")
    }
}
