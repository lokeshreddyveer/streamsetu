package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Folder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

/**
 * The "privacy matrix" library: two playlists that are exact twins (A and B), each with a normal, a locked, a hidden and an adult-named folder, plus a title that sits in an open
 * folder of one playlist and in the locked folder of the other. Synthetic titles only. Every surface test builds this and asserts that nothing restricted comes out.
 */
class PrivacyFixture {
    val ctx: Context = ApplicationProvider.getApplicationContext()
    val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    val db: AppDatabase = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries()
        .addCallback(object : androidx.room.RoomDatabase.Callback() { override fun onCreate(db: SupportSQLiteDatabase) { SearchIndex.create(db); PeopleIndex.create(db); LanLog.create(db); Profiles.create(db) } }).build()
    val parental = ParentalControls(ctx)
    val library = LibraryRepository(db, ctx, scope)
    val folders = FolderRepository(db, library, parental, scope)
    val catalog = CatalogRepository(db, library, folders)
    val search = SearchRepository(db, library, folders, ctx)

    companion object {
        // Folders (same names in both playlists: the second playlist's copy is a twin of the first).
        const val OPEN_A = "a-open"; const val LOCKED_A = "a-locked"; const val HIDDEN_A = "a-hidden"; const val ADULT_A = "a-adult"
        const val OPEN_B = "b-open"; const val LOCKED_B = "b-locked"; const val HIDDEN_B = "b-hidden"; const val ADULT_B = "b-adult"
        val names = mapOf("open" to "ENGLISH | GENERAL", "locked" to "PRIVATE VAULT", "hidden" to "HIDDEN SHELF", "adult" to "ADULT XXX")
        // Titles. "Open Film" is fine everywhere. "Secret Film" is only in the locked folder of A and in the (unmarked) twin folder of B. "Split Title" is in the open folder of A and the locked folder of B.
        const val OPEN_FILM_A = "m-open-a"; const val OPEN_FILM_B = "m-open-b"
        const val SECRET_A = "m-secret-a"; const val SECRET_B = "m-secret-b"
        const val SPLIT_A = "m-split-a"; const val SPLIT_B = "m-split-b"
        const val HIDDEN_FILM_A = "m-hidden-a"; const val HIDDEN_FILM_B = "m-hidden-b"
        const val ADULT_FILM_A = "m-adult-a"; const val ADULT_FILM_B = "m-adult-b"
        const val LONE_A = "m-lone-a"; const val LONE_B = "m-lone-b"          // a title whose only other copy is in a restricted folder with a DIFFERENT name
        const val SERIES_SECRET = "s-secret-a"; const val SERIES_OPEN = "s-open-a"
        val restrictedMovies = setOf(SECRET_A, SECRET_B, SPLIT_A, SPLIT_B, HIDDEN_FILM_A, HIDDEN_FILM_B, ADULT_FILM_A, ADULT_FILM_B, LONE_A, LONE_B)
    }

    fun build(): PrivacyFixture = runBlocking {
        for ((id, order) in listOf("A" to 0, "B" to 1)) db.sources().upsert(SourceEntity(id, "Playlist $id", "M3U", "http://x/$id", null, null, true, 1_000L * (order + 1), "OK", sortOrder = order))
        val cats = ArrayList<CategoryEntity>()
        for ((src, tag) in listOf("A" to "a", "B" to "b")) for ((key, name) in names) {
            cats += CategoryEntity("$tag-$key", src, "MOVIE", name, 0)
            cats += CategoryEntity("$tag-s-$key", src, "SERIES", name, 0)
        }
        db.catalog().putCategories(cats)
        fun m(id: String, src: String, cat: String, title: String, year: Int? = 2020, at: Long = 10) = MovieEntity(id, src, cat, title, "http://img/$id.jpg", year, null, null, "ref:$id", at)
        val movies = listOf(
            m(OPEN_FILM_A, "A", OPEN_A, "Open Film"), m(OPEN_FILM_B, "B", OPEN_B, "Open Film"),
            m("m-plain-a", "A", OPEN_A, "Plain Story"), m("m-plain-b", "B", OPEN_B, "Plain Story"),
            m("m-other-a", "A", OPEN_A, "Other Voyage"), m("m-other-b", "B", OPEN_B, "Other Voyage"),
            m(SECRET_A, "A", LOCKED_A, "Secret Film"), m(SECRET_B, "B", LOCKED_B, "Secret Film"),
            m(SPLIT_A, "A", OPEN_A, "Split Title"), m(SPLIT_B, "B", LOCKED_B, "Split Title"),
            m(LONE_A, "A", LOCKED_A, "Lone Copy"), m(LONE_B, "B", OPEN_B, "Lone Copy"),
            m(HIDDEN_FILM_A, "A", HIDDEN_A, "Hidden Film"), m(HIDDEN_FILM_B, "B", HIDDEN_B, "Hidden Film"),
            m(ADULT_FILM_A, "A", ADULT_A, "Adult Film"), m(ADULT_FILM_B, "B", ADULT_B, "Adult Film"),
        )
        db.catalog().putMovies(movies)
        val raw = db.openHelper.writableDatabase
        SearchIndex.upsert(raw, movies.map { SearchHit("MOVIE", it.id, it.sourceId, it.categoryId, it.title) })
        val series = listOf(
            SeriesEntity(SERIES_OPEN, "A", "a-s-open", "Open Show", "http://img/so.jpg", null, 2021, null, null, "p1", 5),
            SeriesEntity(SERIES_SECRET, "A", "a-s-locked", "Secret Show", "http://img/ss.jpg", null, 2021, null, null, "p2", 5),
        )
        db.catalog().putSeries(series)
        SearchIndex.upsert(raw, series.map { SearchHit("SERIES", it.id, it.sourceId, it.categoryId, it.title) })
        // The person's own marks: the locked and hidden folders of playlist A (the same-named folders of B are NOT marked by hand; the twin rules must cover them).
        folders.toggleLocked(ContentKind.MOVIE, folder(LOCKED_A, "A", names["locked"]!!))
        folders.toggleHidden(ContentKind.MOVIE, folder(HIDDEN_A, "A", names["hidden"]!!))
        folders.toggleLocked(ContentKind.SERIES, folder("a-s-locked", "A", names["locked"]!!))
        val both = library.createCombined("Both", listOf("A", "B"))
        library.open(library.entries.first { e -> e.any { it.id == both } }.first { it.id == both })
        this@PrivacyFixture
    }

    fun folder(id: String, source: String, name: String) = Folder(id, source, name, 0)
    fun close() { scope.cancel(); db.close() }
}
