package app.streamsetu.core.data.repo

import app.streamsetu.core.model.ContentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedTitleTests {
    private val movie = SavedTitle("s1:mv:200", ContentKind.MOVIE, "s1", "movie:200:mkv", null, "Big Buck Bunny", "2008", SaveState.DONE, 3_000_000, 3_000_000, "s1_mv_200.mkv", 5, null)
    private val episode = SavedTitle("s1:ep:9", ContentKind.EPISODE, "s1", "9:mp4", "s1:sr:3", "Some Show", "S1 E2 · Pilot", SaveState.DOWNLOADING, 100, 1000, null, 6, "Interrupted")

    @Test fun theListIsKeptBetweenLaunches() = assertEquals(listOf(movie, episode), SavedTitles.decode(SavedTitles.encode(listOf(movie, episode))))

    @Test fun aTitleWithATabOrNewlineSurvives() {
        val odd = movie.copy(title = "Odd\tName\nHere")
        assertEquals("Odd Name Here", SavedTitles.decode(SavedTitles.encode(listOf(odd))).single().title)
    }

    @Test fun anUnreadableLineIsIgnored() {
        assertEquals(listOf(movie), SavedTitles.decode("garbage\n" + SavedTitles.encode(listOf(movie)) + "\nA\tCHANNEL\tx"))
        assertTrue(SavedTitles.decode("").isEmpty())
    }

    @Test fun theFileNameIsSafeAndKeepsTheKindOfFile() {
        assertEquals("s1_mv_200.mkv", SavedTitles.fileName("s1:mv:200", "http://host/movie/u/p/200.mkv?token=1"))
        assertEquals("x.mp4", SavedTitles.fileName("x", "http://host/movie/u/p/200"))
        assertEquals("x.mp4", SavedTitles.fileName("x", "http://host/a.php?x=1"))
    }

    @Test fun aListOfPiecesCannotBeSavedAsOneFile() {
        assertTrue(SavedTitles.isStreamingList("http://host/a/b.m3u8?x=1"))
        assertFalse(SavedTitles.isStreamingList("http://host/a/b.mp4"))
        assertFalse(SavedTitles.isStreamingList("http://host/movie/u/p/1.mkv"))
    }

    @Test fun howFarItIsNeverPassesWhole() {
        assertEquals(0.1f, episode.fraction, 0.001f)
        assertEquals(0f, episode.copy(bytesTotal = 0).fraction, 0f)
        assertEquals(1f, episode.copy(bytesDone = 5000).fraction, 0f)
    }

    @Test fun sizesAreReadable() {
        assertEquals("3 MB", SavedTitles.size(3L shl 20)); assertEquals("1.5 GB", SavedTitles.size((1.5 * (1L shl 30)).toLong())); assertEquals("512 B", SavedTitles.size(512))
    }
}
