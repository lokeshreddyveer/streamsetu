package app.streamsetu.tv.ui.phone

import app.streamsetu.tv.ui.components.WatchedTick
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterPlaceholder
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage

/** True on a phone or tablet: a touch screen and no television. A Fire TV or Android TV keeps the remote layout. */
fun isPhoneDevice(context: Context): Boolean {
    val pm = context.packageManager
    val tv = pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) || pm.hasSystemFeature("amazon.hardware.fire_tv") || pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
    return !tv && pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
}

/** Type sizes for a screen held in the hand (the TV sizes are set for reading from a sofa). */
object Ph {
    val title = 24.sp; val heading = 18.sp; val body = 15.sp; val small = 13.sp; val caption = 12.sp
    val gutter = 16.dp
    val tabBar = 58.dp
}

@Composable
fun Tap(onClick: () -> Unit, modifier: Modifier = Modifier, onLong: (() -> Unit)? = null, content: @Composable BoxScope.() -> Unit) {
    @OptIn(ExperimentalFoundationApi::class)
    Box(modifier.combinedClickable(onClick = onClick, onLongClick = onLong), content = content)
}

@Composable
fun Icon(icon: ImageVector, tint: Color = Tokens.text, size: Dp = 24.dp, modifier: Modifier = Modifier) =
    Image(icon, null, modifier.size(size), colorFilter = ColorFilter.tint(tint))

/** A round icon button with a 48 dp touch target. */
@Composable
fun IconTap(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = Tokens.text, filled: Boolean = false) {
    Box(modifier.size(48.dp).clip(CircleShape).then(if (filled) Modifier.background(Color(0x40FFFFFF)) else Modifier).semantics { contentDescription = label; role = Role.Button }.clickable(onClick = onClick), Alignment.Center) { Icon(icon, tint, 24.dp) }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    Row(
        modifier.height(36.dp).clip(RoundedCornerShape(18.dp)).background(if (selected) Tokens.accent else Tokens.elevated).semantics { this.selected = selected; role = Role.Button }.clickable(onClick = onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Icon(icon, if (selected) Color(0xFF04141A) else Tokens.textSecondary, 16.dp)
        Label(text, Ph.small, if (selected) Color(0xFF04141A) else Tokens.text, FontWeight.Medium)
    }
}

@Composable
fun PillButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    Row(
        modifier.height(44.dp).clip(RoundedCornerShape(22.dp)).background(if (primary) Color.White else Color(0x33FFFFFF)).clickable(onClick = onClick).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        if (icon != null) Icon(icon, if (primary) Color.Black else Tokens.text, 20.dp)
        Label(text, Ph.body, if (primary) Color.Black else Tokens.text, FontWeight.SemiBold)
    }
}

/** A poster for a grid or a row: artwork, a bar for how far you are, a small badge, and the title under it. Tap opens; touch and hold opens the menu. */
@Composable
fun PhonePoster(title: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, subtitle: String? = null, badge: String? = null, progress: Float = 0f, onLong: (() -> Unit)? = null, itemId: String? = null) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Tap(onClick, Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(10.dp)).background(Tokens.card), onLong) {
            if (imageUrl.isNullOrBlank()) PosterPlaceholder(title, Modifier.fillMaxSize()) else AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxHeight().background(Tokens.accent)) }
            if (badge != null) Box(Modifier.align(Alignment.TopEnd).padding(5.dp).background(Color(0xB3000000), RoundedCornerShape(5.dp)).padding(horizontal = 5.dp, vertical = 1.dp)) { Label(badge, Ph.caption, Tokens.text, FontWeight.SemiBold) }
            if (itemId != null && itemId in app.streamsetu.tv.ui.components.LocalWatched.current) WatchedTick()
        }
        Label(title, Ph.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Ph.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A wide card (Continue Watching, channels). */
@Composable
fun PhoneWide(title: String, subtitle: String?, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, progress: Float = 0f, badge: String? = null, onLong: (() -> Unit)? = null) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Tap(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp)).background(Tokens.card), onLong) {
            PosterPlaceholder(title, Modifier.fillMaxSize())
            if (!imageUrl.isNullOrBlank()) AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxHeight().background(Tokens.accent)) }
            if (badge != null) Box(Modifier.align(Alignment.TopStart).padding(6.dp).background(Tokens.accent, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label(badge, Ph.caption, Color(0xFF04141A), FontWeight.Bold) }
        }
        Label(title, Ph.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Ph.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, action: String? = null, onAction: () -> Unit = {}) {
    Row(modifier.fillMaxWidth().padding(horizontal = Ph.gutter), verticalAlignment = Alignment.CenterVertically) {
        Label(text, Ph.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.weight(1f).semantics { heading() })
        if (action != null) Box(Modifier.clickable(onClick = onAction).padding(vertical = 8.dp, horizontal = 4.dp)) { Label(action, Ph.small, Tokens.accent, FontWeight.Medium) }
    }
}

/** The bottom bar, as on the iPhone: a floating rounded bar with a highlighted capsule behind the section you are in. */
@Composable
fun PhoneTabBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val items = listOf(
        Triple(Tab.HOME, Icons.Filled.Home, "Home"), Triple(Tab.LIVE, Icons.Filled.LiveTv, "Live TV"), Triple(Tab.MOVIES, Icons.Filled.Movie, "Movies"),
        Triple(Tab.SERIES, Icons.Filled.VideoLibrary, "Series"), Triple(Tab.SETTINGS, Icons.Filled.MoreHoriz, "More"),
    )
    Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 14.dp, vertical = 8.dp)) {
        Row(Modifier.fillMaxWidth().height(62.dp).clip(RoundedCornerShape(31.dp)).background(Color(0xF2151820)).padding(5.dp)) {
            items.forEach { (tab, icon, name) ->
                val on = tab == selected || (tab == Tab.SETTINGS && selected in listOf(Tab.GUIDE, Tab.SEARCH, Tab.LIBRARIES))
                Column(
                    Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(26.dp)).background(if (on) Color(0xFF263149) else Color.Transparent).clickable { onSelect(tab) },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    Icon(icon, if (on) Tokens.accent else Tokens.textTertiary, 24.dp)
                    Label(name, 11.sp, if (on) Tokens.accent else Tokens.textTertiary, if (on) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(top = 1.dp))
                }
            }
        }
    }
}

/** The top of a section, as on the iPhone: its name in a pill in the middle, round buttons on the right (and one on the left when there is one). */
@Composable
fun PhoneTopBar(title: String, modifier: Modifier = Modifier, leading: (@Composable () -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Box(modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).height(64.dp).padding(horizontal = 12.dp)) {
        Row(Modifier.align(Alignment.CenterStart)) { leading?.invoke() }
        Box(Modifier.align(Alignment.Center).clip(RoundedCornerShape(22.dp)).background(Color(0xFF14161B)).border(1.dp, Tokens.lineStrong, RoundedCornerShape(22.dp)).padding(horizontal = 22.dp, vertical = 9.dp)) { Label(title, Ph.heading, Tokens.text, FontWeight.SemiBold) }
        Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(8.dp)) { actions() }
    }
}

/** A round outlined button for the top bar. */
@Composable
fun RoundTap(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(CircleShape).background(Color(0xFF14161B)).border(1.dp, Tokens.lineStrong, CircleShape).semantics { contentDescription = label; role = Role.Button }.clickable(onClick = onClick), Alignment.Center) { Icon(icon, Tokens.text, 22.dp) }
}

/** The featured title: a rounded card with the picture, the title, a line of facts, a short story and a Play button, with dots for the other titles. It turns by itself. */
@Composable
fun PhoneBanner(items: List<app.streamsetu.tv.ui.components.BannerItem>, onPrimary: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, onDetails: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, modifier: Modifier = Modifier) {
    if (items.isEmpty()) return
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(items.size, index) { if (items.size > 1) { kotlinx.coroutines.delay(8000); index = (index + 1) % items.size } }
    val b = items[index % items.size]
    Box(modifier.padding(horizontal = Ph.gutter).fillMaxWidth().aspectRatio(1.55f).clip(RoundedCornerShape(20.dp)).background(Tokens.card).clickable { onDetails(b) }) {
        androidx.compose.animation.Crossfade(b, animationSpec = androidx.compose.animation.core.tween(600), label = "banner") { it ->
            Box(Modifier.fillMaxSize()) {
                if (it.imageUrl.isNullOrBlank()) PosterPlaceholder(it.title, Modifier.fillMaxSize()) else AsyncImage(it.imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0.35f to Color.Transparent, 1f to Color(0xE6000000))))
                Column(Modifier.align(Alignment.BottomStart).padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Label(it.title, 22.sp, Color.White, FontWeight.Bold, maxLines = 2)
                    if (it.facts.isNotEmpty()) Label(it.facts.joinToString("  ·  "), Ph.small, Color(0xCCFFFFFF))
                    it.synopsis?.let { t -> Label(t, Ph.small, Color(0xB3FFFFFF), maxLines = 2) }
                    Row(Modifier.padding(top = 6.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Row(Modifier.height(40.dp).clip(RoundedCornerShape(20.dp)).background(Color.White).clickable { onPrimary(it) }.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.PlayArrow, Color.Black, 20.dp); Label(if (it.primaryLabel == "Play") "Play" else it.primaryLabel, Ph.body, Color.Black, FontWeight.SemiBold)
                        }
                        Spacer(Modifier.weight(1f))
                        if (items.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                            items.take(8).forEachIndexed { i, _ -> Box(Modifier.height(6.dp).width(if (i == index % items.size) 20.dp else 6.dp).clip(CircleShape).background(if (i == index % items.size) Color.White else Color(0x66FFFFFF))) }
                        }
                    }
                }
            }
        }
    }
}

/** Shows a message under a short pause rather than flashing "empty" while a list loads. */
@Composable
fun Empty(title: String, message: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Label(title, Ph.heading, Tokens.text, FontWeight.SemiBold)
        Label(message, Ph.small, Tokens.textSecondary, maxLines = 3)
    }
}

/** The strip above the tab bar while something plays and the picture is closed: what it is, play or pause, and stop. Tap it to bring the picture back. */
@Composable
fun MiniPlayer(c: app.streamsetu.tv.AppContainer, onOpen: () -> Unit) {
    val item by c.playback.current.collectAsState()
    val state by c.playback.state.collectAsState()
    val shown = item ?: return
    val playing = state == app.streamsetu.core.playback.PlaybackState.Playing || state == app.streamsetu.core.playback.PlaybackState.Buffering
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp).clip(RoundedCornerShape(18.dp)).background(Color(0xF21B2030)).clickable(onClick = onOpen).padding(start = 10.dp, top = 6.dp, bottom = 6.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(Tokens.card)) {
            if (shown.artworkUrl.isNullOrBlank()) PosterPlaceholder(shown.title, Modifier.fillMaxSize()) else AsyncImage(shown.artworkUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        Column(Modifier.weight(1f)) {
            Label(if (shown is app.streamsetu.core.model.EpisodePlayable) shown.series.title else shown.title, Ph.small, Tokens.text, FontWeight.SemiBold)
            Label(if (shown.isLive) (if (playing) "Live" else "Paused") else if (playing) "Playing" else "Paused", Ph.caption, Tokens.textSecondary)
        }
        IconTap(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play", { c.playback.togglePause() })
        IconTap(Icons.Filled.Close, "Stop", { c.playback.stop() })
    }
}
