package app.streamsetu.core.playback

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.view.View
import app.streamsetu.core.model.Playable
import app.streamsetu.core.net.StreamResolver
import app.streamsetu.core.settings.AppSettings
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
 * The Mac's `PlaybackCoordinator`. It picks the engine for each stream (ExoPlayer or MPV, per the Settings and the stream's format), starts it, retries when
 * the stream drops ([RecoveryPolicy]), switches to the other engine once when a format is not supported, waits for the network when it is gone,
 * and reports progress so the position can be remembered. The engines only play.
 */
class PlaybackController(
    context: Context,
    private val resolver: StreamResolver,
    private val settings: AppSettings,
    private val policy: RecoveryPolicy = RecoveryPolicy(),
    private val onProgress: suspend (Playable, positionMs: Long, durationMs: Long) -> Unit = { _, _, _ -> },
    private val onStarted: suspend (Playable) -> Unit = {},
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val engines = HashMap<EngineKind, PlayerEngine>()
    /** MPV needs Android 8 and its native libraries; on anything older the app plays with ExoPlayer alone. */
    val available: Set<EngineKind> = buildSet { add(EngineKind.EXOPLAYER); if (MpvEngine.isSupported()) add(EngineKind.MPV) }

    private val _engine = MutableStateFlow<PlayerEngine?>(null)
    /** The engine playing now (its [PlayerEngine.view] is the picture). */
    val engine: StateFlow<PlayerEngine?> = _engine.asStateFlow()

    private val _state = MutableStateFlow<PlaybackState>(PlaybackState.Idle)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()
    private val _current = MutableStateFlow<Playable?>(null)
    val current: StateFlow<Playable?> = _current.asStateFlow()
    private val _audio = MutableStateFlow<List<TrackOption>>(emptyList())
    val audioTracks: StateFlow<List<TrackOption>> = _audio.asStateFlow()
    private val _subtitles = MutableStateFlow<List<TrackOption>>(emptyList())
    val subtitleTracks: StateFlow<List<TrackOption>> = _subtitles.asStateFlow()

    private val _speed = MutableStateFlow(1f)
    val speed: StateFlow<Float> = _speed.asStateFlow()
    private val _aspect = MutableStateFlow(AspectMode.FIT)
    val aspect: StateFlow<AspectMode> = _aspect.asStateFlow()
    /** Set when a movie or episode starts partway through (resumed): the position, so the screen can offer Start Over. */
    private val _resumedFrom = MutableStateFlow(0L)
    val resumedFrom: StateFlow<Long> = _resumedFrom.asStateFlow()
    private var bufferingSince = 0L
    private var attempt = 0
    private var switchedEngine = false
    private var startPositionMs = 0L
    private var job: Job? = null
    private var progressJob: Job? = null
    private var waitingForNetwork = false
    private var appliedPreferredTracks = false
    private val closedAt = HashMap<String, Long>()      // when a stream of each playlist was last closed: one-connection accounts need a moment
    private var startedAt = 0L
    private var firstFrameLogged = false
    private var loggedStart = false      // a play is logged once, however many times it is retried or moved to the other engine

    init {
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post { if (waitingForNetwork) { waitingForNetwork = false; restart() } } }
        })
    }

    private fun engineFor(kind: EngineKind): PlayerEngine = engines.getOrPut(kind) {
        (if (kind == EngineKind.MPV) MpvEngine(appContext) else ExoEngine(appContext)).also { e -> e.onEvent = { ev -> if (_engine.value === e) handle(ev) } }
    }

    /** Starts [item]. A movie or episode resumes at [resumeAtMs] (when the Settings allow it). */
    fun play(item: Playable, resumeAtMs: Long = 0) {
        _current.value?.let { closedAt[it.sourceId] = System.currentTimeMillis() }
        saveProgress()
        job?.cancel()
        attempt = 0; switchedEngine = false; appliedPreferredTracks = false; loggedStart = false; firstFrameLogged = false; bufferingSince = 0L
        startPositionMs = if (item.isLive || !settings.resumeAutomatically.value) 0 else resumeAtMs
        _resumedFrom.value = if (startPositionMs > 30_000) startPositionMs else 0
        _speed.value = 1f
        _current.value = item
        _state.value = PlaybackState.Resolving
        _audio.value = emptyList(); _subtitles.value = emptyList()
        startProgressTicker(item)
        job = scope.launch { startNow(item, null) }
    }

    private suspend fun startNow(item: Playable, forced: EngineKind?) {
        // A provider that allows one connection keeps the last one open for a few seconds; opening another at once is refused or very slow.
        val wait = 3500 - (System.currentTimeMillis() - (closedAt[item.sourceId] ?: 0L))
        if (wait in 1..3500) { android.util.Log.i("Playback", "pacing: waiting ${wait} ms for the provider"); delay(wait) }
        val url = resolver.resolve(item.sourceId, item.streamRef)
        if (url == null) { _state.value = PlaybackState.Failed(PlaybackError(ErrorKind.NOT_FOUND, "The playlist for this item is gone or has no login.")); return }
        val container = StreamContainer.of(url, item.isLive)
        val kind = forced ?: EngineSelector.select(container, settings.enginePreference.value, available)
        android.util.Log.i("Playback", "start ${if (item.isLive) "live" else "vod"} '${item.title}' container=$container engine=${kind.label} (preference=${settings.enginePreference.value.label}) host=${runCatching { java.net.URI(url).host }.getOrNull()}")
        val next = engineFor(kind)
        val previous = _engine.value
        if (previous != null && previous !== next) previous.stop()
        _engine.value = next
        next.setAspect(_aspect.value); next.setSpeed(1f)
        startedAt = System.currentTimeMillis()
        next.load(EngineRequest(url, emptyMap(), startPositionMs, item.isLive, settings.bufferingMode.value))
        if (!loggedStart) { loggedStart = true; onStarted(item) }
    }

    private fun handle(ev: EngineEvent) {
        android.util.Log.i("Playback", "${_engine.value?.kind?.label}: $ev pos=${positionMs / 1000}s dur=${durationMs / 1000}s")
        when (ev) {
            EngineEvent.Buffering -> { if (bufferingSince == 0L) bufferingSince = System.currentTimeMillis(); if (_state.value !is PlaybackState.Retrying) _state.value = PlaybackState.Buffering }
            is EngineEvent.Ready -> { bufferingSince = 0L; if (!firstFrameLogged) { firstFrameLogged = true; android.util.Log.i("Playback", "first picture after ${System.currentTimeMillis() - startedAt} ms (${_engine.value?.kind?.label})") }; attempt = 0; _state.value = if (ev.playing) PlaybackState.Playing else PlaybackState.Paused; refreshTracks() }
            EngineEvent.Ended -> { _state.value = PlaybackState.Ended; onEnded() }
            EngineEvent.TracksChanged -> refreshTracks()
            is EngineEvent.Error -> handleError(ev.error)
        }
    }

    private fun onEnded() {
        saveProgress()
    }

    private fun restart(forced: EngineKind? = null) {
        val item = _current.value ?: return
        val e = _engine.value
        if (!item.isLive && e != null) startPositionMs = e.positionMs
        job?.cancel()
        job = scope.launch { startNow(item, forced ?: e?.kind?.takeIf { switchedEngine }) }
    }

    private fun handleError(error: PlaybackError) {
        val item = _current.value ?: return
        val e = _engine.value
        // A format the engine cannot play goes to the other engine once, like the Mac app does; so does an engine that keeps failing.
        if (!switchedEngine && e != null && (error.kind == ErrorKind.FORMAT || attempt >= 2)) {
            EngineSelector.other(e.kind, available)?.let { other ->
                switchedEngine = true; attempt = 0
                _state.value = PlaybackState.Retrying(0, 1)
                job?.cancel(); job = scope.launch { startPositionMs = if (item.isLive) 0 else e.positionMs; startNow(item, other) }
                return
            }
        }
        when (val d = policy.decide(error, attempt, item.isLive, online = isOnline())) {
            is RecoveryPolicy.Decision.GiveUp -> { if (d.error.kind == ErrorKind.NO_NETWORK) waitingForNetwork = true; _state.value = PlaybackState.Failed(d.error) }
            is RecoveryPolicy.Decision.Retry -> {
                attempt = d.attempt
                _state.value = PlaybackState.Retrying(attempt, (d.delayMs / 1000).toInt().coerceAtLeast(1))
                job?.cancel(); job = scope.launch { delay(d.delayMs); restart() }
            }
        }
    }

    /** A stream that sits in "buffering" for too long is treated as a failure, so the retry and engine-switch rules take over instead of an endless spinner. */
    private fun watchStalls() {
        scope.launch {
            while (true) {
                delay(2000)
                val since = bufferingSince
                val item = _current.value
                if (item != null && since != 0L && _state.value == PlaybackState.Buffering && System.currentTimeMillis() - since > (if (item.isLive) 18_000 else 30_000)) {
                    bufferingSince = 0L
                    android.util.Log.i("Playback", "stalled in buffering; recovering")
                    handleError(PlaybackError(ErrorKind.TIMEOUT, "The stream stopped loading"))
                }
            }
        }
    }
    init { watchStalls() }

    fun setSpeed(s: Float) { _speed.value = s; _engine.value?.setSpeed(s) }
    fun setAspect(m: AspectMode) { _aspect.value = m; _engine.value?.setAspect(m) }
    fun startOver() { _engine.value?.seekTo(0); _resumedFrom.value = 0 }

    /** Switches the player for the stream playing now (the iPhone app's "Player" chip). */
    fun switchEngine(kind: EngineKind) {
        val item = _current.value ?: return
        if (kind !in available || _engine.value?.kind == kind) return
        startPositionMs = if (item.isLive) 0 else positionMs
        switchedEngine = true; attempt = 0
        _state.value = PlaybackState.Resolving
        job?.cancel(); job = scope.launch { startNow(item, kind) }
    }

    fun retryNow() { attempt = 0; switchedEngine = false; _state.value = PlaybackState.Resolving; restart() }
    fun togglePause() { val e = _engine.value ?: return; if (e.isPlaying) e.pause() else e.play() }
    fun seekBy(deltaMs: Long) { val e = _engine.value ?: return; if (_current.value?.isLive == false) e.seekTo((e.positionMs + deltaMs).coerceIn(0, e.durationMs.takeIf { it > 0 } ?: Long.MAX_VALUE)) }
    val positionMs: Long get() = _engine.value?.positionMs ?: 0
    val durationMs: Long get() = _engine.value?.durationMs ?: 0
    val engineKind: EngineKind? get() = _engine.value?.kind
    fun streamInfo(): String = _engine.value?.streamInfo().orEmpty()

    fun selectAudio(id: String?) { _engine.value?.selectAudio(id); main.postDelayed({ refreshTracks() }, 300) }
    fun selectSubtitle(id: String?) { _engine.value?.selectSubtitle(id); main.postDelayed({ refreshTracks() }, 300) }

    private fun refreshTracks() {
        val e = _engine.value ?: return
        _audio.value = e.audioTracks(); _subtitles.value = e.subtitleTracks()
        if (appliedPreferredTracks || (_audio.value.isEmpty() && _subtitles.value.isEmpty())) return
        appliedPreferredTracks = true
        val al = settings.audioLanguage.value; val sl = settings.subtitleLanguage.value
        if (al.isNotBlank()) _audio.value.firstOrNull { it.language?.startsWith(al, true) == true }?.let { e.selectAudio(it.id) }
        if (settings.subtitlesByDefault.value) (_subtitles.value.firstOrNull { sl.isNotBlank() && it.language?.startsWith(sl, true) == true } ?: _subtitles.value.firstOrNull())?.let { e.selectSubtitle(it.id) }
    }

    private fun startProgressTicker(item: Playable) {
        progressJob?.cancel()
        if (item.isLive) return
        progressJob = scope.launch { while (true) { delay(10_000); saveProgress() } }
    }

    /** Remembers where a movie or episode stopped (when the Settings allow it). */
    fun saveProgress() {
        val item = _current.value ?: return
        if (item.isLive || !settings.rememberPosition.value) return
        val pos = positionMs; val dur = durationMs
        if (dur > 0) scope.launch { onProgress(item, pos, dur) }
    }

    fun stop() {
        saveProgress()
        job?.cancel(); progressJob?.cancel()
        _current.value?.let { closedAt[it.sourceId] = System.currentTimeMillis() }
        _engine.value?.stop()
        _current.value = null; _state.value = PlaybackState.Idle
    }

    fun release() { stop(); engines.values.forEach { it.release() }; engines.clear(); scope.coroutineContext[Job]?.cancel() }

    private fun isOnline(): Boolean {
        val n = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(n)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }
}
