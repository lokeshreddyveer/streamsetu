package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.ui.theme.Tokens

private fun Tab.icon(): ImageVector = when (this) {
    Tab.HOME -> Icons.Filled.Home
    Tab.LIVE -> Icons.Filled.LiveTv
    Tab.FAVOURITES -> Icons.Filled.Favorite
    Tab.MOVIES -> Icons.Filled.Movie
    Tab.SERIES -> Icons.Filled.VideoLibrary
    Tab.SEARCH -> Icons.Filled.Search
    Tab.SETTINGS -> Icons.Filled.Settings
}

@Composable
fun SideRail(selected: Tab, onSelect: (Tab) -> Unit) {
    Column(Modifier.fillMaxHeight().width(210.dp).padding(start = 24.dp, top = 40.dp, end = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Label("StreamSetu", Tokens.heading, Tokens.accent, FontWeight.Bold, modifier = Modifier.padding(start = 10.dp, bottom = 18.dp))
        Tab.entries.forEach { tab ->
            Focusable(
                onClick = { onSelect(tab) }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp),
                container = if (tab == selected) Tokens.surfaceHigh else Tokens.background, scaleOnFocus = 1.03f,
            ) { focused ->
                Row(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Image(tab.icon(), null, Modifier.size(24.dp), colorFilter = ColorFilter.tint(if (tab == selected || focused) Tokens.accent else Tokens.muted))
                    Label(tab.title, color = if (tab == selected || focused) Tokens.text else Tokens.muted, weight = if (tab == selected) FontWeight.SemiBold else FontWeight.Normal)
                }
            }
        }
    }
}
