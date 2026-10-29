package app.streamsetu.tv.ui.components

import androidx.compose.foundation.basicMarquee
import androidx.compose.ui.unit.sp
import app.streamsetu.tv.ui.theme.ui
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.launch
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.repo.SearchText
import app.streamsetu.core.model.*
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.ui.theme.Tokens

/** A fixed entry above the provider's folders (All, Favorites, Watch Later...). */
data class Shortcut(val browse: Browse, val label: String, val icon: ImageVector)

/** What the panel can do to a folder. The panel never touches the database itself. */
interface FolderActions {
    fun toggleFavorite(f: Folder); fun togglePinned(f: Folder); fun toggleHidden(f: Folder); fun toggleLocked(f: Folder)
    fun rename(f: Folder, alias: String?); fun move(f: Folder, to: app.streamsetu.core.data.repo.MoveTo); fun restoreOrder()
    fun resetPosition(f: Folder); fun resetFolder(f: Folder)
    /** Makes a folder of the person's own (a collection). Provider folders are never created, moved into or deleted. */
    fun createFolder(name: String)
    fun isUnlocked(folderId: String): Boolean
    val hasPin: Boolean
    fun checkPin(pin: String): Boolean
    fun setPin(pin: String)
    fun unlock(folderId: String)
}

/**
 * The folder column of Movies, Series and Live TV. Top: the heading and a field that searches folder names only. Then the shortcuts, then the provider's folders in the
 * person's order. A highlight slides to the open folder (the text never moves). Holding OK on a folder opens its menu; "Reorder" lets Up and Down move it.
 * Hidden folders are left out unless Manage is on; locked folders ask for the PIN before they open.
 */
@Composable
fun FolderPanel(
    title: String,
    shortcuts: List<Shortcut>,
    folders: List<Folder>,
    selected: Browse,
    onSelect: (Browse) -> Unit,
    actions: FolderActions,
    modifier: Modifier = Modifier,
    entry: FocusRequester? = null,
    showSearch: Boolean = false,
    onRight: () -> Boolean = { false },
    /** Left from the folders: the main sidebar. */
    onLeft: (() -> Unit)? = null,
    /** Moving over a folder never opens it (OK does); kept for callers that still ask for the old behaviour. */
    selectOnDwell: Boolean = false,
    onShortcutMenu: (Shortcut) -> Unit = {},
    /** Called after OK on a row (the row was chosen, not only passed over). */
    onConfirm: () -> Unit = {},
) {
    var query by remember { mutableStateOf("") }
    var manage by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Folder?>(null) }
    var reordering by remember { mutableStateOf<String?>(null) }
    var pinFor by remember { mutableStateOf<Folder?>(null) }
    var creatingPinFor by remember { mutableStateOf<Folder?>(null) }
    var renameFor by remember { mutableStateOf<Folder?>(null) }
    var infoFor by remember { mutableStateOf<Folder?>(null) }
    var creating by remember { mutableStateOf(false) }
    var resetFor by remember { mutableStateOf<Folder?>(null) }
    var unlockingToRemove by remember { mutableStateOf(false) }
    var lockAfterCreate by remember { mutableStateOf(false) }
    val reduced = LocalReducedMotion.current
    val listState = rememberLazyListState()
    val q = SearchText.normalize(query)
    val visible = folders.filter { (manage || !it.pref.hidden) && (q.isEmpty() || SearchText.normalize(it.title).contains(q) || SearchText.normalize(it.providerName).contains(q)) }
    val shownShortcuts = if (q.isEmpty()) shortcuts else emptyList()
    val rows: List<Any> = shownShortcuts + visible
    val selectedKey: Any? = when (selected) { is Browse.Folder -> "f:${selected.id}"; else -> shortcuts.firstOrNull { it.browse == selected }?.let { "s:${it.label}" } }

    // The highlight stays in one place: once the remote is a few rows down, the list moves under it instead of the highlight moving down the panel.
    var focusedIdx by remember { mutableIntStateOf(-1) }
    // The row the remote is on is brought into view only when it is not already fully in view; the list does not move for every step.
    LaunchedEffect(focusedIdx) {
        if (focusedIdx < 0) return@LaunchedEffect
        val info = listState.layoutInfo
        val row = info.visibleItemsInfo.firstOrNull { it.index == focusedIdx }
        val inView = row != null && row.offset >= info.viewportStartOffset && row.offset + row.size <= info.viewportEndOffset
        if (!inView) runCatching { listState.animateScrollToItem((focusedIdx - 2).coerceAtLeast(0)) }
    }
    // One stable focus requester per folder or shortcut (by its id), so Up and Down can name the next row exactly instead of leaving it to a search of the list.
    val rowRequesters = remember { HashMap<Any, FocusRequester>() }
    val moveScope = androidx.compose.runtime.rememberCoroutineScope()
    var moving by remember { mutableStateOf(false) }
    fun keyOf(r: Any): Any = if (r is Shortcut) "s:${r.label}" else "f:${(r as Folder).id}"
    fun requesterOf(r: Any): FocusRequester { val own = rowRequesters.getOrPut(keyOf(r)) { FocusRequester() }; return own }
    BackHandler(enabled = reordering != null) { reordering = null }
    // The open folder's row must exist for the remote to land on it: bring it into view when the panel appears or the selection changes.
    LaunchedEffect(selectedKey) { val i = rows.indexOfFirst { (it is Shortcut && "s:${it.label}" == selectedKey) || (it is Folder && "f:${it.id}" == selectedKey) }; if (i > 3) runCatching { listState.scrollToItem(i - 2) } }

    fun open(f: Folder) {
        if (f.pref.locked && !actions.isUnlocked(f.id)) { if (actions.hasPin) pinFor = f else creatingPinFor = f }
        else { onSelect(Browse.Folder(f.id)); onConfirm() }
    }

    Column(
        modifier.fillMaxHeight().background(Tokens.card).padding(vertical = Tokens.safeVertical, horizontal = 8.dp)
            .onPreviewKeyEvent { e ->
                val id = reordering
                if (id != null && e.type == KeyEventType.KeyDown) {
                    val f = folders.firstOrNull { it.id == id }
                    when (e.key) {
                        Key.DirectionUp -> { f?.let { actions.move(it, app.streamsetu.core.data.repo.MoveTo.UP) }; true }
                        Key.DirectionDown -> { f?.let { actions.move(it, app.streamsetu.core.data.repo.MoveTo.DOWN) }; true }
                        Key.DirectionCenter, Key.Enter, Key.DirectionLeft, Key.DirectionRight -> { reordering = null; true }
                        else -> false
                    }
                } else if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) onRight() else if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionLeft && onLeft != null) { onLeft(); true } else false
            },
    ) {
        Column(Modifier.padding(start = 14.dp, end = 8.dp, bottom = 6.dp)) {
            Label(title, 22.sp, Tokens.text, FontWeight.Bold)
            Label(if (folders.isEmpty()) "No folders" else "%,d folders".format(folders.count { !it.pref.hidden }), 15.sp, Tokens.textTertiary, modifier = Modifier.padding(top = 1.dp))
        }
        // The folder search field is only on screens with a very long list of folders (Live TV); Movies and Series have the Search chip on the page.
        if (showSearch) TvTextField(query, { query = it }, "Search folders", Modifier.padding(horizontal = 8.dp).fillMaxWidth(), compact = true, leadingIcon = Icons.Filled.Search)
        // New folder and Manage folders sit up here, one press from the search field, so they are reached without scrolling through every folder.
        Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            PanelAction("New", Icons.Filled.CreateNewFolder, Modifier.weight(1f)) { creating = true }
            PanelAction(if (manage) "Done" else "Edit", Icons.Filled.Tune, Modifier.weight(1f), highlighted = manage) { manage = !manage }
        }

        // Holding Up runs the highlight to the top of the folders and stops there; it does not carry on into the buttons above. A fresh press does.
        Box(Modifier.weight(1f).fillMaxWidth().onPreviewKeyEvent { e ->
            if (e.type != androidx.compose.ui.input.key.KeyEventType.KeyDown || reordering != null) return@onPreviewKeyEvent false
            val up = e.key == androidx.compose.ui.input.key.Key.DirectionUp; val down = e.key == androidx.compose.ui.input.key.Key.DirectionDown
            if (!up && !down) return@onPreviewKeyEvent false
            // Holding Up runs the highlight to the top of the folders and stops there; a fresh press goes on to the buttons above.
            if (up && focusedIdx <= 0) return@onPreviewKeyEvent e.nativeKeyEvent.repeatCount > 0
            if (moving) return@onPreviewKeyEvent true                          // a move is still landing: repeated presses wait for it
            val target = if (up) focusedIdx - 1 else focusedIdx + 1
            if (target < 0 || target >= rows.size) return@onPreviewKeyEvent true      // the end of the list: stay on the last folder
            moving = true
            moveScope.launch {
                try {
                    if (listState.layoutInfo.visibleItemsInfo.none { it.index == target }) listState.scrollToItem((target - 2).coerceAtLeast(0))
                    androidx.compose.runtime.withFrameNanos { }
                    val r = rows[target]
                    runCatching { (if ((r is Shortcut && r.browse == selected) || (r is Folder && selected == Browse.Folder(r.id))) entry else null)?.requestFocus() ?: requesterOf(r).requestFocus() }
                } finally { moving = false }
            }
            true
        }) {
            LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                itemsIndexed(rows, key = { _, r -> if (r is Shortcut) "s:${r.label}" else "f:${(r as Folder).id}" }) { idx, r ->
                    // A small heading where the shortcuts end and the provider's folders begin.
                    if (r is Folder && (idx == 0 || rows[idx - 1] is Shortcut) && visible.isNotEmpty()) Label("FOLDERS", 11.sp, Tokens.textTertiary, FontWeight.Bold, modifier = Modifier.padding(start = 10.dp, top = if (idx == 0) 2.dp else 8.dp, bottom = 2.dp), letterSpacing = androidx.compose.ui.unit.TextUnit(1.4f, androidx.compose.ui.unit.TextUnitType.Sp))
                    if (r is Shortcut) {
                        PanelRow(r.label, r.icon, null, r.browse == selected, false, if (r.browse == selected && entry != null) Modifier.focusRequester(entry) else Modifier.focusRequester(requesterOf(r)), onFocusDwell = { if (selectOnDwell) onSelect(r.browse) }, onRowFocus = { focusedIdx = idx }, onLongClick = if (r.browse is Browse.Collection) ({ onShortcutMenu(r) }) else null, onClick = { onSelect(r.browse); onConfirm() })
                    } else {
                        val f = r as Folder
                        val isSel = selected == Browse.Folder(f.id)
                        PanelRow(
                            f.title, if (f.pref.locked) Icons.Filled.Lock else if (f.pref.pinned) Icons.Filled.PushPin else if (f.pref.favorite) Icons.Filled.Star else FolderIcons.forName(f.title),
                            f.count.takeIf { it > 0 }, isSel, f.pref.hidden, (if (reordering == f.id) Modifier.background(Tokens.accent.copy(alpha = 0.18f)) else Modifier).then(if (isSel && entry != null) Modifier.focusRequester(entry) else Modifier.focusRequester(requesterOf(f))),
                            onFocusDwell = { if (selectOnDwell && !(f.pref.locked && !actions.isUnlocked(f.id))) onSelect(Browse.Folder(f.id)) }, onRowFocus = { focusedIdx = idx },
                            onLongClick = { menuFor = f }, onClick = { open(f) }, reordering = reordering == f.id,
                        )
                    }
                }
                if (q.isNotEmpty() && visible.isEmpty()) item(key = "none") { Label("No folder matches “$query”.", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(12.dp), maxLines = 2) }
            }
        }
    }

    if (creating) RenameDialog("", onSave = { actions.createFolder(it); creating = false }, onReset = { creating = false }, onClose = { creating = false }, title = "New folder", hint = "A folder of your own. Add titles to it by holding OK on a poster.", resetLabel = "Cancel")
    menuFor?.let { f ->
        val ids = visible.map { it.id }
        fun can(to: app.streamsetu.core.data.repo.MoveTo) = app.streamsetu.core.data.repo.FolderOrder.canMove(ids, f.id, to)
        ContextMenu(f.title, if (f.title != f.providerName) f.providerName else null, buildList {
            add(MenuAction("Open folder", Icons.Filled.FolderOpen) { open(f) })
            if (can(app.streamsetu.core.data.repo.MoveTo.UP)) add(MenuAction("Move up", Icons.Filled.ArrowUpward) { actions.move(f, app.streamsetu.core.data.repo.MoveTo.UP) })
            if (can(app.streamsetu.core.data.repo.MoveTo.DOWN)) add(MenuAction("Move down", Icons.Filled.ArrowDownward) { actions.move(f, app.streamsetu.core.data.repo.MoveTo.DOWN) })
            if (can(app.streamsetu.core.data.repo.MoveTo.FIRST)) add(MenuAction("Move to first", Icons.Filled.VerticalAlignTop) { actions.move(f, app.streamsetu.core.data.repo.MoveTo.FIRST) })
            if (can(app.streamsetu.core.data.repo.MoveTo.LAST)) add(MenuAction("Move to last", Icons.Filled.VerticalAlignBottom) { actions.move(f, app.streamsetu.core.data.repo.MoveTo.LAST) })
            add(MenuAction(if (f.pref.pinned) "Unpin" else "Pin to the top", Icons.Filled.PushPin) { actions.togglePinned(f) })
            add(MenuAction(if (f.pref.favorite) "Remove from favorite folders" else "Add to favorite folders", Icons.Filled.Star) { actions.toggleFavorite(f) })
            add(MenuAction(if (f.pref.hidden) "Unhide folder" else "Hide folder", Icons.Filled.VisibilityOff) { actions.toggleHidden(f) })
            add(MenuAction(if (f.pref.locked) "Unlock folder" else "Lock folder", Icons.Filled.Lock) {
                if (f.pref.locked) { if (actions.hasPin) { unlockingToRemove = true; pinFor = f } else actions.toggleLocked(f) }
                else if (actions.hasPin) actions.toggleLocked(f) else { lockAfterCreate = true; creatingPinFor = f }
            })
            add(MenuAction("Rename display name…", Icons.Filled.Edit) { renameFor = f })
            add(MenuAction("Folder information", Icons.Filled.Info) { infoFor = f })
            if (f.pref.sortIndex >= 0) add(MenuAction("Reset folder position", Icons.Filled.Restore) { actions.resetPosition(f) })
            if (f.pref != app.streamsetu.core.model.FolderPref()) add(MenuAction("Reset folder customization…", Icons.Filled.RestartAlt) { resetFor = f })
        }, onClose = { menuFor = null })
    }
    infoFor?.let { f ->
        ContextMenu(f.title, listOfNotNull("Provider name: ${f.providerName}", f.pref.alias?.let { "Display name: $it" }, "%,d titles".format(f.count),
            listOfNotNull(if (f.pref.favorite) "favorite" else null, if (f.pref.pinned) "pinned" else null, if (f.pref.hidden) "hidden" else null, if (f.pref.locked) "locked" else null).joinToString(", ").takeIf { it.isNotBlank() }?.let { "Marked: $it" }).joinToString("\n"),
            listOf(MenuAction("Close", Icons.Filled.Close) {}), onClose = { infoFor = null })
    }
    resetFor?.let { f ->
        ContextMenu("Reset “${f.title}”?", "Removes its display name, pin, favorite, hidden and lock marks and puts it back in the provider's position. Nothing else is touched.",
            listOf(MenuAction("Cancel", Icons.Filled.Close) {}, MenuAction("Reset “${f.title}”", Icons.Filled.RestartAlt, danger = true) { actions.resetFolder(f) }), onClose = { resetFor = null })
    }
    pinFor?.let { f ->
        PinDialog(create = false, check = actions::checkPin, onDone = {
            pinFor = null
            if (unlockingToRemove) { unlockingToRemove = false; actions.toggleLocked(f) } else { actions.unlock(f.id); onSelect(Browse.Folder(f.id)) }
        }, onClose = { pinFor = null; unlockingToRemove = false })
    }
    creatingPinFor?.let { f ->
        PinDialog(create = true, check = { true }, onDone = { pin ->
            actions.setPin(pin); creatingPinFor = null
            if (lockAfterCreate) { lockAfterCreate = false; actions.toggleLocked(f) } else { actions.unlock(f.id); onSelect(Browse.Folder(f.id)) }
        }, onClose = { creatingPinFor = null; lockAfterCreate = false })
    }
    renameFor?.let { f ->
        RenameDialog(f.title, onSave = { actions.rename(f, it); renameFor = null }, onReset = { actions.rename(f, null); renameFor = null }, onClose = { renameFor = null })
    }
}

/** A small button in the folder panel's header. */
@Composable
private fun PanelAction(label: String, icon: ImageVector, modifier: Modifier, highlighted: Boolean = false, onClick: () -> Unit) {
    Focusable(onClick, modifier.height(44.ui), scaleOnFocus = 1.0f, container = if (highlighted) Tokens.accent.copy(alpha = 0.18f) else Color(0x1AFFFFFF), focusedContainer = Color(0x40FFFFFF), shape = RoundedCornerShape(Tokens.radius)) { f ->
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            Image(icon, null, Modifier.size(20.ui), colorFilter = ColorFilter.tint(if (f || highlighted) Color.White else Tokens.textSecondary))
            Label(label, 15.sp, if (f || highlighted) Color.White else Tokens.textSecondary, FontWeight.Medium)
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun PanelRow(label: String, icon: ImageVector, count: Int?, selected: Boolean, dimmed: Boolean, extra: Modifier, onFocusDwell: () -> Unit = {}, onRowFocus: () -> Unit = {}, onLongClick: (() -> Unit)? = null, reordering: Boolean = false, onClick: () -> Unit) {
    var dwellKey by remember { mutableIntStateOf(0) }
    var focused by remember { mutableStateOf(false) }
    // Moving the remote over folders opens one only after a short pause, so scrolling through many folders stays light.
    LaunchedEffect(dwellKey, focused) { if (focused) { kotlinx.coroutines.delay(250); onFocusDwell() } }
    // The same entry as the main sidebar (56 high, a 3-wide accent bar for the open folder, a soft fill for the open one and a stronger one where the remote is); the names are set smaller.
    Focusable(onClick, extra.testTag("panel-row-$label").fillMaxWidth().heightIn(min = 56.ui), scaleOnFocus = 1.0f, container = if (selected) Color(0x1AFFFFFF) else Color.Transparent, focusedContainer = Color(0x40FFFFFF), shape = RoundedCornerShape(Tokens.radius), onFocus = { focused = it; dwellKey++; if (it) onRowFocus() }, onLongClick = onLongClick) { f ->
        Row(Modifier.heightIn(min = 56.ui), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.padding(start = 2.dp).width(3.dp).height(20.ui).background(if (selected) Tokens.accent else Color.Transparent, RoundedCornerShape(2.dp)))
            Box(Modifier.width(34.ui), Alignment.Center) {
                Image(if (reordering) Icons.Filled.SwapVert else icon, null, Modifier.size(22.ui), colorFilter = ColorFilter.tint(if (f || selected) Color.White else Tokens.textSecondary))
            }
            val ink = if (dimmed) Tokens.textTertiary else if (f || selected) Color.White else Tokens.textSecondary
            val weight = if (selected) FontWeight.SemiBold else FontWeight.Medium
            // Every row stays one clean line. The row the remote is on slides its whole name sideways (after a short pause), so a long name can be read in full without the list changing shape.
            if (f) androidx.compose.foundation.text.BasicText(app.streamsetu.tv.ui.i18n.I18n.tr(label), Modifier.weight(1f).padding(start = 8.dp).basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 700, velocity = 40.dp),
                style = androidx.compose.ui.text.TextStyle(color = ink, fontSize = 14.sp, fontWeight = weight), maxLines = 1, softWrap = false)
            else Label(label, 14.sp, ink, weight, modifier = Modifier.weight(1f).padding(start = 8.dp))
            Spacer(Modifier.width(8.dp))          // the number of titles is not shown beside the name: the whole width goes to the name
        }
    }
}

@Composable
fun RenameDialog(current: String, onSave: (String) -> Unit, onReset: () -> Unit, onClose: () -> Unit, title: String = "Display label", hint: String = "Only changes how it looks here. The provider's name is not touched.", resetLabel: String = "Use provider name") {
    var text by remember { mutableStateOf(current) }
    TvDialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.popIn().width(340.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Label(title, Tokens.title, Tokens.text, FontWeight.Bold)
                Label(hint, Tokens.small, Tokens.textSecondary, maxLines = 2)
                TvTextField(text, { text = it }, "Label", Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TvButton("Save", { onSave(text) }, primary = true)
                    TvButton(resetLabel, onReset)
                }
            }
        }
    }
}


/**
 * How the folder column appears. The page is switched between full width and split once, with no animation of the width; only the column's own fade and a short slide play (about 150 ms,
 * none with reduced motion), so the cards are never measured again and again while it opens.
 */
@Composable
fun folderEnter(): androidx.compose.animation.EnterTransition {
    val reduced = LocalReducedMotion.current
    val px = with(LocalDensity.current) { 16.dp.roundToPx() }
    return if (reduced) androidx.compose.animation.EnterTransition.None
    else androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(150)) + androidx.compose.animation.slideInHorizontally(androidx.compose.animation.core.tween(150)) { -px }
}
