package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.streamsetu.core.sync.SyncProgress
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.theme.Tokens

/** The progress line of a read as two parts that can each be translated: the stage, and "12,000 of 66,000" or "24,000" when a count is known. */
internal fun fillingParts(p: SyncProgress): Pair<String, String?> {
    val n = java.text.NumberFormat.getIntegerInstance(java.util.Locale.US)
    val count = when { p.total > 0 -> "${n.format(p.done)} of ${n.format(p.total)}"; p.done > 0 -> n.format(p.done); else -> null }
    return p.stage.label to count
}

/**
 * Shown by Movies, Series and Live TV in place of an empty message while the library is still being filled (a read or the identity fill is running): says so, with the stage and the
 * count when there is one, and a thin bar when the total is known. Draws nothing once the fill is over.
 */
@Composable
fun LibraryFillingNotice(c: AppContainer, modifier: Modifier = Modifier) {
    val filling by c.fill.filling.collectAsStateWithLifecycle(initialValue = c.fill.fillingNow)
    if (!filling) return
    val progress by c.fill.progress.collectAsStateWithLifecycle()
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        BrandLoader(size = 40.dp)
        Label("Your library is being filled", Tokens.title, Tokens.text, FontWeight.SemiBold)
        Label("Titles appear here as they arrive.", Tokens.body, Tokens.textSecondary)
        progress?.let { p ->
            val (stage, count) = fillingParts(p)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Label(stage, Tokens.small, Tokens.textSecondary); count?.let { Label(it, Tokens.small, Tokens.textTertiary) } }
            p.fraction?.let { f -> Box(Modifier.width(320.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Tokens.elevated)) { Box(Modifier.fillMaxHeight().fillMaxWidth(f).background(Tokens.accent)) } }
        }
    }
}
