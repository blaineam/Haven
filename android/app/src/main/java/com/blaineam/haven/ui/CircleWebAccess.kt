package com.blaineam.haven.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HavenNet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Web browsers, per circle. A browser linked to someone's account reads a circle only when the
 * circle allows web devices (core `webpolicy`): its admins decide for a circle that has a creator,
 * and every member has to agree for one that does not (older circles, conversations). This is my
 * account's own switch, with a plain statement of where the circle stands. Shown in the circle's
 * settings and, for a conversation, from its composer menu. iOS `CircleWebAccessSection` parity.
 */
@Composable
fun CircleWebAccessRows(circleId: String) {
    var tick by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    // The engine read takes its lock — off main.
    val status by produceState<uniffi.haven_ffi.CircleWebAccessFfi?>(null, circleId, tick) {
        value = withContext(Dispatchers.Default) { HavenNet.circleWebAccess(circleId) }
    }
    val s = status ?: return
    Column(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.circle_web_title), color = HavenTheme.textSecondary, fontSize = 12.sp)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.circle_web_allow), color = HavenTheme.textPrimary, fontSize = 13.sp,
                modifier = Modifier.weight(1f))
            Switch(
                checked = s.mine,
                enabled = s.canSign,
                onCheckedChange = { want ->
                    scope.launch {
                        withContext(Dispatchers.Default) { HavenNet.setCircleWebAccess(circleId, want) }
                        tick++
                    }
                },
                colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
            )
        }
        Text(
            stringResource(if (s.allowed) R.string.circle_web_on else R.string.circle_web_off),
            color = if (s.allowed) HavenTheme.textPrimary else HavenTheme.textSecondary, fontSize = 11.sp,
        )
        val who = when {
            !s.canSign -> stringResource(R.string.circle_web_linked_cant)
            s.decidedByAdmins && s.iDecide -> stringResource(R.string.circle_web_admin_you)
            s.decidedByAdmins -> stringResource(R.string.circle_web_admin_other)
            s.waitingOn.isEmpty() -> stringResource(R.string.circle_web_everyone_done)
            else -> stringResource(R.string.circle_web_waiting, s.waitingOn.size)
        }
        Text(who, color = HavenTheme.textSecondary, fontSize = 11.sp)
        Text(stringResource(R.string.circle_web_warn), color = HavenTheme.textSecondary, fontSize = 11.sp)
    }
}
