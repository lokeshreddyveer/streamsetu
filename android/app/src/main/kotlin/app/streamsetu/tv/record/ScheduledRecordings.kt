package app.streamsetu.tv.record

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import app.streamsetu.core.data.repo.RecordingFiles
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.net.Http
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.SyncEntryPoint
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/** A programme set to be recorded. */
data class ScheduledRec(
    val id: String, val channelId: String, val channelName: String, val sourceId: String, val streamRef: String, val title: String,
    val startMs: Long, val endMs: Long, val state: String = SCHEDULED, val detail: String? = null,
) {
    companion object { const val SCHEDULED = "scheduled"; const val RECORDING = "recording"; const val DONE = "done"; const val FAILED = "failed"; const val MISSED = "missed" }
}

/**
 * Records a live programme at its time: the person picks Record in the guide, an alarm wakes the app a minute before the start, and a foreground service writes the stream to a
 * file in the recordings folder until the programme ends (a minute of padding on each side). It needs a connection of its own, so a provider that allows only one stream cannot
 * record while something else plays. The list is kept on this device.
 */
object ScheduledRecordings {
    const val ACTION = "app.streamsetu.RECORD"
    const val PADDING_MS = 60_000L
    private const val PREFS = "scheduled-recordings"
    private val state = MutableStateFlow<List<ScheduledRec>>(emptyList())
    val items: StateFlow<List<ScheduledRec>> = state.asStateFlow()
    private val lock = Any()

    fun idOf(channelId: String, startMs: Long) = "$channelId@$startMs"

    /** Reads the saved list. An ordinary refresh (a screen opening, the service starting): a recording that is under way keeps its state. See [recover] for after a restart. */
    fun load(context: Context) = synchronized(lock) { state.value = readSaved(context) }

    /**
     * Once, when the app process starts: a recording that was under way when the previous process ended did not finish, so it is marked as interrupted (what was written stays).
     * Only here, never in [load]: a screen opening while a recording is running must not turn that recording into a failure.
     */
    fun recover(context: Context) = synchronized(lock) {
        state.value = readSaved(context).map { if (it.state == ScheduledRec.RECORDING && !active.containsKey(it.id)) it.copy(state = ScheduledRec.FAILED, detail = "The recording was interrupted.") else it }
        save(context)
    }

    private fun readSaved(context: Context): List<ScheduledRec> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("list", "[]") ?: "[]"
        val list = runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).map { a.getJSONObject(it).let { o -> ScheduledRec(o.getString("id"), o.getString("ch"), o.getString("chName"), o.getString("src"), o.getString("ref"), o.getString("title"), o.getLong("start"), o.getLong("end"), o.optString("state", ScheduledRec.SCHEDULED), o.optString("detail").takeIf { d -> d.isNotEmpty() }) } }
        }.getOrDefault(emptyList())
        return list
    }

    private fun save(context: Context) {
        val a = JSONArray()
        state.value.forEach { r -> a.put(JSONObject().put("id", r.id).put("ch", r.channelId).put("chName", r.channelName).put("src", r.sourceId).put("ref", r.streamRef).put("title", r.title).put("start", r.startMs).put("end", r.endMs).put("state", r.state).put("detail", r.detail ?: "")) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("list", a.toString()).apply()
    }

    fun isScheduled(channelId: String, startMs: Long) = state.value.any { it.id == idOf(channelId, startMs) && it.state == ScheduledRec.SCHEDULED }

    /** False when the programme is already over or already set to record. */
    fun schedule(context: Context, ch: Channel, p: EpgProgram): Boolean = synchronized(lock) {
        if (state.value.isEmpty()) load(context)
        val id = idOf(ch.id, p.startMs)
        if (p.endMs <= System.currentTimeMillis() || state.value.any { it.id == id && it.state == ScheduledRec.SCHEDULED }) return false
        val r = ScheduledRec(id, ch.id, ch.name, ch.sourceId, ch.streamRef, p.title, p.startMs, p.endMs)
        state.value = (state.value.filterNot { it.id == id } + r).sortedBy { it.startMs }
        save(context); arm(context, r)
        true
    }

    /** The download in progress for each recording, so Cancel can stop it and not only remove the entry. */
    internal val active = java.util.concurrent.ConcurrentHashMap<String, okhttp3.Call>()
    /** Recordings the person cancelled while they were running, until the capture that was running has seen it and cleaned up. */
    private val cancelled: MutableSet<String> = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    internal fun takeCancelled(id: String): Boolean = cancelled.remove(id)

    fun cancel(context: Context, id: String) = synchronized(lock) {
        active[id]?.let { cancelled += id; it.cancel() }
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context, id))
        state.value = state.value.filterNot { it.id == id }; save(context)
    }

    fun clearFinished(context: Context) = synchronized(lock) {
        state.value = state.value.filter { it.state == ScheduledRec.SCHEDULED || it.state == ScheduledRec.RECORDING }; save(context)
    }

    internal fun update(context: Context, id: String, state_: String, detail: String? = null) = synchronized(lock) {
        state.value = state.value.map { if (it.id == id) it.copy(state = state_, detail = detail) else it }; save(context)
    }

    fun arm(context: Context, r: ScheduledRec) {
        val at = (r.startMs - PADDING_MS).coerceAtLeast(System.currentTimeMillis() + 1000)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context, r.id)
        val exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
        when {
            Build.VERSION.SDK_INT >= 23 && exact -> am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            Build.VERSION.SDK_INT >= 23 -> am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            else -> am.set(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    private fun pending(context: Context, id: String): PendingIntent {
        val i = Intent(context, RecordReceiver::class.java).setAction(ACTION).setData(android.net.Uri.parse("streamsetu-record://${android.net.Uri.encode(id)}")).putExtra("id", id)
        return PendingIntent.getBroadcast(context, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** After a restart the alarms are gone; the recordings still ahead are armed again. */
    fun rearm(context: Context) { load(context); state.value.filter { it.state == ScheduledRec.SCHEDULED && it.endMs > System.currentTimeMillis() }.forEach { arm(context, it) } }
}

/** The alarm went off: start the service that records. */
class RecordReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ScheduledRecordings.ACTION) return
        val id = intent.getStringExtra("id") ?: return
        val i = Intent(context, RecordService::class.java).putExtra("id", id)
        runCatching { if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i) }
    }
}

/** Writes one programme to a file while it is on. */
class RecordService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id") ?: run { stopSelf(); return START_NOT_STICKY }
        ScheduledRecordings.load(this)
        val rec = ScheduledRecordings.items.value.firstOrNull { it.id == id } ?: run { stopSelf(); return START_NOT_STICKY }
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, note(rec.title), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(NOTE_ID, note(rec.title))
        val wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "streamsetu:record").apply { acquire((rec.endMs - System.currentTimeMillis()).coerceAtLeast(0) + 3 * ScheduledRecordings.PADDING_MS) }
        scope.launch {
            try { capture(rec) } finally { runCatching { wake.release() }; stopSelf(startId) }
        }
        return START_NOT_STICKY
    }

    private suspend fun capture(rec: ScheduledRec) {
        val c: AppContainer = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        val stop = rec.endMs + ScheduledRecordings.PADDING_MS
        if (stop <= System.currentTimeMillis()) { ScheduledRecordings.update(this, rec.id, ScheduledRec.MISSED, "The device was off at that time."); return }
        ScheduledRecordings.update(this, rec.id, ScheduledRec.RECORDING)
        val file = File(c.recordingsFolder, RecordingFiles.fileName(rec.channelName + " - " + rec.title, System.currentTimeMillis()))
        try {
            val url = c.resolver.resolve(rec.sourceId, rec.streamRef) ?: error("The channel's address could not be found.")
            val req = Request.Builder().url(url).apply { c.resolver.headers(rec.sourceId).forEach { (k, v) -> header(k, v) }; c.resolver.userAgent(rec.sourceId)?.let { header("User-Agent", it) } }.build()
            val client = Http.client.newBuilder().readTimeout(30, java.util.concurrent.TimeUnit.SECONDS).build()
            var wrote = 0L
            val call = client.newCall(req)
            ScheduledRecordings.active[rec.id] = call
            val startedAt = System.currentTimeMillis()
            var endedEarly = false
            call.execute().use { resp ->
                if (!resp.isSuccessful) error("The provider answered ${resp.code}. It may allow only one stream at a time.")
                val type = resp.header("Content-Type").orEmpty().lowercase()
                // A playlist (HLS) is a list of addresses, not video: copying it would save text under a video name. Told by the content type, or by the start of what arrives.
                if ("mpegurl" in type) error("This channel streams as HLS, which cannot be recorded yet.")
                val src = resp.body?.byteStream() ?: error("Nothing was received.")
                file.outputStream().buffered().use { out ->
                    val buf = ByteArray(64 * 1024)
                    // The first bytes are gathered (a short first read must not decide) and looked at without a byte-order mark or leading white space.
                    val head = java.io.ByteArrayOutputStream()
                    while (head.size() < PROBE_BYTES && System.currentTimeMillis() < stop) {
                        val n = src.read(buf)
                        if (n < 0) { endedEarly = System.currentTimeMillis() < stop - EARLY_SLACK_MS; break }
                        head.write(buf, 0, n)
                    }
                    if (looksLikePlaylist(head.toByteArray())) error("This channel streams as HLS, which cannot be recorded yet.")
                    if (head.size() > 0) { out.write(head.toByteArray()); wrote += head.size() }
                    while (!endedEarly && System.currentTimeMillis() < stop) {
                        val n = src.read(buf)
                        if (n < 0) { endedEarly = System.currentTimeMillis() < stop - EARLY_SLACK_MS; break }
                        out.write(buf, 0, n); wrote += n
                    }
                }
            }
            if (wrote == 0L) { file.delete(); error("Nothing was received.") }
            // The stream closed well before the programme ended: what was saved is kept, but it is not called a finished recording.
            if (endedEarly) ScheduledRecordings.update(this, rec.id, ScheduledRec.FAILED, "The stream stopped after ${(System.currentTimeMillis() - startedAt) / 60_000} min; the part received was saved.")
            else ScheduledRecordings.update(this, rec.id, ScheduledRec.DONE)
        } catch (e: Exception) {
            if (file.exists() && file.length() == 0L) file.delete()
            // Cancelled from Settings: the entry is already gone; the partial file goes with it.
            if (ScheduledRecordings.takeCancelled(rec.id)) file.delete()
            else ScheduledRecordings.update(this, rec.id, ScheduledRec.FAILED, e.message ?: "It did not finish.")
        } finally { ScheduledRecordings.active.remove(rec.id) }
    }

    private fun note(title: String): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle("Recording").setContentText(title).setOngoing(true).build()
    }

    override fun onDestroy() {
        // The service is going away (the system stopped it): a download that is still blocked on the network is cancelled with it, not left running.
        ScheduledRecordings.active.values.forEach { runCatching { it.cancel() } }
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); super.onDestroy()
    }

    companion object { private const val CHANNEL = "recording"; private const val NOTE_ID = 7041; private const val EARLY_SLACK_MS = 90_000L; private const val PROBE_BYTES = 188

        /** True when what arrived starts like an HLS playlist: "#EXTM3U", after an optional byte-order mark and white space. */
        fun looksLikePlaylist(head: ByteArray): Boolean {
            var i = 0
            if (head.size >= 3 && head[0] == 0xEF.toByte() && head[1] == 0xBB.toByte() && head[2] == 0xBF.toByte()) i = 3
            while (i < head.size && (head[i] == ' '.code.toByte() || head[i] == '\t'.code.toByte() || head[i] == '\r'.code.toByte() || head[i] == '\n'.code.toByte())) i++
            val tag = "#EXTM3U".toByteArray(Charsets.ISO_8859_1)
            return head.size - i >= tag.size && tag.indices.all { head[i + it] == tag[it] }
        }
    }
}
