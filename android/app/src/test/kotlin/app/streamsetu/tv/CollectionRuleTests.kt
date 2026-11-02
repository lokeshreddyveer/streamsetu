package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class CollectionRuleTests {
    private lateinit var db: AppDatabase
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private lateinit var browse: BrowseRepository
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private val now get() = System.currentTimeMillis() / 1000

    private fun movie(id: String, title: String, year: Int?, rating: String?, cat: String? = "c1", src: String = "A", added: Long = now) = MovieEntity(id, src, cat, title, null, year, rating, null, "r", added)

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        val library = LibraryRepository(db, ctx, scope); val folders = FolderRepository(db, library, ParentalControls(ctx), scope)
        browse = BrowseRepository(db, library, folders, ctx)
        runBlocking {
            for (id in listOf("A", "B")) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1, "OK"))
            db.catalog().putCategories(listOf(CategoryEntity("c1", "A", "MOVIE", "Telugu | 2026", 0), CategoryEntity("c2", "A", "MOVIE", "Hindi Classics", 1), CategoryEntity("c3", "B", "MOVIE", "Drama", 0)))
            db.catalog().putMovies(listOf(
                movie("m1", "Alpha (Telugu)", 2024, "7.5"), movie("m2", "Beta", 2019, "6.0", cat = "c2"), movie("m3", "Gamma (Hindi)", 1995, "8.2", cat = "c2"),
                movie("m4", "Delta", 2022, null, cat = "c1"), movie("m5", "Epsilon 100%", 2021, "5.0", cat = "c3", src = "B"), movie("m6", "Old", 2010, "9.0", cat = "c3", src = "B", added = now - 100L * 86400),
            ))
        }
        runBlocking { val l = library.entries.first { l -> l.any { it.id == "src:A" } }; library.open(l.first { it.id == "src:A" }) }
    }
    @After fun close() { scope.cancel(); db.close() }

    private fun ids(r: CollectionRule, sources: List<String> = listOf("A")) = runBlocking {
        browse.moviesPage(Browse.Rule("x", r), SortSpec.defaultFor(ContentKind.MOVIE), 90, 0, sources, emptySet()).map { it.id }.toSet()
    }

    @Test fun anEmptyRuleIsNotSaveableAndNeverAList() { assertTrue(CollectionRule().problems().isNotEmpty()); assertTrue(CollectionRule().isEmpty) }
    @Test fun yearRangeFiltersAndABackwardRangeIsRefused() {
        assertEquals(setOf("m1", "m4"), ids(CollectionRule(yearFrom = 2020, yearTo = 2029)))
        assertTrue(CollectionRule(yearFrom = 2025, yearTo = 2020).problems().isNotEmpty())
    }
    @Test fun ratingNeedsARatingAndATitleWithoutOneNeverMatches() { assertEquals(setOf("m1", "m3"), ids(CollectionRule(minRating = 7.0))) }
    @Test fun languageFindsTheBracketOrTheFolderName() { assertEquals(setOf("m1", "m4"), ids(CollectionRule(language = "Telugu"))); assertEquals(setOf("m2", "m3"), ids(CollectionRule(language = "Hindi"))) }
    @Test fun titleAndFolderWordsMatchAnyCase() { assertEquals(setOf("m1"), ids(CollectionRule(titleContains = "ALPH"))); assertEquals(setOf("m2", "m3"), ids(CollectionRule(folderContains = "classics"))) }
    @Test fun everyConditionHasToHoldTogether() { assertEquals(setOf("m1"), ids(CollectionRule(language = "Telugu", minRating = 7.0, yearFrom = 2020))); assertEquals(emptySet<String>(), ids(CollectionRule(language = "Telugu", minRating = 9.0))) }
    @Test fun aRuleOnlyEverShowsTheOpenLibrary() { assertEquals(setOf("m5"), ids(CollectionRule(titleContains = "epsilon"), sources = listOf("B"))); assertEquals(emptySet<String>(), ids(CollectionRule(titleContains = "epsilon"), sources = listOf("A"))) }
    @Test fun aSourceRuleStaysInsideTheLibraryToo() { assertEquals(emptySet<String>(), ids(CollectionRule(sourceId = "B"), sources = listOf("A"))); assertEquals(setOf("m5", "m6"), ids(CollectionRule(sourceId = "B"), sources = listOf("A", "B"))) }
    @Test fun addedWithinDaysUsesTheDatabaseClock() { assertEquals(setOf("m5"), ids(CollectionRule(addedWithinDays = 30, sourceId = "B"), sources = listOf("A", "B"))) }
    @Test fun unwatchedAndFavouritesUseThePersonsOwnLists() = runBlocking {
        db.user().putProgress(ProgressEntity("m1", "MOVIE", null, 600_000, 7_200_000, now, false))
        db.user().putFavorite(FavoriteEntity("m3", "MOVIE", UserRepository.FAVOURITES, now))
        assertEquals(setOf("m2", "m3", "m4"), ids(CollectionRule(unwatched = true)))
        assertEquals(setOf("m3"), ids(CollectionRule(favoritesOnly = true)))
    }
    @Test fun wildcardsAndQuotesInTypedWordsAreLiteralAndNeverBreakTheQuery() {
        assertEquals(emptySet<String>(), ids(CollectionRule(titleContains = "%")))
        assertEquals(setOf("m5"), ids(CollectionRule(titleContains = "100%"), sources = listOf("A", "B")))
        assertEquals(emptySet<String>(), ids(CollectionRule(titleContains = "'; DROP TABLE movies; --")))
        assertTrue(db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM movies").use { it.moveToFirst() && it.getInt(0) == 6 })
    }
    @Test fun aRuleOnAChannelListMatchesNothing() { assertEquals(listOf("1 = 0"), CollectionRuleSql.of(ContentKind.CHANNEL, CollectionRule(language = "Telugu")).conditions) }
    @Test fun theRuleIsDescribedInWordsWithoutAnyAddress() { assertEquals("Telugu · 2020 to 2029 · rating 7+ · unwatched", CollectionRule(language = "Telugu", yearFrom = 2020, yearTo = 2029, minRating = 7.0, unwatched = true).describe()) }

    // ---- the store

    private fun store() = SmartCollectionStore(ctx, "smart-test")
    @Before fun clean() { ctx.getSharedPreferences("smart-test", Context.MODE_PRIVATE).edit().clear().commit() }

    @Test fun aSavedCollectionSurvivesARestartExactly() {
        val rule = CollectionRule(sourceId = "A", yearFrom = 2020, yearTo = 2029, minRating = 7.5, language = "Telugu", unwatched = true, favoritesOnly = true, addedWithinDays = 30, titleContains = "king", folderContains = "2026")
        val id = store().add("Telugu picks", ContentKind.MOVIE, rule).getOrThrow()
        val again = store().get(id)!!
        assertEquals(rule, again.rule); assertEquals("Telugu picks", again.name); assertEquals(ContentKind.MOVIE, again.scope)
    }
    @Test fun anInvalidRuleOrNameIsRefusedWithAReason() {
        assertTrue(store().add("", ContentKind.MOVIE, CollectionRule(language = "Telugu")).isFailure); assertTrue(store().add("x", ContentKind.MOVIE, CollectionRule()).isFailure)
        assertTrue(store().add("x", ContentKind.CHANNEL, CollectionRule(language = "Telugu")).isFailure); assertTrue(store().add("x", ContentKind.MOVIE, CollectionRule(minRating = 11.0)).isFailure)
    }
    @Test fun renameEditAndDeleteChangeOnlyThatCollection() {
        val s = store(); val a = s.add("A", ContentKind.MOVIE, CollectionRule(language = "Hindi")).getOrThrow(); val b = s.add("B", ContentKind.SERIES, CollectionRule(unwatched = true)).getOrThrow()
        s.rename(a, "A2"); s.update(b, "B", CollectionRule(minRating = 8.0)); assertEquals("A2", s.get(a)!!.name); assertEquals(8.0, s.get(b)!!.rule.minRating)
        s.delete(a); assertNull(s.get(a)); assertNotNull(s.get(b)); assertEquals(1, s.of(ContentKind.SERIES).size); assertEquals(0, s.of(ContentKind.MOVIE).size)
    }
    @Test fun aDamagedOrHostileFileIsSkippedNeverTrusted() {
        val text = """[{"id":"ok","name":"Fine","scope":"MOVIE","rule":{"language":"Hindi"}},{"id":"ok","name":"Duplicate","scope":"MOVIE","rule":{"language":"Hindi"}},
            {"id":"c","name":"Channels","scope":"CHANNEL","rule":{"language":"Hindi"}},{"id":"e","name":"Empty rule","scope":"MOVIE","rule":{}},{"id":"w","name":"Bad years","scope":"MOVIE","rule":{"yearFrom":3000}},"junk",{"name":"No id","scope":"MOVIE","rule":{"language":"x"}}]"""
        assertEquals(listOf("Fine"), SmartCollectionStore.decode(text).map { it.name }); assertTrue(SmartCollectionStore.decode("not json").isEmpty()); assertTrue(SmartCollectionStore.decode(null).isEmpty())
    }
    @Test fun enormousSavedValuesAreRefusedUnreadOrSkipped() {
        val huge = "x".repeat(SmartCollectionStore.MAX_SAVED_CHARS + 1)
        assertTrue("a file beyond the limit is ignored whole", SmartCollectionStore.decode("""[{"id":"a","name":"n","scope":"MOVIE","rule":{"language":"Hindi","titleContains":"$huge"}}]""").isEmpty())
        assertTrue("a connection id that is far too long is skipped", SmartCollectionStore.decode("""[{"id":"a","name":"n","scope":"MOVIE","rule":{"sourceId":"${"s".repeat(500)}"}}]""").isEmpty())
        assertTrue("a language that is far too long is skipped", SmartCollectionStore.decode("""[{"id":"a","name":"n","scope":"MOVIE","rule":{"language":"${"L".repeat(500)}"}}]""").isEmpty())
        assertTrue("a rule with unknown extra fields is skipped", SmartCollectionStore.decode("""[{"id":"a","name":"n","scope":"MOVIE","rule":{"language":"Hindi","a":1,"b":1,"c":1,"d":1,"e":1,"f":1,"g":1,"h":1,"i":1,"j":1,"k":1,"l":1,"m":1}}]""").isEmpty())
        assertEquals(1, SmartCollectionStore.decode("""[{"id":"a","name":"n","scope":"MOVIE","rule":{"language":"Hindi"}}]""").size)
        assertTrue(CollectionRule(language = "L".repeat(41)).problems().isNotEmpty()); assertTrue(CollectionRule(sourceId = "s".repeat(81)).problems().isNotEmpty())
        assertTrue(CollectionRule(minRating = Double.NaN).problems().isNotEmpty())
    }

    @Test fun theNumberOfCollectionsIsBounded() {
        val s = store(); repeat(SmartCollectionStore.MAX) { assertTrue(s.add("C$it", ContentKind.MOVIE, CollectionRule(minRating = 5.0)).isSuccess) }
        assertTrue(s.add("one too many", ContentKind.MOVIE, CollectionRule(minRating = 5.0)).isFailure)
    }
    @Test fun aSavedRuleHoldsNoAddressOrLogin() { val saved = SmartCollectionStore.encode(listOf(SmartCollection("i", "n", ContentKind.MOVIE, CollectionRule(language = "Telugu")))); assertFalse(saved.contains("http")); assertFalse(saved.contains("password")) }
}
