package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.streamsetu.core.model.*
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.core.ui.motion.slideFade
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

data class MenuAction(val label: String, val icon: ImageVector, val enabled: Boolean = true, val run: () -> Unit)

/** The small menu opened by holding OK on a folder, poster or channel. */
@Composable
fun ContextMenu(title: String, subtitle: String? = null, actions: List<MenuAction>, onClose: () -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.MENU_OPEN); delay(80); runCatching { first.requestFocus() } }
    DisposableEffect(Unit) { onDispose { app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.MENU_CLOSE) } }
    // This menu usually opens while OK is still held; see [SelectKeyGuard].
    val guard = remember { SelectKeyGuard() }
    LaunchedEffect(Unit) { while (!guard.armed) { delay(60); guard.tick() } }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().onPreviewKeyEvent { e -> SelectKeyGuard.isSelect(e) && guard.swallow(SelectKeyGuard.isDown(e)) }, Alignment.Center) {
            Column(Modifier.width(300.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Label(title, Tokens.title, Tokens.text, FontWeight.Bold)
                if (subtitle != null) Label(subtitle, Tokens.small, Tokens.textSecondary)
                Spacer(Modifier.height(6.dp))
                val firstEnabled = actions.indexOfFirst { it.enabled }
                actions.forEachIndexed { idx, a ->
                    Focusable({ if (a.enabled) { onClose(); a.run() } else app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.ERROR) }, (if (idx == firstEnabled) Modifier.focusRequester(first) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f, selectSound = null) { _ ->
                        Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Image(a.icon, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(if (a.enabled) Tokens.accent else Tokens.textTertiary))
                            Label(a.label, Tokens.row, if (a.enabled) Tokens.text else Tokens.textTertiary)
                        }
                    }
                }
            }
        }
    }
}

/** A number pad the remote can use. [create] asks twice (new PIN); otherwise it checks the PIN. Wrong PINs shake nothing and simply ask again. */
@Composable
fun PinDialog(create: Boolean, check: (String) -> Boolean, onDone: (String) -> Unit, onClose: () -> Unit) {
    var entered by remember { mutableStateOf("") }
    var firstEntry by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(80); runCatching { first.requestFocus() } }
    fun press(d: String) {
        if (entered.length >= 4) return
        entered += d
        if (entered.length == 4) {
            val pin = entered; entered = ""
            when {
                !create -> if (check(pin)) onDone(pin) else { message = "That PIN is not right."; app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.ERROR) }
                firstEntry == null -> { firstEntry = pin; message = "Enter it once more to confirm." }
                firstEntry == pin -> onDone(pin)
                else -> { firstEntry = null; message = "The two PINs did not match. Start again." }
            }
        }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.width(250.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(if (create) (if (firstEntry == null) "Create a PIN" else "Confirm your PIN") else "Enter PIN", Tokens.title, Tokens.text, FontWeight.Bold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { repeat(4) { Box(Modifier.size(12.dp).background(if (it < entered.length) Tokens.accent else Tokens.elevated, RoundedCornerShape(50))) } }
                Label(message ?: if (create) "Four digits. Locked folders ask for it." else " ", Tokens.small, if (message != null) Tokens.warning else Tokens.textSecondary, maxLines = 2)
                listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("⌫", "0", "")).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        row.forEach { k ->
                            if (k.isEmpty()) Spacer(Modifier.size(width = 62.dp, height = 40.dp))
                            else Focusable({ if (k == "⌫") entered = entered.dropLast(1) else press(k) }, (if (k == "5") Modifier.focusRequester(first) else Modifier).size(width = 62.dp, height = 40.dp), scaleOnFocus = 1.04f) { _ ->
                                Box(Modifier.fillMaxSize(), Alignment.Center) { Label(k, Tokens.title, Tokens.text, FontWeight.SemiBold) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The sort side sheet: it slides in from the right edge, shows only the choices this catalog can honestly offer, and applies on request. */
@Composable
fun SortSheet(kind: ContentKind, current: SortSpec, availability: SortAvailability, onApply: (SortSpec) -> Unit, onClose: () -> Unit) {
    var draft by remember { mutableStateOf(current) }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { delay(100); runCatching { first.requestFocus() } }
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val fields = availability.offers(kind)
    fun natural(f: SortField) = when (f) {
        SortField.NAME -> "A to Z" to "Z to A"
        SortField.ADDED, SortField.YEAR, SortField.RECENTLY_WATCHED -> "Newest first" to "Oldest first"
        SortField.RATING -> "Highest first" to "Lowest first"
        else -> "As the provider lists" to "Reversed"
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.CenterEnd) {
            Column(
                Modifier.slideFade(shown, fromX = 40.dp, durationMs = Motion.SCREEN).padding(end = 16.dp).width(290.dp).fillMaxHeight(0.92f).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Label("Sort", Tokens.title, Tokens.text, FontWeight.Bold)
                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    item { Eyebrow("Order by", Modifier.padding(vertical = 4.dp)) }
                    items(fields, key = { it.name }) { f ->
                        val on = draft.field == f
                        Focusable({ draft = draft.copy(field = f) }, (if (on) Modifier.focusRequester(first) else Modifier).fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Label(f.label, Tokens.row, if (on) Tokens.accent else Tokens.text, modifier = Modifier.weight(1f))
                                if (on) Image(Icons.Filled.Check, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                            }
                        }
                    }
                    item { Eyebrow("Direction", Modifier.padding(top = 10.dp, bottom = 4.dp)) }
                    item {
                        val (a, b) = natural(draft.field)
                        Focusable({ draft = draft.copy(ascending = !draft.ascending) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
                            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Image(if (draft.ascending) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(Tokens.accent))
                                Label(if (draft.ascending) a else b, Tokens.row, Tokens.text)
                            }
                        }
                    }
                    item { Eyebrow("Also", Modifier.padding(top = 10.dp, bottom = 4.dp)) }
                    item { ToggleRow("Favorites first", draft.favoritesFirst) { draft = draft.copy(favoritesFirst = it) } }
                    if (kind != ContentKind.CHANNEL) item { ToggleRow("Unwatched first", draft.unwatchedFirst) { draft = draft.copy(unwatchedFirst = it) } }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TvButton("Apply", { onApply(draft); onClose() }, primary = true)
                    TvButton("Reset", { draft = SortSpec.defaultFor(kind) })
                }
            }
        }
    }
}

@Composable
fun ToggleRow(label: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Focusable({ onChange(!on) }, Modifier.fillMaxWidth(), scaleOnFocus = 1.0f) { _ ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Label(label, Tokens.row, Tokens.text, modifier = Modifier.weight(1f))
            Image(if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, Modifier.size(17.dp), colorFilter = ColorFilter.tint(if (on) Tokens.accent else Tokens.textTertiary))
        }
    }
}

/** Local corrections to a title and its picture. The provider's data is not changed, and "Use the provider's" removes the correction. */
@Composable
fun OverrideDialog(title: String, poster: String, onSave: (String, String) -> Unit, onReset: () -> Unit, onClose: () -> Unit) {
    var t by remember { mutableStateOf(title) }
    var p by remember { mutableStateOf(poster) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.width(380.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label("Edit details", Tokens.title, Tokens.text, FontWeight.Bold)
                Label("Only changes how it looks on this device. The provider's data is not touched.", Tokens.small, Tokens.textSecondary, maxLines = 2)
                TvTextField(t, { t = it }, "Title", Modifier.fillMaxWidth())
                TvTextField(p, { p = it }, "Picture address (optional)", Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TvButton("Save", { onSave(t, p) }, primary = true)
                    TvButton("Use the provider's", onReset)
                }
            }
        }
    }
}
