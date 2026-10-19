package app.streamsetu.tv.ui.screens

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import app.streamsetu.core.model.Playable
import app.streamsetu.tv.AppContainer

/**
 * Hands the stream that is playing to another app on the device (VLC, MX Player, Just Player and the like), chosen from the system's list. Our own player is paused first, so a
 * provider that allows one connection is not asked twice. The address goes only to the app the person picks, and is never shown or stored.
 */
object ExternalPlayer {
    suspend fun open(c: AppContainer, context: Context, item: Playable) {
        val url = c.resolver.resolve(item.sourceId, item.streamRef)
        if (url == null || !url.startsWith("http")) {
            Toast.makeText(context, "This copy is on this device, so it cannot be handed to another app.", Toast.LENGTH_LONG).show(); return
        }
        val headers = (c.resolver.userAgent(item.sourceId)?.let { mapOf("User-Agent" to it) } ?: emptyMap()) + c.resolver.headers(item.sourceId)
        val type = if (url.substringBefore('?').endsWith(".m3u8", ignoreCase = true)) "application/x-mpegURL" else "video/*"
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(url), type).putExtra("title", item.title)
        // MX Player and several others read the request headers from this list: name, value, name, value.
        if (headers.isNotEmpty()) intent.putExtra("headers", headers.flatMap { listOf(it.key, it.value) }.toTypedArray())
        if (c.playback.state.value == app.streamsetu.core.playback.PlaybackState.Playing) c.playback.togglePause()
        val chooser = Intent.createChooser(intent, "Play in…")
        if (context !is android.app.Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(chooser) }.onFailure { Toast.makeText(context, "No other player app is installed.", Toast.LENGTH_LONG).show() }
    }
}
