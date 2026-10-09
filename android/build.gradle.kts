// Top-level build file. Plugin versions are declared here and applied per-module.
plugins {
    // AGP 9 compiles Kotlin itself (built-in Kotlin), so there is no org.jetbrains.kotlin.android
    // plugin any more. AGP 9.4.1 brings KGP 2.2.10; declaring the Compose compiler plugin at 2.2.21
    // lifts KGP to the matching 2.2.21 — the two must stay on the same Kotlin version.
    // AGP 9 also brought R8's optimized resource shrinking and strict full-mode keep rules
    // (Play vitals flagged the 8.x R8 setup for memory/performance).
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
}
