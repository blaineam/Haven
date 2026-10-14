package com.blaineam.haven.core

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * An in-process stand-in for `haven-relay`'s signed-HTTP lane: GET / HEAD / PUT on `/k/<key>` and the
 * delta LIST on `/l/<prefix>`, backed by a plain map. Every request is recorded in [hits]. It never
 * checks the signature (the tests swap `HavenNet.httpAuthSigner` for a stub), it only holds bytes.
 */
class FakeRelayServer {
    class Hit(val method: String, val path: String, val body: ByteArray)

    val store = ConcurrentHashMap<String, ByteArray>()
    val hits = CopyOnWriteArrayList<Hit>()
    /** Every request answers with this status while set (a refusing or broken relay). */
    @Volatile var forceStatus: Int? = null
    /** Keys whose GET answers this status instead of the stored bytes. */
    val getStatus = ConcurrentHashMap<String, Int>()
    /** Keys whose PUT is answered with this status (and not stored). */
    val putStatus = ConcurrentHashMap<String, Int>()
    private val puts = CopyOnWriteArrayList<CountDownLatch>()
    private val getWaiters = CopyOnWriteArrayList<Pair<String, CountDownLatch>>()
    private lateinit var server: HttpServer
    lateinit var base: String
        private set

    fun start(): FakeRelayServer {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex -> handle(ex) }
        server.start()
        base = "http://127.0.0.1:${server.address.port}"
        return this
    }

    fun stop() { server.stop(0) }

    /** A latch that opens after [n] more PUTs land (the only way to wait on a fire-and-forget upload without sleeping). */
    fun latchForPuts(n: Int): CountDownLatch = CountDownLatch(n).also { puts += it }

    /** A latch that opens when a GET of a key containing [part] arrives. */
    fun latchForGet(part: String): CountDownLatch = CountDownLatch(1).also { getWaiters += part to it }

    fun awaitPuts(latch: CountDownLatch): Boolean = latch.await(10, TimeUnit.SECONDS)

    fun puts() = hits.filter { it.method == "PUT" }

    private fun handle(ex: HttpExchange) {
        val body = ex.requestBody.readBytes()
        val path = ex.requestURI.rawPath
        hits += Hit(ex.requestMethod, path, body)
        val key = if (path.startsWith("/k/")) URLDecoder.decode(path.removePrefix("/k/"), "UTF-8") else null
        var status = forceStatus ?: 200
        var out = ByteArray(0)
        if (forceStatus == null) when {
            path.startsWith("/l/") -> {
                val prefix = URLDecoder.decode(path.removePrefix("/l/"), "UTF-8")
                val keys = store.keys.filter { it.startsWith(prefix) }.sorted()
                val digest = keys.joinToString(",").hashCode().toString()
                ex.responseHeaders.add("X-Haven-List-Digest", digest)
                if (ex.requestHeaders.getFirst("X-Haven-List-Digest") == digest) status = 204
                else out = (keys.joinToString("\n") + "\n\n").toByteArray()
            }
            ex.requestMethod == "HEAD" -> status = if (store.containsKey(key)) 200 else 404
            ex.requestMethod == "GET" -> {
                val forced = getStatus[key]
                val v = store[key]
                if (forced != null) status = forced else if (v == null) status = 404 else out = v
            }
            ex.requestMethod == "PUT" -> { val forced = putStatus[key]; if (forced != null) status = forced else store[key!!] = body }
        }
        if (ex.requestMethod == "HEAD") ex.sendResponseHeaders(status, -1)
        else if (status == 204) ex.sendResponseHeaders(204, -1)
        else { ex.sendResponseHeaders(status, if (out.isEmpty()) -1 else out.size.toLong()); if (out.isNotEmpty()) ex.responseBody.use { it.write(out) } }
        ex.close()
        if (ex.requestMethod == "PUT") puts.forEach { it.countDown() }
        if (ex.requestMethod == "GET" && key != null) getWaiters.forEach { (part, l) -> if (key.contains(part)) l.countDown() }
    }
}
