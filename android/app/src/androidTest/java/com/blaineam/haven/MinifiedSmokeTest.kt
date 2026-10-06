package com.blaineam.haven

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Smoke tests for the R8-MINIFIED build — the release configuration, run on a device.
 *
 * Every step below crosses into the Rust core through JNA/UniFFI (identity generation, sealing a
 * post, sealing media, opening the feed, a DM's epoch-sealed thread, call signalling) or through
 * JNI (NativeBridge), which is exactly where a missing keep rule turns into a release-only crash.
 * They drive the app ONLY through the accessibility tree (UiAutomator) so the test never reaches
 * into obfuscated internals — it sees what a user sees.
 *
 * Run by Scripts/android-minified-smoke.mjs (`android-minified` Soren suite), which builds with
 * `-PhavenTestBuildType=minified`, clears the app's data before EACH test (both need a fresh
 * install: one onboards, one boots the offline demo dataset) and scans logcat for R8 signatures.
 * They need a cleared install and granted permissions per test, which `connectedDebugAndroidTest`
 * doesn't give them, so they skip unless the runner passes `-e haven_smoke 1` (the script does).
 */
@RunWith(AndroidJUnit4::class)
class MinifiedSmokeTest {

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val context = instrumentation.targetContext
    private val pkg = context.packageName

    @org.junit.Before fun onlyUnderTheSmokeScript() {
        org.junit.Assume.assumeTrue("run by Scripts/android-minified-smoke.mjs (-e haven_smoke 1)",
            InstrumentationRegistry.getArguments().getString("haven_smoke") == "1")
    }

    private fun launch(configure: Intent.() -> Unit = {}) {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            setClassName(pkg, "com.blaineam.haven.MainActivity")
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            configure()
        }
        context.startActivity(intent)
        device.wait(Until.hasObject(By.pkg(pkg).depth(0)), LONG)
    }

    private fun waitFor(sel: BySelector, timeout: Long = LONG, what: String = sel.toString()): UiObject2 {
        val o = device.wait(Until.findObject(sel), timeout)
        assertNotNull("timed out waiting for $what — on screen: ${onScreen()}", o)
        return o!!
    }

    /** Every text / content description currently on screen, for a failure message. */
    private fun onScreen(): String = runCatching {
        device.findObjects(By.pkg(device.currentPackageName)).mapNotNull { o ->
            (o.text ?: o.contentDescription)?.takeIf { it.isNotBlank() }
        }.distinct().take(40).joinToString(" | ", prefix = "[${device.currentPackageName}] ")
    }.getOrDefault("?")

    /** The bottom-most match — the nav bar's "You"/"Messages" tab, not a post author of that name. */
    private fun lowest(text: String): UiObject2 {
        waitFor(By.text(text))
        return device.findObjects(By.text(text)).maxBy { it.visibleBounds.top }
    }

    private fun assertAlive() {
        // A crash in a background coroutine kills the process without failing any wait above it.
        assertTrue("app process died", device.executeShellCommand("pidof $pkg").isNotBlank())
    }

    @Test
    fun onboarding_feed_post_photo_settings() {
        launch()

        // Onboarding → identity creation (Account generation + persisted seed through the FFI).
        waitFor(By.text("I'm new to Haven"), LONG * 2)
        waitFor(By.clazz("android.widget.EditText")).text = "Smoke Tester"
        waitFor(By.text("I'm new to Haven")).click()

        // The feed (engine boot, circle state, feed() through the bindings).
        val composer = waitFor(By.text("Post to everyone in My Circle"), LONG * 2)

        // A text post (seal + store + feed re-open).
        composer.click()
        waitFor(By.clazz("android.widget.EditText").focused(true)).text = "R8 smoke text post"
        waitFor(By.text("Post")).click()
        waitFor(By.text("R8 smoke text post"), what = "the text post in the feed")
        assertAlive()

        // A photo post via the share sheet (LocalMedia sealing, the AVIF preview tier, EXIF, decode).
        val dir = File(context.cacheDir, "shared-files").apply { mkdirs() }
        val jpeg = File(dir, "r8-smoke.jpg")
        val bmp = Bitmap.createBitmap(800, 600, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(30, 144, 255)) }
        jpeg.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        context.startActivity(Intent(Intent.ACTION_SEND).apply {
            setClassName(pkg, "com.blaineam.haven.MainActivity")
            type = "image/jpeg"
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://$pkg.files/shared-files/${jpeg.name}"))
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        waitFor(By.text("Share as post")).click()
                lowest("My Circle").click()   // the sheet's row, not the feed header behind it
        waitFor(By.text("Send")).click()
        waitFor(By.desc("Photo"), LONG * 2, "the photo post's tile in the feed")
        assertAlive()

        // Settings and the screens that read identity / keys / relay state back out of the core.
        // The composer keeps the keyboard up, and the keyboard covers the bottom navigation. Back
        // drops it; should that Back land on the activity instead (the keyboard already gone),
        // bring Haven forward again — either way the tabs must then be reachable.
        if (device.wait(Until.findObject(By.text("Activity")), 3_000) == null) {
            device.pressBack()
            if (device.wait(Until.findObject(By.text("Activity")), 3_000) == null) {
                reopenHaven()
            }
        }
        waitFor(By.text("Activity"), what = "the bottom navigation bar")
        lowest("You").click()
        waitFor(By.desc("Settings")).click()
        for (page in listOf("Identity & devices", "Security & diagnostics", "Relays")) {
            waitFor(By.text(page)).click()
            waitFor(By.desc("Back")).click()
        }
        waitFor(By.text("Identity & devices"))
        assertAlive()
    }

    @Test
    fun demo_feed_dm_and_call() {
        // The offline demo dataset (QA_HOOKS): four friend identities handshake with this one and
        // author sealed posts, stories and DMs through the real engine — so this is the
        // multi-identity half of the boundary, with nobody else on the network.
        launch { putExtra("haven_demo", true) }
        waitFor(By.text("Maya Quinn"), LONG * 2, "the demo feed")
        waitFor(By.desc("Photo"), LONG, "a photo post in the demo feed")

        // A DM: open the thread (epoch-sealed history) and send into it.
        lowest("Messages").click()
        waitFor(By.text("Maya Quinn")).click()
        waitFor(By.text("Message…")).click()
        waitFor(By.clazz("android.widget.EditText").focused(true)).text = "R8 smoke dm"
        waitFor(By.desc("Send")).click()
        waitFor(By.text("R8 smoke dm"), what = "the sent DM")
        assertAlive()

        // A call: start (call signalling through the sealed channel + WebRTC), then end it.
        waitFor(By.desc("Video call")).click()
        waitFor(By.desc("End"), LONG, "the in-call screen")

        if (context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            // Picture-in-picture (ui/CallPip.kt): Home with a live call floats it…
            device.pressHome()
            awaitPinned(true, "the call to enter PiP on Home")
            // …reopening Haven (the PiP window's expand, or its launcher icon) returns to the call…
            reopenHaven()
            awaitPinned(false, "PiP to expand back to the app")
            waitFor(By.desc("End"), LONG, "the call screen after leaving PiP")
            // …and the call ending while it floats closes the window.
            device.pressHome()
            awaitPinned(true, "the call to re-enter PiP")
            com.blaineam.haven.core.CallManager.hangup()
            awaitPinned(false, "the PiP window to close when the call ends")
            // …and Haven opens normally afterwards (no stuck, invisible task).
            reopenHaven()
        } else {
            waitFor(By.desc("End")).click()
        }
        // Back in Haven with the call gone (the thread or the conversation list, depending on how
        // the app was reopened) — never a stuck call screen.
        waitFor(By.text("Maya Quinn"), LONG, "Haven after hanging up")
        assertTrue("call screen still up after hangup", !device.hasObject(By.desc("End")))
        assertAlive()
    }

    /** Leave PiP the way the launcher / the window's expand button does: start the activity again.
     *  (`am start` as shell: an in-process startActivity from a backgrounded app is not the same
     *  path, and the PiP menu's own buttons don't take injected taps reliably.) */
    private fun reopenHaven() {
        device.executeShellCommand("am start -n $pkg/com.blaineam.haven.MainActivity")
        device.wait(Until.hasObject(By.pkg(pkg).depth(0)), LONG)
    }

    /** Whether our task is in the pinned (picture-in-picture) windowing mode, per the window manager. */
    private fun pinned(): Boolean = device.executeShellCommand("dumpsys activity activities")
        .lines().any { it.contains("mode=pinned") && it.contains(pkg) }

    private fun awaitPinned(want: Boolean, what: String) {
        val end = System.currentTimeMillis() + LONG
        while (System.currentTimeMillis() < end) {
            if (pinned() == want) {
                // The task reports `pinned` as the enter animation STARTS; leaving PiP mid-animation
                // makes SystemUI send the task to the back instead of expanding it. Let it settle.
                Thread.sleep(2_000)
                return
            }
            Thread.sleep(250)
        }
        throw AssertionError("timed out waiting for $what — on screen: ${onScreen()}")
    }

    private companion object {
        const val LONG = 20_000L
    }
}
