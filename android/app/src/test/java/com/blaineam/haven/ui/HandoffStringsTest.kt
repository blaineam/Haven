package com.blaineam.haven.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/** The transfer banner's strings exist in all nine languages, with the English placeholders: a
 *  missing or reordered `%n$d` is a crash only a phone in that language would see. */
class HandoffStringsTest {
    private val folders = listOf("values", "values-de", "values-es", "values-fr", "values-it", "values-ja",
        "values-ko", "values-b+pt+BR", "values-zh-rCN")

    private fun res(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main/res").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return File(d, "android/app/src/main/res")
    }

    /** name → the placeholders it takes, in argument order. */
    private fun strings(folder: String): Map<String, List<String>> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(res(), "$folder/strings.xml")).documentElement
        val all = doc.getElementsByTagName("string")
        return (0 until all.length).map { all.item(it) as Element }
            .filter { it.getAttribute("name").startsWith("handoff_") }
            .associate { e ->
                e.getAttribute("name") to Regex("%\\d+\\\$[sd]").findAll(e.textContent).map { it.value }.sorted().toList()
            }
    }

    @Test fun every_language_has_every_banner_string_with_the_same_placeholders() {
        val english = strings("values")
        assertEquals(13, english.size)
        assertEquals(4, english.getValue("handoff_both_fmt").size)
        for (folder in folders.drop(1)) assertEquals(folder, english, strings(folder))
    }
}
