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
 * The Mac app's default theme: same colours, same roles. Sizes are for reading from a sofa and follow the real size of the screen (see [UiScale]).
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

    // Radii, spacing and television-safe margins. The sizes were designed on a 1280 dp wide screen; they are scaled by the real width of the screen (see [UiScale]) so the same proportions
    // fill a 960 dp or a 1280 dp television without any scaling of the whole picture. Text sizes are in sp and follow the television's own density.
    val radiusSmall get() = 10.ui; val radius get() = 14.ui; val radiusPanel get() = 18.ui; val radiusLarge get() = 18.ui
    /** A poster is 154 x 230 on a 1280 dp screen; the Movies and Series grids work out their own column width from the space (about seven across with the folders closed). */
    val posterWidth get() = 154.ui
    val landscapeWidth get() = 240.ui
    val gutter get() = 18.ui
    val screenPadding get() = 40.ui
    /** About 3.5 % of the width on each side, kept clear of the edge (television-safe area), and about 4 % of the height at the top and bottom. */
    val safeHorizontal get() = (UiScale.widthDp * 0.035f).coerceIn(24f, 62f).dp
    val safeVertical get() = (UiScale.heightDp * 0.04f).coerceIn(18f, 30f).dp
    /** The main sidebar takes no width while it is closed; open, it floats over the page. */
    val sidebarCompact = 0.dp
    val sidebarExpanded get() = (UiScale.widthDp * 0.19f).coerceIn(180f, 240f).dp
    /** The folder column is narrower than the main sidebar (about 19 % of the screen), so the page keeps most of the width. */
    val folderPanelWidth get() = (UiScale.widthDp * (184f / 960f)).coerceIn(160f, 230f).dp          // 184 dp on a 960 dp wide television

    /** Hero title 40; screen title 32; section title 23; card title 17; navigation 17; metadata 14; badge 13. */
    val hero = 40.sp; val display = 32.sp; val pageTitle = 32.sp; val title = 23.sp; val heading = 17.sp
    val nav = 17.sp; val body = 17.sp; val row = 17.sp; val small = 14.sp; val caption = 13.sp; val eyebrow = 12.sp
}

/** Poster widths for a 1280 dp wide screen, scaled by the real width (the phone layout keeps its own sizes). */
val app.streamsetu.core.settings.PosterSize.tv: androidx.compose.ui.unit.Dp get() = when (this) {
    app.streamsetu.core.settings.PosterSize.COMPACT -> 140.ui
    app.streamsetu.core.settings.PosterSize.STANDARD -> 154.ui
    app.streamsetu.core.settings.PosterSize.LARGE -> 168.ui
}

/**
 * The real size of the screen in dp, and the scale that follows from it: the layout sizes are written for a 1280 dp wide screen and are multiplied by [k] (the screen's width over 1280, kept
 * between 0.6 and 1.3). It is set once at the root of the television app from the actual window, before anything reads it; nothing is drawn through a scaled canvas.
 */
object UiScale {
    @Volatile var widthDp = 1280f
    @Volatile var heightDp = 720f
    val k: Float get() = (widthDp / 1280f).coerceIn(0.6f, 1.3f)
    fun apply(w: Float, h: Float) { if (w > 0f && h > 0f) { widthDp = w; heightDp = h } }
}

/** A size written for a 1280 dp wide screen, scaled to the real screen. */
val Int.ui: androidx.compose.ui.unit.Dp get() = (this * UiScale.k).dp
val Float.ui: androidx.compose.ui.unit.Dp get() = (this * UiScale.k).dp
