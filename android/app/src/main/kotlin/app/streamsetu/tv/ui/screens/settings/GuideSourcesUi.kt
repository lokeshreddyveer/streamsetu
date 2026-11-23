package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import app.streamsetu.core.data.guidehub.FreshLevel
import app.streamsetu.core.data.guidehub.GuideSourceStatus
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/**
 * Guide sources on the Live TV page: every guide the app reads with its health, an address field with a test, refresh now, and the public channel database. The guides the playlists bring
 * are listed too; only added guides can be switched off or removed. Works with the remote: every control is a row.
 */
@Composable
fun GuideSourcesSettings(c: AppContainer) {
    val scope = rememberCoroutineScope()
    var statuses by remember { mutableStateOf<List<GuideSourceStatus>>(emptyList()) }
    var name by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var msg by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var enrich by remember { mutableStateOf(c.guideHub.enrichmentEnabled) }
    fun reload() { scope.launch { statuses = runCatching { c.guideHub.statuses() }.getOrDefault(emptyList()) } }
    LaunchedEffect(Unit) { reload() }

    SettingGroup("Guide sources", "Your playlists' own guides are listed with any guide address you add. A channel without a guide of its own can use an added one. Credits: channel data from the public iptv-org database.") {
        if (statuses.isEmpty()) InfoRow("No guides yet", "")
        statuses.forEach { s ->
            InfoRow(s.name, s.summary, s.findings.filter { it.level != FreshLevel.FRESH && it.text != s.summary }.joinToString(" ") { it.text }.ifBlank { null })
            if (s.kind == "userXMLTV") {
                ToggleRow(s.name + " is used", null, s.enabled) { on -> scope.launch { c.guideHub.setEnabled(s.id, on); reload() } }
                ActionRow("Remove ${s.name}", "Takes this guide's programmes out. Your own channel matches to it go too.", "Remove", danger = true) { scope.launch { c.guideHub.removeSource(s.id); reload() } }
            }
        }
        ToggleRow("Fill missing logos, genres and countries", "Uses the public iptv-org channel list, downloaded once a day. Nothing from your library is sent. Locked, hidden, adult and kids channels are never touched.", enrich) { on ->
            enrich = on; c.guideHub.enrichmentEnabled = on
            scope.launch { if (!on) c.guideHub.undoEnrichment() else { busy = true; msg = "Reading the channel list…"; runCatching { c.guideHub.enrich(force = true) }.let { msg = if (it.isSuccess) "Channel list applied to ${it.getOrDefault(0)} channels." else "The channel list could not be read now." }; busy = false } }
        }
        Label("Guide name (optional)", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 12.dp, top = 6.dp))
        TvTextField(name, { name = it }, "Name", Modifier.fillMaxWidth().padding(horizontal = 12.dp))
        Label("Guide address (XMLTV, .xml or .xml.gz)", Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 12.dp, top = 6.dp))
        TvTextField(address, { address = it }, "https://…", Modifier.fillMaxWidth().padding(horizontal = 12.dp))
        ActionRow("Test the address", "Reads the start of the guide and says whether it is valid, how many channels and programmes it holds.", "Test", confirm = false, enabled = address.isNotBlank() && !busy) {
            scope.launch { busy = true; msg = c.guideHub.test(address).message; busy = false }
        }
        ActionRow("Add this guide", "The address is kept encrypted on this device. The guide is read right away.", "Add", confirm = false, enabled = address.isNotBlank() && !busy) {
            scope.launch {
                busy = true
                msg = try {
                    c.guideHub.addSource(name, address); name = ""; address = ""
                    val r = c.guideHub.refresh(force = true)
                    if (r.any { it.outcome == "empty" || it.outcome == "failed" }) "Guide added, but it could not be used. See the details above." else "Guide added."
                } catch (e: IllegalArgumentException) { e.message } catch (e: Exception) { "Could not add that guide." }
                busy = false; reload()
            }
        }
        ActionRow("Refresh all guides", "Reads every added guide and the public channel list again.", "Refresh", confirm = false, enabled = !busy) {
            scope.launch {
                busy = true; msg = "Refreshing…"
                val r = runCatching { c.guideHub.refresh(force = true) }
                msg = r.fold({ list -> if (list.isEmpty()) "Nothing to refresh." else if (list.any { it.outcome == "empty" || it.outcome == "failed" }) "Some guides could not be used. See the details above." else "Guides refreshed." }, { "Refreshing did not work now." })
                busy = false; reload()
            }
        }
    }
    ResultLine(msg)
}

/** A small dot on a channel in the TV Guide: the channel has programmes now. Nothing for a channel without a guide, so a long list stays quiet. */
@Composable
fun GuideDot(hasGuide: Boolean) {
    if (hasGuide) Box(Modifier.size(7.dp).background(Tokens.accent, CircleShape).semantics { contentDescription = app.streamsetu.tv.ui.i18n.I18n.tr("Guide available") })
}

/** The Live TV row indicator, as on the Mac and iPhone: green when the channel has a programme now, amber when it is matched to a guide that has nothing now, nothing when it has no guide. Not focusable: D-pad focus is untouched. */
enum class GuideAvailability(val label: String) {
    NONE("No guide"), MAPPED_EMPTY("Guide has no upcoming programmes"), NOW_NEXT("Guide available");
    companion object { fun of(mapped: Boolean, hasProgrammeNow: Boolean) = if (!mapped) NONE else if (hasProgrammeNow) NOW_NEXT else MAPPED_EMPTY }
}

@Composable
fun GuideDot(availability: GuideAvailability) {
    if (availability != GuideAvailability.NONE) Box(Modifier.size(7.dp).background(if (availability == GuideAvailability.NOW_NEXT) Tokens.success else Tokens.warning, CircleShape).semantics { contentDescription = app.streamsetu.tv.ui.i18n.I18n.tr(availability.label) })
}

/** "The guide was last updated 3 days ago": shown at the top of the TV Guide when a guide needs attention. Hidden for a day once dismissed. */
@Composable
fun GuideFreshnessBanner(c: AppContainer) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember { context.getSharedPreferences("guidehub", android.content.Context.MODE_PRIVATE) }
    var item by remember { mutableStateOf<GuideSourceStatus?>(null) }
    var dismissedKey by remember { mutableStateOf(prefs.getString("bannerDismissed", "") ?: "") }
    LaunchedEffect(Unit) {
        item = runCatching { c.guideHub.statuses() }.getOrDefault(emptyList())
            .filter { it.enabled && (it.freshness.level >= FreshLevel.WARNING || it.freshness.key == "guide.endsIn") }.maxByOrNull { it.freshness.level.ordinal }
    }
    val s = item ?: return
    val stamp = dismissedKey.split('|')
    val hidden = stamp.size == 2 && stamp[0] == s.freshness.key && System.currentTimeMillis() - (stamp[1].toLongOrNull() ?: 0) < 86_400_000L
    if (hidden) return
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp).background(Tokens.card, RoundedCornerShape(Tokens.radius)).padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Label(s.summary, Tokens.small, Tokens.text, modifier = Modifier.weight(1f))
        Focusable({ val k = "${s.freshness.key}|${System.currentTimeMillis()}"; prefs.edit().putString("bannerDismissed", k).apply(); dismissedKey = k }, Modifier.padding(start = 8.dp), container = Tokens.elevated) { _ ->
            Label("Dismiss", Tokens.small, Tokens.text, FontWeight.Medium, modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
        }
    }
}

/** Channel Manager: pick the channel of an added guide that carries this channel's schedule, or remove the choice. A choice is never changed by automatic matching. */
@Composable
fun GuideMatchDialog(c: AppContainer, ch: ChannelEntity, onClose: () -> Unit, onDone: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var all by remember { mutableStateOf<List<Triple<String, String, String>>>(emptyList()) }
    var q by remember { mutableStateOf(app.streamsetu.core.data.repo.SearchText.normalize(ch.name)) }
    LaunchedEffect(Unit) { all = runCatching { c.guideHub.addedGuideChannels() }.getOrDefault(emptyList()) }
    val shown = remember(all, q) { val n = app.streamsetu.core.data.repo.SearchText.normalize(q); all.filter { n.isEmpty() || it.third.contains(n) || it.second.lowercase().contains(n) }.take(40) }
    TvDialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.widthIn(max = 620.dp).fillMaxWidth().padding(20.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radius)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label("Match a guide for ${ch.name}", Tokens.title, Tokens.text, FontWeight.Bold)
                Label("Pick the channel of an added guide that carries this channel's schedule. Matching by name never overrides your choice.", Tokens.small, Tokens.textSecondary)
                TvTextField(q, { q = it }, "Search guide channels", Modifier.fillMaxWidth())
                if (all.isEmpty()) Label("No added guide has channels yet. Add a guide in Settings, Live TV, Guide sources.", Tokens.small, Tokens.textTertiary)
                shown.forEach { (src, id, nm) -> SettingRow(nm, id, null) { scope.launch { c.guideHub.setUserMapping(ch.id, src, id); onDone("Guide matched."); onClose() } } }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Focusable({ scope.launch { c.guideHub.setUserMapping(ch.id, null, null); onDone("Guide match removed."); onClose() } }, container = Tokens.elevated) { _ -> Label("Remove my match", Tokens.small, Tokens.text, modifier = Modifier.padding(12.dp, 6.dp)) }
                    Focusable({ onClose() }, container = Tokens.elevated) { _ -> Label("Cancel", Tokens.small, Tokens.text, modifier = Modifier.padding(12.dp, 6.dp)) }
                }
            }
        }
    }
}
