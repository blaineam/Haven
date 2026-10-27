package com.blaineam.haven.core

import android.media.AudioDeviceInfo

/**
 * Where a call's audio goes — pure decisions so they are JVM-testable (Apple parity: CallAudioRoute).
 *
 * A call used to ALWAYS select the built-in loudspeaker as its communication device. On API 31+ that
 * overrides whatever the user connected — a car (Bluetooth / Android Auto), earbuds, a wired or USB
 * headset — so the call played from the phone's speaker in a pocket while the OS-level route picker
 * could not reach the car. The speaker is only the default when nothing external is attached, and an
 * explicit tap on the speaker button always wins.
 */
object CallRoutePolicy {
    /** Output types the user attaches on purpose (pairing / plugging in). */
    private val EXTERNAL = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY, AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST, AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL, AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_AUX_LINE, AudioDeviceInfo.TYPE_DOCK,
    )

    fun isExternal(type: Int): Boolean = type in EXTERNAL

    fun hasExternalOutput(types: Collection<Int>): Boolean = types.any(::isExternal)

    /** Speaker or not: an explicit tap wins; otherwise speaker unless something external is attached. */
    fun wantsSpeaker(userChoice: Boolean?, externalActive: Boolean): Boolean =
        userChoice ?: !externalActive
}
