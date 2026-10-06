package com.blaineam.haven.core

import android.content.pm.ServiceInfo

/**
 * Which foreground-service types [ConnectionService] asks for, kept pure so the rules are tested.
 *
 * Android 15 (API 35) gives `dataSync` a budget of about 6 hours a day. When it runs out the system
 * calls `onTimeout(startId, fgsType)` and the service must stop within seconds, or the app is
 * killed with ForegroundServiceDidNotStopInTimeException; while it is out, `startForeground` with
 * `dataSync` throws. `microphone` and `mediaProjection` have no such budget, so during a call or a
 * screen share the service holds ONLY those — a call must never lose its mic because the idle
 * "Stay connected" time ran out. Below API 35 there is no budget and `dataSync` stays as before.
 */
object ForegroundTypes {
    /** First Android with the dataSync time budget (Android 15). */
    const val DATA_SYNC_BUDGET_SDK = 35

    /** The types for `startForeground`, or 0 below API 29 (no typed startForeground there). */
    fun forState(sdk: Int, micWanted: Boolean, projection: Boolean): Int {
        if (sdk < 29) return 0
        val inCall = micWanted || projection
        var type = 0
        if (!inCall || sdk < DATA_SYNC_BUDGET_SDK) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        if (projection) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (micWanted && sdk >= 34) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        // A call on API 29–33 with no projection still needs a type: keep the service alive as dataSync.
        return if (type == 0) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else type
    }

    /**
     * The dataSync budget ran out. During a call/share: the types to re-promote with (no dataSync),
     * so the call keeps its mic and capture. Otherwise null — stop the foreground service now.
     */
    fun afterTimeout(sdk: Int, micWanted: Boolean, projection: Boolean): Int? {
        if (!(micWanted || projection)) return null
        val type = forState(maxOf(sdk, DATA_SYNC_BUDGET_SDK), micWanted, projection) and
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC.inv()
        return if (type == 0) null else type
    }
}
