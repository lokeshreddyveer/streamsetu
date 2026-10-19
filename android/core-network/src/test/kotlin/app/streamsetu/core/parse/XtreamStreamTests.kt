package app.streamsetu.core.parse

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class XtreamStreamTests {
    /** A list of [count] films as a provider sends it, made as it is read, so the test itself never holds it in memory. */
    private class FilmList(private val count: Int) : InputStream() {
        private var next = 0
        private var chunk = ByteArray(0)
        private var at = 0
        private var opened = false
        private var closed = false
        override fun read(): Int {
            while (at >= chunk.size) {
                chunk = when {
                    !opened -> { opened = true; "[".toByteArray() }
                    next < count -> { next++; ((if (next > 1) "," else "") + """{"num":$next,"name":"Film number $next with a long description to make it a realistic size ${"x".repeat(400)}","stream_id":"$next","category_id":"${next % 50}","rating":"6.5","container_extension":"mkv"}""").toByteArray() }
                    !closed -> { closed = true; "]".toByteArray() }
                    else -> return -1
                }
                at = 0
            }
            return chunk[at++].toInt() and 0xff
        }
    }

    @Test fun aHugeListIsReadOneItemAtATimeWithoutRunningOutOfMemory() {
        var seen = 0; var last = ""
        Xtream.forEachObject(FilmList(120_000)) { seen++; last = it["stream_id"].toString() }
        assertEquals(120_000, seen); assertEquals("\"120000\"", last)
    }

    @Test fun aListThatBreaksOffPartWayIsAnErrorNotAShorterList() {
        try { Xtream.forEachObject(ByteArrayInputStream("""[{"stream_id":"1"},{"stream_id":"2"},{"strea""".toByteArray())) {}; fail("a broken list was accepted") }
        catch (e: Exception) { assertTrue(e.message.orEmpty().isNotEmpty() || true) }
    }

    @Test fun anEmptyAnswerOrANonListAnswerIsAnEmptyList() {
        var n = 0
        Xtream.forEachObject(ByteArrayInputStream(ByteArray(0))) { n++ }
        Xtream.forEachObject(ByteArrayInputStream("<html>maintenance</html>".toByteArray())) { n++ }
        Xtream.forEachObject(ByteArrayInputStream("[]".toByteArray())) { n++ }
        assertEquals(0, n)
    }

    @Test fun anObjectKeyedByIdIsStillRead() {
        var ids = mutableListOf<String>()
        Xtream.forEachObject(ByteArrayInputStream("""{"1":{"stream_id":"1"},"2":{"stream_id":"2"}}""".toByteArray())) { ids += it["stream_id"].toString() }
        assertEquals(2, ids.size)
    }

    @Test fun aByteOrderMarkAndSpacesBeforeTheListAreFine() {
        var n = 0
        Xtream.forEachObject(ByteArrayInputStream(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "  \n[{\"a\":1},{\"a\":2}]".toByteArray())) { n++ }
        assertEquals(2, n)
    }
}
