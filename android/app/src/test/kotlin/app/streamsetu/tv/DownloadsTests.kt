package app.streamsetu.tv

import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.repo.SaveState
import app.streamsetu.core.model.Movie
import app.streamsetu.core.playback.StreamUrlResolver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.ServerSocket

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class DownloadsTests {
    /** A small web server on this computer: it answers a request for a file, and honours a Range header. */
    private class TinyServer(private val files: Map<String, ByteArray>, val seenRanges: MutableList<String?>) {
        private val socket = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
        val port get() = socket.localPort
        private val thread = Thread {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                Thread { runCatching { serve(client) } }.start()
            }
        }.apply { isDaemon = true }
        fun start() = thread.start()
        fun stop() = socket.close()

        private fun serve(client: java.net.Socket) = client.use { c ->
            val input = c.getInputStream().bufferedReader()
            val path = input.readLine().split(' ')[1]
            var range: String? = null
            while (true) { val line = input.readLine() ?: break; if (line.isEmpty()) break; if (line.startsWith("Range:", true)) range = line.substringAfter(':').trim() }
            seenRanges += range
            val out = c.getOutputStream()
            val body = files[path]
            if (body == null) { out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()); return@use }
            val from = range?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull()
            if (from != null) { out.write("HTTP/1.1 206 Partial Content\r\nContent-Length: ${body.size - from}\r\nConnection: close\r\n\r\n".toByteArray()); out.write(body, from, body.size - from) }
            else { out.write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()); out.write(body) }
            out.flush()
        }
    }

    private lateinit var server: TinyServer
    private val body = ByteArray(1_000_000) { (it % 251).toByte() }
    private val ranges = mutableListOf<String?>()

    @Before fun start() { server = TinyServer(mapOf("/movie/1.mp4" to body, "/list/1.m3u8" to ByteArray(0)), ranges).also { it.start() } }

    @After fun stop() { server.stop() }

    private val movie = Movie("s1:mv:1", "s1", null, "Test Film", null, 2020, null, null, "movie:1:mp4", 0)
    private fun downloads(busy: () -> Boolean = { false }, ref: String = "/movie/1.mp4"): Downloads {
        val resolver = object : StreamUrlResolver {
            override suspend fun resolve(sourceId: String, streamRef: String): String? = "http://127.0.0.1:${server.port}$ref"
            override suspend fun headers(sourceId: String): Map<String, String> = emptyMap()
            override suspend fun userAgent(sourceId: String): String? = null
        }
        val context = ApplicationProvider.getApplicationContext<android.app.Application>()
        context.getSharedPreferences("downloads", android.content.Context.MODE_PRIVATE).edit().clear().apply()
        return Downloads(context, resolver, busy, CoroutineScope(SupervisorJob() + Dispatchers.IO)).also { it.wifiOnly = false; it.folder.listFiles()?.forEach { f -> f.delete() } }
    }

    private fun waitFor(d: Downloads, id: String, vararg states: SaveState) {
        val end = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < end) { if (d.item(id)?.state in states) return; Thread.sleep(50) }
    }

    @Test fun aMovieIsSavedAndPlaysFromTheDevice() {
        val d = downloads()
        d.enqueue(movie)
        waitFor(d, movie.id, SaveState.DONE, SaveState.FAILED)
        assertEquals(SaveState.DONE, d.item(movie.id)?.state)
        val uri = assertNotNull(d.localUri(movie.id)).let { d.localUri(movie.id)!! }
        assertTrue(uri.startsWith("file:"))
        assertEquals(body.size, java.io.File(java.net.URI(uri)).length().toInt())
        assertEquals(body.size.toLong(), d.item(movie.id)?.bytesTotal)
    }

    @Test fun aRemovedDownloadLeavesNoFileAndNoRecord() {
        val d = downloads()
        d.enqueue(movie); waitFor(d, movie.id, SaveState.DONE)
        d.remove(movie.id)
        assertNull(d.item(movie.id)); assertNull(d.localUri(movie.id))
        assertTrue(d.folder.listFiles().orEmpty().isEmpty())
    }

    @Test fun nothingStartsWhileSomethingIsPlaying() {
        var playing = true
        val d = downloads(busy = { playing })
        d.enqueue(movie)
        Thread.sleep(1_500)
        assertEquals(SaveState.QUEUED, d.item(movie.id)?.state)                      // held back
        playing = false
        waitFor(d, movie.id, SaveState.DONE)
        assertEquals(SaveState.DONE, d.item(movie.id)?.state)
    }

    @Test fun anInterruptedDownloadCarriesOnWithARangeRequest() {
        val d = downloads()
        val name = app.streamsetu.core.data.repo.SavedTitles.fileName(movie.id, "http://x/movie/1.mp4")
        java.io.File(d.folder, "$name.part").writeBytes(body.copyOfRange(0, 400_000))
        d.enqueue(movie)
        waitFor(d, movie.id, SaveState.DONE)
        assertEquals(SaveState.DONE, d.item(movie.id)?.state)
        assertTrue(ranges.contains("bytes=400000-"))
        assertTrue(java.io.File(java.net.URI(d.localUri(movie.id)!!)).readBytes().contentEquals(body))        // the two parts join into the whole file
    }

    @Test fun aListOfPiecesIsRefusedWithAReason() {
        val d = downloads(ref = "/list/1.m3u8")
        d.enqueue(movie); waitFor(d, movie.id, SaveState.FAILED)
        assertEquals(SaveState.FAILED, d.item(movie.id)?.state)
        assertTrue(d.item(movie.id)?.error.orEmpty().contains("pieces"))
    }
}
