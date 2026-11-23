package app.streamsetu.tv

import app.streamsetu.core.data.db.ContentIdentityEntity
import app.streamsetu.core.data.db.PeopleIndex
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.tv.ui.screens.*
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import app.streamsetu.tv.PrivacyFixture.Companion as F

/** The filmography against the library: how credits find their titles, that restricted ones never do, and what the page shows without a credential or offline. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PersonFilmographyAppTests {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var fx: PrivacyFixture
    private val sources = listOf("A", "B")

    @Before fun open() {
        fx = PrivacyFixture().build()
        runBlocking {
            val rows = ArrayList<ContentIdentityEntity>()
            for (m in fx.db.catalog().moviesByIds(listOf(F.OPEN_FILM_A, F.OPEN_FILM_B, "m-plain-a", "m-plain-b", F.SECRET_A, F.SECRET_B, F.SPLIT_A, F.SPLIT_B, F.LONE_A, F.LONE_B, F.HIDDEN_FILM_A, F.ADULT_FILM_A)))
                rows += ContentIdentityEntity(m.id, "MOVIE", m.sourceId, IdentityKey.ofOrFallback(m.title), m.year, null, 2, false, null, 0L, IdentityKey.VERSION)
            for (s in fx.db.catalog().seriesByIds(listOf(F.SERIES_OPEN, F.SERIES_SECRET))) rows += ContentIdentityEntity(s.id, "SERIES", s.sourceId, IdentityKey.ofOrFallback(s.title), s.year, null, 2, false, null, 0L, IdentityKey.VERSION)
            fx.db.identity().putAll(rows)
        }
    }
    @After fun close() = fx.close()

    private fun credit(title: String, year: Int?, id: Long = 1, tv: Boolean = false, original: String? = null) = Credit(id, tv, title, original, year, year?.let { "$it-01-01" }, "https://image.tmdb.org/t/p/w342/x.jpg", null, 1.0, null, null)
    private fun match(vararg c: Credit, ids: LibraryTmdbIds = LibraryTmdbIds { _, _ -> emptyList() }) = runBlocking { LibraryMatcher(fx.db, fx.folders.visibility, ids).match(c.toList(), sources) }

    @Test fun titleAndYearMatchFoldsVersionsAndTwinsIntoOneHit() {
        val h = match(credit("Open Film", 2020, 1))
        val hit = h.getValue("movie1")
        assertEquals("the two playlists' copies are one tile", 2, hit.versions)
        assertEquals("the preferred source stands for it", "A", hit.movie!!.sourceId)
        assertEquals("B", runBlocking { LibraryMatcher(fx.db, fx.folders.visibility).match(listOf(credit("Open Film", 2020, 1)), listOf("B", "A")) }.getValue("movie1").movie!!.sourceId)
    }

    @Test fun aYearApartStillMatchesTwoYearsApartDoesNot() {
        assertTrue(match(credit("Open Film", 2021, 1)).isNotEmpty()); assertTrue(match(credit("Open Film", 2019, 1)).isNotEmpty())
        assertTrue(match(credit("Open Film", 2023, 1)).isEmpty()); assertTrue("no year, no name match", match(credit("Open Film", null, 1)).isEmpty())
    }

    @Test fun anOriginalTitleAlsoMatchesAndSeriesMatchSeries() {
        assertTrue(match(credit("Something Else", 2020, 1, original = "Plain Story")).isNotEmpty())
        assertTrue("a series credit is not a film", match(credit("Open Show", 2021, 2, tv = false)).isEmpty())
        assertNotNull(match(credit("Open Show", 2021, 2, tv = true))["tv2"]?.series)
    }

    @Test fun aStoredTmdbIdIsExactEvenWhenTheNameAndYearDiffer() {
        val ids = LibraryTmdbIds { id, tv -> if (id == 99L && !tv) listOf("m-plain-a") else emptyList() }
        val hit = match(credit("A Totally Different Name", 1999, 99), ids = ids).getValue("movie99")
        assertEquals("m-plain-a", hit.movie!!.id)
    }

    @Test fun restrictedTitlesAreNeverInYourLibrary() {
        val h = match(credit("Secret Film", 2020, 1), credit("Split Title", 2020, 2), credit("Lone Copy", 2020, 3), credit("Hidden Film", 2020, 4), credit("Adult Film", 2020, 5), credit("Secret Show", 2021, 6, tv = true))
        assertTrue("leaked: ${h.keys}", h.isEmpty())
        val byId = LibraryTmdbIds { _, _ -> listOf(F.SECRET_A, F.SPLIT_A) }
        assertTrue("an exact id of a restricted title is not available either", match(credit("Whatever", 2000, 7), ids = byId).isEmpty())
    }

    // ---- what the page shows
    private val credits = """{"cast":[{"id":1,"media_type":"movie","title":"Open Film","release_date":"2020-05-05","poster_path":"/a.jpg","popularity":3.0},{"id":2,"media_type":"movie","title":"Far Away","release_date":"2011-05-05","poster_path":"/b.jpg","popularity":2.0}]}"""
    private fun loader(dir: java.io.File, key: String?, fail: Boolean = false, calls: MutableList<String> = ArrayList(), now: () -> Long = { System.currentTimeMillis() }, online: Boolean = true, error: Exception = IOException("no answer")): PersonPageLoader {
        val auth = TmdbAuth({ key }, { null }, dir, now)
        val people = TmdbPeople(auth, dir, { u, _ -> calls += u; if (fail) throw error; if ("combined_credits" in u) credits else if ("search/person" in u) """{"results":[{"id":7,"name":"Ann Actor","known_for":[{"title":"Open Film"}]}]}""" else """{"id":7,"name":"Ann Actor","biography":"Bio.","known_for_department":"Acting"}""" }, now)
        return PersonPageLoader(people, LibraryMatcher(fx.db, fx.folders.visibility), { n -> personTitles(fx.db, fx.catalog, fx.folders.visibility, sources, n) }, { sources }, { e -> TmdbProblem.message(e, online, false) })
    }
    private fun run(l: PersonPageLoader, id: Long? = 7L): List<PersonPageState> { val out = ArrayList<PersonPageState>(); runBlocking { l.load("Ann Actor", id, "Open Film", "en") { out += it } }; return out }

    @Test fun fullFilmographyMarksWhatIsInTheLibrary() {
        val last = run(loader(tmp.newFolder(), "KEY")).last()
        assertTrue(last.fullList); assertFalse(last.loading); assertNull(last.note)
        assertEquals(listOf(true, false), last.tiles.map { it.inLibrary })
        assertEquals(1 to 2, FilmographyView.counts(last.tiles, FilmKind.ALL).let { it.second to it.first })
    }

    @Test fun noCredentialFallsBackToTheLocalListWithAQuietLine() {
        val raw = fx.db.openHelper.writableDatabase
        PeopleIndex.save(raw, F.OPEN_FILM_A, "MOVIE", "A", listOf("Ann Actor"), SearchText::normalize)
        PeopleIndex.save(raw, F.SECRET_A, "MOVIE", "A", listOf("Ann Actor"), SearchText::normalize)
        val calls = ArrayList<String>()
        val s = run(loader(tmp.newFolder(), null, calls = calls)).last()
        assertEquals(PersonNotes.NO_KEY, s.note); assertFalse(s.fullList)
        assertEquals(listOf("Open Film"), s.tiles.map { it.credit.title }); assertTrue(s.tiles.all { it.inLibrary }); assertTrue(calls.isEmpty())
    }

    @Test fun offlineWithNothingSavedFallsBackAndOfflineWithASavedCopyKeepsIt() {
        val dir = tmp.newFolder()
        val s = run(loader(dir, "KEY", fail = true, online = false)).last()
        assertEquals(PersonNotes.OFFLINE, s.note); assertFalse(s.fullList)
        run(loader(dir, "KEY"))                                           // saved now
        dir.listFiles()!!.forEach { it.setLastModified(System.currentTimeMillis() - 40L * TmdbFiles.DAY_MS) }          // stale: shown at once, refresh fails
        val seen = run(loader(dir, "KEY", fail = true, online = false))
        assertTrue("the saved copy comes first, at once", seen.first().fullList && seen.first().loading)
        assertEquals(PersonNotes.OFFLINE, seen.last().note); assertTrue(seen.last().fullList); assertEquals(2, seen.last().tiles.size)
    }

    @Test fun aFreshSavedCopyIsNotAskedForAgainAndANameIsResolvedWhenThereIsNoId() {
        val dir = tmp.newFolder(); val calls = ArrayList<String>()
        run(loader(dir, "KEY", calls = calls), id = null)
        assertTrue(calls.any { "search/person" in it })
        calls.clear(); val s = run(loader(dir, "KEY", calls = calls), id = 7L)
        assertTrue("a fresh copy needs no request", calls.isEmpty()); assertEquals(1, s.size)
    }

    @Test fun offlineIsSaidOnlyWithoutAConnectionAndEveryOtherFailureHasItsOwnWordsAndARetry() {
        fun last(online: Boolean, e: Exception) = run(loader(tmp.newFolder(), "KEY", fail = true, online = online, error = e)).last()
        val gone = last(false, IOException("x")); assertEquals(PersonNotes.OFFLINE, gone.note); assertTrue(gone.retry)
        val silent = last(true, IOException("x")); assertEquals("The details service did not answer. Try again.", silent.note); assertTrue("a Retry is offered", silent.retry)
        assertEquals("TMDB did not accept your key. Check it in Settings.", last(true, app.streamsetu.core.net.HttpStatusException(401)).note)
        assertEquals("TMDB is busy right now. Try again in a moment.", last(true, app.streamsetu.core.net.HttpStatusException(429, 5)).note)
        assertEquals(TmdbProblem.Kind.BUILT_IN_REJECTED, TmdbProblem.kind(app.streamsetu.core.net.HttpStatusException(403), true, builtIn = true))
        assertNull("no note and no retry when it worked", run(loader(tmp.newFolder(), "KEY")).last().note)
    }
}
