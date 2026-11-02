package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.streamsetu.core.addon.*
import app.streamsetu.core.data.repo.AddonRegistry
import app.streamsetu.core.data.repo.InstalledAddon
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import kotlinx.coroutines.launch

/** What was found at an address, waiting for the person to read it and decide. */
private class Pending(val text: String, val manifest: AddonManifest, val official: OfficialEntry? = null)

/**
 * Settings, Add-ons. An add-on is a small description of a service (where its catalog is, which servers it may use, how it signs in), never a program: nothing in it runs.
 * The description is read, shown and checked first; it is installed only when the person says so, and from then on it can talk only to the servers it named.
 */
@Composable
fun AddonsSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    var refresh by remember { mutableIntStateOf(0) }
    var installed by remember { mutableStateOf(emptyList<InstalledAddon>()) }
    LaunchedEffect(refresh) { installed = runCatching { c.addons.installed() }.getOrDefault(emptyList()) }
    var address by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<Pending?>(null) }
    var user by remember { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    fun say(e: Throwable) = (if (e is AddonException) e.message else "That did not work. Check the address and try again.").also { result = it }

    SettingGroup("Add an add-on", "An add-on can only talk to the servers its description names, only over https, and is given only the sign-in you type here. It cannot run anything on this device. Add only add-ons you trust: the service behind one can see which of its titles you ask for.") {
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(address, { address = it.trim(); pending = null }, "https://… address of the add-on description", Modifier.fillMaxWidth()) }
        ActionRow("Look it up", if (busy) "Reading…" else "Shows what it asks for before anything is installed.", "Look up", confirm = false, enabled = address.isNotBlank() && !busy) {
            busy = true; result = null; pending = null; user = ""; secret = ""          // a sign-in typed for one add-on is never carried to another
            scope.launch {
                try {
                    val (text, parsed) = c.addons.preview(address)
                    when (parsed) {
                        is ManifestResult.Valid -> pending = Pending(text, parsed.manifest)
                        is ManifestResult.Refused -> result = "Not installed. " + parsed.reasons.take(3).joinToString(" ")
                    }
                } catch (e: Exception) { say(e) }
                busy = false
            }
        }
        pending?.let { p ->
            val m = p.manifest
            InfoRow(m.name, if (p.official != null) "Official" else "Community", m.id)
            InfoRow("It provides", m.capabilitySet.joinToString(", ") { it.key }, "Titles and channels from its catalog" + if (AddonCapability.EPG in m.capabilitySet) ". It also declares a guide, which this version does not read." else "")
            InfoRow("Servers it may use", m.allowedHosts.joinToString(", "))
            InfoRow("Limits", "${m.limits.timeoutSeconds} s, ${m.limits.maxResponseBytes / (1024 * 1024)} MB per answer")
            if (m.auth != AddonAuth.NONE) {
                if (m.auth == AddonAuth.USERNAME_PASSWORD) Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(user, { user = it.trim() }, "User name", Modifier.fillMaxWidth()) }
                Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(secret, { secret = it.trim() }, if (m.auth == AddonAuth.TOKEN) "Token" else "Password", Modifier.fillMaxWidth(), secret = true) }
            }
            ActionRow("Install ${m.name}", "Kept in Libraries like any other connection. You can turn it off or remove it at any time.", "Install", confirm = true, enabled = !busy) {
                busy = true; result = null
                scope.launch {
                    try {
                        val a = if (p.official != null) c.addons.installOfficial(p.official, user, secret) else c.addons.install(p.text, AddonTrust.COMMUNITY, user, secret)
                        pending = null; address = ""; user = ""; secret = ""; refresh++
                        result = "${a.manifest.name} is installed. Reading its catalog…"
                        runCatching { c.sync.sync(a.source.id) }.onSuccess { r -> result = "${a.manifest.name}: ${r.channels} channels and ${r.movies} movies." }.onFailure { e -> result = "${a.manifest.name} is installed, but its catalog could not be read: " + (e.message ?: "unknown error") }
                    } catch (e: Exception) { say(e) }
                    busy = false; refresh++
                }
            }
        }
        ResultLine(result)
    }

    var official by remember { mutableStateOf<OfficialAddons.Resolved?>(null) }
    SettingGroup("Official add-ons", "The list is signed by StreamSetu. An add-on on it is installed only if its description is exactly the one that was approved.") {
        ActionRow("Show the official list", if (busy) "Reading\u2026" else null, "Show", confirm = false, enabled = !busy) {
            busy = true; result = null
            scope.launch {
                // What the app already has is shown at once, with no waiting for the network; the server is then asked, and the list changes only if it has a newer verified one.
                official = runCatching { c.addons.localOfficial() }.getOrNull()
                try { official = c.addons.refreshOfficial() } catch (e: Exception) { if (official == null) say(e) else result = "The list could not be refreshed. Showing the last verified list." }
                busy = false
            }
        }
        official?.let { r ->
            r.note?.let { InfoRow("Note", "", it) }
            if (r.entries.isEmpty()) InfoRow("No official add-ons have been published yet", "", "This is the checked list (${r.updated}), not a failure.")
        }
        official?.entries?.forEach { e ->
            ActionRow(e.name, "Review before installing", "Review", confirm = false, enabled = !busy) {
                busy = true; result = null; user = ""; secret = ""
                scope.launch {
                    try { val (text, parsed) = c.addons.previewOfficial(e); if (parsed is ManifestResult.Valid) pending = Pending(text, parsed.manifest, e) else result = "Not installed. The approved description did not pass the checks." } catch (x: Exception) { say(x) }
                    busy = false
                }
            }
        }
    }

    SettingGroup("Installed", if (installed.isEmpty()) "Nothing is installed." else null) {
        installed.forEach { a ->
            val s = a.source
            InfoRow("${a.manifest.name}  ·  ${a.trust.label}", if (!a.enabled) "Off" else s.status.name.lowercase().replaceFirstChar { it.uppercase() }, s.lastError?.takeIf { a.enabled && s.status == app.streamsetu.core.model.SyncStatus.FAILED })
            ToggleRow("Use ${a.manifest.name}", null, a.enabled) { on -> scope.launch { c.addons.setEnabled(a.manifest.id, on); refresh++ } }
            ActionRow("Read it again now", null, "Refresh", confirm = false, enabled = a.enabled && !busy) {
                busy = true; result = null
                scope.launch { runCatching { c.sync.sync(s.id) }.onSuccess { r -> result = "${a.manifest.name}: ${r.channels} channels and ${r.movies} movies." }.onFailure { e -> result = e.message ?: "Could not read ${a.manifest.name}." }; busy = false; refresh++ }
            }
            ActionRow("Clear what was read from it", "The add-on stays installed and is read again at the next refresh.", "Clear", confirm = true) { scope.launch { c.addons.clearCache(a.manifest.id); refresh++ } }
            ActionRow("Remove ${a.manifest.name}", "Deletes the add-on, everything read from it and its saved sign-in.", "Remove", danger = true) { scope.launch { c.addons.remove(a.manifest.id); refresh++ } }
        }
    }
}
