package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.core.playback.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

private enum class SettingsPage(val title: String) { GENERAL("General"), PLAYBACK("Playback"), LIBRARY("Library"), ADVANCED("Advanced") }

private val languages = listOf("" to "Any", "en" to "English", "hi" to "Hindi", "te" to "Telugu", "ta" to "Tamil", "kn" to "Kannada", "ml" to "Malayalam", "ur" to "Urdu", "ar" to "Arabic", "es" to "Spanish", "fr" to "French")

/** Settings, laid out like the Mac's window: General, Playback, Library, Advanced; grouped rows with a title, an explanation and the current value. Every control saves at once. */
@Composable
fun SettingsScreen(vm: SettingsViewModel, c: AppContainer, nav: Navigator) {
    var page by rememberSaveable { mutableStateOf(SettingsPage.GENERAL.name) }
    val current = SettingsPage.valueOf(page)
    Row(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxHeight().width(Tokens.sidebarWidth).background(Tokens.panel)) {
            Column(Modifier.weight(1f).padding(8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                SettingsPage.entries.forEach { p ->
                    Focusable({ page = p.name }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall),
                        container = if (p == current) androidx.compose.ui.graphics.Color(0x0AFFFFFF) else androidx.compose.ui.graphics.Color.Transparent, focusedContainer = androidx.compose.ui.graphics.Color(0x1FFFFFFF), scaleOnFocus = 1.02f) { f ->
                        LaunchedEffect(f) { if (f && p != current) { kotlinx.coroutines.delay(250); page = p.name } }
                        Label(p.title, Tokens.row, if (p == current || f) Tokens.accent else Tokens.textSecondary, if (p == current) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                    }
                }
            }
            Box(Modifier.fillMaxHeight().width(1.dp).background(Tokens.line))
        }
        LazyColumn(Modifier.weight(1f).fillMaxHeight(), contentPadding = PaddingValues(start = 24.dp, top = 16.dp, end = Tokens.screenPadding, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { Label(current.title, Tokens.pageTitle, Tokens.text, FontWeight.SemiBold) }
            when (current) {
                SettingsPage.GENERAL -> general(c)
                SettingsPage.PLAYBACK -> playback(c)
                SettingsPage.LIBRARY -> library(vm, c, nav)
                SettingsPage.ADVANCED -> advanced(vm, c)
            }
        }
    }
}

// ---- building blocks -------------------------------------------------------------------------------------------------------------------

@Composable
private fun Group(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column {
        Eyebrow(title, Modifier.padding(start = 4.dp, bottom = 6.dp))
        Column(Modifier.fillMaxWidth().background(Tokens.card, RoundedCornerShape(Tokens.radiusPanel)), content = content)
        if (footer != null) Label(footer, Tokens.caption, Tokens.textTertiary, maxLines = 3, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
    }
}

/** One row: title and explanation on the left, the current value on the right. OK changes it. */
@Composable
private fun Row(title: String, detail: String? = null, value: String? = null, note: String? = null, onClick: () -> Unit = {}) {
    Focusable(onClick, Modifier.fillMaxWidth(), shape = RoundedCornerShape(Tokens.radiusSmall), container = androidx.compose.ui.graphics.Color.Transparent, scaleOnFocus = 1.01f) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f)) {
                Label(title, Tokens.row, Tokens.text, FontWeight.Medium)
                if (detail != null) Label(detail, Tokens.caption, Tokens.textSecondary, maxLines = 2)
                if (note != null) Label(note, Tokens.caption, Tokens.warning, maxLines = 2)
            }
            if (value != null) Label(value, Tokens.row, if (f) Tokens.accent else Tokens.textSecondary, FontWeight.Medium)
        }
    }
}

private fun <T> next(list: List<T>, now: T): T = list[(list.indexOf(now) + 1).mod(list.size)]

// ---- pages -----------------------------------------------------------------------------------------------------------------------------

private fun androidx.compose.foundation.lazy.LazyListScope.general(c: AppContainer) {
    item {
        val hide by c.parental.hideAdult.collectAsState()
        Group("Appearance") {
            Row("Theme", "StreamSetu uses the Obsidian theme, the same as the Mac app.", "Obsidian")
        }
    }
    item {
        val hide by c.parental.hideAdult.collectAsState()
        Group("Parental controls", "Hides folders whose names mark adult content, everywhere in the app.") {
            Row("Hide adult folders", "Folders named XXX, Adult, 18+ and similar are left out.", if (hide) "On" else "Off") { c.parental.setHideAdult(!hide) }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.playback(c: AppContainer) {
    val s = c.settings
    item {
        val pref by s.enginePreference.collectAsState()
        val available = c.playback.available
        Group("Player engine", "Automatic uses ExoPlayer for HLS, MP4, DASH and MPEG-TS, and MPV for MKV, AVI and RTSP. If a stream's format isn't supported, StreamSetu tries the other engine once.") {
            Row("Engine", "Automatic is recommended.", pref.label) { s.setEngine(next(EnginePreference.entries, pref)) }
            if (pref == EnginePreference.MPV && EngineKind.MPV !in available) Row("MPV is unavailable", "ExoPlayer will be used. MPV needs Android 8 or later.")
            Row("ExoPlayer", "Android's own player. HLS, MP4, DASH, MPEG-TS; hardware decoding.", "Available")
            Row("MPV", "Plays MKV with any audio, AVI, RTSP and unusual formats.", if (EngineKind.MPV in available) "Available" else "Not available")
        }
    }
    item {
        val mode by s.bufferingMode.collectAsState()
        Group("Buffering", "How much of the stream is read ahead. A larger buffer rides out a slow provider.") {
            Row("Mode", mode.detail, mode.label) { s.setBuffering(next(BufferingMode.entries, mode)) }
        }
    }
    item {
        val al by s.audioLanguage.collectAsState(); val sl by s.subtitleLanguage.collectAsState(); val sd by s.subtitlesByDefault.collectAsState()
        Group("Audio and subtitles") {
            Row("Audio language", "Chosen automatically when a stream offers several audio tracks. You can still switch (MENU).", languages.firstOrNull { it.first == al }?.second ?: "Any") { s.setAudioLanguage(next(languages.map { it.first }, al)) }
            Row("Subtitle language", "Used when subtitles are shown by default.", languages.firstOrNull { it.first == sl }?.second ?: "Any") { s.setSubtitleLanguage(next(languages.map { it.first }, sl)) }
            Row("Show subtitles by default", "Turns subtitles on when a track in your language exists.", if (sd) "On" else "Off") { s.setSubtitlesByDefault(!sd) }
        }
    }
    item {
        val pn by s.playNextAutomatically.collectAsState(); val rp by s.rememberPosition.collectAsState(); val ra by s.resumeAutomatically.collectAsState()
        Group("Behaviour") {
            Row("Play next episode automatically", "Only continues within the series you are watching.", if (pn) "On" else "Off") { s.setPlayNext(!pn) }
            Row("Remember playback position", "Saves where you stop in movies and episodes so Continue Watching works.", if (rp) "On" else "Off") { s.setRememberPosition(!rp) }
            Row("Resume automatically", "Continue a partly watched title where it stopped instead of from the start.", if (ra && rp) "On" else "Off") { s.setResumeAutomatically(!ra) }
        }
    }
    item {
        val si by s.showStreamInfo.collectAsState()
        Group("Diagnostics") {
            Row("Show stream information", "A small overlay with the engine, resolution and codecs while playing.", if (si) "On" else "Off") { s.setShowStreamInfo(!si) }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.library(vm: SettingsViewModel, c: AppContainer, nav: Navigator) {
    item {
        val sources by vm.sources.collectAsState()
        val message by vm.message.collectAsState()
        Group("Playlists", message) {
            if (sources.isEmpty()) Row("No playlists yet", "Add an Xtream login or an M3U link.")
            sources.forEach { src ->
                Row(src.name, "${if (src.type == SourceType.XTREAM) "Xtream" else "M3U"} · ${statusText(src)}", "Refresh") { vm.sync(src) }
                Row("Remove ${src.name}", "Deletes the playlist and its channels from this device.", "Remove") { vm.remove(src) }
            }
            Row("Add a playlist", "An Xtream login or an M3U link.", "Add") { nav.open(Overlay.AddPlaylist) }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.advanced(vm: SettingsViewModel, c: AppContainer) {
    item {
        Group("About") {
            Row("Version", null, "0.1.0")
            Row("Requires", null, "Android 5.1 or later (MPV: Android 8)")
            Row("This device", null, "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} · Android ${android.os.Build.VERSION.RELEASE}")
            Row("Playback engines", null, c.playback.available.joinToString(", ") { it.label })
        }
    }
    item {
        Group("Your data", "Your playlists, favorites and history stay on this device. Nothing is sent anywhere.") {
            Row("Clear watch history", "Removes Recently Watched and Watch History. Favorites and resume positions are kept.", "Clear") { vm.clearHistory() }
        }
    }
}

private fun statusText(s: Source) = when (s.status) {
    SyncStatus.NEVER -> "not read yet"
    SyncStatus.SYNCING -> "reading…"
    SyncStatus.OK -> "up to date"
    SyncStatus.FAILED -> "could not be read"
}
