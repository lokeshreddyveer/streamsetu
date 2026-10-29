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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** A titled block of rows. */
@Composable
fun SettingGroup(title: String, footer: String? = null, danger: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    // A danger group (erase, reset) is set apart at the bottom of its page, tinted red, so it is never taken for an ordinary section.
    Column(Modifier.fillMaxWidth().padding(top = if (danger) 24.dp else 8.dp)) {
        Label(title, Tokens.heading, if (danger) Tokens.danger else Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = 6.dp, bottom = 10.dp))
        Column(Modifier.fillMaxWidth().background(if (danger) Tokens.danger.copy(alpha = 0.10f) else Tokens.card, RoundedCornerShape(Tokens.radiusPanel)).then(if (danger) Modifier.border(1.dp, Tokens.danger.copy(alpha = 0.45f), RoundedCornerShape(Tokens.radiusPanel)) else Modifier).padding(vertical = 8.dp, horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp), content = content)
        if (footer != null) Label(footer, Tokens.caption, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
    }
}

/**
 * The base of every row: title, explanation, a value on the right. A row that cannot be used says why, right under its title,
 * and does nothing when pressed (it never just looks dead).
 */
@Composable
fun SettingRow(title: String, detail: String? = null, value: String? = null, enabled: Boolean = true, reason: String? = null, danger: Boolean = false, switch: Boolean? = null, chevron: Boolean = false, onClick: () -> Unit = {}) {
    Focusable(if (enabled) onClick else ({}), Modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radius), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1.015f) { f ->
        Row(Modifier.heightIn(min = if (detail != null) 80.ui else 62.ui).padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Label(title, Tokens.row, if (!enabled) Tokens.textTertiary else if (danger) Tokens.danger else Tokens.text, FontWeight.Medium)
                if (detail != null) Label(detail, Tokens.caption, Tokens.textSecondary, maxLines = 2)
                if (!enabled && reason != null) Label(reason, Tokens.caption, Tokens.warning, maxLines = 2)
            }
            if (switch != null) SwitchControl(switch, enabled) else if (value != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) { Label(value, Tokens.row, if (!enabled) Tokens.textTertiary else if (f) Tokens.accent else Tokens.textSecondary, FontWeight.Medium, maxLines = 2, modifier = Modifier.widthIn(max = 220.dp)); if (chevron) Image(Icons.Filled.ChevronRight, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.textTertiary)) }
        }
    }
}

/** The switch: the track changes colour and the knob slides across, instead of jumping. */
@Composable
private fun SwitchControl(on: Boolean, enabled: Boolean) {
    val reduced = app.streamsetu.core.ui.motion.LocalReducedMotion.current
    val t = androidx.compose.animation.core.animateFloatAsState(if (on) 1f else 0f, if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(app.streamsetu.core.ui.motion.Motion.SHORT, easing = app.streamsetu.core.ui.motion.Motion.Standard), label = "switchKnob")
    val track = androidx.compose.animation.animateColorAsState(if (!enabled) Color(0x14FFFFFF) else if (on) Tokens.accent else Color(0x33FFFFFF), if (reduced) androidx.compose.animation.core.snap() else androidx.compose.animation.core.tween(app.streamsetu.core.ui.motion.Motion.SHORT), label = "switchTrack")
    Box(Modifier.width(54.dp).height(30.dp).drawBehind { drawRoundRect(track.value, cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2)) }.padding(3.dp)) {
        Box(Modifier.graphicsLayer { translationX = t.value * 24.dp.toPx() }.size(24.dp).background(if (on) Tokens.onBright else Color.White, androidx.compose.foundation.shape.CircleShape))
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
    SettingRow(title, if (armed) "Press again to confirm. Waiting 5 seconds." else detail, if (armed) "Confirm" else label, enabled, reason, danger) {
        if (confirm && !armed) armed = true else { armed = false; onRun() }
    }
}

/** Information with nothing to do: shown as a plain row, so the remote does not stop on it. */
@Composable
fun InfoRow(title: String, value: String, detail: String? = null) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Label(title, Tokens.row, Tokens.text, FontWeight.Medium)
            if (detail != null) Label(detail, Tokens.caption, Tokens.textSecondary, maxLines = 2)
        }
        Label(value, Tokens.row, Tokens.textSecondary, FontWeight.Medium, maxLines = 2, modifier = Modifier.widthIn(max = 220.dp))
    }
}

/** A line of result text under a group (what an action just did). */
@Composable
fun ResultLine(text: String?) { if (text != null) Label(text, Tokens.small, Tokens.accent, maxLines = 4, modifier = Modifier.padding(start = 4.dp, top = 2.dp)) }
