package app.streamsetu.tv

import app.streamsetu.core.data.repo.SaveState
import app.streamsetu.core.data.repo.SavedTitle
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.ui.components.downloadStatusOf
import app.streamsetu.tv.ui.screens.live.ChannelGrouper
import app.streamsetu.tv.ui.screens.live.groupChannels
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** The list pipelines keep their results while doing less work: appending a page groups only the new rows, and a download tick inside the same 5 percent step changes nothing. */
class ScrollPipelineTests {
    private fun ch(i: Int, name: String) = Channel("c$i", "s", null, name, i, null, "ref$i", null)
    private val names = listOf("BBC One", "BBC One HD", "CNN", "CNN FHD", "Sky News", "BBC One 4K", "Eurosport", "CNN HD", "Arte", "Arte SD")
    private val all = names.mapIndexed { i, n -> ch(i, n) }

    @Test fun appendedPagesGiveTheSameGroupsAsGroupingEverythingAgain() {
        val g = ChannelGrouper()
        for (n in listOf(3, 4, 6, 10)) assertEquals(groupChannels(all.take(n)), g.group(all.take(n)))
    }

    @Test fun aChangedOrShorterListStartsAgain() {
        val g = ChannelGrouper()
        g.group(all)
        val changed = all.take(6) + ch(99, "Other")
        assertEquals(groupChannels(changed), g.group(changed))
        assertEquals(groupChannels(all.take(2)), g.group(all.take(2)))
    }

    private fun saved(id: String, state: SaveState, done: Long, total: Long = 1000, series: String? = null) =
        SavedTitle(id, ContentKind.MOVIE, "s", "ref", series, "t", null, state, done, total, null, 0L, null)

    @Test fun downloadProgressInsideOneStepMakesAnEqualMap() {
        val a = downloadStatusOf(listOf(saved("m1", SaveState.DOWNLOADING, 500)))
        val b = downloadStatusOf(listOf(saved("m1", SaveState.DOWNLOADING, 510)))
        assertEquals(a, b)
        assertEquals(0.5f, a.getValue("m1").second, 0.001f)
    }

    @Test fun aSeriesShowsItsMostActiveEpisode() {
        val m = downloadStatusOf(listOf(saved("e1", SaveState.DONE, 1000, series = "x"), saved("e2", SaveState.DOWNLOADING, 200, series = "x")))
        assertEquals(SaveState.DOWNLOADING, m.getValue("x").first)
    }
}
