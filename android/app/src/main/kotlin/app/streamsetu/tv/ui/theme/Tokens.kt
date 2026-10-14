package app.streamsetu.tv.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The page and card colours of one theme. */
enum class Theme(val label: String, val background: Color, val panel: Color, val card: Color, val elevated: Color, val focused: Color) {
    OBSIDIAN("Obsidian", Color(0xFF050505), Color(0xFF0A0A0A), Color(0xFF151515), Color(0xFF1E1E1E), Color(0xFF2A2A2A)),
    AMOLED("Amoled black", Color(0xFF000000), Color(0xFF000000), Color(0xFF0D0D0D), Color(0xFF181818), Color(0xFF262626)),
    MIDNIGHT("Midnight", Color(0xFF060912), Color(0xFF0A0E1A), Color(0xFF111827), Color(0xFF1B2438), Color(0xFF26324A)),
    SLATE("Slate", Color(0xFF0D1014), Color(0xFF12161C), Color(0xFF1B2028), Color(0xFF252B35), Color(0xFF313845)),
    FOREST("Forest", Color(0xFF060C09), Color(0xFF0A120E), Color(0xFF111C16), Color(0xFF1A2A21), Color(0xFF253A2E));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: OBSIDIAN }
}

/** A highlight colour. */
enum class Accent(val label: String, val color: Color) {
    CYAN("Cyan", Color(0xFF43DCE8)), GOLD("Gold", Color(0xFFF5AD42)), VIOLET("Violet", Color(0xFFA48BFF)), GREEN("Green", Color(0xFF3DDCA8)), ROSE("Rose", Color(0xFFFF6B8A)), BLUE("Blue", Color(0xFF4DA3FF));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: CYAN }
}

/**
 * The Mac app's default theme (Obsidian): same colours, same roles. Sizes are the Mac sizes scaled up for reading from a sofa.
 * The colours that can change with the theme and accent are read from state, so every screen that uses them redraws when they change.
 */
object Tokens {
    private var themeState by mutableStateOf(Theme.OBSIDIAN)
    private var accentState by mutableStateOf(Accent.CYAN)
    fun apply(theme: Theme, accent: Accent) { themeState = theme; accentState = accent }

    val background get() = themeState.background
    val panel get() = themeState.panel        // sidebar and top bar
    val surface get() = themeState.panel
    val card get() = themeState.card
    val elevated get() = themeState.elevated
    val accent get() = accentState.color
    /** The warm focus accent of the opening screen and Home. */
    val gold = Color(0xFFF5AD42)
    val goldHighlight = Color(0xFFFFCA76)
    val focusedSurface get() = themeState.focused
    val text = Color(0xFFF5F6F8)
    val textSecondary = Color(0xFFB8CCD8)
    val textTertiary = Color(0xFF7F97A6)
    val line = Color(0x12FFFFFF)         // white 7 %
    val lineStrong = Color(0x24FFFFFF)   // white 14 %
    val success = Color(0xFF38B981)
    val warning = Color(0xFFE0A93B)
    val danger = Color(0xFFD9534F)
    val playPill get() = accentState.color     // primary actions use the accent, with dark text

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
    val sidebarCompact = 58.dp
    val sidebarExpanded = 184.dp
    val folderPanelWidth = 168.dp

    val display = 26.sp; val pageTitle = 21.sp; val title = 18.sp; val heading = 16.sp
    val nav = 15.sp; val body = 14.sp; val row = 14.sp; val small = 12.sp; val caption = 11.sp; val eyebrow = 10.sp
}
