package app.streamsetu.tv.ui.screens.search

import app.streamsetu.core.data.repo.GlobalResults
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SearchPresentationTests {
    private fun item(id: String, title: String, kind: SearchKind = SearchKind.MOVIE) = SearchItem(id, kind, title, "", null, SearchTarget.OpenCollection(id, app.streamsetu.core.model.ContentKind.MOVIE), 0)
    private fun results(vararg items: SearchItem) = GlobalResults(items.groupBy { it.kind })

    @Test fun anExactTitleIsTheBestMatchWhateverItsCaseOrAccents() {
        val r = results(item("m1", "Pushpa 2"), item("m2", "Pushpa"), item("s1", "Pushpa The Series", SearchKind.SERIES))
        assertEquals("m2", bestMatchOf(r, "  pushpa ")?.id)
        assertEquals("m1", bestMatchOf(r, "PUSHPA 2")?.id)
        assertNull(bestMatchOf(r, "pushp"))
    }
    @Test fun theBestMatchIsNotListedAgainInItsGroup() {
        val r = results(item("m1", "Leo"), item("m2", "Leo Das"), item("m3", "Leon"))
        val best = bestMatchOf(r, "leo")
        assertEquals(listOf("m2", "m3"), withoutBest(r.byKind.getValue(SearchKind.MOVIE), best).map { it.id })
        assertEquals(listOf("m1", "m2", "m3"), withoutBest(r.byKind.getValue(SearchKind.MOVIE), null).map { it.id })       // no exact match: nothing is removed
    }
    @Test fun doneGoesToTheExactMatchThenTheFirstResultInGroupOrder() {
        val r = results(item("c1", "News Channel", SearchKind.CHANNEL), item("m1", "News"), item("m2", "News Hour"))
        assertEquals("m1", doneResultId(r, "news"))                                 // the exact title, although a channel is listed first
        assertEquals(SearchKind.entries.firstNotNullOf { k -> r.byKind[k]?.firstOrNull() }.id, doneResultId(r, "new"))      // no exact title: the first result as shown
        assertNull(doneResultId(GlobalResults(), "anything"))
    }
    @Test fun resultsComeBeforeCommandsAndAskAi() {
        assertEquals(listOf(DoneStep.RESULT, DoneStep.ACTION), doneSteps(hasResult = true))
        assertEquals(listOf(DoneStep.ACTION), doneSteps(hasResult = false))
    }
}
