# Haven — R8 keep rules for the release build.
#
# R8 renames and strips everything that is not reachable from Java/Kotlin. That is wrong in
# exactly the places where something looks a class or member up BY NAME at runtime: JNA, the
# UniFFI bindings it serves, JNI from the Rust core, and a few Android/AndroidX entry points that
# are persisted by name. Every rule below names the lookup it protects. Keep them narrow — but a
# missing keep is a launch crash in production, so when in doubt, verify on the minified build:
#
#   ./gradlew :app:assembleMinified        (R8 exactly as release, debug-signed, installable)
#   node Scripts/android-minified-smoke.mjs  (the `android-minified` Soren suite)
#
# Libraries that ship their own consumer rules (org.webrtc, AndroidX WorkManager, coroutines,
# OkHttp, Play services, CameraX) are not repeated here.

# ── Readable production stack traces ──────────────────────────────────────────────────────────
# Line numbers survive; the source file name is collapsed. The mapping.txt CI uploads to Play
# (and keeps as an artifact) turns the obfuscated frames back into real ones.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
# @Structure.FieldOrder is a runtime annotation JNA reads; Kotlin metadata isn't needed.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,Signature,InnerClasses,EnclosingMethod

# ── JNA (net.java.dev.jna:jna @aar) ───────────────────────────────────────────────────────────
# libjnidispatch.so resolves com.sun.jna classes, fields and methods through JNI FindClass /
# GetFieldID / GetMethodID by their literal names (Pointer.peer, Structure, Native.fromNative,
# CallbackReference.getCallback…). Any rename there and the first FFI call dies in class init.
# The AAR ships no consumer rules, so this one is ours. It is JNA's own recommended rule.
-keep class com.sun.jna.** { *; }
# JNA's desktop code paths reference AWT, which Android doesn't have. Never reached on Android.
-dontwarn java.awt.**

# Structures (UniFFI's RustBuffer, ForeignBytes, UniffiRustCallStatus, the foreign-future result
# and VTable structs). JNA reads/writes their fields by the NAMES listed in @Structure.FieldOrder,
# via reflection, and instantiates the nested ByValue/ByReference subclasses reflectively for
# return values and out-params. Renaming a field or dropping a no-arg constructor breaks the
# marshalling of every FFI call (a RustBuffer is in nearly all of them).
-keep class * extends com.sun.jna.Structure { *; }

# Callbacks (future continuations, foreign-future completion, callback-interface vtables such as
# InboundListener). JNA finds the method to invoke by reflecting over the Callback interface
# (CallbackReference.getCallbackMethod), and it must stay the one public method with the declared
# signature on both the interface and the Kotlin object that implements it.
-keep interface * extends com.sun.jna.Callback { *; }
-keep class * implements com.sun.jna.Callback { *; }

# UniFFI direct mapping: Native.register(UniffiLib::class.java, "haven_ffi") binds every `external
# fun` by its NAME to the identically named exported Rust symbol (uniffi_haven_ffi_fn_…). The
# default proguard-android-optimize rules already keep native method names; these make the binding
# objects themselves explicit so neither is ever merged, inlined or renamed out from under JNA.
-keep class uniffi.haven_ffi.UniffiLib { *; }
-keep class uniffi.haven_ffi.IntegrityCheckingUniffiLib { *; }

# ── JNI from the Rust core ────────────────────────────────────────────────────────────────────
# libhaven_ffi.so exports Java_com_blaineam_haven_core_NativeBridge_nativeInitAndroidContext,
# which the JVM binds by class + method NAME (core/haven-ffi/src/lib.rs).
-keep class com.blaineam.haven.core.NativeBridge {
    native <methods>;
}
# iroh's TLS stack links rustls-platform-verifier, whose Rust side looks up
# org.rustls.platformverifier.CertificateVerifier through JNI. The Kotlin half is not bundled
# today; if it ever is, it must keep its names. No-op otherwise.
-keep class org.rustls.platformverifier.** { *; }
-dontwarn org.rustls.platformverifier.**

# ── Bundled native libraries with JNI back into Java ──────────────────────────────────────────
# avif-coder's libcoder.so throws its exceptions with ThrowNew(FindClass("com/radzivon/…/
# GetPixelsException")) and friends. Its consumer rule (-keepclasseswithmembernames) only covers
# classes with native methods, not those exceptions, so a decode failure would turn into a
# NoClassDefFoundError instead of the exception PreviewCodec catches.
-keep class com.radzivon.bartoshyk.avif.coder.** { *; }

# ── Haven's own by-name lookups ───────────────────────────────────────────────────────────────
# ComposeStateHolders.initOnMain() class-initializes these with Class.forName(
# "com.blaineam.haven.core.$name") so their Compose state predates the first composition (the
# 2026-10-01 launch crash). R8 can't see a computed name; without these, every forName silently
# fails under runCatching and the crash returns. ProguardRulesTest keeps this list in sync with
# ComposeStateHolders.CLASSES.
-keepnames class com.blaineam.haven.core.ActivityStore
-keepnames class com.blaineam.haven.core.AvatarStore
-keepnames class com.blaineam.haven.core.CallManager
-keepnames class com.blaineam.haven.core.CircleLock
-keepnames class com.blaineam.haven.core.CircleSettings
-keepnames class com.blaineam.haven.core.DmDrafts
-keepnames class com.blaineam.haven.core.DeviceKeyStore
-keepnames class com.blaineam.haven.core.DeviceCredentialStore
-keepnames class com.blaineam.haven.core.DeviceRosterManager
-keepnames class com.blaineam.haven.core.DmRead
-keepnames class com.blaineam.haven.core.DmPins
-keepnames class com.blaineam.haven.core.EvictedMediaStore
-keepnames class com.blaineam.haven.core.HiddenStore
-keepnames class com.blaineam.haven.core.InstagramImporter
-keepnames class com.blaineam.haven.core.KeptStoriesStore
-keepnames class com.blaineam.haven.core.LowDataMonitor
-keepnames class com.blaineam.haven.core.SyncMetrics
-keepnames class com.blaineam.haven.core.HavenNet
-keepnames class com.blaineam.haven.core.MediaProcessing
-keepnames class com.blaineam.haven.core.MediaWantedStore
-keepnames class com.blaineam.haven.core.MediaReoptimizer
-keepnames class com.blaineam.haven.core.MediaLimits
-keepnames class com.blaineam.haven.core.QaDriver
-keepnames class com.blaineam.haven.core.RelayNudge
-keepnames class com.blaineam.haven.core.PinnedMediaStore
-keepnames class com.blaineam.haven.core.ScheduledStore
-keepnames class com.blaineam.haven.core.ShareInbox
-keepnames class com.blaineam.haven.core.InviteInbox
-keepnames class com.blaineam.haven.core.PostLinkInbox
-keepnames class com.blaineam.haven.core.StoryLinkInbox
-keepnames class com.blaineam.haven.core.CircleLinkInbox
-keepnames class com.blaineam.haven.core.RelayHistoryResync

# WorkManager stores the worker's CLASS NAME in its database. SyncWorker is enqueued as unique
# periodic work with ExistingPeriodicWorkPolicy.KEEP, so the row written by an unobfuscated
# install (every version before R8) survives the update. If the class were renamed, that row
# would never instantiate again ("Could not create Worker") and KEEP would stop a fresh enqueue
# from replacing it — background sync would die silently on upgrade.
-keep class com.blaineam.haven.core.SyncWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# AGP 9 / R8 strict full mode: a body-less `-keep class A` no longer keeps A's no-arg constructor.
# Room and WorkManager ship exactly such rules (`-keep class * extends androidx.room.RoomDatabase`,
# `-keep class * extends androidx.work.InputMerger`) and then instantiate those classes reflectively
# through `<init>()` — WorkDatabase_Impl at WorkManager startup (every launch crashed in
# androidx.room.Room.getGeneratedImplementation) and OverwritingInputMerger when work is enqueued.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.InputMerger { <init>(); }
