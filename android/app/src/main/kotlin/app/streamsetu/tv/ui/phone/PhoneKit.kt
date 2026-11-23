package app.streamsetu.tv.ui.phone

import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.tv.ui.components.DownloadBadge
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
import androidx.compose.ui.semantics.customActions
import androidx.compose.animation.animateColorAsState
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
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
import app.streamsetu.tv.ui.components.progressFill
import app.streamsetu.tv.ui.components.kenBurns
import app.streamsetu.tv.ui.components.PosterPlaceholder
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage

/**
 * A glossy surface in the theme's colours: the card colour (or the accent, for a main button), a top-lit sheen and a bright hairline along the top edge. Every colour comes from [Tokens],
 * so it changes with the theme and the accent. Solid colours only (no blur), so it stays cheap while scrolling.
 */
fun Modifier.glossy(shape: androidx.compose.ui.graphics.Shape, fill: Color = Tokens.card, accent: Boolean = false): Modifier {
    val base: androidx.compose.ui.graphics.Brush = if (accent) androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Tokens.accent, Tokens.accent.copy(alpha = 0.72f))) else androidx.compose.ui.graphics.SolidColor(fill)
    return this
        .background(base, shape)
        .background(androidx.compose.ui.graphics.Brush.verticalGradient(0f to Color(if (accent) 0x3DFFFFFF else 0x1FFFFFFF), 0.6f to Color.Transparent), shape)
        .border(1.dp, androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color(0x3DFFFFFF), Color(0x08FFFFFF))), shape)
}

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
}

@Composable
fun Tap(onClick: () -> Unit, modifier: Modifier = Modifier, onLong: (() -> Unit)? = null, content: @Composable BoxScope.() -> Unit) {
    // Every card and poster on the phone presses in a little and springs back (only a dim with reduced motion), with a light tick on a tap.
    val source = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    val view = androidx.compose.ui.platform.LocalView.current
    @OptIn(ExperimentalFoundationApi::class)
    Box(modifier.pressFeel(source).combinedClickable(interactionSource = source, indication = null, onClick = { view.performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY); onClick() },
        onLongClick = onLong?.let { l -> { view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS); l() } }), content = content)
}

/** The press feel of the phone app: while [source] is pressed the item shrinks to 0.97 and dims a little, and springs back on release. With reduced motion only the dim. */
@Composable
fun Modifier.pressFeel(source: androidx.compose.foundation.interaction.InteractionSource): Modifier {
    val pressed by source.collectIsPressedAsState()
    val reduced = app.streamsetu.tv.ui.screens.library.reducedMotion()
    val k by androidx.compose.animation.core.animateFloatAsState(if (pressed) 1f else 0f, if (reduced) androidx.compose.animation.core.snap() else app.streamsetu.tv.ui.screens.library.pressSpring(), label = "press")
    return this.graphicsLayer { if (!reduced) { val sc = 1f - 0.03f * k; scaleX = sc; scaleY = sc }; alpha = 1f - 0.1f * k }
}

@Composable
fun Icon(icon: ImageVector, tint: Color = Tokens.text, size: Dp = 24.dp, modifier: Modifier = Modifier) =
    Image(icon, null, modifier.size(size), colorFilter = ColorFilter.tint(tint))

/** A round icon button with a 48 dp touch target. */
@Composable
fun IconTap(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = Tokens.text, filled: Boolean = false) {
    val source = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Box(modifier.size(48.dp).pressFeel(source).clip(CircleShape).then(if (filled) Modifier.background(Color(0x40FFFFFF)) else Modifier).semantics { contentDescription = label; role = Role.Button }.clickable(interactionSource = source, indication = null, onClick = onClick), Alignment.Center) { Icon(icon, tint, 24.dp) }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, progress: Float? = null) {
    val chipSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Row(
        modifier.height(36.dp).pressFeel(chipSource).clip(RoundedCornerShape(18.dp)).background(animateColorAsState(if (selected) Tokens.accent else Tokens.elevated, androidx.compose.animation.core.tween(160), label = "chip").value)
            .semantics { this.selected = selected; role = Role.Button }.clickable(interactionSource = chipSource, indication = null, onClick = onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (progress != null) DownloadRing(progress, if (selected) Color(0xFF04141A) else Tokens.accent, 18.dp)
        else if (icon != null) Icon(icon, if (selected) Color(0xFF04141A) else Tokens.textSecondary, 16.dp)
        Label(text, Ph.small, if (selected) Color(0xFF04141A) else Tokens.text, FontWeight.Medium)
    }
}

/** A ring that fills as a download proceeds, with a small stop square inside, as Netflix draws it. */
@Composable
fun DownloadRing(progress: Float, ink: Color, size: Dp) {
    val animated by androidx.compose.animation.core.animateFloatAsState(progress.coerceIn(0.04f, 1f), androidx.compose.animation.core.tween(400), label = "download")
    androidx.compose.foundation.Canvas(Modifier.size(size)) {
        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.2.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)
        drawArc(ink.copy(alpha = 0.3f), 0f, 360f, false, style = stroke)
        drawArc(ink, -90f, 360f * animated, false, style = stroke)
        val side = this.size.minDimension * 0.28f
        drawRect(ink, androidx.compose.ui.geometry.Offset((this.size.width - side) / 2, (this.size.height - side) / 2), androidx.compose.ui.geometry.Size(side, side))
    }
}

@Composable
fun PillButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    val pillSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Row(
        modifier.height(44.dp).pressFeel(pillSource).clip(RoundedCornerShape(22.dp)).glossy(RoundedCornerShape(22.dp), accent = primary).clickable(interactionSource = pillSource, indication = null, onClick = onClick).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        if (icon != null) Icon(icon, if (primary) Color.White else Tokens.text, 20.dp)
        Label(text, Ph.body, if (primary) Color.White else Tokens.text, FontWeight.SemiBold)
    }
}

/** A poster for a grid or a row: artwork, a bar for how far you are, a small badge, and the title under it. Tap opens; touch and hold opens the menu. */
@Composable
fun PhonePoster(title: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, subtitle: String? = null, badge: String? = null, progress: Float = 0f, onLong: (() -> Unit)? = null, itemId: String? = null) {
    app.streamsetu.tv.ui.components.ReportTileVisible(itemId, !imageUrl.isNullOrBlank())
    // A poster without a menu of its own opens the shared one; every item of it is also a screen-reader action of the poster.
    val shared = LocalTileMenu.current
    val long = onLong ?: itemId?.let { id -> shared?.let { open -> { open(id) } } }
    val a11y = rememberTileA11y(itemId)
    Column(modifier.moreOptionsAction(long, a11y), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Tap(onClick, Modifier.fillMaxWidth().aspectRatio(2f / 3f).tileShadow(12.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.card).border(1.dp, Color(0x1AFFFFFF), RoundedCornerShape(12.dp)), long) {
            app.streamsetu.tv.ui.components.PosterArt(title, imageUrl?.takeIf { it.isNotBlank() }, Modifier.fillMaxSize(), year = subtitle?.take(4))
            val shown = if (progress > 0f) progress else itemId?.let { app.streamsetu.tv.ui.components.LocalPartialProgress.current[it] } ?: 0f
            if (shown > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(shown.coerceIn(0f, 1f)).fillMaxHeight().background(Tokens.accent)) }
            // The corner: the tag first, the rating after it, so they never overlap.
            Row(Modifier.align(Alignment.TopEnd).padding(6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (badge != null) Box(Modifier.background(Color(0x99000000), RoundedCornerShape(7.dp)).border(1.dp, Color(0x26FFFFFF), RoundedCornerShape(7.dp)).padding(horizontal = 6.dp, vertical = 2.dp)) { Label(badge, Ph.caption, Tokens.text, FontWeight.SemiBold) }
                app.streamsetu.tv.ui.components.TileRating(itemId, small = true)
            }
            if (itemId != null) app.streamsetu.tv.ui.components.LocalDownloadStatus.current[itemId]?.let { (st, f) -> DownloadBadge(st, f) }
            if (itemId != null && itemId in app.streamsetu.tv.ui.components.LocalWatched.current) WatchedTick()
        }
        Label(title, Ph.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Ph.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A wide card (Continue Watching, channels). */
@Composable
fun PhoneWide(title: String, subtitle: String?, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, progress: Float = 0f, badge: String? = null, onLong: (() -> Unit)? = null, itemId: String? = null) {
    app.streamsetu.tv.ui.components.ReportTileVisible(itemId, !imageUrl.isNullOrBlank())
    val a11y = rememberTileA11y(itemId)
    Column(modifier.moreOptionsAction(onLong, a11y), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Tap(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f).tileShadow(14.dp).clip(RoundedCornerShape(14.dp)).background(Tokens.card).border(1.dp, Color(0x1AFFFFFF), RoundedCornerShape(14.dp)), onLong) {
            PosterPlaceholder(title, Modifier.fillMaxSize())
            if (!imageUrl.isNullOrBlank()) AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).progressFill(progress, Color(0x66000000), Tokens.accent))
            if (badge != null) Box(Modifier.align(Alignment.TopStart).padding(6.dp).background(Tokens.accent, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label(badge, Ph.caption, Color(0xFF04141A), FontWeight.Bold) }
            app.streamsetu.tv.ui.components.TileRating(itemId, Modifier.align(Alignment.TopEnd).padding(6.dp), small = true)
        }
        Label(title, Ph.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Ph.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, action: String? = null, onAction: () -> Unit = {}) {
    Row(modifier.fillMaxWidth().padding(horizontal = Ph.gutter), verticalAlignment = Alignment.CenterVertically) {
        Label(text, 20.sp, Tokens.text, FontWeight.Bold, modifier = Modifier.weight(1f).semantics { heading() })
        if (action != null) Box(Modifier.clickable(onClick = onAction).padding(vertical = 8.dp, horizontal = 4.dp)) { Label(action, Ph.small, Tokens.accent, FontWeight.Medium) }
    }
}

/** The bottom bar, as on the iPhone: a floating rounded bar with a highlighted capsule behind the section you are in. While the page scrolls down it shrinks to one round button at the right (the icon of the section you are in, no name); tap it to bring the bar back. */
@Composable
fun PhoneTabBar(selected: Tab, onSelect: (Tab) -> Unit, collapsed: Boolean = false, onExpand: () -> Unit = {}) {
    val items = listOf(
        Triple(Tab.HOME, Icons.Filled.Home, "Home"), Triple(Tab.LIVE, Icons.Filled.LiveTv, "Live TV"), Triple(Tab.MOVIES, Icons.Filled.Movie, "Movies"),
        Triple(Tab.SERIES, Icons.Filled.VideoLibrary, "Series"), Triple(Tab.SETTINGS, Icons.Filled.MoreHoriz, "More"),
    )
    // The strip keeps the full bar's height in both states, so the page above it never resizes while it scrolls.
    Box(Modifier.fillMaxWidth().height(62.dp + 16.dp).windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 14.dp, vertical = 8.dp), contentAlignment = Alignment.CenterEnd) {
        androidx.compose.animation.Crossfade(collapsed, animationSpec = androidx.compose.animation.core.tween(180), label = "tabbar") { small ->
            if (small) {
                val current = items.firstOrNull { it.first == selected } ?: items.first { it.first == Tab.SETTINGS }
                Box(Modifier.size(52.dp).shadow(10.dp, CircleShape).clip(CircleShape).glossy(CircleShape)
                    .semantics { contentDescription = "Show the tab bar, ${current.third} is open"; role = Role.Button }.clickable(onClick = onExpand), Alignment.Center) { Icon(current.second, Tokens.accent, 24.dp) }
            } else {
                // The selected tab's background slides from one tab to the next instead of jumping.
                val index = items.indexOfFirst { (tab, _, _) -> tab == selected || (tab == Tab.SETTINGS && selected in listOf(Tab.GUIDE, Tab.SEARCH, Tab.LIBRARIES)) }.coerceAtLeast(0)
                val reduced = app.streamsetu.tv.ui.screens.library.reducedMotion()
                val at by androidx.compose.animation.core.animateFloatAsState(index.toFloat(), if (reduced) androidx.compose.animation.core.snap() else app.streamsetu.tv.ui.screens.library.pressSpring(), label = "tabPill")
                val pill = Tokens.elevated
                Row(Modifier.fillMaxWidth().height(62.dp).shadow(10.dp, RoundedCornerShape(31.dp)).clip(RoundedCornerShape(31.dp)).glossy(RoundedCornerShape(31.dp)).padding(5.dp).drawBehind {
                    val w = size.width / items.size
                    drawRoundRect(pill, androidx.compose.ui.geometry.Offset(at * w, 0f), androidx.compose.ui.geometry.Size(w, size.height), androidx.compose.ui.geometry.CornerRadius(26.dp.toPx()))
                }) {
                    items.forEach { (tab, icon, name) ->
                        val on = tab == selected || (tab == Tab.SETTINGS && selected in listOf(Tab.GUIDE, Tab.SEARCH, Tab.LIBRARIES))
                        val view = androidx.compose.ui.platform.LocalView.current
                        Column(
                            Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(26.dp)).clickable { if (!on && android.os.Build.VERSION.SDK_INT >= 23) view.performHapticFeedback(android.view.HapticFeedbackConstants.CONTEXT_CLICK); onSelect(tab) },
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                        ) {
                            Icon(icon, if (on) Tokens.accent else Tokens.textTertiary, 24.dp)
                            Label(name, 11.sp, if (on) Tokens.accent else Tokens.textTertiary, if (on) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(top = 1.dp))
                        }
                    }
                }
            }
        }
    }
}

/** The top of a section, as on the iPhone: its name in a pill in the middle, round buttons on the right (and one on the left when there is one). */
@Composable
fun PhoneTopBar(title: String, modifier: Modifier = Modifier, leading: (@Composable () -> Unit)? = null, showTitle: Boolean = true, actions: @Composable RowScope.() -> Unit = {}) {
    Box(modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).height(64.dp).padding(horizontal = 12.dp)) {
        Row(Modifier.align(Alignment.CenterStart)) { leading?.invoke() }
        if (showTitle) Box(Modifier.align(Alignment.Center).clip(RoundedCornerShape(22.dp)).glossy(RoundedCornerShape(22.dp)).padding(horizontal = 22.dp, vertical = 9.dp)) { Label(title, Ph.heading, Tokens.text, FontWeight.SemiBold) }
        Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(8.dp)) { actions() }
    }
}

/** A round outlined button for the top bar. */
@Composable
fun RoundTap(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(CircleShape).glossy(CircleShape).semantics { contentDescription = label; role = Role.Button }.clickable(onClick = onClick), Alignment.Center) { Icon(icon, Tokens.text, 22.dp) }
}

/** The featured title: a rounded card with the picture, the title, a line of facts, a short story and a Play button, with dots for the other titles. It turns by itself. */
@Composable
fun PhoneBanner(items: List<app.streamsetu.tv.ui.components.BannerItem>, onPrimary: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, onDetails: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, modifier: Modifier = Modifier, immersive: Boolean = false, share: Float = 0.54f) {
    if (items.isEmpty()) return
    if (immersive) { ImmersiveBanner(items, onPrimary, onDetails, modifier, share); return }
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(items.size, index) { if (items.size > 1) { kotlinx.coroutines.delay(8000); index = (index + 1) % items.size } }
    val b = items[index % items.size]
    Box(modifier.padding(horizontal = Ph.gutter).fillMaxWidth().aspectRatio(1.55f).clip(RoundedCornerShape(20.dp)).background(Tokens.card).clickable { onDetails(b) }) {
        androidx.compose.animation.Crossfade(b, animationSpec = androidx.compose.animation.core.tween(600), label = "banner") { it ->
            Box(Modifier.fillMaxSize()) {
                if (it.imageUrl.isNullOrBlank()) PosterPlaceholder(it.title, Modifier.fillMaxSize()) else if (!it.imageIsBackdrop) app.streamsetu.tv.ui.components.PosterOnWash(it.imageUrl, it.title, Modifier.fillMaxSize()) else AsyncImage(it.imageUrl, null, Modifier.fillMaxSize().kenBurns(it.id), contentScale = ContentScale.Crop)
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

/** How tall a full-width banner is: a share of the screen height, so the first row (or the filter chips) always peeks in under it. */
@Composable
fun heroHeight(share: Float = 0.54f): Dp = (androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp * share).dp.coerceIn(360.dp, 620.dp)

/** The featured title, edge to edge and up under the status bar, melting into the page below. The top bar is drawn over it by the screen. */
@Composable
private fun ImmersiveBanner(items: List<app.streamsetu.tv.ui.components.BannerItem>, onPrimary: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, onDetails: (app.streamsetu.tv.ui.components.BannerItem) -> Unit, modifier: Modifier, share: Float) {
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(items.size, index) { if (items.size > 1) { kotlinx.coroutines.delay(8000); index = (index + 1) % items.size } }
    val b = items[index % items.size]
    val page = Tokens.background
    Box(modifier.fillMaxWidth().height(heroHeight(share)).background(Tokens.card).clickable { onDetails(b) }) {
        androidx.compose.animation.Crossfade(b, animationSpec = androidx.compose.animation.core.tween(600), label = "hero") { it ->
            Box(Modifier.fillMaxSize()) {
                if (it.imageUrl.isNullOrBlank()) PosterPlaceholder(it.title, Modifier.fillMaxSize()) else if (!it.imageIsBackdrop) app.streamsetu.tv.ui.components.PosterOnWash(it.imageUrl, it.title, Modifier.fillMaxSize()) else AsyncImage(it.imageUrl, null, Modifier.fillMaxSize().kenBurns(it.id), contentScale = ContentScale.Crop)
                Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0f to Color(0x99000000), 0.22f to Color.Transparent)))          // keeps the clock and the top buttons readable
                Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0.38f to Color.Transparent, 0.72f to page.copy(alpha = 0.72f), 1f to page)))
                Column(Modifier.align(Alignment.BottomStart).padding(start = 20.dp, end = 20.dp, bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(Tokens.accent))
                        Label("FEATURED", 11.sp, Color(0xD9FFFFFF), FontWeight.Bold, letterSpacing = 1.6.sp)
                    }
                    Label(it.title, 34.sp, Color.White, FontWeight.ExtraBold, maxLines = 2)
                    if (it.facts.isNotEmpty()) Label(it.facts.joinToString("  ·  "), Ph.small, Color(0xC7FFFFFF))
                    it.synopsis?.let { t -> Label(t, Ph.small, Color(0xB3FFFFFF), maxLines = 2) }
                    Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Row(Modifier.height(46.dp).clip(RoundedCornerShape(23.dp)).glossy(RoundedCornerShape(23.dp), accent = true).clickable { onPrimary(it) }.padding(horizontal = 22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.PlayArrow, Color.White, 22.dp); Label(if (it.primaryLabel == "Play") "Play" else it.primaryLabel, Ph.body, Color.White, FontWeight.Bold)
                        }
                        Row(Modifier.height(46.dp).clip(RoundedCornerShape(23.dp)).background(Color(0x40FFFFFF)).border(1.dp, Color(0x29FFFFFF), RoundedCornerShape(23.dp)).clickable { onDetails(it) }.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.Info, Color.White, 20.dp); Label("Details", Ph.body, Color.White, FontWeight.SemiBold)
                        }
                    }
                    Spacer(Modifier.height(12.dp))          // room for the dots
                }
            }
        }
        if (items.size > 1) Row(Modifier.align(Alignment.BottomEnd).padding(end = 20.dp, bottom = 20.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            items.take(8).forEachIndexed { i, _ -> Box(Modifier.height(5.dp).width(if (i == index % items.size) 22.dp else 6.dp).clip(CircleShape).background(if (i == index % items.size) Color.White else Color(0x59FFFFFF))) }
        }
    }
}

/** Shows a message under a short pause rather than flashing "empty" while a list loads. */
@Composable
fun Empty(title: String, message: String, modifier: Modifier = Modifier, art: app.streamsetu.tv.ui.components.EmptyArt = emptyArtFor(title)) {
    app.streamsetu.tv.ui.components.AnimatedEmptyState(art, title, message, modifier.fillMaxWidth().padding(32.dp), titleSize = Ph.heading, messageSize = Ph.small, artSize = 64.dp)
}

/** The picture for an empty page, from what its title says. */
fun emptyArtFor(title: String): app.streamsetu.tv.ui.components.EmptyArt = title.lowercase().let { t -> when {
    "result" in t || "found" in t || "match" in t -> app.streamsetu.tv.ui.components.EmptyArt.NoResults
    "favorite" in t || "later" in t || "saved" in t || "download" in t -> app.streamsetu.tv.ui.components.EmptyArt.Bookmark
    "connection" in t || "offline" in t || "network" in t -> app.streamsetu.tv.ui.components.EmptyArt.NoConnection
    "error" in t || "could not" in t || "failed" in t -> app.streamsetu.tv.ui.components.EmptyArt.Error
    "library" in t -> app.streamsetu.tv.ui.components.EmptyArt.Library
    else -> app.streamsetu.tv.ui.components.EmptyArt.Nothing
} }

/** The strip above the tab bar while something plays and the picture is closed: what it is, play or pause, and stop. Tap it to bring the picture back. */
@Composable
fun MiniPlayer(c: app.streamsetu.tv.AppContainer, onOpen: () -> Unit) {
    val item by c.playback.current.collectAsStateWithLifecycle()
    val state by c.playback.state.collectAsStateWithLifecycle()
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

/** TalkBack: a card with a touch-and-hold menu also offers "More options" as an accessibility action, so the menu does not depend on finding the long press. */
fun Modifier.moreOptionsAction(onLong: (() -> Unit)?, items: List<Pair<String, () -> Unit>> = emptyList()): Modifier = if (onLong == null) this else this.semantics(mergeDescendants = false) {
    customActions = items.map { (label, run) -> androidx.compose.ui.semantics.CustomAccessibilityAction(label) { run(); true } } + androidx.compose.ui.semantics.CustomAccessibilityAction("More options") { onLong(); true }
}

/** The soft shadow under a tile. A shadow per tile is a real GPU cost on a low-end phone or tablet, so there the flat border alone is drawn; elsewhere it is unchanged. */
@Composable
private fun Modifier.tileShadow(radius: androidx.compose.ui.unit.Dp): Modifier {
    val context = androidx.compose.ui.platform.LocalContext.current
    val flat = remember(context) { app.streamsetu.tv.Perf.lowEnd(context) }
    return if (flat) this else this.shadow(6.dp, RoundedCornerShape(radius))
}
