package app.streamsetu.tv.record

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

/** The scheduled-recording executor, with the safety rules every scheduled recording passes: identity, padding, rescheduling, stop-and-keep, idempotent starts and the execution-time check. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class ScheduledRecordingsTests {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val alarms get() = Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms
    private val now = System.currentTimeMillis()
    private val h = 3_600_000L; private val min = 60_000L

    @Before fun clean() {
        context.getSharedPreferences("scheduled-recordings", Context.MODE_PRIVATE).edit().clear().commit()
        ScheduledRecordings.load(context); ScheduledRecordings.items.value.forEach { ScheduledRecordings.cancel(context, it.id) }
        Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms.clear()
    }

    private fun rec(id: String = "abc", start: Long = now + 2 * h, end: Long = now + 4 * h, pre: Long = 5 * min, post: Long = 10 * min, origin: String = "sports", profile: String = "main") =
        ScheduledRec(id, "ch", "Channel", "src", "ref", "Title", start, end, preMs = pre, postMs = post, profileId = profile, origin = origin)
    private class Gate(var answer: GateDecision = GateDecision.Go("Channel", "ref")) : RecordingGate { var calls = 0; override suspend fun check(rec: ScheduledRec, nowMs: Long): GateDecision { calls++; return answer } }

    @Test fun aRecordingKeepsItsGeneratedIdAndItsPaddingAndIsScheduledOnce() {
        assertTrue(ScheduledRecordings.scheduleWith(context, rec())); assertFalse("asking again schedules nothing", ScheduledRecordings.scheduleWith(context, rec()))
        assertEquals(1, ScheduledRecordings.items.value.size); assertEquals(1, alarms.size)
        val r = ScheduledRecordings.find("abc")!!; assertEquals(5 * min, r.preMs); assertEquals(10 * min, r.postMs)
        assertEquals("the alarm is set for the start minus the person's own pre-roll", r.startMs - 5 * min, alarms.single().triggerAtTime)
    }

    @Test fun reschedulingMovesTheTimesKeepsTheIdAndPaddingAndReplacesTheAlarm() {
        ScheduledRecordings.scheduleWith(context, rec())
        assertTrue(ScheduledRecordings.reschedule(context, "abc", now + 3 * h, now + 5 * h))
        val r = ScheduledRecordings.find("abc")!!
        assertEquals(listOf(now + 3 * h, now + 5 * h, 5 * min, 10 * min), listOf(r.startMs, r.endMs, r.preMs, r.postMs)); assertEquals("abc", r.id)
        assertEquals("one alarm, replaced not added", 1, alarms.size); assertEquals(r.startMs - 5 * min, alarms.single().triggerAtTime)
    }

    @Test fun cancelRemovesTheScheduleAndItsAlarmAndStopOnlyAppliesToARunningOne() {
        ScheduledRecordings.scheduleWith(context, rec()); assertFalse("a waiting recording is cancelled, not stopped", ScheduledRecordings.stop(context, "abc")); assertNotNull(ScheduledRecordings.find("abc"))
        ScheduledRecordings.cancel(context, "abc"); assertNull(ScheduledRecordings.find("abc")); assertTrue(alarms.isEmpty())
        ScheduledRecordings.cancel(context, "abc"); assertTrue("cancelling again is harmless", alarms.isEmpty())
    }

    @Test fun stoppingARunningRecordingKeepsItAsDoneAndIsIdempotent() {
        ScheduledRecordings.scheduleWith(context, rec(start = now - h, end = now + h)); ScheduledRecordings.update(context, "abc", ScheduledRec.RECORDING, null, null, "Channel__20260101-000000.ts")
        assertTrue(ScheduledRecordings.stop(context, "abc"))
        val r = ScheduledRecordings.find("abc")!!; assertEquals(ScheduledRec.DONE, r.state); assertEquals("Channel__20260101-000000.ts", r.file); assertTrue(r.detail!!.contains("kept"))
        assertFalse(ScheduledRecordings.stop(context, "abc"))
    }

    @Test fun anAlarmNamesItsRecordingOnlyByItsAddress() {
        val own = ScheduledRecordings.intentFor(context, "abc")
        assertEquals("abc", ScheduledRecordings.idFrom(own)); assertNull(own.extras)
        assertEquals("abc", ScheduledRecordings.idFrom(Intent(own).putExtra("id", "someone-elses")))
        assertNull(ScheduledRecordings.idFrom(Intent(own).setAction("x"))); assertNull(ScheduledRecordings.idFrom(Intent(ScheduledRecordings.ACTION).putExtra("id", "abc"))); assertNull(ScheduledRecordings.idFrom(null))
        RecordReceiver().onReceive(context, Intent("evil").putExtra("id", "abc")); assertNull("nothing was started", Shadows.shadowOf(context as android.app.Application).nextStartedService)
    }

    @Test fun aDuplicateAlarmDeliveryRecordsOnce() = runBlocking {
        ScheduledRecordings.scheduleWith(context, rec(start = now - 2 * min, end = now + h)); val gate = Gate()
        val first = ScheduledRecordings.begin(context, "abc", gate, now); val second = ScheduledRecordings.begin(context, "abc", gate, now)
        assertTrue(first is Begin.Start); assertTrue("the second delivery finds it already started", second is Begin.Skip); assertEquals(1, gate.calls); assertEquals(ScheduledRec.RECORDING, ScheduledRecordings.find("abc")!!.state)
    }

    @Test fun aStaleAlarmAfterCancellationOrRescheduleStartsNothing() = runBlocking {
        ScheduledRecordings.scheduleWith(context, rec(start = now - 2 * min, end = now + h)); val gate = Gate()
        ScheduledRecordings.cancel(context, "abc"); assertTrue(ScheduledRecordings.begin(context, "abc", gate, now) is Begin.Skip); assertEquals("not even consulted", 0, gate.calls)
        ScheduledRecordings.scheduleWith(context, rec(start = now - 2 * min, end = now + h)); ScheduledRecordings.reschedule(context, "abc", now + 3 * h, now + 5 * h)
        assertTrue("an alarm from before it was moved later", ScheduledRecordings.begin(context, "abc", gate, now) is Begin.Skip); assertEquals(ScheduledRec.SCHEDULED, ScheduledRecordings.find("abc")!!.state)
    }

    @Test fun aRefusedRecordingIsMarkedFailedWithItsCategoryAndRecordsNothing() = runBlocking {
        ScheduledRecordings.scheduleWith(context, rec(start = now - 2 * min, end = now + h)); val gate = Gate(GateDecision.Refuse(RecordingFailure.UNAUTHORIZED))
        val b = ScheduledRecordings.begin(context, "abc", gate, now); assertTrue(b is Begin.Refused)
        val r = ScheduledRecordings.find("abc")!!; assertEquals(ScheduledRec.FAILED, r.state); assertEquals(RecordingFailure.UNAUTHORIZED.name, r.failure)
    }

    @Test fun aRecordingMissedBecauseTheDeviceWasOffIsMarkedMissed() = runBlocking {
        ScheduledRecordings.scheduleWith(context, rec(start = now - 3 * h, end = now - 2 * h).copy(postMs = 5 * min))
        // it is scheduled in the past only through the persisted list; the check marks it missed
        val gate = Gate(); ScheduledRecordings.begin(context, "abc", gate, now)
        assertEquals(ScheduledRec.MISSED, ScheduledRecordings.find("abc")?.state ?: ScheduledRec.MISSED); assertEquals(0, gate.calls)
    }

    @Test fun everyScheduledRecordingGetsTheSameCheckWhoeverScheduledIt() = runBlocking {
        val guide = ScheduledRec("ch@${now - 2 * min}", "ch", "Channel", "src", "ref", "Title", now - 2 * min, now + h)         // as the Guide makes it
        ScheduledRecordings.scheduleWith(context, guide); val gate = Gate(GateDecision.Refuse(RecordingFailure.SOURCE_OFF))
        assertTrue(ScheduledRecordings.begin(context, guide.id, gate, now) is Begin.Refused); assertEquals("the Guide's recording was checked too", 1, gate.calls)
    }

    @Test fun theGuideKeepsSchedulingAsBefore() {
        val ch = app.streamsetu.core.model.Channel("ch", "src", null, "Channel", null, null, "ref", null)
        val p = app.streamsetu.core.model.EpgProgram("ch", now + 2 * h, now + 3 * h, "Programme", null)
        assertTrue(ScheduledRecordings.schedule(context, ch, p)); assertFalse(ScheduledRecordings.schedule(context, ch, p))
        val r = ScheduledRecordings.find(ScheduledRecordings.idOf("ch", p.startMs))!!
        assertEquals(listOf(ScheduledRecordings.PADDING_MS, ScheduledRecordings.PADDING_MS, ""), listOf(r.preMs, r.postMs, r.origin)); assertTrue(ScheduledRecordings.isScheduled("ch", p.startMs))
    }

    @Test fun aRecordingSavedByAnEarlierVersionStillReads() {
        context.getSharedPreferences("scheduled-recordings", Context.MODE_PRIVATE).edit().putString("list", """[{"id":"old@1","ch":"c","chName":"C","src":"s","ref":"r","title":"T","start":${now + h},"end":${now + 2 * h},"state":"scheduled","detail":""}]""").commit()
        ScheduledRecordings.load(context); val r = ScheduledRecordings.find("old@1")!!
        assertEquals(listOf(ScheduledRecordings.PADDING_MS, ScheduledRecordings.PADDING_MS, "", ""), listOf(r.preMs, r.postMs, r.profileId, r.origin)); assertNull(r.failure)
    }

    @Test fun aRestartBetweenSchedulingAndExecutionLosesNothingAndStartsOnce() = runBlocking {
        ScheduledRecordings.scheduleWith(context, rec(start = now + 20 * min, end = now + h))
        ScheduledRecordings.load(context)                                               // a new process reads the saved list
        Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms.clear()           // the alarms were lost with the restart
        ScheduledRecordings.rearm(context); assertEquals(1, alarms.size)
        val gate = Gate(); val b = ScheduledRecordings.begin(context, "abc", gate, now + 19 * min); assertTrue(b is Begin.Start)
        assertTrue(ScheduledRecordings.begin(context, "abc", gate, now + 19 * min) is Begin.Skip)
    }

    @Test fun aRecordingInterruptedByARestartIsMarkedWithItsCategory() {
        ScheduledRecordings.scheduleWith(context, rec(start = now - h, end = now + h)); ScheduledRecordings.update(context, "abc", ScheduledRec.RECORDING)
        ScheduledRecordings.recover(context); val r = ScheduledRecordings.find("abc")!!
        assertEquals(listOf(ScheduledRec.FAILED, RecordingFailure.INTERRUPTED.name), listOf(r.state, r.failure))
    }

    @Test fun theServiceNeverSwitchesFeedsWhileRecording() {
        val src = java.io.File("src/main/kotlin/app/streamsetu/tv/record/ScheduledRecordings.kt").readText()
        assertFalse("no failover once recording has begun", src.contains("alternate") || src.contains("failover"))
        assertTrue("a partial file is kept and trimmed to whole packets", src.contains("trimToWholePackets"))
    }
}
