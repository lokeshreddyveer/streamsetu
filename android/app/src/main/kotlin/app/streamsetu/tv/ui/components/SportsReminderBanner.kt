package app.streamsetu.tv.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.playback.PlaybackState
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.personal.ReminderBanner
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the banner can be asked to do. */
class BannerActions(val open: () -> Unit, val dismiss: () -> Unit)

/**
 * The in-app Sports reminder: "India vs Australia starts in 15 minutes", with Open Event and Dismiss. One at a time; it only ever appears for an event the active profile may see (the service checks
 * that before it offers one). It never takes the remote: it appears and goes without moving focus from wherever the person is (browsing, a dialog, Settings), and the person reaches it on purpose
 * with the direction keys. Back dismisses it only while it is the thing focused. While something is playing or a Multi-View is open it has no buttons at all and goes by itself. It never opens Sports
 * on its own.
 */
@Composable
fun SportsReminderBanner(c: AppContainer, nav: Navigator) {
    val banner by c.sportsReminders.banner.collectAsStateWithLifecycle()
    val playing by c.playback.current.collectAsStateWithLifecycle()
    val state by c.playback.state.collectAsStateWithLifecycle()
    val b = banner ?: return
    val busy = nav.top == Overlay.Player || nav.top == Overlay.MultiView || nav.top == Overlay.SportsMultiview || (playing != null && (state == PlaybackState.Playing || state == PlaybackState.Buffering || state == PlaybackState.Resolving))
    val scope = rememberCoroutineScope()
    SportsReminderBannerContent(b, interactive = !busy, nowMs = System.currentTimeMillis(), actions = BannerActions(
        open = { scope.launch { c.sportsReminders.bannerDone(b.id) }; nav.pendingSportsReminder = b.id; if (nav.base == app.streamsetu.tv.nav.Base.Shell) { nav.overlays.clear(); nav.go(Tab.SPORTS) } },
        dismiss = { scope.launch { c.sportsReminders.bannerDone(b.id) } },
    ))
}

@Composable
fun SportsReminderBannerContent(b: ReminderBanner, interactive: Boolean, nowMs: Long, actions: BannerActions) {
    val minutes = maxOf(1, (b.startMs - nowMs + 59_999) / 60_000)
    val text = (b.title ?: "A sports event you set a reminder for") + " starts in $minutes minute" + if (minutes == 1L) "" else "s"
    var focused by remember(b.id) { mutableStateOf(false) }
    LaunchedEffect(b.id, interactive, focused) {
        // Seen is seen: a passive notice goes after a few seconds; one the person may use goes after a longer time, unless they are on it.
        if (!focused) { delay(if (interactive) 30_000L else 8_000L); actions.dismiss() }
    }
    BackHandler(enabled = interactive && focused) { actions.dismiss() }
    Box(Modifier.padding(top = Tokens.safeVertical, start = Tokens.safeHorizontal, end = Tokens.safeHorizontal), Alignment.TopCenter) {
        Column(Modifier.widthIn(max = 640.dp).onFocusChanged { focused = it.hasFocus }.background(Tokens.pick(Color(0xF2101418), Tokens.playerControlsScrimStrong), RoundedCornerShape(14.dp)).padding(horizontal = 18.dp, vertical = 12.dp).testTag("sports-reminder-banner"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label(text, Tokens.body, Color.White, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.testTag("sports-banner-text"))
            if (interactive) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TvButton("Open Event", actions.open, Modifier.testTag("sports-banner-open"), primary = true)
                TvButton("Dismiss", actions.dismiss, Modifier.testTag("sports-banner-dismiss"))
            }
        }
    }
}
