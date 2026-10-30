package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchResultOrder
import app.streamsetu.core.data.repo.SearchTab
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Phase 7 builds on the services that exist. These fail if it grows an engine of its own, if the phone's Search changes, or if Search stops being one list. */
class SportsDiscoveryStaticTests {
    private fun kotlinFiles(vararg roots: String) = roots.flatMap { File(it).walkTopDown().filter { f -> f.extension == "kt" }.toList() }
    private val discovery get() = kotlinFiles("src/main/kotlin/app/streamsetu/tv/sports/discovery")

    @Test fun discoveryHasNoNetworkPlaybackRecordingCatchUpOrReminderEngineOfItsOwn() {
        assertTrue(discovery.size >= 6)
        val forbidden = listOf("OkHttp", "StreamResolver", "HttpURLConnection", "java.net.URL", "Request.Builder", "streamRef", "http://", "https://", "ExoEngine", "MediaPlayer", "AlarmManager", "ScheduledRecordings", "RecordService",
            "CatchUpPlayable", "timeshift", "Notification", "insertFollow", "insertReminder", "insertRecording", "@Insert", "@Query", "@Dao", "execSQL", "sports_follows", "sports_reminders", "sports_recordings", "Dispatchers.Main")
        for (f in discovery) { val t = f.readText(); for (w in forbidden) assertFalse("${f.name} must not contain $w", t.contains(w)) }
    }

    @Test fun onlyTheFollowServiceWritesFollows() {
        val users = kotlinFiles("src/main/kotlin").filter { it.readText().let { t -> t.contains("insertFollow(") || t.contains("deleteFollow(") || t.contains("replaceFollowKey(") } }.map { it.name }
        assertEquals(listOf("SportsFollowService.kt"), users)
        val remindersWriters = kotlinFiles("src/main/kotlin").filter { it.readText().contains("insertReminder(") }.map { it.name }
        assertEquals(listOf("SportsReminderService.kt"), remindersWriters)
        val recordingWriters = kotlinFiles("src/main/kotlin").filter { it.readText().contains("insertRecording(") || it.readText().contains("replaceClosedRecording(") }.map { it.name }
        assertEquals(listOf("SportsRecordingService.kt"), recordingWriters)
    }

    @Test fun thereIsOneSearchEngineAndTheLibraryResultsDoNotWaitForSports() {
        val engines = kotlinFiles("src/main/kotlin").filter { Regex("""class\s+\w*Search\w*\s*[(:{]""").containsMatchIn(it.readText()) }.map { it.name }
        assertFalse("no second search engine is constructed anywhere but the container", kotlinFiles("src/main/kotlin").any { it.name != "StreamSetuApp.kt" && it.name != "AppModule.kt" && it.readText().contains("GlobalSearch(") })
        val content = File("src/main/kotlin/app/streamsetu/tv/ui/screens/search/SearchContent.kt").readText()
        val library = content.indexOf("c.globalSearch.searchProgressive(")
        val sports = content.indexOf("sportsItems = c.sportsSearch.search(")
        assertTrue(library > 0 && sports > 0)
        assertEquals("separate effects: the library is not held up by Sports", 2, Regex("LaunchedEffect\\(").findAll(content.substring(minOf(library, sports) - 600, maxOf(library, sports) + 100)).count().coerceAtLeast(2))
        val sportsBlock = content.substring(content.lastIndexOf("LaunchedEffect(", sports), sports)
        assertFalse("not started by focus", sportsBlock.contains("Focus")); assertTrue("keyed on the words and who may see what", sportsBlock.contains("query") && sportsBlock.contains("sportsContext"))
        assertTrue("a Sports failure keeps the library's results as they are", content.contains("sportsItems = emptyList() }") && !content.substring(sports, sports + 600).contains("results = null"))
        assertTrue(engines.isNotEmpty())
    }

    @Test fun thePhonesSearchIsUnchanged() {
        assertEquals(listOf(SearchKind.MOVIE, SearchKind.SERIES, SearchKind.CHANNEL, SearchKind.EPISODE, SearchKind.PROGRAMME, SearchKind.FOLDER, SearchKind.COLLECTION), SearchResultOrder)
        assertTrue("no Sports group is in the order the phone lists", SearchResultOrder.none { it.name.startsWith("SPORTS_") })
        for (tab in SearchTab.values()) if (tab != SearchTab.ALL) assertTrue("only All can carry Sports", tab.kinds.none { it.name.startsWith("SPORTS_") })
        for (f in kotlinFiles("src/main/kotlin/app/streamsetu/tv/ui/phone")) {
            val t = f.readText()
            assertFalse("${f.name} must not show Sports results", t.contains("SportsSearchOrder") || t.contains("sportsSearch") || t.contains("SPORTS_EVENT"))
        }
        val global = File("../data/src/main/kotlin/app/streamsetu/core/data/repo/GlobalSearch.kt").readText()
        val body = global.substring(global.indexOf("class GlobalSearch("))
        assertFalse("the library's search never returns a Sports result", body.contains("SPORTS_"))
        val phoneMore = File("src/main/kotlin/app/streamsetu/tv/ui/phone/PhoneMore.kt").readText()
        assertTrue("the only phone change is the exhaustive routing branch", phoneMore.contains("is SearchTarget.OpenSports -> Unit"))
    }

    @Test fun discoveryDiagnosticsAreCountsAndFixedWordsOnly() {
        val fields = DiscoveryReport::class.java.declaredFields.filter { !it.name.startsWith("$") }
        assertEquals(setOf("kind", "outcome", "results", "millis", "cacheHit", "ambiguous", "unclassified", "failure"), fields.map { it.name }.toSet())
        assertTrue(fields.none { it.type == List::class.java || it.type == Map::class.java })
    }

    @Test fun theWindowsAreOneDefinition() {
        val (from, to) = SportsWindow.hub(D.NOW); assertEquals(72 * D.H, to - from); assertEquals(0L, from % 900_000L)
        val (hf, ht) = SportsWindow.history(D.NOW, 9); assertEquals("capped at three days", 3 * 24 * D.H, ht - hf)
        assertEquals(0L, SportsWindow.history(D.NOW, 0).let { it.second - it.first })
        val vm = File("src/main/kotlin/app/streamsetu/tv/ui/screens/sports/SportsViewModel.kt").readText()
        assertTrue("the hub, the pages and Search ask the service the same question", vm.contains("deps.load(scope, from, from + 72 * 3_600_000L)") && File("src/main/kotlin/app/streamsetu/tv/sports/discovery/RealSportsSearchSource.kt").readText().contains("SportsWindow.hub"))
    }

    @Test fun nothingInDiscoveryReadsTheWholeRecordingHistory() {
        val service = File("src/main/kotlin/app/streamsetu/tv/sports/recording/SportsRecordingService.kt").readText()
        assertTrue("the screens' recordings are open ones plus the most recent ended ones", service.contains("recentRecordingsFlow(it, RECENT_CLOSED)"))
        assertFalse("discovery never reads the recordings table", discovery.any { Regex("""\bdao\b|SportsDao|recordingsFlow""").containsMatchIn(it.readText()) })
    }
}
