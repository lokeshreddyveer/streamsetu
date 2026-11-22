package app.streamsetu.tv.ui.phone

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Lock
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.ui.components.ChannelLogo
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.screens.folders.*
import app.streamsetu.tv.ui.screens.section.Card
import app.streamsetu.tv.ui.theme.Tokens

/**
 * The Folders view on a phone: a list of folder rows, "Name (count)" and See all above about twelve tiles and a last "More" tile. Rows are read when first drawn and kept (the list, and each
 * row, remember where they were scrolled to); folders are listed 20 at a time. A locked folder shows its name and a lock, nothing else.
 */
@Composable
fun PhoneFolderRows(model: FolderRowsModel, kind: ContentKind, modifier: Modifier = Modifier, onOpenFolder: (FolderRow) -> Unit, onOpenCard: (Card) -> Unit, onOpenChannel: (Channel) -> Unit) {
    val rows by model.rows.collectAsState()
    val total by model.total.collectAsState()
    val state = model.listState
    LaunchedEffect(state, rows.size) { snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last -> if (last >= rows.size - 3) model.more() } }
    LazyColumn(modifier.fillMaxSize(), state = state, contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (rows.isEmpty()) items(3, key = { "sk$it" }, contentType = { "skeleton-row" }) {
            Column(Modifier.padding(horizontal = Ph.gutter), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.width(160.dp).height(16.dp).clip(RoundedCornerShape(6.dp)).background(Tokens.card))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { repeat(3) { Box(Modifier.width(112.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp)).background(Tokens.card)) } }
            }
        }
        items(rows, key = { it.key }, contentType = { "folder-row" }) { row ->
            LaunchedEffect(row.id, model.version.intValue) { model.load(row) }
            val tiles = model.tiles[row.id]
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PhoneFolderHeader(row, onOpenFolder)
                if (row.locked) {
                    Box(Modifier.padding(horizontal = Ph.gutter).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Tokens.card).clickable { onOpenFolder(row) }.padding(14.dp)) { Label("Locked. Open to enter the PIN.", Ph.small, Tokens.textSecondary) }
                } else LazyRow(state = model.rowState(row.id), contentPadding = PaddingValues(horizontal = Ph.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    when (tiles) {
                        null -> items(4, key = { "sk$it" }) { Box(Modifier.width(112.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp)).background(Tokens.card)) }
                        is RowTiles.Titles -> {
                            items(tiles.cards, key = { it.id }, contentType = { "poster" }) { card -> PhonePoster(card.title, card.posterUrl, { onOpenCard(card) }, Modifier.width(112.dp), itemId = card.id, subtitle = card.year?.toString() ?: " ") }
                            item(key = "more", contentType = "more") { MoreTile(onClick = { onOpenFolder(row) }, tall = true) }
                        }
                        is RowTiles.Channels -> {
                            items(tiles.items, key = { it.channel.id }, contentType = { "channel" }) { t ->
                                Column(Modifier.width(150.dp).clip(RoundedCornerShape(12.dp)).background(Tokens.card).clickable { onOpenChannel(t.channel) }.padding(10.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { ChannelLogo(t.channel.logoUrl, t.channel.name, 32.dp); Label(t.channel.name, Ph.caption, Tokens.text, FontWeight.Medium, maxLines = 1) }
                                    Label(t.now ?: "No guide", 11.sp, Tokens.textTertiary, maxLines = 1)
                                    Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(if (t.progress != null) Color(0x33FFFFFF) else Color.Transparent)) { t.progress?.let { Box(Modifier.fillMaxHeight().fillMaxWidth(it).background(Tokens.accent)) } }
                                }
                            }
                            item(key = "more", contentType = "more") { MoreTile(onClick = { onOpenFolder(row) }, tall = false) }
                        }
                    }
                }
            }
        }
        if (rows.isNotEmpty() && rows.size < total) item(key = "loading-rows") { Box(Modifier.fillMaxWidth().height(48.dp), Alignment.Center) { Label("Loading…", Ph.caption, Tokens.textTertiary) } }
    }
}

/** The heading of a folder row: the name, then the count dimmed and smaller in brackets on the same baseline, and See all. A locked folder shows a lock and no count. */
@Composable
internal fun PhoneFolderHeader(row: FolderRow, onOpenFolder: (FolderRow) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Ph.gutter), verticalAlignment = Alignment.CenterVertically) {
        if (row.locked) Icon(Icons.Filled.Lock, Tokens.textSecondary, 18.dp)
        Row(Modifier.weight(1f).padding(start = if (row.locked) 6.dp else 0.dp).clearAndSetSemantics { heading(); contentDescription = folderRowDescription(row) }, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Label(row.name, 20.sp, Tokens.text, FontWeight.Bold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
            if (!row.locked && row.count > 0) Label("(%,d)".format(row.count), Ph.small, Tokens.textTertiary, maxLines = 1)
        }
        if (!row.locked) Box(Modifier.clickable { onOpenFolder(row) }.padding(vertical = 8.dp, horizontal = 4.dp)) { Label("See all", Ph.small, Tokens.accent, FontWeight.Medium) }
    }
}

@Composable
internal fun MoreTile(onClick: () -> Unit, tall: Boolean) {
    Box(Modifier.width(if (tall) 112.dp else 90.dp).then(if (tall) Modifier.aspectRatio(2f / 3f) else Modifier.height(80.dp)).clip(RoundedCornerShape(12.dp)).background(Tokens.card)
        .semantics { contentDescription = "More titles in this folder" }.clickable(onClick = onClick), Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.ChevronRight, Tokens.text, 28.dp)
            Label("More", Ph.small, Tokens.text, FontWeight.SemiBold)
        }
    }
}
