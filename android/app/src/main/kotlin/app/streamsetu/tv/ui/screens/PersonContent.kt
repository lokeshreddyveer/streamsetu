package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.data.repo.*
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.PosterArt
import app.streamsetu.tv.ui.components.rememberArtwork
import app.streamsetu.tv.ui.theme.Tokens
import coil.compose.AsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What the person page knows right now. [note] is a quiet line (no key, offline); [fullList] is false when only the local list could be shown. */
data class PersonPageState(val info: PersonInfo? = null, val tiles: List<FilmTile> = emptyList(), val loading: Boolean = true, val note: String? = null, val fullList: Boolean = false, val retry: Boolean = false)

object PersonNotes { const val NO_KEY = "Add your own key in Settings for the full filmography"; const val OFFLINE = "You are offline"; const val NOT_ANSWERING = "The details service did not answer. Try again." }

/** Fills the person page: saved data at once, then a fresh answer; the local list when TMDB cannot be used. Every step is handed to [emit]. */
class PersonPageLoader(private val people: TmdbPeople, private val matcher: LibraryMatcher, private val local: suspend (String) -> List<PersonTitle>, private val sources: () -> List<String>, private val describe: (Exception) -> String = { PersonNotes.NOT_ANSWERING }) {
    private suspend fun full(f: Filmography, loading: Boolean, note: String? = null, retry: Boolean = false): PersonPageState {
        val hits = runCatching { matcher.match(f.credits, sources()) }.getOrDefault(emptyMap())
        return PersonPageState(f.person, f.credits.map { FilmTile(it, hits[it.key]) }, loading, note, true, retry)
    }
    private suspend fun localOnly(name: String, note: String?, retry: Boolean = false): PersonPageState {
        val l = runCatching { local(name) }.getOrDefault(emptyList())
        val tiles = l.mapIndexed { i, t ->
            FilmTile(Credit(-(i + 1L), t.series != null, t.title, null, t.year, t.year?.let { "$it-01-01" }, t.posterUrl, null, 0.0, null, null), LibraryHit(t.movie, t.series, t.versions))
        }
        return PersonPageState(null, tiles, false, note, false, retry)
    }

    suspend fun load(name: String, personId: Long?, fromTitle: String?, lang: String, emit: (PersonPageState) -> Unit) {
        if (!people.enabled) { emit(localOnly(name, PersonNotes.NO_KEY)); return }
        val id = personId ?: try { withContext(Dispatchers.IO) { people.resolve(name, fromTitle) } } catch (e: CancellationException) { throw e } catch (e: Exception) { emit(localOnly(name, describe(e), retry = true)); return }
        if (id == null) { emit(localOnly(name, null)); return }
        val cached = withContext(Dispatchers.IO) { people.cached(id, lang) }
        val fresh = people.isFresh(id, lang)
        if (cached != null) emit(full(cached, loading = !fresh)) else emit(PersonPageState(loading = true))
        if (cached != null && fresh) return
        try { emit(full(withContext(Dispatchers.IO) { people.load(id, lang) }, false)) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { val why = describe(e); emit(if (cached != null) full(cached, false, why, true) else localOnly(name, why, true)) }
    }
}

/** Where the person page was when a title was opened from it, so coming back lands on the same poster. */
object PersonMemory {
    private var person: String? = null; private var key: String? = null
    fun set(name: String, tileKey: String) { person = name; key = tileKey }
    fun take(name: String): String? = if (person == name) key else null
    fun clear() { person = null; key = null }
}

private const val HEADER_ITEMS = 4
private fun sp(v: Int) = v.sp

/** The label under a tile and its spoken form: "Pokiri, 2006, in your library". */
fun filmSpoken(t: FilmTile) = listOfNotNull(t.credit.title, t.credit.year?.toString(), t.credit.tag?.lowercase(), if (t.inLibrary) "in your library" else "not in your library", if ((t.hit?.versions ?: 0) > 1) "${t.hit!!.versions} versions" else null).joinToString(", ")

/** The stateless page (the screen wires data and navigation to it). */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun PersonContent(name: String, photo: String?, state: PersonPageState, tv: Boolean, libraryOnly: Boolean, onLibraryOnly: (Boolean) -> Unit, onOpen: (FilmTile) -> Unit, kids: Boolean = false, actingOnly: Boolean = false, onActingOnly: (Boolean) -> Unit = {}, onRetry: (() -> Unit)? = null) {
    var sort by remember { mutableStateOf(FilmSort.NEWEST) }
    var kind by remember { mutableStateOf(FilmKind.ALL) }
    var sheet by remember { mutableStateOf<FilmTile?>(null) }
    val only = libraryOnly || kids          // a Kids profile never browses beyond the library
    val (all, inLib) = remember(state.tiles, kind, actingOnly) { FilmographyView.counts(state.tiles, kind, actingOnly) }
    val shown = remember(state.tiles, sort, kind, only, actingOnly) { FilmographyView.arrange(state.tiles, sort, kind, only, actingOnly) }
    val split = remember(shown) { FilmographyView.secondaryStart(shown) }
    val grid = rememberLazyGridState()
    val restoreKey = remember { PersonMemory.take(name) }
    var restored by remember { mutableStateOf(false) }
    var focusKey by remember { mutableStateOf<String?>(null) }
    val fr = remember { FocusRequester() }
    LaunchedEffect(shown.size) {
        if (!restored && shown.isNotEmpty()) {
            restored = true
            val i = shown.indexOfFirst { it.key == restoreKey }
            if (restoreKey != null && i >= 0) { grid.scrollToItem(HEADER_ITEMS + i + (if (split in 0..i) 1 else 0)); focusKey = restoreKey }
        }
    }
    val h = if (tv) Tokens.safeHorizontal else 16.dp
    Box(Modifier.fillMaxSize().background(Tokens.background)) {
        LazyVerticalGrid(GridCells.Adaptive(if (tv) 154.dp else 104.dp), Modifier.fillMaxSize().testTag("person-grid"), state = grid,
            contentPadding = PaddingValues(start = h, end = h, top = if (tv) Tokens.safeVertical else 48.dp, bottom = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 10.dp), verticalArrangement = Arrangement.spacedBy(if (tv) Tokens.gutter else 12.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }, key = "header") { PersonHeader(name, photo, state, tv) }
            item(span = { GridItemSpan(maxLineSpan) }, key = "switch") {
                if (!kids && state.fullList) Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SegButton("All films", all, !only, tv, "seg-all") { onLibraryOnly(false) }
                    SegButton("In your library", inLib, only, tv, "seg-library") { onLibraryOnly(true) }
                } else Label(if (state.loading && state.tiles.isEmpty()) "Looking in your library…" else "%,d in your library".format(inLib), if (tv) Tokens.small else sp(13), Tokens.textSecondary)
            }
            item(span = { GridItemSpan(maxLineSpan) }, key = "controls") {
                if (state.fullList) androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilmSort.values().forEach { s -> ChoiceChip(s.label, sort == s, tv, "Sort by ${s.label}") { sort = s } }
                    Spacer(Modifier.width(10.dp))
                    FilmKind.values().forEach { k -> ChoiceChip(k.label, kind == k, tv, "Show ${k.label}") { kind = k } }
                    ChoiceChip("Acting only", actingOnly, tv, "Acting only") { onActingOnly(!actingOnly) }
                }
            }
            item(span = { GridItemSpan(maxLineSpan) }, key = "note") {
                val msg = state.note ?: if (state.loading && state.tiles.isNotEmpty()) "Updating…" else null
                if (msg != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Label(msg, if (tv) Tokens.small else sp(13), Tokens.textTertiary, modifier = Modifier.weight(1f, fill = false))
                    if (state.retry && onRetry != null) ChoiceChip("Retry", false, tv, "Retry loading this person") { onRetry() }
                } else Spacer(Modifier.height(1.dp))
            }
            if (state.loading && state.tiles.isEmpty()) {
                items(12, key = { "sk$it" }, contentType = { "skeleton" }) { Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(if (tv) Tokens.radius else 12.dp)).background(Tokens.card)) }
            } else if (shown.isEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "empty") {
                    val first = name.substringBefore(' ')
                    Label(if (only && state.fullList) "None of $first's films are in your library yet." else if (only) "Nothing in your library yet" else "No films found.", if (tv) Tokens.body else sp(15), Tokens.textSecondary, modifier = Modifier.padding(vertical = 24.dp).testTag("person-empty"), maxLines = 3)
                }
            } else {
                val tile: @Composable (Int) -> Unit = { i ->
                    val t = shown[i]
                    FilmTileView(t, tv, if (t.key == focusKey) Modifier.focusRequester(fr) else Modifier, { PersonMemory.set(name, t.key) }) {
                        PersonMemory.set(name, t.key)
                        if (t.inLibrary) onOpen(t) else if (!kids) sheet = t
                    }
                }
                val firstGroup = if (split >= 0) split else shown.size
                items(firstGroup, key = { shown[it].key }, contentType = { "film" }) { i -> tile(i) }
                if (split >= 0) {
                    item(span = { GridItemSpan(maxLineSpan) }, key = "secondary-head") { Label("Voice and cameo credits", if (tv) Tokens.small else sp(13), Tokens.textTertiary, FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp).testTag("secondary-head")) }
                    items(shown.size - split, key = { shown[split + it].key }, contentType = { "film" }) { j -> tile(split + j) }
                }
            }
        }
    }
    if (tv) LaunchedEffect(focusKey, shown.size) { if (focusKey != null && shown.any { it.key == focusKey }) { kotlinx.coroutines.delay(60); runCatching { fr.requestFocus() }; focusKey = null } }
    sheet?.let { InfoSheet(it, tv) { sheet = null } }
}

@Composable
private fun PersonHeader(name: String, photo: String?, state: PersonPageState, tv: Boolean) {
    val info = state.info
    val pic = info?.photo ?: photo
    val size = if (tv) 160.dp else 112.dp
    var expanded by remember { mutableStateOf(false) }
    val bio = info?.biography?.takeIf { it.isNotBlank() }
    Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(size).clip(CircleShape).background(Tokens.card).testTag("person-photo"), Alignment.Center) {
                if (pic.isNullOrBlank()) Label(name.split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1).uppercase() }, (size.value / 3).sp, Tokens.textSecondary, FontWeight.SemiBold)
                else AsyncImage(pic, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Label(name, if (tv) Tokens.display else sp(24), Tokens.text, FontWeight.Bold, maxLines = 2)
                if (info != null) {
                    PersonText.born(info)?.let { Label(it, if (tv) Tokens.small else sp(13), Tokens.textSecondary, maxLines = 2) }
                    PersonText.knownFor(info.department, FilmographyView.knownFor(state.tiles.map { it.credit }))?.let { Label("Known for: $it", if (tv) Tokens.small else sp(13), Tokens.textSecondary, maxLines = 3) }
                    PersonText.alsoKnownAs(info)?.let { Label("Also known as $it", if (tv) Tokens.caption else sp(12), Tokens.textTertiary, maxLines = 1) }
                }
            }
        }
        if (bio != null) {
            Label(bio, if (tv) Tokens.small else sp(14), Tokens.text, maxLines = if (expanded) 200 else 4, modifier = Modifier.widthIn(max = 860.dp).testTag("person-bio"))
            if (bio.length > 220) TextButton(if (expanded) "Less" else "More", tv) { expanded = !expanded }
        }
    }
}

@Composable
private fun TextButton(text: String, tv: Boolean, onClick: () -> Unit) {
    if (tv) Focusable(onClick, Modifier.testTag("person-more"), shape = RoundedCornerShape(Tokens.radius), browse = true) { _ -> Label(text, Tokens.small, Tokens.accent, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) }
    else Label(text, sp(14), Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("person-more").clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClick).padding(vertical = 8.dp, horizontal = 4.dp))
}

/** One of the two buttons: "All films (42)" / "In your library (5)". Spoken as "All films, 42, selected". */
@Composable
private fun SegButton(text: String, count: Int, on: Boolean, tv: Boolean, tag: String, onClick: () -> Unit) {
    val spoken = "$text, $count" + if (on) ", selected" else ""
    val body: @Composable () -> Unit = { Label("$text ($count)", if (tv) Tokens.body else sp(14), if (on) Color.White else Tokens.text, if (on) FontWeight.SemiBold else FontWeight.Medium, modifier = Modifier.padding(horizontal = 18.dp, vertical = if (tv) 10.dp else 9.dp)) }
    val sem = Modifier.testTag(tag).semantics(mergeDescendants = true) { contentDescription = spoken; role = Role.RadioButton; selected = on }
    if (tv) Focusable(onClick, sem, shape = RoundedCornerShape(50), container = if (on) Tokens.accent else Tokens.card, focusedContainer = if (on) Tokens.accent else Tokens.focusedSurface, browse = true) { _ -> body() }
    else Box(sem.clip(RoundedCornerShape(50)).background(if (on) Tokens.accent else Tokens.card).clickable(role = Role.RadioButton, onClick = onClick)) { body() }
}

/** The choice chip of the filmography bar (sort, kind, acting only): one choice at a time, TV focus ring or phone tap. (The phone's selectable pill is PhoneKit's Chip; a static label is StatusChip.) */
@Composable
private fun ChoiceChip(text: String, on: Boolean, tv: Boolean, spoken: String, onClick: () -> Unit) {
    val body: @Composable () -> Unit = { Label(text, if (tv) Tokens.small else sp(13), if (on) Tokens.text else Tokens.textSecondary, if (on) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.padding(horizontal = 12.dp, vertical = if (tv) 6.dp else 6.dp)) }
    val sem = Modifier.testTag("chip-$text").semantics(mergeDescendants = true) { contentDescription = spoken + if (on) ", selected" else ""; role = Role.RadioButton; selected = on }
    if (tv) Focusable(onClick, sem, shape = RoundedCornerShape(50), container = if (on) Tokens.focusedSurface else Color.Transparent, focusedContainer = Tokens.focusedSurface, hairline = !on, browse = true) { _ -> body() }
    else Box(sem.clip(RoundedCornerShape(50)).background(if (on) Tokens.focusedSurface else Tokens.card).clickable(role = Role.RadioButton, onClick = onClick)) { body() }
}

/** One poster with its year, rating and library label. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun FilmTileView(t: FilmTile, tv: Boolean, focus: Modifier, onFocus: () -> Unit, onClick: () -> Unit) {
    val c = t.credit
    val title = remember(c.title) { ArtworkNames.normalizeText(c.title).ifBlank { c.title } }
    val poster = c.poster ?: t.hit?.movie?.posterUrl ?: t.hit?.series?.posterUrl
    val sub = listOfNotNull(c.year?.toString(), c.rating?.let(app.streamsetu.core.data.repo.DisplayRating::star), if ((t.hit?.versions ?: 0) > 1) "${t.hit!!.versions} versions" else null).joinToString(" · ").ifEmpty { " " }
    val labelColor = if (t.inLibrary) Tokens.success else Tokens.textTertiary
    val label = if (t.inLibrary) "In your library" else "Not in your library"
    val spoken = remember(t) { filmSpoken(t) }
    val menu = app.streamsetu.tv.ui.phone.LocalTileMenu.current
    val itemId = t.hit?.movie?.id ?: t.hit?.series?.id
    val long: (() -> Unit)? = if (menu != null && itemId != null) ({ menu(itemId) }) else null          // a title in your library opens the shared menu
    val tag = c.tag
    val art: @Composable () -> Unit = { Box(Modifier.fillMaxSize()) { PosterArt(title, if (tv) rememberArtwork(poster, 154.dp, 3 to 2, Tokens.radius) else poster?.takeIf { it.isNotBlank() }, Modifier.fillMaxSize(), year = c.year?.toString())
        if (tag != null) Label(tag, if (tv) Tokens.caption else sp(11), Tokens.text, FontWeight.SemiBold, modifier = Modifier.align(Alignment.TopStart).padding(5.dp).background(Tokens.chipScrim, RoundedCornerShape(5.dp)).padding(horizontal = 6.dp, vertical = 1.dp).testTag("tag-${c.key}"))
        c.rating?.let { app.streamsetu.tv.ui.components.RatingBadge(it, Modifier.align(Alignment.TopEnd).padding(5.dp), small = !tv) } } }          // the same star as on every tile
    val caption: @Composable () -> Unit = {
        Label(title, if (tv) Tokens.caption else sp(12), Tokens.text, FontWeight.Medium, maxLines = 2, modifier = Modifier.padding(horizontal = 2.dp))
        Label(sub, if (tv) Tokens.caption else sp(11), Tokens.textTertiary, modifier = Modifier.padding(horizontal = 2.dp))
        if (c.kind != CreditKind.CREW) c.role?.takeIf { it.isNotBlank() }?.let { Label("as $it", if (tv) Tokens.caption else sp(11), Tokens.textTertiary, maxLines = 1, modifier = Modifier.padding(horizontal = 2.dp).testTag("as-${c.key}")) }
        Label(label, if (tv) Tokens.caption else sp(11), labelColor, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 2.dp))
    }
    if (tv) Column(Modifier.testTag("film-${t.key}").semantics(mergeDescendants = true) { contentDescription = spoken }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Focusable(onClick, focus.fillMaxWidth().aspectRatio(2f / 3f), onLongClick = long, container = Tokens.card, focusedContainer = Tokens.focusedSurface, browse = true, onFocus = { if (it) onFocus() }, ringBand = true) { _ -> art() }
        caption()
    } else Column(Modifier.testTag("film-${t.key}").clip(RoundedCornerShape(12.dp)).semantics(mergeDescendants = true) { contentDescription = spoken; role = Role.Button }.combinedClickable(onClick = onClick, onLongClick = long), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp)).background(Tokens.card)) { art() }
        caption()
    }
}

/** A title that is not in the library: what TMDB says, with no way to play it. */
@Composable
private fun InfoSheet(t: FilmTile, tv: Boolean, onClose: () -> Unit) {
    val c = t.credit
    val close = remember { FocusRequester() }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose) {
        Column(Modifier.widthIn(max = 560.dp).clip(RoundedCornerShape(16.dp)).background(Tokens.panel).padding(20.dp).testTag("film-sheet"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(if (tv) 130.dp else 100.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(10.dp)).background(Tokens.card)) { PosterArt(c.title, c.poster?.takeIf { it.isNotBlank() }, Modifier.fillMaxSize(), year = c.year?.toString()) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Label(c.title, if (tv) Tokens.title else sp(18), Tokens.text, FontWeight.Bold, maxLines = 3)
                    Label(listOfNotNull(c.year?.toString(), if (c.series) "Series" else "Film", c.rating?.let(app.streamsetu.core.data.repo.DisplayRating::star)).joinToString(" · "), if (tv) Tokens.small else sp(13), Tokens.textSecondary)
                    c.role?.takeIf { it.isNotBlank() }?.let { Label(it, if (tv) Tokens.small else sp(13), Tokens.textTertiary, maxLines = 2) }
                    Label("Not in your library", if (tv) Tokens.small else sp(13), Tokens.textTertiary, FontWeight.SemiBold)
                }
            }
            c.overview?.takeIf { it.isNotBlank() }?.let { Label(it, if (tv) Tokens.small else sp(14), Tokens.text, maxLines = 8) }
            if (tv) Focusable(onClose, Modifier.focusRequester(close).testTag("film-sheet-close"), container = Tokens.card, focusedContainer = Tokens.focusedSurface) { _ -> Label("Close", Tokens.body, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 24.dp, vertical = 10.dp)) }
            else Label("Close", sp(15), Tokens.accent, FontWeight.SemiBold, modifier = Modifier.testTag("film-sheet-close").clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClose).padding(vertical = 8.dp, horizontal = 4.dp))
        }
    }
    if (tv) LaunchedEffect(Unit) { kotlinx.coroutines.delay(80); runCatching { close.requestFocus() } }
}
