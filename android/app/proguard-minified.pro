# Extra keeps for the `minified` build type ONLY (never release). See build.gradle.kts.
#
# The androidTest APK runs in the app's process and is R8-processed against the app's mapping, so
# it can call into obfuscated code — but only into members R8 left in place. HavenTestRunner arms
# the offline gate before the Application exists (HavenOffline.set); R8 would otherwise inline
# that one-liner into its only app caller and drop it, and the runner would die with
# NoSuchMethodError before a single test ran. Obfuscation is still allowed: this changes nothing
# about how JNA/UniFFI code is shrunk, so the smoke run still tests the release configuration.
-keep,allowobfuscation class com.blaineam.haven.core.HavenOffline { *; }

# ConnectionServiceTimeoutTest (Android 15 dataSync budget) also runs against this build, so the R8
# configuration's foreground-service path is exercised too. It drives the service through its
# companion's start/stop/startForCall/endCall; keep those callable (names may still be obfuscated).
-keep,allowobfuscation class com.blaineam.haven.core.ConnectionService$Companion {
    public <methods>;
}
-keep,allowobfuscation class com.blaineam.haven.core.ConnectionService {
    public static ** Companion;
}

# The test APK shares the app's copy of the Kotlin standard library (AGP strips the duplicate and
# remaps the test's calls onto the app's obfuscated names). R8 shrinks the app's stdlib to what the
# APP calls, so a test calling e.g. Intrinsics.checkNotNullParameter or CloseableKt.closeFinally
# that the app happens not to keep dies with NoSuchMethodError before its first line. Keep the
# stdlib whole here — renamed, but present. Release still shrinks it; nothing JNA-related changes.
-keep,allowobfuscation class kotlin.** { *; }
# Same story for the AndroidX pieces androidx.test calls into from the app's classpath:
# androidx.tracing (AndroidJUnitRunner's Trace sections) and lifecycle (ActivityScenario).
-keep,allowobfuscation class androidx.tracing.** { *; }
-keep,allowobfuscation class androidx.lifecycle.** { *; }
# MinifiedSmokeTest ends a call while it floats in picture-in-picture (there's no in-window
# control to tap), to prove the PiP window closes with the call.
-keep,allowobfuscation class com.blaineam.haven.core.CallManager {
    public void hangup();
}
