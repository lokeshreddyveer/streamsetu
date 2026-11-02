package app.streamsetu.tv.ui.screens.settings

import app.streamsetu.tv.ui.theme.ui
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.draw.clip
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** The look of Settings, after macOS System Settings: its blue and green, its calm type, inset rounded groups with hairlines between the rows. */
object Mac {
    // the selected row, the pills and the switches follow the chosen accent colour; the rest is neutral
    val blue get() = Tokens.accent; val blueSelected get() = Tokens.accent; val green get() = Tokens.accent
    val indigo = Color(0xFF5E5CE6); val pink = Color(0xFFFF375F); val gray = Color(0xFF8E8E93)
    val red get() = if (Tokens.projector) Tokens.danger else Color(0xFFFF453A)
    val orange = Color(0xFFFF9F0A); val purple = Color(0xFFBF5AF2); val teal = Color(0xFF40C8E0)
    // The grey-on-page layers of Settings: a lighter tint in Projector Mode, so a group stays a visible block on the page and the row the remote is on shows as one.
    val card get() = if (Tokens.projector) Color(0x2BFFFFFF) else Color(0x12FFFFFF)
    val hairline get() = if (Tokens.projector) Color(0x3DFFFFFF) else Color(0x1AFFFFFF)
    val focus get() = if (Tokens.projector) Color(0x52FFFFFF) else Color(0x2EFFFFFF)
    val rowTitle = 14.sp; val rowDetail = 12.sp; val groupTitle = 12.sp; val pageTitle = 26.sp
}

/** Rows of one group count themselves, so every row but the first draws a hairline above it. */
internal val LocalGroupCounter = androidx.compose.runtime.compositionLocalOf<java.util.concurrent.atomic.AtomicInteger?> { null }

/** A titled block of rows. */
@Composable
fun SettingGroup(title: String, footer: String? = null, danger: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    // A danger group (erase, reset) is set apart at the bottom of its page, tinted red, so it is never taken for an ordinary section.
    val counter = remember { java.util.concurrent.atomic.AtomicInteger() }
    Column(Modifier.fillMaxWidth().padding(top = if (danger) 22.dp else 14.dp)) {
        Label(title, Mac.groupTitle, if (danger) Mac.red else Tokens.textSecondary, FontWeight.SemiBold, modifier = Modifier.padding(start = 12.dp, bottom = 6.dp))
        androidx.compose.runtime.CompositionLocalProvider(LocalGroupCounter provides counter) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (danger) Mac.red.copy(alpha = 0.10f) else Mac.card, RoundedCornerShape(12.dp)).then(if (danger) Modifier.border(1.dp, Mac.red.copy(alpha = 0.40f), RoundedCornerShape(12.dp)) else Modifier), content = content)
        }
        if (footer != null) Label(footer, Mac.rowDetail, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(start = 12.dp, top = 6.dp))
    }
}

/** Asks one row of a Settings page, found by its title, to take the remote when it appears (Settings search opens a page this way). [done] is called once the row has it. */
class SettingFocusTarget(val title: String, val requester: androidx.compose.ui.focus.FocusRequester, val done: () -> Unit) {
    /** Set only when the row reports that it really has the focus. */
    @Volatile var landed = false
}
internal const val MAX_FOCUS_TRIES = 60          // about a second of frames; SettingsScreen then moves the remote to the page instead
/**
 * A lazy page builds only the rows near the screen, so a row far down does not exist to take the remote. This moves down the page a screenful at a time until the row has been built and says
 * it has the focus. The whole search is bounded (about a second of frames); when the row is not on the page at all, [onMissing] is called so the remote goes to the page instead.
 */
@Composable
fun SweepToSettingTarget(state: androidx.compose.foundation.lazy.LazyListState, target: SettingFocusTarget?, onMissing: () -> Unit = {}) {
    if (target == null) return
    LaunchedEffect(target) {
        var next = 0; var frames = 0
        while (!target.landed && frames < MAX_FOCUS_TRIES) {
            androidx.compose.runtime.withFrameNanos { }; frames++          // a row that is already on screen gets its own chance first
            if (target.landed) break
            val info = state.layoutInfo
            if (info.totalItemsCount == 0) continue
            if (next >= info.totalItemsCount) break
            state.scrollToItem(next); next += maxOf(1, info.visibleItemsInfo.size)
            androidx.compose.runtime.withFrameNanos { }; frames++          // the row that has just been built asks for the remote in this frame
        }
        if (!target.landed) onMissing()
    }
}

val LocalSettingFocus = androidx.compose.runtime.compositionLocalOf<SettingFocusTarget?> { null }

/**
 * The base of every row: title, explanation, a value on the right. A row that cannot be used says why, right under its title,
 * and does nothing when pressed (it never just looks dead).
 */
@Composable
fun SettingRow(title: String, detail: String? = null, value: String? = null, enabled: Boolean = true, reason: String? = null, danger: Boolean = false, switch: Boolean? = null, chevron: Boolean = false, button: Boolean = false, modifier: Modifier = Modifier, onClick: () -> Unit = {}) {
    val target = LocalSettingFocus.current?.takeIf { it.title == title }
    // The request is repeated, a frame at a time, until the row itself says it has the focus (it may not be laid out, or scrolled into view, yet); only then is the target let go.
    if (target != null) LaunchedEffect(target) {
        var tries = 0
        while (!target.landed && tries++ < MAX_FOCUS_TRIES) { runCatching { target.requester.requestFocus() }; androidx.compose.runtime.withFrameNanos { } }
        if (target.landed) target.done()
    }
    val position = LocalGroupCounter.current?.let { remember { it.getAndIncrement() } } ?: 1
    Focusable(if (enabled) onClick else ({}), modifier.fillMaxWidth().then(if (target != null) Modifier.focusRequester(target.requester) else Modifier), onFocus = { if (it && target != null) target.landed = true }, shape = RoundedCornerShape(0.dp), container = Color.Transparent, focusedContainer = Mac.focus, scaleOnFocus = 1.0f, showRing = false, style = app.streamsetu.tv.ui.components.TvFocusStyle.DENSE) { f ->
        Row(Modifier.heightIn(min = if (detail != null) 62.ui else 48.ui).drawBehind { if (position > 0) drawLine(Mac.hairline, androidx.compose.ui.geometry.Offset(14.dp.toPx(), 0f), androidx.compose.ui.geometry.Offset(size.width, 0f), 1.dp.toPx()) }.padding(horizontal = 14.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Label(title, Mac.rowTitle, if (!enabled) Tokens.textTertiary else if (danger) Mac.red else Tokens.text, FontWeight.Medium)
                if (detail != null) Label(detail, Mac.rowDetail, Tokens.textSecondary, maxLines = 2)
                if (!enabled && reason != null) Label(reason, Mac.rowDetail, Tokens.warning, maxLines = 2)
            }
            if (switch != null) SwitchControl(switch, enabled)
            else if (value != null && button) {
                // An action is a rounded-rectangle button at the right edge, blue while the remote is on its row, as on the Mac.
                Box(Modifier.background(if (!enabled) Color(0x14FFFFFF) else if (f) Mac.blueSelected else Color(0x26FFFFFF), RoundedCornerShape(8.dp)).padding(horizontal = 14.dp, vertical = 5.dp)) {
                    Label(value, Mac.rowTitle, if (!enabled) Tokens.textTertiary else if (danger && !f) Mac.red else Color.White, FontWeight.Medium, maxLines = 1)
                }
            } else if (value != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) { Label(value, Mac.rowTitle, if (!enabled) Tokens.textTertiary else Tokens.textSecondary, FontWeight.Normal, maxLines = 2, modifier = Modifier.widthIn(max = 240.dp)); if (chevron) Image(Icons.Filled.ChevronRight, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)) }
        }
    }
}

/** The switch: the track changes colour and the knob slides across, instead of jumping. */
@Composable
private fun SwitchControl(on: Boolean, enabled: Boolean) {
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    val t = androidx.compose.animation.core.animateFloatAsState(if (on) 1f else 0f, if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(app.streamsetu.core.ui.motion.Motion.SHORT, easing = app.streamsetu.core.ui.motion.Motion.Standard), label = "switchKnob")
    val track = androidx.compose.animation.animateColorAsState(if (!enabled) Color(0x14FFFFFF) else if (on) Mac.green else Color(0x40FFFFFF), if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(app.streamsetu.core.ui.motion.Motion.SHORT), label = "switchTrack")
    Box(Modifier.width(50.dp).height(28.dp).drawBehind { drawRoundRect(track.value, cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2)) }.padding(3.dp)) {
        Box(Modifier.graphicsLayer { translationX = t.value * 22.dp.toPx() }.size(22.dp).background(Color.White, androidx.compose.foundation.shape.CircleShape))
    }
}

/** A setting with a short list of choices: OK opens the list with the current one ticked. */
@Composable
fun <T> ChoiceRow(title: String, detail: String? = null, options: List<Pair<T, String>>, value: T, enabled: Boolean = true, reason: String? = null, onChange: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingRow(title, detail, options.firstOrNull { it.first == value }?.second ?: "—", enabled, reason, chevron = true) { open = true }
    if (open) ContextMenu(title, detail, options.map { (v, label) -> MenuAction(label + if (v == value) "   ✓" else "", if (v == value) Icons.Filled.Check else Icons.Filled.ChevronRight) { onChange(v) } }, onClose = { open = false })
}

@Composable
fun ToggleRow(title: String, detail: String? = null, on: Boolean, enabled: Boolean = true, reason: String? = null, onChange: (Boolean) -> Unit) =
    SettingRow(title, detail, if (on) "On" else "Off", enabled, reason, switch = on) { onChange(!on) }

/** A button-like row. A destructive one needs a second press within a few seconds; a small note says so. */
@Composable
fun ActionRow(title: String, detail: String? = null, label: String = "Run", danger: Boolean = false, confirm: Boolean = danger, enabled: Boolean = true, reason: String? = null, onRun: () -> Unit) {
    var armed by remember { mutableStateOf(false) }
    LaunchedEffect(armed) { if (armed) { delay(5000); armed = false } }
    SettingRow(title, if (armed) "Press again to confirm. Waiting 5 seconds." else detail, if (armed) "Confirm" else label, enabled, reason, danger, button = true) {
        if (confirm && !armed) armed = true else { armed = false; onRun() }
    }
}

/** Information with nothing to do: shown as a plain row, so the remote does not stop on it. */
@Composable
fun InfoRow(title: String, value: String, detail: String? = null) {
    val position = LocalGroupCounter.current?.let { remember { it.getAndIncrement() } } ?: 1
    // A line of facts can take the remote (nothing happens on OK), so a page made only of facts can still be scrolled with Up and Down: the remote walks the lines and the page follows it.
    // It is the cheapest focus target there is (one focus modifier and one fill drawn only while focused): a page has dozens of these and they are all composed at once.
    var focused by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused }.focusable()
        .drawBehind { if (focused) drawRect(Mac.focus); if (position > 0) drawLine(Mac.hairline, androidx.compose.ui.geometry.Offset(14.dp.toPx(), 0f), androidx.compose.ui.geometry.Offset(size.width, 0f), 1.dp.toPx()) }
        .padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Label(title, Mac.rowTitle, Tokens.text, FontWeight.Medium)
            if (detail != null) Label(detail, Mac.rowDetail, Tokens.textSecondary, maxLines = 2)
        }
        Label(value, Mac.rowTitle, Tokens.textSecondary, FontWeight.Normal, maxLines = 2, modifier = Modifier.widthIn(max = 240.dp))
    }
}

/** A line of result text under a group (what an action just did). */
@Composable
fun ResultLine(text: String?) { if (text != null) Label(text, Tokens.small, Tokens.accent, maxLines = 4, modifier = Modifier.padding(start = 4.dp, top = 2.dp)) }
