package app.streamsetu.tv.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The Mac app's default theme (Obsidian): same colours, same roles. Sizes are the Mac sizes scaled up for reading from a sofa. */
object Tokens {
    val background = Color(0xFF0B0D12)
    val panel = Color(0xFF11141B)        // sidebar and top bar
    val surface = Color(0xFF0F1218)
    val card = Color(0xFF151922)
    val elevated = Color(0xFF1B202A)
    val accent = Color(0xFF2BB8F0)
    val text = Color(0xFFF5F6F8)
    val textSecondary = Color(0xFFA2A7B2)
    val textTertiary = Color(0xFF77808E)
    val line = Color(0x12FFFFFF)         // white 7 %
    val lineStrong = Color(0x24FFFFFF)   // white 14 %
    val success = Color(0xFF38B981)
    val warning = Color(0xFFF0B34A)
    val danger = Color(0xFFEF5350)
    val playPill = Color(0xFFFF6B5A)     // the coral Play pill

    // Older names used by the screens.
    val muted get() = textSecondary
    val surfaceHigh get() = elevated
    val border get() = line
    val accent2 get() = accent

    // Mac: radius 7 / 8 / 10 / 12, sidebar 184, header 54, poster 150 x 218, landscape 240 x 135.
    val radiusSmall = 7.dp; val radius = 8.dp; val radiusPanel = 10.dp; val radiusLarge = 12.dp
    val sidebarWidth = 200.dp
    val headerHeight = 52.dp
    val posterWidth = 138.dp
    val landscapeWidth = 240.dp
    val screenPadding = 40.dp

    val display = 30.sp; val pageTitle = 23.sp; val title = 20.sp; val heading = 17.sp
    val nav = 14.sp; val body = 15.sp; val row = 14.sp; val small = 13.sp; val caption = 12.sp; val eyebrow = 11.sp
}
