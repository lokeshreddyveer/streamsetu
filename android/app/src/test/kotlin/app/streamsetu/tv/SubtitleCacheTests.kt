package app.streamsetu.tv

import app.streamsetu.core.subtitles.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SubtitleCacheTests {
    @get:Rule val tmp = TemporaryFolder()
    private val want = SubtitleWanted("Movie", 2020, null, null, "en")
    private val found = listOf(SubtitleCandidate(7, "a.srt", "Movie.2020", "en", 10, 7.5, true, false, true, false, false, "Movie", 2020, null, null, 99, "OpenSubtitles"))

    @Test fun whatTheProviderSaidIsKeptAndReadBackExactly() { val c = SubtitleMetadataCache(tmp.newFolder("m")); c.put(want, found); assertEquals(found, c.get(want)) }
    @Test fun anAnswerIsKeptOnlyForItsTimeAndAnotherQuestionIsAnotherAnswer() {
        var t = 1_000L; val c = SubtitleMetadataCache(tmp.newFolder("m2"), ttlMs = 100, now = { t }); c.put(want, found)
        assertNotNull(c.get(want)); assertNull(c.get(want.copy(language = "hi"))); assertNull(c.get(want.copy(season = 1, episode = 2))); t += 101; assertNull(c.get(want))
    }
    @Test fun aDamagedCacheFileIsIgnoredNotTrusted() { val d = tmp.newFolder("m3"); val c = SubtitleMetadataCache(d); java.io.File(d, c.key(want) + ".json").writeText("{ not json"); assertNull(c.get(want)) }
    @Test fun theCacheIsBoundedAndHoldsNoLoginOrAddress() {
        val d = tmp.newFolder("m4"); val c = SubtitleMetadataCache(d); repeat(SubtitleMetadataCache.MAX_FILES + 20) { c.put(want.copy(title = "T$it"), found) }
        assertTrue((d.listFiles()?.size ?: 0) <= SubtitleMetadataCache.MAX_FILES)
        val text = d.listFiles()!!.first().readText(); assertFalse(text.contains("http")); assertFalse(text.contains("password")); assertFalse(text.contains("token"))
    }
}
