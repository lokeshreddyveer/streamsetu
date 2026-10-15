package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.Movie
import app.streamsetu.tv.ui.theme.Tokens

/** The films of a franchise on a line, in the order they came out, numbered and dated. The open film is marked and the others open when chosen. */
@Composable
fun FranchiseTimeline(films: List<Movie>, currentId: String, onOpen: (Movie) -> Unit) {
    if (films.size < 2) return
    Column {
        SectionTitle("Timeline  ·  ${films.size} films" + (films.mapNotNull { it.year }.let { y -> if (y.isEmpty()) "" else "  ·  ${y.min()} – ${y.max()}" }))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
            items(films.withIndex().toList(), key = { it.value.id }) { (i, m) ->
                val here = m.id == currentId
                Column(Modifier.width(Tokens.posterWidth + 14.dp).padding(end = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    PosterCard(m.title, m.posterUrl, { if (!here) onOpen(m) }, subtitle = if (here) "You are here" else null)
                    TimelineRail(i, films.size, films.indexOfFirst { it.id == currentId }.coerceAtLeast(0))
                    Label(m.year?.toString() ?: "", Tokens.small, if (here) Tokens.accent else Tokens.text, FontWeight.SemiBold)
                }
            }
        }
    }
}

/** One piece of the line through the numbered dots; the part up to the open film is lit. It runs the card's width plus its gap, so the pieces meet. */
@Composable
fun TimelineRail(index: Int, count: Int, hereIndex: Int) {
    val lit = Tokens.accent
    val dim = Tokens.textTertiary.copy(alpha = 0.4f)
    val reached = index <= hereIndex
    Box(Modifier.fillMaxWidth().height(28.dp), Alignment.Center) {
        Row(Modifier.fillMaxWidth().height(3.dp)) {
            Box(Modifier.weight(1f).fillMaxHeight().background(if (index == 0) Color.Transparent else if (reached) lit else dim))
            Box(Modifier.weight(1f).fillMaxHeight().background(if (index == count - 1) Color.Transparent else if (index < hereIndex) lit else dim))
        }
        val size = if (index == hereIndex) 28.dp else 22.dp
        Box(Modifier.size(size).background(if (reached) lit else dim, CircleShape), Alignment.Center) {
            Label("${index + 1}", Tokens.small, if (reached) Color.White else Tokens.textSecondary, FontWeight.Bold)
        }
    }
}
