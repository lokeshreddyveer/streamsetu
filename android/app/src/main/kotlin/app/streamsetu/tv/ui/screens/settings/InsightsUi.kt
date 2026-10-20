package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.db.Profile
import app.streamsetu.core.data.repo.*
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.core.model.MoviePlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.InsightAlarms
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val DIGEST_KEY = "weeklyDigest.on"
private const val USUAL_KEY = "usualEvening.on"

private fun prefs(c: AppContainer) = c.context.getSharedPreferences("insights", android.content.Context.MODE_PRIVATE)

/** The digest as it stands now: this week against the one before, the most watched, and subscriptions that need attention. */
suspend fun weeklyDigest(c: AppContainer): WeeklyDigest {
    val week = c.stats.compute(7)
    val fortnight = c.stats.compute(14).totalMs
    val notes = c.sources.sources.first().filter { !it.draft }.mapNotNull { s -> c.resolver.accountStatus(s.id)?.takeIf { it.level() != AccountStatus.Level.FINE }?.let { "${s.name}: ${it.summary()}" } }
    return WeeklyDigest.make(week, (fortnight - week.totalMs).coerceAtLeast(0), 0, notes)
}

/** What is usually watched at the usual time, from the last 28 days of watch time. */
suspend fun usualEvening(c: AppContainer): UsualPick? = UsualEvening.pick(c.db.extras().watchTimeSince(java.time.LocalDate.now().toEpochDay() - UsualEvening.LOOK_BACK_DAYS + 1), java.time.LocalDate.now())

/** Sets the Sunday digest and the usual-time reminder from the latest numbers; called when the app starts and when a switch changes. */
fun refreshInsightAlarms(c: AppContainer) {
    c.appScope.launch(Dispatchers.IO) {
        val p = prefs(c)
        if (p.getBoolean(DIGEST_KEY, false)) { val d = weeklyDigest(c); InsightAlarms.arm(c.context, InsightAlarms.DIGEST, InsightAlarms.nextSunday(), d.headline, d.notificationBody) } else InsightAlarms.cancel(c.context, InsightAlarms.DIGEST)
        val usual = usualEvening(c)
        if (p.getBoolean(USUAL_KEY, false) && usual != null) InsightAlarms.arm(c.context, InsightAlarms.USUAL, InsightAlarms.nextBefore(usual.hour), "Your usual time to watch is near",
            if (usual.title.isNotBlank()) "Last time around ${"%02d:00".format(usual.hour)}: ${usual.title}" else "Around ${"%02d:00".format(usual.hour)} is when you usually watch.")
        else InsightAlarms.cancel(c.context, InsightAlarms.USUAL)
    }
}

@Composable
fun WeeklyDigestSettings(c: AppContainer, nav: Navigator) {
    var digest by remember { mutableStateOf<WeeklyDigest?>(null) }
    var usual by remember { mutableStateOf<UsualPick?>(null) }
    var digestOn by remember { mutableStateOf(prefs(c).getBoolean(DIGEST_KEY, false)) }
    var usualOn by remember { mutableStateOf(prefs(c).getBoolean(USUAL_KEY, false)) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { digest = withContext(Dispatchers.IO) { weeklyDigest(c) }; usual = withContext(Dispatchers.IO) { usualEvening(c) } }
    val d = digest
    SettingGroup("Your week", "Worked out on this device from your watch time. The Sunday notification is written when the app opens, so it is as fresh as your last visit that week.") {
        if (d == null) InfoRow("Reading your week…", "") else {
            InfoRow(d.headline, "")
            if (d.lines.isEmpty()) InfoRow("Watch something and your week fills in here.", "")
            d.lines.forEach { InfoRow(it, "") }
        }
        ToggleRow("Send me this on Sunday evening", null, digestOn) { digestOn = it; prefs(c).edit().putBoolean(DIGEST_KEY, it).apply(); refreshInsightAlarms(c) }
    }
    val u = usual
    if (u != null) SettingGroup("Your usual time", "Learned from the last four weeks of what you watch, on this device.") {
        InfoRow(u.title.ifBlank { "Something you watch" }, "%02d:00".format(u.hour), "You often start around this time.")
        ActionRow("Play ${u.title.ifBlank { "it" }}", null, "Play", confirm = false) {
            scope.launch {
                when (u.kind) {
                    "CHANNEL" -> c.catalog.channel(u.itemId)?.let { app.streamsetu.tv.play(c, nav, ChannelPlayable(it)) }
                    "MOVIE" -> c.catalog.movie(u.itemId)?.let { app.streamsetu.tv.play(c, nav, MoviePlayable(it)) }
                    "SERIES" -> c.catalog.series(u.itemId)?.let { c.playSeries(it) }
                }
            }
        }
        ToggleRow("Remind me ten minutes before", null, usualOn) { usualOn = it; prefs(c).edit().putBoolean(USUAL_KEY, it).apply(); refreshInsightAlarms(c) }
    }
}

/** What StreamSetu keeps on this device and what it can send out, as it is now. */
@Composable
fun PrivacyReportSettings(c: AppContainer) {
    var report by remember { mutableStateOf<PrivacyReport?>(null) }
    LaunchedEffect(Unit) {
        report = withContext(Dispatchers.IO) {
            fun count(sql: String) = runCatching { c.db.openHelper.readableDatabase.query(sql).use { if (it.moveToFirst()) it.getInt(0) else 0 } }.getOrDefault(0)
            PrivacyReport.make(PrivacyReport.State(
                diagnosticsOn = false, hasTmdbKey = !c.credentials.load("tmdb.key").isNullOrBlank(), hasOpenSubtitles = !c.credentials.load("os.key").isNullOrBlank(), lanSync = c.lan.wanted,
                profileCount = c.profiles.profiles.value.size, historyCount = count("SELECT COUNT(*) FROM watch_log"), favoriteCount = count("SELECT COUNT(*) FROM favorites"),
                searchCount = count("SELECT COUNT(*) FROM search_history"), playlistCount = c.sources.sources.first().count { !it.draft }))
        }
    }
    val r = report ?: return
    fun label(s: PrivacyReport.Status) = when (s) { PrivacyReport.Status.ON -> "On"; PrivacyReport.Status.OFF -> "Off"; PrivacyReport.Status.WHEN_YOU_ASK -> "Only when you ask" }
    SettingGroup("Privacy report: kept on this device only", "This follows the privacy policy and shows your current settings. Nothing here is sent anywhere.") { r.stored.forEach { InfoRow(it.title, "", it.detail) } }
    SettingGroup("Privacy report: can leave this device") { r.sentOut.forEach { InfoRow(it.title, label(it.status), it.detail) } }
    SettingGroup("Never") { PrivacyReport.never.forEach { InfoRow(it, "") } }
}

private val dailyChoices = listOf(0 to "No limit", 30 to "30 minutes", 45 to "45 minutes", 60 to "1 hour", 90 to "90 minutes", 120 to "2 hours", 180 to "3 hours")
private val hourChoices = (0..23).map { it * 60 to "%02d:00".format(it) }

/** Daily time and night hours for each kids profile. Only shown from outside a kids profile. */
@Composable
fun ViewingLimitSettings(c: AppContainer, kids: List<Profile>) {
    kids.forEach { p ->
        var limit by remember(p.id) { mutableStateOf(c.viewingLimits.limit(p.id)) }
        fun save(l: ViewingLimit) { limit = l; c.viewingLimits.set(p.id, l) }
        SettingGroup("Viewing limits for ${p.name}", "Time counts while something plays in this profile. When it runs out, playback stops and the profile's PIN adds ${ViewingLimits.EXTRA_MINUTES} more minutes for the day. Today: ${(c.viewingLimits.secondsUsed(p.id, java.time.LocalDate.now().toEpochDay()) / 60).toInt()} minutes watched.") {
            ChoiceRow("Time each day", options = dailyChoices, value = limit.dailyMinutes) { save(limit.copy(dailyMinutes = it)) }
            ToggleRow("No watching at night", null, limit.bedtimeOn) { save(limit.copy(bedtimeOn = it)) }
            if (limit.bedtimeOn) {
                ChoiceRow("From", options = hourChoices, value = limit.bedtimeStart) { save(limit.copy(bedtimeStart = it)) }
                ChoiceRow("Until", options = hourChoices, value = limit.bedtimeEnd) { save(limit.copy(bedtimeEnd = it)) }
            }
        }
    }
}

/** Over everything when a kids profile has used its time, or it is night. The profile's PIN (a parent) adds time for the day. */
@Composable
fun ViewingBlockOverlay(c: AppContainer) {
    val block by c.viewingBlock.collectAsState()
    val b = block ?: return
    var asking by remember { mutableStateOf(false) }
    val first = remember { FocusRequester() }
    LaunchedEffect(b) { kotlinx.coroutines.delay(150); runCatching { first.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Tokens.background), Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Label(if (b is ViewingBlock.Bedtime) "It's time to rest" else "That's enough for today", Tokens.display, Tokens.text, FontWeight.Bold)
            Label(if (b is ViewingBlock.Bedtime) "Watching starts again at ${ViewingLimit.clock(b.untilMinuteOfDay)}." else "Your watching time for today is used up. See you tomorrow!", Tokens.row, Tokens.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                Focusable({ c.viewingBlock.value = null }, Modifier.focusRequester(first)) { Label("OK", Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 28.dp, vertical = 12.dp)) }
                if (b is ViewingBlock.DailyLimit) Focusable({ asking = true }) { Label("Ask a parent", Tokens.row, Tokens.text, modifier = Modifier.padding(horizontal = 28.dp, vertical = 12.dp)) }
            }
        }
    }
    if (asking) PinDialog(create = false, check = { c.profiles.checkPin(c.profiles.activeId.value, it) },
        onDone = { c.viewingLimits.grantExtra(c.profiles.activeId.value, java.time.LocalDate.now().toEpochDay()); asking = false; c.viewingBlock.value = null }, onClose = { asking = false })
}
