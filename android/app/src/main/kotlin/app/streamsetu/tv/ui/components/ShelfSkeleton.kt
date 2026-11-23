package app.streamsetu.tv.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.streamsetu.core.data.smartmix.HomeLayoutTokens
import app.streamsetu.tv.ui.screens.library.reducedMotion
import app.streamsetu.tv.ui.theme.Tokens

/**
 * A row that is still being built (docs/SMART-MIX.md section 11): the same geometry as a real row, so nothing jumps when it arrives. Title and subtitle bars, then tiles with the row gap (24 dp between rows,
 * 12 dp from header to tiles, 12 dp between tiles), a subtitle line of at least 30 dp, two reserved caption lines and one quiet line under each tile. The soft pulse stops with reduced motion.
 */
@Composable
fun ShelfSkeleton(tileWidth: Dp = Tokens.posterWidth, tiles: Int = 6, inset: Dp = 16.dp, modifier: Modifier = Modifier) {
    val pulse = if (reducedMotion()) null else rememberInfiniteTransition(label = "shelf-skeleton").animateFloat(0.55f, 1f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "pulse")
    val bar = Modifier.clip(RoundedCornerShape(6.dp)).background(Tokens.card)
    Column(modifier.fillMaxWidth().padding(bottom = HomeLayoutTokens.ROW_GAP.dp).alpha(pulse?.value ?: 1f)) {
        Box(bar.padding(horizontal = inset).width(160.dp).height(18.dp))
        Box(Modifier.heightIn(min = HomeLayoutTokens.SUBTITLE_MIN_HEIGHT.dp).padding(top = 6.dp)) { Box(bar.width(110.dp).height(12.dp)) }
        Spacer(Modifier.height(HomeLayoutTokens.HEADER_TO_TILES.dp))
        Row(Modifier.padding(horizontal = inset), horizontalArrangement = Arrangement.spacedBy(HomeLayoutTokens.TILE_GAP.dp)) {
            repeat(tiles) {
                Column(Modifier.width(tileWidth)) {
                    Box(bar.fillMaxWidth().aspectRatio(2f / 3f))
                    Spacer(Modifier.height(6.dp)); Box(bar.fillMaxWidth().height(14.dp)); Spacer(Modifier.height(4.dp)); Box(bar.fillMaxWidth(0.7f).height(14.dp)); Spacer(Modifier.height(4.dp)); Box(bar.fillMaxWidth(0.5f).height(10.dp))
                }
            }
        }
    }
}

/** The three skeleton rows shown while Home loads. */
@Composable
fun HomeSkeleton(modifier: Modifier = Modifier) = Column(modifier) { repeat(HomeLayoutTokens.SKELETON_ROWS) { ShelfSkeleton() } }
