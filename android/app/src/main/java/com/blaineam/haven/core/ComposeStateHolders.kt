package com.blaineam.haven.core

/**
 * Every core object that holds Compose snapshot state, class-initialized ON MAIN before the first
 * composition.
 *
 * The engine boots on a background thread from the very start of the process (MainActivity hands
 * it to [EngineBoot] before setContent), and the boot touches most of these objects. Whichever
 * thread touches an object first runs its initializer and so CREATES its mutableStateOf()s; if that
 * is the boot thread while the first composition is running, composition then reads a state created
 * after its snapshot was taken and Compose throws ("Reading a state that was created after the
 * snapshot was taken" — the e2e launch crash, 2026-10-01). Initializing them all here first makes
 * every such state older than any composition. MainThreadEngineAccessTest keeps this list complete.
 */
object ComposeStateHolders {
    internal val CLASSES = listOf(
        "ActivityStore", "AvatarStore", "CallManager", "CircleLock", "CircleSettings", "DmDrafts",
        "DeviceKeyStore", "DeviceCredentialStore", "DeviceRosterManager", "DmRead", "DmPins",
        "EvictedMediaStore", "HiddenStore", "InstagramImporter", "KeptStoriesStore", "LowDataMonitor",
        "SyncMetrics", "HavenNet", "MediaProcessing", "MediaWantedStore", "MediaReoptimizer",
        "MediaLimits", "QaDriver", "RelayNudge", "PinnedMediaStore", "ScheduledStore", "ShareInbox",
        "InviteInbox", "PostLinkInbox", "StoryLinkInbox", "CircleLinkInbox",
    )

    /** Run each holder's initializer on the calling (main) thread; already-initialized ones are free. */
    fun initOnMain() {
        val loader = ComposeStateHolders::class.java.classLoader
        for (name in CLASSES) {
            runCatching { Class.forName("com.blaineam.haven.core.$name", true, loader) }
        }
    }
}
