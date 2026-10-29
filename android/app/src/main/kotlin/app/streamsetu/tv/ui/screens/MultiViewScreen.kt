package app.streamsetu.tv.ui.screens

import androidx.activity.compose.BackHandler
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ChannelPlayable
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.sports.multiview.MultiviewEntry
import app.streamsetu.tv.sports.multiview.PresetFit
import app.streamsetu.tv.sports.multiview.PresetPlan
import app.streamsetu.tv.sports.multiview.TileStatus
import app.streamsetu.tv.sports.multiview.TileUi
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.phone.Sheet
import app.streamsetu.tv.ui.phone.SheetItem
import app.streamsetu.tv.ui.screens.sports.MultiviewTiles
import app.streamsetu.tv.ui.screens.sports.TileActions
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

private fun entryFor(ch: Channel) = MultiviewEntry(eventId = "", channelId = ch.id, sourceId = ch.sourceId, eventTitle = "", feedLabel = ch.name)

/**
 * Several live channels on one screen. It is the one Multi-View behind both entry points (this one and the Sports builder): the same session starts the pictures one after another, holds the
 * device's limit and picture-size cap, gives the sound to one of them, keeps a failed picture from stopping the others, and releases every player when the screen is left.
 *
 * The channel that was playing starts it; more are added up to what this device can show. A set of channels longer than that is never started or shortened behind the person's back: they choose
 * which to keep, and the set itself is left as it was.
 */
@Composable
fun MultiViewScreen(c: AppContainer, onClose: () -> Unit, onFullScreen: (Channel) -> Unit, onSports: (() -> Unit)? = null) {
    val ctl = c.sportsMultiview
    val session = ctl.session
    val mv by session.state.collectAsStateWithLifecycle()
    val owner = remember { Any() }
    val scope = rememberCoroutineScope()
    val limit = ctl.capability.usableLimit()
    var picking by remember { mutableStateOf(false) }
    var replacing by remember { mutableStateOf<TileUi?>(null) }
    var menu by remember { mutableStateOf<TileUi?>(null) }
    val sourceOf = remember { HashMap<String, String>() }
    val preset = remember { c.multiViewStart.map { sourceOf[it.id] = it.sourceId; entryFor(it) } }          // read, never changed
    val plan = remember(limit) { PresetFit.plan(preset, limit) }
    var chooserDone by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { if (limit >= 2 && !mv.active) (plan as? PresetPlan.Ready)?.let { session.start(it.entries, minimum = 1, owner = owner) } }
    DisposableEffect(Unit) { onDispose { session.stopAll(owner) } }
    BackHandler(enabled = true) { if (picking) { picking = false; replacing = null } else if (menu != null) menu = null else onClose() }

    // A channel that would go over the provider's limit waits for an answer first.
    var pendingWarn by remember { mutableStateOf<Pair<Channel, String>?>(null) }
    fun addNow(ch: Channel) { sourceOf[ch.id] = ch.sourceId; val r = replacing; if (r != null) { session.replace(r.id, entryFor(ch)); replacing = null } else session.add(entryFor(ch), owner) }
    fun requestAdd(ch: Channel) {
        val maxStreams = c.resolver.accountStatus(ch.sourceId)?.maxConnections
        val same = mv.tiles.count { sourceOf[it.channelId] == ch.sourceId }
        val warn = if (mv.tiles.none { it.channelId == ch.id }) app.streamsetu.core.data.repo.ConnectionAdvice.message(same, maxStreams) else null
        if (warn != null) pendingWarn = ch to warn else addNow(ch)
    }
    pendingWarn?.let { (ch, msg) ->
        ContextMenu("Your provider's limit", msg, listOf(MenuAction("Open anyway", Icons.Filled.PlayArrow) { addNow(ch) }, MenuAction("Cancel", Icons.Filled.Close) {}), onClose = { pendingWarn = null })
    }

    Column(Modifier.fillMaxSize().background(Color.Black).windowInsetsPadding(WindowInsets.systemBars)) {
        when {
            limit < 2 -> MultiviewUnsupported(onClose, c.multiViewStart.firstOrNull()?.let { ch -> { onFullScreen(ch) } })
            plan is PresetPlan.NeedsChoice && !mv.active && !chooserDone -> PresetChooser(plan.limit, plan.entries, onStart = { picked -> chooserDone = true; session.start(picked, minimum = 1, owner = owner) }, onCancel = onClose)
            else -> {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label("Multi-View", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.weight(1f))
                    Label("Up to $limit views on this device", Tokens.small, Tokens.textSecondary, modifier = Modifier.testTag("mvo-limit"))
                    if (onSports != null) TvButton("Sports events", onSports, icon = Icons.Filled.SportsScore)
                    if (mv.tiles.size < limit) TvButton("Add a channel", { picking = true }, icon = Icons.Filled.Add)
                    TvButton("Close", onClose, icon = Icons.Filled.Close)
                }
                val oneConnection = mv.tiles.mapNotNull { sourceOf[it.channelId] }.distinct().any { id -> c.resolver.allowsOnlyOneStream(id) && mv.tiles.count { sourceOf[it.channelId] == id } > 1 }
                if (oneConnection) Label("This provider allows one stream at a time, so only one of these will play.", Tokens.small, Tokens.warning, modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp), maxLines = 2)
                mv.message?.let { Label(it, Tokens.small, Tokens.warning, modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp).testTag("mvo-message"), maxLines = 2) }
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                    if (mv.tiles.isEmpty()) Box(Modifier.fillMaxSize(), Alignment.Center) { Label("Add a channel to begin", Tokens.body, Tokens.textSecondary) }
                    else MultiviewTiles(mv, { id, ctx -> session.viewFor(id, ctx) }, TileActions(
                        open = { menu = it }, retry = { session.retry(it.id) }, replace = { replacing = it; picking = true }, remove = { session.remove(it.id) },
                        useTwo = { session.useAtMost(2) }, keepOne = { session.useAtMost(1) }, toBuilder = onClose,
                    ), portrait = maxHeight > maxWidth)
                }
            }
        }
    }

    if (picking) {
        // The list the player was started from; when that is just one channel, the channels of the same connection.
        var pool by remember { mutableStateOf(c.queue.filterIsInstance<ChannelPlayable>().map { it.channel }) }
        LaunchedEffect(Unit) {
            if (pool.size <= 1) {
                val source = mv.tiles.firstNotNullOfOrNull { sourceOf[it.channelId] } ?: c.sources.all().firstOrNull { !it.draft && it.channelCount > 0 }?.id
                if (source != null) { val hidden = c.db.extras().hiddenChannelIds().toSet(); pool = c.db.catalog().managerChannels(source, "", 300).filter { it.id !in hidden }.map { it.toModel() } }
            }
        }
        val choices = pool.filter { ch -> mv.tiles.none { it.channelId == ch.id } }.take(200)
        Sheet(if (replacing != null) "Replace with" else "Add a channel", if (choices.isEmpty()) listOf(SheetItem("No other channels in this list", null, false) {}) else choices.map { ch -> SheetItem(ch.name, null, false) { requestAdd(ch) } }, onClose = { picking = false; replacing = null }, subtitle = "From the list you were watching")
    }
    menu?.let { t ->
        val slot = mv.tiles.indexOfFirst { it.id == t.id }
        if (slot >= 0) {
            val acts = ArrayList<MenuAction>()
            if (t.status == TileStatus.PLAYING && !t.audio) acts += MenuAction("Sound from this one", Icons.Filled.VolumeUp) { session.listenHere(t.id) }
            if (slot > 0) acts += MenuAction("Make primary", Icons.Filled.Fullscreen) { session.makePrimary(t.id) }
            if (t.status == TileStatus.PLAYING) acts += MenuAction("Watch full screen", Icons.Filled.Fullscreen) { scope.launch { c.catalog.channel(t.channelId)?.let { ch -> session.stopAll(owner); onFullScreen(ch) } } }
            if (t.status == TileStatus.FAILED) acts += MenuAction("Try again", Icons.Filled.Refresh) { session.retry(t.id) }
            acts += MenuAction("Remove", Icons.Filled.Close, danger = true) { session.remove(t.id) }
            ContextMenu(t.feedLabel, null, acts, onClose = { menu = null })
        }
    }
}

/** The whole set is longer than this device can show: the person picks which to keep. Nothing starts until they do, and the set itself is not changed. */
@Composable
fun PresetChooser(limit: Int, entries: List<MultiviewEntry>, onStart: (List<MultiviewEntry>) -> Unit, onCancel: () -> Unit) {
    var picked by remember { mutableStateOf(entries.take(limit).map { it.channelId }.toSet()) }
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical).testTag("mvo-chooser"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Label("This device can show $limit views at once.", Tokens.title, Tokens.text, FontWeight.Bold, modifier = Modifier.testTag("mvo-chooser-title"))
        Label("You have ${entries.size}. Choose up to $limit to keep; the rest stay in your list and are not started.", Tokens.body, Tokens.textSecondary)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(entries, key = { it.channelId }) { e ->
                val on = e.channelId in picked
                Focusable({ picked = if (on) picked - e.channelId else if (picked.size < limit) picked + e.channelId else picked }, Modifier.fillMaxWidth().testTag("mvo-pick-${e.channelId}"), shape = RoundedCornerShape(Tokens.radiusSmall), scaleOnFocus = 1.0f) {
                    Label((if (on) "✓  " else "     ") + e.feedLabel, Tokens.row, if (on) Tokens.text else Tokens.textSecondary, maxLines = 1, modifier = Modifier.padding(12.dp))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Start with ${picked.size}", { if (picked.isNotEmpty()) onStart(entries.filter { it.channelId in picked }) }, Modifier.testTag("mvo-chooser-start"), primary = picked.isNotEmpty())
            TvButton("Cancel", onCancel, Modifier.testTag("mvo-chooser-cancel"))
        }
    }
}

/** A device that cannot play two videos at once has no Multi-View; it says why and offers the one channel full screen. */
@Composable
fun MultiviewUnsupported(onClose: () -> Unit, watchOne: (() -> Unit)?) {
    Column(Modifier.fillMaxSize().padding(horizontal = Tokens.safeHorizontal, vertical = Tokens.safeVertical).testTag("mvo-unsupported"), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        Label("Multi-View is not available on this device.", Tokens.title, Tokens.text, FontWeight.Bold)
        Label("It cannot play more than one video at the same time.", Tokens.body, Tokens.textSecondary)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (watchOne != null) TvButton("Watch full screen", watchOne, Modifier.testTag("mvo-watch-one"), primary = true)
            TvButton("Close", onClose, Modifier.testTag("mvo-close"))
        }
    }
}
