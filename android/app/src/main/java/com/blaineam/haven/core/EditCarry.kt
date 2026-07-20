package com.blaineam.haven.core

import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.TrackRefFfi

/**
 * What an edit must RESTATE about an item so that editing its text does not delete the rest of it.
 *
 * An Edit event is not a patch. The reducer (`core/haven-p2p/src/social.rs`, `EventKind::Edit`)
 * assigns `body`, `media`, `music` and `mute_video` from the event wholesale, because that is what
 * lets the re-optimize pass re-point an item at smaller bytes without inventing a second event
 * kind. The cost of that design is that an edit which omits a field DELETES it — not just locally,
 * but on every device in the circle, permanently, with no way to get it back.
 *
 * Every editor is therefore obliged to carry forward what it did not mean to change, and "the
 * caller remembers" turned out not to be a durable way to enforce that: the circle-post editor
 * remembered and the DM editor did not, so editing a message's text dropped its photo and its song
 * for both ends of the thread. This object is the one place that obligation is discharged, so that
 * a text editor cannot get it wrong — [HavenNet.editPost] resolves through here rather than
 * accepting attachments from its caller at all.
 *
 * Pure, and deliberately takes the feed rather than reading it: that is what lets the regression
 * test drive it with a feed a real `HavenSocial` produced.
 */
internal object EditCarry {

    /** The attachments an edit of [eventId] must restate, or null if the item is not in [feed]. */
    fun forEvent(feed: List<FeedItemFfi>, eventId: String): Attachments? {
        for (item in feed) {
            if (item.id == eventId) return Attachments(item.media, item.music, item.muteVideo)
            // Comments carry media but no music or mute flag — the reducer's comment branch only
            // touches body and media, so restating null/false for the other two is not a loss.
            for (c in item.comments) {
                if (c.id == eventId) return Attachments(c.media, null, false)
            }
        }
        return null
    }

    /** The parts of an item an edit overwrites but a text edit means to leave alone. */
    data class Attachments(
        val media: List<String>,
        val music: TrackRefFfi?,
        val muteVideo: Boolean,
    )
}
