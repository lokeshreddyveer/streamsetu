package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.repo.TitlePageText
import app.streamsetu.tv.ui.phone.IconTap
import app.streamsetu.tv.ui.phone.Ph
import app.streamsetu.tv.ui.phone.PillButton
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage

/** One of the five equal items under Play. [spoken] is what TalkBack reads ("Favourite, on"). */
data class TitleAction(val icon: ImageVector, val label: String, val on: Boolean = false, val spoken: String = label, val tag: String = "action-$label", val onClick: () -> Unit)

/** Everything the top of a title page shows, top to bottom (the same order on every screen): hero, one quiet line, version picker, Play, five actions, synopsis, genres. */
class TitleTop(
    val title: String, val backdrop: String?, val poster: String?, val meta: String, val pickerLabel: String?, val onPicker: () -> Unit,
    val playLabel: String, val playProgress: Float?, val onPlay: () -> Unit, val playFocus: FocusRequester?, val actions: List<TitleAction>, val synopsis: String?, val genres: List<String>,
    val onBack: (() -> Unit)? = null, val onMenu: (() -> Unit)? = null,
    /** The title's own logo (from the extra sources): drawn over the same space as the title text, which stays underneath as the layout and the spoken name. */
    val logo: String? = null,
    /** "Next episode in 3 days", already in the person's language; null for a film or when it is not known. */
    val nextEpisode: String? = null,
)

private fun sp(v: Int) = v.sp

/** The picture at the top with the title on its gradient. With no wide picture: the poster at its own size on a dimmed wash of itself (no blur, no motion); never an empty box. */
@Composable
fun TitleHero(tv: Boolean, t: TitleTop, modifier: Modifier = Modifier, height: androidx.compose.ui.unit.Dp = if (tv) 330.dp else 280.dp, inset: androidx.compose.ui.unit.Dp = Ph.gutter) {
    val context = androidx.compose.ui.platform.LocalContext.current
    Box(modifier.fillMaxWidth().height(height).background(Tokens.card).testTag("title-hero")) {
        val back = t.backdrop?.takeIf { it.isNotBlank() }
        val poster = t.poster?.takeIf { it.isNotBlank() }
        if (back != null) AsyncImage(if (tv) artworkRequest(context, back, 1280, 720) else back, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else if (poster != null) {
            WashBehindPoster(poster)
            PosterArt(t.title, remember(poster) { artworkRequest(context, poster, 360, 540) }, Modifier.align(Alignment.TopCenter).padding(top = if (tv) 48.dp else 56.dp, bottom = 84.dp).fillMaxHeight().aspectRatio(2f / 3f, matchHeightConstraintsFirst = true).clip(RoundedCornerShape(10.dp)).testTag("hero-poster-wash"))
        } else PosterPlaceholder(t.title, Modifier.fillMaxSize(), showTitle = false)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color(0x66000000), 0.35f to Color.Transparent, 0.62f to Tokens.background.copy(alpha = 0.55f), 1f to Tokens.background)))
        val logo = t.logo?.takeIf { it.isNotBlank() }
        Box(Modifier.align(Alignment.BottomStart).padding(horizontal = inset, vertical = 6.dp)) {
            // With a logo the title text stays (invisible) so nothing moves when the logo arrives and the page is still read aloud by name.
            Label(t.title, if (tv) Tokens.display else Ph.title, Tokens.text, FontWeight.Bold, maxLines = 2, modifier = Modifier.alpha(if (logo != null) 0f else 1f).testTag("detail-title"))
            if (logo != null) AsyncImage(logo, null, Modifier.align(Alignment.CenterStart).widthIn(max = if (tv) 460.dp else 300.dp).heightIn(max = if (tv) 110.dp else 80.dp).testTag("title-logo"), contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
        }
        if (!tv) t.onBack?.let { IconTap(Icons.Filled.ArrowBack, "Back", it, Modifier.align(Alignment.TopStart).windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, top = 4.dp), filled = true) }
        t.onMenu?.let { m ->
            if (tv) TvIconButton(Icons.Filled.MoreHoriz, "Menu", m, Modifier.align(Alignment.TopEnd).padding(top = 8.dp).testTag("title-menu"))
            else IconTap(Icons.Filled.MoreHoriz, "Menu", m, Modifier.align(Alignment.TopEnd).windowInsetsPadding(WindowInsets.statusBars).padding(end = 4.dp, top = 4.dp).testTag("title-menu"), filled = true)
        }
    }
}

/** The part under the hero: the quiet line, the version picker, Play, the five actions, the synopsis and the genres. */
@Composable
fun TitleBody(tv: Boolean, t: TitleTop, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(if (tv) 10.dp else 12.dp)) {
        if (t.meta.isNotBlank()) Label(t.meta, if (tv) Tokens.small else Ph.small, Tokens.textSecondary, maxLines = 2, modifier = Modifier.testTag("title-meta"))
        t.nextEpisode?.takeIf { it.isNotBlank() }?.let { Label(it, if (tv) Tokens.caption else Ph.caption, Tokens.textSecondary, FontWeight.Medium, modifier = Modifier.background(Tokens.card, RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 4.dp).testTag("next-episode")) }
        val playReq = t.playFocus ?: remember { FocusRequester() }
        t.pickerLabel?.let { VersionPickerLine(it, tv, t.onPicker, playReq) }
        val firstAction = remember { FocusRequester() }
        PlayButton(t.playLabel, tv, t.playProgress, t.onPlay, playReq, firstAction)
        TitleActionRow(t.actions, tv, firstAction)
        t.synopsis?.takeIf { it.isNotBlank() }?.let { Synopsis(it, tv) }
        if (t.genres.isNotEmpty()) GenreChips(t.genres, tv)
    }
}

/** One line directly above Play: "English · 2 versions ▾". */
@Composable
fun VersionPickerLine(text: String, tv: Boolean, onClick: () -> Unit, down: FocusRequester? = null) {
    val sem = Modifier.then(if (down != null && tv) Modifier.focusProperties { this.down = down } else Modifier).testTag("version-picker").semantics { contentDescription = text.removeSuffix(" ▾") + ", choose version"; role = Role.Button }
    if (tv) Focusable(onClick, sem, shape = RoundedCornerShape(Tokens.radiusSmall), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = false, ringBand = false) { _ ->
        Label(text, Tokens.small, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp))
    } else Label(text, Ph.small, Tokens.accent, FontWeight.SemiBold, modifier = sem.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClick).padding(vertical = 8.dp, horizontal = 2.dp))
}

/** Full width, the brightest thing on the page. A thin bar shows how far a started title is. */
@Composable
fun PlayButton(text: String, tv: Boolean, progress: Float?, onClick: () -> Unit, focus: FocusRequester?, down: FocusRequester? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        val m = Modifier.fillMaxWidth().then(if (down != null && tv) Modifier.focusProperties { this.down = down } else Modifier).testTag("title-play").semantics { contentDescription = text }.then(if (focus != null) Modifier.focusRequester(focus) else Modifier)
        if (tv) TvButton(text, onClick, m, icon = Icons.Filled.PlayArrow, primary = true) else PillButton(text, onClick, m, icon = Icons.Filled.PlayArrow, primary = true)
        if (progress != null && progress > 0f) Box(Modifier.fillMaxWidth().height(3.dp).background(Tokens.elevated, RoundedCornerShape(2.dp))) { Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxHeight().background(Tokens.accent, RoundedCornerShape(2.dp))) }
    }
}

/** Five equal items, each an icon with its label under it (labels wrap at a large font). */
@Composable
fun TitleActionRow(actions: List<TitleAction>, tv: Boolean, first: FocusRequester? = null) {
    if (actions.isEmpty()) return
    Row(Modifier.fillMaxWidth().testTag("action-row"), horizontalArrangement = Arrangement.spacedBy(if (tv) 8.dp else 6.dp)) {
        actions.forEachIndexed { i, a ->
            val sem = Modifier.weight(1f).then(if (i == 0 && first != null && tv) Modifier.focusRequester(first) else Modifier).testTag(a.tag).semantics(mergeDescendants = true) { contentDescription = a.spoken; role = Role.Button; selected = a.on }
            val content: @Composable (Boolean) -> Unit = { f ->
                val ink = if (f && tv) Tokens.onBright else if (a.on) Tokens.accent else Tokens.text
                Column(Modifier.fillMaxWidth().padding(vertical = if (tv) 8.dp else 10.dp, horizontal = 2.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Image(a.icon, null, Modifier.size(if (tv) 22.dp else 24.dp), colorFilter = ColorFilter.tint(ink))
                    Label(a.label, if (tv) Tokens.caption else Ph.caption, ink, FontWeight.Medium, maxLines = 2, textAlign = TextAlign.Center)
                }
            }
            if (tv) Focusable(a.onClick, sem, shape = RoundedCornerShape(Tokens.radiusSmall), container = Color(0x26FFFFFF), focusedContainer = Color.White, scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = false, ringBand = false) { f -> content(f) }
            else Box(sem.clip(RoundedCornerShape(12.dp)).background(Tokens.elevated).clickable(role = Role.Button, onClick = a.onClick)) { content(false) }
        }
    }
}

/** Three lines, then More (focusable on a television). */
@Composable
fun Synopsis(text: String, tv: Boolean) {
    var more by remember(text) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Label(text, if (tv) Tokens.body else Ph.body, Tokens.textSecondary, maxLines = if (more) 40 else 3, modifier = Modifier.testTag("title-synopsis"))
        if (text.length > 150) {
            val go = { more = !more }
            val word = if (more) "Less" else "More"
            if (tv) Focusable(go, Modifier.testTag("synopsis-more"), shape = RoundedCornerShape(Tokens.radiusSmall), container = Color.Transparent, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = false, ringBand = false) { _ -> Label(word, Tokens.small, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp)) }
            else Label(word, Ph.small, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("synopsis-more").clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = go).padding(vertical = 6.dp, horizontal = 2.dp))
        }
    }
}

/** Quiet genre chips (not tappable: there is no genre page to open). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GenreChips(genres: List<String>, tv: Boolean) {
    FlowRow(Modifier.testTag("genre-chips"), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        genres.forEach { g -> Label(g, if (tv) Tokens.caption else Ph.caption, Tokens.textSecondary, modifier = Modifier.background(Tokens.card, RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 4.dp)) }
    }
}

/**
 * The details as a plain list: the label above, its value under it, wrapping at any font size. Names (Directed by, Starring) are links to the person page. [folder] draws the "In folder" row
 * (it opens the folder).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DetailsList(rows: List<TitlePageText.Row>, tv: Boolean, onPerson: (String) -> Unit, folder: (@Composable () -> Unit)?) {
    if (rows.isEmpty()) return
    Column(Modifier.fillMaxWidth().testTag("details-list"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionLabel("Details", tv)
        rows.forEach { r ->
            Column(Modifier.testTag("detail-${r.label}"), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                if (!r.folder) Label(r.label, if (tv) Tokens.caption else Ph.caption, Tokens.textTertiary, maxLines = 2)
                when {
                    r.folder -> folder?.invoke()
                    r.names.isNotEmpty() -> FlowRow(horizontalArrangement = Arrangement.spacedBy(if (tv) 8.dp else 4.dp), verticalArrangement = Arrangement.spacedBy(if (tv) 6.dp else 0.dp)) {
                        r.names.forEach { n ->
                            val sem = Modifier.testTag("person-link-$n").semantics { contentDescription = "$n, open page"; role = Role.Button }
                            if (tv) Focusable({ onPerson(n) }, sem, shape = RoundedCornerShape(Tokens.radiusSmall), container = Tokens.card, focusedContainer = Tokens.focusedSurface, scaleOnFocus = 1f, style = TvFocusStyle.DENSE, showRing = false, ringBand = false) { _ -> Label(n, Tokens.small, Tokens.text, modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)) }
                            else Label(n, Ph.body, Tokens.accent, modifier = sem.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button) { onPerson(n) }.padding(vertical = 6.dp, horizontal = 4.dp))
                        }
                    }
                    else -> Label(r.value.orEmpty(), if (tv) Tokens.small else Ph.body, Tokens.text, maxLines = 6)
                }
            }
        }
    }
}

@Composable
fun SectionLabel(text: String, tv: Boolean) = Label(text, if (tv) Tokens.heading else Ph.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(bottom = 2.dp))

/** Opens the official trailer (TMDB gives a video key) in whatever app plays it. Nothing about the person or the library is sent. */
fun openTrailer(context: android.content.Context, key: String) {
    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://www.youtube.com/watch?v=" + android.net.Uri.encode(key))).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
}
