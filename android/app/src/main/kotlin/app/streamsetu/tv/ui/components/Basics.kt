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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
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

@Composable
fun Label(text: String, size: TextUnit = Tokens.body, color: Color = Tokens.text, weight: FontWeight = FontWeight.Normal,
          maxLines: Int = 1, modifier: Modifier = Modifier, letterSpacing: TextUnit = TextUnit.Unspecified) {
    BasicText(text, modifier, style = TextStyle(color = color, fontSize = size, fontWeight = weight, letterSpacing = letterSpacing), maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

/** Small spaced capitals, as in the Mac sidebar and banners ("DISCOVER · FROM YOUR LIBRARY"). */
@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier, color: Color = Tokens.textTertiary) =
    Label(text.uppercase(), Tokens.eyebrow, color, FontWeight.Bold, modifier = modifier, letterSpacing = 1.4.sp)

/**
 * Anything the remote can land on. Flat like the Mac app: no outline at rest; when focused it lifts slightly and shows a thin accent ring
 * (a TV has no pointer, so the ring is the cursor).
 */
@Composable
fun Focusable(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(Tokens.radius),
    container: Color = Tokens.card,
    focusedContainer: Color = Tokens.elevated,
    scaleOnFocus: Float = 1.05f,
    hairline: Boolean = false,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) scaleOnFocus else 1f, label = "focus-scale")
    Box(
        modifier
            .scale(scale)
            .clip(shape)
            .background(if (focused) focusedContainer else container)
            .then(if (focused) Modifier.border(BorderStroke(2.dp, Tokens.accent), shape) else if (hairline) Modifier.border(BorderStroke(1.dp, Tokens.line), shape) else Modifier)
            .onFocusChanged { focused = it.isFocused }
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick),
    ) { content(focused) }
}

@Composable
fun TvButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(50), container = if (primary) Tokens.playPill else Tokens.elevated,
        focusedContainer = if (primary) Tokens.playPill else Tokens.elevated.copy(alpha = 1f), scaleOnFocus = 1.05f) { _ ->
        Row(Modifier.padding(horizontal = 24.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (icon != null) Image(icon, null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(Tokens.text))
            Label(text, Tokens.row, Tokens.text, FontWeight.SemiBold)
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
fun PosterCard(title: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, progress: Float = 0f, width: Dp = Tokens.posterWidth, subtitle: String? = null) {
    Column(modifier.width(width), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Focusable(onClick, Modifier.fillMaxWidth().aspectRatio(150f / 218f)) { _ ->
            PosterPlaceholder(title, Modifier.fillMaxSize())
            if (!imageUrl.isNullOrBlank()) AsyncImage(imageUrl, title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(Tokens.accent)) }
        }
        Label(title, Tokens.row, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A wide 16:9 card (Continue Watching). */
@Composable
fun LandscapeCard(title: String, subtitle: String?, imageUrl: String?, onClick: () -> Unit, progress: Float = 0f, width: Dp = Tokens.landscapeWidth) {
    Column(Modifier.width(width), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Focusable(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f)) { _ ->
            PosterPlaceholder(title, Modifier.fillMaxSize())
            if (!imageUrl.isNullOrBlank()) AsyncImage(imageUrl, title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color(0x66000000))) { Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(Tokens.accent)) }
        }
        Label(title, Tokens.row, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 2.dp))
        if (subtitle != null) Label(subtitle, Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

@Composable
fun ChannelLogo(url: String?, name: String, size: Dp = 56.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.elevated), Alignment.Center) {
        if (url.isNullOrBlank()) Label(name.take(2).uppercase(), Tokens.row, Tokens.textTertiary, FontWeight.Bold)
        else AsyncImage(url, name, Modifier.fillMaxSize().padding(5.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) = Label(text, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = modifier.padding(bottom = 10.dp))

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
