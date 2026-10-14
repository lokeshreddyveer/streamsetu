package app.streamsetu.core.data

import app.streamsetu.core.data.repo.TmdbService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TmdbTests {
    @Test fun searchTextDropsTagsAndTakesTheYear() {
        assertEquals(TmdbService.Query("Heat", 1995), TmdbService.query("Heat (1995) [FHD]", null))
        assertEquals(TmdbService.Query("Heat", 1995), TmdbService.query("EN | Heat HEVC 1080p", 1995))
        assertEquals(TmdbService.Query("The Bear", null), TmdbService.query("The Bear", null))
        assertEquals(TmdbService.Query("Inception", 2010), TmdbService.query("Inception [2010] 4K", 2011))      // a year in the name wins over a stored one
    }

    @Test fun theFirstResultGivesPictureAndStory() {
        val f = TmdbService.parse("""{"results":[{"poster_path":"/abc.jpg","overview":"Cops."},{"poster_path":"/other.jpg"}]}""")
        assertEquals("https://image.tmdb.org/t/p/w342/abc.jpg", f!!.posterUrl); assertEquals("Cops.", f.plot)
        assertNull(TmdbService.parse("""{"results":[]}""")); assertNull(TmdbService.parse("not json"))
        assertNull(TmdbService.parse("""{"results":[{"overview":"No picture"}]}""")!!.posterUrl)
    }
}
