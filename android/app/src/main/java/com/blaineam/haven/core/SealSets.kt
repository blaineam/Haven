package com.blaineam.haven.core

/**
 * Pure rules for WHICH circles a stored media blob is sealed for.
 *
 * A blob is one file per ref, content-addressed, uploaded once. The engine can seal it so every circle
 * in a list opens it (`seal_circle_media_multi`, first id = primary), so a multi-circle post seals each
 * attachment for ALL the chosen circles up front. The at-rest blob remembers the set it was sealed for
 * (see [LocalMedia.sealedCircles]); a later post to a circle outside that set re-seals it for the UNION
 * — never for just the new set, which would lock the circles that already hold the ref out of it.
 */
object SealSets {
    /** Stable, order-free text form for persistence. Blank ids are dropped. */
    fun encode(ids: Collection<String>): String = ids.filter { it.isNotBlank() }.toSortedSet().joinToString(",")

    fun decode(text: String?): Set<String> =
        text?.split(',')?.filter { it.isNotBlank() }?.toSet() ?: emptySet()

    /** The blob already opens for every wanted circle — nothing to re-seal. */
    fun covers(recorded: Set<String>, wanted: List<String>): Boolean = recorded.containsAll(wanted)

    /** The ids to seal for: [wanted] first (its first id is the engine's primary), then any previously
     *  sealed circle not being posted to now, so earlier posts of the same ref keep opening. */
    fun target(wanted: List<String>, recorded: Set<String>): List<String> =
        (wanted + recorded.sorted()).filter { it.isNotBlank() }.distinct()
}
