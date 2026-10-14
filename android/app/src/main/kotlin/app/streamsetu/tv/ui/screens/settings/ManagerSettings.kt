package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.data.repo.ViewingStatistics
import app.streamsetu.core.net.ChannelHealthCheck
import app.streamsetu.core.net.Health
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.Reminders
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/** "3 h 20 min", "45 min", "under a minute". */
fun duration(ms: Long): String {
    val min = ms / 60_000
    return when { min >= 60 -> "${min / 60} h ${min % 60} min"; min >= 1 -> "$min min"; ms > 0 -> "under a minute"; else -> "none" }
}

@Composable
fun StatisticsSettings(c: AppContainer) {
    var period by rememberSaveable { mutableIntStateOf(30) }
    var stats by remember { mutableStateOf<ViewingStatistics?>(null) }
    var msg by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(period, msg) { stats = c.stats.compute(period) }
    SettingGroup("What you have watched", "Time is counted while something is playing, and stays on this device. A stream left on overnight is not counted for more than the time it really played.") {
        ChoiceRow("Period", options = listOf(7 to "Last 7 days", 30 to "Last 30 days", 365 to "Last year", 0 to "Everything"), value = period) { period = it }
    }
    val s = stats
    if (s == null) { Loading(Modifier.height(80.dp)); return }
    if (s.isEmpty) { SettingGroup("Nothing yet") { InfoRow("No watch time in this period", "", "Play something and come back.") }; return }
    SettingGroup("Totals") {
        InfoRow("Total", duration(s.totalMs))
        InfoRow("Live TV", duration(s.liveMs)); InfoRow("Movies", duration(s.movieMs)); InfoRow("Series", duration(s.seriesMs))
        s.busiestHour?.let { h -> InfoRow("Busiest hour", java.text.SimpleDateFormat("h a", java.util.Locale.getDefault()).format(java.util.Calendar.getInstance().apply { set(java.util.Calendar.HOUR_OF_DAY, h) }.time)) }
    }
    SettingGroup("Last 14 days") {
        val max = (s.days.maxOfOrNull { it.second } ?: 0L).coerceAtLeast(1L)
        Row(Modifier.fillMaxWidth().height(84.dp).padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
            s.days.forEach { (_, ms) -> Box(Modifier.weight(1f).fillMaxHeight(), Alignment.BottomCenter) { Box(Modifier.fillMaxWidth().fillMaxHeight((ms.toFloat() / max).coerceIn(0.03f, 1f)).background(if (ms > 0) Tokens.accent else Tokens.elevated, RoundedCornerShape(3.dp))) } }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 8.dp)) {
            val f = java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault())
            Label(f.format(java.util.Date.from(s.days.first().first.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant())), Tokens.caption, Tokens.textTertiary, modifier = Modifier.weight(1f))
            Label("Today", Tokens.caption, Tokens.textTertiary)
        }
    }
    listOf("Most watched channels" to s.topChannels, "Most watched movies" to s.topMovies, "Most watched series" to s.topSeries).forEach { (title, top) ->
        if (top.isNotEmpty()) SettingGroup(title) { top.forEach { InfoRow(it.title, duration(it.ms)) } }
    }
    SettingGroup("Reset") { ActionRow("Clear statistics", "Removes the watch time kept on this device. Favorites, history and positions are not touched.", "Clear", danger = true) { scope.launch { c.stats.clear(); msg = "Statistics cleared." } } }
    ResultLine(msg)
}

@Composable
fun ChannelManagerSettings(c: AppContainer) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val sources by c.sources.sources.collectAsState(initial = emptyList())
    val withChannels = sources.filter { !it.draft && it.channelCount > 0 }
    var sourceId by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(withChannels.map { it.id }) { if (sourceId == null || withChannels.none { it.id == sourceId }) sourceId = withChannels.firstOrNull()?.id }
    var query by remember { mutableStateOf("") }
    val prefs by c.channelPrefs.all.collectAsState(initial = emptyList())
    val prefMap = remember(prefs) { prefs.associateBy { it.channelId } }
    var rows by remember { mutableStateOf<List<ChannelEntity>>(emptyList()) }
    LaunchedEffect(sourceId, query, prefs) { delay(200); rows = sourceId?.let { c.db.catalog().managerChannels(it, query.trim(), 60) }.orEmpty() }
    var health by remember { mutableStateOf<Map<String, Health>>(emptyMap()) }
    var checking by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<ChannelEntity?>(null) }
    var prompt by remember { mutableStateOf<Triple<ChannelEntity, Boolean, String>?>(null) }   // channel, true = guide id (false = name), start text
    var msg by remember { mutableStateOf<String?>(null) }

    if (withChannels.isEmpty()) { SettingGroup("Channels") { InfoRow("No live channels yet", "", "Add a connection with live TV, then manage its channels here.") }; return }
    SettingGroup("Channel Manager", "Hide channels you never watch, give one a better name, or tie it to the right guide channel. This only changes how things look on this device; a refresh of the playlist keeps your changes.") {
        if (withChannels.size > 1) ChoiceRow("Connection", options = withChannels.map { it.id to it.name }, value = sourceId ?: "") { sourceId = it; health = emptyMap() }
        TvTextField(query, { query = it }, "Find a channel by name", Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), leadingIcon = Icons.Filled.Search)
        ActionRow("Check the channels listed below", "Asks each one for its first few kilobytes, three at a time. Takes a minute or two. A channel that does not answer in time is not counted as dead.", if (checking) "Checking…" else "Check", confirm = false, enabled = !checking && rows.isNotEmpty()) {
            checking = true; health = emptyMap()
            scope.launch {
                val gate = Semaphore(3); val list = rows
                list.map { ch -> async(Dispatchers.IO) { gate.withPermit {
                    val url = c.resolver.resolve(ch.sourceId, ch.streamRef)
                    val h = if (url == null) Health.Dead("No address") else ChannelHealthCheck.check(url, c.resolver.headers(ch.sourceId), c.resolver.userAgent(ch.sourceId))
                    withContext(Dispatchers.Main) { health = health + (ch.id to h) }
                } } }.awaitAll()
                checking = false
                msg = "${health.values.count { it is Health.Dead }} dead, ${health.values.count { it is Health.Slow }} slow, ${health.values.count { it is Health.Silent }} did not answer in time."
            }
        }
        val dead = rows.filter { health[it.id] is Health.Dead && prefMap[it.id]?.hidden != true }
        if (dead.isNotEmpty()) ActionRow("Hide the ${dead.size} dead channels", "Only the ones that answered with an error. They can be shown again here.", "Hide", confirm = true) { scope.launch { c.channelPrefs.setHiddenMany(dead.map { it.id }, true); msg = "${dead.size} channels hidden." } }
    }
    ResultLine(msg)
    SettingGroup("Channels", if (rows.size >= 60) "The first 60 matches. Type in the box to narrow the list." else null) {
        if (rows.isEmpty()) InfoRow("No channel matches", "")
        rows.forEach { ch ->
            val p = prefMap[ch.id]
            val state = listOfNotNull(if (p?.hidden == true) "Hidden" else null, p?.name?.let { "Renamed" }, p?.epgId?.let { "Guide set" }, health[ch.id]?.label).joinToString(" · ")
            SettingRow(ch.name, if (ch.epgId.isNullOrBlank()) "No guide channel" else "Guide: ${ch.epgId}", state.ifBlank { "Shown" }) { menuFor = ch }
        }
    }
    menuFor?.let { ch ->
        val p = prefMap[ch.id]
        ContextMenu(ch.name, null, buildList {
            add(MenuAction(if (p?.hidden == true) "Show this channel" else "Hide this channel", if (p?.hidden == true) Icons.Filled.Visibility else Icons.Filled.VisibilityOff) { scope.launch { c.channelPrefs.setHidden(ch.id, p?.hidden != true) } })
            add(MenuAction("Rename…", Icons.Filled.Edit) { prompt = Triple(ch, false, ch.name) })
            add(MenuAction("Set the guide channel…", Icons.Filled.Schedule) { prompt = Triple(ch, true, ch.epgId.orEmpty()) })
            if (p != null) add(MenuAction("Undo my changes", Icons.Filled.Restore) { scope.launch { c.db.catalog().channel(ch.id)?.let { _ -> }; c.channelPrefs.reset(ch); msg = "Changes undone. The provider's name and guide id return after the next refresh." } })
        }, onClose = { menuFor = null })
    }
    prompt?.let { (ch, forGuide, start) ->
        var text by remember { mutableStateOf(start) }
        Dialog(onDismissRequest = { prompt = null }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize(), Alignment.Center) {
                Column(Modifier.widthIn(max = 420.dp).fillMaxWidth().padding(20.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(if (forGuide) "Guide channel for ${ch.name}" else "Rename ${ch.name}", Tokens.title, Tokens.text, FontWeight.Bold)
                    Label(if (forGuide) "The id the guide uses for this channel (the XMLTV channel id). Empty goes back to the provider's." else "Empty goes back to the provider's name.", Tokens.small, Tokens.textSecondary, maxLines = 3)
                    TvTextField(text, { text = it }, if (forGuide) "Guide channel id" else "Name", Modifier.fillMaxWidth())
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TvButton("Save", { scope.launch { if (forGuide) c.channelPrefs.mapGuide(ch, text) else c.channelPrefs.rename(ch, text) }; prompt = null }, primary = true)
                        TvButton("Cancel", { prompt = null })
                    }
                }
            }
        }
    }
}

/** The reminders that are set, with a way to cancel each. */
@Composable
fun RemindersSettings(c: AppContainer) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val list by c.db.extras().reminders().collectAsState(initial = emptyList())
    val time = remember { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT) }
    SettingGroup("Programme reminders", "Open the TV Guide, choose a programme that has not started, and pick Remind me. A notification arrives a minute before it starts.") {
        if (list.isEmpty()) InfoRow("No reminders set", "")
        list.forEach { r -> ActionRow(r.title, "${r.channelName} · ${time.format(Date(r.startMs))}", "Cancel", confirm = false) { scope.launch { Reminders.cancel(c, context, r.id) } } }
    }
}
