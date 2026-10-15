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
        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(films.withIndex().toList(), key = { it.value.id }) { (i, m) ->
                val here = m.id == currentId
                Column(Modifier.width(Tokens.posterWidth), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    PosterCard(m.title, m.posterUrl, { if (!here) onOpen(m) }, subtitle = if (here) "You are here" else null)
                    // The line runs through the dots, in this card's own width and the gap to the next one.
                    Box(Modifier.fillMaxWidth().height(14.dp), Alignment.CenterStart) {
                        Box(Modifier.fillMaxWidth().height(2.dp).background(Tokens.textTertiary))
                        Box(Modifier.size(if (here) 14.dp else 9.dp).background(if (here) Tokens.accent else Tokens.textSecondary, CircleShape))
                    }
                    Label("${i + 1}  ·  ${m.year ?: "?"}", Tokens.small, if (here) Tokens.text else Tokens.textSecondary, if (here) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
    }
}
