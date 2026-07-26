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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

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
        }
        release {
            isMinifyEnabled = false   // tighten later; JNA + reflection need care under R8
            // Only attach the release signing config when CI actually provided a keystore.
            if (havenKeystoreFile != null && file(havenKeystoreFile).exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
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
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.activity:activity-compose:1.9.3")

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

    // Background sync (serverless, like the iOS BGAppRefreshTask) for local notifications.
    implementation("androidx.work:work-runtime-ktx:2.9.1")

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
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.10.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
