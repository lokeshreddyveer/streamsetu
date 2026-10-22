package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.AIClient
import app.streamsetu.core.data.repo.AIProvider
import app.streamsetu.core.data.repo.WatchSuggestion
import app.streamsetu.core.data.repo.DebridAccount
import app.streamsetu.core.data.repo.DebridService
import app.streamsetu.core.data.repo.TraktApp
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sync.TraktService
import app.streamsetu.tv.ui.components.*
import kotlinx.coroutines.launch

/** Settings, Trakt and Debrid: the person's own keys, Trakt sign-in by code, the watchlist, and a box to play a link through a debrid account. */
@Composable
fun IntegrationsSettings(c: AppContainer, nav: app.streamsetu.tv.nav.Navigator) {
    AskAiSettings(c, nav)
    AiSettings(c)
    TraktSettings(c)
    DebridSettings(c)
}

@Composable
private fun TraktSettings(c: AppContainer) {
    val state by c.trakt.state.collectAsState()
    val message by c.trakt.message.collectAsState()
    var id by remember { mutableStateOf(c.trakt.app().clientId) }
    var secret by remember { mutableStateOf(c.trakt.app().secret) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    SettingGroup("Trakt", "Marks what you watch on Trakt and adds your Trakt watchlist to Watch Later. You use your own free Trakt app (trakt.tv/oauth/applications, with urn:ietf:wg:oauth:2.0:oob as the redirect), so nothing goes through us. Nothing is sent for a private watch or in a kids profile.") {
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(id, { id = it.trim() }, "Client ID", Modifier.fillMaxWidth()) }
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(secret, { secret = it.trim() }, "Client Secret", Modifier.fillMaxWidth(), secret = true) }
        ActionRow("Save keys", null, "Save", confirm = false, enabled = id.isNotBlank() && secret.isNotBlank()) { c.trakt.saveApp(TraktApp(id, secret)); result = "Saved." }
        when (val s = state) {
            TraktService.State.NotConfigured -> InfoRow("Add your keys to sign in", "")
            TraktService.State.SignedOut -> ActionRow("Sign in to Trakt", "A code is shown; you enter it on another device.", "Sign in", confirm = false) { c.trakt.beginSignIn() }
            is TraktService.State.WaitingForCode -> {
                InfoRow("Open ${s.url} on your phone or computer and enter", s.userCode)
                ActionRow("Cancel sign-in", null, "Cancel", confirm = false) { c.trakt.cancelSignIn() }
            }
            TraktService.State.SignedIn -> {
                InfoRow("Signed in to Trakt", "")
                ActionRow("Add my watchlist to Watch Later", if (busy) "Reading…" else null, "Add", confirm = false, enabled = !busy) {
                    busy = true; result = null
                    scope.launch {
                        result = try { val (added, found, total) = c.importTraktWatchlist(); if (total == 0) "Your Trakt watchlist is empty." else "Trakt lists $total. $found are in your library, $added added to Watch Later." } catch (e: Exception) { e.message }
                        busy = false
                    }
                }
                ActionRow("Sign out of Trakt", null, "Sign out", danger = true) { c.trakt.signOut() }
            }
        }
        ResultLine(result ?: message)
    }
}

@Composable
private fun DebridSettings(c: AppContainer) {
    var account by remember { mutableStateOf(c.debrid.load()) }
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    SettingGroup("Debrid", "Plays a link from a file host, or a magnet link, through your own debrid account. Your token is kept in encrypted storage and sent only to the service you choose.") {
        ChoiceRow("Service", options = DebridService.entries.map { it to it.title }, value = account.service) { account = account.copy(service = it) }
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(account.token, { account = account.copy(token = it.trim()) }, "API token (${account.service.tokenHelp})", Modifier.fillMaxWidth(), secret = true) }
        ActionRow("Save token", null, "Save", confirm = false) { c.debrid.save(account); status = if (account.isComplete) "Saved." else "Removed." }
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(input, { input = it }, "Paste a link or magnet link", Modifier.fillMaxWidth()) }
        ActionRow("Play", if (busy) "Working…" else null, "Play", confirm = false, enabled = !busy && account.isComplete && input.isNotBlank()) {
            busy = true; status = null
            scope.launch {
                try { c.playDebrid(input); input = "" } catch (e: Exception) { status = e.message }
                busy = false
            }
        }
        ResultLine(status)
    }
}

@Composable
private fun AiSettings(c: AppContainer) {
    var cfg by remember { mutableStateOf(c.ai.load()) }
    var status by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    SettingGroup("AI assistant", "Ask for something to watch in your own words. Only the words you type are sent: never your playlist address, your logins, or what you have watched. You bring your own key.") {
        ChoiceRow("AI", options = AIProvider.entries.map { it to it.title }, value = cfg.provider) { cfg = c.ai.load(it) }
        if (cfg.provider.needsKey) Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(cfg.key, { cfg = cfg.copy(key = it.trim()) }, "API key", Modifier.fillMaxWidth(), secret = true) }
        if (cfg.provider == AIProvider.OLLAMA) Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(cfg.base, { cfg = cfg.copy(base = it.trim()) }, "Address (http://192.168.1.20:11434)", Modifier.fillMaxWidth()) }
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(cfg.model, { cfg = cfg.copy(model = it.trim()) }, "Model (${cfg.provider.defaultModel})", Modifier.fillMaxWidth()) }
        InfoRow("Where to get it", "", cfg.provider.keyHelp)
        InfoRow("Cost and limits (${AIProvider.PRICES_AS_OF})", "", cfg.provider.pricing + " " + AIProvider.PRICES_NOTE + " Check " + cfg.provider.pricingUrl.removePrefix("https://") + " for today's figures.")
        ActionRow("Save", null, "Save", confirm = false) { c.ai.save(cfg); status = "Saved." }
        ActionRow("Test", if (testing) "Testing…" else null, "Test", confirm = false, enabled = !testing && cfg.isReady) {
            c.ai.save(cfg); testing = true; status = null
            scope.launch { status = try { AIClient(cfg).ask("Reply with the single word OK.", "Test"); "It works." } catch (e: Exception) { e.message }; testing = false }
        }
        ResultLine(status)
    }
}

@Composable
private fun AskAiSettings(c: AppContainer, nav: app.streamsetu.tv.nav.Navigator) {
    val kids = c.profiles.profiles.collectAsState().value.firstOrNull { it.id == c.profiles.activeId.value }?.kids == true
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var suggestion by remember { mutableStateOf<WatchSuggestion?>(null) }
    var found by remember { mutableStateOf<List<app.streamsetu.tv.FoundTitle>>(emptyList()) }
    val scope = rememberCoroutineScope()
    SettingGroup("Ask AI", "Describe what you feel like watching. The AI suggests titles, and the app looks for them in your own library on this device.") {
        when {
            kids -> InfoRow("The AI is not available in a kids profile.", "")
            !c.ai.load().isReady -> InfoRow("Choose an AI below first", "", "Add a key for ${c.ai.provider.title}.")
            else -> {
                Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(text, { text = it }, "A tense thriller, something light for the family, like Inception…", Modifier.fillMaxWidth()) }
                ActionRow("Ask", if (busy) "Thinking…" else "Using ${c.ai.provider.title}. Only what you type is sent.", "Ask", confirm = false, enabled = !busy && text.isNotBlank()) {
                    busy = true; error = null; suggestion = null; found = emptyList()
                    scope.launch {
                        try { val r = c.askWhatToWatch(text); suggestion = r.first; found = r.second } catch (e: Exception) { error = e.message }
                        busy = false
                    }
                }
                ResultLine(error)
                suggestion?.let { s ->
                    if (s.note.isNotEmpty()) InfoRow(s.note, "")
                    found.forEach { f -> ActionRow(f.title, listOfNotNull(if (f.isSeries) "Series" else "Movie", f.year?.toString()).joinToString(" · "), "Open", confirm = false) { f.open(nav) } }
                    if (found.isEmpty() && s.titles.isNotEmpty()) InfoRow("None of the suggestions are in your library", "", s.titles.joinToString(", "))
                }
            }
        }
    }
}
