package app.streamsetu.core.data.repo

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

class SearchCommandTests {
    @Test fun screens() {
        assertEquals(listOf<SearchCommand>(SearchCommand.Go(CommandTarget.LIVE_TV)), SearchCommands.parse("go to live tv"))
        assertEquals(listOf<SearchCommand>(SearchCommand.Go(CommandTarget.FAVORITES)), SearchCommands.parse("show me my favourites"))
        assertEquals(listOf<SearchCommand>(SearchCommand.Go(CommandTarget.WATCH_LATER)), SearchCommands.parse("watch later"))
    }
    @Test fun aLoneWordIsJustASearch() { assertTrue(SearchCommands.parse("live").isEmpty()); assertTrue(SearchCommands.parse("recent").isEmpty()) }
    @Test fun playAndLists() {
        assertEquals(listOf<SearchCommand>(SearchCommand.Play("Inception")), SearchCommands.parse("play Inception"))
        assertEquals(listOf<SearchCommand>(SearchCommand.Favourite("Inception", true)), SearchCommands.parse("add Inception to favourites"))
        assertEquals(listOf<SearchCommand>(SearchCommand.WatchLater("Inception", false)), SearchCommands.parse("remove Inception from watch later"))
        assertEquals(listOf<SearchCommand>(SearchCommand.Resume), SearchCommands.parse("resume"))
        assertEquals(listOf<SearchCommand>(SearchCommand.LastChannel), SearchCommands.parse("last channel"))
    }
    @Test fun aScreenWithFilters() {
        assertEquals(listOf<SearchCommand>(SearchCommand.Go(CommandTarget.MOVIES, "telugu movies 2024")), SearchCommands.parse("telugu movies 2024"))
        assertTrue(SearchCommands.parse("inception").isEmpty())
    }
}
