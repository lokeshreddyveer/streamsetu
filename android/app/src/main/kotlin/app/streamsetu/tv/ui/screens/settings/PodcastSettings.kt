package app.streamsetu.tv.ui.screens.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.UrlPlayable
import app.streamsetu.core.podcast.PodcastFeed
import app.streamsetu.core.podcast.PodcastSub
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.TvTextField
import kotlinx.coroutines.launch

/** Settings, Podcasts: the shows followed, a search of Apple's public directory (or a pasted feed address), and the episodes of a show. */
@Composable
fun PodcastSettings(c: AppContainer, nav: Navigator) {
    val service = c.podcasts
    val scope = rememberCoroutineScope()
    val following by service.subscriptions.collectAsState()
    var term by remember { mutableStateOf("") }
    var found by remember { mutableStateOf<List<PodcastSub>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    var open by remember { mutableStateOf<PodcastSub?>(null) }
    var feed by remember { mutableStateOf<PodcastFeed?>(null) }
    var shown by remember { mutableStateOf(30) }

    fun openShow(s: PodcastSub) { open = s; feed = null; shown = 30; msg = null; scope.launch { runCatching { service.load(s.feedUrl) }.onSuccess { feed = it }.onFailure { msg = it.message } } }

    val show = open
    if (show != null) {
        SettingGroup(show.title, show.author.ifBlank { null }) {
            ActionRow("Back to podcasts", label = "Back", confirm = false) { open = null; feed = null }
            val isFollowing = following.any { it.feedUrl == show.feedUrl }
            ActionRow(if (isFollowing) "Unfollow" else "Follow", label = if (isFollowing) "Unfollow" else "Follow", confirm = false) {
                if (isFollowing) service.unfollow(show.feedUrl) else scope.launch { runCatching { service.follow(show.feedUrl) }.onFailure { msg = it.message } }
            }
        }
        val f = feed
        if (f == null) SettingGroup("Episodes") { InfoRow(if (msg == null) "Loading…" else "Could not load", msg ?: "") }
        else SettingGroup("${f.episodes.size} episodes") {
            f.episodes.take(shown).forEach { e ->
                val length = e.durationSec?.let { s -> if (s >= 3600) "${s / 3600} h ${(s % 3600) / 60} min" else "${maxOf(s / 60, 1)} min" }
                val date = e.publishedMs?.let { java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(it)) }
                ActionRow(e.title, listOfNotNull(date, length).joinToString("  ·  ").ifBlank { null }, "Play", confirm = false) { play(c, nav, UrlPlayable(e.itemId, e.title, e.audioUrl, f.artwork)) }
            }
            if (f.episodes.size > shown) ActionRow("Show more", label = "More", confirm = false) { shown += 30 }
        }
        return
    }
    SettingGroup("Following", "Follow shows and play their episodes. Your place in each episode is remembered. Search uses Apple's public podcast directory; nothing about you is sent besides the words you search for.") {
        if (following.isEmpty()) InfoRow("No shows yet", "")
        following.forEach { s -> ActionRow(s.title, s.author.ifBlank { null }, "Open", confirm = false) { openShow(s) } }
    }
    SettingGroup("Find a show") {
        Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) { TvTextField(term, { term = it }, "Search, or paste a feed address", Modifier.fillMaxWidth()) }
        ActionRow("Search", label = if (busy) "…" else "Search", confirm = false, enabled = term.isNotBlank() && !busy) {
            busy = true; msg = null; found = emptyList()
            scope.launch {
                val words = term.trim()
                runCatching {
                    if (words.startsWith("http://") || words.startsWith("https://")) { val s = service.follow(words); term = ""; msg = "Following ${s.title}." }
                    else { found = service.search(words); if (found.isEmpty()) msg = "No shows found." }
                }.onFailure { msg = it.message ?: "That did not work." }
                busy = false
            }
        }
        found.forEach { s -> ActionRow(s.title, s.author.ifBlank { null }, "Open", confirm = false) { openShow(s) } }
        ResultLine(msg)
    }
}
