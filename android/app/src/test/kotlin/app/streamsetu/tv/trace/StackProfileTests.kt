package app.streamsetu.tv.trace

import org.junit.Assert.*
import org.junit.Test

class StackProfileTests {
    @Test fun theBusiestPlaceComesFirstWithItsShareOfTheSamples() {
        val p = StackProfile()
        repeat(10) { p.tick(); p.add("worker", "GuideVm.rows:99", "SQLite.step"); if (it < 4) p.add("main", "Home.draw:10", "Canvas.drawRect") }
        val r = p.report()
        assertTrue(r[0], r[0].startsWith("100%") && "worker | GuideVm.rows:99 | in SQLite.step" in r[0])
        assertTrue(r[1], r[1].startsWith(" 40%") && "main" in r[1])
    }

    @Test fun aReportStartsAFreshWindow() {
        val p = StackProfile(); p.tick(); p.add("main", "A.b:1", "C.d")
        assertEquals(1, p.report().size)
        assertTrue(p.report().isEmpty())
    }

    @Test fun aThreadWaitingInASystemCallIsNotCountedAsBusy() {
        assertTrue(StackSampler.isWaiting(StackTraceElement("android.os.MessageQueue", "nativePollOnce", "MessageQueue.java", -2)))
        assertTrue(StackSampler.isWaiting(StackTraceElement("java.net.SocketInputStream", "socketRead0", "SocketInputStream.java", -2)))
        assertFalse(StackSampler.isWaiting(StackTraceElement("android.database.sqlite.SQLiteConnection", "nativeExecute", "SQLiteConnection.java", -2)))
    }

    @Test fun threadsAreGroupedByKind() {
        assertEquals("main", StackSampler.kindOf("main"))
        assertEquals("worker", StackSampler.kindOf("DefaultDispatcher-worker-7"))
        assertEquals("database", StackSampler.kindOf("arch_disk_io_3"))
        assertEquals("render", StackSampler.kindOf("RenderThread"))
        assertEquals("OkHttp TaskRunner", StackSampler.kindOf("OkHttp TaskRunner"))
    }
}
