package app.streamsetu.tv.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The page and card colours of one theme. */
enum class Theme(val label: String, val background: Color, val panel: Color, val card: Color, val elevated: Color, val focused: Color) {
    /** The default: a neutral cinematic charcoal. Colour comes from artwork; the interface stays out of the way. */
    CINEMA("Cinema", Color(0xFF0B0D10), Color(0xFF101317), Color(0xFF14171B), Color(0xFF20242A), Color(0xFF303740)),
    CINEMATIC("Cinematic", Color(0xFF07080C), Color(0xFF0D0F15), Color(0xFF13161F), Color(0xFF1B1F2B), Color(0xFF282D3D)),
    OBSIDIAN("Obsidian", Color(0xFF050505), Color(0xFF0A0A0A), Color(0xFF151515), Color(0xFF1E1E1E), Color(0xFF2A2A2A)),
    AMOLED("Amoled black", Color(0xFF000000), Color(0xFF000000), Color(0xFF0D0D0D), Color(0xFF181818), Color(0xFF262626)),
    MIDNIGHT("Midnight", Color(0xFF060912), Color(0xFF0A0E1A), Color(0xFF111827), Color(0xFF1B2438), Color(0xFF26324A)),
    SLATE("Slate", Color(0xFF0D1014), Color(0xFF12161C), Color(0xFF1B2028), Color(0xFF252B35), Color(0xFF313845)),
    FOREST("Forest", Color(0xFF060C09), Color(0xFF0A120E), Color(0xFF111C16), Color(0xFF1A2A21), Color(0xFF253A2E));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: CINEMA }
}

/** A highlight colour. */
enum class Accent(val label: String, val color: Color) {
    EMBER("Ember", Color(0xFFFF6B3D)), CYAN("Cyan", Color(0xFF4CC9D8)), GOLD("Gold", Color(0xFFF5AD42)), VIOLET("Violet", Color(0xFFA48BFF)), GREEN("Green", Color(0xFF3DDCA8)), ROSE("Rose", Color(0xFFFF6B8A)), BLUE("Blue", Color(0xFF4DA3FF));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: CYAN }
}

/**
 * The Mac app's default theme (Obsidian): same colours, same roles. Sizes are the Mac sizes scaled up for reading from a sofa.
 * The colours that can change with the theme and accent are read from state, so every screen that uses them redraws when they change.
 */
object Tokens {
    private var themeState by mutableStateOf(Theme.CINEMA)
    private var accentState by mutableStateOf(Accent.CYAN)
    fun apply(theme: Theme, accent: Accent) { themeState = theme; accentState = accent }

    val background get() = themeState.background
    val panel get() = themeState.panel        // sidebar and top bar
    val surface get() = themeState.panel
    val card get() = themeState.card
    val elevated get() = themeState.elevated
    val accent get() = accentState.color
    /** The accent, under its older name: the focus colour of Home, the sidebar marker and the opening screen. */
    val gold get() = accentState.color
    /** A lighter shade of the accent, for text and icons that need to stand out on a focused item. */
    val goldHighlight get() = androidx.compose.ui.graphics.lerp(accentState.color, Color.White, 0.35f)
    val focusedSurface get() = themeState.focused
    val text = Color(0xFFF7F8FA)
    val textSecondary = Color(0xFFADB4BE)
    val textTertiary = Color(0xFF777F8B)
    /** The focus ring and the primary button: white, so the one bright thing on the screen is the thing the remote is on. */
    val focusRing = Color.White
    /** Text on a white or accent fill. */
    val onBright = Color(0xFF0B0D10)
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
    val radiusSmall = 6.dp; val radius = 10.dp; val radiusPanel = 14.dp; val radiusLarge = 16.dp
    val sidebarWidth = 176.dp
    val headerHeight = 44.dp
    /** Design canvas 960 x 540 dp, 12 columns of 52 dp with 20 dp gutters (844 dp of content, 58 dp each side). Posters 6 across = 124 dp (2:3), landscape cards 4 across = 196, 3 across = 268 (16:9). */
    val posterWidth = 124.dp
    val landscapeWidth = 268.dp
    val gutter = 20.dp
    val screenPadding = 32.dp
    /** About 5 % of the screen on each side, kept clear of the edge (television-safe area). */
    val safeHorizontal = 58.dp
    val safeVertical = 27.dp
    val sidebarCompact = 64.dp
    val sidebarExpanded = 184.dp
    val folderPanelWidth = 168.dp

    /** Hero title 44; screen title 32; section title 22; card title 18; navigation 18; metadata 15; button 17. */
    val hero = 44.sp; val display = 34.sp; val pageTitle = 30.sp; val title = 22.sp; val heading = 18.sp
    val nav = 18.sp; val body = 16.sp; val row = 17.sp; val small = 15.sp; val caption = 13.sp; val eyebrow = 11.sp
}

/** Poster widths on the television's 960 dp canvas: 8, 6 or 5 across (the phone layout keeps its own sizes). */
val app.streamsetu.core.settings.PosterSize.tv: androidx.compose.ui.unit.Dp get() = when (this) {
    app.streamsetu.core.settings.PosterSize.COMPACT -> 104.dp
    app.streamsetu.core.settings.PosterSize.STANDARD -> 124.dp
    app.streamsetu.core.settings.PosterSize.LARGE -> 152.dp
}
