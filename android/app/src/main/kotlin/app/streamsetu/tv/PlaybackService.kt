package app.streamsetu.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState as SessionState
import android.os.Build
import android.os.IBinder
import app.streamsetu.core.model.EpisodePlayable
import app.streamsetu.core.model.Playable
import app.streamsetu.core.playback.PlaybackState
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Keeps the sound playing when the app is left, and puts the controls on the lock screen and in the notification shade. It runs while something is playing
 * and stops itself when playback stops. The player itself lives in [app.streamsetu.core.playback.PlaybackController]; this only shows and forwards.
 */
@AndroidEntryPoint
class PlaybackService : Service() {
    @Inject lateinit var container: AppContainer
    private lateinit var session: MediaSession
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var artworkFor: String? = null
    private var artwork: Bitmap? = null
    private var artJob: Job? = null
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Now playing", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        session = MediaSession(this, "StreamSetu").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { if (container.playback.state.value == PlaybackState.Paused) container.playback.togglePause() }
                override fun onPause() { if (container.playback.state.value == PlaybackState.Playing) container.playback.togglePause() }
                override fun onSkipToNext() = skip(+1)
                override fun onSkipToPrevious() = skip(-1)
                override fun onFastForward() = container.playback.seekBy(30_000)
                override fun onRewind() = container.playback.seekBy(-10_000)
                override fun onSeekTo(pos: Long) = container.playback.seekBy(pos - container.playback.positionMs)
                override fun onStop() = container.playback.stop()
            })
            isActive = true
        }
        val p = container.playback
        scope.launch { combine(p.current, p.state, p.audioOnly) { c, s, _ -> c to s }.collect { refresh() } }
        scope.launch { while (true) { delay(15_000); if (container.playback.state.value == PlaybackState.Playing) refresh() } }
    }

    private fun skip(delta: Int) { val c = container; if (c.queue.size > 1) c.step(delta) else c.playback.seekBy(if (delta > 0) 30_000 else -10_000) }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> container.playback.togglePause()
            ACTION_NEXT -> skip(+1)
            ACTION_PREVIOUS -> skip(-1)
            ACTION_STOP -> container.playback.stop()
        }
        refresh()
        return START_NOT_STICKY
    }

    private fun action(code: Int, name: String) = PendingIntent.getService(this, code, Intent(this, PlaybackService::class.java).setAction(name), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun refresh() {
        val p = container.playback
        val item: Playable? = p.current.value
        if (item == null) {
            // Android insists that a service started as a foreground service shows its notification at least once, even when it is about to stop.
            if (!foreground) { startForegroundNow(placeholder()); }
            stopForegroundCompat(); stopSelf(); return
        }
        val st = p.state.value
        val playing = st == PlaybackState.Playing || st == PlaybackState.Buffering || st == PlaybackState.Resolving
        val subtitle = if (item is EpisodePlayable) item.series.title else if (item.isLive) "Live" else null
        val duration = if (item.isLive) -1L else p.durationMs
        session.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, item.title).putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle).putLong(MediaMetadata.METADATA_KEY_DURATION, duration)
            .apply { artwork?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }.build())
        val actions = SessionState.ACTION_PLAY or SessionState.ACTION_PAUSE or SessionState.ACTION_PLAY_PAUSE or SessionState.ACTION_STOP or SessionState.ACTION_SKIP_TO_NEXT or SessionState.ACTION_SKIP_TO_PREVIOUS or
            (if (item.isLive) 0L else SessionState.ACTION_SEEK_TO or SessionState.ACTION_FAST_FORWARD or SessionState.ACTION_REWIND)
        session.setPlaybackState(SessionState.Builder().setActions(actions)
            .setState(if (playing) SessionState.STATE_PLAYING else if (st == PlaybackState.Paused) SessionState.STATE_PAUSED else SessionState.STATE_BUFFERING, if (item.isLive) SessionState.PLAYBACK_POSITION_UNKNOWN else p.positionMs, if (playing) 1f else 0f).build())
        loadArtwork(item)

        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        @Suppress("DEPRECATION")
        b.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle(item.title).setContentText(subtitle).setContentIntent(open).setOngoing(playing).setShowWhen(false).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_media_previous, "Previous", action(1, ACTION_PREVIOUS))
            .addAction(if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Pause" else "Play", action(2, ACTION_TOGGLE))
            .addAction(android.R.drawable.ic_media_next, "Next", action(3, ACTION_NEXT))
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", action(4, ACTION_STOP))
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
        artwork?.let { b.setLargeIcon(it) }
        val n = b.build()
        if (!foreground) startForegroundNow(n)
        else (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(ID, n)
    }

    private fun startForegroundNow(n: Notification) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK) else startForeground(ID, n)
        foreground = true
    }

    private fun placeholder(): Notification {
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.ic_media_play).setContentTitle("StreamSetu").build()
    }

    private fun loadArtwork(item: Playable) {
        val url = item.artworkUrl?.takeIf { it.isNotBlank() }
        if (url == artworkFor) return
        artworkFor = url; artwork = null; artJob?.cancel()
        if (url == null) return
        artJob = scope.launch {
            val req = coil.request.ImageRequest.Builder(this@PlaybackService).data(url).size(256).allowHardware(false).build()
            val bmp = (coil.Coil.imageLoader(this@PlaybackService).execute(req).drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap
            if (bmp != null && artworkFor == url) { artwork = bmp; refresh() }
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() { if (foreground) { if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true); foreground = false } }

    override fun onDestroy() {
        scope.cancel()
        runCatching { session.isActive = false; session.release() }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "now-playing"
        private const val ID = 7
        const val ACTION_TOGGLE = "app.streamsetu.TOGGLE"
        const val ACTION_NEXT = "app.streamsetu.NEXT"
        const val ACTION_PREVIOUS = "app.streamsetu.PREVIOUS"
        const val ACTION_STOP = "app.streamsetu.STOP"

        /** Starts the service. Called while the app is on screen, which is the only time the system allows it. */
        fun start(context: Context) {
            val i = Intent(context, PlaybackService::class.java)
            runCatching { if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i) }
        }
    }
}
