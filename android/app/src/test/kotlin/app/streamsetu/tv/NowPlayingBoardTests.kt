package app.streamsetu.tv

import app.streamsetu.core.sync.lan.LanRecord
import app.streamsetu.tv.sync.NowPlayingBoard
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class NowPlayingBoardTests {
    private fun rec(device: String, title: String, ts: Long, deleted: Boolean = false) = LanRecord("now", listOf(device), ts, deleted,
        if (deleted) null else buildJsonObject { put("title", title); put("pos", 12.0); put("dev", "Fire TV"); put("src", "abc"); put("kind", "movie"); put("prov", "7") })

    @Test fun showsWhatAnotherDeviceIsPlayingAndForgetsItWhenItStops() {
        val b = NowPlayingBoard(); val t = System.currentTimeMillis()
        b.ingest(listOf(rec("tv", "Film", t)))
        assertEquals(listOf("Film"), b.current().map { it.title }); assertEquals("Fire TV", b.current().first().deviceName)
        b.ingest(listOf(rec("tv", "", t + 1000, deleted = true)))
        assertTrue(b.current().isEmpty())
    }
    @Test fun anOlderRecordDoesNotReplaceANewerOne() {
        val b = NowPlayingBoard(); val t = System.currentTimeMillis()
        b.ingest(listOf(rec("tv", "New", t))); b.ingest(listOf(rec("tv", "Old", t - 5000)))
        assertEquals(listOf("New"), b.current().map { it.title })
    }
    @Test fun staleEntriesAreLeftOut() {
        val b = NowPlayingBoard(); b.ingest(listOf(rec("tv", "Film", System.currentTimeMillis() - 10 * 60_000)))
        assertTrue(b.current().isEmpty())
    }
}
