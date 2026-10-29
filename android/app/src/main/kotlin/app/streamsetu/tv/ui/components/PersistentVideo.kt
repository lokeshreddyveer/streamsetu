package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens
import kotlin.math.roundToInt

/**
 * The one video surface of the TV app. It lives above the screens and below the player's controls, and is only ever given a new size and place: on the Live TV preview it sits on the
 * box that screen publishes ([Navigator.videoBounds]), under the fullscreen player it fills the window. Opening or closing the player therefore never detaches the picture from one
 * parent and attaches it to another, and the stream is never touched.
 */
@Composable
fun PersistentVideo(c: AppContainer, nav: Navigator) {
    val item by c.playback.current.collectAsStateWithLifecycle()
    val audioOnly by c.playback.audioOnly.collectAsStateWithLifecycle()
    val fullscreen = nav.top == Overlay.Player
    val bounds = nav.videoBounds
    val onLivePreview = nav.base == Base.Shell && nav.tab == Tab.LIVE && nav.top == null && bounds != null
    val shown = item != null && !audioOnly && (fullscreen || onLivePreview)
    if (!shown) return
    val ring = with(LocalDensity.current) { 3.dp.roundToPx() }          // the focus ring of the preview stays visible around the picture
    Box(Modifier.fillMaxSize()) {
        if (fullscreen || bounds == null) {
            Box(Modifier.fillMaxSize().background(Color.Black)) { EngineSurface(c, Modifier.fillMaxSize()) }
        } else {
            val d = LocalDensity.current
            val w = with(d) { (bounds.width.roundToInt() - ring * 2).coerceAtLeast(0).toDp() }
            val h = with(d) { (bounds.height.roundToInt() - ring * 2).coerceAtLeast(0).toDp() }
            Box(Modifier.offset { IntOffset(bounds.left.roundToInt() + ring, bounds.top.roundToInt() + ring) }.size(w, h).clip(RoundedCornerShape(13.dp)).background(Color.Black)) {
                EngineSurface(c, Modifier.fillMaxSize())
                LivePreviewStatus(c)
            }
        }
    }
}

/** What the Live TV preview says over the picture: the wait, a retry, a failure, or the LIVE tag. */
@Composable
private fun LivePreviewStatus(c: AppContainer) {
    val state by c.playback.state.collectAsStateWithLifecycle()
    val current by c.playback.current.collectAsStateWithLifecycle()
    val providerWait by c.playback.providerWaitMs.collectAsStateWithLifecycle()
    val live = current?.takeIf { it.isLive } as? ChannelPlayable
    Box(Modifier.fillMaxSize(), Alignment.Center) {
        when (val st = state) {
            PlaybackState.Resolving, PlaybackState.Buffering -> if (live != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { Spinner(); Label(loadingLabel(st, providerWait), Tokens.small, Tokens.textSecondary) }
            is PlaybackState.Retrying -> Label("Trying again…", Tokens.small, Tokens.textSecondary)
            is PlaybackState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Label("This channel did not play", Tokens.heading, Tokens.text, FontWeight.SemiBold); Label(st.error.message, Tokens.small, Tokens.textSecondary, maxLines = 2); Label("Press OK on the channel to try again.", Tokens.caption, Tokens.textTertiary)
            }
            else -> if (live == null) Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Image(Icons.Filled.LiveTv, null, Modifier.size(34.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)); Label("Choose a channel to watch", Tokens.heading, Tokens.textSecondary)
            }
        }
    }
    if (live != null) Box(Modifier.padding(8.dp).background(Tokens.danger, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label("LIVE", Tokens.caption, Color.White, FontWeight.Bold) }
}
