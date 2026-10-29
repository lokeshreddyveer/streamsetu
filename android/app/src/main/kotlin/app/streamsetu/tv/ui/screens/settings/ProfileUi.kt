package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.db.Profile
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sync.SwitchResult
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

private val profileColors = listOf(Color(0xFFFF6B3D), Color(0xFF409EF2), Color(0xFF5CC77F), Color(0xFFB873F2), Color(0xFFF2B333), Color(0xFFE6619E))

@Composable
fun ProfileAvatar(p: Profile, size: Int = 88) {
    Box(Modifier.size(size.dp).background(profileColors[kotlin.math.abs(p.color) % profileColors.size], CircleShape), Alignment.Center) {
        Label(p.name.take(1).uppercase(), (size * 0.42f).dp.value.let { androidx.compose.ui.unit.TextUnit(it, androidx.compose.ui.unit.TextUnitType.Sp) }, Color.White, FontWeight.Bold)
    }
}

/** Asks for a PIN, then switches. Returns through [onResult] with whether the switch happened. */
@Composable
private fun SwitchWithPin(c: AppContainer, target: Profile, onDone: (Boolean) -> Unit) {
    val owner = c.profiles.pinOwnerFor(target.id)
    if (owner == null) { LaunchedEffect(target.id) { onDone(c.profiles.switchTo(target.id) == SwitchResult.Switched) }; return }
    var pin by remember { mutableStateOf<String?>(null) }
    PinDialog(create = false, check = { c.profiles.checkPin(owner, it) }, onDone = { entered -> pin = entered; onDone(c.profiles.switchTo(target.id, entered) == SwitchResult.Switched) }, onClose = { onDone(false) })
}

/** "Who's watching?", shown at the start when more than one profile exists. */
@Composable
fun ProfilePickerOverlay(c: AppContainer, onDone: () -> Unit) {
    val profiles by c.profiles.profiles.collectAsState()
    var choosing by remember { mutableStateOf<Profile?>(null) }
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(150); runCatching { first.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Tokens.background), Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(36.dp)) {
            Label("Who's watching?", Tokens.display, Tokens.text, FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                profiles.forEachIndexed { i, p ->
                    Focusable({ if (p.id == c.profiles.activeId.value) onDone() else choosing = p }, (if (i == 0) Modifier.focusRequester(first) else Modifier), shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp), container = Color.Transparent, focusedContainer = Tokens.focusedSurface) {
                        Column(Modifier.padding(14.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            ProfileAvatar(p); Label(p.name + if (p.kids) " · Kids" else "", Tokens.row, Tokens.text, FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
    choosing?.let { t -> SwitchWithPin(c, t) { ok -> choosing = null; if (ok) onDone() } }
}

/** Settings, Profiles. */
@Composable
fun ProfileSettings(c: AppContainer) {
    val profiles by c.profiles.profiles.collectAsState()
    val activeId by c.profiles.activeId.collectAsState()
    var switching by remember { mutableStateOf<Profile?>(null) }
    var adding by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var kids by remember { mutableStateOf(false) }
    var usePin by remember { mutableStateOf(false) }
    var pinDialog by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    SettingGroup("Profiles", "Each profile keeps separate favorites, collections, history and progress.") {
        profiles.forEach { p ->
            if (p.id == activeId) InfoRow(p.name, "In use now", if (p.kids) "Kids profile" else null)
            else {
                ActionRow(p.name, if (p.kids) "Kids" else if (p.hasPin) "Has a PIN" else null, label = "Switch", confirm = false) { switching = p }
                if (p.id != app.streamsetu.core.data.db.Profiles.MAIN) ActionRow("Remove ${p.name}", "Deletes this profile's favorites, collections and history.", label = "Remove", danger = true) { c.profiles.remove(p.id) }
            }
        }
        ActionRow("Add a profile", if (profiles.size >= app.streamsetu.core.data.db.Profiles.MAX) "Four profiles is the most." else null, label = "Add", confirm = false, enabled = profiles.size < app.streamsetu.core.data.db.Profiles.MAX) { adding = !adding }
    }
    if (adding) SettingGroup("New profile") {
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(name, { name = it }, "Name", Modifier.fillMaxWidth()) }
        ToggleRow("Kids profile", "Hides restricted folders and requires its PIN to leave.", kids) { kids = it }
        if (!kids) ToggleRow("Ask for a PIN to open this profile", null, usePin) { usePin = it }
        ActionRow("Create", if (kids || usePin) "Next you will choose a four-digit PIN." else null, label = "Create", confirm = false, enabled = name.isNotBlank()) {
            if (kids || usePin) pinDialog = true else { val ok = c.profiles.add(name, false, null) != null; msg = if (ok) null else "That name is already used."; if (ok) { adding = false; name = "" } }
        }
        ResultLine(msg)
    }
    if (pinDialog) PinDialog(create = true, check = { true }, onDone = { pin ->
        val ok = c.profiles.add(name, kids, pin) != null
        pinDialog = false; msg = if (ok) null else "That name is already used."
        if (ok) { adding = false; name = ""; kids = false; usePin = false }
    }, onClose = { pinDialog = false })
    switching?.let { t -> SwitchWithPin(c, t) { switching = null } }
    if (profiles.firstOrNull { it.id == activeId }?.kids != true) ViewingLimitSettings(c, profiles.filter { it.kids })
}
