package app.streamsetu.tv.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Overlay
import app.streamsetu.tv.play
import app.streamsetu.tv.ui.components.*
import app.streamsetu.tv.ui.theme.Tokens

@Composable
fun Shelf(title: String, padding: PaddingValues = PaddingValues(horizontal = Tokens.screenPadding, vertical = 6.dp), content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        Label(title, Tokens.heading, Tokens.text, FontWeight.Bold, modifier = Modifier.padding(start = Tokens.screenPadding, top = 4.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = padding, content = content)
    }
}

@Composable
fun ChannelShelf(title: String, channels: List<Channel>, c: AppContainer, nav: Navigator, padding: PaddingValues) {
    Shelf(title, padding) {
        items(channels, key = { it.id }) { ch ->
            Focusable({ play(c, nav, ChannelPlayable(ch), channels.map { ChannelPlayable(it) }) }, Modifier.width(96.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(Tokens.radius)) {
                Column(Modifier.padding(horizontal = 8.dp, vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    ChannelLogo(ch.logoUrl, ch.name, 44.dp)
                    Label(ch.name, Tokens.caption, Tokens.text, FontWeight.Medium)
                }
            }
        }
    }
}

/** "★ 7.3" for a rating worth showing (providers send 0 or nothing when they do not know). */
fun ratingBadge(r: String?): String? = r?.toDoubleOrNull()?.takeIf { it > 0.0 }?.let { "★ " + (if (it >= 10) "10" else String.format("%.1f", it)) }
