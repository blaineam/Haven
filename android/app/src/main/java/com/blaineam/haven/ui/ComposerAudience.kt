package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R

/**
 * Who a circle post (or a reply on one) actually reaches — said by the composer itself.
 *
 * People posted private things to the WHOLE circle believing they were writing to one person: the
 * audience was implicit in the circle switcher. So the composer's own form says it: the placeholder
 * names the circle ("Post to everyone in Family"), the send control is a labeled "Post" pill (not the
 * DM paper plane), and a reply reads "Reply to everyone in Family…". Passive cues only — no audience
 * menu and no "are you sure?" step in front of a post.
 * iOS parity: apple/HavenApp/ComposerAudience.swift.
 */
object ComposerAudience {
    /** Open (or reuse) [dmCircleId] in Messages, carrying [text] into its composer when non-blank;
     *  RootScreen switches to Messages when DmDrafts.openThread is set. */
    fun openThread(dmCircleId: String, text: String = "") {
        if (text.isNotBlank()) com.blaineam.haven.core.DmDrafts.stage(dmCircleId, text)
        else com.blaineam.haven.core.DmDrafts.openThread.value = dmCircleId
    }
}

/** Feed composer placeholder: names the circle when it fits (<= 14 chars), else "Post to everyone…". */
@Composable
fun postPlaceholder(circle: String): String =
    if (circle.length <= 14) stringResource(R.string.composer_post_cd_named, circle)
    else stringResource(R.string.composer_placeholder)

/** Reply placeholder: names the circle when it fits (<= 14 chars), else the plain "Reply to everyone…". */
@Composable
fun replyPlaceholder(circle: String): String =
    if (circle.length <= 14) stringResource(R.string.circle_reply_placeholder_named, circle)
    else stringResource(R.string.circle_reply_placeholder_generic)

/**
 * The feed composer's text field and labeled Post pill. Pure UI over its parameters — the caller owns
 * the draft and does the actual posting — so it can be driven in a Compose test without a live engine.
 * Post goes straight to [onPost]: the placeholder and the pill are the audience cue, nothing asks.
 */
@Composable
fun AudienceComposerBar(
    circleName: String,
    draft: String,
    onDraftChange: (String) -> Unit,
    canPost: Boolean,
    onPost: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 2.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = draft, onValueChange = onDraftChange,
            placeholder = { Text(postPlaceholder(circleName)) },
            modifier = Modifier.weight(1f).testTag("composeField"), shape = RoundedCornerShape(22.dp), maxLines = 4,
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
        )
        Spacer(Modifier.size(8.dp))
        // Labeled "Post", not a bare paper plane: the plane is what a private message's send
        // looks like, and this goes to the whole circle. White-on-brand-gradient — never themed.
        val postCd = stringResource(R.string.composer_post_cd_named, circleName)
        Box(Modifier.height(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
            .clickable(enabled = canPost) { onPost() }
            .padding(horizontal = 18.dp)
            .semantics { contentDescription = postCd }
            .testTag("composeSend"),
            contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.composer_post_button), color = Color.White,
                fontSize = 15.sp, fontWeight = FontWeight.Bold)
        }
    }
}
