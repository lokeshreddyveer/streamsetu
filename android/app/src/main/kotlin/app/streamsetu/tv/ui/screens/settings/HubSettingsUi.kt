package app.streamsetu.tv.ui.screens.settings

import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.hub.HubAccess
import app.streamsetu.core.data.hub.HubAttribution
import app.streamsetu.core.data.hub.HubHttp
import app.streamsetu.core.data.hub.HubSource
import app.streamsetu.core.data.hub.HubTester
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.hub.HubRuntime
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.TvTextField
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The words of Settings > Artwork and details for the extra sources. The only place (with the Credits group) where a service is named; the same wording as the Apple app. */
object HubSettingsText {
    class Card(val source: HubSource, val title: String, val help: String, val keyLabel: String?)
    val cards = listOf(
        Card(HubSource.FANART, "fanart.tv", "Extra logos, backgrounds and posters. Asked only for a title you open or see, once per title. Your own free personal key is optional: it is sent in addition to the app's key and new images from the community reach you in 2 days instead of 7.", "Your fanart.tv personal key (optional)"),
        Card(HubSource.TVDB, "TheTVDB", "Episode details and artwork for series. On by default with the app's key; you can switch it off here or use your own TheTVDB subscriber key (and PIN).", "Your TheTVDB subscriber key"),
        Card(HubSource.TVMAZE, "TVmaze", "Next-episode dates, seasons and schedules for series. Needs no key and sends only a show id.", null),
    )
    /** The same words as legal/licenses.md (the TMDB logo and notice are shown above these lines, by TmdbNotice). */
    val credits = listOf(HubAttribution.FANART_CREDIT + " (" + HubAttribution.FANART_LINK.removePrefix("https://") + ")", HubAttribution.TVDB_CREDIT + " (" + HubAttribution.TVDB_LINK.removePrefix("https://") + ")", HubAttribution.TVMAZE_CREDIT, HubAttribution.IPTV_ORG_CREDIT, HubAttribution.WIKIDATA_CREDIT, HubAttribution.OPENSUBTITLES_CREDIT)
}

/** One card for each extra source: switch, own key, status, Test. */
@Composable
fun HubSourcesGroup(c: AppContainer) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var rev by remember { mutableIntStateOf(0) }
    SettingGroup("More sources", HubAttribution.KEEP_NOTE) {
        for (card in HubSettingsText.cards) {
            val a = remember(card.source) { HubRuntime.access(c, context, card.source) }
            var message by remember(card.source) { mutableStateOf<String?>(null) }
            var testing by remember(card.source) { mutableStateOf(false) }
            val on = remember(rev) { a.enabled }
            ToggleRow(card.title, card.help, on) { a.enabled = it; if (!it) scope.launch(Dispatchers.IO) { c.db.hub().purgeSource(card.source.key) }; message = null; rev++ }
            Label(remember(rev) { a.statusLine }, app.streamsetu.tv.ui.theme.Tokens.small, Tokens.textSecondary, modifier = Modifier.padding(start = 12.dp, bottom = 4.dp))
            if (card.keyLabel != null) {
                var key by remember(card.source) { mutableStateOf("") }
                TvTextField(key, { key = it.trim() }, if (remember(rev) { a.ownKey != null }) "Replace key" else card.keyLabel, Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), secret = true)
                if (card.source == HubSource.TVDB) {
                    var pin by remember { mutableStateOf("") }
                    TvTextField(pin, { pin = it.trim() }, if (remember(rev) { a.pin != null }) "Replace PIN" else "PIN", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), secret = true)
                    if (pin.isNotEmpty()) ActionRow("Save PIN", null, "Save", confirm = false) { HubRuntime.secrets(c).set(HubAccess.TVDB_PIN_ACCOUNT, pin); pin = ""; HubRuntime.secrets(c).set(HubAccess.TVDB_TOKEN_ACCOUNT, null); rev++; message = "Key saved." }
                }
                if (key.isNotEmpty()) ActionRow("Save key", null, "Save", confirm = false) { a.setOwnKey(key); if (card.source == HubSource.TVDB) HubRuntime.secrets(c).set(HubAccess.TVDB_TOKEN_ACCOUNT, null); key = ""; rev++; message = "Key saved." }
                if (remember(rev) { a.ownKey != null }) ActionRow("Remove key", "Your key is saved on this device.", "Remove", confirm = false) {
                    a.setOwnKey(null); if (card.source == HubSource.TVDB) { HubRuntime.secrets(c).set(HubAccess.TVDB_PIN_ACCOUNT, null); HubRuntime.secrets(c).set(HubAccess.TVDB_TOKEN_ACCOUNT, null) }; rev++; message = "Your key was removed."
                }
            }
            ActionRow("Test " + card.title, message ?: "Asks once whether this source accepts its key.", if (testing) "Testing…" else "Test", confirm = false, enabled = !testing) {
                testing = true; message = "Checking…"
                scope.launch { message = withContext(Dispatchers.IO) { HubTester.check(card.source, a, HubRuntime.secrets(c), HubHttp).second }; testing = false; rev++ }
            }
        }
        Label(HubAttribution.PRIVACY, Tokens.small, Tokens.textTertiary, maxLines = 6, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
    }
}

/** Settings > About > Credits: the one place every service the app uses is named, each with the notice it requires (TMDB logo and notice first). */
@Composable
fun ServiceCredits() {
    SettingGroup("Credits") { TmdbNotice(); for (t in HubSettingsText.credits) Label(t, Tokens.small, Tokens.textSecondary, maxLines = 3, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) }
}
