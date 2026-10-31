package app.streamsetu.tv

import app.streamsetu.tv.ui.components.rested
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The pane beside the Live TV list (now and next, the guide) is costly to build, and a held key used to build it for every channel it passed. It now follows the channel the remote has
 * rested on: the first one shows at once, a run of changes shows nothing new until the last one has stayed for the rest time, and each is shown in the end. Exact virtual time, no real waiting.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RestedValueTests {
    private fun scenario(body: suspend kotlinx.coroutines.test.TestScope.(src: MutableSharedFlow<String>, out: MutableList<String>) -> Unit) = runTest(UnconfinedTestDispatcher()) {
        val src = MutableSharedFlow<String>(extraBufferCapacity = 64); val out = ArrayList<String>()
        val job = launch { src.rested(150).collect { out += it } }
        body(src, out); job.cancel()
    }

    @Test fun theFirstValueShowsAtOnce() = scenario { src, out -> src.emit("A"); assertEquals(listOf("A"), out) }

    @Test fun aChangeShowsOnlyOnceItHasRested() = scenario { src, out ->
        src.emit("A"); src.emit("B")
        advanceTimeBy(149); assertEquals("still the old one just before the rest time", listOf("A"), out)
        advanceTimeBy(2); assertEquals(listOf("A", "B"), out)
    }

    @Test fun aRunOfFastChangesShowsOnlyTheLastOne() = scenario { src, out ->
        src.emit("A")
        for (v in listOf("B", "C", "D", "E")) { src.emit(v); advanceTimeBy(40) }          // a held key: a new channel every 40 ms
        assertEquals("nothing is built while the key is held", listOf("A"), out)
        advanceTimeBy(200); assertEquals("the channels in between were never shown", listOf("A", "E"), out)
    }

    @Test fun eachRestedChannelIsShownInTheEnd() = scenario { src, out ->
        src.emit("A"); src.emit("B"); advanceTimeBy(300); src.emit("C"); advanceTimeBy(300)
        assertEquals(listOf("A", "B", "C"), out)
    }
}
