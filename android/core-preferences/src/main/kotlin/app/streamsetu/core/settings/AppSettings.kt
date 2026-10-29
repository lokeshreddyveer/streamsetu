package app.streamsetu.core.settings

import android.content.Context
import app.streamsetu.core.playback.BufferingMode
import app.streamsetu.core.playback.EnginePreference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The Mac's `AppSettings`: every control saves the moment it changes and survives restarts. Read by the player and the Settings screens. */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private fun <T> flow(initial: T) = MutableStateFlow(initial)

    private val _engine = flow(EnginePreference.from(prefs.getString("engine", null)))
    val enginePreference: StateFlow<EnginePreference> = _engine
    fun setEngine(v: EnginePreference) { prefs.edit().putString("engine", v.name).apply(); _engine.value = v }

    private val _buffering = flow(BufferingMode.from(prefs.getString("buffering", null)))
    val bufferingMode: StateFlow<BufferingMode> = _buffering
    fun setBuffering(v: BufferingMode) { prefs.edit().putString("buffering", v.name).apply(); _buffering.value = v }

    private val _audioLang = flow(prefs.getString("audioLang", "") ?: "")
    val audioLanguage: StateFlow<String> = _audioLang
    fun setAudioLanguage(v: String) { prefs.edit().putString("audioLang", v).apply(); _audioLang.value = v }

    private val _subLang = flow(prefs.getString("subLang", "") ?: "")
    val subtitleLanguage: StateFlow<String> = _subLang
    fun setSubtitleLanguage(v: String) { prefs.edit().putString("subLang", v).apply(); _subLang.value = v }

    private val _subsDefault = flow(prefs.getBoolean("subsDefault", false))
    val subtitlesByDefault: StateFlow<Boolean> = _subsDefault
    fun setSubtitlesByDefault(v: Boolean) { prefs.edit().putBoolean("subsDefault", v).apply(); _subsDefault.value = v }

    private val _bestFirst = flow(prefs.getBoolean("bestVersionFirst", true))
    /** A film that exists in several qualities or folders starts with the best copy; if it does not play, the next best is tried. */
    val bestVersionFirst: StateFlow<Boolean> = _bestFirst
    fun setBestVersionFirst(v: Boolean) { prefs.edit().putBoolean("bestVersionFirst", v).apply(); _bestFirst.value = v }

    private val _playNext = flow(prefs.getBoolean("playNext", true))
    val playNextAutomatically: StateFlow<Boolean> = _playNext
    fun setPlayNext(v: Boolean) { prefs.edit().putBoolean("playNext", v).apply(); _playNext.value = v }

    private val _remember = flow(prefs.getBoolean("remember", true))
    val rememberPosition: StateFlow<Boolean> = _remember
    fun setRememberPosition(v: Boolean) { prefs.edit().putBoolean("remember", v).apply(); _remember.value = v }

    private val _resume = flow(prefs.getBoolean("resume", true))
    val resumeAutomatically: StateFlow<Boolean> = _resume
    fun setResumeAutomatically(v: Boolean) { prefs.edit().putBoolean("resume", v).apply(); _resume.value = v }

    private val _info = flow(prefs.getBoolean("streamInfo", false))
    val showStreamInfo: StateFlow<Boolean> = _info
    fun setShowStreamInfo(v: Boolean) { prefs.edit().putBoolean("streamInfo", v).apply(); _info.value = v }

    // ---- Buffering: separately for Live TV and for movies and episodes ----
    private val _liveBuf = flow(BufferingMode.from(prefs.getString("bufferLive", prefs.getString("buffering", null))).let { if (it == BufferingMode.STANDARD) BufferingMode.AUTOMATIC else it })
    val liveBuffering: StateFlow<BufferingMode> = _liveBuf
    fun setLiveBuffering(v: BufferingMode) { prefs.edit().putString("bufferLive", v.name).apply(); _liveBuf.value = v }
    private val _vodBuf = flow(BufferingMode.from(prefs.getString("bufferVod", null)).let { if (it == BufferingMode.LOW_LATENCY || it == BufferingMode.STANDARD) BufferingMode.AUTOMATIC else it })
    val vodBuffering: StateFlow<BufferingMode> = _vodBuf
    fun setVodBuffering(v: BufferingMode) { prefs.edit().putString("bufferVod", v.name).apply(); _vodBuf.value = v }

    // ---- Playback behaviour ----
    private val _seek = flow(prefs.getInt("seekSecs", 10))
    val seekSeconds: StateFlow<Int> = _seek
    fun setSeekSeconds(v: Int) { prefs.edit().putInt("seekSecs", v).apply(); _seek.value = v }
    private val _autoRetry = flow(prefs.getBoolean("autoRetry", true))
    /** On: a failing stream is retried by itself a few times. Off: it stops at once and waits for the person. */
    val automaticRetry: StateFlow<Boolean> = _autoRetry
    fun setAutomaticRetry(v: Boolean) { prefs.edit().putBoolean("autoRetry", v).apply(); _autoRetry.value = v }
    private val _stall = flow(prefs.getString("stall", "NORMAL") ?: "NORMAL")
    /** How long a stream may sit loading before it counts as failed: SHORT, NORMAL or LONG. */
    val stallPatience: StateFlow<String> = _stall
    fun setStallPatience(v: String) { prefs.edit().putString("stall", v).apply(); _stall.value = v }
    fun engineFor(sourceId: String): EnginePreference? = prefs.getString("engine.$sourceId", null)?.let { n -> EnginePreference.entries.firstOrNull { it.name == n } }
    fun setEngineFor(sourceId: String, v: EnginePreference?) { prefs.edit().apply { if (v == null) remove("engine.$sourceId") else putString("engine.$sourceId", v.name) }.apply() }
    /** The engine chosen for one kind of viewing ("LIVE", "MOVIES" or "CATCHUP"); null means the app-wide setting. A connection's own choice still wins. */
    fun engineForKind(kind: String): EnginePreference? = prefs.getString("engine.kind.$kind", null)?.let { n -> EnginePreference.entries.firstOrNull { it.name == n } }
    fun setEngineForKind(kind: String, v: EnginePreference?) { prefs.edit().apply { if (v == null) remove("engine.kind.$kind") else putString("engine.kind.$kind", v.name) }.apply() }
    fun liveBufferFor(sourceId: String): BufferingMode? = prefs.getString("bufferLive.$sourceId", null)?.let { n -> BufferingMode.entries.firstOrNull { it.name == n } }
    fun setLiveBufferFor(sourceId: String, v: BufferingMode?) { prefs.edit().apply { if (v == null) remove("bufferLive.$sourceId") else putString("bufferLive.$sourceId", v.name) }.apply() }

    private val _confirmExit = flow(prefs.getBoolean("confirmExit", true))
    /** On: Back in the player asks whether to keep watching or leave. */
    val confirmLeavingPlayer: StateFlow<Boolean> = _confirmExit
    fun setConfirmLeavingPlayer(v: Boolean) { prefs.edit().putBoolean("confirmExit", v).apply(); _confirmExit.value = v }

    // ---- Video ----
    private val _aspect = flow(prefs.getString("aspect", "FIT") ?: "FIT")
    val defaultAspect: StateFlow<String> = _aspect
    fun setDefaultAspect(v: String) { prefs.edit().putString("aspect", v).apply(); _aspect.value = v }
    private val _decoderFallback = flow(prefs.getBoolean("decoderFallback", true))
    val decoderFallback: StateFlow<Boolean> = _decoderFallback
    fun setDecoderFallback(v: Boolean) { prefs.edit().putBoolean("decoderFallback", v).apply(); _decoderFallback.value = v }

    // ---- Audio ----
    private val _passthrough = flow(prefs.getBoolean("passthrough", true))
    /** On: surround sound is passed to the TV or receiver when it supports it. Off: the device decodes to stereo. */
    val surroundPassthrough: StateFlow<Boolean> = _passthrough
    fun setSurroundPassthrough(v: Boolean) { prefs.edit().putBoolean("passthrough", v).apply(); _passthrough.value = v }
    private val _rememberAudio = flow(prefs.getBoolean("rememberAudio", true))
    val rememberAudioChoice: StateFlow<Boolean> = _rememberAudio
    fun setRememberAudioChoice(v: Boolean) { prefs.edit().putBoolean("rememberAudio", v).apply(); _rememberAudio.value = v }

    // ---- Subtitles ----
    private val _subMode = flow(prefs.getString("subMode", if (prefs.getBoolean("subsDefault", false)) "ON" else "AUTO") ?: "AUTO")
    /** OFF, AUTO (on when the audio is not in the preferred language) or ON. */
    val subtitleMode: StateFlow<String> = _subMode
    fun setSubtitleMode(v: String) { prefs.edit().putString("subMode", v).apply(); _subMode.value = v }
    private val _subSize = flow(prefs.getString("subSize", "MEDIUM") ?: "MEDIUM")
    val subtitleSize: StateFlow<String> = _subSize
    fun setSubtitleSize(v: String) { prefs.edit().putString("subSize", v).apply(); _subSize.value = v }
    private val _subBg = flow(prefs.getString("subBg", "NONE") ?: "NONE")
    val subtitleBackground: StateFlow<String> = _subBg
    fun setSubtitleBackground(v: String) { prefs.edit().putString("subBg", v).apply(); _subBg.value = v }
    private val _subOutline = flow(prefs.getBoolean("subOutline", true))
    val subtitleOutline: StateFlow<Boolean> = _subOutline
    fun setSubtitleOutline(v: Boolean) { prefs.edit().putBoolean("subOutline", v).apply(); _subOutline.value = v }

    private val _autoSubs = flow(prefs.getBoolean("autoSubtitles", false))
    /** Fetches a subtitle from OpenSubtitles by itself when a film or episode has none in the chosen language. Needs the free account set up under Subtitles. */
    val autoSubtitles: StateFlow<Boolean> = _autoSubs
    fun setAutoSubtitles(v: Boolean) { prefs.edit().putBoolean("autoSubtitles", v).apply(); _autoSubs.value = v }

    // ---- The queue of titles lined up to play ----
    fun queueRaw(): String = prefs.getString("watchQueue", "") ?: ""
    fun setQueueRaw(v: String) { prefs.edit().putString("watchQueue", v).apply() }

    // ---- Frame rate ----
    private val _matchFps = flow(prefs.getBoolean("matchFrameRate", false))
    /** Switches the TV to the refresh rate that suits the video (24, 25, 30, 50 or 60 per second). Off by default: the screen goes dark for a moment while it switches. */
    val matchFrameRate: StateFlow<Boolean> = _matchFps
    fun setMatchFrameRate(v: Boolean) { prefs.edit().putBoolean("matchFrameRate", v).apply(); _matchFps.value = v }

    // ---- Live TV ----
    private val _invert = flow(prefs.getBoolean("invertChannelKeys", false))
    /** Off: Up is the next channel. On: Up is the previous one. */
    val invertChannelKeys: StateFlow<Boolean> = _invert
    fun setInvertChannelKeys(v: Boolean) { prefs.edit().putBoolean("invertChannelKeys", v).apply(); _invert.value = v }
    private val _chNumbers = flow(prefs.getBoolean("chNumbers", true))
    val showChannelNumbers: StateFlow<Boolean> = _chNumbers
    fun setShowChannelNumbers(v: Boolean) { prefs.edit().putBoolean("chNumbers", v).apply(); _chNumbers.value = v }
    private val _resumeLast = flow(prefs.getBoolean("resumeLastChannel", false))
    val resumeLastChannel: StateFlow<Boolean> = _resumeLast
    fun setResumeLastChannel(v: Boolean) { prefs.edit().putBoolean("resumeLastChannel", v).apply(); _resumeLast.value = v }
    var lastChannelId: String?
        get() = prefs.getString("lastChannel", null)
        set(v) { prefs.edit().putString("lastChannel", v).apply() }

    // ---- Catalog refresh ----
    private val _bgHours = flow(prefs.getInt("bgSyncHours", 0))
    /** 0 = only when asked; otherwise how many hours between background reads. */
    val backgroundSyncHours: StateFlow<Int> = _bgHours
    fun setBackgroundSyncHours(v: Int) { prefs.edit().putInt("bgSyncHours", v).apply(); _bgHours.value = v }

    private val _catchupZone = flow(prefs.getString("catchupZone", "UTC") ?: "UTC")
    /** The time zone a provider reads catch-up start times in: UTC or this device's. */
    val catchupZone: StateFlow<String> = _catchupZone
    fun setCatchupZone(v: String) { prefs.edit().putString("catchupZone", v).apply(); _catchupZone.value = v }

    private val _refreshOnStart = flow(prefs.getBoolean("refreshOnStart", false))
    /** On: every connection and its guide are read again when the app opens (never while something is playing). */
    val refreshOnStart: StateFlow<Boolean> = _refreshOnStart
    fun setRefreshOnStart(v: Boolean) { prefs.edit().putBoolean("refreshOnStart", v).apply(); _refreshOnStart.value = v }

    // ---- Updates ----
    private val _autoUpdates = flow(prefs.getBoolean("autoUpdateCheck", true))
    /** On: when the app opens (and nothing is playing) it asks GitHub whether a newer release exists. It never installs anything by itself. */
    val autoUpdateCheck: StateFlow<Boolean> = _autoUpdates
    fun setAutoUpdateCheck(v: Boolean) { prefs.edit().putBoolean("autoUpdateCheck", v).apply(); _autoUpdates.value = v }
    var lastUpdateCheckAt: Long
        get() = prefs.getLong("updateCheckedAt", 0L)
        set(v) { prefs.edit().putLong("updateCheckedAt", v).apply() }
    /** A version the person chose to skip: it is not offered again by the prompt (Settings still shows it). */
    var skippedUpdate: String
        get() = prefs.getString("updateSkipped", "").orEmpty()
        set(v) { prefs.edit().putString("updateSkipped", v).apply() }

    // ---- Background audio and backups ----
    private val isTelevision = context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) || context.packageManager.hasSystemFeature("amazon.hardware.fire_tv")
    private val _bgAudio = flow(prefs.getBoolean("bgAudio", !isTelevision))
    /** On (the default on a phone): leaving the app keeps the sound playing, with controls on the lock screen and in the notification shade. */
    val backgroundAudio: StateFlow<Boolean> = _bgAudio
    fun setBackgroundAudio(v: Boolean) { prefs.edit().putBoolean("bgAudio", v).apply(); _bgAudio.value = v }
    private val _autoBackup = flow(prefs.getBoolean("autoBackup", true))
    /** On: a backup is saved about once a week and the last five are kept. */
    val automaticBackups: StateFlow<Boolean> = _autoBackup
    fun setAutomaticBackups(v: Boolean) { prefs.edit().putBoolean("autoBackup", v).apply(); _autoBackup.value = v }

    // ---- App DNS: encrypted DNS for the app's own traffic (see core-network AppDns). Off by default; the provider is remembered while it is off. ----
    private val _dnsOn = flow(prefs.getBoolean("dnsOn", false))
    val appDnsEnabled: StateFlow<Boolean> = _dnsOn
    fun setAppDnsEnabled(v: Boolean) { prefs.edit().putBoolean("dnsOn", v).apply(); _dnsOn.value = v }
    private val _dnsProvider = flow(prefs.getString("dnsProvider", "CLOUDFLARE") ?: "CLOUDFLARE")
    val appDnsProvider: StateFlow<String> = _dnsProvider
    fun setAppDnsProvider(v: String) { prefs.edit().putString("dnsProvider", v).apply(); _dnsProvider.value = v }
    private val _dnsName = flow(prefs.getString("dnsName", "") ?: "")
    val appDnsName: StateFlow<String> = _dnsName
    fun setAppDnsName(v: String) { prefs.edit().putString("dnsName", v).apply(); _dnsName.value = v }
    private val _dnsUrl = flow(prefs.getString("dnsUrl", "") ?: "")
    val appDnsUrl: StateFlow<String> = _dnsUrl
    fun setAppDnsUrl(v: String) { prefs.edit().putString("dnsUrl", v.trim()).apply(); _dnsUrl.value = v.trim() }
    private val _dnsBootstrap = flow(prefs.getString("dnsBootstrap", "") ?: "")
    /** Comma-separated IP addresses of a custom resolver (optional). */
    val appDnsBootstrap: StateFlow<String> = _dnsBootstrap
    fun setAppDnsBootstrap(v: String) { prefs.edit().putString("dnsBootstrap", v).apply(); _dnsBootstrap.value = v }
    private val _dnsLocal = flow(prefs.getBoolean("dnsLocal", true))
    val appDnsLocalUsesSystem: StateFlow<Boolean> = _dnsLocal
    fun setAppDnsLocalUsesSystem(v: Boolean) { prefs.edit().putBoolean("dnsLocal", v).apply(); _dnsLocal.value = v }

    // ---- Network proxy ----
    private val _proxyKind = flow(prefs.getString("proxyKind", "NONE") ?: "NONE")
    /** NONE, HTTP or SOCKS. Streams and playlist reads go through it; addresses on the local network never do. */
    val proxyKind: StateFlow<String> = _proxyKind
    private val _proxyHost = flow(prefs.getString("proxyHost", "") ?: "")
    val proxyHost: StateFlow<String> = _proxyHost
    private val _proxyPort = flow(prefs.getInt("proxyPort", 0))
    val proxyPort: StateFlow<Int> = _proxyPort
    fun setProxyKind(v: String) { prefs.edit().putString("proxyKind", v).apply(); _proxyKind.value = v }
    fun setProxyHost(v: String) { prefs.edit().putString("proxyHost", v.trim()).apply(); _proxyHost.value = v.trim() }
    fun setProxyPort(v: Int) { prefs.edit().putInt("proxyPort", v).apply(); _proxyPort.value = v }
    /** "http://host:port" for MPV, which can only use an HTTP proxy; null when none is set or it is a SOCKS one. */
    val mpvProxy: String? get() = if (_proxyKind.value == "HTTP" && _proxyHost.value.isNotBlank() && _proxyPort.value in 1..65535) "http://${_proxyHost.value}:${_proxyPort.value}" else null

    // ---- Folders and privacy ----
    private val _dwell = flow(prefs.getBoolean("folderDwell", true))
    /** On: resting on a folder opens it after a moment. Off: it opens only when OK is pressed. */
    val foldersOpenOnFocus: StateFlow<Boolean> = _dwell
    fun setFoldersOpenOnFocus(v: Boolean) { prefs.edit().putBoolean("folderDwell", v).apply(); _dwell.value = v }
    private val _relock = flow(prefs.getString("relock", "LEAVE") ?: "LEAVE")
    /** When unlocked folders lock again: LEAVE (when the library is closed), TEN (after ten minutes), SESSION (only when the app closes). */
    val relockPolicy: StateFlow<String> = _relock
    fun setRelockPolicy(v: String) { prefs.edit().putString("relock", v).apply(); _relock.value = v }
    private val _textScale = flow(prefs.getInt("textScale", 100))
    val textScalePercent: StateFlow<Int> = _textScale
    fun setTextScalePercent(v: Int) { prefs.edit().putInt("textScale", v).apply(); _textScale.value = v }

    /** Puts every preference above back to its default. Content, connections, favourites and progress are not touched. */
    fun resetPlayerPreferences() {
        prefs.edit().clear().apply()
        setEngine(EnginePreference.AUTOMATIC); setLiveBuffering(BufferingMode.AUTOMATIC); setVodBuffering(BufferingMode.AUTOMATIC); setSeekSeconds(10); setAutomaticRetry(true); setStallPatience("NORMAL")
        setDefaultAspect("FIT"); setDecoderFallback(true); setSurroundPassthrough(true); setRememberAudioChoice(true); setSubtitleMode("AUTO"); setSubtitleSize("MEDIUM"); setSubtitleBackground("NONE"); setSubtitleOutline(true)
        setAudioLanguage(""); setSubtitleLanguage(""); setPlayNext(true); setRememberPosition(true); setResumeAutomatically(true); setShowStreamInfo(false)
    }
}
