package app.streamsetu.tv

import android.content.Context
import androidx.mediarouter.media.MediaControlIntent
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import app.streamsetu.core.model.Playable
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Tells the Cast framework to use Google's default media receiver, which plays web video addresses (HLS and MP4) on a Chromecast or a TV with Chromecast built in. */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder().setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID).build()
    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/** What Casting is doing now. */
sealed interface CastState {
    data object Idle : CastState
    data class Casting(val device: String, val playing: Boolean) : CastState
}

/**
 * Casting a stream to a Chromecast from a phone. A Chromecast fetches the stream itself, so only plain web addresses work: HLS and MP4 do, raw MPEG-TS often does not, and a
 * stream that needs special request headers cannot be cast. It is only ever started on a phone with Google Play services; on a Fire TV nothing here runs.
 */
class CastSupport(private val context: Context) {
    private val _state = MutableStateFlow<CastState>(CastState.Idle)
    val state: StateFlow<CastState> = _state.asStateFlow()
    private var cast: CastContext? = null
    private var pending: (() -> Unit)? = null
    private var hadSession = false

    /** True on a phone whose Google Play services can cast. */
    fun available(): Boolean = app.streamsetu.tv.ui.phone.isPhoneDevice(context) && runCatching { GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS }.getOrDefault(false)

    @Suppress("DEPRECATION")
    private fun context(): CastContext? {
        if (cast == null && available()) cast = runCatching { CastContext.getSharedInstance(context) }.getOrNull()?.also { cc ->
            cc.sessionManager.addSessionManagerListener(object : SessionManagerListener<CastSession> {
                override fun onSessionStarted(session: CastSession, sessionId: String) { hadSession = true; pending?.invoke(); pending = null; publish(session) }
                override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) { publish(session) }
                override fun onSessionEnded(session: CastSession, error: Int) { _state.value = CastState.Idle }
                override fun onSessionSuspended(session: CastSession, reason: Int) {}
                override fun onSessionStarting(session: CastSession) {}
                override fun onSessionStartFailed(session: CastSession, error: Int) { pending = null; _state.value = CastState.Idle }
                override fun onSessionEnding(session: CastSession) {}
                override fun onSessionResuming(session: CastSession, sessionId: String) {}
                override fun onSessionResumeFailed(session: CastSession, error: Int) { _state.value = CastState.Idle }
            }, CastSession::class.java)
        }
        return cast
    }

    private fun publish(session: CastSession) {
        val client = session.remoteMediaClient
        val name = session.castDevice?.friendlyName ?: "Chromecast"
        _state.value = CastState.Casting(name, client?.isPlaying == true)
        client?.registerCallback(object : com.google.android.gms.cast.framework.media.RemoteMediaClient.Callback() {
            override fun onStatusUpdated() { _state.value = CastState.Casting(name, client.isPlaying) }
        })
    }

    private fun selector() = MediaRouteSelector.Builder().addControlCategory(CastMediaControlIntent.categoryForCast(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)).addControlCategory(MediaControlIntent.CATEGORY_REMOTE_PLAYBACK).build()

    /** The devices that can be cast to right now, found while [scanning] is held open. */
    fun devices(): List<MediaRouter.RouteInfo> {
        context() ?: return emptyList()
        return MediaRouter.getInstance(context).routes.filter { it.matchesSelector(selector()) && !it.isDefaultOrBluetooth }
    }

    private val scanCallback = object : MediaRouter.Callback() {}
    /** While the device list is on screen the phone looks for devices actively. */
    fun startScanning() { if (context() != null) MediaRouter.getInstance(context).addCallback(selector(), scanCallback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY) }
    fun stopScanning() { runCatching { MediaRouter.getInstance(context).removeCallback(scanCallback) } }

    /** Connects to [route] and then sends [item] (at [positionMs]) to it. */
    fun castTo(route: MediaRouter.RouteInfo, item: Playable, url: String, positionMs: Long) {
        val cc = context() ?: return
        pending = { send(item, url, positionMs) }
        val current = cc.sessionManager.currentCastSession
        if (current != null && current.isConnected && current.castDevice?.deviceId == route.id.substringAfterLast(':')) { pending = null; send(item, url, positionMs) }
        else MediaRouter.getInstance(context).selectRoute(route)
    }

    private fun send(item: Playable, url: String, positionMs: Long) {
        val client = cast?.sessionManager?.currentCastSession?.remoteMediaClient ?: return
        val meta = MediaMetadata(if (item.isLive || item !is app.streamsetu.core.model.EpisodePlayable) MediaMetadata.MEDIA_TYPE_MOVIE else MediaMetadata.MEDIA_TYPE_TV_SHOW).apply {
            putString(MediaMetadata.KEY_TITLE, item.title)
            item.artworkUrl?.takeIf { it.isNotBlank() }?.let { addImage(com.google.android.gms.common.images.WebImage(android.net.Uri.parse(it))) }
        }
        val info = MediaInfo.Builder(url).setStreamType(if (item.isLive) MediaInfo.STREAM_TYPE_LIVE else MediaInfo.STREAM_TYPE_BUFFERED).setContentType(contentType(url)).setMetadata(meta).build()
        client.load(MediaLoadRequestData.Builder().setMediaInfo(info).setAutoplay(true).setCurrentTime(if (item.isLive) 0 else positionMs).build())
    }

    fun togglePause() { cast?.sessionManager?.currentCastSession?.remoteMediaClient?.togglePlayback() }

    /** Where the cast item is now, so playing on the phone can carry on from there. */
    fun positionMs(): Long = cast?.sessionManager?.currentCastSession?.remoteMediaClient?.approximateStreamPosition ?: 0

    fun stop() { cast?.sessionManager?.endCurrentSession(true); _state.value = CastState.Idle }

    companion object {
        fun contentType(url: String): String {
            val p = url.substringBefore('?').lowercase()
            return when { ".m3u8" in p -> "application/x-mpegURL"; p.endsWith(".mpd") -> "application/dash+xml"; p.endsWith(".mkv") || p.endsWith(".webm") -> "video/webm"; p.endsWith(".ts") -> "video/mp2t"; else -> "video/mp4" }
        }
    }
}
