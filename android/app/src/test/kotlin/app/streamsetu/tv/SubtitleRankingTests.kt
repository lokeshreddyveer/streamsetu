package app.streamsetu.tv

import app.streamsetu.core.subtitles.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.GZIPOutputStream

class SubtitleRankingTests {
    private fun c(id: Long, release: String = "Movie.2020.1080p.WEB-DL", title: String? = "Movie", year: Int? = 2020, season: Int? = null, episode: Int? = null, downloads: Int = 100, hi: Boolean = false,
                  hash: Boolean = false, trusted: Boolean = false, machine: Boolean = false, ai: Boolean = false, runtime: Int? = null, lang: String = "en", rating: Double = 0.0) =
        SubtitleCandidate(id, "$release.srt", release, lang, downloads, rating, hi, hash, trusted, ai, machine, title, year, season, episode, runtime)
    private val movie = SubtitleWanted("Movie", 2020, null, null, "en")
    private val ep = SubtitleWanted("Show", null, 2, 5, "en")

    @Test fun aHashMatchWinsEvenWithFewDownloadsAndIsExactFileHigh() {
        val r = SubtitleRanking.rank(listOf(c(1, downloads = 90_000), c(2, hash = true, downloads = 3)), movie)
        assertEquals(2L, r.first().candidate.fileId); assertEquals(SubtitleMatch.EXACT_FILE, r.first().match); assertEquals(SubtitleConfidence.HIGH, r.first().confidence)
    }

    @Test fun theOwnReleaseNameMakesItAnExactFileMatch() {
        val w = movie.copy(fileName = "Movie.2020.1080p.WEB-DL.mkv")
        val r = SubtitleRanking.rank(listOf(c(1, release = "Movie.2020.720p.BluRay", downloads = 50_000), c(2, release = "Movie 2020 1080p WEB DL")), w)
        assertEquals(2L, r.first().candidate.fileId); assertEquals(SubtitleMatch.EXACT_FILE, r.first().match)
    }

    @Test fun aSubtitleForAnotherEpisodeOrTitleIsDroppedNotRankedLow() {
        val r = SubtitleRanking.rank(listOf(c(1, title = "Show", season = 2, episode = 4, year = null), c(2, title = "Show", season = 2, episode = 5, year = null), c(3, title = "Other Show", season = 2, episode = 5, year = null)), ep)
        assertEquals(listOf(2L), r.map { it.candidate.fileId })
    }

    @Test fun aFilmNeverGetsAnEpisodesSubtitle() { assertTrue(SubtitleRanking.rank(listOf(c(1, season = 1, episode = 2)), movie).isEmpty()) }

    @Test fun anEpisodeWithNoStatedNumbersRanksBelowOneThatConfirmsItAndCannotBeHigh() {
        val r = SubtitleRanking.rank(listOf(c(1, title = "Show", year = null, downloads = 100_000), c(2, title = "Show", season = 2, episode = 5, year = null, downloads = 1)), ep)
        assertEquals(2L, r.first().candidate.fileId); assertNotEquals(SubtitleConfidence.HIGH, r.last().confidence)
    }

    @Test fun sameEpisodeAndRuntimeIsNamedAsSuchOnlyWhenTheRuntimeReallyAgrees() {
        val w = ep.copy(runtimeMinutes = 44)
        val r = SubtitleRanking.rank(listOf(c(1, release = "Show.S02E05.A", title = "Show", year = null, season = 2, episode = 5, runtime = 44), c(2, release = "Show.S02E05.B", title = "Show", year = null, season = 2, episode = 5, runtime = null)), w)
        assertEquals(SubtitleMatch.SAME_EPISODE_AND_RUNTIME, r.first { it.candidate.fileId == 1L }.match); assertEquals(SubtitleMatch.TITLE_MATCH, r.first { it.candidate.fileId == 2L }.match)
    }

    @Test fun aRuntimeThatIsFarOffPushesTheResultDown() {
        val w = movie.copy(runtimeMinutes = 120)
        val r = SubtitleRanking.rank(listOf(c(1, runtime = 95, downloads = 1000), c(2, runtime = 120, downloads = 10)), w)
        assertEquals(2L, r.first().candidate.fileId)
    }

    @Test fun theLanguageMustBeTheOneAskedFor() { assertEquals(listOf(1L), SubtitleRanking.rank(listOf(c(1, lang = "en"), c(2, lang = "fr"), c(3, lang = "pt-BR")), movie).map { it.candidate.fileId }); assertEquals(listOf(3L), SubtitleRanking.rank(listOf(c(3, lang = "pt-BR")), movie.copy(language = "pt")).map { it.candidate.fileId }) }

    @Test fun hearingImpairedFollowsThePreference() {
        val list = listOf(c(1, release = "A", hi = true), c(2, release = "B", hi = false))
        assertEquals(2L, SubtitleRanking.rank(list, movie).first().candidate.fileId); assertEquals(1L, SubtitleRanking.rank(list, movie.copy(preferHearingImpaired = true)).first().candidate.fileId)
    }

    @Test fun machineAndAiTranslationsRankBelowHumanOnesAndAreNeverAppliedByThemselves() {
        val r = SubtitleRanking.rank(listOf(c(1, release = "A", machine = true, downloads = 100_000, trusted = true), c(2, release = "B", ai = true, downloads = 100_000), c(3, release = "C", downloads = 5)), movie)
        assertEquals(3L, r.first().candidate.fileId); assertFalse(r.first { it.candidate.fileId == 1L }.safeToApplyAutomatically); assertFalse(r.first { it.candidate.fileId == 2L }.safeToApplyAutomatically)
    }

    @Test fun lowConfidenceIsNeverSafeToApplyAutomatically() {
        val r = SubtitleRanking.rank(listOf(c(1, title = null, year = null, release = "something else entirely", downloads = 500)), movie)
        assertEquals(SubtitleConfidence.LOW, r.single().confidence); assertFalse(r.single().safeToApplyAutomatically)
    }

    @Test fun aClearTitleAndYearMatchIsSafeToApply() {
        val r = SubtitleRanking.rank(listOf(c(1, downloads = 5000, trusted = true, rating = 8.0)), movie).single()
        assertEquals(SubtitleMatch.TITLE_MATCH, r.match); assertTrue(r.safeToApplyAutomatically)
    }

    @Test fun theSameSubtitleUploadedTwiceIsShownOnceAsTheBetterOne() {
        val r = SubtitleRanking.rank(listOf(c(1, release = "Movie.2020.WEB-DL", downloads = 10), c(2, release = "movie 2020 web dl", downloads = 900)), movie)
        assertEquals(1, r.size); assertEquals(2L, r.single().candidate.fileId)
    }

    @Test fun theOrderIsStableForEqualScores() {
        val r = SubtitleRanking.rank(listOf(c(5, release = "A"), c(3, release = "B"), c(4, release = "C")), movie)
        assertEquals(listOf(3L, 4L, 5L), r.map { it.candidate.fileId })
    }

    @Test fun everyResultCarriesTheReasonAndTheDetailLine() {
        val r = SubtitleRanking.rank(listOf(c(1, hash = true, hi = true, downloads = 1234)), movie).single()
        assertTrue(r.detail.startsWith("Exact file match · High confidence")); assertTrue(r.detail.contains("hearing impaired")); assertTrue(r.detail.contains("1,234 downloads")); assertTrue(r.reasons.contains("Made for this exact file"))
    }

    @Test fun titleWordsIgnoreQualityBracketsAndPunctuation() {
        assertEquals(listOf("alpha", "beta"), SubtitleRanking.words("Alpha.Beta.2024.1080p.WEB-DL.x265 (Telugu)").filter { it != "2024" })
        assertEquals(1.0, SubtitleRanking.similarity("The.Movie.1080p", "the movie"), 0.001)
    }

    // ---- files

    private fun srt(n: Int = 3) = (1..n).joinToString("\n\n") { "$it\n00:00:0$it,000 --> 00:00:0${it + 1},000\nLine $it" }

    @Test fun aNormalSubtitleIsAcceptedAndNamedByItsContent() {
        val ok = SubtitleFiles.check(srt().toByteArray()); assertEquals("srt", ok.extension); assertEquals(64, ok.sha256.length); assertEquals(ok.sha256 + ".srt", SubtitleFiles.fileNameFor(ok))
        assertEquals("the same content is the same file", ok.sha256, SubtitleFiles.check(srt().toByteArray()).sha256)
    }

    @Test fun windowsLineEndingsBomUtf16AndLegacyEncodingsAreAllReadAsUtf8() {
        assertTrue(SubtitleFiles.check(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + srt().toByteArray()).text.startsWith("1\n00:00"))
        assertFalse(SubtitleFiles.check(srt().replace("\n", "\r\n").toByteArray()).text.contains("\r"))
        assertTrue(SubtitleFiles.check(byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + srt().toByteArray(Charsets.UTF_16LE)).text.contains("Line 1"))
        assertTrue(SubtitleFiles.check(("1\n00:00:01,000 --> 00:00:02,000\ncafé").toByteArray(charset("windows-1252"))).text.contains("café"))
    }

    @Test fun somethingThatIsNotSubtitlesIsRefused() {
        for (bad in listOf(ByteArray(0), "<html>hello</html>".toByteArray(), "just words".toByteArray(), ByteArray(300) { 7 })) try { SubtitleFiles.check(bad); fail("accepted") } catch (_: SubtitleFiles.Rejected) {}
    }

    @Test fun aFileOverTheLimitIsRefusedBeforeItIsReadAndAStreamThatLiesAboutItsSizeIsCutOff() {
        try { SubtitleFiles.readLimited(SubtitleFiles.MAX_BYTES + 1L, ByteArray(1).inputStream()); fail() } catch (_: SubtitleFiles.Rejected) {}
        try { SubtitleFiles.readLimited(-1, ByteArray(SubtitleFiles.MAX_BYTES + 10).inputStream()); fail() } catch (_: SubtitleFiles.Rejected) {}
        assertEquals(5, SubtitleFiles.readLimited(5, ByteArray(5).inputStream()).size)
    }

    @Test fun aCompressedFileThatExpandsTooFarIsRefusedAndASmallOneIsUnpacked() {
        fun gz(b: ByteArray) = ByteArrayOutputStream().also { GZIPOutputStream(it).use { z -> z.write(b) } }.toByteArray()
        assertTrue(SubtitleFiles.check(gz(srt().toByteArray())).text.contains("Line 1"))
        val bomb = gz(ByteArray(SubtitleFiles.MAX_EXPANDED_BYTES + 1000) { '0'.code.toByte() }); assertTrue("a bomb is small compressed", bomb.size < SubtitleFiles.MAX_BYTES)
        try { SubtitleFiles.check(bomb); fail() } catch (_: SubtitleFiles.Rejected) {}
    }

    @Test fun nothingAProviderSendsEverChoosesTheFileName() { assertFalse(SubtitleFiles.fileNameFor(SubtitleFiles.check(srt().toByteArray())).contains("/")); assertTrue(SubtitleFiles.fileNameFor(SubtitleFiles.check(srt().toByteArray())).matches(Regex("[0-9a-f]{64}\\.(srt|vtt)"))) }

    // ---- the metadata cache (needs org.json: it runs under the Android test setup)
}
