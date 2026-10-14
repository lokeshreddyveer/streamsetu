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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import androidx.compose.ui.layout.ContentScale

@Composable
fun Label(text: String, size: androidx.compose.ui.unit.TextUnit = Tokens.body, color: Color = Tokens.text, weight: FontWeight = FontWeight.Normal,
          maxLines: Int = 1, modifier: Modifier = Modifier) {
    BasicText(text, modifier, style = TextStyle(color = color, fontSize = size, fontWeight = weight), maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

/** Anything the remote can land on: it grows and gets a cyan edge when focused, and reacts to OK. */
@Composable
fun Focusable(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(12.dp),
    container: Color = Tokens.surface,
    focusedContainer: Color = Tokens.surfaceHigh,
    scaleOnFocus: Float = 1.06f,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) scaleOnFocus else 1f, label = "focus-scale")
    Box(
        modifier
            .scale(scale)
            .clip(shape)
            .background(if (focused) focusedContainer else container)
            .border(BorderStroke(if (focused) 3.dp else 1.dp, if (focused) Tokens.accent else Tokens.border), shape)
            .onFocusChanged { focused = it.isFocused }
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick),
    ) { content(focused) }
}

@Composable
fun TvButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    Focusable(onClick, modifier, shape = RoundedCornerShape(10.dp), container = if (primary) Tokens.accent2 else Tokens.surface,
        focusedContainer = if (primary) Tokens.accent else Tokens.surfaceHigh, scaleOnFocus = 1.04f) { focused ->
        Row(Modifier.padding(horizontal = 22.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (icon != null) Image(icon, null, Modifier.size(22.dp), colorFilter = ColorFilter.tint(if (primary && focused) Color.Black else Tokens.text))
            Label(text, color = if (primary && focused) Color.Black else Tokens.text, weight = FontWeight.SemiBold)
        }
    }
}

/** A poster tile for movies and series. */
@Composable
fun PosterCard(title: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier, progress: Float = 0f, width: Dp = 150.dp) {
    Column(modifier.width(width), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Focusable(onClick, Modifier.fillMaxWidth().aspectRatio(2f / 3f)) {
            if (imageUrl.isNullOrBlank()) Box(Modifier.fillMaxSize(), Alignment.Center) { Label(title.take(2).uppercase(), 32.sp, Tokens.muted, FontWeight.Bold) }
            else AsyncImage(imageUrl, title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            if (progress > 0f) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(progress).height(4.dp).background(Tokens.accent))
        }
        Label(title, Tokens.small, Tokens.muted, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

@Composable
fun ChannelLogo(url: String?, name: String, size: Dp = 56.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(10.dp)).background(Tokens.surfaceHigh), Alignment.Center) {
        if (url.isNullOrBlank()) Label(name.take(2).uppercase(), 18.sp, Tokens.muted, FontWeight.Bold)
        else AsyncImage(url, name, Modifier.fillMaxSize().padding(4.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) = Label(text, Tokens.heading, Tokens.text, FontWeight.SemiBold, modifier = modifier.padding(bottom = 10.dp))

@Composable
fun EmptyState(title: String, message: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Column(modifier.fillMaxSize(), Arrangement.Center, Alignment.CenterHorizontally) {
        Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Label(message, Tokens.body, Tokens.muted, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
        if (action != null) { Spacer(Modifier.height(20.dp)); action() }
    }
}

/** A single-line text box that works with the on-screen keyboard and a remote. */
@Composable
fun TvTextField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, secret: Boolean = false, onDone: () -> Unit = {}) {
    var focused by remember { mutableStateOf(false) }
    Box(
        modifier.clip(RoundedCornerShape(10.dp)).background(Tokens.surface)
            .border(BorderStroke(if (focused) 3.dp else 1.dp, if (focused) Tokens.accent else Tokens.border), RoundedCornerShape(10.dp))
            .padding(horizontal = 18.dp, vertical = 14.dp),
    ) {
        if (value.isEmpty()) Label(placeholder, color = Tokens.muted)
        BasicTextField(
            value, onChange, Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
            textStyle = TextStyle(color = Tokens.text, fontSize = Tokens.body), singleLine = true, cursorBrush = SolidColor(Tokens.accent),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onDone() }),
        )
    }
}

@Composable
fun Spinner(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val a by t.animateFloat(0.3f, 1f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(700), androidx.compose.animation.core.RepeatMode.Reverse), label = "alpha")
    Box(modifier.size(28.dp).clip(RoundedCornerShape(50)).background(Brush.linearGradient(listOf(Tokens.accent.copy(alpha = a), Tokens.accent2.copy(alpha = a)))))
}
