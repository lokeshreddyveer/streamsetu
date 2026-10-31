package app.streamsetu.tv.search

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.ui.screens.search.SHOW_MORE_STEP
import app.streamsetu.tv.ui.screens.search.SearchPhase
import app.streamsetu.tv.ui.screens.search.searchPhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** What Android Search takes from the macOS and iOS Search: the same ranking order, per-playlist results, a tab for Episodes and TV Guide, "Show more", and one explicit phase. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SearchParityTests {
    private lateinit var db: AppDatabase
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private lateinit var library: LibraryRepository
    private lateinit var search: GlobalSearch
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        SearchIndex.create(db.openHelper.writableDatabase); PeopleIndex.create(db.openHelper.writableDatabase)
        library = LibraryRepository(db, ctx, scope)
        val folders = FolderRepository(db, library, ParentalControls(ctx))
        search = GlobalSearch(db, library, folders, CollectionRepository(db), SearchRepository(db, library, folders, ctx)) { n -> "Playlist $n" }
        runBlocking { for (id in listOf("A", "B")) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1, "OK")) }
    }
    @After fun close() { scope.cancel(); db.close() }          // the repository keeps collecting from the database: stop it first, or its next read hits a closed database and the error lands in whichever test runs next

    private fun movie(id: String, source: String, title: String) = runBlocking {
        db.catalog().putMovies(listOf(MovieEntity(id, source, null, title, null, 2020, null, null, "ref", 0)))
        SearchIndex.insert(db.openHelper.writableDatabase, listOf(SearchHit("MOVIE", id, source, null, title)))
    }
    private fun openLibrary(vararg ids: String) = runBlocking {
        val entries = library.entries.first { l -> l.any { it.id == "src:${ids[0]}" } }; library.open(entries.first { it.id == "src:${ids[0]}" }); kotlinx.coroutines.yield()
    }

    // ---- ranking: the order the Apple ladder gives (1000 exact, 800 starts with, 600 a word starts with it, 400 contains)

    private fun rank(q: String, vararg titles: String) = titles.sortedByDescending { SearchText.score(it, q) }

    @Test fun theRankingOrderIsTheAppleOrderForTheSameCases() {
        assertEquals(listOf("Inception", "Inception Reloaded", "The Inception", "Reinception"), rank("inception", "Reinception", "The Inception", "Inception Reloaded", "Inception"))
        assertEquals("every typed word starting a word of the title ranks like Apple's word-start tier, above a title that only contains it", listOf("The Dark Knight Rises", "Mydarkknights"), rank("dark knight", "Mydarkknights", "The Dark Knight Rises"))
        for ((q, order) in listOf(
            "inception" to listOf("Inception", "Inception 2", "The Inception", "Reinceptions"),
            "news" to listOf("News", "News Hour", "The News", "Breaking Newsroom"),
            "avatar" to listOf("Avatar", "Avatar The Last Airbender", "James Avatar", "Navatar"),
        )) {
            val scores = order.map { SearchText.score(it, q) }
            assertEquals("$q: strictly the Apple tiers, best first", scores.sortedDescending(), scores)
            assertTrue("$q: exact (1000) and starts-with (800) hold their Apple values", scores[0] == 1000 && scores[1] == 800)
            assertTrue("$q: a word start (600 class) ranks above contains (400 class)", scores[2] > scores[3] && scores[3] >= 300)
        }
        assertEquals("no match is no result", 0, SearchText.score("Casablanca", "inception"))
    }

    // ---- the same title in two playlists is two results

    @Test fun theSameTitleInTwoPlaylistsStaysTwoResultsAndTheSameTitleTwiceInOneShowsOnce() = runBlocking {
        movie("A:m1", "A", "Inception"); movie("A:m2", "A", "Inception"); movie("B:m1", "B", "Inception")
        db.libraries().put(LibraryEntity("both", "Both", 1)); db.libraries().putMembers(listOf(LibraryMemberEntity("both", "A"), LibraryMemberEntity("both", "B")))
        library.open(library.entries.first { l -> l.any { it.id == "lib:both" && it.sourceIds.size == 2 } }.first { it.id == "lib:both" }); kotlinx.coroutines.yield()
        val movies = search.search("inception").byKind[SearchKind.MOVIE].orEmpty()
        assertEquals("one per playlist: A once (its two copies collapse) and B once", 2, movies.size)
        val sources = movies.map { (it.target as SearchTarget.OpenMovie).movie.sourceId }.toSet(); assertEquals(setOf("A", "B"), sources)
        assertTrue("each says which playlist it is in, so the person can choose the version", movies.all { it.subtitle.contains("Playlist") })
        assertEquals(2, movies.map { it.id }.toSet().size)
    }

    // ---- Show more, and the new tabs

    @Test fun eachGroupHasAFirstPageAndAMoreFlagThatShowMoreRaises() = runBlocking {
        for (i in 1..30) movie("A:m$i", "A", "Cricket Night $i")
        openLibrary("A")
        val first = search.search("cricket night")
        assertEquals("a first page of twelve", 12, first.byKind[SearchKind.MOVIE]!!.size); assertTrue("and the group says there is more", SearchKind.MOVIE in first.more)
        val more = search.search("cricket night", SearchTab.ALL, 12, mapOf(SearchKind.MOVIE to SHOW_MORE_STEP))
        assertEquals(30, more.byKind[SearchKind.MOVIE]!!.size.coerceAtMost(30)); assertTrue("all thirty fit in 12 + 24", more.byKind[SearchKind.MOVIE]!!.size > 12)
        assertFalse("nothing left to show", SearchKind.MOVIE in more.more)
        assertEquals("the first rows stay first and in the same order", first.byKind[SearchKind.MOVIE]!!.map { it.id }, more.byKind[SearchKind.MOVIE]!!.take(12).map { it.id })
    }

    @Test fun aGroupWithNothingMoreHasNoMoreFlag() = runBlocking {
        movie("A:m1", "A", "Cricket Night"); openLibrary("A")
        assertTrue(search.search("cricket night").more.isEmpty())
    }

    @Test fun theNewTabsSearchOnlyEpisodesOrOnlyTheGuide() {
        assertEquals(setOf(SearchKind.EPISODE), SearchTab.EPISODES.kinds); assertEquals(setOf(SearchKind.PROGRAMME), SearchTab.GUIDE.kinds)
        assertEquals("Episodes", SearchTab.EPISODES.label); assertEquals("TV Guide", SearchTab.GUIDE.label)
        for (t in listOf(SearchTab.LIVE, SearchTab.MOVIES, SearchTab.SERIES, SearchTab.EPISODES, SearchTab.GUIDE)) assertTrue("${t.name} carries no Sports group", t.kinds.none { it.name.startsWith("SPORTS_") })
    }

    // ---- one explicit phase

    private val none = GlobalResults(); private val some = GlobalResults(mapOf(SearchKind.MOVIE to listOf(SearchItem("m", SearchKind.MOVIE, "t", "", null, SearchTarget.OpenCollection("x", ContentKind.MOVIE), 1))))

    @Test fun thePhaseIsOneValueForEveryCombinationOfWhatTheScreenKnows() {
        assertEquals(SearchPhase.IDLE, searchPhase(true, null, false, false)); assertEquals(SearchPhase.IDLE, searchPhase(true, some, true, true))
        assertEquals(SearchPhase.LOADING, searchPhase(false, null, true, false)); assertEquals("a lookup that has found nothing yet is still loading", SearchPhase.LOADING, searchPhase(false, none, true, false))
        assertEquals(SearchPhase.RESULTS, searchPhase(false, some, true, false)); assertEquals("a late failure keeps the results", SearchPhase.RESULTS, searchPhase(false, some, false, true))
        assertEquals(SearchPhase.EMPTY, searchPhase(false, none, false, false))
        assertEquals(SearchPhase.FAILED, searchPhase(false, null, false, true)); assertEquals(SearchPhase.FAILED, searchPhase(false, none, false, true))
        assertEquals("other kinds of result count as something to show", SearchPhase.RESULTS, searchPhase(false, none, false, false, otherResults = true))
    }

    private val screen get() = java.io.File("src/main/kotlin/app/streamsetu/tv/ui/screens/search/SearchContent.kt").readText()

    @Test fun theScreenOffersTheTabsAShowMoreRowPerGroupAndDrawsFromOnePhase() {
        val t = screen
        assertTrue(t.contains("TypeChip(\"Episodes\"") && t.contains("TypeChip(\"TV Guide\"") && t.contains("MenuAction(\"Episodes\"") && t.contains("MenuAction(\"TV Guide\""))
        assertTrue("one Show more row per group that has more, with a stable key so the remote stays on it", t.contains("if (kind in r.more) item(key = \"more-${'$'}{kind.name}\")"))
        assertTrue("asking for more gives the whole answer at once (no partial lists that would drop the row)", t.contains("if (asked.isEmpty()) c.globalSearch.searchProgressive(") && t.contains("c.globalSearch.search(query, tab, base, asked)"))
        assertTrue(t.contains("val phase = searchPhase(query.isBlank(), r, searching, failed, sportsItems.isNotEmpty())") && t.contains("phase == SearchPhase.LOADING") && t.contains("phase == SearchPhase.EMPTY") && t.contains("phase == SearchPhase.IDLE"))
        assertTrue("the chosen tab survives leaving and coming back", t.contains("held?.extraTab = extraTab") && t.contains("mutableStateOf<SearchTab?>(held?.extraTab)"))
    }
}
