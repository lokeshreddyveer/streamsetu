package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Random

/**
 * How long the automatic artwork queue takes to start and run through a library of the real shape (66,540 movies and 18,011 series, 5% without a poster; and a 200k one), and how much memory it holds,
 * with an instant fake network. Runs only when ARTWORK_BENCH=1. JVM and Robolectric SQLite numbers on the development Mac: NOT the speed of a phone or a TV stick (needs real hardware).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ArtworkQueueBenchmark {
    @get:Rule val tmp = TemporaryFolder()
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()

    private fun build(movies: Int, series: Int): AppDatabase {
        val db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
        val raw = db.openHelper.writableDatabase
        raw.execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('S','Playlist','XTREAM','x',1,1,'OK',0,0,0,0,0,0)")
        for (i in 0 until 600) { raw.execSQL("INSERT INTO categories (id, sourceId, kind, name, sortOrder) VALUES ('S-M-$i','S','MOVIE','ENGLISH | Folder $i',$i)"); raw.execSQL("INSERT INTO categories (id, sourceId, kind, name, sortOrder) VALUES ('S-S-$i','S','SERIES','ENGLISH | Folder $i',$i)") }
        val rnd = Random(5)
        raw.beginTransaction()
        val mv = raw.compileStatement("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES (?,?,?,?,?,?,?,?,?,?)")
        for (i in 0 until movies) { mv.clearBindings(); mv.bindString(1, "S:m$i"); mv.bindString(2, "S"); mv.bindString(3, "S-M-${rnd.nextInt(600)}"); mv.bindString(4, "Title ${i} Word${i % 977} (${1990 + i % 35})"); if (rnd.nextInt(100) >= 5) mv.bindString(5, "http://i/$i.jpg"); mv.bindLong(6, 1990L + i % 35); mv.bindString(9, "r$i"); mv.bindLong(10, 1L); mv.executeInsert() }
        val sr = raw.compileStatement("INSERT INTO series (id, sourceId, categoryId, title, posterUrl, backdropUrl, year, rating, plot, providerId, addedAt) VALUES (?,?,?,?,?,NULL,?,NULL,NULL,?,?)")
        for (i in 0 until series) { sr.clearBindings(); sr.bindString(1, "S:s$i"); sr.bindString(2, "S"); sr.bindString(3, "S-S-${rnd.nextInt(600)}"); sr.bindString(4, "Show $i Word${i % 311}"); if (rnd.nextInt(100) >= 5) sr.bindString(5, "http://i/s$i.jpg"); sr.bindLong(6, 2000L + i % 25); sr.bindString(7, "p$i"); sr.bindLong(8, 1L); sr.executeInsert() }
        raw.setTransactionSuccessful(); raw.endTransaction()
        return db
    }

    private fun measure(label: String, movies: Int, series: Int) = runBlocking {
        val db = build(movies, series)
        val folders = FolderRepository(db, LibraryRepository(db, ctx, kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined)), ParentalControls(ctx), kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined))
        val dir = tmp.newFolder(); var t = 1_000_000_000_000L
        val svc = TmdbService(db, { "KEY" }, folders.visibility, dir, { t }, TmdbAuth({ "KEY" })) { u, _ -> t += 100; val q = java.net.URLDecoder.decode(u.substringAfter("query=").substringBefore("&"), "UTF-8"); """{"results":[{"id":1,"title":"$q","poster_path":"/p.jpg","overview":"s","release_date":"2000-01-01"}]}""" }
        val e = ArtworkMatchEngine(db, svc, folders.visibility, dir, { "p" }, { true }, { true }, ArtworkMatchEngine.Config(concurrency = 4, includeSummaryOnly = false), { t }, Dispatchers.Default)
        System.gc(); val before = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
        var peak = before
        val sampler = Thread { while (!Thread.interrupted()) { val u = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }; if (u > peak) peak = u; try { Thread.sleep(20) } catch (x: InterruptedException) { break } } }.also { it.isDaemon = true; it.start() }
        val t0 = System.nanoTime()
        val r = e.runOnce()
        val ms = (System.nanoTime() - t0) / 1_000_000
        sampler.interrupt()
        val p = e.progress.value
        println("BENCH $label: $r in ${ms} ms for ${p.done} titles (${p.total} total); heap before ${before / 1_048_576} MB, peak ${peak / 1_048_576} MB (+${(peak - before) / 1_048_576} MB)")
        db.close()
    }

    @Test fun benchmark() {
        assumeTrue("set ARTWORK_BENCH=1", System.getenv("ARTWORK_BENCH") == "1")
        measure("66,540 movies + 18,011 series", 66_540, 18_011)
        measure("200,000 movies + 50,000 series", 200_000, 50_000)
    }
}
