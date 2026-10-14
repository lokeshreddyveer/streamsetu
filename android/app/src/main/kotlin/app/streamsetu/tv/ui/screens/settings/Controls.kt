package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/** A titled block of rows. */
@Composable
fun SettingGroup(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Eyebrow(title, Modifier.padding(start = 4.dp, bottom = 8.dp))
        Column(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(18.dp)).padding(vertical = 6.dp, horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
        if (footer != null) Label(footer, Tokens.caption, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
    }
}

/**
 * The base of every row: title, explanation, a value on the right. A row that cannot be used says why, right under its title,
 * and does nothing when pressed (it never just looks dead).
 */
@Composable
fun SettingRow(title: String, detail: String? = null, value: String? = null, enabled: Boolean = true, reason: String? = null, danger: Boolean = false, switch: Boolean? = null, onClick: () -> Unit = {}) {
    Focusable(if (enabled) onClick else ({}), Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1.0f) { f ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Label(title, Tokens.row, if (!enabled) Tokens.textTertiary else if (danger) Tokens.danger else Tokens.text, FontWeight.Medium)
                if (detail != null) Label(detail, Tokens.caption, Tokens.textSecondary, maxLines = 3)
                if (!enabled && reason != null) Label(reason, Tokens.caption, Tokens.warning, maxLines = 3)
            }
            if (switch != null) Box(Modifier.width(48.dp).height(26.dp).background(if (!enabled) Color(0x14FFFFFF) else if (switch) Tokens.accent else Color(0x33FFFFFF), RoundedCornerShape(13.dp)).padding(3.dp)) {
                Box(Modifier.align(if (switch) Alignment.CenterEnd else Alignment.CenterStart).size(20.dp).background(Color.White, androidx.compose.foundation.shape.CircleShape))
            } else if (value != null) Label(value, Tokens.row, if (!enabled) Tokens.textTertiary else if (f) Tokens.accent else Tokens.textSecondary, FontWeight.Medium, maxLines = 2, modifier = Modifier.widthIn(max = 220.dp))
        }
    }
}

/** A setting with a short list of choices: OK opens the list with the current one ticked. */
@Composable
fun <T> ChoiceRow(title: String, detail: String? = null, options: List<Pair<T, String>>, value: T, enabled: Boolean = true, reason: String? = null, onChange: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingRow(title, detail, options.firstOrNull { it.first == value }?.second ?: "—", enabled, reason) { open = true }
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

@Composable
fun InfoRow(title: String, value: String, detail: String? = null) = SettingRow(title, detail, value)

/** A line of result text under a group (what an action just did). */
@Composable
fun ResultLine(text: String?) { if (text != null) Label(text, Tokens.small, Tokens.accent, maxLines = 4, modifier = Modifier.padding(start = 4.dp, top = 2.dp)) }
