plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.blaineam.haven"
    // Play Console requires target API 36+ (Android 16) for new uploads / updates.
    compileSdk = 36

    defaultConfig {
        applicationId = "com.blaineam.haven"
        minSdk = 29
        targetSdk = 36
        // CI overrides these per release so every Play upload has a unique, increasing versionCode
        // (Play rejects a re-used code). Locally they default to the baseline below.
        //   ./gradlew bundleRelease -PhavenVersionCode=<n> -PhavenVersionName=<x.y.z>
        versionCode = (project.findProperty("havenVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("havenVersionName") as String?) ?: "0.1.0"
        // Our own runner, so the whole instrumented-test process is hermetic before
        // `HavenApplication.onCreate` can schedule a mailbox poll. See HavenTestRunner.
        testInstrumentationRunner = "com.blaineam.haven.HavenTestRunner"

        // We ship prebuilt .so files in jniLibs; keep the APK to the ABIs we build.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // Release signing is wired from env vars (set by CI from repository secrets). When the
    // keystore env isn't present we leave `signingConfigs` empty so `assembleRelease` produces
    // an UNSIGNED APK — CI falls back to `assembleDebug` for zero-setup betas in that case.
    val havenKeystoreFile = System.getenv("HAVEN_KEYSTORE_FILE")
    if (havenKeystoreFile != null && file(havenKeystoreFile).exists()) {
        signingConfigs {
            create("release") {
                storeFile = file(havenKeystoreFile)
                storePassword = System.getenv("HAVEN_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("HAVEN_KEY_ALIAS")
                keyPassword = System.getenv("HAVEN_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            // QA/demo hooks (demo seeding, the haven_no_net gate) — see the `minified` type below.
            buildConfigField("boolean", "QA_HOOKS", "true")
        }
        release {
            // R8: shrink + optimize + obfuscate. Play flagged 1.8.11 at 0% obfuscation. JNA and the
            // UniFFI bindings look classes/fields/methods up by NAME, so proguard-rules.pro keeps
            // exactly those (every rule says what lookup it protects). The `android-minified` Soren
            // suite runs this exact R8 configuration on an emulator before every release.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("boolean", "QA_HOOKS", "false")
            // Only attach the release signing config when CI actually provided a keystore.
            if (havenKeystoreFile != null && file(havenKeystoreFile).exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        // Release's R8 configuration, debug-signed and installable side by side with the debug app
        // (its own applicationId, so a smoke run can `pm clear` it without touching the QA fleet's
        // debug install). NOT debuggable on purpose: a debuggable build puts R8 in debug mode, which
        // skips the inlining/merging that release does, and we want to RUN what we ship.
        //
        // The one difference from release: QA_HOOKS is on, so the instrumented smoke tests can
        // launch the offline demo dataset (friends, DMs, a call target) — the same hooks the debug
        // build has. They are still compiled out of release. proguard-minified.pro adds the
        // handful of keeps the androidTest APK needs to reach into the app (none affect JNA).
        create("minified") {
            initWith(getByName("release"))
            applicationIdSuffix = ".minified"
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
            proguardFiles("proguard-minified.pro")
            testProguardFiles("proguard-test.pro")
            buildConfigField("boolean", "QA_HOOKS", "true")
        }
    }

    // Instrumented tests normally target `debug`. `-PhavenTestBuildType=minified` points them at the
    // R8 build instead (Scripts/android-minified-smoke.mjs) so the smoke tests exercise obfuscated
    // code — the only way to catch a missing keep rule before Play does.
    testBuildType = (project.findProperty("havenTestBuildType") as String?) ?: "debug"

    sourceSets {
        // The demo dataset's photos/avatars live with the debug-only assets; the minified smoke
        // run seeds the same dataset, so it needs them too. Release never sees them.
        getByName("minified").assets.srcDir("src/debug/assets")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true   // BuildConfig.DEBUG gates the debug-only demo seeder
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    // Per-ABI APKs so a sideloadable arm64 build is ~half the size of the universal one.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = true   // also keep a universal one for the emulator
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    // AVIF encode + decode for the 512px preview tier (docs/PREVIEW-TIER-DESIGN.md).
    // Bundled rather than relying on the platform: AVIF is native only from API 31 and minSdk is 29,
    // and Android has no public AVIF ENCODER at any level — every client must be able to WRITE
    // previews, not just read them, because any device can be the sender. libdav1d-based.
    implementation("com.github.awxkee:avif-coder:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    // 1.10.x: enableEdgeToEdge() no longer calls Window.setStatusBarColor/setNavigationBarColor on
    // API 35+ (deprecated there — Play flags apps whose edge-to-edge path still uses them).
    implementation("androidx.activity:activity-compose:1.10.1")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.3")

    // UniFFI Kotlin bindings need JNA (the Android @aar variant) + coroutines.
    // 5.19.1, not 5.14.0: Play Console flags the older AAR's bundled libjnidispatch.so as unsafe on
    // 16 KB-page devices ("compiled using an older Android NDK version that can still cause
    // crashes"). Verified from the artifacts themselves — 5.14.0's x86_64 PT_LOAD segments are 4 KB
    // aligned (0x1000) where 16 KB devices need >=0x4000, and both ABIs in 5.19.1 are 0x4000. This
    // is a transitive native lib we don't build, so bumping JNA is the only fix available to us.
    implementation("net.java.dev.jna:jna:5.19.1@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Persisted identity / prefs, encrypted at rest by the Android Keystore.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // QR: generate + decode with zxing-core; scan with a custom in-app CameraX UI.
    implementation("com.google.zxing:core:3.5.3")
    // 1.4.2, not 1.3.4: camera-core ships libimage_processing_util_jni.so, and 1.3.4's is 4 KB
    // aligned (0x1000) on both 64-bit ABIs — the same 16 KB-page hazard Play flagged for JNA, just
    // not called out yet. Verified from the artifacts: 1.4.2's segments are 0x4000. Staying on the
    // 1.4.x line rather than 1.5.0 keeps this a page-alignment fix, not a CameraX major-version
    // migration on the eve of a store release.
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")

    // In-app browser (Chrome Custom Tabs) for opening shared links inside Haven.
    implementation("androidx.browser:browser:1.8.0")

    // WebSocket client for the /webrtc/hairpin call-media relay (CallHairpin). Pure Kotlin/Java —
    // it ships no .so, so it sidesteps the 16 KB-page-alignment hazard that forced the JNA and
    // CameraX bumps above. Android has no built-in WebSocket client (java.net.http is not on the
    // platform), and the hairpin is the only media path a call has when ICE cannot pair.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Background sync (serverless, like the iOS BGAppRefreshTask) for local notifications.
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    // Play In-App Review (support kit's RatingManager) — gated, earned review prompts.
    implementation("com.google.android.play:review-ktx:2.0.2")

    // Biometric (per-circle Face/fingerprint lock) — needs a FragmentActivity host.
    implementation("androidx.biometric:biometric:1.1.0")
    // Force a modern Fragment: biometric 1.1.0 drags in fragment 1.2.5, whose legacy 16-bit
    // requestCode check crashes Compose's ActivityResultRegistry permission launcher
    // ("Can only use lower 16 bits for requestCode") on every fresh Android 13+ launch.
    implementation("androidx.fragment:fragment-ktx:1.8.5")

    // EXIF orientation for picked photos (so they aren't sideways/blank).
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // Nearby Connections — offline mesh over BLE/Wi-Fi (the Android take on MultipeerConnectivity).
    implementation("com.google.android.gms:play-services-nearby:19.3.0")

    // WebRTC (maintained libwebrtc fork, prebuilt .so) for mesh group calls — Android side of
    // the same DTLS-SRTP media + SDP/ICE-over-sealed-channel design as iOS.
    implementation("io.getstream:stream-webrtc-android:1.3.8")

    // Video filter transcode (MediaCodec + OpenGL decode→shader→encode). Apache-2.0, bundled in
    // the APK — no Google services, offline, de-Google-able. We feed it our own GLSL so the look
    // matches the iOS FilterSpec pipeline exactly (incl. Kodak Gold). Photos use the same shader
    // via an offscreen GL pass, so photo + video + iOS are pixel-consistent.
    implementation("com.github.MasayukiSuda:Mp4Composer-android:v0.4.1")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // --- Tests ---
    testImplementation("junit:junit:4.13.2")
    // Android stubs org.json in unit tests (every method throws), so the archive parser — which is
    // pure JSON walking and the part most worth testing off-device — needs the real thing.
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    // UI-level smoke tests for the R8 build (MinifiedSmokeTest): drives the app through the
    // accessibility tree, so the test never reaches into obfuscated app internals.
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.10.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
