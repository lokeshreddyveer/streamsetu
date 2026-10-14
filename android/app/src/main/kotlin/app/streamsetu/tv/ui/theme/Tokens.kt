package app.streamsetu.tv.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The look of the Apple apps: near-black, a navy surface, cyan and blue accents. */
object Tokens {
    val background = Color(0xFF0B0D12)
    val surface = Color(0xFF151922)
    val surfaceHigh = Color(0xFF1E2430)
    val border = Color(0xFF2A3140)
    val accent = Color(0xFF22D3EE)
    val accent2 = Color(0xFF3B82F6)
    val text = Color(0xFFF3F4F6)
    val muted = Color(0xFF9CA3AF)
    val danger = Color(0xFFF87171)
    val success = Color(0xFF34D399)

    /** A TV is read from the sofa: no text below 14 sp, and generous edges (overscan). */
    val screenPadding = 48.dp
    val body = 18.sp
    val small = 14.sp
    val title = 28.sp
    val heading = 22.sp
}
