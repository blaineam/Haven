package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Builds small synthetic Instagram "Download your information" (JSON) archives for the tests. */
object InstagramFixture {
    fun media(uri: String, ts: Long, title: String = "", genre: String? = null): JSONObject = JSONObject()
        .put("uri", uri).put("creation_timestamp", ts).put("title", title).also {
            if (genre != null) it.put("media_metadata", JSONObject().put("video_metadata", JSONObject().put("music_genre", genre)))
        }

    /** A post: [medias] directly under "media"; [nested] hangs further album members off a nested chain. */
    fun post(ts: Long?, title: String, medias: List<JSONObject>, nested: List<JSONObject> = emptyList(), draft: Boolean = false): JSONObject {
        val o = JSONObject().put("title", title).put("media", JSONArray(medias))
        if (ts != null) o.put("timestamp", ts)
        if (nested.isNotEmpty()) o.put("label_values", JSONArray().put(JSONObject().put("label", "Media")
            .put("dict", JSONArray().put(JSONObject().put("dict", JSONArray(nested))))))
        if (draft) o.put("label_values", JSONArray().put(JSONObject().put("label", "Draft").put("value", "true")))
        return o
    }

    fun write(
        dir: File, name: String = "instagram-test.zip",
        posts: List<JSONObject>? = null, stories: List<JSONObject>? = null, reels: List<List<JSONObject>>? = null,
        files: Map<String, ByteArray> = emptyMap(), extra: Map<String, ByteArray> = emptyMap(),
    ): File {
        val out = File(dir, name)
        ZipOutputStream(out.outputStream()).use { z ->
            fun put(n: String, b: ByteArray) { z.putNextEntry(ZipEntry(n)); z.write(b); z.closeEntry() }
            if (posts != null) put("your_instagram_activity/media/posts.json", JSONArray(posts).toString().toByteArray())
            if (stories != null) put("your_instagram_activity/media/stories.json",
                JSONObject().put("ig_stories", JSONArray(stories)).toString().toByteArray())
            if (reels != null) put("your_instagram_activity/media/reels.json",
                JSONObject().put("ig_reels_media", JSONArray(reels.map { JSONObject().put("media", JSONArray(it)) })).toString().toByteArray())
            for ((n, b) in files) put(n, b)
            for ((n, b) in extra) put(n, b)
        }
        return out
    }
}
