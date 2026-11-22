package app.streamsetu.tv.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.repo.OtherVersions
import app.streamsetu.tv.ui.screens.library.pressSpring
import app.streamsetu.tv.ui.screens.library.pressable
import app.streamsetu.tv.ui.screens.library.reducedMotion
import app.streamsetu.tv.ui.screens.library.softGlow
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage

// "Other languages" on the detail pages: the same film or show in its other languages, as a row of chips. Each chip has a small poster, the language in bold, the language in
// its own script (or "Dubbed") beneath it, and the quality as a small badge. The open version is first, outlined and ticked; the others open their own page. Everything
// follows the chosen theme and accent; a chip has a fixed width and its text is cut short inside it, so nothing runs past its edge.

/** What a screen reader says for one version: "Hindi, dubbed, FHD". */
private fun spoken(v: OtherVersions.Version) = listOfNotNull(v.label, if (v.current) "current version" else null).joinToString(", ")

/**
 * The row on a television. [versions] is null while the grouping is still running (a few quiet placeholder chips show then); hidden when there is no other version. Large
 * chips the remote moves along: focus is the accent ring, a soft glow and a springy lift, with room at both ends of the row so neither is cut off.
 */
@Composable
fun <T> TvOtherLanguages(versions: List<Pair<OtherVersions.Version, T>>?, poster: (T) -> String?, onOpen: (T) -> Unit) {
    if (versions != null && versions.size < 2) return
    Column {
        SectionHeading(versions?.size, tv = true)
        LazyRow(Modifier.bleedStart(16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(start = 16.dp, end = 24.dp, top = 12.dp, bottom = 12.dp)) {
            if (versions == null) items(3) { SkeletonChip(TvChipWidth, tv = true) }
            else items(versions, key = { it.first.id }) { (v, item) -> if (v.current) VersionChip(v, poster(item), TvChipWidth, tv = true) else TvVersionChip(v, poster(item)) { onOpen(item) } }
        }
    }
}

/** The row on a phone: chips that scroll sideways and come to rest on a chip, with the press feel of the app's start screens. */
@Composable
fun <T> PhoneOtherLanguages(versions: List<Pair<OtherVersions.Version, T>>?, poster: (T) -> String?, onOpen: (T) -> Unit, modifier: Modifier = Modifier) {
    if (versions != null && versions.size < 2) return
    Column(modifier) {
        Box(Modifier.padding(horizontal = 20.dp)) { SectionHeading(versions?.size, tv = false) }
        val state = rememberLazyListState()
        LazyRow(state = state, flingBehavior = rememberSnapFlingBehavior(state), horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp)) {
            if (versions == null) items(3) { SkeletonChip(PhoneChipWidth, tv = false) }
            else items(versions, key = { it.first.id }) { (v, item) ->
                if (v.current) VersionChip(v, poster(item), PhoneChipWidth, tv = false)
                else VersionChip(v, poster(item), PhoneChipWidth, tv = false, modifier = Modifier.pressable(Role.Button) { onOpen(item) })
            }
        }
    }
}

private val TvChipWidth = 236.dp
private val PhoneChipWidth = 176.dp

@Composable
private fun SectionHeading(count: Int?, tv: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Label("Other languages", if (tv) Tokens.heading else 17.sp, Tokens.text, FontWeight.SemiBold)
        if (count != null) Box(Modifier.background(Tokens.elevated, RoundedCornerShape(50)).padding(horizontal = 9.dp, vertical = 2.dp)) {
            Label("$count versions", if (tv) Tokens.small else 12.sp, Tokens.textSecondary, FontWeight.Medium)
        }
    }
}

/**
 * One chip. The open version ([OtherVersions.Version.current]) is outlined in the accent with a filled tick and sits a little raised; the others are a quiet surface with a
 * hairline. The text is cut short with an ellipsis inside the chip's fixed width.
 */
@Composable
private fun VersionChip(v: OtherVersions.Version, poster: String?, width: Dp, tv: Boolean, focused: Boolean = false, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(if (tv) 18.dp else 14.dp)
    val raised = if (v.current) Modifier.graphicsLayer { translationY = -2.dp.toPx() } else Modifier
    Box(modifier.then(raised).width(width)
        .clearAndSetSemantics { contentDescription = spoken(v) + if (v.current) "" else ". Opens this version." }
        .clip(shape).background(if (v.current) Tokens.accent.copy(alpha = 0.12f) else if (focused) Tokens.focusedSurface else Tokens.card)
        .border(if (v.current) 2.dp else 1.dp, if (v.current) Tokens.accent else Tokens.lineStrong, shape)) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.padding(top = 3.dp, start = 3.dp)) {
                Box(Modifier.size(if (tv) 48.dp else 44.dp, if (tv) 68.dp else 62.dp).clip(RoundedCornerShape(8.dp)).background(Tokens.elevated)) {
                    if (!poster.isNullOrBlank()) AsyncImage(poster, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                }
                if (v.current) Box(Modifier.align(Alignment.TopStart).offset((-4).dp, (-4).dp).size(18.dp).background(Tokens.accent, CircleShape), Alignment.Center) {
                    Image(Icons.Filled.Check, null, Modifier.size(12.dp), colorFilter = ColorFilter.tint(Tokens.onBright))
                }
            }
            Column(Modifier.weight(1f).padding(end = if (v.quality != null) 30.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Label(v.language ?: v.label, if (tv) 18.sp else 16.sp, Tokens.text, FontWeight.Bold)
                (v.native ?: if (v.current) "Now open" else null)?.let { Label(it, if (tv) 14.sp else 13.sp, Tokens.textSecondary) }
            }
        }
        v.quality?.let { q -> Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Tokens.accent.copy(alpha = 0.18f), RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 1.dp)) {
            Label(q, if (tv) 12.sp else 11.sp, Tokens.accent, FontWeight.Bold)
        } }
    }
}

/** A chip for the remote: the accent ring, a soft glow and a springy lift on focus (none with reduced motion). */
@Composable
private fun TvVersionChip(v: OtherVersions.Version, poster: String?, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val reduced = reducedMotion()
    val glow by animateFloatAsState(if (focused) 1f else 0f, if (reduced) snap() else tween(150), label = "chipGlow")
    val lift by animateFloatAsState(if (focused && !reduced) 1.05f else 1f, if (reduced) snap() else pressSpring(), label = "chipLift")
    Box(Modifier.graphicsLayer { scaleX = lift; scaleY = lift }.drawWithCache {
        val stroke = Stroke(3.dp.toPx()); val ring = 3.dp.toPx(); val corner = 18.dp.toPx()
        onDrawBehind { if (!Tokens.projector) softGlow(Tokens.accent, glow, corner, stroke, ring, rings = 4) }
    }) {
        Focusable(onClick, Modifier.semantics { role = Role.Button; onClick("Opens this version") { onClick(); true } }, shape = RoundedCornerShape(18.dp), container = Color.Transparent,
            focusedContainer = Color.Transparent, scaleOnFocus = 1f, ring = Tokens.accent, ringWidth = 3.dp, onFocus = { focused = it }) { f ->
            VersionChip(v, poster, TvChipWidth, tv = true, focused = f)
        }
    }
}

/** A placeholder chip with a soft light passing over it while the versions are still being found. It runs only while it is on screen; with reduced motion it is still. */
@Composable
private fun SkeletonChip(width: Dp, tv: Boolean) {
    val reduced = reducedMotion()
    val t = if (reduced) null else rememberInfiniteTransition(label = "skeleton").animateFloat(0f, 1f, infiniteRepeatable(tween(1200, easing = LinearEasing)), label = "shimmer")
    val shape = RoundedCornerShape(if (tv) 18.dp else 14.dp)
    Box(Modifier.width(width).height(if (tv) 84.dp else 78.dp).clip(shape).background(Tokens.card).drawWithCache {
        val band = size.width * 0.5f
        val light = Brush.horizontalGradient(0f to Color.Transparent, 0.5f to Color.White.copy(alpha = 0.06f), 1f to Color.Transparent, startX = 0f, endX = band)
        onDrawBehind {
            drawRect(Tokens.elevated.copy(alpha = 0.7f), Offset(8.dp.toPx(), 8.dp.toPx()), Size(44.dp.toPx(), size.height - 16.dp.toPx()))
            drawRect(Tokens.elevated.copy(alpha = 0.7f), Offset(62.dp.toPx(), size.height * 0.32f), Size(size.width * 0.42f, 10.dp.toPx()))
            drawRect(Tokens.elevated.copy(alpha = 0.5f), Offset(62.dp.toPx(), size.height * 0.56f), Size(size.width * 0.28f, 8.dp.toPx()))
            val p = t?.value ?: return@onDrawBehind
            translate(-band + (size.width + band) * p, 0f) { drawRect(light, Offset.Zero, Size(band, size.height)) }
        }
    })
}

/** The person's audio language (Settings), as the language name the grouping uses ("ta" becomes "tamil"), or null when none is set. */
fun preferredLanguage(c: app.streamsetu.tv.AppContainer): String? =
    c.settings.audioLanguage.value.takeIf { it.isNotBlank() }?.let { code -> java.util.Locale(code).getDisplayLanguage(java.util.Locale.ENGLISH).lowercase().takeIf { it.isNotBlank() && it != code.lowercase() } ?: code.lowercase() }

/**
 * The open version under the title of a detail page, "Hindi · Dubbed · FHD", so versions that share a poster and a story can be told apart at a glance. Hidden when nothing
 * about the version is known.
 */
@Composable
fun VersionPill(version: OtherVersions.Version?, tv: Boolean, modifier: Modifier = Modifier) {
    val v = version?.takeIf { it.label.isNotBlank() } ?: return
    Row(modifier.semantics { contentDescription = "This version: " + v.label }.background(Tokens.accent.copy(alpha = 0.14f), RoundedCornerShape(50)).border(1.dp, Tokens.accent.copy(alpha = 0.45f), RoundedCornerShape(50))
        .padding(horizontal = if (tv) 12.dp else 10.dp, vertical = if (tv) 4.dp else 3.dp), verticalAlignment = Alignment.CenterVertically) {
        Label(v.label, if (tv) Tokens.small else 13.sp, Tokens.text, FontWeight.SemiBold)
    }
}
