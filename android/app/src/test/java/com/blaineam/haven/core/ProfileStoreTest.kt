package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Profile + synced-settings store: persistence, per-field last-writer-wins stamps, remote apply. */
class ProfileStoreTest {
    private lateinit var ctx: FakeContext

    @Before fun setUp() {
        ctx = FakeContext()
        resetSingleton()
    }

    private fun resetSingleton() {
        ProfileStore::class.java.getDeclaredField("instance").apply { isAccessible = true }.set(null, null)
    }

    private fun fresh(): ProfileStore { resetSingleton(); return ProfileStore.get(ctx) }

    @Test fun a_new_profile_has_the_documented_defaults() {
        val p = ProfileStore.get(ctx)
        assertFalse(p.onboarded); assertEquals("", p.displayName); assertEquals("🌅", p.emoji)
        assertEquals(0, p.retentionDays); assertNull(p.retentionSecs())
        assertTrue("optimize defaults on", p.autoOptimize); assertFalse(p.saveMyPosts); assertFalse(p.saveOthersPosts)
        assertEquals("full", p.notificationDetail)
        assertEquals(0L, p.fieldTimestamp("name")); assertEquals(0L, p.settingTimestamp(ProfileStore.TS_SAVE))
    }

    @Test fun get_returns_one_instance() {
        assertTrue(ProfileStore.get(ctx) === ProfileStore.get(FakeContext()))
    }

    @Test fun onboarding_persists_and_stamps_the_name_and_emoji() {
        val before = System.currentTimeMillis()
        val p = ProfileStore.get(ctx)
        p.completeOnboarding("Ana", "🦊")
        assertTrue(p.onboarded)
        assertTrue(p.fieldTimestamp("name") >= before); assertTrue(p.fieldTimestamp("emoji") >= before)
        assertEquals(0L, p.fieldTimestamp("bio"))
        val again = fresh()
        assertTrue(again.onboarded); assertEquals("Ana", again.displayName); assertEquals("🦊", again.emoji)
        assertEquals("the stamps persist too", p.fieldTimestamp("name"), again.fieldTimestamp("name"))
    }

    @Test fun marking_onboarded_leaves_the_profile_blank() {
        val p = ProfileStore.get(ctx)
        p.markOnboarded()
        assertTrue(p.onboarded); assertEquals("", p.displayName); assertEquals(0L, p.fieldTimestamp("name"))
        assertTrue(fresh().onboarded)
    }

    @Test fun save_stamps_only_the_fields_that_changed() {
        val p = ProfileStore.get(ctx)
        p.displayName = "Ana"; p.save()
        assertTrue(p.fieldTimestamp("name") > 0)
        assertEquals(0L, p.fieldTimestamp("bio")); assertEquals(0L, p.fieldTimestamp("link"))
        val nameTs = p.fieldTimestamp("name")
        p.bio = "hello"; p.save()
        assertTrue(p.fieldTimestamp("bio") > 0)
        assertEquals("an unchanged field keeps its stamp", nameTs, p.fieldTimestamp("name"))
        p.link = "https://example.com"; p.emoji = "🐙"; p.save()
        assertTrue(p.fieldTimestamp("link") > 0 && p.fieldTimestamp("emoji") > 0)
        val again = fresh()
        assertEquals("hello", again.bio); assertEquals("https://example.com", again.link); assertEquals("🐙", again.emoji)
    }

    @Test fun retention_converts_days_to_seconds_and_persists_with_a_stamp() {
        val p = ProfileStore.get(ctx)
        p.setRetention(30)
        assertEquals(30L * 86_400L, p.retentionSecs()!!.toLong())
        assertTrue(p.settingTimestamp(ProfileStore.TS_RET) > 0)
        assertEquals(30, fresh().retentionDays)
        p.setRetention(0); assertNull(p.retentionSecs())
        p.setRetention(-5); assertNull("negative = keep forever", p.retentionSecs())
    }

    @Test fun synced_toggles_persist_and_stamp_their_ios_storage_keys() {
        val p = ProfileStore.get(ctx)
        p.saveMyPosts = true; p.saveOthersPosts = true; p.autoOptimize = false
        for (k in listOf(ProfileStore.TS_SAVE, ProfileStore.TS_SAVE_OTHERS, ProfileStore.TS_OPT)) assertTrue(k, p.settingTimestamp(k) > 0)
        assertEquals("haven.saveToPhotos", ProfileStore.TS_SAVE)
        val again = fresh()
        assertTrue(again.saveMyPosts); assertTrue(again.saveOthersPosts); assertFalse(again.autoOptimize)
    }

    @Test fun device_local_toggles_persist_without_a_sync_stamp() {
        val p = ProfileStore.get(ctx)
        p.videoSoundOn = true; p.superDataSaver = true; p.sendOriginal = true
        assertTrue(p.videoSoundOn && p.superDataSaver && p.sendOriginal)
        val again = fresh()
        assertTrue(again.videoSoundOn && again.superDataSaver && again.sendOriginal)
        assertEquals(0L, again.settingTimestamp("videoSoundOn"))
    }

    @Test fun notification_detail_only_accepts_the_three_known_levels() {
        val p = ProfileStore.get(ctx)
        p.notificationDetail = "private"; assertEquals("private", p.notificationDetail)
        p.notificationDetail = "minimal"; assertEquals("minimal", p.notificationDetail)
        p.notificationDetail = "banana"; assertEquals("full", p.notificationDetail)
        p.notificationDetail = "private"
        assertEquals("private", fresh().notificationDetail)
    }

    // ---- last-writer-wins from another of my devices ---------------------------------------------

    @Test fun a_newer_remote_field_wins_and_adopts_the_remote_timestamp() {
        val p = ProfileStore.get(ctx)
        p.displayName = "Local"; p.save()
        val localTs = p.fieldTimestamp("name")
        assertTrue(p.applyRemoteField("name", "Remote", localTs + 1000))
        assertEquals("Remote", p.displayName)
        assertEquals("not re-stamped as a fresh local edit", localTs + 1000, p.fieldTimestamp("name"))
        assertEquals("persisted", "Remote", fresh().displayName)
    }

    @Test fun an_older_or_equal_remote_field_loses() {
        val p = ProfileStore.get(ctx)
        p.displayName = "Local"; p.save()
        val ts = p.fieldTimestamp("name")
        assertFalse(p.applyRemoteField("name", "Stale", ts - 1))
        assertFalse(p.applyRemoteField("name", "Tie", ts))
        assertEquals("Local", p.displayName)
    }

    @Test fun remote_fields_cover_every_profile_field_but_never_blank_the_emoji_or_avatar() {
        val p = ProfileStore.get(ctx)
        assertTrue(p.applyRemoteField("bio", "a bio", 10)); assertEquals("a bio", p.bio)
        assertTrue(p.applyRemoteField("link", "https://x.y", 10)); assertEquals("https://x.y", p.link)
        assertTrue(p.applyRemoteField("emoji", "🐢", 10)); assertEquals("🐢", p.emoji)
        assertTrue(p.applyRemoteField("avatar", "QUJD", 10)); assertEquals("QUJD", p.avatarB64)
        assertTrue(p.applyRemoteField("emoji", "", 20)); assertEquals("a blank emoji is ignored", "🐢", p.emoji)
        assertTrue(p.applyRemoteField("avatar", "", 20)); assertEquals("a blank avatar is ignored", "QUJD", p.avatarB64)
        assertTrue(p.applyRemoteField("name", "", 20)); assertEquals("a name CAN be cleared by a newer edit", "", p.displayName)
    }

    @Test fun remote_settings_are_last_writer_wins_and_do_not_restamp() {
        val p = ProfileStore.get(ctx)
        assertTrue(p.applyRemoteSettingBool(ProfileStore.TS_SAVE, true, 100))
        assertTrue(p.saveMyPosts); assertEquals(100L, p.settingTimestamp(ProfileStore.TS_SAVE))
        assertFalse(p.applyRemoteSettingBool(ProfileStore.TS_SAVE, false, 100))
        assertFalse(p.applyRemoteSettingBool(ProfileStore.TS_SAVE, false, 50))
        assertTrue(p.saveMyPosts)
        assertTrue(p.applyRemoteSettingBool(ProfileStore.TS_SAVE_OTHERS, true, 5)); assertTrue(p.saveOthersPosts)
        assertTrue(p.applyRemoteSettingBool(ProfileStore.TS_OPT, false, 5)); assertFalse(p.autoOptimize)
        assertEquals(5L, p.settingTimestamp(ProfileStore.TS_OPT))
    }

    @Test fun remote_retention_applies_only_when_newer() {
        val p = ProfileStore.get(ctx)
        assertTrue(p.applyRemoteRetention(90, 200))
        assertEquals(90, p.retentionDays); assertEquals(200L, p.settingTimestamp(ProfileStore.TS_RET))
        assertFalse(p.applyRemoteRetention(7, 150)); assertEquals(90, p.retentionDays)
        assertEquals(90, fresh().retentionDays)
    }

    @Test fun reset_forgets_the_profile_and_every_stamp() {
        val p = ProfileStore.get(ctx)
        p.completeOnboarding("Ana", "🦊"); p.setRetention(30)
        p.reset()
        assertFalse(p.onboarded); assertEquals("", p.displayName); assertEquals("🌅", p.emoji)
        assertEquals(0L, p.fieldTimestamp("name")); assertEquals(0L, p.settingTimestamp(ProfileStore.TS_RET))
        assertTrue(ctx.prefs("haven.profile").data.isEmpty())
    }
}
