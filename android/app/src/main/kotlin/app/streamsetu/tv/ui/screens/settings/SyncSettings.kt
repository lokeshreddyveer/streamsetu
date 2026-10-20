package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/** Settings, Sync on this network: favourites, Watch Later, collections and resume points shared directly with the person's other devices on the same Wi-Fi. */
@Composable
fun SyncSettings(c: AppContainer) {
    val lan = c.lan
    val scope = rememberCoroutineScope()
    val enabled by lan.enabled.collectAsState()
    val found by lan.found.collectAsState()
    val trusted by lan.trusted.collectAsState()
    val prompt by lan.prompt.collectAsState()
    val status by lan.status.collectAsState()
    val message by lan.message.collectAsState()
    var adding by remember { mutableStateOf(false) }
    DisposableEffect(adding) { lan.setPairing(adding); onDispose { lan.setPairing(false) } }
    LaunchedEffect(message) { if (message != null && message!!.endsWith("is now paired.")) adding = false }

    SettingGroup("Sync on this network", "Devices on the same Wi-Fi share favourites, Watch Later, collections and resume points directly with each other. No account and no server; nothing leaves your network. Pair each device once.") {
        ToggleRow("Sync on this network", "Works between Mac, iPhone, iPad, Android phones and Fire TV.", enabled) { lan.setEnabled(it, remember = true) }
    }
    if (!enabled) return
    SettingGroup("Devices") {
        InfoRow("Status", status)
        trusted.forEach { p ->
            ActionRow(p.name, if (found.any { it.id == p.id }) "On this network" else "Not here now", label = "Forget", danger = true) { lan.forget(p) }
        }
        ActionRow("Sync now", label = "Sync", confirm = false) { scope.launch { lan.syncNow() } }
        ActionRow(if (adding) "Stop adding" else "Add a device", if (adding) "Open Sync on this network on your other device and pick this one there, or pick that device below." else null, label = if (adding) "Stop" else "Add", confirm = false) { adding = !adding }
    }
    if (adding) {
        val p = prompt
        if (p != null) SettingGroup("Does ${p.peerName} show the same number?") {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) { Label(p.digits.chunked(3).joinToString(" "), Tokens.display, Tokens.accent, FontWeight.Bold) }
            ActionRow("They match", label = "Yes", confirm = false) { lan.answer(true) }
            ActionRow("They don't match", label = "No", danger = true, confirm = false) { lan.answer(false) }
        } else SettingGroup("Devices found") {
            val fresh = found.filter { f -> trusted.none { it.id == f.id } }
            if (fresh.isEmpty()) InfoRow("Looking…", "Nothing yet", "Both devices need to be on the same Wi-Fi with this screen open.")
            fresh.forEach { f -> ActionRow(f.name, null, label = "Pair", confirm = false) { scope.launch { lan.pair(f) } } }
            ResultLine(message)
        }
    }
}
