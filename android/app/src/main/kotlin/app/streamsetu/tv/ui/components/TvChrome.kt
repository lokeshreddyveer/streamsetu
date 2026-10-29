package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/*
 * The shared pieces every TV screen is made of, so Home, Movies, Series, Guide, Live TV and Settings share one title size, one way of showing actions that do not fit, one way of
 * heading a section, one way of saying "nothing here" or "it failed", one filter strip and one side panel. A screen that needs something else should add it here, not beside here.
 */

/** The title of a page with one supporting line (a count, a status) and the page's actions on the right. The title may use two lines; the supporting line never more than one. */
@Composable
fun TvPageHeader(title: String, modifier: Modifier = Modifier, subtitle: String? = null, actions: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold, maxLines = 2)
            if (!subtitle.isNullOrBlank()) Label(subtitle, Tokens.small, Tokens.textSecondary, maxLines = 1)
        }
        actions()
    }
}

/** The heading of a row or group on a page. */
@Composable
fun TvSectionHeading(title: String, modifier: Modifier = Modifier, count: Int? = null, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold)
        if (count != null) Label("%,d".format(count), Tokens.small, Tokens.textTertiary)
        trailing()
    }
}

/** One action of a page. [badge] is a short note beside the name (a number of active filters). */
data class TvAction(val label: String, val icon: ImageVector, val badge: String? = null, val onClick: () -> Unit)

/**
 * A page's actions. The ones in [primary] are always shown. The ones in [secondary] are shown too when everything fits the width this has (measured, with the text size taken into
 * account), and otherwise sit behind a More button that opens them as a menu.
 */
@Composable
fun TvActionBar(primary: List<TvAction>, modifier: Modifier = Modifier, secondary: List<TvAction> = emptyList(), moreLabel: String = "More") {
    var open by remember { mutableStateOf(false) }
    BoxWithConstraints(modifier) {
        val scale = maxOf(1f, LocalDensity.current.fontScale)
        fun width(a: TvAction) = 56f + a.label.length * 8.5f * scale + (a.badge?.length ?: 0) * 8f
        val everything = (primary + secondary).sumOf { width(it).toDouble() } + 8f * (primary.size + secondary.size)
        val fits = secondary.isEmpty() || everything <= maxWidth.value
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            primary.forEach { TvActionButton(it) }
            if (fits) secondary.forEach { TvActionButton(it) }
            else TvActionButton(TvAction(moreLabel, Icons.Filled.MoreHoriz, badge = secondary.mapNotNull { it.badge }.firstOrNull()) { open = true })
        }
    }
    if (open) ContextMenu(moreLabel, null, secondary.map { a -> MenuAction(a.label + (a.badge?.let { "  ·  $it" } ?: ""), a.icon) { a.onClick() } }, onClose = { open = false })
}

@Composable
private fun TvActionButton(a: TvAction) {
    Focusable(a.onClick, Modifier.heightIn(min = 40.dp), shape = RoundedCornerShape(Tokens.radius), container = Tokens.card.copy(alpha = 0.85f), scaleOnFocus = 1.04f) { f ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Image(a.icon, a.label, Modifier.size(18.dp), colorFilter = ColorFilter.tint(if (f) Color.White else Tokens.textSecondary))
            Label(a.label + (a.badge?.let { "  ·  $it" } ?: ""), Tokens.small, Tokens.text, FontWeight.Medium, maxLines = 1)
        }
    }
}

/** What a page shows instead of its content: it is loading, it is empty, or something failed. Never shows technical error text; an action (Retry, Add a connection) is optional. */
@Composable
fun TvStatusState(title: String, modifier: Modifier = Modifier, detail: String? = null, loading: Boolean = false, icon: ImageVector? = null, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().background(if (icon != null) Tokens.card else Color.Transparent, RoundedCornerShape(Tokens.radius)).padding(vertical = 12.dp, horizontal = if (icon != null) 16.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (loading) Spinner()
        if (icon != null) Image(icon, null, Modifier.size(28.dp), colorFilter = ColorFilter.tint(Tokens.warning))
        Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold, maxLines = 2)
        if (!detail.isNullOrBlank()) Label(detail, Tokens.body, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
        if (actionLabel != null && onAction != null) TvButton(actionLabel, onAction)
    }
}

/**
 * A strip of choices that scrolls sideways (categories, types) and keeps the one under the remote in view. [selected] is the chosen index, shown filled.
 */
@Composable
fun TvFilterBar(labels: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier, maxLabel: Dp = 200.dp) {
    val state = rememberLazyListState()
    val scope = rememberCoroutineScope()
    suspend fun reveal(index: Int) {
        val info = state.layoutInfo
        val v = info.visibleItemsInfo.firstOrNull { it.index == index }
        when {
            v == null -> state.scrollToItem(index)
            v.offset < info.viewportStartOffset -> state.animateScrollBy((v.offset - info.viewportStartOffset).toFloat())
            v.offset + v.size > info.viewportEndOffset -> state.animateScrollBy((v.offset + v.size - info.viewportEndOffset).toFloat())
        }
    }
    LaunchedEffect(selected, labels.size) { if (labels.isNotEmpty()) reveal(selected.coerceIn(0, labels.lastIndex)) }
    LazyRow(modifier, state = state, horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(horizontal = 4.dp)) {
        itemsIndexed(labels, key = { i, l -> "$i:$l" }) { i, label ->
            val on = i == selected
            Focusable({ onSelect(i) }, Modifier.heightIn(min = 38.dp), shape = RoundedCornerShape(50), container = if (on) Tokens.accent.copy(alpha = 0.22f) else Tokens.elevated, scaleOnFocus = 1.04f,
                onFocus = { if (it) scope.launch { reveal(i) } }) { _ ->
                Label(label, Tokens.small, Tokens.text, if (on) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).widthIn(max = maxLabel))
            }
        }
    }
}

/** A panel beside the page (details, a menu of options): one width, one background, one title, and it scrolls when its content is longer than the screen. */
@Composable
fun TvSidePanel(title: String, modifier: Modifier = Modifier, width: Dp = 380.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.width(width).fillMaxHeight().background(Tokens.panel).padding(horizontal = 20.dp, vertical = Tokens.safeVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Label(title, Tokens.heading, Tokens.text, FontWeight.Bold, maxLines = 2)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp), content = content)
    }
}
