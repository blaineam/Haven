package com.blaineam.haven.ui

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The launcher icon per palette: one `<activity-alias>` each (AndroidManifest.xml), exactly one
 * enabled. Enabling the chosen alias before disabling the rest keeps a launcher entry present at
 * every instant, and DONT_KILL_APP keeps Haven running through the switch. Deep links, share
 * filters and shortcuts live on MainActivity itself, so they resolve identically whichever alias is on.
 */
object AppIcon {
    fun aliasName(id: String): String = "com.blaineam.haven.LauncherAlias" + id.replaceFirstChar { it.uppercase() }

    /** Pure plan: which alias to enable, which to disable. */
    fun plan(selected: String): Pair<String, List<String>> {
        val on = Palettes.normalizedId(selected)
        return aliasName(on) to Palettes.all.filter { it.id != on }.map { aliasName(it.id) }
    }

    fun apply(context: Context, selected: String) {
        val pm = context.packageManager
        val (on, off) = plan(selected)
        fun set(name: String, enabled: Boolean) {
            val cn = ComponentName(context.packageName, name)
            val want = if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            // Skip a no-op: each write can make the launcher refresh its icon.
            if (runCatching { pm.getComponentEnabledSetting(cn) }.getOrNull() == want) return
            runCatching { pm.setComponentEnabledSetting(cn, want, PackageManager.DONT_KILL_APP) }
        }
        set(on, true)
        off.forEach { set(it, false) }
    }
}
