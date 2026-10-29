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

/** Why a recording did not happen or did not finish: fixed words, safe to count and to log. */
enum class RecordingFailure {
    UNAUTHORIZED, PROFILE_CHANGED, CHANNEL_MISSING, SOURCE_OFF, CONNECTION_LIMIT, DEVICE_RECORDING_LIMIT, STORAGE, UNSUPPORTED_FORMAT, PROVIDER_REFUSED, NETWORK, NO_DATA, ENDED_EARLY, INTERRUPTED, MISSED, REVIEW_REQUIRED, UNKNOWN
}

/**
 * A programme set to record. [id] is generated and never changes (the Guide uses channel and start, the Sports recordings a generated one); the start and end may be corrected later and the id stays.
 * [preMs] and [postMs] are the padding the person chose before and after the programme. [profileId] is the profile it was made under (empty for one saved before profiles were recorded here),
 * [origin] is who asked ("sports" or none), [failure] is the structured reason when it did not finish, and [file] is the name (not the path) of the file it wrote.
 */
data class ScheduledRec(
    val id: String, val channelId: String, val channelName: String, val sourceId: String, val streamRef: String, val title: String,
    val startMs: Long, val endMs: Long, val state: String = SCHEDULED, val detail: String? = null,
    val preMs: Long = ScheduledRecordings.PADDING_MS, val postMs: Long = ScheduledRecordings.PADDING_MS,
    val profileId: String = "", val origin: String = "", val failure: String? = null, val file: String? = null,
) {
    companion object { const val SCHEDULED = "scheduled"; const val RECORDING = "recording"; const val DONE = "done"; const val FAILED = "failed"; const val MISSED = "missed" }
}

/** The answer of the check made when a recording is about to start. */
sealed interface GateDecision {
    /** Allowed: record this channel now. The channel name and stream reference are read afresh, not taken from what was saved when it was scheduled. */
    data class Go(val channelName: String, val streamRef: String) : GateDecision
    data class Refuse(val failure: RecordingFailure) : GateDecision
}

/**
 * The check every scheduled recording passes at the moment it is due, whoever scheduled it. It gets the recording's own id and reads everything else afresh: the current profile and library, the
 * connection, the channel, folder locks, hidden channels, the adult and kids rules, whether the connection is on, the capacity for another recording and the free space. Nothing the alarm
 * carried, and nothing true when the recording was scheduled, authorizes it.
 */
fun interface RecordingGate { suspend fun check(rec: ScheduledRec, nowMs: Long): GateDecision }

/** What starting a recording came to. */
sealed interface Begin {
    data class Start(val rec: ScheduledRec, val channelName: String, val streamRef: String) : Begin
    /** Nothing to do and nothing changed: it is not waiting (cancelled, finished, started already by an earlier delivery, or not on the list), or it is not due yet. */
    data class Skip(val reason: String) : Begin
    /** Due but not allowed: it is marked failed with the reason and nothing was recorded. */
    data class Refused(val rec: ScheduledRec, val failure: RecordingFailure) : Begin
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

    /** An alarm that arrives much earlier than the recording's start (one set before it was moved later) is not acted on. */
    const val EARLY_SLACK_MS = 90_000L
    const val SCHEME = "streamsetu-record"

    /** The recording an alarm is for, read only from the intent's action and address. Extras, another action or another scheme select nothing. */
    fun idFrom(intent: Intent?): String? {
        if (intent?.action != ACTION) return null
        val uri = intent.data ?: return null
        if (uri.scheme != SCHEME) return null
        return uri.schemeSpecificPart?.removePrefix("//")?.let(android.net.Uri::decode)?.takeIf { it.isNotEmpty() && it.length <= 80 }
    }

    /** The alarm's intent: explicit component, one action, the id in the address, no extras. */
    internal fun intentFor(context: Context, id: String): Intent = Intent(context, RecordReceiver::class.java).setAction(ACTION).setData(android.net.Uri.parse("$SCHEME://${android.net.Uri.encode(id)}"))

    /** Reads the saved list. An ordinary refresh (a screen opening, the service starting): a recording that is under way keeps its state. See [recover] for after a restart. */
    fun load(context: Context) = synchronized(lock) { state.value = readSaved(context) }

    /**
     * Once, when the app process starts: a recording that was under way when the previous process ended did not finish, so it is marked as interrupted (what was written stays).
     * Only here, never in [load]: a screen opening while a recording is running must not turn that recording into a failure.
     */
    fun recover(context: Context) = synchronized(lock) {
        state.value = readSaved(context).map { if (it.state == ScheduledRec.RECORDING && !active.containsKey(it.id)) it.copy(state = ScheduledRec.FAILED, detail = "The recording was interrupted.", failure = RecordingFailure.INTERRUPTED.name) else it }
        save(context)
    }

    private fun readSaved(context: Context): List<ScheduledRec> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("list", "[]") ?: "[]"
        val list = runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).map { a.getJSONObject(it).let { o -> ScheduledRec(o.getString("id"), o.getString("ch"), o.getString("chName"), o.getString("src"), o.getString("ref"), o.getString("title"), o.getLong("start"), o.getLong("end"), o.optString("state", ScheduledRec.SCHEDULED), o.optString("detail").takeIf { d -> d.isNotEmpty() },
                o.optLong("pre", PADDING_MS), o.optLong("post", PADDING_MS), o.optString("profile"), o.optString("origin"), o.optString("failure").takeIf { d -> d.isNotEmpty() }, o.optString("file").takeIf { d -> d.isNotEmpty() }) } }
        }.getOrDefault(emptyList())
        return list
    }

    private fun save(context: Context) {
        val a = JSONArray()
        state.value.forEach { r -> a.put(JSONObject().put("id", r.id).put("ch", r.channelId).put("chName", r.channelName).put("src", r.sourceId).put("ref", r.streamRef).put("title", r.title).put("start", r.startMs).put("end", r.endMs).put("state", r.state).put("detail", r.detail ?: "").put("pre", r.preMs).put("post", r.postMs).put("profile", r.profileId).put("origin", r.origin).put("failure", r.failure ?: "").put("file", r.file ?: "")) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("list", a.toString()).apply()
    }

    fun isScheduled(channelId: String, startMs: Long) = state.value.any { it.id == idOf(channelId, startMs) && it.state == ScheduledRec.SCHEDULED }

    /** False when the programme is already over or already set to record. */
    fun schedule(context: Context, ch: Channel, p: EpgProgram, profileId: String = ""): Boolean = synchronized(lock) {
        if (state.value.isEmpty()) load(context)
        val id = idOf(ch.id, p.startMs)
        if (p.endMs <= System.currentTimeMillis() || state.value.any { it.id == id && it.state == ScheduledRec.SCHEDULED }) return false
        val r = ScheduledRec(id, ch.id, ch.name, ch.sourceId, ch.streamRef, p.title, p.startMs, p.endMs, profileId = profileId)
        state.value = (state.value.filterNot { it.id == id } + r).sortedBy { it.startMs }
        save(context); arm(context, r)
        true
    }

    /**
     * Adds a recording with its own id and padding. False if that id is already on the list, whatever its state: asking twice (a restart, a repeated tap, a guide refresh) schedules once.
     */
    fun scheduleWith(context: Context, r: ScheduledRec): Boolean = synchronized(lock) {
        if (state.value.isEmpty()) load(context)
        if (r.endMs + r.postMs <= System.currentTimeMillis() || state.value.any { it.id == r.id }) return false
        state.value = (state.value + r).sortedBy { it.startMs }
        save(context); arm(context, r)
        true
    }

    /** Moves a waiting recording to the programme's corrected times. Its id and its padding stay; the alarm is replaced, not added to. False if it is not waiting. */
    fun reschedule(context: Context, id: String, startMs: Long, endMs: Long): Boolean = synchronized(lock) {
        if (state.value.isEmpty()) load(context)
        val r = state.value.firstOrNull { it.id == id && it.state == ScheduledRec.SCHEDULED } ?: return false
        val moved = r.copy(startMs = startMs, endMs = endMs)
        state.value = state.value.map { if (it.id == id) moved else it }.sortedBy { it.startMs }
        save(context)
        if (moved.endMs + moved.postMs > System.currentTimeMillis()) arm(context, moved) else (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context, id))
        true
    }

    fun find(id: String): ScheduledRec? = state.value.firstOrNull { it.id == id }

    /**
     * What the alarm for [id] should do. It reads the recording by its id (nothing the alarm carried), starts it only if it is waiting and due, asks the [gate] with the current situation, and marks it
     * recording in the same step so a second delivery finds it already started. A recording that is not waiting, or not due yet, is left exactly as it is.
     */
    suspend fun begin(context: Context, id: String, gate: RecordingGate, nowMs: Long = System.currentTimeMillis()): Begin {
        val first = synchronized(lock) { if (state.value.isEmpty()) load(context); state.value.firstOrNull { it.id == id } } ?: return Begin.Skip("not on the list")
        if (first.state != ScheduledRec.SCHEDULED) return Begin.Skip("not waiting")
        if (nowMs < first.startMs - first.preMs - EARLY_SLACK_MS) return Begin.Skip("not due yet")                      // an alarm from before it was moved later
        if (nowMs >= first.endMs + first.postMs) { update(context, id, ScheduledRec.MISSED, "The device was off at that time.", RecordingFailure.MISSED); return Begin.Skip("over") }
        val decision = gate.check(first, nowMs)
        return synchronized(lock) {
            val now = state.value.firstOrNull { it.id == id }
            when {
                now == null || now.state != ScheduledRec.SCHEDULED || now.startMs != first.startMs || now.endMs != first.endMs -> Begin.Skip("changed while it was checked")          // cancelled, moved or started by another delivery
                decision is GateDecision.Refuse -> { update(context, id, ScheduledRec.FAILED, refusalText(decision.failure), decision.failure); Begin.Refused(first, decision.failure) }
                decision is GateDecision.Go -> { update(context, id, ScheduledRec.RECORDING); Begin.Start(now.copy(state = ScheduledRec.RECORDING), decision.channelName, decision.streamRef) }
                else -> Begin.Skip("unknown")
            }
        }
    }

    fun refusalText(f: RecordingFailure) = when (f) {
        RecordingFailure.CONNECTION_LIMIT -> "Your provider has no free connection for a recording at that time."
        RecordingFailure.DEVICE_RECORDING_LIMIT -> "Two recordings are already running on this device."
        RecordingFailure.STORAGE -> "There is not enough free space to record."
        RecordingFailure.CHANNEL_MISSING -> "The channel is no longer in the library."
        RecordingFailure.REVIEW_REQUIRED -> "The schedule changed and needs a review."
        else -> "This recording is no longer allowed."
    }

    /** The download in progress for each recording, so Cancel can stop it and not only remove the entry. */
    internal val active = java.util.concurrent.ConcurrentHashMap<String, okhttp3.Call>()
    /** Recordings the person cancelled while they were running, until the capture that was running has seen it and cleaned up. */
    private val cancelled: MutableSet<String> = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    internal fun takeCancelled(id: String): Boolean = cancelled.remove(id)

    /** Recordings the person stopped while they were running: the capture that sees this keeps what it has written. */
    private val stopped: MutableSet<String> = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    internal fun takeStopped(id: String): Boolean = stopped.remove(id)

    /** Removes a recording from the list and cancels its alarm. One that is running is cut off and its partial file is removed with it (use [stop] to keep it). */
    fun cancel(context: Context, id: String) = synchronized(lock) {
        active[id]?.let { cancelled += id; it.cancel() }
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context, id))
        state.value = state.value.filterNot { it.id == id }; save(context)
    }

    /**
     * Ends a recording that is running and keeps what has been written, as a playable file. It is marked done ("Stopped") and stays on the list. A waiting recording is not affected: use [cancel].
     * Idempotent: stopping again, or stopping one that is not running, changes nothing.
     */
    fun stop(context: Context, id: String): Boolean = synchronized(lock) {
        val call = active[id]
        if (state.value.none { it.id == id && it.state == ScheduledRec.RECORDING }) return false
        stopped += id; call?.cancel()
        if (call == null) { state.value = state.value.map { if (it.id == id) it.copy(state = ScheduledRec.DONE, detail = "Stopped. The part recorded was kept.") else it }; save(context); stopped -= id }
        true
    }

    fun clearFinished(context: Context) = synchronized(lock) {
        state.value = state.value.filter { it.state == ScheduledRec.SCHEDULED || it.state == ScheduledRec.RECORDING }; save(context)
    }

    internal fun update(context: Context, id: String, state_: String, detail: String? = null, failure: RecordingFailure? = null, file: String? = null) = synchronized(lock) {
        state.value = state.value.map { if (it.id == id) it.copy(state = state_, detail = detail, failure = failure?.name, file = file ?: it.file) else it }; save(context)
    }

    fun arm(context: Context, r: ScheduledRec) {
        val at = (r.startMs - r.preMs).coerceAtLeast(System.currentTimeMillis() + 1000)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context, r.id)
        val exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
        when {
            Build.VERSION.SDK_INT >= 23 && exact -> am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            Build.VERSION.SDK_INT >= 23 -> am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            else -> am.set(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    private fun pending(context: Context, id: String): PendingIntent = PendingIntent.getBroadcast(context, 0, intentFor(context, id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** After a restart the alarms are gone; the recordings still ahead are armed again. */
    fun rearm(context: Context) { load(context); state.value.filter { it.state == ScheduledRec.SCHEDULED && it.endMs > System.currentTimeMillis() }.forEach { arm(context, it) } }
}

/** The alarm went off: start the service that records. */
class RecordReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = ScheduledRecordings.idFrom(intent) ?: return                                // our own alarm, and only the recording its address names
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
        val rec = ScheduledRecordings.find(id) ?: run { stopSelf(); return START_NOT_STICKY }
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, note(rec.title), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(NOTE_ID, note(rec.title))
        val wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "streamsetu:record").apply { acquire((rec.endMs - System.currentTimeMillis()).coerceAtLeast(0) + rec.preMs + 2 * rec.postMs + 60_000L) }
        scope.launch {
            try { run(id) } finally { runCatching { wake.release() }; stopSelf(startId) }
        }
        return START_NOT_STICKY
    }

    /** The recording is read again by its id and checked now; only a waiting, due, allowed one is recorded. A second delivery, a cancelled or moved recording and a refused one record nothing. */
    private suspend fun run(id: String) {
        val c: AppContainer = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        when (val b = ScheduledRecordings.begin(this, id, c.recordingGate)) {
            is Begin.Start -> capture(c, b)
            is Begin.Skip, is Begin.Refused -> {}
        }
    }

    /** Thrown inside the capture with the reason it can be counted under. */
    private class Failure(val category: RecordingFailure, message: String) : Exception(message)

    private suspend fun capture(c: AppContainer, begin: Begin.Start) {
        val rec = begin.rec
        val stop = rec.endMs + rec.postMs
        val file = File(c.recordingsFolder, RecordingFiles.fileName(begin.channelName + " - " + rec.title, System.currentTimeMillis()))
        ScheduledRecordings.update(this, rec.id, ScheduledRec.RECORDING, null, null, file.name)
        try {
            val url = c.resolver.resolveForRecording(rec.sourceId, begin.streamRef) ?: throw Failure(RecordingFailure.CHANNEL_MISSING, "The channel's address could not be found.")
            val req = Request.Builder().url(url).apply { c.resolver.headers(rec.sourceId).forEach { (k, v) -> header(k, v) }; c.resolver.userAgent(rec.sourceId)?.let { header("User-Agent", it) } }.build()
            val client = Http.client.newBuilder().readTimeout(30, java.util.concurrent.TimeUnit.SECONDS).build()
            var wrote = 0L
            val call = client.newCall(req)
            ScheduledRecordings.active[rec.id] = call
            val startedAt = System.currentTimeMillis()
            var endedEarly = false
            call.execute().use { resp ->
                if (!resp.isSuccessful) throw Failure(RecordingFailure.PROVIDER_REFUSED, "The provider answered ${resp.code}. It may allow only one stream at a time.")
                val type = resp.header("Content-Type").orEmpty().lowercase()
                // A playlist (HLS) is a list of addresses, not video: copying it would save text under a video name. Told by the content type, or by the start of what arrives.
                if ("mpegurl" in type) throw Failure(RecordingFailure.UNSUPPORTED_FORMAT, "This channel streams as HLS, which cannot be recorded yet.")
                val src = resp.body?.byteStream() ?: throw Failure(RecordingFailure.NO_DATA, "Nothing was received.")
                file.outputStream().buffered().use { out ->
                    val buf = ByteArray(64 * 1024)
                    // The first bytes are gathered (a short first read must not decide) and looked at without a byte-order mark or leading white space.
                    val head = java.io.ByteArrayOutputStream()
                    while (head.size() < PROBE_BYTES && System.currentTimeMillis() < stop) {
                        val n = src.read(buf)
                        if (n < 0) { endedEarly = System.currentTimeMillis() < stop - EARLY_SLACK_MS; break }
                        head.write(buf, 0, n)
                    }
                    if (looksLikePlaylist(head.toByteArray())) throw Failure(RecordingFailure.UNSUPPORTED_FORMAT, "This channel streams as HLS, which cannot be recorded yet.")
                    if (head.size() > 0) { out.write(head.toByteArray()); wrote += head.size() }
                    while (!endedEarly && System.currentTimeMillis() < stop) {
                        val n = src.read(buf)
                        if (n < 0) { endedEarly = System.currentTimeMillis() < stop - EARLY_SLACK_MS; break }
                        out.write(buf, 0, n); wrote += n
                    }
                }
            }
            if (wrote == 0L) { file.delete(); throw Failure(RecordingFailure.NO_DATA, "Nothing was received.") }
            trimToWholePackets(file)
            // The stream closed well before the programme ended: what was saved is kept, but it is not called a finished recording.
            if (endedEarly) ScheduledRecordings.update(this, rec.id, ScheduledRec.FAILED, "The stream stopped after ${(System.currentTimeMillis() - startedAt) / 60_000} min; the part received was saved.", RecordingFailure.ENDED_EARLY, file.name)
            else ScheduledRecordings.update(this, rec.id, ScheduledRec.DONE, null, null, file.name)
        } catch (e: Exception) {
            val kept = file.exists() && file.length() > 0
            if (file.exists() && file.length() == 0L) file.delete()
            when {
                // Stopped by the person: the part recorded is kept as a playable file and the recording is done.
                ScheduledRecordings.takeStopped(rec.id) -> { if (kept) trimToWholePackets(file); ScheduledRecordings.update(this, rec.id, ScheduledRec.DONE, "Stopped. The part recorded was kept.", null, if (kept) file.name else null) }
                // Cancelled from Settings: the entry is already gone; the partial file goes with it.
                ScheduledRecordings.takeCancelled(rec.id) -> file.delete()
                else -> {
                    if (kept) trimToWholePackets(file)
                    val category = (e as? Failure)?.category ?: if (e is java.io.IOException) RecordingFailure.NETWORK else RecordingFailure.UNKNOWN
                    ScheduledRecordings.update(this, rec.id, ScheduledRec.FAILED, e.message ?: "It did not finish.", category, if (kept) file.name else null)          // a partial file is kept, and playable
                }
            }
        } finally { ScheduledRecordings.active.remove(rec.id) }
    }

    /** A transport stream is made of 188-byte packets; a file cut off in the middle of one is trimmed to the last whole packet so it plays. */
    private fun trimToWholePackets(file: File) {
        runCatching { val len = file.length(); val whole = len - len % 188; if (whole in 1 until len) java.io.RandomAccessFile(file, "rw").use { it.setLength(whole) } }
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
