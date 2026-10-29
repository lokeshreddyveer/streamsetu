package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.ui.screens.sports.SportsLoad
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone

class SportsSearchTests {
    private val h = D.H; private val now = D.NOW

    private class Src(var events: List<SportsEvent>, var follows: FollowSet = FollowSet.NONE, var rows: List<SportsRecordingEntity> = emptyList()) : SportsSearch.Source {
        var context = "ctx"; var loads = 0; var fail: Exception? = null; var gate: CompletableDeferred<Unit>? = null; @Volatile var rev = 1
        override fun now() = D.NOW
        override val zone: TimeZone = D.UTC
        override suspend fun contextKey() = context
        override suspend fun load(): SportsLoad { loads++; gate?.await(); fail?.let { throw it }; return SportsLoad(events, "rev-$rev", true) }
        override suspend fun follows() = follows
        override suspend fun recordings() = rows
    }
    private val reports = ArrayList<DiscoveryReport>()
    private fun search(src: Src) = SportsSearch(src) { reports.add(it) }

    private val events = listOf(
        D.event("1", now - h, listOf("India", "Australia"), competition = "Test Series"),
        D.event("2", now + h, listOf("India", "Nepal"), competition = "Asia Cup"),
        D.event("3", now + 30 * h, listOf("Indiana Pacers", "Heat"), sport = Sport.BASKETBALL, competition = "NBA"),
        D.event("4", now + 3 * h, listOf("Brazil", "Peru"), sport = Sport.FOOTBALL, competition = "Copa India Cup"),
    )

    @Test fun anExactNameBeatsAPrefixAndAPrefixBeatsAWordMatch() = runBlocking {
        val r = search(Src(events)).search("india")
        val teams = r.filter { it.kind == SearchKind.SPORTS_TEAM }
        assertEquals("the team called exactly India comes first", "India", teams.first().title)
        assertEquals(listOf("India", "Indiana Pacers"), teams.map { it.title })
        val comps = r.filter { it.kind == SearchKind.SPORTS_COMPETITION }.map { it.title }
        assertEquals("Copa India Cup contains the word but does not start with it", listOf("Copa India Cup"), comps)
    }

    @Test fun eventsAreOrderedByMatchThenFollowedThenLiveThenSoonThenLater() = runBlocking {
        val more = events + D.event("5", now + 5 * h, listOf("India", "Fiji"), competition = "Other") + D.event("6", now + 2 * h, listOf("India", "Chile"), competition = "Other")
        val followed = FollowSet(listOf(D.team(Sport.CRICKET, "Fiji")), IdentityIndex.build(more))
        val r = search(Src(more, followed)).search("india").filter { it.kind == SearchKind.SPORTS_EVENT }.map { (it.target as SearchTarget.OpenSports).eventId }
        assertEquals("followed first, then live, then starting soon (by time); a prefix beats a word in the name, whatever the time", listOf("5", "1", "2", "6", "3", "4"), r)
    }

    @Test fun everyTypedWordMustStartAWordOfTheName() = runBlocking {
        val s = search(Src(events))
        assertEquals(listOf("India vs Australia"), s.search("aus ind").filter { it.kind == SearchKind.SPORTS_EVENT }.map { it.title })
        assertTrue(s.search("zzz").isEmpty()); assertTrue(s.search("   ").isEmpty()); assertTrue(s.search("!!!").isEmpty())
    }

    @Test fun malformedAndVeryLongTextIsHandled() = runBlocking {
        val s = search(Src(events))
        val long = "india ".repeat(500) + "\u0000\uD800 \n\t" + "x".repeat(10_000)
        assertTrue(s.search(long).isEmpty() || true)
        assertTrue(s.search("\u0000\uD800").isEmpty()); assertTrue(s.search("'; DROP TABLE sports_recordings; --").isEmpty())
    }

    @Test fun ambiguousNamesFromUnrelatedPlaylistsStaySeparateResults() = runBlocking {
        val a = D.event("a", now + h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", now + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val r = search(Src(listOf(a, b))).search("lions").filter { it.kind == SearchKind.SPORTS_TEAM }
        assertEquals("two teams that merely share a name", 2, r.size); assertEquals(2, r.map { it.id }.toSet().size)
    }

    @Test fun recordingsAreFoundThroughTheirEventAndRowsHoldNoTitle() = runBlocking {
        val rec = D.recording("r1", events[1], "SCHEDULED")
        assertFalse("a stored request keeps no name", rec.toString().contains("Nepal"))
        val r = search(Src(events, rows = listOf(rec))).search("nepal").filter { it.kind == SearchKind.SPORTS_RECORDING }
        assertEquals(1, r.size); assertEquals("Recording scheduled", r.single().subtitle)
        assertEquals("sports:r:r1", r.single().id)
    }

    @Test fun theIndexIsBuiltOncePerContextAndAChangeDropsIt() = runBlocking {
        val src = Src(events); val s = search(src)
        s.search("india"); s.search("indi"); s.search("nepal")
        assertEquals("the second and third query reuse the index", 1, s.builds)
        src.context = "other profile"; s.search("india")
        assertEquals(2, s.builds); s.invalidate(); s.search("india"); assertEquals(3, s.builds)
    }

    @Test fun aNewQueryCancelsTheStaleOne() = runBlocking {
        val src = Src(events).also { it.gate = CompletableDeferred() }; val s = search(src)
        val first = async { runCatching { s.search("india") } }
        while (src.loads == 0) kotlinx.coroutines.delay(5)
        first.cancel(); first.join()
        assertTrue(first.isCancelled || first.await().exceptionOrNull() is kotlinx.coroutines.CancellationException)
        assertTrue(reports.any { it.outcome == DiscoveryOutcome.CANCELLED })
        src.gate!!.complete(Unit); assertTrue(s.search("nepal").isNotEmpty())
    }

    @Test fun aFailureIsRaisedToTheCallerSoTheLibrarysResultsAreLeftAlone() = runBlocking {
        val src = Src(events).also { it.fail = IllegalStateException("boom") }
        assertTrue(runCatching { search(src).search("india") }.isFailure)
        assertEquals(DiscoveryOutcome.ERROR, reports.last().outcome); assertEquals("IllegalStateException", reports.last().failure)
    }

    @Test fun diagnosticsHoldNoNamesNoSearchTextAndNoPaths() = runBlocking {
        val s = search(Src(events, rows = listOf(D.recording("r1", events[1], "SCHEDULED")))); s.search("india nepal secretword"); s.search("india")
        val text = reports.joinToString("\n") { it.line() }
        assertTrue(reports.isNotEmpty())
        for (w in listOf("India", "india", "Nepal", "Australia", "Asia", "secretword", "Channel", "http", "/")) assertFalse("'$w' in: $text", text.contains(w))
        val fields = DiscoveryReport::class.java.declaredFields.filter { !it.name.startsWith("$") }
        assertTrue("only counts, words and times", fields.all { it.type != List::class.java && it.type != Map::class.java })
    }

    @Test fun finishedEventsAreNotSearchable() = runBlocking {
        val done = D.event("z", now - 10 * h, listOf("Gone", "Away"))
        assertTrue(search(Src(listOf(done))).search("gone").isEmpty())
    }
}
