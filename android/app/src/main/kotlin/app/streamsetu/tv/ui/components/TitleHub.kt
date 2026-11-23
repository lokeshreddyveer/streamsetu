package app.streamsetu.tv.ui.components

import androidx.compose.runtime.*
import app.streamsetu.core.data.hub.HubTitles
import app.streamsetu.core.data.hub.NextEpisode
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.i18n.I18n
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the title page shows from the extra sources: the title's logo, a wide picture, the next-episode words, and the credit line a source requires (none unless its terms say so). */
class TitleHubView(val logo: String?, val backdrop: String?, val nextEpisode: String?) {
    companion object { val NONE = TitleHubView(null, null, null) }
}

/**
 * The title page's link to the extra sources. It shows what is saved at once, and about half a second after the page opens (a quick pass asks nothing) asks the sources that can improve it: the same
 * express lane as an opened title anywhere. It never waits on the network and changes the page only when something new has landed.
 */
@Composable
fun rememberTitleHub(c: AppContainer, id: String?, series: Boolean): TitleHubView {
    var view by remember(id) { mutableStateOf(TitleHubView.NONE) }
    LaunchedEffect(id) {
        if (id == null) return@LaunchedEffect
        val hub = c.hubTitles
        suspend fun read() { view = runCatching { hub.saved(id).toView(series) }.getOrDefault(view) }
        read()
        launch { hub.hub.landed.collect { if (it == id) read() } }
        delay(500)
        runCatching { hub.open(id, series) }
        read()
    }
    return view
}

private fun HubTitles.Saved.toView(series: Boolean): TitleHubView {
    val words = if (series) NextEpisode.from(nextEpisode)?.key()?.let { (key, arg) -> I18n.tr(if (arg == null) key else key.replace("{}", arg)) } else null
    return TitleHubView(logo, backdrop, words)
}
