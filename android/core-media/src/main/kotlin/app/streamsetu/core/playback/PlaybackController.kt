package app.streamsetu.core.playback

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.view.View
import app.streamsetu.core.model.Playable
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
    private val resolver: StreamUrlResolver,
    private val settings: AppSettings,
    private val policy: RecoveryPolicy = RecoveryPolicy(),
    private val onProgress: suspend (Playable, positionMs: Long, durationMs: Long) -> Unit = { _, _, _ -> },
    private val onStarted: suspend (Playable) -> Unit = {},
    /** Told every few seconds how long the current item has really been playing (for the Statistics page). */
    private val onWatched: suspend (Playable, ms: Long) -> Unit = { _, _ -> },
    /** Asked once when a stream is refused or gone: returns the same item with a fresh address (an expired playlist link), or null when it cannot. */
    private val refreshStream: suspend (Playable) -> Playable? = { null },
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

    // ---- Sleep timer ----
    private val _sleepEndsAt = MutableStateFlow(0L)
    /** When the sleep timer will stop playback (milliseconds since 1970), or 0 when it is off. */
    val sleepEndsAt: StateFlow<Long> = _sleepEndsAt.asStateFlow()
    private var sleepJob: Job? = null
    /** Stops playback after [minutes]; 0 turns the timer off. */
    fun startSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        if (minutes <= 0) { _sleepEndsAt.value = 0; return }
        val end = System.currentTimeMillis() + minutes * 60_000L
        _sleepEndsAt.value = end
        sleepJob = scope.launch { while (System.currentTimeMillis() < end) delay(1000); _sleepEndsAt.value = 0; stop() }
    }

    // ---- Sound only: the app is in the background, or the mini player is showing ----
    private val _audioOnly = MutableStateFlow(false)
    val audioOnly: StateFlow<Boolean> = _audioOnly.asStateFlow()
    private var minimized = false
    private var backgroundHold = false
    private var appliedAudioOnly = false
    private fun applyAudioOnly() {
        val on = minimized || backgroundHold
        _audioOnly.value = on
        _engine.value?.setVideoEnabled(!on)
        appliedAudioOnly = true
    }
    /** The mini player is showing instead of the picture: only the sound plays. */
    fun setMinimized(on: Boolean) { minimized = on; applyAudioOnly() }

    // ---- Subtitles from a file, and the delay of subtitles and sound ----
    private val _subtitleDelay = MutableStateFlow(0L)
    val subtitleDelayMs: StateFlow<Long> = _subtitleDelay.asStateFlow()
    private val _audioDelay = MutableStateFlow(0L)
    val audioDelayMs: StateFlow<Long> = _audioDelay.asStateFlow()
    /** True when the player in use can move subtitles and sound (MPV can; ExoPlayer cannot). */
    val canDelay: Boolean get() = _engine.value?.kind == EngineKind.MPV
    fun setSubtitleDelay(ms: Long): Boolean = (_engine.value?.setSubtitleDelay(ms) == true).also { if (it) { _subtitleDelay.value = ms; remember() } }
    fun setAudioDelay(ms: Long): Boolean = (_engine.value?.setAudioDelay(ms) == true).also { if (it) { _audioDelay.value = ms; remember() } }
    fun addSubtitle(address: String, label: String): Boolean = _engine.value?.addSubtitle(address, label) == true

    // ---- Picture, sound and subtitle tuning, chapters, quality, and what is remembered for each title ----
    private val _tuning = MutableStateFlow(PlayerTuning())
    val tuning: StateFlow<PlayerTuning> = _tuning.asStateFlow()
    private val _subtitleStyle = MutableStateFlow<SubtitleStyle?>(null)
    /** The subtitle look chosen from the player; null until the person changes it (then the Settings apply). */
    val subtitleStyle: StateFlow<SubtitleStyle?> = _subtitleStyle.asStateFlow()
    private val _chapters = MutableStateFlow<List<Chapter>>(emptyList())
    val chapters: StateFlow<List<Chapter>> = _chapters.asStateFlow()
    private val _qualities = MutableStateFlow<List<TrackOption>>(emptyList())
    val qualities: StateFlow<List<TrackOption>> = _qualities.asStateFlow()
    private val memory = appContext.getSharedPreferences("item-memory", Context.MODE_PRIVATE)
    /** Audio language, subtitles, speed, picture size, sound and picture settings come back the next time the same title or channel is played. */
    var rememberPerTitle: Boolean
        get() = memory.getBoolean("enabled", true)
        set(v) { memory.edit().putBoolean("enabled", v).apply() }
    /** Move on to the next episode by itself when one ends (after a short countdown). */
    var autoPlayNext: Boolean
        get() = memory.getBoolean("autonext", true)
        set(v) { memory.edit().putBoolean("autonext", v).apply() }
    private fun memoryKey(item: Playable) = "m." + item.id

    private fun applyTuningLater() { main.postDelayed({ _engine.value?.let { it.applyTuning(_tuning.value) } }, 800) }

    fun setTuning(t: PlayerTuning) {
        val old = _tuning.value
        _tuning.value = t
        val e = _engine.value
        e?.applyTuning(t)
        // Hardware or software decoding is chosen when the player is built, so ExoPlayer starts the same stream again at the same place.
        if (old.softwareDecoding != t.softwareDecoding && e?.kind == EngineKind.EXOPLAYER) restart()
        remember()
    }

    /** How subtitles look now: what the person chose in the player, else what the Settings say. */
    fun currentSubtitleStyle(): SubtitleStyle = _subtitleStyle.value ?: SubtitleStyle(
        when (settings.subtitleSize.value) { "SMALL" -> 0.8f; "LARGE" -> 1.3f; "XLARGE" -> 1.6f; else -> 1f }, settings.subtitleBackground.value == "DARK", settings.subtitleOutline.value)

    fun setSubtitleStyle(s: SubtitleStyle) { _subtitleStyle.value = s; _engine.value?.applySubtitleStyle(s) }
    fun selectQuality(id: String?) { _engine.value?.selectVideo(id); main.postDelayed({ _qualities.value = _engine.value?.videoQualities().orEmpty() }, 400) }
    /** Jumps to a time in a movie or episode. */
    fun goTo(ms: Long) { val e = _engine.value ?: return; if (_current.value?.isLive == true) return; userSeeked = true; e.seekTo(ms.coerceIn(0, e.durationMs.takeIf { it > 0 } ?: Long.MAX_VALUE)) }

    /** Keeps this title's choices (or this channel's) for next time. */
    fun remember() {
        val item = _current.value ?: return
        if (!rememberPerTitle) return
        val a = _audio.value.firstOrNull { it.selected }; val s = _subtitles.value.firstOrNull { it.selected }
        val t = _tuning.value
        memory.edit().putString(memoryKey(item), listOf(
            a?.language.orEmpty(), if (s == null) "off" else s.language.orEmpty(), _speed.value, _aspect.value.name, _audioDelay.value, _subtitleDelay.value,
            t.brightness, t.contrast, t.saturation, t.gamma, t.deinterlace, t.softwareDecoding, t.boostPercent, t.normalizeLoudness,
        ).joinToString("|")).apply()
    }

    private var remembered: List<String>? = null
    private fun recall(item: Playable) {
        remembered = if (rememberPerTitle) memory.getString(memoryKey(item), null)?.split('|')?.takeIf { it.size >= 14 } else null
        val r = remembered ?: run { _tuning.value = _tuning.value.copy(brightness = 0, contrast = 0, saturation = 0, gamma = 0, deinterlace = false, boostPercent = 100, normalizeLoudness = false); return }
        r[2].toFloatOrNull()?.let { _speed.value = it }
        runCatching { AspectMode.valueOf(r[3]) }.getOrNull()?.let { _aspect.value = it }
        _audioDelay.value = r[4].toLongOrNull() ?: 0; _subtitleDelay.value = r[5].toLongOrNull() ?: 0
        _tuning.value = PlayerTuning(r[6].toIntOrNull() ?: 0, r[7].toIntOrNull() ?: 0, r[8].toIntOrNull() ?: 0, r[9].toIntOrNull() ?: 0, r[10].toBooleanStrictOrNull() ?: false, r[11].toBooleanStrictOrNull() ?: false, r[12].toIntOrNull() ?: 100, r[13].toBooleanStrictOrNull() ?: false)
    }

    // ---- Skip intro ----
    private val introPrefs = appContext.getSharedPreferences("intro", Context.MODE_PRIVATE)
    private fun introKey(item: Playable) = ((item as? app.streamsetu.core.model.EpisodePlayable)?.series?.id) ?: item.id

    /**
     * Where the opening ends for the episode playing now: what the person's own skip taught the app for this series, else a default of 90 seconds. Null for anything that
     * is not an episode, or once the opening is over. The app has no chapter data from providers, so it learns from the first skip in a series.
     */
    fun introEndMs(): Long? {
        val item = _current.value as? app.streamsetu.core.model.EpisodePlayable ?: return null
        val learned = introPrefs.getLong(introKey(item), 0L)
        return IntroSkip.target(positionMs, if (learned > 0) learned else null)
    }

    fun skipIntro() { val end = introEndMs() ?: return; userSeeked = true; _engine.value?.seekTo(end) }

    /** Where the recap at the start of this episode ends, while it is on screen; null for anything else. */
    fun recapEndMs(): Long? {
        if (_current.value !is app.streamsetu.core.model.EpisodePlayable) return null
        return EpisodeMarks.recapEnd(_chapters.value, positionMs, durationMs)
    }

    fun skipRecap() { val end = recapEndMs() ?: return; userSeeked = true; _engine.value?.seekTo(end) }

    /** True once the credits of this episode have started and there is still something to skip. */
    fun creditsShowing(): Boolean {
        val item = _current.value as? app.streamsetu.core.model.EpisodePlayable ?: return false
        val d = durationMs
        val start = EpisodeMarks.creditsStart(_chapters.value, d, introPrefs.getLong("credits." + introKey(item), 0L)) ?: return false
        return positionMs >= start && d - positionMs > 3_000
    }

    /** Called when the person skips the credits (to the next episode or to the end): the distance from the end is remembered for the rest of the series. */
    fun noteCreditsSkip() {
        val item = _current.value as? app.streamsetu.core.model.EpisodePlayable ?: return
        val d = durationMs
        if (EpisodeMarks.isCreditsSkip(positionMs, d, d)) introPrefs.edit().putLong("credits." + introKey(item), d - positionMs).apply()
    }

    /** Skips to the end of the episode; the app then moves on by itself if it is set to. */
    fun skipCreditsToEnd() { noteCreditsSkip(); userSeeked = true; _engine.value?.let { it.seekTo(it.durationMs) } }

    /** A forward jump early in an episode is taken as skipping the opening: where it landed is remembered for the rest of the series. */
    private fun maybeLearnIntro(fromMs: Long, toMs: Long) {
        val item = _current.value as? app.streamsetu.core.model.EpisodePlayable ?: return
        if (IntroSkip.isOpeningSkip(fromMs, toMs)) introPrefs.edit().putLong(introKey(item), toMs).apply()
    }

    /** A picture of the frame on screen, or null when the player cannot give one. */
    fun snapshot(done: (android.graphics.Bitmap?) -> Unit) { val v = _engine.value?.view(appContext); if (v == null) done(null) else FrameGrab.grab(v, done) }
    /** Providers that allow one connection (from the account's own answer, or learned from a refusal): a new stream waits until the old one is closed. */
    private val strict = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private fun isStrict(sourceId: String) = sourceId in strict || appContext.getSharedPreferences("account-formats", Context.MODE_PRIVATE).getInt("max.$sourceId", 0) == 1
    private var switchedEngine = false
    private var startPositionMs = 0L
    private var job: Job? = null
    private var progressJob: Job? = null
    private var waitingForNetwork = false
    private var appliedPreferredTracks = false
    private val closedAt = HashMap<String, Long>()      // when a stream of each playlist was last closed: one-connection accounts need a moment
    /** Each start gets a new number; progress is only written for the session that is still current and has really shown a picture. */
    private var sessionId = 0
    private var sessionVerified = false
    private var userSeeked = false
    private var startedAt = 0L
    private val errors = ArrayDeque<String>()
    /** The last few player errors, newest first, with no addresses (for the diagnostics screen). */
    fun recentErrors(): List<String> = synchronized(errors) { errors.toList() }
    var lastStartupMs: Long = 0; private set
    private var firstFrameLogged = false
    private var loggedStart = false      // a play is logged once, however many times it is retried or moved to the other engine

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { main.post { if (waitingForNetwork) { waitingForNetwork = false; restart() } } }
    }
    private var networkCallbackRegistered = false

    init {
        connectivity.registerDefaultNetworkCallback(networkCallback)
        networkCallbackRegistered = true
    }

    private fun engineFor(kind: EngineKind): PlayerEngine = engines.getOrPut(kind) {
        (if (kind == EngineKind.MPV) MpvEngine(appContext) else ExoEngine(appContext)).also { e -> e.onEvent = { ev -> if (_engine.value === e) handle(ev) } }
    }

    /** Starts [item]. A movie or episode resumes at [resumeAtMs] (when the Settings allow it). */
    fun play(item: Playable, resumeAtMs: Long = 0) {
        _current.value?.let { closedAt[it.sourceId] = System.currentTimeMillis() }
        saveProgress()
        job?.cancel()
        attempt = 0; switchedEngine = false; appliedPreferredTracks = false; loggedStart = false; firstFrameLogged = false; bufferingSince = 0L; refreshedOnce = false
        startPositionMs = if (item.isLive || !settings.resumeAutomatically.value) 0 else resumeAtMs
        _resumedFrom.value = if (startPositionMs > 30_000) startPositionMs else 0
        sessionId++; sessionVerified = false; userSeeked = false
        minimized = false
        _aspect.value = runCatching { AspectMode.valueOf(settings.defaultAspect.value) }.getOrDefault(AspectMode.FIT)
        _speed.value = 1f
        _subtitleDelay.value = 0; _audioDelay.value = 0; appliedAudioOnly = false
        _current.value = item
        recall(item)
        _state.value = PlaybackState.Resolving
        _audio.value = emptyList(); _subtitles.value = emptyList(); _chapters.value = emptyList(); _qualities.value = emptyList()
        startProgressTicker(item)
        job = scope.launch { startNow(item, null) }
    }

    private suspend fun startNow(item: Playable, forced: EngineKind?) {
        stopRecording()
        // A provider that allows one connection keeps the last one open for a few seconds; opening another at once is refused or very slow.
        if (isStrict(item.sourceId)) { _engine.value?.takeIf { _state.value != PlaybackState.Idle }?.stop(); if (_engine.value != null) closedAt[item.sourceId] = System.currentTimeMillis() }
        val wait = 3500 - (System.currentTimeMillis() - (closedAt[item.sourceId] ?: 0L))
        if (wait in 1..3500) { android.util.Log.i("Playback", "pacing: waiting ${wait} ms for the provider"); delay(wait) }
        val url = LocalFiles.find(item.id) ?: resolver.resolve(item.sourceId, item.streamRef)          // a saved copy plays from the device
        if (url == null) { _state.value = PlaybackState.Failed(PlaybackError(ErrorKind.NOT_FOUND, "The playlist for this item is gone or has no login.")); return }
        val container = StreamContainer.of(url, item.isLive)
        val viewing = when { item is app.streamsetu.core.model.CatchUpPlayable -> "CATCHUP"; item.isLive -> "LIVE"; else -> "MOVIES" }
        val preference = settings.engineFor(item.sourceId) ?: settings.engineForKind(viewing) ?: settings.enginePreference.value
        // A file on this device is opened through Android's content system, which only ExoPlayer can do.
        val kind = forced ?: if (url.startsWith("content://")) EngineKind.EXOPLAYER else EngineSelector.select(container, preference, available)
        android.util.Log.i("Playback", "start ${if (item.isLive) "live" else "vod"} '${item.title}' container=$container engine=${kind.label} (preference=${preference.label}) host=${runCatching { java.net.URI(url).host }.getOrNull()}")
        val next = engineFor(kind)
        val previous = _engine.value
        if (previous != null && previous !== next) previous.stop()
        _engine.value = next
        next.setAspect(_aspect.value); next.setSpeed(_speed.value)
        startedAt = System.currentTimeMillis()
        val buffering = if (item.isLive) settings.liveBufferFor(item.sourceId) ?: settings.liveBuffering.value else settings.vodBuffering.value
        val scale = when (settings.subtitleSize.value) { "SMALL" -> 0.8f; "LARGE" -> 1.3f; "XLARGE" -> 1.6f; else -> 1f }
        val ua = resolver.userAgent(item.sourceId)
        val extra = resolver.headers(item.sourceId)
        next.load(EngineRequest(url, (if (ua != null) mapOf("User-Agent" to ua) else emptyMap()) + extra, startPositionMs, item.isLive, buffering,
            EngineOptions(settings.decoderFallback.value, settings.surroundPassthrough.value, _subtitleStyle.value ?: SubtitleStyle(scale, settings.subtitleBackground.value == "DARK", settings.subtitleOutline.value), settings.mpvProxy.takeIf { !app.streamsetu.core.net.Http.isLocal(runCatching { java.net.URI(url).host }.getOrNull().orEmpty()) }, _tuning.value.softwareDecoding)))
        applyTuningLater()
        if (!loggedStart) { loggedStart = true; onStarted(item) }
    }

    private fun handle(ev: EngineEvent) {
        android.util.Log.i("Playback", "${_engine.value?.kind?.label}: $ev pos=${positionMs / 1000}s dur=${durationMs / 1000}s")
        when (ev) {
            EngineEvent.Buffering -> { if (bufferingSince == 0L) bufferingSince = System.currentTimeMillis(); if (_state.value !is PlaybackState.Retrying) _state.value = PlaybackState.Buffering }
            is EngineEvent.Ready -> { sessionVerified = true; bufferingSince = 0L; if (!firstFrameLogged) { firstFrameLogged = true; lastStartupMs = System.currentTimeMillis() - startedAt; android.util.Log.i("Playback", "first picture after $lastStartupMs ms (${_engine.value?.kind?.label})") }; attempt = 0; _state.value = if (ev.playing) PlaybackState.Playing else PlaybackState.Paused; if (!appliedAudioOnly && _audioOnly.value) applyAudioOnly(); refreshTracks() }
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

    private var refreshedOnce = false

    private fun handleError(error: PlaybackError) {
        val item = _current.value ?: return
        // An address that expired (login or "not found" on a link that used to work) is refreshed from the playlist once before anything else is tried.
        if (!refreshedOnce && (error.kind == ErrorKind.AUTH || error.kind == ErrorKind.NOT_FOUND)) {
            refreshedOnce = true
            job?.cancel()
            job = scope.launch {
                val fresh = runCatching { refreshStream(item) }.getOrNull()
                if (fresh != null && fresh.streamRef != item.streamRef) { android.util.Log.i("Playback", "stream address refreshed from the playlist"); _current.value = fresh; startNow(fresh, null) }
                else recover(error)
            }
            return
        }
        recover(error)
    }

    private fun recover(error: PlaybackError) {
        val item = _current.value ?: return
        synchronized(errors) { errors.addFirst("${java.text.DateFormat.getTimeInstance(java.text.DateFormat.MEDIUM).format(java.util.Date())}  ${error.kind}: ${error.message.take(120)}"); while (errors.size > 20) errors.removeLast() }
        if (error.kind == ErrorKind.SERVER_REFUSED) strict.add(item.sourceId)
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
        val attemptsSoFar = if (settings.automaticRetry.value) attempt else Int.MAX_VALUE / 2     // retries off: give up at once and wait for the person
        when (val d = policy.decide(error, attemptsSoFar, item.isLive, online = isOnline())) {
            is RecoveryPolicy.Decision.GiveUp -> { if (d.error.kind == ErrorKind.NO_NETWORK) waitingForNetwork = true; _state.value = PlaybackState.Failed(d.error) }
            is RecoveryPolicy.Decision.Retry -> {
                attempt = d.attempt
                _state.value = PlaybackState.Retrying(attempt, (d.delayMs / 1000).toInt().coerceAtLeast(1))
                job?.cancel(); job = scope.launch { delay(d.delayMs); restart() }
            }
        }
    }

    private fun stallLimitMs(live: Boolean) = when (settings.stallPatience.value) { "SHORT" -> if (live) 10_000L else 20_000L; "LONG" -> if (live) 30_000L else 60_000L; else -> if (live) 18_000L else 30_000L }

    /** Facts about the stream playing now (engine, container, picture, buffer, dropped frames, start time), with no addresses or logins. */
    fun diagnostics(): Map<String, String> = linkedMapOf("Engine" to (engineKind?.label ?: "none"), "State" to _state.value.toString().substringBefore('(')) + (_engine.value?.diagnostics().orEmpty()) +
        (if (lastStartupMs > 0) mapOf("Time to first picture" to "$lastStartupMs ms") else emptyMap())

    /** A stream that sits in "buffering" for too long is treated as a failure, so the retry and engine-switch rules take over instead of an endless spinner. */
    private fun watchStalls() {
        scope.launch {
            while (true) {
                delay(2000)
                val since = bufferingSince
                val item = _current.value
                if (item != null && since != 0L && _state.value == PlaybackState.Buffering && System.currentTimeMillis() - since > stallLimitMs(item.isLive)) {
                    bufferingSince = 0L
                    android.util.Log.i("Playback", "stalled in buffering; recovering")
                    handleError(PlaybackError(ErrorKind.TIMEOUT, "The stream stopped loading"))
                }
            }
        }
    }
    init { watchStalls() }

    /** Counts the time something is really playing, in small slices. */
    private fun watchClock() {
        scope.launch {
            var last = System.currentTimeMillis()
            while (true) {
                delay(5000)
                val now = System.currentTimeMillis()
                val item = _current.value
                if (item != null && _state.value == PlaybackState.Playing) runCatching { onWatched(item, now - last) }
                last = now
            }
        }
    }
    init { watchClock() }

    fun setSpeed(s: Float) { _speed.value = s; _engine.value?.setSpeed(s); remember() }
    fun setAspect(m: AspectMode) { _aspect.value = m; _engine.value?.setAspect(m); remember() }
    fun startOver() { userSeeked = true; _engine.value?.seekTo(0); _resumedFrom.value = 0 }

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
    fun seekBy(deltaMs: Long) {
        val e = _engine.value ?: return; userSeeked = true
        if (_current.value?.isLive == false) { val to = (e.positionMs + deltaMs).coerceIn(0, e.durationMs.takeIf { it > 0 } ?: Long.MAX_VALUE); maybeLearnIntro(e.positionMs, to); if (EpisodeMarks.isCreditsSkip(e.positionMs, to, e.durationMs)) noteCreditsSkip(); e.seekTo(to) }
    }
    val positionMs: Long get() = _engine.value?.positionMs ?: 0
    val durationMs: Long get() = _engine.value?.durationMs ?: 0
    // ---- Recording the channel being watched ----
    data class RecordingInfo(val path: String, val sinceMs: Long)
    private val _recording = MutableStateFlow<RecordingInfo?>(null)
    /** What is being recorded now (the file and when it began), or null. */
    val recording: StateFlow<RecordingInfo?> = _recording.asStateFlow()

    /** True when the player in use can write the stream to a file (MPV). */
    fun canRecord(): Boolean = _current.value?.let { it.isLive && it !is app.streamsetu.core.model.CatchUpPlayable } == true && _engine.value?.kind == EngineKind.MPV

    /** Starts writing the channel being watched to [file]. A few seconds later the file is checked: if nothing arrived the recording is dropped and [onProblem] is told. */
    fun startRecording(file: java.io.File, onProblem: (String) -> Unit) {
        val e = _engine.value ?: return
        if (_recording.value != null || !canRecord()) return
        if (!e.setRecording(file.absolutePath)) { onProblem("This channel can't be recorded with this player."); return }
        _recording.value = RecordingInfo(file.absolutePath, System.currentTimeMillis())
        scope.launch {
            delay(7_000)
            if (_recording.value?.path == file.absolutePath && file.length() == 0L) { stopRecording(); file.delete(); onProblem("Nothing was recorded: this channel can't be written to a file.") }
        }
    }

    fun stopRecording() {
        if (_recording.value == null) return
        _engine.value?.setRecording(null)
        _recording.value = null
    }

    /** The frame rate of the video playing now, or 0 while it is not known. */
    fun frameRate(): Float = _engine.value?.frameRate() ?: 0f
    val engineKind: EngineKind? get() = _engine.value?.kind
    fun streamInfo(): String = _engine.value?.streamInfo().orEmpty()

    fun selectAudio(id: String?) {
        if (settings.rememberAudioChoice.value) _audio.value.firstOrNull { it.id == id }?.language?.takeIf { it.isNotBlank() }?.let { settings.setAudioLanguage(it) }
        _engine.value?.selectAudio(id); main.postDelayed({ refreshTracks(); remember() }, 300)
    }
    fun selectSubtitle(id: String?) { _engine.value?.selectSubtitle(id); main.postDelayed({ refreshTracks(); remember() }, 300) }

    private fun refreshTracks() {
        val e = _engine.value ?: return
        _audio.value = e.audioTracks(); _subtitles.value = e.subtitleTracks()
        _chapters.value = e.chapters(); _qualities.value = e.videoQualities()
        if (appliedPreferredTracks || (_audio.value.isEmpty() && _subtitles.value.isEmpty())) return
        appliedPreferredTracks = true
        e.applyTuning(_tuning.value)
        if (_audioDelay.value != 0L) e.setAudioDelay(_audioDelay.value)
        if (_subtitleDelay.value != 0L) e.setSubtitleDelay(_subtitleDelay.value)
        // What was chosen for this title last time beats the general language settings.
        remembered?.let { r ->
            val al = r[0]; val sl = r[1]
            if (al.isNotBlank()) _audio.value.firstOrNull { it.language?.startsWith(al, true) == true }?.let { e.selectAudio(it.id) }
            if (sl == "off") e.selectSubtitle(null) else if (sl.isNotBlank()) _subtitles.value.firstOrNull { it.language?.startsWith(sl, true) == true }?.let { e.selectSubtitle(it.id) }
            return
        }
        val al = settings.audioLanguage.value; val sl = settings.subtitleLanguage.value
        if (al.isNotBlank()) _audio.value.firstOrNull { it.language?.startsWith(al, true) == true }?.let { e.selectAudio(it.id) }
        val wantSubs = when (settings.subtitleMode.value) {
            "ON" -> true
            "OFF" -> false
            else -> al.isNotBlank() && _audio.value.firstOrNull { it.selected }?.language?.startsWith(al, true) == false       // AUTO: when the sound is not in the preferred language
        }
        if (!wantSubs) e.selectSubtitle(null)
        else (_subtitles.value.firstOrNull { sl.isNotBlank() && it.language?.startsWith(sl, true) == true } ?: _subtitles.value.firstOrNull())?.let { e.selectSubtitle(it.id) }
    }

    private fun startProgressTicker(item: Playable) {
        progressJob?.cancel()
        if (!item.tracksProgress) return
        progressJob = scope.launch { while (true) { delay(10_000); saveProgress() } }
    }

    /** Remembers where a movie or episode stopped (when the Settings allow it). */
    fun saveProgress() {
        val item = _current.value ?: return
        if (!item.tracksProgress || !settings.rememberPosition.value) return
        val pos = positionMs; val dur = durationMs
        // A checkpoint is only replaced by a position that is real: the picture has played in this session, the numbers make sense, and
        // a position far below where we resumed (a seek that failed and restarted from zero) is not allowed to erase the earlier one.
        if (!sessionVerified || dur <= 0 || pos < 0 || pos > dur + 5_000) return
        if (!userSeeked && startPositionMs > 30_000 && pos < startPositionMs - 15_000) return
        val session = sessionId
        scope.launch { if (session == sessionId) onProgress(item, pos, dur) }
    }

    fun stop() {
        stopRecording()
        sleepJob?.cancel(); _sleepEndsAt.value = 0
        minimized = false; backgroundHold = false; _audioOnly.value = false
        saveProgress()
        job?.cancel(); progressJob?.cancel()
        _current.value?.let { closedAt[it.sourceId] = System.currentTimeMillis() }
        _engine.value?.stop()
        _current.value = null; _state.value = PlaybackState.Idle
    }

    // ---- Lifecycle: Home button, TV sleep, HDMI changes ----
    private var backgroundJob: Job? = null
    private var restoreItem: Playable? = null
    private var restorePosition = 0L
    private var pausedByLifecycle = false

    /** The app left the screen. The position is saved; a movie pauses; a live stream is closed after a short grace so it does not hold the provider's connection. */
    fun onBackground() {
        val item = _current.value ?: return
        saveProgress()
        backgroundJob?.cancel()
        // With background audio on, whatever is playing carries on as sound only (the notification and lock screen then have the controls).
        val st = _state.value
        if (settings.backgroundAudio.value && (st == PlaybackState.Playing || st == PlaybackState.Buffering || st == PlaybackState.Resolving || st is PlaybackState.Retrying)) { backgroundHold = true; applyAudioOnly(); return }
        if (item.isLive) {
            backgroundJob = scope.launch {
                delay(20_000)
                restoreItem = item; restorePosition = 0
                closedAt[item.sourceId] = System.currentTimeMillis()
                job?.cancel(); progressJob?.cancel(); _engine.value?.stop(); _state.value = PlaybackState.Idle
            }
        } else if (_engine.value?.isPlaying == true) { _engine.value?.pause(); pausedByLifecycle = true }
    }

    /** The app is back: a live channel that was closed starts again; a movie that was paused by leaving carries on from where it was. */
    fun onForeground() {
        backgroundJob?.cancel()
        if (backgroundHold) { backgroundHold = false; applyAudioOnly() }
        val item = restoreItem
        if (item != null) { restoreItem = null; play(item, restorePosition); return }
        if (pausedByLifecycle) { pausedByLifecycle = false; _engine.value?.play() }
    }

    fun release() {
        stop()
        if (networkCallbackRegistered) { networkCallbackRegistered = false; runCatching { connectivity.unregisterNetworkCallback(networkCallback) } }
        engines.values.forEach { it.release() }; engines.clear()
        scope.coroutineContext[Job]?.cancel()
    }

    private fun isOnline(): Boolean {
        val n = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(n)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }
}


/** The rules for the Skip intro button, kept apart from the player so they can be tested. */
object IntroSkip {
    const val DEFAULT_MS = 90_000L
    /** The opening is only offered near the start of an episode. */
    const val WINDOW_MS = 5 * 60_000L
    private const val MIN_JUMP_MS = 25_000L

    /** Where to jump to from [positionMs], or null when the button should not show: too early (the first seconds), or past the opening. */
    fun target(positionMs: Long, learnedMs: Long?): Long? {
        val end = learnedMs ?: DEFAULT_MS
        return if (positionMs in 3_000 until (end - 2_000).coerceAtLeast(3_001) && positionMs < WINDOW_MS) end else null
    }

    /** True for a forward jump of at least 25 seconds that starts and ends inside the first five minutes. */
    fun isOpeningSkip(fromMs: Long, toMs: Long) = fromMs < WINDOW_MS && toMs <= WINDOW_MS && toMs - fromMs >= MIN_JUMP_MS
}

/** The recap at the start of an episode and the credits at its end: found from chapter titles when the file has them, and for credits also learned from the person's own jump near the end. */
object EpisodeMarks {
    const val RECAP_WINDOW_MS = 8 * 60_000L
    const val CREDITS_WINDOW_MS = 12 * 60_000L
    const val SHORTEST_MS = 10 * 60_000L
    private val recapWords = listOf("recap", "previously", "previous", "last time", "story so far")
    private val creditsWords = listOf("credit", "outro", "ending", "end card")

    private fun named(chapters: List<Chapter>, words: List<String>) = chapters.indexOfFirst { c -> c.title.lowercase().let { t -> words.any { it in t } } }

    /** Where the recap ends, while [positionMs] is inside it; null otherwise. */
    fun recapEnd(chapters: List<Chapter>, positionMs: Long, durationMs: Long): Long? {
        val i = named(chapters, recapWords).takeIf { it >= 0 && chapters[it].startMs < RECAP_WINDOW_MS } ?: return null
        val end = if (i + 1 < chapters.size) chapters[i + 1].startMs else minOf(chapters[i].startMs + 90_000, if (durationMs > 0) durationMs else Long.MAX_VALUE)
        return if (positionMs >= chapters[i].startMs - 1_000 && positionMs < end - 3_000) end else null
    }

    /** Where the credits start: a chapter called credits, else the distance from the end that an earlier skip in this series taught the app. */
    fun creditsStart(chapters: List<Chapter>, durationMs: Long, learnedLeadMs: Long?): Long? {
        if (durationMs < SHORTEST_MS) return null
        val i = named(chapters, creditsWords)
        if (i >= 0 && chapters[i].startMs > durationMs / 2) return chapters[i].startMs
        return learnedLeadMs?.takeIf { it > 0 }?.let { durationMs - it }
    }

    /** A jump (or a press of Next Episode) from the last twelve minutes to the last twenty seconds is the person skipping the credits. */
    fun isCreditsSkip(fromMs: Long, toMs: Long, durationMs: Long) =
        durationMs >= SHORTEST_MS && durationMs - fromMs <= CREDITS_WINDOW_MS && durationMs - fromMs >= 20_000 && durationMs - toMs <= 20_000
}

/** Where a saved copy of a movie or episode is found, when there is one (set by the app, which keeps the downloads). */
object LocalFiles {
    @Volatile var finder: ((String) -> String?)? = null
    fun find(itemId: String): String? = finder?.invoke(itemId)
}
