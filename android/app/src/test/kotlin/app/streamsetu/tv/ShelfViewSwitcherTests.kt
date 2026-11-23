package app.streamsetu.tv

import app.streamsetu.core.data.smartmix.ShelfView
import app.streamsetu.tv.ui.screens.home.HomeViewModel.MixShelf
import app.streamsetu.tv.ui.screens.home.ShelfViewSwitcher
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** The switch of one shelf touches that shelf only: nothing else changes, nothing is rebuilt twice, a stale answer is dropped. */
class ShelfViewSwitcherTests {
    private fun shelf(id: String, view: ShelfView?, tag: String) = MixShelf(id, id, tag, emptyList(), view, null)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @Test fun onlyTheSwitchedShelfChangesAndSwitchingBackBuildsNothing() {
        val saved = ArrayList<Pair<String, ShelfView>>(); val built = ArrayList<Pair<String, ShelfView>>()
        val sw = ShelfViewSwitcher(scope, { id, v -> saved += id to v }) { id, v -> built += id to v; shelf(id, v, "$id-${v.wire}") }
        val base = listOf(shelf("top-week", null, "tw"), shelf("trending-library", ShelfView.WEEKLY, "t-weekly"), shelf("genre:action", ShelfView.WEEKLY, "a-weekly"))
        base.forEach(sw::remember)
        sw.switch(base[1], "trending-library", ShelfView.ALL_TIME)
        val after = sw.apply(base)
        assertEquals("the other shelves keep their content, their order and their identity", listOf(base[0], null, base[2]).map { it?.caption }.let { listOf("tw", "t-all", "a-weekly").let { _ -> listOf(after[0].caption, after[1].caption, after[2].caption) } }, listOf("tw", "trending-library-allTime", "a-weekly"))
        assertSame(base[0], after[0]); assertSame(base[2], after[2]); assertEquals(listOf("top-week", "trending-library", "genre:action"), after.map { it.id })
        assertEquals(listOf("trending-library" to ShelfView.ALL_TIME), saved); assertEquals("only that shelf was built, once", listOf("trending-library" to ShelfView.ALL_TIME), built)
        sw.switch(after[1], "trending-library", ShelfView.WEEKLY); sw.switch(sw.apply(base)[1], "trending-library", ShelfView.ALL_TIME); sw.switch(sw.apply(base)[1], "trending-library", ShelfView.WEEKLY)
        assertEquals("switching back and forth builds nothing more", 1, built.size); assertEquals("t-weekly", sw.apply(base)[1].caption)
    }

    @Test fun theControlMovesAtOnceWhileTheTilesWaitAndAStaleBuildIsDropped() = runBlocking {
        val gates = HashMap<ShelfView, CompletableDeferred<MixShelf?>>(); gates[ShelfView.ALL_TIME] = CompletableDeferred(); gates[ShelfView.WEEKLY] = CompletableDeferred()
        val sw = ShelfViewSwitcher(scope, { _, _ -> }) { id, v -> gates[v]!!.await() }
        val current = shelf("genre:drama", ShelfView.WEEKLY, "old")
        sw.switch(current, "genre:drama", ShelfView.ALL_TIME)
        val moved = sw.apply(listOf(current)).single()
        assertEquals("the control moved at once", ShelfView.ALL_TIME, moved.view); assertEquals("and the tiles stayed until the new ones arrive", "old", moved.caption)
        sw.switch(moved, "genre:drama", ShelfView.WEEKLY)          // a newer tap
        gates[ShelfView.ALL_TIME]!!.complete(shelf("genre:drama", ShelfView.ALL_TIME, "stale"))
        assertNotEquals("a stale answer is never shown", "stale", sw.apply(listOf(current)).single().caption)
    }

    @Test fun aRebuildOfHomeClearsEverythingAndWarmingFillsTheOtherView() = runBlocking {
        var builds = 0
        val sw = ShelfViewSwitcher(scope, { _, _ -> }) { id, v -> builds++; shelf(id, v, "built") }
        val base = listOf(shelf("genre:comedy", ShelfView.WEEKLY, "w"), shelf("rediscover", null, "r"))
        base.forEach(sw::remember); sw.warm(base)
        assertEquals("only the switchable shelf was warmed", 1, builds); assertNotNull(sw.cached("genre:comedy", ShelfView.ALL_TIME))
        sw.switch(base[0], "genre:comedy", ShelfView.ALL_TIME); assertEquals("the first tap builds nothing", 1, builds)
        sw.reset(); assertSame(base, sw.apply(base)); assertNull(sw.cached("genre:comedy", ShelfView.ALL_TIME))
    }
}
