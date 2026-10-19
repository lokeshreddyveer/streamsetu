package app.streamsetu.core.data.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RecordingFilesTests {
    @Test fun aRecordingIsNamedByChannelAndTimeAndReadBack() {
        val name = RecordingFiles.fileName("News 24 | HD/4K", 1_792_000_000_000)
        assertTrue(name.endsWith(".ts")); assertTrue('/' !in name && '|' !in name)
        val (title, at) = RecordingFiles.parse(name)!!
        assertEquals("News 24 _ HD_4K", title)
        assertEquals(1_792_000_000_000 / 1000, at / 1000)
    }

    @Test fun aFileThatIsNotOursIsIgnored() { assertNull(RecordingFiles.parse("holiday.ts")); assertNull(RecordingFiles.parse("x__notadate.ts")) }

    @Test fun aChannelNameWithTheSeparatorStillReadsBack() = assertEquals("A__B", RecordingFiles.parse(RecordingFiles.fileName("A__B", 1_792_000_000_000))!!.first)

    @Test fun theFolderIsListedNewestFirstAndOtherFilesAreSkipped() {
        val dir = createTempDir()
        File(dir, RecordingFiles.fileName("Old", 1_700_000_000_000)).writeText("a")
        File(dir, RecordingFiles.fileName("New", 1_790_000_000_000)).writeText("bb")
        File(dir, "notes.txt").writeText("x"); File(dir, RecordingFiles.fileName("Part", 1_780_000_000_000) + ".part").writeText("x")
        assertEquals(listOf("New", "Old"), RecordingFiles.list(dir).map { it.title })
        assertEquals(2L, RecordingFiles.list(dir).first().bytes)
        dir.deleteRecursively()
    }

    @Test fun thePlayIdRoundTrips() {
        assertEquals("a__b.ts", RecordingFiles.fileOf(RecordingFiles.playId("a__b.ts")))
        assertNull(RecordingFiles.fileOf("s1:mv:1"))
    }
}
