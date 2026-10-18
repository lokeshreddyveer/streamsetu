package app.streamsetu.core.data.repo

import app.streamsetu.core.model.ContentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchQueueTests {
    private class Memory : QueueStore { var text = ""; override fun read() = text; override fun write(value: String) { text = value } }
    private val a = QueuedTitle(ContentKind.MOVIE, "m1", "Alpha")
    private val b = QueuedTitle(ContentKind.MOVIE, "m2", "Beta")
    private val show = QueuedTitle(ContentKind.SERIES, "s1", "Gamma Show")

    @Test fun titlesPlayInTheOrderTheyWereAdded() {
        val q = WatchQueue(Memory()); q.add(a); q.add(show)
        assertEquals(a, q.popNext()); assertEquals(show, q.popNext()); assertNull(q.popNext())
    }

    @Test fun playNextGoesToTheFrontAndATitleIsNeverQueuedTwice() {
        val q = WatchQueue(Memory()); q.add(a); q.add(b); q.add(b, next = true)
        assertEquals(listOf("m2", "m1"), q.items.value.map { it.id })
        q.add(a)                                    // adding again moves it to the end, it does not appear twice
        assertEquals(listOf("m2", "m1"), q.items.value.map { it.id })
    }

    @Test fun aTitleCanBeTakenOutOrTheWholeLineCleared() {
        val q = WatchQueue(Memory()); q.add(a); q.add(b)
        q.remove("m1")
        assertEquals(listOf("m2"), q.items.value.map { it.id }); assertFalse(q.contains("m1"))
        q.clear(); assertTrue(q.items.value.isEmpty())
    }

    @Test fun theLineIsKeptBetweenLaunches() {
        val store = Memory()
        WatchQueue(store).apply { add(a); add(show) }
        assertEquals(listOf(a, show), WatchQueue(store).items.value)
    }

    @Test fun aTitleWithATabOrANewlineInItsNameSurvives() {
        val store = Memory()
        WatchQueue(store).add(QueuedTitle(ContentKind.MOVIE, "m3", "Odd\tName\nHere"))
        assertEquals("Odd Name Here", WatchQueue(store).items.value.single().title)
    }

    @Test fun anUnreadableLineIsIgnored() {
        val store = Memory().apply { text = "garbage\nMOVIE\tm1\tAlpha\nCHANNEL\tc1\tNo" }
        assertEquals(listOf(a), WatchQueue(store).items.value)
    }
}
