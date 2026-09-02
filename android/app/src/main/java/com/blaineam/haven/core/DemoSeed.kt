package com.blaineam.haven.core

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.util.Log
import com.blaineam.haven.BuildConfig
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.TrackRefFfi
import java.io.ByteArrayOutputStream

private const val TAG = "DemoSeed"

/**
 * Debug-only "demo mode": populates a lively, PII-free synthetic dataset so Play Store
 * screenshots aren't barren. A faithful port of the iOS [DemoSeeder] (apple/HavenApp/DemoSeed.swift).
 *
 * It drives the REAL hybrid-PQ social engine the same way the live app does: each fictional friend
 * is a full [HavenSocial] identity built from a deterministic 32-byte seed; they handshake into a
 * shared "default" circle with the user (addContactBundle / myBundle), author sealed posts /
 * stories / DMs, and those envelopes are receive()d into the user's engine — so the feed, stories
 * tray, DM threads, circle switcher, reactions, and comments are all genuinely populated, NOT faked.
 *
 * EVERYTHING here is gated on [BuildConfig.DEBUG] so it can never run in a release build.
 *
 * Launch flags (read from the Activity intent extras):
 *   haven_demo (bool)            seed the synthetic dataset + jump into the app
 *   haven_skip_onboarding (bool) implied true whenever haven_demo is on (no onboarding flow)
 *   haven_no_net (bool)          talk to NOTHING — no iroh node, no relay HTTP, no Multipeer-style
 *                                nearby, no push, no S3 (offline, fast, deterministic). Stands on
 *                                its own: it does NOT need haven_demo. See [HavenOffline].
 *   haven_tab (string)           which tab is selected at launch: circle | messages | you
 */
object DemoEnv {
    @Volatile var isDemo = false; private set
    @Volatile var skipOnboarding = false; private set
    @Volatile var tab: String? = null; private set

    /** Read launch flags from the Activity intent. No-op (everything off) in a release build.
     *
     *  There is deliberately no `noNet` field here any more: [HavenOffline] is the one place that
     *  answers "are we offline", and a second name for the same state is what let the old code read
     *  the flag in one branch and gate on it in another. */
    fun configure(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        // Tri-state on purpose: present-and-true, present-and-false, absent. Read BEFORE the demo
        // check — this used to sit below the `if (!isDemo) return`, so asking for an offline run
        // without also asking for the synthetic dataset silently did nothing, and the app went
        // online with the device's real identity.
        val asked: Boolean? =
            if (intent.hasExtra("haven_no_net")) intent.getBooleanExtra("haven_no_net", false) else null
        if (asked == true) HavenOffline.set(true)
        isDemo = intent.getBooleanExtra("haven_demo", false)
        if (!isDemo) return
        // Demo IMPLIES offline: a synthetic cast must never reach a real peer, and neither capture
        // script passes `haven_no_net` — so every Play Store screenshot used to be taken with the
        // node up and this device published to the public directory. `--ez haven_no_net false` is
        // still honoured, for a demo run that deliberately wants the wire.
        if (asked != false) HavenOffline.set(true)
        // Demo always skips onboarding so screenshots land straight in the populated app.
        skipOnboarding = intent.getBooleanExtra("haven_skip_onboarding", true)
        tab = intent.getStringExtra("haven_tab")
        Log.i(TAG, "demo on (tab=$tab offline=${HavenOffline.enabled})")
    }
}

object DemoSeeder {
    @Volatile private var didSeed = false

    /** Friend node ids + the second-circle name, for a (future) demo group-call overlay. */
    @Volatile var callParticipants: List<String> = emptyList(); private set
    const val callName = "Weekend Crew"

    /** A fictional person in the demo dataset. */
    private class Persona(
        val name: String,
        val emoji: String,
        val bio: String,
        val seedByte: Int,    // fills a deterministic 32-byte account seed
        val avatar: String,   // bundled demo avatar asset name (assets/demo/<avatar>.jpg)
    ) {
        var engine: HavenSocial? = null
        var hex: String = ""
    }

    /**
     * Seed the dataset once. Safe to call repeatedly (idempotent within a launch). Must be called
     * after [HavenNet.init] so the engine + LocalMedia are ready. Gated on DEBUG + demo flag.
     */
    fun seed(context: Context) {
        if (!BuildConfig.DEBUG || !DemoEnv.isDemo || didSeed || !HavenNet.isReady) return
        didSeed = true
        val main = HavenNet.engine

        // ── The user ("me") ───────────────────────────────────────────────────────────────
        val me = ProfileStore.get(context)
        me.displayName = "Riley Avery"
        me.emoji = "🌿"
        me.bio = "designer · plant hoarder · weekend hiker 🌄"
        me.link = "rileyavery.studio"
        me.save()
        me.setAvatar(avatarB64(context, "avatar-me"))   // my own photo avatar

        val mainHex = HavenNet.nodeIdHex
        runCatching { main.createCircle(DEFAULT_CIRCLE, "Your circle") }

        // The nudge is a PROBLEM state — "this circle has no relay yet". A seeded circle would
        // trip it (4 members, no relay), so every Play screenshot would open on a banner
        // advertising something missing. A relay is the normal setup, so the demo starts past it.
        RelayNudge.dismiss(DEFAULT_CIRCLE)

        // ── The cast ──────────────────────────────────────────────────────────────────────
        val people = listOf(
            Persona("Maya Quinn", "🌸", "ceramics & cold brew", 0xA1, "avatar-maya"),
            Persona("Theo Park", "🦊", "trail runner, map nerd", 0xB2, "avatar-theo"),
            Persona("Nina Brooks", "🦋", "film photography", 0xC3, "avatar-nina"),
            Persona("Sam Rivera", "🌊", "surf + sourdough", 0xD4, "avatar-sam"),
        )

        for (p in people) {
            val engine = runCatching { HavenSocial(seedData(p.seedByte)) }.getOrNull() ?: continue
            p.engine = engine
            runCatching { engine.createCircle(DEFAULT_CIRCLE, "Your circle") }
            // I learn their keys (so I can open their posts); they learn mine (so they can seal to me).
            val hex = runCatching { main.addContactBundle(DEFAULT_CIRCLE, engine.myBundle()) }.getOrNull() ?: ""
            runCatching { engine.addContactBundle(DEFAULT_CIRCLE, main.myBundle()) }
            p.hex = hex
            if (hex.isEmpty()) continue
            HavenNet.demoAddContact(hex, p.name, runCatching { engine.verificationHex() }.getOrNull() ?: "")
            AvatarStore.put(hex, avatarB64(context, p.avatar), p.emoji)   // real photo avatars in demo
        }
        val valid = people.filter { it.engine != null && it.hex.isNotEmpty() }
        callParticipants = valid.take(3).map { it.hex }

        // ── Demo media (the same real, PII-free photos iOS bundles) ─────────────────────────
        installPhotos(context)
        installVideos(context)

        // ── Stories tray (two friends + me) ─────────────────────────────────────────────────
        story(main, valid.getOrNull(0), listOf("img_demo_sunset"), "golden hour at the cove 🌅", mins(40))
        story(main, valid.getOrNull(1), listOf("img_demo_ridge"), "made it to the ridge 🥾", mins(95))
        // My own story.
        runCatching {
            main.post(DEFAULT_CIRCLE, "studio fuel ☕️", listOf("img_demo_coffee"), null,
                86_400UL, true, false, msAgo(mins(20)))
        }

        // ── The circle feed: a lively multi-author mix with reactions + comments ────────────
        val p1 = friendPost(main, valid, 0, "first throw off the new wheel 🪴 obsessed",
            listOf("img_demo_pottery"), null, mins(180))
        val p2 = friendPost(main, valid, 1, "12 miles before breakfast. trail magic is real.",
            listOf("img_demo_trail"), track("Sunrun", "The Wanderers"), mins(140))
        val p3 = myPost(main, "new little corner of the studio came together today 🌿",
            listOf("img_demo_plant"), mins(75))
        // Two ADJACENT video posts + a mixed carousel — the feed autoplays only the centred card's
        // visible page, so this is what makes that coordinator visible in the demo.
        myPost(main, "the cove at golden hour, on repeat 🌊", listOf("vid_demo_cove"), mins(58))
        myPost(main, "ridge wind — sound off, obviously 🏔️", listOf("vid_demo_ridge"), mins(52))
        myPost(main, "a clip and a still from the same afternoon",
            listOf("img_demo_sunset", "vid_demo_cove"), mins(46))
        val p4 = friendPost(main, valid, 2, "everyone, meet the newest member of the crew 🐾",
            listOf("img_demo_pup"), null, mins(30))
        val p5 = friendPost(main, valid, 3, "sunday slow brunch — the sourdough finally rose 🍞",
            listOf("img_demo_brunch"), null, mins(12))

        // Reactions + comments fan in from the circle.
        react(main, valid, p1, "🔥", listOf(1, 2, 3))
        react(main, valid, p1, "🪴", listOf(0))
        comment(main, valid, p1, 1, "the glaze on this!! 😍", mins(170))
        comment(main, valid, p1, 3, "teach me your ways", mins(165))

        react(main, valid, p2, "👟", listOf(0, 2))
        comment(main, valid, p2, 0, "those views are unreal", mins(130))

        react(main, valid, p3, "🌿", listOf(0, 1, 2, 3))
        comment(main, valid, p3, 2, "cozy!! love the light in here", mins(60))

        react(main, valid, p4, "🐶", listOf(0, 1, 3))
        react(main, valid, p4, "❤️", listOf(2))
        comment(main, valid, p4, 0, "the FLOOF 😭🐾", mins(24))

        react(main, valid, p5, "🤤", listOf(0, 2))

        // ── A second circle, so the switcher is populated ───────────────────────────────────
        val crew = "demo-weekend-crew"
        runCatching { main.createCircle(crew, "Weekend Crew") }
        for (p in valid.take(3)) {
            runCatching { main.addExistingToCircle(crew, p.hex) }
            runCatching { p.engine?.createCircle(crew, "Weekend Crew") }
            runCatching { p.engine?.addContactBundle(crew, main.myBundle()) }
        }
        valid.firstOrNull()?.engine?.let { e ->
            runCatching {
                e.post(crew, "who's in for the cabin this weekend? ⛰️", emptyList(), null,
                    null, false, false, msAgo(mins(220)))
            }.getOrNull()?.let { env -> runCatching { main.receive(crew, env) } }
        }
        runCatching {
            main.post(crew, "me!! bringing the sourdough 🍞", emptyList(), null,
                null, false, false, msAgo(mins(210)))
        }

        // ── DM threads (each DM is a private 2-person circle) ───────────────────────────────
        valid.getOrNull(0)?.let {
            seedDm(main, mainHex, it, listOf(
                DmLine(false, "did you see the new kiln schedule?", mins(300), null),
                DmLine(true, "yes! booked us both for saturday 🔥", mins(298), null),
                DmLine(false, "you're the best. coffee after?", mins(295), null),
                DmLine(true, "always ☕️", mins(292), track("Slow Morning", "Wax & Wane")),
            ))
        }
        valid.getOrNull(1)?.let {
            seedDm(main, mainHex, it, listOf(
                DmLine(false, "trail conditions look perfect for sunday", mins(500), null),
                DmLine(true, "sending the gpx now 🗺️", mins(496), null),
                DmLine(false, "🙌", mins(495), null),
            ))
        }

        HavenNet.demoPersist()
        HavenNet.demoMarkConnected()
        HavenNet.demoRefresh()
        Log.i(TAG, "seeded ${valid.size} friends, 2 circles, ${callParticipants.size} call participants")
    }

    // MARK: - Authoring helpers

    /**
     * Replay a friend's whole sync bundle (their key commit + re-sealed events) into my engine,
     * exactly like a real hello back-fill does.
     *
     * An epoch-sealed event can only be opened with the AUTHOR's key commit, so handing `receive`
     * a bare post envelope silently fails to open — the post is accepted and then never appears.
     * That's why the demo cast was invisible: the feed had 3 posts instead of 8, and every seeded
     * reaction/comment was a no-op. Apple hit this same bug when group keying landed (see
     * DemoSeed.swift's replayIntoMain); this is the Kotlin port of that fix.
     */
    private fun replayIntoMain(main: HavenSocial, friend: HavenSocial, circleId: String = DEFAULT_CIRCLE) {
        runCatching { friend.syncEnvelopes(circleId) }.getOrDefault(emptyList())
            .forEach { env -> runCatching { main.receive(circleId, env) } }
    }

    /** A friend authors a post into the default circle; it's received into my engine. Returns the post id. */
    private fun friendPost(
        main: HavenSocial, valid: List<Persona>, by: Int, body: String,
        media: List<String>, music: TrackRefFfi?, minutesAgo: Int,
    ): String? {
        val engine = valid.getOrNull(by)?.engine ?: return null
        val ts = msAgo(minutesAgo)
        runCatching {
            engine.post(DEFAULT_CIRCLE, body, media, music, null, false, false, ts)
        }.getOrNull() ?: return null
        replayIntoMain(main, engine)
        return idForCreatedAt(main, ts)
    }

    /** I author a post into the default circle. Returns its id. */
    private fun myPost(main: HavenSocial, body: String, media: List<String>, minutesAgo: Int): String? {
        val ts = msAgo(minutesAgo)
        runCatching {
            main.post(DEFAULT_CIRCLE, body, media, null, null, false, false, ts)
        }.getOrNull() ?: return null
        return idForCreatedAt(main, ts)
    }

    /** Friends react to a target post. [by] are indices into [valid]. */
    private fun react(main: HavenSocial, valid: List<Persona>, id: String?, emoji: String, by: List<Int>) {
        if (id == null) return
        for (i in by) {
            val engine = valid.getOrNull(i)?.engine ?: continue
            ensureHasCircleHistory(main, engine)
            runCatching { engine.react(DEFAULT_CIRCLE, id, emoji, msAgo(mins(5))) }.getOrNull() ?: continue
            replayIntoMain(main, engine)
        }
    }

    private fun comment(main: HavenSocial, valid: List<Persona>, id: String?, by: Int, body: String, minutesAgo: Int) {
        if (id == null) return
        val engine = valid.getOrNull(by)?.engine ?: return
        ensureHasCircleHistory(main, engine)
        runCatching { engine.comment(DEFAULT_CIRCLE, id, body, emptyList(), msAgo(minutesAgo)) }.getOrNull() ?: return
        replayIntoMain(main, engine)
    }

    /**
     * Replay my whole default-circle history into a friend's engine so they can react/comment.
     *
     * This runs AFTER friendPost already replayed that friend into main, and receiving my commits can
     * advance the friend's epoch — leaving main holding a STALE commit for them. So every caller must
     * replayIntoMain AGAIN once the friend authors, or the reaction/comment is accepted and then never
     * opens (the same epoch-seal trap replayIntoMain exists for). Missing that is why the demo feed
     * showed zero reaction chips and zero seeded comments.
     */
    private fun ensureHasCircleHistory(main: HavenSocial, friend: HavenSocial) {
        for (env in runCatching { main.syncEnvelopes(DEFAULT_CIRCLE) }.getOrDefault(emptyList())) {
            runCatching { friend.receive(DEFAULT_CIRCLE, env) }
        }
    }

    private fun story(main: HavenSocial, persona: Persona?, refs: List<String>, caption: String, minutesAgo: Int) {
        val engine = persona?.engine ?: return
        runCatching {
            engine.post(DEFAULT_CIRCLE, caption, refs, null, 86_400UL, true, false, msAgo(minutesAgo))
        }.getOrNull() ?: return
        replayIntoMain(main, engine)   // commit + re-sealed events (see replayIntoMain)
    }

    private class DmLine(val mine: Boolean, val body: String, val mins: Int, val music: TrackRefFfi?)

    /** Build a two-person DM circle and a short back-and-forth thread. */
    private fun seedDm(main: HavenSocial, mainHex: String, friend: Persona, lines: List<DmLine>) {
        val engine = friend.engine ?: return
        val dmId = "dm:" + listOf(mainHex, friend.hex).sorted().joinToString("-")
        runCatching { main.createCircle(dmId, friend.name) }
        runCatching { main.addExistingToCircle(dmId, friend.hex) }
        runCatching { engine.createCircle(dmId, "Riley Avery") }
        runCatching { engine.addContactBundle(dmId, main.myBundle()) }
        for (line in lines) {
            val ts = msAgo(line.mins)
            if (line.mine) {
                runCatching { main.post(dmId, line.body, emptyList(), line.music, null, false, false, ts) }
            } else {
                runCatching {
                    engine.post(dmId, line.body, emptyList(), line.music, null, false, false, ts)
                }.getOrNull() ?: continue
                replayIntoMain(main, engine, dmId)   // epoch-sealed: needs their key commit too
            }
        }
    }

    // MARK: - Small utilities

    private fun idForCreatedAt(main: HavenSocial, ts: ULong): String? =
        runCatching { main.feed(DEFAULT_CIRCLE, nowMs(), null) }.getOrDefault(emptyList())
            .firstOrNull { it.createdAt == ts }?.id

    private fun track(title: String, artist: String): TrackRefFfi =
        TrackRefFfi(catalogId = "demo-$title", title = title, artist = artist, artworkUrl = "", durationMs = 192_000UL)

    private fun mins(m: Int): Int = m
    private fun msAgo(minutesAgo: Int): ULong =
        (maxOf(0.0, System.currentTimeMillis() / 1000.0 - minutesAgo * 60.0) * 1000.0).toLong().toULong()

    /** A deterministic 32-byte account seed from a single distinguishing byte. */
    private fun seedData(b: Int): ByteArray =
        ByteArray(32) { i -> ((b + i) and 0xFF).toByte() }

    // MARK: - Demo art (synthetic, PII-free gradient "photos")

    /** ref → a (hue, accent-hue) pair so each demo photo is a distinct soft gradient. */
    private val photoHues: List<Pair<String, Pair<Float, Float>>> = listOf(
        "img_demo_sunset" to (18f to 330f),   // amber → magenta dusk
        "img_demo_ridge" to (205f to 250f),   // blue ridge
        "img_demo_pottery" to (28f to 12f),   // terracotta
        "img_demo_trail" to (110f to 80f),    // forest greens
        "img_demo_plant" to (140f to 95f),    // leafy green
        "img_demo_pup" to (35f to 20f),       // warm tan
        "img_demo_coffee" to (30f to 22f),    // espresso
        "img_demo_brunch" to (45f to 18f),    // golden crust
    )

    /**
     * Install the demo photos into LocalMedia under the fixed refs. Loads the SAME bundled,
     * royalty-free, PII-free photos iOS uses (apple/HavenApp/DemoAssets → android debug
     * assets/demo/), falling back to a synthetic gradient only if an asset is missing. Always
     * (re)writes so it replaces any gradient from an older demo run.
     */
    private fun installPhotos(context: Context) {
        for ((ref, hues) in photoHues) {
            val asset = "demo/photo-" + ref.removePrefix("img_demo_") + ".jpg"
            val bytes = runCatching { context.assets.open(asset).use { it.readBytes() } }.getOrNull()
                ?: gradientJpeg(hues.first, hues.second)
            LocalMedia.storeUnderRef(DEFAULT_CIRCLE, ref, bytes)
        }
    }

    /**
     * Install the demo VIDEOS under fixed `vid_` refs — synthetic, silent gradient clips (no people,
     * no audio, no PII). One portrait + one landscape, so the feed's inline autoplay is exercised
     * both letterboxing onto its blurred backdrop and filling the page.
     *
     * "ridge" deliberately ALSO exists as a photo (`img_demo_ridge`, above) — that img_/vid_ pair on
     * one name is what caught LocalMedia keying its files by the kind-stripped ref, serving the video
     * for both. Keep both variants so the demo keeps covering that collision.
     */
    private fun installVideos(context: Context) {
        for (name in listOf("cove", "ridge")) {
            val bytes = runCatching { context.assets.open("demo/video-$name.mp4").use { it.readBytes() } }.getOrNull()
                ?: continue   // no asset → simply no video post; never a broken ref
            LocalMedia.storeUnderRef(DEFAULT_CIRCLE, "vid_demo_$name", bytes)
        }
    }

    /** Base64 of a bundled demo avatar JPEG (assets/demo/<name>.jpg), or "" if missing. */
    private fun avatarB64(context: Context, asset: String): String =
        runCatching {
            android.util.Base64.encodeToString(context.assets.open("demo/$asset.jpg").use { it.readBytes() }, android.util.Base64.NO_WRAP)
        }.getOrDefault("")

    /** A soft two-tone diagonal gradient JPEG — clearly synthetic, contains no people / PII. */
    private fun gradientJpeg(hueA: Float, hueB: Float, w: Int = 1080, h: Int = 1350): ByteArray {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val top = Color.HSVToColor(floatArrayOf(hueA, 0.45f, 0.92f))
        val bottom = Color.HSVToColor(floatArrayOf(hueB, 0.55f, 0.55f))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), top, bottom, Shader.TileMode.CLAMP)
        }
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        // A soft highlight blob so it reads as an abstract photo, not a flat fill.
        val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = android.graphics.RadialGradient(
                w * 0.7f, h * 0.3f, w * 0.6f,
                Color.argb(90, 255, 255, 255), Color.argb(0, 255, 255, 255), Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), glow)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
        return out.toByteArray()
    }
}
