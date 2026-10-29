package app.streamsetu.tv.sports.recording

import android.app.AlarmManager
import android.content.Context
import android.os.Looper
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.MetadataSource
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventKind
import app.streamsetu.core.sports.SportsFeed
import app.streamsetu.tv.record.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

/** Measurements, not behaviour: the numbers go to the test output. Run on a development machine, so they are a floor for a TV, not a TV figure. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsRecordingPerformanceTests {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val alarms get() = Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms
    private lateinit var db: AppDatabase
    private lateinit var d: FakeRecordingDeps
    private lateinit var svc: SportsRecordingService
    private val h = 3_600_000L; private val min = 60_000L; private val t0 = 1_800_000_000_000L
    private val offMain = ArrayList<Boolean>()

    @Before fun open() {
        context.getSharedPreferences("scheduled-recordings", Context.MODE_PRIVATE).edit().clear().commit()
        ScheduledRecordings.load(context); ScheduledRecordings.items.value.forEach { ScheduledRecordings.cancel(context, it.id) }; alarms.clear()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).build()
        d = FakeRecordingDeps(context); d.time = t0
        svc = SportsRecordingService(db.sports(), d) { }
    }
    @After fun close() { db.close() }

    private fun event(i: Int, start: Long, feeds: Int = 3, sides: List<String> = listOf("Team A$i", "Team B$i"), sport: Sport = Sport.values()[i % Sport.values().size]): SportsEvent {
        val ids = (0 until feeds).map { "c$i-$it" }
        ids.forEach { d.auth.channels[it] = Channel(it, "A", "cat", "Channel $it", null, null, "ref-$it", null) }
        return SportsEvent("e$i", sport, SportsEventKind.HEAD_TO_HEAD, "League ${i % 40}", sides, null, sides.joinToString(" vs "), start, start + 3 * h,
            ids.map { SportsFeed(it, "A", "Channel $it", null, MetadataSource.UNKNOWN, if (it.endsWith("0")) "FHD" else "HD", MetadataSource.PARSED_FROM_NAME, null, it, 0L, false) }, 0.95, setOf("A"), "r")
    }
    private fun <T> onWorker(b: suspend () -> T): T = runBlocking(Dispatchers.Default) { offMain.add(Looper.myLooper() != Looper.getMainLooper()); b() }
    private fun ms(n: Long) = n / 1_000_000.0
    private fun stats(label: String, nanos: List<Long>, size: String) {
        val s = nanos.sorted(); fun p(q: Double) = s[minOf(s.size - 1, (s.size * q).toInt())]
        println(String.format(java.util.Locale.US, "PERF %-44s n=%-5d median=%7.2f ms  p95=%7.2f ms  worst=%7.2f ms  [%s]", label, s.size, ms(p(0.5)), ms(p(0.95)), ms(s.last()), size))
    }
    private fun timed(n: Int, op: suspend (Int) -> Unit): List<Long> = (0 until n).map { i -> val t = System.nanoTime(); onWorker { op(i) }; System.nanoTime() - t }
    private fun usedMb(): Long { repeat(3) { System.gc(); Thread.sleep(50) }; val r = Runtime.getRuntime(); return (r.totalMemory() - r.freeMemory()) / (1024 * 1024) }

    private fun history(n: Int) = (0 until n).map { i ->
        SportsRecordingEntity("h$i", "main", "library-1", "cricket", "cricket|head_to_head|team a$i|team b$i|", "league", "team a$i|team b$i", "A", "x$i", t0 - (i + 1) * h, t0 - (i + 1) * h + 3 * h, 60_000, 300_000, (t0 - i * h) / 1_800_000L,
            2, "x$i", null, "s$i", null, if (i % 3 == 0) "COMPLETED" else if (i % 3 == 1) "CANCELLED" else "FAILED", null, "stamp", t0, t0)
    }

    @Test fun measure() {
        val guide = (0 until 1500).map { event(it, t0 + (it % 96) * 30 * min + (it / 96) * 7 * 24 * h) }
        val target = guide[10]
        // planning: the first call in this process, then repeated calls
        val cold = timed(1) { svc.plan(target, null, 60_000, 300_000, guide) }
        stats("plan, cold (first call)", cold, "guide ${guide.size} events, 3 feeds each")
        stats("plan, warm", timed(60) { svc.plan(guide[10 + it], null, 60_000, 300_000, guide) }, "guide ${guide.size} events, 3 feeds each")
        stats("plan, warm, no guide siblings", timed(60) { svc.plan(guide[10 + it], null, 60_000, 300_000) }, "single event")

        // re-matching 40 open recordings against the large guide
        onWorker { for (i in 0 until 40) assertTrue(svc.record(guide[100 + i * 9], null, 60_000, 300_000, guide) is RecordOutcome.Scheduled) }
        val shifted = guide.map { it.copy(startMs = it.startMs + 4 * min, endMs = it.endMs + 4 * min) }
        stats("re-match, 40 open vs ${guide.size}-event guide", timed(30) { svc.reassociate(if (it % 2 == 0) shifted else guide) }, "40 open recordings, guide ${guide.size}")
        assertEquals("no alarm or schedule was doubled", 40, ScheduledRecordings.items.value.size); assertEquals(40, alarms.size)
        onWorker { db.sports().recordings("main").forEach { svc.cancel(it.id) } }; assertEquals(0, ScheduledRecordings.items.value.size)

        // 100 schedule / reschedule / cancel cycles, memory before and after
        val before = usedMb(); val e = guide[500]; val moved = listOf(e.copy(startMs = e.startMs + 3 * min, endMs = e.endMs + 3 * min))
        val cycle = timed(100) {
            val out = svc.record(e, null, 60_000, 300_000, guide) as RecordOutcome.Scheduled
            svc.reassociate(moved); svc.reassociate(listOf(e))
            assertEquals(1, ScheduledRecordings.items.value.size); assertEquals(1, alarms.size)
            svc.cancel(out.id)
        }
        stats("schedule+reschedule x2+cancel cycle", cycle, "100 cycles, same event")
        val after = usedMb()
        println("PERF memory heap used before=$before MB after=$after MB across 100 cycles")
        assertEquals(0, ScheduledRecordings.items.value.size); assertEquals(0, alarms.size)

        // duplicate and stale alarms
        var out: RecordOutcome.Scheduled? = null
        onWorker { out = svc.record(guide[600], null, 60_000, 300_000, guide) as RecordOutcome.Scheduled }
        val id = db.sports().let { runBlocking { it.recording(out!!.id)!!.scheduleId } }
        val gate = RecordingGate { _, _ -> GateDecision.Refuse(RecordingFailure.UNAUTHORIZED) }
        val dup = timed(500) { assertTrue(ScheduledRecordings.begin(context, id, gate, t0) is Begin.Skip) }
        stats("duplicate/early alarm delivery (not due)", dup, "500 deliveries, 0 recordings started")
        onWorker { svc.cancel(out!!.id) }
        val stale = timed(500) { assertTrue(ScheduledRecordings.begin(context, id, gate, t0 + 20 * h) is Begin.Skip) }
        stats("stale alarm after cancel", stale, "500 deliveries, 0 recordings started")
        assertTrue(d.archivePlays.isEmpty())

        assertTrue("planning and re-matching ran on a worker thread here; in the app the caller's dispatcher decides", offMain.all { it })
    }

    @Test fun databaseGrowthAndQueryTimeWithAThousandHistoricalRequests() {
        val file = java.io.File(context.cacheDir, "perf-sports.db").also { it.delete() }
        val fdb = Room.databaseBuilder(context, AppDatabase::class.java, file.absolutePath).setJournalMode(androidx.room.RoomDatabase.JournalMode.TRUNCATE).build()
        try {
            val dao = fdb.sports(); runBlocking { fdb.openHelper.writableDatabase.query("PRAGMA wal_checkpoint").close() }
            val base = file.length()
            val rows = history(1200); val t = System.nanoTime(); runBlocking { rows.forEach { dao.insertRecording(it) } }; val insertMs = ms(System.nanoTime() - t)
            runBlocking { fdb.openHelper.writableDatabase.query("PRAGMA wal_checkpoint").close() }
            val grew = file.length() - base
            val svc2 = SportsRecordingService(dao, d) { }
            val list = (0 until 100).map { System.nanoTime().let { t1 -> runBlocking { dao.recordings("main") }; System.nanoTime() - t1 } }
            stats("list all requests for profile", list, "${rows.size} historical rows")
            val open = (0 until 100).map { System.nanoTime().let { t1 -> runBlocking { dao.openRecordings() }; System.nanoTime() - t1 } }
            stats("list open requests for profile", open, "${rows.size} historical rows")
            val byId = (0 until 200).map { System.nanoTime().let { t1 -> runBlocking { dao.recordingBySchedule("s${it * 5}") }; System.nanoTime() - t1 } }
            stats("lookup by schedule id (alarm path)", byId, "${rows.size} historical rows")
            val guide = (0 until 1500).map { event(it, t0 + (it % 96) * 30 * min) }
            runBlocking { svc2.record(guide[3], null, 60_000, 300_000, guide) }
            stats("plan with history", (0 until 30).map { val t1 = System.nanoTime(); runBlocking { svc2.plan(guide[3 + it], null, 60_000, 300_000, guide) }; System.nanoTime() - t1 }, "${rows.size} historical rows + 1 open")
            println(String.format(java.util.Locale.US, "PERF database growth: %d rows inserted in %.0f ms, file grew %d KB (%.0f bytes/row)", rows.size, insertMs, grew / 1024, grew.toDouble() / rows.size))
            runBlocking { svc2.cancel(dao.openRecordings().first().id) }
        } finally { fdb.close(); file.delete() }
    }
}
