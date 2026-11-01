package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.Browse
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.SortSpec
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

/**
 * A page of Movies or Series belongs exactly to the library and restrictions it was asked for: it is read from what is passed in, never from whatever is open or locked when the read happens,
 * so a read that was started before a change cannot return what the change took away.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class BrowsePageKeyTests {
    private lateinit var db: AppDatabase
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    private lateinit var browse: BrowseRepository
    private lateinit var folders: FolderRepository
    private lateinit var library: LibraryRepository
    private val parental by lazy { ParentalControls(ctx) }
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private val sort = SortSpec.defaultFor(ContentKind.MOVIE)

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        library = LibraryRepository(db, ctx, scope)
        folders = FolderRepository(db, library, parental, scope)
        browse = BrowseRepository(db, library, folders, ctx)
        runBlocking {
            for (id in listOf("A", "B")) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1, "OK"))
            db.catalog().putMovies(listOf(
                MovieEntity("a1", "A", "open", "Open one", null, 2020, null, null, "r", 1),
                MovieEntity("a2", "A", "locked", "Locked one", null, 2020, null, null, "r", 2),
                MovieEntity("a3", "A", "adult", "Adult one", null, 2020, null, null, "r", 3),
                MovieEntity("b1", "B", "open", "Other library", null, 2020, null, null, "r", 4),
            ))
        }
    }
    @After fun close() { scope.cancel(); db.close() }

    private fun ids(sources: List<String>, restricted: Set<String>) = runBlocking { browse.moviesPage(Browse.All, sort, 90, 0, sources, restricted).map { it.id }.toSet() }

    @Test fun aPageHoldsOnlyTheSourcesItWasAskedFor() {
        assertEquals(setOf("a1", "a2", "a3"), ids(listOf("A"), emptySet()))
        assertEquals(setOf("b1"), ids(listOf("B"), emptySet()))
        assertEquals(emptySet<String>(), ids(emptyList(), emptySet()))
    }

    @Test fun aPageLeavesOutExactlyTheFoldersItWasToldAreRestricted() {
        assertEquals(setOf("a1", "a3"), ids(listOf("A"), setOf("locked")))
        assertEquals(setOf("a1"), ids(listOf("A"), setOf("locked", "adult")))
    }

    @Test fun whatTheDatabaseSaysAboutLocksNowDoesNotChangeAPageThatWasAskedForWithoutThem() = runBlocking {
        db.folders().put(FolderPrefEntity("MOVIE", "locked", locked = true))          // locked in the database after the request was made
        assertEquals("the page belongs to its request, not to the locks that exist when it is read", setOf("a1", "a2", "a3"), ids(listOf("A"), emptySet()))
        assertEquals(setOf("a1", "a3"), ids(listOf("A"), folders.restrictedIds(ContentKind.MOVIE).first { "locked" in it }))
    }

    @Test fun adultFoldersAreRestrictedWhileAdultContentIsHidden() = runBlocking {
        db.catalog().putCategories(listOf(CategoryEntity("adult", "A", "MOVIE", "XXX Adult", 1), CategoryEntity("open", "A", "MOVIE", "Drama", 2)))
        library.open(library.entries.first { e -> e.any { it.id == "src:A" } }.first { it.id == "src:A" })
        parental.setHideAdult(true)
        assertEquals(true, "adult" in kotlinx.coroutines.withTimeout(5_000) { folders.restrictedIds(ContentKind.MOVIE).first { "adult" in it } })
    }

    @Test fun aSecondPageContinuesTheFirstWithoutRepeatingOrLeakingARestrictedTitle() {
        val page1 = runBlocking { browse.moviesPage(Browse.All, sort, 1, 0, listOf("A"), setOf("locked")).map { it.id } }
        val page2 = runBlocking { browse.moviesPage(Browse.All, sort, 1, 1, listOf("A"), setOf("locked")).map { it.id } }
        assertEquals(2, (page1 + page2).toSet().size); assertFalse("a2" in page1 + page2)
    }
}
