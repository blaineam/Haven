package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.SignedCallFrame
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/**
 * The call signalling state machine: which inbound frames ring the phone, which are refused and why, how a call
 * is torn down, and what goes back out. Everything that needs a live WebRTC stack (the peer connections, the
 * camera, the audio route) is out of reach of a JVM test, so these drive the part that decides things — the frame
 * handlers — directly, with the engine and relay faked. The call thread's Handler is a recording double: work posted
 * to it runs when a test drains it.
 */
@Suppress("UNCHECKED_CAST")
class CallManagerSignalingTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val other = "c4".repeat(32)
    private val stranger = "c5".repeat(32)
    private val cm = CallManager::class.java

    private fun f(name: String) = cm.getDeclaredField(name).apply { isAccessible = true }
    private fun invoke(name: String, vararg args: Any?): Any? {
        val m = cm.declaredMethods.first { it.name == name && it.parameterCount == args.size }.apply { isAccessible = true }
        return try { m.invoke(CallManager, *args) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun handle(type: Int, body: ByteArray?) = invoke("handle", type, body)
    private fun drain() { val h = f("callHandler").get(CallManager); try { h.javaClass.getMethod("drain").invoke(h) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException } }
    private fun drainAll() { val h = f("callHandler").get(CallManager); try { h.javaClass.getMethod("drainAll").invoke(h) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException } }
    private fun pending(): Int { val h = f("callHandler").get(CallManager); return h.javaClass.getMethod("pendingCount").invoke(h) as Int }
    private fun lane() { (f("sendLane").get(CallManager) as ExecutorService).submit {}.get(10, TimeUnit.SECONDS) }
    private fun sealedTypes() = env.social.sealedCalls.map { it.second.toInt() to it.first }

    private fun ended() = f("endedSessions").get(CallManager) as MutableMap<String, Long>

    private val sid = "sess-0001"
    private fun invite(from: String = peer, session: String = sid, name: String = "Family call",
                       roster: List<String> = listOf(from, env.me), sentAt: Long = System.currentTimeMillis() / 1000) =
        CallWire.groupInvite(from, session, name, roster.joinToString(","), sentAt)

    @Before fun setUp() {
        env.up()
        env.social.sealCall = { _, _, d -> byteArrayOf(9) + d }
        f("appContext").set(CallManager, env.ctx)
        f("myHex").set(CallManager, env.me)
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
        HavenNet.contacts.add(Contact(other, "Sam", "v"))
        resetCall()
    }
    @After fun tearDown() { resetCall(); env.down() }

    private fun resetCall() {
        invoke("teardown")
        drainAll()
        ended().clear()
        f("lastPeerSeenMs").setLong(CallManager, 0L)
        f("mediaStarted").setBoolean(CallManager, false)
        CallManager.micOn.value = true; CallManager.speakerOn.value = true
        env.social.sealedCalls.clear()
    }

    // ---- ringing ------------------------------------------------------------------------------

    @Test fun a_frame_that_cannot_be_opened_is_recorded_and_changes_nothing() {
        handle(CallWire.GROUP_INVITE, null)
        assertEquals("recv-unopenable:${CallWire.GROUP_INVITE}", CallManager.qaLastCallEvent)
        assertFalse(CallManager.ringing.value)
    }

    @Test fun a_group_invite_from_a_contact_rings_with_the_roster_and_arms_the_ring_timeout() {
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, other, env.me)))
        assertTrue(CallManager.ringing.value)
        assertTrue(CallManager.callInProgress)
        assertEquals("Family call", CallManager.peerName.value)
        assertEquals(sid, CallManager.qaSessionId)
        assertEquals(listOf(peer, other).sorted(), CallManager.participants.toList())
        assertEquals("recv:${CallWire.GROUP_INVITE}", CallManager.qaLastCallEvent)
        assertEquals("the bounded ring (a hangup that never arrives must not ring forever)", 1, pending())
        drain()
        assertTrue("armed, not fired: it is a 60 s timeout", CallManager.ringing.value)
    }

    @Test fun an_unnamed_group_call_is_titled_group_call() {
        handle(CallWire.GROUP_INVITE, invite(name = "", roster = listOf(peer, other, env.me)))
        assertEquals("Group call", CallManager.peerName.value)
    }

    @Test fun a_one_to_one_call_is_titled_by_the_caller_not_by_the_title_the_caller_sent() {
        // The sender names the thread as THEY see it — for a 1:1 that is the callee's own name.
        handle(CallWire.GROUP_INVITE, invite(name = "Me (callee)", roster = listOf(peer, env.me)))
        assertEquals("Pat", CallManager.peerName.value)
    }

    @Test fun an_invite_from_someone_who_is_not_a_contact_never_rings() {
        handle(CallWire.GROUP_INVITE, invite(from = stranger, roster = listOf(stranger, env.me)))
        assertFalse(CallManager.ringing.value)
    }

    @Test fun an_unparseable_invite_is_dropped() {
        handle(CallWire.GROUP_INVITE, ByteArray(10))
        assertFalse(CallManager.ringing.value)
    }

    @Test fun a_relay_replayed_stale_invite_does_not_ring_but_one_still_inside_the_window_does() {
        val now = System.currentTimeMillis() / 1000
        handle(CallWire.GROUP_INVITE, invite(sentAt = now - 400))
        assertFalse("the caller stopped dialing long ago", CallManager.ringing.value)
        handle(CallWire.GROUP_INVITE, invite(sentAt = now - 100))
        assertTrue(CallManager.ringing.value)
    }

    @Test fun a_legacy_one_to_one_invite_rings_with_the_callers_name() {
        val body = peer.toByteArray() + "Pat".toByteArray()
        handle(CallWire.INVITE, body)
        assertTrue(CallManager.ringing.value)
        assertEquals("Pat", CallManager.peerName.value)
        assertEquals("legacy:$peer", CallManager.qaSessionId)
    }

    @Test fun a_legacy_invite_from_a_stranger_is_ignored() {
        handle(CallWire.INVITE, stranger.toByteArray() + "Eve".toByteArray())
        assertFalse(CallManager.ringing.value)
    }

    @Test fun a_second_invite_while_ringing_for_the_same_session_merges_the_roster_and_another_session_is_ignored() {
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, env.me)))
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, other, env.me)))
        assertEquals(listOf(peer, other).sorted(), CallManager.participants.toList())
        handle(CallWire.GROUP_INVITE, invite(from = other, session = "another", roster = listOf(other, env.me)))
        assertEquals("the first call keeps the line", sid, CallManager.qaSessionId)
    }

    @Test fun a_legacy_invite_while_already_in_a_call_just_adds_the_sender() {
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, env.me)))
        handle(CallWire.INVITE, other.toByteArray() + "Sam".toByteArray())
        assertTrue(CallManager.participants.contains(other))
        assertEquals(sid, CallManager.qaSessionId)
    }

    // ---- ending -------------------------------------------------------------------------------

    @Test fun the_callers_hangup_ends_a_ringing_call_and_the_session_is_tombstoned_against_a_re_ring() {
        handle(CallWire.GROUP_INVITE, invite())
        handle(CallWire.HANGUP, CallWire.hangup(peer, sid))
        assertFalse(CallManager.ringing.value)
        assertEquals("", CallManager.qaSessionId)
        assertTrue(ended().containsKey(sid))
        handle(CallWire.GROUP_INVITE, invite())
        assertFalse("a retransmitted invite for a call we already left must not re-ring", CallManager.ringing.value)
    }

    @Test fun a_late_hangup_from_an_earlier_call_does_not_end_this_one() {
        handle(CallWire.GROUP_INVITE, invite())
        handle(CallWire.HANGUP, CallWire.hangup(peer, "an-older-session"))
        assertTrue(CallManager.ringing.value)
    }

    @Test fun a_hangup_from_a_sender_that_predates_session_ids_still_applies() {
        handle(CallWire.GROUP_INVITE, invite())
        handle(CallWire.HANGUP, peer.toByteArray())
        assertFalse(CallManager.ringing.value)
    }

    @Test fun one_participant_leaving_a_group_call_keeps_it_going_for_the_others() {
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, other, env.me)))
        handle(CallWire.HANGUP, CallWire.hangup(peer, sid))
        assertTrue(CallManager.ringing.value)
        assertEquals(listOf(other), CallManager.participants.toList())
    }

    @Test fun answering_on_another_of_my_devices_silences_this_ring_but_only_from_my_own_account() {
        handle(CallWire.GROUP_INVITE, invite())
        handle(CallWire.HANDLED_ELSEWHERE, CallWire.handledElsewhere(peer, sid))
        assertTrue("only MY account may silence my ring", CallManager.ringing.value)
        handle(CallWire.HANDLED_ELSEWHERE, CallWire.handledElsewhere(env.me, "wrong-session"))
        assertTrue(CallManager.ringing.value)
        handle(CallWire.HANDLED_ELSEWHERE, CallWire.handledElsewhere(env.me, sid))
        assertFalse(CallManager.ringing.value)
        assertTrue("and a retransmitted invite must not re-ring", ended().containsKey(sid))
    }

    @Test fun handled_elsewhere_never_hangs_up_a_call_already_answered_here() {
        handle(CallWire.GROUP_INVITE, invite())
        CallManager.inCall.value = true
        handle(CallWire.HANDLED_ELSEWHERE, CallWire.handledElsewhere(env.me, sid))
        assertTrue(CallManager.inCall.value)
    }

    @Test fun ending_a_call_on_another_of_my_devices_tears_down_even_an_answered_call() {
        handle(CallWire.GROUP_INVITE, invite())
        CallManager.ringing.value = false; CallManager.inCall.value = true
        handle(CallWire.ENDED_ELSEWHERE, CallWire.handledElsewhere(peer, sid))
        assertTrue("not my account: ignored", CallManager.inCall.value)
        handle(CallWire.ENDED_ELSEWHERE, CallWire.handledElsewhere(env.me, "another"))
        assertTrue("not this session: ignored", CallManager.inCall.value)
        handle(CallWire.ENDED_ELSEWHERE, CallWire.handledElsewhere(env.me, sid))
        assertFalse(CallManager.inCall.value)
    }

    @Test fun an_in_call_state_with_no_session_is_cleared_by_my_accounts_end_frame() {
        CallManager.inCall.value = true
        handle(CallWire.ENDED_ELSEWHERE, CallWire.handledElsewhere(env.me, "whatever"))
        assertFalse(CallManager.inCall.value)
    }

    @Test fun a_ring_nobody_answers_ends_as_missed() {
        handle(CallWire.GROUP_INVITE, invite())
        invoke("ringTimedOut")
        assertFalse(CallManager.ringing.value)
        assertTrue(ended().containsKey(sid))
    }

    @Test fun a_ring_timeout_after_the_call_was_answered_does_nothing() {
        handle(CallWire.GROUP_INVITE, invite())
        CallManager.inCall.value = true
        invoke("ringTimedOut")
        assertTrue(CallManager.inCall.value)
    }

    @Test fun an_old_tombstone_no_longer_suppresses_a_fresh_invite() {
        ended()[sid] = System.currentTimeMillis() - 10 * 60_000L
        handle(CallWire.GROUP_INVITE, invite())
        assertTrue(CallManager.ringing.value)
    }

    // ---- answering and declining --------------------------------------------------------------

    @Test fun answering_a_call_that_is_not_there_is_not_an_answer() {
        CallManager.accept(); drain()
        assertFalse(CallManager.inCall.value)
        CallManager.inCall.value = true
        CallManager.accept(); drain()
        assertTrue("already answered: ignored", CallManager.inCall.value)
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun answering_tells_the_caller_and_stands_my_other_devices_down() {
        env.social.deviceIds[env.me] = listOf(env.device, "d2".repeat(32))
        handle(CallWire.GROUP_INVITE, invite())
        CallManager.accept()
        // Media setup needs the WebRTC stack, which a JVM test cannot load: the answer is signalled first.
        runCatching { drain() }
        lane()
        assertTrue(CallManager.inCall.value)
        assertFalse(CallManager.ringing.value)
        assertTrue("ACCEPT to the caller", sealedTypes().contains(CallWire.ACCEPT to peer))
        assertTrue("handled-elsewhere to my sibling device", sealedTypes().contains(CallWire.HANDLED_ELSEWHERE to "d2".repeat(32)))
    }

    @Test fun declining_hangs_up_three_times_to_survive_a_dropped_frame_and_tells_my_other_devices() {
        env.social.deviceIds[env.me] = listOf(env.device, "d2".repeat(32))
        handle(CallWire.GROUP_INVITE, invite())
        CallManager.decline()
        drain()      // the hangup itself
        drainAll()   // and its two delayed retransmissions
        lane()
        assertFalse(CallManager.ringing.value)
        assertEquals(3, sealedTypes().count { it == CallWire.HANGUP to peer })
        assertTrue(sealedTypes().contains(CallWire.ENDED_ELSEWHERE to "d2".repeat(32)))
    }

    // ---- placing and growing a call -----------------------------------------------------------

    @Test fun placing_a_call_while_one_is_already_up_adds_the_people_instead() {
        handle(CallWire.GROUP_INVITE, invite(roster = listOf(peer, env.me)))
        CallManager.startCall(listOf(other), "ignored")
        drain()
        assertEquals(sid, CallManager.qaSessionId)
        assertTrue(CallManager.participants.contains(other))
    }

    @Test fun adding_someone_to_a_call_re_broadcasts_the_roster_to_everyone() {
        f("sessionId").set(CallManager, sid)
        CallManager.connecting.value = true
        (f("roster").get(CallManager) as MutableSet<String>).addAll(listOf(env.me, peer))
        CallManager.addToCall(listOf(other, env.me, peer)); drain(); lane()
        val toWhom = env.social.sealedCalls.filter { it.second.toInt() == CallWire.GROUP_INVITE }.map { it.first }.toSet()
        assertEquals(setOf(peer, other).sorted(), toWhom.sorted())
        assertTrue(CallManager.participants.containsAll(listOf(peer, other)))
    }

    @Test fun adding_to_a_call_that_is_not_up_or_adding_nobody_new_does_nothing() {
        CallManager.addToCall(listOf(other)); drain()
        assertTrue(env.social.sealedCalls.isEmpty())
        f("sessionId").set(CallManager, sid)
        CallManager.connecting.value = true
        (f("roster").get(CallManager) as MutableSet<String>).addAll(listOf(env.me, other))
        CallManager.addToCall(listOf(other)); drain(); lane()
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun only_contacts_not_already_in_the_call_and_not_blocked_can_be_added() {
        val third = "c6".repeat(32)
        HavenNet.contacts.add(Contact(third, "Lee", "v"))
        HavenNet.contacts.add(Contact(env.me, "Me", "v"))
        HavenNet.blocked.add(third)
        CallManager.participants.add(peer)
        assertEquals(listOf(other), CallManager.addableContacts().map { it.idHex })
    }

    // ---- in-call frames that need no media stack ------------------------------------------------

    @Test fun a_participants_camera_state_drives_the_avatar_placeholder_and_a_strangers_does_not() {
        handle(CallWire.GROUP_INVITE, invite())
        handle(CallWire.CAMERA, CallWire.cameraState(peer, sid, on = false))
        assertEquals(listOf(peer), CallManager.remoteCameraOff.toList())
        handle(CallWire.CAMERA, CallWire.cameraState(peer, sid, on = false))
        assertEquals("not listed twice", listOf(peer), CallManager.remoteCameraOff.toList())
        handle(CallWire.CAMERA, CallWire.cameraState(stranger, sid, on = false))
        assertEquals(listOf(peer), CallManager.remoteCameraOff.toList())
        handle(CallWire.CAMERA, CallWire.cameraState(peer, sid, on = true))
        assertTrue(CallManager.remoteCameraOff.isEmpty())
    }

    @Test fun signalling_for_the_wrong_session_or_from_a_non_participant_is_refused_before_any_media_starts() {
        handle(CallWire.GROUP_INVITE, invite())
        val sdp = CallSignal.encodeSdp("offer", "v=0")
        handle(CallWire.OFFER, CallWire.signal(peer, "wrong", sdp))
        handle(CallWire.OFFER, CallWire.signal(stranger, sid, sdp))
        handle(CallWire.ANSWER, CallWire.signal(peer, "wrong", CallSignal.encodeSdp("answer", "v=0")))
        handle(CallWire.ICE, CallWire.signal(stranger, sid, CallSignal.encodeCandidate("candidate:1", 0, "0")))
        handle(CallWire.ACCEPT, CallWire.accept(peer, "wrong"))
        handle(CallWire.ACCEPT, CallWire.accept(stranger, sid))
        assertFalse("nothing in this state may start a mesh", f("mediaStarted").getBoolean(CallManager))
        assertFalse(CallManager.inCall.value)
    }

    @Test fun no_session_means_no_negotiation() {
        handle(CallWire.OFFER, CallWire.signal(peer, "", CallSignal.encodeSdp("offer", "v=0")))
        assertFalse(f("mediaStarted").getBoolean(CallManager))
    }

    @Test fun a_call_with_no_peers_for_45_seconds_is_ended() {
        CallManager.inCall.value = true
        invoke("checkStuckCall")
        assertTrue("first sighting only starts the clock", CallManager.inCall.value)
        f("lastPeerSeenMs").setLong(CallManager, System.currentTimeMillis() - 60_000)
        CallManager.noticeStuckCall(); drain(); drain()
        assertFalse(CallManager.inCall.value)
    }

    @Test fun a_call_that_is_not_up_resets_the_stuck_clock() {
        f("lastPeerSeenMs").setLong(CallManager, 123L)
        invoke("checkStuckCall")
        assertEquals(0L, f("lastPeerSeenMs").getLong(CallManager))
    }

    // ---- controls ---------------------------------------------------------------------------------

    @Test fun the_mic_and_speaker_toggles_run_on_the_call_thread() {
        CallManager.toggleMic(); CallManager.toggleSpeaker()
        assertTrue("nothing happens until the call thread runs it", CallManager.micOn.value && CallManager.speakerOn.value)
        drain()
        assertFalse(CallManager.micOn.value); assertFalse(CallManager.speakerOn.value)
        CallManager.toggleMic(); drain()
        assertTrue(CallManager.micOn.value)
        assertFalse(CallManager.isOnCallThread())
    }

    @Test fun the_active_speaker_needs_two_consecutive_polls_and_clears_on_silence() {
        invoke("resolveActiveSpeaker", peer, 0.5, 0.0)
        assertNull("one loud poll is a blip", CallManager.activeSpeaker.value)
        invoke("resolveActiveSpeaker", peer, 0.5, 0.0)
        assertEquals(peer, CallManager.activeSpeaker.value)
        invoke("resolveActiveSpeaker", peer, 0.0, 0.0)
        assertNull(CallManager.activeSpeaker.value)
        repeat(2) { invoke("resolveActiveSpeaker", "", 0.1, 0.4) }
        assertEquals("my own voice is the loudest: the highlight is mine", "", CallManager.activeSpeaker.value)
        CallManager.micOn.value = false
        invoke("resolveActiveSpeaker", peer, 0.01, 0.4)
        assertNull("a muted mic cannot be the speaker", CallManager.activeSpeaker.value)
    }

    @Test fun a_one_to_one_call_does_not_poll_audio_levels() {
        CallManager.activeSpeaker.value = peer
        invoke("pollAudioLevels")
        assertNull(CallManager.activeSpeaker.value)
    }

    @Test fun audio_routes_are_named_for_the_qa_dump() {
        assertEquals("speaker", invoke("routeName", android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals("earpiece", invoke("routeName", android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertEquals("wired", invoke("routeName", android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET))
        assertEquals("wired", invoke("routeName", android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES))
        assertEquals("bluetooth", invoke("routeName", android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals("usb", invoke("routeName", android.media.AudioDeviceInfo.TYPE_USB_HEADSET))
        assertEquals("usb", invoke("routeName", android.media.AudioDeviceInfo.TYPE_USB_DEVICE))
        assertEquals("type:99", invoke("routeName", 99))
        assertEquals("none", invoke("routeName", arrayOf<Any?>(null)[0]))
        assertTrue(invoke("isExternalRoute", android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO) as Boolean)
        assertFalse(invoke("isExternalRoute", android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) as Boolean)
    }

    // ---- sealed frames ----------------------------------------------------------------------------

    private fun opens(sender: String, plaintext: ByteArray) {
        env.social.openCall = { _, _ -> SignedCallFrame(sender, plaintext) }
    }
    private val body = peer.toByteArray() + byteArrayOf(1, 2, 3)

    @Test fun a_verified_frame_is_opened_to_its_plaintext() {
        opens(peer, body)
        assertEquals(body.toList(), CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0))!!.toList())
    }

    @Test fun a_frame_the_engine_cannot_open_or_that_is_too_short_is_dropped() {
        assertNull("no engine answer", CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
        opens(peer, ByteArray(10))
        assertNull(CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
        opens("short", body)
        assertNull(CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
    }

    @Test fun a_frame_whose_declared_sender_is_not_the_proven_signer_is_a_forgery_unless_the_device_belongs_to_the_account() {
        val device = "d9".repeat(32)
        opens(device, body)   // signed by a device key, but the frame names the ACCOUNT peer
        assertNull(CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
        env.social.accountOfDevice[device] = other
        assertNull("the device belongs to someone else", CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
        env.social.accountOfDevice[device] = peer
        assertEquals("a seedless device signs for its account", body.toList(), CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0))!!.toList())
    }

    @Test fun a_frame_from_a_blocked_sender_is_dropped() {
        opens(peer, body)
        HavenNet.blocked.add(peer)
        assertNull(CallManager.openSealed(CallWire.ACCEPT, byteArrayOf(0)))
    }

    @Test fun a_sealed_send_reaches_the_relays_live_lane_and_an_unsealable_one_sends_nothing() {
        val landed = env.relay.latchForPuts(1)
        CallManager.sealedSend(CallWire.ACCEPT, byteArrayOf(5), peer)
        assertTrue(env.relay.awaitPuts(landed))
        assertTrue(env.relay.store.keys.any { it.contains("/__live__/$peer/") })
        env.social.sealCall = { _, _, _ -> ByteArray(0) }
        env.relay.hits.clear()
        CallManager.sealedSend(CallWire.ACCEPT, byteArrayOf(6), peer)
        lane()
        assertTrue("no plaintext fallback: if sealing fails nothing is sent", env.relay.puts().isEmpty())
    }
}
