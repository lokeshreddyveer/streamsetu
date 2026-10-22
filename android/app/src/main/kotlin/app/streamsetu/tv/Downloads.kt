package app.streamsetu.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import app.streamsetu.core.data.repo.SaveState
import app.streamsetu.core.data.repo.SavedTitle
import app.streamsetu.core.data.repo.SavedTitles
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Episode
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.Series
import app.streamsetu.core.net.Http
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject

/**
 * Saves movies and episodes on this device so they play without a connection. One download runs at a time (a connection that allows one stream cannot also
 * stream), none runs while something is playing (a download would take the connection a stream needs), and one that was interrupted carries on from where it
 * stopped. The stream address is asked of the connection when a download starts and is never stored or shown.
 */
class Downloads(private val context: Context, private val resolver: app.streamsetu.core.playback.StreamUrlResolver, private val busy: () -> Boolean, private val scope: CoroutineScope) {
    private val prefs = context.getSharedPreferences("downloads", Context.MODE_PRIVATE)
    /** Where the files are kept: the app's own folder, so no permission is needed and uninstalling the app clears them. */
    val folder: File = File(context.getExternalFilesDir(null) ?: context.filesDir, "downloads").also { it.mkdirs() }
    private val _items = MutableStateFlow(SavedTitles.decode(prefs.getString("items", "").orEmpty()).map { if (it.state == SaveState.DOWNLOADING) it.copy(state = SaveState.QUEUED) else it })
    val items: StateFlow<List<SavedTitle>> = _items
    private val running = AtomicBoolean(false)
    private var lastSaved = HashMap<String, Long>()

    /** Downloads over Wi-Fi or a cable only (the default); off lets a phone use mobile data too. */
    /** Removes a saved title once it has been watched to the end. Off by default. */
    var deleteWhenWatched: Boolean
        get() = prefs.getBoolean("deleteWatched", false)
        set(v) { prefs.edit().putBoolean("deleteWatched", v).apply() }

    /** Removes the finished downloads whose title was watched to the end ([watched] holds those ids). */
    fun sweepWatched(watched: Set<String>) { _items.value.filter { it.state == SaveState.DONE && it.itemId in watched }.forEach { remove(it.itemId) } }

    var wifiOnly: Boolean
        get() = prefs.getBoolean("wifiOnly", true)
        set(v) { prefs.edit().putBoolean("wifiOnly", v).apply() }

    init { if (_items.value.any { it.state == SaveState.QUEUED }) start() }

    fun item(id: String): SavedTitle? = _items.value.firstOrNull { it.itemId == id }
    val totalBytes: Long get() = _items.value.sumOf { if (it.state == SaveState.DONE) it.bytesTotal else it.bytesDone }

    /** The saved file of a finished download as an address the player can open, or null. */
    fun localUri(itemId: String): String? = item(itemId)?.takeIf { it.state == SaveState.DONE }?.fileName?.let { File(folder, it) }?.takeIf { it.exists() }?.let { Uri.fromFile(it).toString() }

    fun enqueue(movie: Movie) {
        if (item(movie.id)?.let { it.state != SaveState.FAILED } == true) return
        add(SavedTitle(movie.id, ContentKind.MOVIE, movie.sourceId, movie.streamRef, null, movie.title, movie.year?.toString(), SaveState.QUEUED, 0, 0, null, System.currentTimeMillis(), null))
    }

    fun enqueue(episode: Episode, series: Series) {
        if (item(episode.id)?.let { it.state != SaveState.FAILED } == true) return
        add(SavedTitle(episode.id, ContentKind.EPISODE, series.sourceId, episode.streamRef, series.id, series.title, "S${episode.season} E${episode.number} · ${episode.title}", SaveState.QUEUED, 0, 0, null, System.currentTimeMillis(), null))
    }

    fun pause(id: String) = change(id) { if (it.state == SaveState.DOWNLOADING || it.state == SaveState.QUEUED) it.copy(state = SaveState.PAUSED) else it }
    fun resume(id: String) { change(id) { if (it.state == SaveState.PAUSED || it.state == SaveState.FAILED) it.copy(state = SaveState.QUEUED, error = null) else it }; start() }

    /** Stops a download if it is running, deletes what was saved, and forgets it. */
    fun remove(id: String) {
        val t = item(id) ?: return
        _items.value = _items.value.filter { it.itemId != id }; persist()
        t.fileName?.let { File(folder, it).delete(); File(folder, "$it.part").delete() }
    }

    fun removeAll() { _items.value.map { it.itemId }.forEach(::remove) }

    private fun add(t: SavedTitle) { _items.value = _items.value.filter { it.itemId != t.itemId } + t; persist(); start() }
    private fun change(id: String, f: (SavedTitle) -> SavedTitle) { _items.value = _items.value.map { if (it.itemId == id) f(it) else it }; persist() }
    private fun persist() { prefs.edit().putString("items", SavedTitles.encode(_items.value)).apply() }

    private fun metered(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return app.streamsetu.core.playback.NetworkCompat.isMetered(cm)
    }

    /** Starts the downloads, and the notification that keeps them going when the app is left. Safe to call as often as is convenient. */
    fun start() {
        runCatching { ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java)) }
        if (!running.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) { try { loop() } finally { running.set(false) } }
    }

    private suspend fun loop() {
        while (true) {
            val waiting = _items.value.filter { it.state == SaveState.QUEUED }
            if (waiting.isEmpty()) return
            if (busy() || (wifiOnly && metered())) { delay(8_000); continue }
            download(waiting.minBy { it.addedAt })
        }
    }

    private fun fail(id: String, message: String, partial: Boolean) =
        change(id) { it.copy(state = if (partial) SaveState.PAUSED else SaveState.FAILED, error = if (partial) "Interrupted. Resume to carry on." else message) }

    private suspend fun download(t: SavedTitle) {
        val id = t.itemId
        change(id) { it.copy(state = SaveState.DOWNLOADING, error = null) }
        val url = runCatching { resolver.resolve(t.sourceId, t.streamRef) }.getOrNull()
        if (url == null) { fail(id, "This title could not be found on its connection.", false); return }
        if (SavedTitles.isStreamingList(url)) { fail(id, "This title streams in pieces and cannot be saved as one file.", false); return }
        val name = SavedTitles.fileName(id, url)
        val part = File(folder, "$name.part")
        try {
            val headers = runCatching { resolver.headers(t.sourceId) }.getOrDefault(emptyMap())
            val have = part.length()
            val request = Request.Builder().url(url).header("User-Agent", headers["User-Agent"] ?: "VLC/3.0.20 LibVLC/3.0.20")
                .apply { headers.forEach { (k, v) -> header(k, v) }; if (have > 0) header("Range", "bytes=$have-") }.build()
            Http.client.newCall(request).execute().use { resp ->
                if (resp.code == 416) { part.delete(); change(id) { it.copy(state = SaveState.QUEUED, bytesDone = 0) }; return }
                if (!resp.isSuccessful) { fail(id, "The connection refused the download (code ${resp.code}).", false); return }
                val append = resp.code == 206 && have > 0
                val body = resp.body ?: run { fail(id, "The connection sent nothing.", false); return }
                val start = if (append) have else 0L
                val total = body.contentLength().takeIf { it > 0 }?.let { start + it } ?: 0L
                change(id) { it.copy(fileName = name, bytesTotal = total, bytesDone = start) }
                FileOutputStream(part, append).use { out ->
                    val buffer = ByteArray(64 * 1024)
                    var done = start
                    var tick = System.currentTimeMillis()
                    body.byteStream().use { input ->
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n); done += n
                            val now = System.currentTimeMillis()
                            if (now - tick >= 700) {
                                tick = now
                                val current = item(id)
                                if (current == null || current.state != SaveState.DOWNLOADING) return          // paused or removed
                                if (busy()) { change(id) { it.copy(state = SaveState.QUEUED, bytesDone = done) }; return }          // something started playing
                                _items.value = _items.value.map { if (it.itemId == id) it.copy(bytesDone = done) else it }
                                if (done - (lastSaved[id] ?: 0L) > 16_000_000) { lastSaved[id] = done; persist() }
                            }
                        }
                    }
                }
            }
            if (item(id) == null) { part.delete(); return }
            val finalFile = File(folder, name)
            finalFile.delete()
            if (part.renameTo(finalFile)) change(id) { it.copy(state = SaveState.DONE, bytesDone = finalFile.length(), bytesTotal = finalFile.length(), fileName = name, error = null) }
            else fail(id, "The file could not be saved on this device.", false)
        } catch (e: IOException) {
            val message = (e.message ?: "The connection was lost.").replace(Regex("https?://\\S+"), "the connection")
            if (item(id) != null) fail(id, message, part.exists() && part.length() > 0)
        }
    }
}

/** Keeps the downloads going when the app is left, and shows how far they are. It stops itself when nothing is left to save. */
@AndroidEntryPoint
class DownloadService : Service() {
    @Inject lateinit var container: AppContainer
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        show(container.downloads.items.value)
        scope.launch { container.downloads.items.collect { show(it) } }
        return START_NOT_STICKY
    }

    private fun show(items: List<SavedTitle>) {
        val active = items.filter { it.state == SaveState.DOWNLOADING || it.state == SaveState.QUEUED }
        if (active.isEmpty()) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return }
        val current = active.firstOrNull { it.state == SaveState.DOWNLOADING } ?: active.first()
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle(if (active.size > 1) "Saving ${active.size} titles" else "Saving ${current.title}")
            .setContentText(if (current.state == SaveState.DOWNLOADING) "${(current.fraction * 100).toInt()} %" else "Waiting")
            .setProgress(100, (current.fraction * 100).toInt(), current.bytesTotal <= 0).setOngoing(true).setOnlyAlertOnce(true).build()
        if (!foreground) {
            if (Build.VERSION.SDK_INT >= 29) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) else startForeground(ID, n)
            foreground = true
        } else (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(ID, n)
    }

    override fun onDestroy() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); super.onDestroy() }

    companion object { private const val CHANNEL = "downloads"; private const val ID = 7 }
}
