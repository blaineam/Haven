package com.blaineam.haven.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.blaineam.haven.R
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.SecretMessages
import kotlinx.coroutines.delay

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) { if (c is Activity) return c; c = c.baseContext }
    return null
}

private fun setSecureFlag(context: Context, on: Boolean) {
    val activity = context.findActivity() ?: return
    if (on) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
}

/**
 * A tap-to-reveal secret message: hidden behind a lock until tapped, auto-hides after ~6s, and
 * marks the window FLAG_SECURE (excluded from screenshots/recents) while revealed — the coarse
 * Android counterpart of iOS's per-window screenshot exclusion.
 */
// `contentColor` is the ENCLOSING bubble's foreground, not this chip's own choice: a secret rides
// inside a DM bubble that is either a pink fill (white content) or a theme card (themed content).
@Composable
fun SecretBubble(body: String, contentColor: Color = HavenTheme.textPrimary) {
    val context = LocalContext.current
    var revealed by remember(body) { mutableStateOf(false) }
    LaunchedEffect(revealed) {
        if (revealed) { setSecureFlag(context, true); delay(6000); revealed = false }
        else setSecureFlag(context, false)
    }
    DisposableEffect(Unit) { onDispose { setSecureFlag(context, false) } }
    Row(
        Modifier.clip(RoundedCornerShape(10.dp)).background(contentColor.copy(alpha = 0.10f))
            .clickable { if (!revealed) revealed = true }
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Lock, null, tint = contentColor, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(6.dp))
        Text(
            if (revealed) SecretMessages.text(body) else stringResource(R.string.secret_tap_to_view),
            color = contentColor, fontSize = 15.sp,
        )
    }
}
