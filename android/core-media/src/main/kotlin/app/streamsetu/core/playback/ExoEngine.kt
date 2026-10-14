package app.streamsetu.core.playback

import android.content.Context
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.streamsetu.core.net.Http

/** Android's own player: HLS, MP4, DASH and MPEG-TS, with hardware decoding. */
class ExoEngine(context: Context) : PlayerEngine {
    private val appContext = context.applicationContext
    override val kind = EngineKind.EXOPLAYER
    override var onEvent: (EngineEvent) -> Unit = {}

    private var player: ExoPlayer? = null
    private var builtFor: List<Any?>? = null
    private var userAgent: String? = null
    private var options = EngineOptions()
    private var dropped = 0L
    private var decoderName = ""
    private var viewRef: PlayerView? = null
    private var currentHeaders: Map<String, String> = emptyMap()

    private fun ensurePlayer(mode: BufferingMode): ExoPlayer {
        val key = listOf(mode, options.decoderFallback, options.passthrough, userAgent, currentHeaders)
        if (player != null && builtFor == key) return player!!
        player?.release()
        val factory = OkHttpDataSource.Factory(Http.client).setUserAgent(userAgent ?: Http.USER_AGENT).setDefaultRequestProperties(currentHeaders.filterKeys { !it.equals("User-Agent", true) })
        // IPTV transport streams are often cut mid-frame and start between keyframes: these flags let ExoPlayer start and recover on them.
        val extractors = DefaultExtractorsFactory()
            .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS)
            .setConstantBitrateSeekingEnabled(true)
        // A decoder that fails on one stream hands over to another decoder instead of failing the stream.
        val passthrough = options.passthrough
        val renderers = object : DefaultRenderersFactory(appContext) {
            // With passthrough off the sound is decoded on this device to stereo instead of being sent as-is to a TV or receiver.
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): androidx.media3.exoplayer.audio.AudioSink? =
                if (passthrough) super.buildAudioSink(context, enableFloatOutput, enableAudioTrackPlaybackParams)
                else androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(context).setAudioCapabilities(androidx.media3.exoplayer.audio.AudioCapabilities.DEFAULT_AUDIO_CAPABILITIES).setEnableFloatOutput(enableFloatOutput).setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams).build()
        }.setEnableDecoderFallback(options.decoderFallback).setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
        val p = ExoPlayer.Builder(appContext, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(androidx.media3.datasource.DefaultDataSource.Factory(appContext, factory), extractors).setLiveTargetOffsetMs(mode.liveOffsetMs))
            .setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(mode.minMs, mode.maxMs, mode.startMs, mode.rebufferMs).setPrioritizeTimeOverSizeThresholds(true).setBackBuffer(30_000, true).build())
            .setHandleAudioBecomingNoisy(true)
            .build()
        dropped = 0
        p.addAnalyticsListener(object : androidx.media3.exoplayer.analytics.AnalyticsListener {
            override fun onDroppedVideoFrames(eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) { dropped += droppedFrames }
            override fun onVideoDecoderInitialized(eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) { this@ExoEngine.decoderName = decoderName }
        })
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_BUFFERING -> onEvent(EngineEvent.Buffering)
                    Player.STATE_READY -> onEvent(EngineEvent.Ready(p.playWhenReady))
                    Player.STATE_ENDED -> onEvent(EngineEvent.Ended)
                }
            }
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) { if (p.playbackState == Player.STATE_READY) onEvent(EngineEvent.Ready(playWhenReady)) }
            override fun onPlayerError(error: PlaybackException) {
                // A live stream that fell behind its window just jumps to the live edge; that is not a failure.
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) { p.seekToDefaultPosition(); p.prepare(); return }
                onEvent(EngineEvent.Error(classify(error)))
            }
            override fun onTracksChanged(tracks: Tracks) { onEvent(EngineEvent.TracksChanged) }
        })
        player = p; builtFor = key
        viewRef?.player = p
        return p
    }

    override fun view(context: Context): View {
        viewRef?.let { return it }
        val v = PlayerView(context).apply { useController = false; resizeMode = resizeFor(aspect); keepScreenOn = true; player = this@ExoEngine.player }
        viewRef = v
        applySubtitleStyle()
        return v
    }

    private fun applySubtitleStyle() {
        val st = options.subtitles
        viewRef?.subtitleView?.apply {
            setFractionalTextSize(androidx.media3.ui.SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * st.scale)
            setStyle(androidx.media3.ui.CaptionStyleCompat(android.graphics.Color.WHITE, if (st.darkBackground) 0xB3000000.toInt() else android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT,
                if (st.outline) androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_OUTLINE else androidx.media3.ui.CaptionStyleCompat.EDGE_TYPE_NONE, android.graphics.Color.BLACK, null))
        }
    }

    override fun load(request: EngineRequest) {
        options = request.options
        userAgent = request.headers["User-Agent"]
        currentHeaders = request.headers.filterKeys { !it.equals("User-Agent", true) }
        val p = ensurePlayer(request.buffering)
        applySubtitleStyle()
        p.setMediaItem(MediaItem.fromUri(request.url), if (request.startMs > 5_000) request.startMs else C.TIME_UNSET)
        p.prepare()
        p.playWhenReady = true
    }

    private var aspect = AspectMode.FIT
    private fun resizeFor(m: AspectMode) = when (m) { AspectMode.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT; AspectMode.FILL -> AspectRatioFrameLayout.RESIZE_MODE_FILL; AspectMode.ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM }
    override fun setAspect(mode: AspectMode) { aspect = mode; viewRef?.resizeMode = resizeFor(mode) }
    override fun setSpeed(speed: Float) { player?.setPlaybackSpeed(speed) }

    override fun setVideoEnabled(enabled: Boolean) {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, !enabled).build()
    }

    /** ExoPlayer takes a subtitle as part of the media item, so the stream is set up again at the same place. */
    override fun addSubtitle(address: String, label: String): Boolean {
        val p = player ?: return false
        val current = p.currentMediaItem ?: return false
        val mime = when (address.substringBefore('?').substringAfterLast('.').lowercase()) {
            "vtt" -> androidx.media3.common.MimeTypes.TEXT_VTT
            "ass", "ssa" -> androidx.media3.common.MimeTypes.TEXT_SSA
            "ttml", "xml", "dfxp" -> androidx.media3.common.MimeTypes.APPLICATION_TTML
            else -> androidx.media3.common.MimeTypes.APPLICATION_SUBRIP
        }
        val sub = MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(address)).setMimeType(mime).setLabel(label).setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build()
        val item = current.buildUpon().setSubtitleConfigurations(current.localConfiguration?.subtitleConfigurations.orEmpty() + sub).build()
        val at = p.currentPosition
        p.setMediaItem(item, at); p.prepare(); p.playWhenReady = true
        return true
    }

    override fun play() { player?.play() }
    override fun pause() { player?.pause() }
    override fun seekTo(positionMs: Long) { player?.seekTo(positionMs) }
    override fun stop() { player?.stop(); player?.clearMediaItems() }
    override fun release() { player?.release(); player = null; viewRef?.player = null }
    override val positionMs get() = player?.currentPosition ?: 0
    override val durationMs get() = player?.duration?.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0
    override val isPlaying get() = player?.isPlaying == true

    override fun audioTracks() = tracks(C.TRACK_TYPE_AUDIO)
    override fun subtitleTracks() = tracks(C.TRACK_TYPE_TEXT)

    private fun tracks(type: Int): List<TrackOption> {
        val p = player ?: return emptyList()
        return p.currentTracks.groups.filter { it.type == type }.flatMapIndexed { g, group ->
            (0 until group.length).filter { group.isTrackSupported(it) }.map { t ->
                val f = group.getTrackFormat(t)
                TrackOption("$g:$t", f.label ?: f.language?.let { java.util.Locale(it).displayLanguage } ?: "Track ${g + 1}", f.language, group.isTrackSelected(t))
            }
        }
    }

    override fun selectAudio(id: String?) = select(C.TRACK_TYPE_AUDIO, id)
    override fun selectSubtitle(id: String?) = select(C.TRACK_TYPE_TEXT, id)

    private fun select(type: Int, id: String?) {
        val p = player ?: return
        val b = p.trackSelectionParameters.buildUpon()
        if (id == null) b.setTrackTypeDisabled(type, true)
        else {
            val (g, t) = id.split(':').map { it.toInt() }
            val group = p.currentTracks.groups.filter { it.type == type }.getOrNull(g) ?: return
            b.setTrackTypeDisabled(type, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, t))
        }
        p.trackSelectionParameters = b.build()
    }

    override fun diagnostics(): Map<String, String> {
        val p = player ?: return emptyMap()
        val v = p.videoFormat; val a = p.audioFormat
        return linkedMapOf(
            "Video" to (v?.let { listOfNotNull("${it.width}×${it.height}", it.sampleMimeType?.substringAfter('/'), it.frameRate.takeIf { f -> f > 0 }?.let { f -> "%.0f fps".format(f) }).joinToString(" · ") } ?: "none"),
            "Video bitrate" to (v?.bitrate?.takeIf { it > 0 }?.let { "${it / 1000} kbps" } ?: "unknown"),
            "Audio" to (a?.let { listOfNotNull(it.sampleMimeType?.substringAfter('/'), it.channelCount.takeIf { c -> c > 0 }?.let { c -> "$c ch" }, it.language).joinToString(" · ") } ?: "none"),
            "Decoder" to decoderName.ifBlank { "unknown" },
            "Buffered ahead" to "${((p.bufferedPosition - p.currentPosition).coerceAtLeast(0)) / 1000} s",
            "Dropped frames" to dropped.toString(),
        )
    }

    override fun streamInfo(): String {
        val p = player ?: return ""
        val v = p.videoFormat; val a = p.audioFormat
        return listOfNotNull(v?.let { "${it.width}×${it.height}" }, v?.sampleMimeType?.substringAfter('/'), a?.sampleMimeType?.substringAfter('/'),
            v?.bitrate?.takeIf { it > 0 }?.let { "${it / 1000} kbps" }).joinToString(" · ")
    }

    private fun classify(e: PlaybackException): PlaybackError {
        val http = generateSequence(e.cause) { it.cause }.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
        return when {
            http == 404 || http == 410 -> PlaybackError(ErrorKind.NOT_FOUND, "Not found", http)
            http == 401 -> PlaybackError(ErrorKind.AUTH, "Login refused", http)
            e.errorCode in PlaybackException.ERROR_CODE_DRM_UNSPECIFIED..PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED -> PlaybackError(ErrorKind.DRM, "Protected content")
            http == 403 || http == 429 || http == 458 || http == 503 || (http != null && http >= 500) -> PlaybackError(ErrorKind.SERVER_REFUSED, "Refused", http)
            e.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT || e.errorCode == PlaybackException.ERROR_CODE_TIMEOUT -> PlaybackError(ErrorKind.TIMEOUT, "Timed out")
            e.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> PlaybackError(ErrorKind.NO_NETWORK, "Network failed")
            e.errorCode in listOf(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED) -> PlaybackError(ErrorKind.FORMAT, "Unsupported")
            e.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED || e.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED -> PlaybackError(ErrorKind.DECODER, "Decoder failed")
            else -> PlaybackError(ErrorKind.UNKNOWN, e.message.orEmpty())
        }
    }
}
