package app.streamsetu.tv

import android.content.Context
import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.streamsetu.core.data.db.*
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.data.repo.smartmix.*
import app.streamsetu.core.data.smartmix.PoolRequest
import app.streamsetu.core.data.smartmix.ShelfSpec
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Folder
import app.streamsetu.core.sync.CatalogStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Random

/**
 * Measurements on synthetic libraries of the real library's shape (66,540 movies, 18,011 series, 14,879 channels, 632 folders, twice as two twin playlists; and a 200k one). Runs only when
 * SMARTMIX_BENCH=1 (it takes minutes). These are JVM + Robolectric SQLite timings on the development Mac: they show plans and relative costs, NOT the speed of a TV stick or phone.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SmartMixBenchmark {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), AppDatabase::class.java)
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private val out = StringBuilder()
    private fun say(s: String) { println("BENCH $s"); out.appendLine(s) }

    private val langs = listOf("ENGLISH", "HINDI", "TAMIL", "TELUGU", "KANNADA", "MALAYALAM", "ARABIC", "SPANISH", "FRENCH", "KOREAN", "TURKISH", "ITALIAN")
    private val words = listOf("Midnight", "River", "Crimson", "Silent", "Garden", "Iron", "Paper", "Echo", "Winter", "Golden", "Hollow", "Lantern", "Harbor", "Velvet", "Cinder", "Meadow", "Falcon", "Marble", "Ember", "Orchid", "Summit", "Willow", "Copper", "Drift")
    private val quals = listOf("", "", "", " FHD", " FHD", " HD", " 4K", " SD", " HDCAM", "")

    private class Counts(val movies: Int, val series: Int, val channels: Int, val mFolders: Int, val sFolders: Int, val cFolders: Int)

    /** Zipf-shaped sizes: a few folders hold most titles. */
    private fun folderOf(rnd: Random, folders: Int): Int { val u = rnd.nextDouble(); return minOf(folders - 1, (Math.pow(u, 2.2) * folders).toInt()) }

    private fun fill(db: SupportSQLiteDatabase, src: String, c: Counts, seed: Long) {
        val rnd = Random(seed)
        db.execSQL("INSERT INTO sources (id, name, type, address, enabled, lastSyncAt, status, sortOrder, draft, channelCount, movieCount, seriesCount, lastOpenedAt) VALUES ('$src','Playlist $src','XTREAM','x',1,${System.currentTimeMillis()},'OK',${if (src == "A") 0 else 1},0,${c.channels},${c.movies},${c.series},0)")
        fun cat(kind: String, n: Int) { for (i in 0 until n) db.execSQL("INSERT INTO categories (id, sourceId, kind, name, sortOrder) VALUES ('$src-$kind-$i','$src','$kind','${langs[i % langs.size]} | ${if (kind == "CHANNEL") "LIVE" else "GROUP"} ${i / langs.size}',$i)") }
        cat("MOVIE", c.mFolders); cat("SERIES", c.sFolders); cat("CHANNEL", c.cFolders)
        val mv = db.compileStatement("INSERT INTO movies (id, sourceId, categoryId, title, posterUrl, year, rating, plot, streamRef, addedAt) VALUES (?,?,?,?,?,?,?,?,?,?)")
        val titleRnd = Random(seed xor 0x5bd1e995L)       // the titles are the same in both twin playlists; only ids and the order of the work differ
        val works = ArrayList<Pair<String, Int>>()          // (title, year) of the works seen so far: a reused work keeps its year, as another language or quality of the same film does
        for (i in 0 until c.movies) {
            val tr = Random(7L * 100003 + i)             // same title for the same i in both playlists
            val reuse = works.isNotEmpty() && tr.nextDouble() < 0.25
            val (base, year) = if (reuse) works[tr.nextInt(works.size)] else Pair("${words[tr.nextInt(words.size)]} ${words[tr.nextInt(words.size)]} ${tr.nextInt(900)}", 1985 + (Math.pow(tr.nextDouble(), 0.5) * 41).toInt()).also { works += it }
            val lang = langs[tr.nextInt(langs.size)]
            val title = "$base ($year)${if (reuse) " ($lang)" else ""}${quals[tr.nextInt(quals.size)]}"
            val cat = "$src-MOVIE-${folderOf(tr, c.mFolders)}"
            mv.clearBindings(); mv.bindString(1, "$src:m$i"); mv.bindString(2, src); mv.bindString(3, cat); mv.bindString(4, title)
            if (tr.nextDouble() < 0.87) mv.bindString(5, "http://img.example/$i.jpg"); mv.bindLong(6, year.toLong())
            mv.bindString(9, "ref:$src:$i"); mv.bindLong(10, 1_700_000_000_000L + (i / 700) * 86_400_000L + tr.nextInt(80_000))
            mv.executeInsert()
        }
        val sr = db.compileStatement("INSERT INTO series (id, sourceId, categoryId, title, posterUrl, backdropUrl, year, rating, plot, providerId, addedAt) VALUES (?,?,?,?,?,NULL,?,NULL,NULL,?,?)")
        for (i in 0 until c.series) {
            val tr = Random(11L * 100003 + i)
            val year = 1990 + tr.nextInt(36)
            sr.clearBindings(); sr.bindString(1, "$src:s$i"); sr.bindString(2, src); sr.bindString(3, "$src-SERIES-${folderOf(tr, c.sFolders)}")
            sr.bindString(4, "${words[tr.nextInt(words.size)]} ${words[tr.nextInt(words.size)]} Show ${tr.nextInt(500)} ($year)"); sr.bindString(5, "http://img.example/s$i.jpg"); sr.bindLong(6, year.toLong()); sr.bindString(7, "p$i"); sr.bindLong(8, 1_700_000_000_000L + (i / 300) * 86_400_000L)
            sr.executeInsert()
        }
        val ch = db.compileStatement("INSERT INTO channels (id, sourceId, categoryId, name, streamRef, catchupDays, sortOrder, addedAt, isRadio) VALUES (?,?,?,?,?,0,?,?,0)")
        for (i in 0 until c.channels) { ch.clearBindings(); ch.bindString(1, "$src:c$i"); ch.bindString(2, src); ch.bindString(3, "$src-CHANNEL-${i % c.cFolders}"); ch.bindString(4, "Channel $i"); ch.bindString(5, "ref:$src:c$i"); ch.bindLong(6, i.toLong()); ch.bindLong(7, 1_700_000_000_000L); ch.executeInsert() }
    }

    private fun <T> time(label: String, warm: Int = 3, runs: Int = 10, block: () -> T): T {
        var last: T? = null
        repeat(warm) { last = block() }
        val t = LongArray(runs) { val s = System.nanoTime(); last = block(); System.nanoTime() - s }.sorted()
        say("  %-58s p50 %8.2f ms   p95 %8.2f ms".format(label, t[runs / 2] / 1e6, t[(runs * 95 / 100).coerceAtMost(runs - 1)] / 1e6))
        return last!!
    }
    private fun plan(db: SupportSQLiteDatabase, sql: String) = db.query("EXPLAIN QUERY PLAN $sql").use { c -> buildList { while (c.moveToNext()) add(c.getString(3)) }.joinToString(" ; ") }
    private fun size(name: String) = ctx.getDatabasePath(name).length() / 1024 / 1024

    private fun run(name: String, label: String, perSource: Counts, sources: List<String>) {
        say("=== $label: ${sources.size} playlist(s), per playlist ${perSource.movies} movies / ${perSource.series} series / ${perSource.channels} channels / ${perSource.mFolders + perSource.sFolders + perSource.cFolders} folders ===")
        helper.createDatabase(name, 10).apply {
            beginTransaction(); try { sources.forEachIndexed { i, s -> fill(this, s, perSource, 100L + i) }; setTransactionSuccessful() } finally { endTransaction() }
            close()
        }
        val sizeBefore = size(name)
        val t0 = System.nanoTime()
        helper.runMigrationsAndValidate(name, 11, true, *AppDatabase.MIGRATIONS).close()
        say("  migration 10 -> 11 (6 tables, 2 big indexes on movies/series): %.0f ms; file %d MB -> %d MB".format((System.nanoTime() - t0) / 1e6, sizeBefore, size(name)))

        val db = Room.databaseBuilder(ctx, AppDatabase::class.java, name).addMigrations(*AppDatabase.MIGRATIONS).build()
        val raw = db.openHelper.writableDatabase
        SearchIndex.create(raw); PeopleIndex.create(raw); LanLog.create(raw); Profiles.create(raw)
        val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
        val library = LibraryRepository(db, ctx, scope)
        val parental = ParentalControls(ctx)
        val folders = FolderRepository(db, library, parental, scope)
        val catalog = CatalogRepository(db, library, folders)
        runBlocking {
            val id = library.createCombined("All", sources); library.open(library.entries.first { l -> l.any { it.id == id } }.first { it.id == id })
        }
        // the person's marks: 50 locked folders, 3 hidden ones (in the first playlist)
        runBlocking {
            val a = sources.first()
            val cats = db.catalog().categoriesOfKind("MOVIE").filter { it.sourceId == a }
            for (c in cats.filter { it.id != "$a-MOVIE-0" && it.id != "$a-MOVIE-1" }.take(50)) folders.toggleLocked(ContentKind.MOVIE, Folder(c.id, a, c.name, 0))
            for (c in cats.takeLast(3)) folders.toggleHidden(ContentKind.MOVIE, Folder(c.id, a, c.name, 0))
        }
        say("  rows: movies ${runBlocking { db.catalog().movieTotal() }}, series ${runBlocking { db.catalog().seriesTotal() }}, channels ${runBlocking { db.catalog().channelTotal() }}")

        // --- identity fill (a library read before the identity table existed) ---
        val store = IdentityStore(db)
        val before = size(name)
        var n = 0; val t1 = System.nanoTime(); var worst = 0L
        while (true) { val s = System.nanoTime(); val k = runBlocking { store.backfillStep(2000) }; worst = maxOf(worst, System.nanoTime() - s); if (k == 0) break; n += k }
        val fillMs = (System.nanoTime() - t1) / 1e6
        say("  identity fill of $n titles in 2,000-row batches: %.0f ms total (%.0f rows/s), slowest batch %.0f ms; file +%d MB; coverage %.3f".format(fillMs, n / (fillMs / 1000), worst / 1e6, size(name) - before, runBlocking { store.coverage() }))
        val sample = (0 until 100_000).map { "Title ${it % 997} (20${it % 25}) (HINDI) FHD" }
        val td = System.nanoTime(); sample.forEach { Derive.derive("MOVIE", it, "HINDI | GROUP 1", 2000 + it.length % 20) }; say("  Derive.derive: %.2f us/row (100k rows, JVM, warm-up not excluded)".format((System.nanoTime() - td) / 1e3 / sample.size))
        say("  identity buckets with more than one item: " + raw.query("SELECT COUNT(*) FROM (SELECT 1 FROM content_identity WHERE kind='MOVIE' AND sourceId='${sources.first()}' GROUP BY identityKey, year HAVING COUNT(*) > 1)").use { it.moveToFirst(); it.getInt(0) })

        // --- twin detection ---
        if (sources.size > 1) { time("SourceTwins.recompute (both kinds, 1 pair)", 1, 5) { runBlocking { SourceTwins.recompute(db) } }
            say("  twin rows: " + runBlocking { db.identity().twins().joinToString { "${it.kind} ${it.matched}/${minOf(it.totalA, it.totalB)}" } }) }

        // --- candidate pool and folder queries ---
        val ids = library.sourceIds.value
        val inList = ids.joinToString(",") { "'$it'" }
        val oldRecent = "SELECT id, sourceId, categoryId, title, year, rating, addedAt, posterUrl FROM movies WHERE sourceId IN ($inList) ORDER BY addedAt DESC LIMIT 1500"
        say("  plan old recent pool : " + plan(raw, oldRecent))
        say("  plan new recent pool : " + plan(raw, "SELECT id, sourceId, categoryId, title, year, rating, addedAt, posterUrl FROM movies WHERE sourceId = '${ids.first()}' AND posterUrl IS NOT NULL AND posterUrl != '' ORDER BY addedAt DESC LIMIT 1500"))
        fun cursorCount(sql: String) = raw.query(sql).use { var k = 0; while (it.moveToNext()) k++; k }
        time("recent pool 1500, old: IN(playlists) ORDER BY addedAt") { cursorCount(oldRecent) }
        time("recent pool 1500, new: one query per playlist + merge") { runBlocking { ids.flatMap { db.catalog().recentMovieCandidates(it, 1500) }.sortedByDescending { it.addedAt }.take(1500) }.size }
        val bigFolder = "${ids.first()}-MOVIE-0"; val smallFolder = "${ids.first()}-MOVIE-150"
        for ((nm, f) in listOf("biggest" to bigFolder, "small" to smallFolder)) {
            say("  plan folder head old ($nm): " + plan(raw, "SELECT * FROM movies WHERE categoryId = '$f' ORDER BY title LIMIT 12"))
            say("  plan folder head new ($nm): " + plan(raw, "SELECT id FROM movies WHERE sourceId = '${ids.first()}' AND categoryId = '$f' ORDER BY addedAt DESC LIMIT 12"))
            time("first 12 of the $nm folder, old: categoryId + ORDER BY title") { runBlocking { db.catalog().moviesIn(f, 12).first() }.size }
            time("first 12 of the $nm folder, new: (sourceId, categoryId, addedAt)") { runBlocking { db.catalog().movieFolderHead(ids.first(), f, 12) }.size }
        }
        time("folder counts GROUP BY categoryId over all movies (today's folder list)") { runBlocking { db.catalog().movieFolderCounts(ids).first() }.size }
        time("categories + prefs read for Visibility (all kinds)") { runBlocking { folders.visibility.excludedFolders(ContentKind.MOVIE, Visibility.Surface.SEARCH).size } }

        // --- visibility with 50 locked + 3 hidden folders ---
        var cold = 0L
        run { val fresh = Visibility(db, { true }, { emptySet() }); val s = System.nanoTime(); runBlocking { fresh.snapshot(Visibility.Surface.RECOMMEND) }; cold = System.nanoTime() - s }
        say("  Visibility.snapshot(RECOMMEND), cold (builds the restricted-title index over ${runBlocking { folders.visibility.excludedFolders(ContentKind.MOVIE, Visibility.Surface.RECOMMEND).size }} folders): %.1f ms".format(cold / 1e6))
        time("Visibility.snapshot(RECOMMEND), warm") { runBlocking { folders.visibility.snapshot(Visibility.Surface.RECOMMEND) } }
        time("Visibility.snapshot(HISTORY)") { runBlocking { folders.visibility.snapshot(Visibility.Surface.HISTORY) } }

        // --- the banner mix ---
        time("featured(): old ORDER BY RANDOM() over whole table x2 kinds") { runBlocking { db.catalog().randomMovies(24, ids).size + db.catalog().randomSeries(24, ids).size } }
        time("featured(): new pool 1500 + visibility + canonical pick") { runBlocking { catalog.featured(12).size } }

        // --- the whole Smart Mix pipeline (real adapter over the identity tables) ---
        run {
            val rt = Runtime.getRuntime()
            fun usedMb(): Long { System.gc(); return (rt.totalMemory() - rt.freeMemory()) / 1024 / 1024 }
            val pref = "hindi"
            val mix = SmartMixHome(db, folders.visibility, { ids }, { pref }, null)
            val base = usedMb()
            // seed some watch history so signals/affinity/dismissals are not empty
            raw.execSQL("INSERT OR IGNORE INTO progress(itemId, kind, seriesId, positionMs, durationMs, updatedAt, completed) SELECT id, 'MOVIE', NULL, 100, 100, ${System.currentTimeMillis()}, 1 FROM movies WHERE sourceId = '${ids.first()}' ORDER BY addedAt DESC LIMIT 200")
            raw.execSQL("INSERT OR IGNORE INTO watch_time(day, hour, itemId, kind, title, ms) SELECT ${java.time.LocalDate.now().toEpochDay()}, 20, id, 'MOVIE', 'x', 3600000 FROM movies WHERE sourceId = '${ids.first()}' ORDER BY addedAt DESC LIMIT 200")
            val t0 = System.nanoTime(); val first = runBlocking { mix.home("main") }; val firstMs = (System.nanoTime() - t0) / 1e6
            say("  PIPELINE first Home data ready (cold: restrictions, activity, 6 shelves, ${first.sumOf { it.result.ids.size }} titles in ${first.size} shelves): %.0f ms".format(firstMs))
            time("PIPELINE home() warm cache (5 s activity cache)", 1, 5) { runBlocking { mix.home("main") }.size }
            time("PIPELINE home() after invalidate (full rebuild of activity + 6 shelves)", 1, 5) { mix.invalidate(); runBlocking { mix.home("main") }.size }
            for (shelf in ShelfSpec.GLOBAL) {
                var n = 0
                time("  pool + engine, shelf $shelf", 1, 5) { mix.invalidate(); val b = runBlocking { mix.shelf("main", shelf) }; n = b.result.ids.size; n }
                runBlocking { mix.source.prepare() }
                val pool = mix.source.pool(PoolRequest("main", shelf, mix.dayKey(), emptyList(), 2000))
                say("      $shelf: pool ${pool.size} copies, shelf ${n} titles, restricted flagged ${pool.count { it.restricted }}")
            }
            say("  PIPELINE memory: +${usedMb() - base} MB retained after building every shelf (JVM heap, rough); pool object size about ${"%.1f".format(2000 * 220 / 1024.0 / 1024.0)} MB per 2,000 copies")
            val cols = "ci.itemId, ci.kind, ci.sourceId, ci.identityKey, ci.year, ci.lang, ci.qualityRank, ci.isCam, ci.folderKey, x.categoryId, x.rating, x.addedAt, x.posterUrl"
            say("  plan newest per playlist : " + plan(raw, "SELECT $cols FROM movies x JOIN content_identity ci ON ci.itemId = x.id WHERE x.sourceId = '${ids.first()}' ORDER BY x.addedAt DESC LIMIT 600"))
            say("  plan language shelf       : " + plan(raw, "SELECT $cols FROM movies x JOIN content_identity ci ON ci.itemId = x.id WHERE x.sourceId = '${ids.first()}' AND ci.lang = 'Hindi' ORDER BY x.addedAt DESC LIMIT 600"))
            say("  plan folder-key shelf     : " + plan(raw, "SELECT $cols FROM movies x JOIN content_identity ci ON ci.itemId = x.id WHERE ci.folderKey = 'MOVIE|english general' ORDER BY x.addedAt DESC LIMIT 200"))
            say("  plan twin copies by key   : " + plan(raw, "SELECT $cols FROM movies x JOIN content_identity ci ON ci.itemId = x.id WHERE ci.kind = 'MOVIE' AND ci.identityKey IN ('a','b')"))
            say("  plan restricted keys      : " + plan(raw, "SELECT ci.identityKey, ci.year FROM content_identity ci JOIN movies x ON x.id = ci.itemId WHERE x.categoryId IN ('${ids.first()}-MOVIE-5')"))
            // incremental: one folder locked; the source cache is dropped and only the shelves are rebuilt vs a brand-new instance
            val t2 = System.nanoTime(); mix.invalidate(); runBlocking { mix.home("main") }; val inc = (System.nanoTime() - t2) / 1e6
            val t3 = System.nanoTime(); val fresh = SmartMixHome(db, Visibility(db, { true }, { emptySet() }), { ids }, { pref }, null); runBlocking { fresh.home("main") }; val full = (System.nanoTime() - t3) / 1e6
            say("  PIPELINE incremental (invalidate + rebuild after a lock/profile/library change): %.0f ms; full rebuild from nothing (new instance, cold visibility): %.0f ms".format(inc, full))
            // folder rows: first page of 20 folders, 12 tiles each, through the real browse query
            val rows = runBlocking { folders.folders(ContentKind.MOVIE).first() }
            val order = FolderRowsPlan.order(rows, emptyMap(), pref)
            time("FOLDER ROWS: order ${rows.size} folders + clean names", 1, 5) { FolderRowsPlan.order(rows, emptyMap(), pref).take(20).map { FolderNaming.clean(it.providerName) }.size }
            val restricted = runBlocking { folders.restrictedIdsNow(ContentKind.MOVIE) }
            val browse = BrowseRepository(db, library, folders, ctx)
            time("FOLDER ROWS: one page = 20 folders x 20 titles (12 shown), newest added", 1, 5) { runBlocking { order.take(20).filter { it.id !in restricted }.sumOf { f -> browse.moviesPage(app.streamsetu.core.model.Browse.Folder(f.id), app.streamsetu.core.model.SortSpec(app.streamsetu.core.model.SortField.ADDED), 20, 0, ids, restricted).size } } }
            say("  plan folder row tiles     : " + plan(raw, "SELECT * FROM movies x WHERE x.sourceId IN ('${ids.first()}') AND x.categoryId = '${ids.first()}-MOVIE-3' ORDER BY x.addedAt DESC, x.rowid DESC LIMIT 20"))
        }

        // --- canonical pick over a 2,000-title pool ---
        val pool = runBlocking { ids.flatMap { db.catalog().recentMovieCandidates(it, 1000) } }
        val copies = pool.map { r -> CanonicalPick.Copy(r.id, "MOVIE", r.sourceId, r.categoryId, IdentityKey.ofOrFallback(r.title), IdentityKey.yearOf(r.title, r.year), Derive.languageOf(r.title, null), Derive.qualityRank(r.title, null), r.addedAt) }
        time("identity key + derive for ${pool.size} pool rows (degraded path)") { pool.forEach { Derive.derive("MOVIE", it.title, null, it.year) } }
        time("CanonicalPick.group over ${copies.size} copies") { CanonicalPick.group(copies, CanonicalPick.Context(preferredLang = "Hindi", sourceRank = mapOf("A" to 0, "B" to 1))).size }
        say("  groups from ${copies.size} copies: " + CanonicalPick.group(copies).size)

        // --- an identical read, and +300 / -300 / +300 changed, through the real write path (CatalogStore) ---
        if (perSource.movies <= 80_000 && ids.size >= 1) {
            val s = ids.first()
            val cats = runBlocking { db.catalog().categoriesOfKind("MOVIE").filter { it.sourceId == s } + db.catalog().categoriesOfKind("SERIES").filter { it.sourceId == s } }
            val mv = runBlocking { raw.query("SELECT * FROM movies WHERE sourceId = '$s'").use { c -> buildList { while (c.moveToNext()) add(MovieEntity(c.getString(c.getColumnIndexOrThrow("id")), s, c.getString(c.getColumnIndexOrThrow("categoryId")), c.getString(c.getColumnIndexOrThrow("title")), c.getString(c.getColumnIndexOrThrow("posterUrl")), c.getInt(c.getColumnIndexOrThrow("year")), null, null, c.getString(c.getColumnIndexOrThrow("streamRef")), c.getLong(c.getColumnIndexOrThrow("addedAt")))) } } }
            val sr = runBlocking { raw.query("SELECT * FROM series WHERE sourceId = '$s'").use { c -> buildList { while (c.moveToNext()) add(SeriesEntity(c.getString(c.getColumnIndexOrThrow("id")), s, c.getString(c.getColumnIndexOrThrow("categoryId")), c.getString(c.getColumnIndexOrThrow("title")), c.getString(c.getColumnIndexOrThrow("posterUrl")), null, c.getInt(c.getColumnIndexOrThrow("year")), null, null, c.getString(c.getColumnIndexOrThrow("providerId")), c.getLong(c.getColumnIndexOrThrow("addedAt")))) } } }
            val cs = CatalogStore(db)
            say("  (identity rows exist from the fill above, so the next read only compares hashes)")
            var t = System.nanoTime(); runBlocking { cs.replace(s, cats, emptyList(), mv, sr) }; say("  first read through CatalogStore (fingerprint new; rows upserted, identity compared): %.0f ms".format((System.nanoTime() - t) / 1e6))
            t = System.nanoTime(); runBlocking { cs.replace(s, cats, emptyList(), mv, sr) }; say("  identical re-read (fingerprint hit, nothing written): %.0f ms".format((System.nanoTime() - t) / 1e6))
            raw.execSQL("DELETE FROM content_identity WHERE sourceId = '$s'"); raw.execSQL("DELETE FROM catalog_fingerprints")
            t = System.nanoTime(); runBlocking { cs.replace(s, cats, emptyList(), mv, sr) }; say("  read of the same catalog with NO identity rows yet (derives and writes ${mv.size + sr.size} rows inside the read): %.0f ms".format((System.nanoTime() - t) / 1e6))
            val gone = mv.take(300).map { it.id }.toSet()
            val next = mv.drop(300).mapIndexed { i, m -> if (i in 1000 until 1300) m.copy(title = m.title + " Part II") else m } + (0 until 300).map { i -> mv[i].copy(id = "$s:new$i", title = "Brand New Title $i (2026)", streamRef = "ref:new$i") }
            val changes = ArrayList<ChangeSet>(); val job = kotlinx.coroutines.GlobalScope.launch(Dispatchers.Unconfined) { IdentityStore.changes.collect { changes += it } }
            t = System.nanoTime(); runBlocking { cs.replace(s, cats, emptyList(), next, sr) }; val ms = (System.nanoTime() - t) / 1e6; job.cancel()
            say("  read with +300 / -300 / +300 changed titles (whole catalog write incl. 8 ms pauses): %.0f ms; identity change set: %s".format(ms, changes.filter { it.kind == "MOVIE" }.joinToString { "+${it.added} -${it.removed} ~${it.changed}" }))
            say("  coverage after: %.4f".format(runBlocking { store.coverage() }))
        }
        db.close(); scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
    }

    @Test fun benchmark() {
        assumeTrue("set SMARTMIX_BENCH=1", System.getenv("SMARTMIX_BENCH") == "1")
        val a = Counts(66_540, 18_011, 14_879, 172, 302, 158)
        run("twins", "A: owner scale, two twin playlists", a, listOf("A", "B"))
        run("single", "A: owner scale, one playlist", a, listOf("A"))
        run("big", "B: 200k stress, one playlist", Counts(140_000, 45_000, 40_000, 400, 800, 300), listOf("A"))
        java.io.File(System.getenv("SMARTMIX_BENCH_OUT") ?: "/tmp/smartmix-bench.txt").writeText(out.toString())
    }
}
