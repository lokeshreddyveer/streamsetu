package app.streamsetu.tv.ui.screens.folders

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.screens.section.Card
import app.streamsetu.tv.ui.theme.Tokens

private const val MORE = "more"

/**
 * Folders view on a television: one row per folder, "Name · count" and See all above about twelve tiles, the last tile "More ›" (the folder's own full grid, with its sort, filter and search).
 * Rows are lazy items that read their tiles when first drawn; ids are stable, so the list and each row keep their place, and Back from a folder puts the remote on the tile it left.
 */
@Composable
fun TvFolderRows(
    model: FolderRowsModel, kind: ContentKind, posterWidth: Dp, dense: Boolean, modifier: Modifier = Modifier,
    onOpenFolder: (FolderRow) -> Unit, onOpenCard: (Card) -> Unit, onOpenChannel: (app.streamsetu.core.model.Channel) -> Unit,
    /** Where the remote lands when it enters the page: the first tile of the first row. */
    entry: FocusRequester? = null,
) {
    val rows by model.rows.collectAsState()
    val total by model.total.collectAsState()
    val listState = model.listState
    // The end of the list is near: the next 20 folders.
    LaunchedEffect(listState, rows.size) { snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last -> if (last >= rows.size - 4) model.more() } }
    LazyColumn(modifier.fillMaxSize().railOnLeft(), state = listState, contentPadding = PaddingValues(top = 6.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (rows.isEmpty()) items(4, key = { "sk$it" }, contentType = { "skeleton-row" }) { SkeletonRow(posterWidth) }
        items(rows, key = { it.key }, contentType = { "folder-row" }) { row -> TvFolderRow(model, kind, row, posterWidth, dense, onOpenFolder, onOpenCard, onOpenChannel, if (row.id == rows.firstOrNull()?.id) entry else null) }
        if (rows.isNotEmpty() && rows.size < total) item(key = "more-rows", contentType = "loading") { SkeletonRow(posterWidth) }
    }
}

@Composable
private fun SkeletonRow(posterWidth: Dp) {
    Column(Modifier.padding(start = Tokens.safeHorizontal, top = 8.dp, bottom = 8.dp)) {
        Box(Modifier.width(220.dp).height(18.dp).clip(RoundedCornerShape(6.dp)).background(Tokens.card))
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(Tokens.gutter)) { repeat(6) { Box(Modifier.width(posterWidth).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.card)) } }
    }
}

@Composable
private fun TvFolderRow(
    model: FolderRowsModel, kind: ContentKind, row: FolderRow, posterWidth: Dp, dense: Boolean,
    onOpenFolder: (FolderRow) -> Unit, onOpenCard: (Card) -> Unit, onOpenChannel: (app.streamsetu.core.model.Channel) -> Unit, entry: FocusRequester?,
) {
    LaunchedEffect(row.id, model.version.intValue) { model.load(row) }
    val tiles = model.tiles[row.id]
    Column(Modifier.padding(bottom = 4.dp)) {
        TvFolderHeader(row, onOpenFolder)
        if (row.locked) {
            // Name and lock only: no count, no pictures. Selecting it opens the folder list, which asks for the PIN.
            LazyRow(Modifier.railOnLeft(), contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = 24.dp, top = 8.dp, bottom = 8.dp)) {
                item(key = "locked") { MoreTile("Locked", Icons.Filled.Lock, posterWidth, dense, { onOpenFolder(row) }, Modifier) }
            }
            return@Column
        }
        val restore = remember { FocusRequester() }
        val rowState = model.rowState(row.id)
        val wantsFocus = model.restoreFocus && model.focused?.first == row.id
        LazyRow(Modifier.railOnLeft().focusRestorer(), state = rowState, horizontalArrangement = Arrangement.spacedBy(Tokens.gutter), contentPadding = PaddingValues(start = Tokens.safeHorizontal, end = 24.dp, top = 8.dp, bottom = 8.dp)) {
            when (tiles) {
                null -> items(6, key = { "sk$it" }, contentType = { "skeleton" }) { Box(Modifier.width(posterWidth).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.card)) }
                is RowTiles.Titles -> {
                    items(tiles.cards, key = { it.id }, contentType = { "poster" }) { card ->
                        val mine = wantsFocus && model.focused?.second == card.id
                        PosterCard(card.title, card.posterUrl, { model.focused = row.id to card.id; onOpenCard(card) }, width = posterWidth, itemId = card.id, subtitle = card.year?.toString() ?: " ", dense = dense,
                            focusRequester = if (card.id == (tiles as RowTiles.Titles).cards.first().id && entry != null) entry else if (mine) restore else null, onFocusChange = { if (it) model.focused = row.id to card.id })
                    }
                    item(key = MORE, contentType = "more") { MoreTile("More", Icons.Filled.ChevronRight, posterWidth, dense, { model.focused = row.id to MORE; onOpenFolder(row) }, if (wantsFocus && model.focused?.second == MORE) Modifier.focusRequester(restore) else Modifier) }
                }
                is RowTiles.Channels -> {
                    items(tiles.items, key = { it.channel.id }, contentType = { "channel" }) { t ->
                        val mine = wantsFocus && model.focused?.second == t.channel.id
                        ChannelTile(t, { model.focused = row.id to t.channel.id; onOpenChannel(t.channel) }, if (t.channel.id == (tiles as RowTiles.Channels).items.first().channel.id && entry != null) Modifier.focusRequester(entry) else if (mine) Modifier.focusRequester(restore) else Modifier, onFocus = { if (it) model.focused = row.id to t.channel.id })
                    }
                    item(key = MORE, contentType = "more") { MoreTile("More", Icons.Filled.ChevronRight, 180.dp, dense, { model.focused = row.id to MORE; onOpenFolder(row) }, if (wantsFocus && model.focused?.second == MORE) Modifier.focusRequester(restore) else Modifier, tall = false) }
                }
            }
        }
        // Back from a folder: the remote goes back to the tile it left, once, when the row has its tiles.
        if (wantsFocus && tiles != null) LaunchedEffect(tiles) {
            requestFocusOnFrames(6, { runCatching { restore.requestFocus() } }, { false }); model.restoreFocus = false
        }
    }
}

/** The heading of a folder row: the name, then the count dimmed and smaller in brackets on the same baseline, and See all. A locked folder shows a lock and no count. */
@Composable
internal fun TvFolderHeader(row: FolderRow, onOpenFolder: (FolderRow) -> Unit) {
    Row(Modifier.padding(start = Tokens.safeHorizontal, end = Tokens.safeHorizontal, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        if (row.locked) Icon(Icons.Filled.Lock, Tokens.textSecondary, 18.dp)
        // "English · 4K" then the count, smaller and dimmed, in brackets, on one baseline. A locked folder shows no count. Read out as "English 4K, 1,058 titles".
        Row(Modifier.weight(1f, fill = false).clearAndSetSemantics { contentDescription = folderRowDescription(row) }, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Label(row.name, Tokens.title, Tokens.text, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
            if (!row.locked && row.count > 0) Label("(%,d)".format(row.count), Tokens.small, Tokens.textTertiary, FontWeight.Normal, maxLines = 1)
        }
        if (!row.locked) Focusable({ onOpenFolder(row) }, Modifier, shape = RoundedCornerShape(Tokens.radiusSmall), container = Color.Transparent, scaleOnFocus = 1.04f, browse = true) { f ->
            Label("See all", Tokens.small, if (f) Color.White else Tokens.textSecondary, FontWeight.Medium, modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp))
        }
    }
}

@Composable
internal fun MoreTile(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, width: Dp, dense: Boolean, onClick: () -> Unit, modifier: Modifier, tall: Boolean = true) {
    Focusable(onClick, modifier.width(width).then(if (tall) Modifier.aspectRatio(2f / 3f) else Modifier.height(96.dp)).semantics { contentDescription = if (label == "More") "More titles in this folder" else label }, container = Tokens.card, scaleOnFocus = if (dense) 1.0f else 1.04f, browse = true) { _ ->
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(icon, Tokens.text, 34.dp)
            Label(label, Tokens.body, Tokens.text, FontWeight.SemiBold)
        }
    }
}

@Composable
internal fun ChannelTile(t: ChannelTileData, onClick: () -> Unit, modifier: Modifier, onFocus: (Boolean) -> Unit) {
    Focusable(onClick, modifier.width(220.dp).height(96.dp), container = Tokens.card, scaleOnFocus = 1.0f, browse = true, onFocus = onFocus) { _ ->
        Column(Modifier.fillMaxSize().padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChannelLogo(t.channel.logoUrl, t.channel.name, 30.dp)
                Label(t.channel.name, Tokens.small, Tokens.text, FontWeight.Medium, maxLines = 1)
            }
            Label(t.now ?: "No guide", Tokens.caption, Tokens.textSecondary, maxLines = 1)
            t.progress?.let { p ->
                Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color(0x33FFFFFF))) { Box(Modifier.fillMaxHeight().fillMaxWidth(p).background(Tokens.accent)) }
            }
        }
    }
}

@Composable
private fun Icon(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, size: Dp) =
    androidx.compose.foundation.Image(icon, null, Modifier.size(size), colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(tint))

/** What a screen reader says for a folder row's heading: no separator dots, the count in words, nothing for a locked folder's count. */
fun folderRowDescription(row: FolderRow): String {
    val name = row.name.replace(" · ", " ")
    return when {
        row.locked -> "$name, locked"
        row.count > 0 -> "$name, %,d titles".format(row.count)
        else -> name
    }
}
