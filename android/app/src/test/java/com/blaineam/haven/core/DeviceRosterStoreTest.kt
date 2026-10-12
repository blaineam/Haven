package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The multi-device roster's persistence and revocation bookkeeping (the signing itself is the Rust core's). */
class DeviceRosterStoreTest {
    private lateinit var ctx: FakeContext
    private val primary = "aa".repeat(32)
    private val phone = "bb".repeat(32)
    private val tablet = "cc".repeat(32)

    @Before fun setUp() {
        ctx = FakeContext()
        DeviceCredentialStore.init(ctx)
        DeviceRosterManager.init(ctx)
        DeviceRosterManager.clear()
    }

    private fun b64(b: ByteArray) = android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP)

    private fun seedRoster(version: Long = 3, revoked: List<String> = emptyList()) {
        val entries = JSONObject()
            .put(primary, JSONObject().put("bundle", b64(byteArrayOf(1))).put("name", "Primary").put("isPrimary", true))
            .put(phone, JSONObject().put("bundle", b64(byteArrayOf(2, 2))).put("name", "Pixel").put("isPrimary", false))
            .put(tablet, JSONObject().put("bundle", b64(byteArrayOf(3, 3, 3))).put("name", "Tab"))
        val root = JSONObject().put("version", version).put("primaryHex", primary)
            .put("entries", entries).put("revoked", JSONArray(revoked))
        ctx.prefs("haven.deviceRoster").data["rosterV2"] = root.toString()
        DeviceRosterManager.init(ctx)
    }

    @Test fun a_fresh_install_has_no_roster() {
        assertFalse(DeviceRosterManager.isEnabled())
        assertTrue(DeviceRosterManager.devices.isEmpty())
        assertTrue(DeviceRosterManager.activeLinkedBundles().isEmpty())
    }

    @Test fun a_saved_roster_loads_with_the_primary_listed_first() {
        seedRoster()
        assertTrue(DeviceRosterManager.isEnabled())
        val d = DeviceRosterManager.devices.toList()
        assertEquals(listOf(primary, phone, tablet), d.map { it.nodeHex })
        assertEquals(listOf(true, false, false), d.map { it.isPrimary })
        assertEquals(listOf("Primary", "Pixel", "Tab"), d.map { it.name })
    }

    @Test fun grant_recipients_are_the_linked_devices_minus_primary_and_revoked() {
        seedRoster(revoked = listOf(tablet))
        val bundles = DeviceRosterManager.activeLinkedBundles()
        assertEquals(1, bundles.size)
        assertArrayEquals(byteArrayOf(2, 2), bundles[0])
    }

    @Test fun without_a_revocation_both_linked_devices_receive_key_grants() {
        seedRoster()
        assertEquals(setOf(listOf<Byte>(2, 2), listOf<Byte>(3, 3, 3)),
            DeviceRosterManager.activeLinkedBundles().map { it.toList() }.toSet())
    }

    @Test fun the_master_key_can_never_be_revoked() {
        seedRoster()
        assertFalse(DeviceRosterManager.revoke(primary, null, ByteArray(32)))
        assertEquals(3, DeviceRosterManager.devices.size)
    }

    @Test fun revoking_a_device_drops_it_from_the_grant_recipients_at_once() {
        seedRoster()
        DeviceRosterManager.revoke(phone, null, ByteArray(32))   // signing needs the native core: result unused here
        assertEquals(1, DeviceRosterManager.activeLinkedBundles().size)
        assertArrayEquals(byteArrayOf(3, 3, 3), DeviceRosterManager.activeLinkedBundles()[0])
    }

    @Test fun stepping_down_forgets_the_roster_and_the_credential() {
        seedRoster()
        DeviceCredentialStore.save(byteArrayOf(9, 9))
        DeviceRosterManager.stepDown()
        assertFalse(DeviceRosterManager.isEnabled())
        assertTrue(DeviceRosterManager.devices.isEmpty())
        assertFalse(DeviceCredentialStore.isAuthorized())
        assertTrue(DeviceCredentialStore.authorized.value.not())
    }

    @Test fun clear_wipes_memory_and_prefs() {
        seedRoster()
        DeviceRosterManager.clear()
        assertFalse(DeviceRosterManager.isEnabled())
        assertFalse(ctx.prefs("haven.deviceRoster").data.containsKey("rosterV2"))
    }

    @Test fun a_corrupt_roster_blob_is_ignored() {
        ctx.prefs("haven.deviceRoster").data["rosterV2"] = "{not json"
        DeviceRosterManager.init(ctx)
        assertFalse(DeviceRosterManager.isEnabled())
    }

    @Test fun the_credential_round_trips_and_clears() {
        assertNull(DeviceCredentialStore.load()); assertFalse(DeviceCredentialStore.isAuthorized())
        DeviceCredentialStore.save(byteArrayOf(1, 2, 3, 4))
        assertTrue(DeviceCredentialStore.authorized.value)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), DeviceCredentialStore.load())
        DeviceCredentialStore.authorized.value = false
        DeviceCredentialStore.refresh()
        assertTrue("refresh re-derives authorization from the stored credential", DeviceCredentialStore.authorized.value)
        DeviceCredentialStore.clear()
        assertNull(DeviceCredentialStore.load()); assertFalse(DeviceCredentialStore.authorized.value)
    }
}
