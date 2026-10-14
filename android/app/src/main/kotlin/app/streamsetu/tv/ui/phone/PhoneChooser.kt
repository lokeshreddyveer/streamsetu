package app.streamsetu.tv.ui.phone

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import app.streamsetu.core.model.LibraryEntry
import app.streamsetu.core.model.SourceType
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Base
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.Loading
import app.streamsetu.tv.ui.screens.library.LibraryViewModel
import app.streamsetu.tv.ui.theme.Tokens

private fun typeOf(e: LibraryEntry) = when (e.typeLabel) { "Stalker portal" -> SourceType.STALKER; "M3U URL" -> SourceType.M3U; "Local M3U file" -> SourceType.LOCAL_FILE; else -> SourceType.XTREAM }

/** The first screen of every launch: pick the library to open. A tap opens it; the three dots manage it. */
@Composable
fun PhoneChooser(c: AppContainer, nav: Navigator, vm: LibraryViewModel = hiltViewModel()) {
    val entries by vm.entries.collectAsState()
    var addMenu by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<LibraryEntry?>(null) }

    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Ph.gutter, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(app.streamsetu.tv.R.drawable.brand_logo), null, Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row { Label("Stream", Ph.title, Tokens.text, FontWeight.Bold); Label("Setu", Ph.title, Tokens.gold, FontWeight.Bold) }
                Label("Your streams. One home.", Ph.caption, Tokens.textSecondary)
            }
            IconTap(Icons.Filled.Settings, "Settings", { nav.openSettingsFromChooser() })
        }
        Label("Choose your library", Ph.heading, Tokens.text, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = Ph.gutter))
        Label("Tap a connection to start watching.", Ph.small, Tokens.textSecondary, modifier = Modifier.padding(horizontal = Ph.gutter, vertical = 4.dp))
        val list = entries
        if (list == null) Loading(Modifier.weight(1f)) else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(Ph.gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(list, key = { it.id }) { e -> Row(e, onOpen = {
                if (e.kind == LibraryEntry.Kind.UNFINISHED) nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) else vm.open(e) { nav.enterLibrary() }
            }, onMore = { menuFor = e }) }
            item {
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFF131314)).clickable { addMenu = true }.padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Tile(Icons.Filled.Add, Color(0xFF2A2A2C), Color.White)
                    Column(Modifier.weight(1f)) { Label("Add a library", Ph.body, Tokens.text, FontWeight.SemiBold); Label("Xtream Codes, M3U link or file, Stalker", Ph.caption, Tokens.textSecondary) }
                }
            }
        }
    }

    if (addMenu) Sheet("Add a library", listOf(
        SheetItem("Xtream Codes", Icons.Filled.Dns) { nav.base = Base.Setup(SourceType.XTREAM) },
        SheetItem("M3U link", Icons.Filled.Link) { nav.base = Base.Setup(SourceType.M3U) },
        SheetItem("Stalker / Ministra portal", Icons.Filled.Router) { nav.base = Base.Setup(SourceType.STALKER) },
        SheetItem("M3U file from this phone", Icons.Filled.Description) { nav.base = Base.Setup(SourceType.LOCAL_FILE) },
        SheetItem("Combine libraries", Icons.Filled.Layers) { nav.base = Base.Combined() },
    ), onClose = { addMenu = false })
    menuFor?.let { e -> Sheet(e.name, buildList {
        if (e.kind != LibraryEntry.Kind.UNFINISHED) add(SheetItem("Open", Icons.Filled.PlayArrow) { vm.open(e) { nav.enterLibrary() } })
        if (e.kind == LibraryEntry.Kind.UNFINISHED) add(SheetItem("Continue setup", Icons.Filled.Edit) { nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) })
        if (e.kind == LibraryEntry.Kind.CONNECTION) add(SheetItem("Edit connection", Icons.Filled.Edit) { nav.base = Base.Setup(typeOf(e), e.sourceIds.first()) })
        if (e.kind == LibraryEntry.Kind.COMBINED) add(SheetItem("Edit members", Icons.Filled.Layers) { nav.base = Base.Combined(e) })
        add(SheetItem("More options", Icons.Filled.Tune) { nav.open(Overlay.ManageLibrary(e)) })
    }, onClose = { menuFor = null }) }
}

@Composable
private fun Tile(icon: androidx.compose.ui.graphics.vector.ImageVector, bg: Color, tint: Color) {
    Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(bg), Alignment.Center) { Icon(icon, tint, 22.dp) }
}

@Composable
private fun Row(e: LibraryEntry, onOpen: () -> Unit, onMore: () -> Unit) {
    val (bg, tint) = when {
        e.kind == LibraryEntry.Kind.COMBINED -> Color(0xFF2A2A2C) to Color.White
        e.kind == LibraryEntry.Kind.UNFINISHED -> Color(0xFF4A3A14) to Tokens.gold
        e.typeLabel == "M3U URL" -> Color(0xFF3A2A66) to Color(0xFFA48BFF)
        e.typeLabel == "Local M3U file" -> Color(0xFF14463A) to Color(0xFF3DDCA8)
        else -> Color(0xFF1B3A5C) to Color(0xFF4DA3FF)
    }
    val health = when (e.health) {
        LibraryEntry.Health.OK -> "Ready" to Tokens.success
        LibraryEntry.Health.NEVER_READ -> "Not read yet" to Tokens.warning
        LibraryEntry.Health.LAST_READ_FAILED -> "Last refresh failed" to Tokens.warning
        LibraryEntry.Health.UNFINISHED -> "Setup not finished" to Tokens.warning
    }
    androidx.compose.foundation.layout.Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFF131314)).clickable(onClick = onOpen).padding(start = 14.dp, top = 8.dp, bottom = 8.dp, end = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Tile(when { e.kind == LibraryEntry.Kind.COMBINED -> Icons.Filled.Layers; e.kind == LibraryEntry.Kind.UNFINISHED -> Icons.Filled.Edit; else -> Icons.Filled.Dns }, bg, tint)
        Column(Modifier.weight(1f)) {
            Label(e.name, Ph.body, Tokens.text, FontWeight.SemiBold)
            androidx.compose.foundation.layout.Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(7.dp).background(health.second, CircleShape))
                Label(health.first + if (e.kind == LibraryEntry.Kind.UNFINISHED) "" else "  ·  " + (if (e.kind == LibraryEntry.Kind.COMBINED) "${e.sourceIds.size} sources" else e.typeLabel), Ph.caption, Tokens.textSecondary)
            }
        }
        IconTap(Icons.Filled.MoreVert, "Options", onMore, tint = Tokens.textSecondary)
    }
}
