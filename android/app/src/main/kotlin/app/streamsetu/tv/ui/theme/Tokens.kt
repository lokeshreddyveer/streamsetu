package app.streamsetu.tv.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The Mac app's default theme (Obsidian): same colours, same roles. Sizes are the Mac sizes scaled up for reading from a sofa. */
object Tokens {
    val background = Color(0xFF080C14)
    val panel = Color(0xFF0D1520)        // sidebar and top bar
    val surface = Color(0xFF0D1520)
    val card = Color(0xFF142735)
    val elevated = Color(0xFF193440)
    val accent = Color(0xFF43DCE8)
    val focusedSurface = Color(0xFF29515E)
    val text = Color(0xFFF5F6F8)
    val textSecondary = Color(0xFFB8CCD8)
    val textTertiary = Color(0xFF7F97A6)
    val line = Color(0x12FFFFFF)         // white 7 %
    val lineStrong = Color(0x24FFFFFF)   // white 14 %
    val success = Color(0xFF38B981)
    val warning = Color(0xFFE0A93B)
    val danger = Color(0xFFD9534F)
    val playPill = Color(0xFF43DCE8)     // primary actions use the accent, with dark text

    // Older names used by the screens.
    val muted get() = textSecondary
    val surfaceHigh get() = elevated
    val border get() = line
    val accent2 get() = accent

    // Mac: radius 7 / 8 / 10 / 12, sidebar 184, header 54, poster 150 x 218, landscape 240 x 135.
    val radiusSmall = 8.dp; val radius = 10.dp; val radiusPanel = 12.dp; val radiusLarge = 16.dp
    val sidebarWidth = 176.dp
    val headerHeight = 44.dp
    val posterWidth = 112.dp
    val landscapeWidth = 196.dp
    val screenPadding = 32.dp
    /** About 5 % of the screen on each side, kept clear of the edge (television-safe area). */
    val safeHorizontal = 48.dp
    val safeVertical = 27.dp
    val sidebarCompact = 36.dp
    val sidebarExpanded = 130.dp
    val folderPanelWidth = 190.dp

    val display = 24.sp; val pageTitle = 19.sp; val title = 17.sp; val heading = 15.sp
    val nav = 13.sp; val body = 13.sp; val row = 13.sp; val small = 12.sp; val caption = 11.sp; val eyebrow = 10.sp
}
