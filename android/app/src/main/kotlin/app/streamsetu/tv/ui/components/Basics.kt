package app.streamsetu.tv.ui.components

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import app.streamsetu.core.ui.motion.focusScale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun Label(text: String, size: TextUnit = Tokens.body, color: Color = Tokens.text, weight: FontWeight = FontWeight.Normal,
          maxLines: Int = 1, modifier: Modifier = Modifier, letterSpacing: TextUnit = TextUnit.Unspecified) {
    BasicText(text, modifier, style = TextStyle(color = color, fontSize = size, fontWeight = weight, letterSpacing = letterSpacing), maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

/** Small spaced capitals, as in the Mac sidebar and banners ("DISCOVER · FROM YOUR LIBRARY"). */
@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier, color: Color = Tokens.textTertiary) =
    Label(text.uppercase(), Tokens.eyebrow, color, FontWeight.Bold, modifier = modifier, letterSpacing = 1.4.sp)

/** False while a full-screen page covers the screen, so the page underneath cannot take the remote's focus. */
val LocalFocusEnabled = androidx.compose.runtime.compositionLocalOf { true }

/** Where DOWN from the top bar lands on the current page (the hero's Play button, the open category pill, the first settings page...). */
val LocalContentEntry = androidx.compose.runtime.compositionLocalOf<FocusRequester?> { null }

/** A thicker white focus frame for people who find the thin accent line hard to see. */
val LocalHighContrast = androidx.compose.runtime.compositionLocalOf { false }

/** The last thing on the base page that held focus, so closing a page (a movie, an episode list, the player) returns you to it. */
object FocusMemory { var last: FocusRequester? = null; var lastHasFocus = false }

/** True inside a full-screen page (movie, series, add playlist, player): its buttons are not part of the remembered base page. */
val LocalInOverlay = androidx.compose.runtime.compositionLocalOf { false }

/**
 * Anything the remote can land on. Flat like the Mac app: no outline at rest; when focused it lifts slightly and shows a thin accent ring
 * (a TV has no pointer, so the ring is the cursor).
 */
/** Draws the edge of a shape (the focus ring). Half of the stroke falls outside the shape and is clipped, so the width is doubled by the caller. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.strokeOutline(o: androidx.compose.ui.graphics.Outline, color: Color, width: Float) {
    val st = androidx.compose.ui.graphics.drawscope.Stroke(width)
    when (o) {
        is androidx.compose.ui.graphics.Outline.Rounded -> drawRoundRect(color, androidx.compose.ui.geometry.Offset(o.roundRect.left, o.roundRect.top), androidx.compose.ui.geometry.Size(o.roundRect.width, o.roundRect.height), o.roundRect.topLeftCornerRadius, style = st)
        is androidx.compose.ui.graphics.Outline.Rectangle -> drawRect(color, androidx.compose.ui.geometry.Offset(o.rect.left, o.rect.top), androidx.compose.ui.geometry.Size(o.rect.width, o.rect.height), style = st)
        is androidx.compose.ui.graphics.Outline.Generic -> drawPath(o.path, color, style = st)
    }
}

@Composable
fun Focusable(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(Tokens.radius),
    container: Color = Tokens.card,
    focusedContainer: Color = Tokens.focusedSurface,
    scaleOnFocus: Float = app.streamsetu.core.ui.motion.Motion.CARD_FOCUS_SCALE,
    hairline: Boolean = false,
    ring: Color = Tokens.accent,
    onFocus: (Boolean) -> Unit = {},
    onLongClick: (() -> Unit)? = null,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    var longHandled by remember { mutableStateOf(false) }
    var held by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val highContrast = LocalHighContrast.current
    val enabled = LocalFocusEnabled.current
    val own = remember { FocusRequester() }
    val inOverlay = LocalInOverlay.current
    Box(
        modifier
            .focusScale(focused, scaleOnFocus)
            .clip(shape)
            .background(if (focused) focusedContainer else container)
            // The ring is drawn, not added as a layer, so taking and losing focus does not rebuild the modifier chain.
            .drawWithContent {
                drawContent()
                if (focused) strokeOutline(shape.createOutline(size, layoutDirection, this), if (highContrast) Color.White else ring, (if (highContrast) 3.dp else 1.5.dp).toPx() * 2)
                else if (hairline) strokeOutline(shape.createOutline(size, layoutDirection, this), Tokens.line, 1.dp.toPx() * 2)
            }
            .focusRequester(own)
            .focusProperties { canFocus = enabled }
            .onFocusChanged {
                focused = it.isFocused
                onFocus(it.isFocused)
                if (it.isFocused && enabled && !inOverlay) { FocusMemory.last = own; FocusMemory.lastHasFocus = true }
                else if (!it.isFocused && FocusMemory.last === own) FocusMemory.lastHasFocus = false
            }
            // Holding OK opens the context menu; a short press still clicks. A held key repeats (repeatCount 1, 2, ...), and a timer covers remotes that do not repeat.
            .then(if (onLongClick == null) Modifier else Modifier.onPreviewKeyEvent { e ->
                val select = e.key == androidx.compose.ui.input.key.Key.DirectionCenter || e.key == androidx.compose.ui.input.key.Key.Enter || e.key == androidx.compose.ui.input.key.Key.NumPadEnter
                if (!select) return@onPreviewKeyEvent false
                when (e.type) {
                    androidx.compose.ui.input.key.KeyEventType.KeyDown -> {
                        if (longHandled) true
                        else if (e.nativeKeyEvent.repeatCount >= 1) { longHandled = true; held = false; onLongClick(); scope.launch { delay(900); longHandled = false }; true }
                        else {
                            if (!held) { held = true; scope.launch { delay(550); if (held && !longHandled) { longHandled = true; held = false; onLongClick(); delay(900); longHandled = false } } }
                            false
                        }
                    }
                    androidx.compose.ui.input.key.KeyEventType.KeyUp -> { held = false; if (longHandled) { longHandled = false; true } else false }
                    else -> false
                }
            })
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick),
    ) { content(focused) }
}

@Composable
fun TvButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false, onFocus: (Boolean) -> Unit = {}) {
    Focusable(onClick, modifier, onFocus = onFocus, shape = RoundedCornerShape(50), container = if (primary) Tokens.accent.copy(alpha = 0.88f) else Tokens.elevated,
        focusedContainer = if (primary) Tokens.accent else Tokens.focusedSurface, scaleOnFocus = 1.04f) { _ ->
        val ink = if (primary) Color(0xFF04141A) else Tokens.text
        Row(Modifier.padding(horizontal = 14.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (icon != null) Image(icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(ink))
            Label(text, Tokens.row, ink, FontWeight.SemiBold)
        }
    }
}

/** The quiet tinted card shown while a poster loads or when there is none (same idea as the Mac app: a colour from the title). */
@Composable
fun PosterPlaceholder(title: String, modifier: Modifier = Modifier) {
    var h = 1469598103934665603UL
    for (b in title.lowercase().toByteArray()) { h = (h xor b.toULong()) * 1099511628211UL }
    val hue = (h % 360UL).toFloat()
    fun c(l: Float, s: Float) = Color.hsl(hue, s, l)
    Box(modifier.background(Brush.linearGradient(listOf(c(0.29f, 0.25f), c(0.08f, 0.28f)))), Alignment.BottomStart) {
        Label(title.uppercase(), Tokens.row, Tokens.text.copy(alpha = 0.92f), maxLines = 4, modifier = Modifier.padding(12.dp), letterSpacing = 0.7.sp)
    }
}

/** A poster, 150 x 218 on the Mac scaled up: artwork, title and a quiet subtitle under it. A thin bar shows how far you are. */
@Composable
fun PosterCard(title: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, progress: Float = 0f, width: Dp = Tokens.posterWidth, subtitle: String? = null, badge: String? = null, focusRequester: FocusRequester? = null, onLongClick: (() -> Unit)? = null) {
    Column(modifier.width(width), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Focusable(onClick, (if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier).fillMaxWidth().aspectRatio(2f / 3f), scaleOnFocus = app.streamsetu.core.ui.motion.Motion.POSTER_FOCUS_SCALE, onLongClick = onLongClick) { _ ->
            // With a picture to come, a flat dark tile is enough underneath (a title gradient only when there is no picture): less to draw and lay out per card.
            if (imageUrl.isNullOrBlank()) PosterPlaceholder(title, Modifier.fillMaxSize()) else { Box(Modifier.fillMaxSize().background(Tokens.card)); AsyncImage(imageUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(Tokens.accent)) }
            if (badge != null) Box(Modifier.align(Alignment.TopEnd).padding(5.dp).background(Color(0xB3000000), RoundedCornerShape(5.dp)).padding(horizontal = 5.dp, vertical = 1.dp)) { Label(badge, Tokens.caption, Tokens.text, FontWeight.SemiBold) }
        }
        Label(title, Tokens.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A wide 16:9 card (Continue Watching). */
@Composable
fun LandscapeCard(title: String, subtitle: String?, imageUrl: String?, onClick: () -> Unit, progress: Float = 0f, width: Dp = Tokens.landscapeWidth, badge: String? = null) {
    Column(Modifier.width(width), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Focusable(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f)) { _ ->
            PosterPlaceholder(title, Modifier.fillMaxSize())
            if (!imageUrl.isNullOrBlank()) AsyncImage(imageUrl, title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(Tokens.accent)) }
            if (badge != null) Box(Modifier.align(Alignment.TopStart).padding(6.dp).background(Tokens.accent, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp)) { Label(badge, Tokens.caption, Color(0xFF04141A), FontWeight.Bold) }
        }
        Label(title, Tokens.row, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

@Composable
fun ChannelLogo(url: String?, name: String, size: Dp = 30.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.elevated), Alignment.Center) {
        if (url.isNullOrBlank()) Label(name.take(2).uppercase(), Tokens.row, Tokens.textTertiary, FontWeight.Bold)
        else AsyncImage(url, name, Modifier.fillMaxSize().padding(5.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) = Label(text, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = modifier.padding(bottom = 6.dp))

@Composable
fun EmptyState(title: String, message: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Column(modifier.fillMaxSize(), Arrangement.Center, Alignment.CenterHorizontally) {
        Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Label(message, Tokens.body, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
        if (action != null) { Spacer(Modifier.height(20.dp)); action() }
    }
}

/**
 * A text box for a remote. It shows the value like a button; pressing OK opens the keyboard (and only then), Done or Back closes it and
 * returns to the list. A field that took the keyboard the moment it was focused would trap the remote on it.
 */
@Composable
fun TvTextField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, secret: Boolean = false, onDone: () -> Unit = {}) {
    var editing by remember { mutableStateOf(false) }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val requester = remember { androidx.compose.ui.focus.FocusRequester() }
    val rowRequester = remember { androidx.compose.ui.focus.FocusRequester() }
    var gotFocus by remember { mutableStateOf(false) }
    LaunchedEffect(editing) { gotFocus = false; if (editing) { runCatching { requester.requestFocus() }; keyboard?.show() } }
    Focusable({ editing = true }, modifier.focusRequester(rowRequester), shape = RoundedCornerShape(Tokens.radius), container = Tokens.card, focusedContainer = Tokens.elevated, scaleOnFocus = 1.02f, hairline = true) { _ ->
        Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp)) {
            if (editing) {
                BasicTextField(
                    value, onChange, Modifier.fillMaxWidth().focusRequester(requester).onFocusChanged { f -> if (f.isFocused) gotFocus = true else if (gotFocus) { editing = false } },
                    textStyle = TextStyle(color = Tokens.text, fontSize = Tokens.body), singleLine = true, cursorBrush = SolidColor(Tokens.accent),
                    visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
                    keyboardOptions = KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { editing = false; keyboard?.hide(); runCatching { rowRequester.requestFocus() }; onDone() }),
                )
            } else {
                val shown = if (secret && value.isNotEmpty()) "•".repeat(value.length.coerceAtMost(24)) else value
                if (value.isEmpty()) Label(placeholder, color = Tokens.textTertiary) else Label(shown)
            }
        }
    }
}

@Composable
fun Spinner(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val a by t.animateFloat(0.3f, 1f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(700), androidx.compose.animation.core.RepeatMode.Reverse), label = "alpha")
    Box(modifier.size(26.dp).clip(RoundedCornerShape(50)).background(Tokens.accent.copy(alpha = a)))
}

/** Shown for the moment before a page has its data, instead of a misleading "nothing here". */
@Composable
fun Loading(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), Alignment.Center) { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) { Spinner(); Label("Loading…", Tokens.row, Tokens.textSecondary) } }
}

/** A short fade-and-rise when a page appears, so moving between sections feels smooth instead of cutting. Alpha and translation only, and it stops at once under reduced motion. */
@Composable
fun FadeIn(key: Any, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    val a = remember(key) { androidx.compose.animation.core.Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(key) { if (!reduced) a.animateTo(1f, androidx.compose.animation.core.tween(app.streamsetu.core.ui.motion.Motion.SCREEN, easing = app.streamsetu.core.ui.motion.Motion.Standard)) }
    Box(modifier.graphicsLayer { alpha = a.value; translationY = (1f - a.value) * 12.dp.toPx() }) { content() }
}
