package app.streamsetu.tv.sports.multiview

import android.content.Context
import android.view.View
import app.streamsetu.core.model.Channel
import app.streamsetu.core.playback.BufferingMode
import app.streamsetu.core.playback.EngineEvent
import app.streamsetu.core.playback.EngineOptions
import app.streamsetu.core.playback.EngineRequest
import app.streamsetu.core.playback.ErrorKind
import app.streamsetu.core.playback.ExoEngine
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.RealSportsAuthorization

/**
 * One tile's player: the same `ExoEngine` the single player and the existing Multi-View use. It plays through the shared HTTP client (App DNS, the proxy, redirect checks), with the stream
 * resolved and the headers supplied by the same resolver as Live TV. The tile's volume and captions are the engine's own.
 */
class RealTileEngine(context: Context, private val c: AppContainer) : TileEngine {
    private val engine = ExoEngine(context)
    private val appContext = context.applicationContext

    override var onEvent: (TileEvent) -> Unit = {}
        set(value) {
            field = value
            engine.onEvent = { ev ->
                when (ev) {
                    EngineEvent.Buffering -> value(TileEvent.Buffering)
                    is EngineEvent.Ready -> value(TileEvent.Ready)
                    EngineEvent.Ended -> value(TileEvent.Failed(TileFailure.OTHER, false))
                    is EngineEvent.Error -> value(TileEvent.Failed(failure(ev.error.kind), ev.error.kind == ErrorKind.DECODER))
                    EngineEvent.TracksChanged -> {}
                }
            }
        }

    override fun load(request: TileRequest) {
        // Hardware decoders only (never software beside other pictures), a cap on the picture size for the tile, and no passthrough sound for a tile that may be silent.
        val options = EngineOptions(decoderFallback = c.settings.decoderFallback.value, passthrough = false, softwareDecoding = false, maxVideoWidth = request.maxWidth, maxVideoHeight = request.maxHeight)
        engine.load(EngineRequest(request.url, request.headers, 0, true, BufferingMode.AUTOMATIC, options))
    }

    override fun setVolume(volume: Float) { engine.setVolume(volume) }
    override fun setCaptions(enabled: Boolean) { if (!enabled) engine.selectSubtitle(null) }
    override fun stop() { engine.stop() }
    override fun release() { engine.release() }
    override fun view(context: Context): View? = engine.view(context)

    private fun failure(k: ErrorKind) = when (k) {
        ErrorKind.NO_NETWORK -> TileFailure.NETWORK
        ErrorKind.SERVER_REFUSED, ErrorKind.AUTH -> TileFailure.REFUSED
        ErrorKind.NOT_FOUND -> TileFailure.NOT_FOUND
        ErrorKind.TIMEOUT -> TileFailure.TIMEOUT
        ErrorKind.FORMAT, ErrorKind.DRM -> TileFailure.FORMAT
        ErrorKind.DECODER -> TileFailure.NO_DECODER
        ErrorKind.UNKNOWN -> TileFailure.OTHER
    }
}

/** Multi-View's services, made from the application's own: the Live TV resolver for addresses and headers, and the same authorization checks Sports playback uses. */
class RealMultiviewDeps(private val context: Context, c: AppContainer) : RealSportsAuthorization(c), MultiviewDeps {
    override fun createEngine(): TileEngine? = runCatching { RealTileEngine(context, c) }.getOrNull()

    override suspend fun resolve(channel: Channel): TileRequest? {
        val url = c.resolver.resolve(channel.sourceId, channel.streamRef) ?: return null
        val ua = c.resolver.userAgent(channel.sourceId)
        return TileRequest(url, (if (ua != null) mapOf("User-Agent" to ua) else emptyMap()) + c.resolver.headers(channel.sourceId), 0, 0)
    }

    override fun nowMs(): Long = System.currentTimeMillis()
}

/** The Sports Multi-View as the application holds it: the capability, the builder's list and the tile session. One of each, so the list survives a visit to the player and back. */
class SportsMultiviewController(val capability: MultiviewCapability, val selection: SportsMultiviewSelection, val session: MultiviewSession) {
}
