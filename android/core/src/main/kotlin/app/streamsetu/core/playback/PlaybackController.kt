package app.streamsetu.core.playback

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import app.streamsetu.core.model.Playable
import app.streamsetu.core.net.Http
import app.streamsetu.core.net.StreamResolver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The one player. It owns an ExoPlayer, turns a [Playable] into an address, starts it, retries when the stream drops (see [RecoveryPolicy]),
 * waits for the network when it is gone, and reports progress so the position can be remembered.
 */
class PlaybackController(
    context: Context,
    private val resolver: StreamResolver,
    private val policy: RecoveryPolicy = RecoveryPolicy(),
    private val onProgress: suspend (Playable, positionMs: Long, durationMs: Long) -> Unit = { _, _, _ -> },
    private val onStarted: suspend (Playable) -> Unit = {},
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val dataSourceFactory: DataSource.Factory = OkHttpDataSource.Factory(Http.client).setUserAgent(Http.USER_AGENT)

    val player: ExoPlayer = ExoPlayer.Builder(appContext)
        .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
        .setLoadControl(
            DefaultLoadControl.Builder()
                // Enough buffer to ride out a slow provider, but a short wait before the first picture.
                .setBufferDurationsMs(20_000, 60_000, 1_500, 4_000)
                .build()
        )
        .setHandleAudioBecomingNoisy(true)
        .build()

    private val _state = MutableStateFlow<PlaybackState>(PlaybackState.Idle)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val _current = MutableStateFlow<Playable?>(null)
    val current: StateFlow<Playable?> = _current.asStateFlow()

    private val _audio = MutableStateFlow<List<TrackOption>>(emptyList())
    val audioTracks: StateFlow<List<TrackOption>> = _audio.asStateFlow()
    private val _subtitles = MutableStateFlow<List<TrackOption>>(emptyList())
    val subtitleTracks: StateFlow<List<TrackOption>> = _subtitles.asStateFlow()

    private var attempt = 0
    private var startPositionMs = 0L
    private var job: Job? = null
    private var progressJob: Job? = null
    private var waitingForNetwork = false
    private var lastResolved: String? = null

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> if (_state.value !is PlaybackState.Retrying) _state.value = PlaybackState.Buffering
                    Player.STATE_READY -> { attempt = 0; _state.value = if (player.playWhenReady) PlaybackState.Playing else PlaybackState.Paused }
                    Player.STATE_ENDED -> _state.value = PlaybackState.Ended
                    Player.STATE_IDLE -> {}
                }
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (player.playbackState == Player.STATE_READY) _state.value = if (playWhenReady) PlaybackState.Playing else PlaybackState.Paused
            }

            override fun onPlayerError(error: PlaybackException) = handleError(classify(error))

            override fun onTracksChanged(tracks: Tracks) = refreshTracks(tracks)
        })
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post { if (waitingForNetwork) { waitingForNetwork = false; restart() } } }
        })
    }

    /** Starts [item]. A movie or episode resumes at [resumeAtMs]. */
    fun play(item: Playable, resumeAtMs: Long = 0) {
        saveProgress()
        job?.cancel()
        attempt = 0
        startPositionMs = if (item.isLive) 0 else resumeAtMs
        _current.value = item
        _state.value = PlaybackState.Resolving
        _audio.value = emptyList(); _subtitles.value = emptyList()
        startProgressTicker(item)
        job = scope.launch { startNow(item) }
    }

    private suspend fun startNow(item: Playable) {
        val url = resolver.resolve(item.sourceId, item.streamRef)
        if (url == null) { _state.value = PlaybackState.Failed(PlaybackError(ErrorKind.NOT_FOUND, "The playlist for this item is gone or has no login.")); return }
        lastResolved = url
        player.setMediaItem(MediaItem.fromUri(url), if (startPositionMs > 5_000) startPositionMs else C.TIME_UNSET)
        player.prepare()
        player.playWhenReady = true
        onStarted(item)
    }

    private fun restart() {
        val item = _current.value ?: return
        if (!item.isLive) startPositionMs = player.currentPosition
        job?.cancel()
        job = scope.launch { startNow(item) }
    }

    private fun handleError(error: PlaybackError) {
        val item = _current.value ?: return
        val decision = policy.decide(error, attempt, item.isLive, online = isOnline())
        when (decision) {
            is RecoveryPolicy.Decision.GiveUp -> {
                if (decision.error.kind == ErrorKind.NO_NETWORK) waitingForNetwork = true
                _state.value = PlaybackState.Failed(decision.error)
            }
            is RecoveryPolicy.Decision.Retry -> {
                attempt = decision.attempt
                _state.value = PlaybackState.Retrying(attempt, (decision.delayMs / 1000).toInt().coerceAtLeast(1))
                job?.cancel()
                job = scope.launch { delay(decision.delayMs); restart() }
            }
        }
    }

    fun retryNow() { attempt = 0; _state.value = PlaybackState.Resolving; restart() }

    fun togglePause() { if (player.isPlaying) player.pause() else player.play() }
    fun seekBy(deltaMs: Long) { if (_current.value?.isLive == false) player.seekTo((player.currentPosition + deltaMs).coerceIn(0, player.duration.takeIf { it > 0 } ?: Long.MAX_VALUE)) }
    val positionMs: Long get() = player.currentPosition
    val durationMs: Long get() = player.duration.takeIf { it != C.TIME_UNSET } ?: 0

    fun selectAudio(id: String?) = select(C.TRACK_TYPE_AUDIO, id)
    fun selectSubtitle(id: String?) = select(C.TRACK_TYPE_TEXT, id)

    private fun select(type: Int, id: String?) {
        val builder = player.trackSelectionParameters.buildUpon()
        if (id == null) {
            builder.setTrackTypeDisabled(type, true)
        } else {
            val (g, t) = id.split(':').map { it.toInt() }
            val group = player.currentTracks.groups.filter { it.type == type }.getOrNull(g) ?: return
            builder.setTrackTypeDisabled(type, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, t))
        }
        player.trackSelectionParameters = builder.build()
    }

    private fun refreshTracks(tracks: Tracks) {
        fun options(type: Int) = tracks.groups.filter { it.type == type }.flatMapIndexed { g, group ->
            (0 until group.length).filter { group.isTrackSupported(it) }.map { t ->
                val f = group.getTrackFormat(t)
                TrackOption("$g:$t", f.label ?: f.language?.let { java.util.Locale(it).displayLanguage } ?: "Track ${g + 1}", f.language, group.isTrackSelected(t))
            }
        }
        _audio.value = options(C.TRACK_TYPE_AUDIO); _subtitles.value = options(C.TRACK_TYPE_TEXT)
    }

    private fun startProgressTicker(item: Playable) {
        progressJob?.cancel()
        if (item.isLive) return
        progressJob = scope.launch { while (true) { delay(10_000); saveProgress() } }
    }

    /** Remembers where a movie or episode stopped. */
    fun saveProgress() {
        val item = _current.value ?: return
        if (item.isLive) return
        val pos = player.currentPosition; val dur = durationMs
        if (dur > 0) scope.launch { onProgress(item, pos, dur) }
    }

    fun stop() {
        saveProgress()
        job?.cancel(); progressJob?.cancel()
        player.stop(); player.clearMediaItems()
        _current.value = null; _state.value = PlaybackState.Idle
    }

    fun release() { stop(); player.release(); scope.coroutineContext[Job]?.cancel() }

    private fun isOnline(): Boolean {
        val n = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(n)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }

    private fun classify(e: PlaybackException): PlaybackError {
        val http = generateSequence(e.cause) { it.cause }.filterIsInstance<androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
        return when {
            http == 404 || http == 410 -> PlaybackError(ErrorKind.NOT_FOUND, "Not found", http)
            http == 401 || http == 403 || http == 429 || http == 458 || (http != null && http >= 500 && http != 503) -> PlaybackError(ErrorKind.SERVER_REFUSED, "Refused", http)
            http == 503 -> PlaybackError(ErrorKind.SERVER_REFUSED, "Busy", http)
            e.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT || e.errorCode == PlaybackException.ERROR_CODE_TIMEOUT -> PlaybackError(ErrorKind.TIMEOUT, "Timed out")
            e.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> PlaybackError(ErrorKind.NO_NETWORK, "Network failed")
            e.errorCode in listOf(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED) -> PlaybackError(ErrorKind.FORMAT, "Unsupported")
            e.errorCode in listOf(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, PlaybackException.ERROR_CODE_DECODING_FAILED) -> PlaybackError(ErrorKind.DECODER, "Decoder failed")
            else -> PlaybackError(ErrorKind.UNKNOWN, e.message.orEmpty())
        }
    }
}
