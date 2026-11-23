package app.streamsetu.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.theme.Tokens

/** How far each of the two cards behind the lead poster shows beyond its edge (docs/SMART-MIX.md 10.3: "two cards peeking behind"). */
val CollectionPeek: Dp = 8.dp

/**
 * A franchise of the "Collections" row: the lead title's poster with two plain cards peeking out behind it to the right, the franchise name under it and "N titles".
 * The same width as every other tile plus the peek, so a row of them lines up with the rows around it.
 */
@Composable
fun CollectionTile(name: String, count: Int, posterUrl: String?, itemId: String, onClick: () -> Unit, modifier: Modifier = Modifier, width: Dp = Tokens.posterWidth) {
    Box(modifier.width(width + CollectionPeek * 2).testTag("collection-tile-$itemId")) {
        for (i in 2 downTo 1) {
            Box(Modifier.padding(start = CollectionPeek * i).width(width).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.radius)).background(Tokens.card).alpha(if (i == 2) 0.45f else 0.7f)
                .offset(y = 0.dp).testTag("collection-peek-$i"))
        }
        PosterCard(name, posterUrl, onClick, itemId = itemId, subtitle = "$count titles", width = width)
    }
}
