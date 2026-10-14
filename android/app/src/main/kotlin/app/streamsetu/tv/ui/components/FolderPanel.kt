package app.streamsetu.tv.ui.components

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
    onRight: () -> Boolean = { false },
    selectOnDwell: Boolean = true,
    onShortcutMenu: (Shortcut) -> Unit = {},
) {
    var query by remember { mutableStateOf("") }
    var manage by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<Folder?>(null) }
    var reordering by remember { mutableStateOf<String?>(null) }
    var pinFor by remember { mutableStateOf<Folder?>(null) }
    var creatingPinFor by remember { mutableStateOf<Folder?>(null) }
    var renameFor by remember { mutableStateOf<Folder?>(null) }
    var infoFor by remember { mutableStateOf<Folder?>(null) }
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

    BackHandler(enabled = reordering != null) { reordering = null }

    fun open(f: Folder) {
        if (f.pref.locked && !actions.isUnlocked(f.id)) { if (actions.hasPin) pinFor = f else creatingPinFor = f }
        else onSelect(Browse.Folder(f.id))
    }

    Column(
        modifier.fillMaxHeight().background(Tokens.panel).padding(top = Tokens.safeVertical, bottom = 10.dp)
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
                } else if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionRight) onRight() else false
            },
    ) {
        Column(Modifier.padding(start = 20.dp, end = 12.dp, bottom = 10.dp)) {
            Label(title, Tokens.pageTitle, Tokens.text, FontWeight.Bold)
            Label(if (folders.isEmpty()) "No folders" else "%,d folders".format(folders.count { !it.pref.hidden }), Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(top = 1.dp))
        }
        TvTextField(query, { query = it }, "Search folders", Modifier.padding(horizontal = 12.dp).fillMaxWidth(), compact = true, leadingIcon = Icons.Filled.Search)
        Spacer(Modifier.height(10.dp))

        Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                itemsIndexed(rows, key = { _, r -> if (r is Shortcut) "s:${r.label}" else "f:${(r as Folder).id}" }) { idx, r ->
                    // A small heading where the shortcuts end and the provider's folders begin.
                    if (r is Folder && (idx == 0 || rows[idx - 1] is Shortcut) && visible.isNotEmpty()) Label("FOLDERS", Tokens.eyebrow, Tokens.textTertiary, FontWeight.Bold, modifier = Modifier.padding(start = 14.dp, top = if (idx == 0) 2.dp else 14.dp, bottom = 4.dp), letterSpacing = androidx.compose.ui.unit.TextUnit(1.4f, androidx.compose.ui.unit.TextUnitType.Sp))
                    if (r is Shortcut) {
                        PanelRow(r.label, r.icon, null, r.browse == selected, false, if (r.browse == selected && entry != null) Modifier.focusRequester(entry) else Modifier, onFocusDwell = { if (selectOnDwell) onSelect(r.browse) }, onLongClick = if (r.browse is Browse.Collection) ({ onShortcutMenu(r) }) else null, onClick = { onSelect(r.browse) })
                    } else {
                        val f = r as Folder
                        val isSel = selected == Browse.Folder(f.id)
                        PanelRow(
                            f.title, if (f.pref.locked) Icons.Filled.Lock else if (f.pref.pinned) Icons.Filled.PushPin else if (f.pref.favorite) Icons.Filled.Star else Icons.Filled.Folder,
                            f.count.takeIf { it > 0 }, isSel, f.pref.hidden, (if (reordering == f.id) Modifier.background(Tokens.accent.copy(alpha = 0.18f)) else Modifier).then(if (isSel && entry != null) Modifier.focusRequester(entry) else Modifier),
                            onFocusDwell = { if (selectOnDwell && !(f.pref.locked && !actions.isUnlocked(f.id))) onSelect(Browse.Folder(f.id)) },
                            onLongClick = { menuFor = f }, onClick = { open(f) }, reordering = reordering == f.id,
                        )
                    }
                }
                if (q.isNotEmpty() && visible.isEmpty()) item(key = "none") { Label("No folder matches “$query”.", Tokens.small, Tokens.textTertiary, modifier = Modifier.padding(12.dp), maxLines = 2) }
            }
        }
        // Always at the bottom, outside the scrolling list.
        Box(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) { PanelRow(if (manage) "Done managing" else "Manage folders", Icons.Filled.Tune, null, false, false, Modifier, onClick = { manage = !manage }) }
    }

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
            listOf(MenuAction("Reset this folder", Icons.Filled.RestartAlt) { actions.resetFolder(f) }, MenuAction("Cancel", Icons.Filled.Close) {}), onClose = { resetFor = null })
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

@Composable
private fun PanelRow(label: String, icon: ImageVector, count: Int?, selected: Boolean, dimmed: Boolean, extra: Modifier, onFocusDwell: () -> Unit = {}, onLongClick: (() -> Unit)? = null, reordering: Boolean = false, onClick: () -> Unit) {
    var dwellKey by remember { mutableIntStateOf(0) }
    var focused by remember { mutableStateOf(false) }
    // Moving the remote over folders opens one only after a short pause, so scrolling through many folders stays light.
    LaunchedEffect(dwellKey, focused) { if (focused) { kotlinx.coroutines.delay(380); onFocusDwell() } }
    // One row: [accent bar 3] [icon box 36] [name, one line] [count]. The bar marks the open folder; the soft fill marks where the remote is.
    Focusable(onClick, extra.fillMaxWidth().height(44.dp), scaleOnFocus = 1.0f, container = Color.Transparent, focusedContainer = Color(0x26FFFFFF), shape = RoundedCornerShape(12.dp), onFocus = { focused = it; dwellKey++ }, onLongClick = onLongClick) { f ->
        Row(Modifier.fillMaxHeight().padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.padding(start = 2.dp).width(3.dp).height(20.dp).background(if (selected) Tokens.accent else Color.Transparent, RoundedCornerShape(2.dp)))
            Box(Modifier.width(36.dp), Alignment.Center) {
                Image(if (reordering) Icons.Filled.SwapVert else icon, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(if (f || selected) Color.White else Tokens.textTertiary))
            }
            Label(label, Tokens.row, if (dimmed) Tokens.textTertiary else if (f || selected) Color.White else Tokens.textSecondary, if (selected) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f).padding(start = 4.dp))
            if (count != null) Label("%,d".format(count), Tokens.caption, Tokens.textTertiary, modifier = Modifier.padding(start = 8.dp))
        }
    }
}

@Composable
fun RenameDialog(current: String, onSave: (String) -> Unit, onReset: () -> Unit, onClose: () -> Unit, title: String = "Display label", hint: String = "Only changes how it looks here. The provider's name is not touched.", resetLabel: String = "Use provider name") {
    var text by remember { mutableStateOf(current) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize(), Alignment.Center) {
            Column(Modifier.width(340.dp).background(Tokens.surface, RoundedCornerShape(Tokens.radiusLarge)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
