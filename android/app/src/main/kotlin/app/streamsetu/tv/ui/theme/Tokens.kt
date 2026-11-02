package app.streamsetu.tv.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The page and card colours of one theme. */
enum class Theme(val label: String, val background: Color, val panel: Color, val card: Color, val elevated: Color, val focused: Color) {
    /** A neutral cinematic charcoal. Colour comes from artwork; the interface stays out of the way. */
    CINEMA("Cinema", Color(0xFF0B0D10), Color(0xFF101317), Color(0xFF14171B), Color(0xFF20242A), Color(0xFF303740)),
    CINEMATIC("Cinematic", Color(0xFF07080C), Color(0xFF0D0F15), Color(0xFF13161F), Color(0xFF1B1F2B), Color(0xFF282D3D)),
    OBSIDIAN("Obsidian", Color(0xFF050505), Color(0xFF0A0A0A), Color(0xFF151515), Color(0xFF1E1E1E), Color(0xFF2A2A2A)),
    AMOLED("Amoled black", Color(0xFF000000), Color(0xFF000000), Color(0xFF0D0D0D), Color(0xFF181818), Color(0xFF262626)),
    MIDNIGHT("Midnight", Color(0xFF060912), Color(0xFF0A0E1A), Color(0xFF111827), Color(0xFF1B2438), Color(0xFF26324A)),
    SLATE("Slate", Color(0xFF0D1014), Color(0xFF12161C), Color(0xFF1B2028), Color(0xFF252B35), Color(0xFF313845)),
    FOREST("Forest", Color(0xFF060C09), Color(0xFF0A120E), Color(0xFF111C16), Color(0xFF1A2A21), Color(0xFF253A2E));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: AMOLED }
}

/**
 * The colours of Projector Mode, in one place. A projector with weak blacks, a washed-out picture or a lit room cannot show near-black surfaces, so every surface here is a visibly
 * lighter slate, text is white or near white, and the lines are stronger. Nothing here is pure black. It is used instead of the chosen theme, never on top of it: the theme and the
 * accent stay saved, and turning the mode off brings them back.
 */
object ProjectorPalette {
    val background = Color(0xFF151A20); val panel = Color(0xFF1B222B); val card = Color(0xFF252E39); val elevated = Color(0xFF303B48); val focusedSurface = Color(0xFF3B4B5E)
    val text = Color(0xFFFFFFFF); val textSecondary = Color(0xFFD8DEE6); val textTertiary = Color(0xFFB0BAC6)
    /** Success, warning and danger, lifted so they are readable (4.5:1 or better) on every Projector surface, the lifted focused one included. */
    val success = Color(0xFF72E5B4); val warning = Color(0xFFFFD180); val danger = Color(0xFFFFB4AB)
    val line = Color(0x3DFFFFFF); val lineStrong = Color(0x66FFFFFF); val focusRing = Color(0xFFFFFFFF); val onBright = Color(0xFF071016)
    /** The accent is lifted a little towards white so it reads on a lit screen. */
    fun accent(chosen: Color) = androidx.compose.ui.graphics.lerp(chosen, Color.White, 0.18f)
    // Dimming layers over a page or over artwork (a menu behind a sheet, the text side of a hero): slate, not black.
    val scrim = Color(0x8C151A20); val scrimStrong = Color(0xB3151A20)
    val heroTextScrimStrong = Color(0xE61B222B); val heroTextScrimMiddle = Color(0xA61B222B); val heroTextScrimClear = Color.Transparent; val heroBottomScrim = background
    val heroTopScrim = Color(0xB31B222B); val heroPosterTint = Color(0x731B222B)
    val sheetScrimMid = Color(0xB31B222B); val sheetScrimMidStrong = Color(0xBF1B222B)
    val playerCenterScrim = Color(0xCC1B222B); val playerControlsScrim = Color(0xCC1B222B); val playerControlsScrimStrong = Color(0xEB1B222B); val playerMenuScrim = Color(0xF51B222B)
    val playerChip = Color(0x991B222B); val playerButton = Color(0x8C1B222B); val playerTrack = Color(0x80303B48)
    val chipScrim = Color(0xCC1B222B); val chipScrimSoft = Color(0xB31B222B); val progressTrack = Color(0xB3151A20); val ringBand = Color(0xFF071016)
}

/** A highlight colour. */
enum class Accent(val label: String, val color: Color) {
    EMBER("Ember", Color(0xFFFF6B3D)), CYAN("Cyan", Color(0xFF4CC9D8)), GOLD("Gold", Color(0xFFF5AD42)), VIOLET("Violet", Color(0xFFA48BFF)), GREEN("Green", Color(0xFF3DDCA8)), ROSE("Rose", Color(0xFFFF6B8A)), BLUE("Blue", Color(0xFF4DA3FF));
    companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: BLUE }
}

/**
 * The Mac app's default theme: same colours, same roles. Sizes are for reading from a sofa and follow the real size of the screen (see [UiScale]).
 * The colours that can change with the theme and accent are read from state, so every screen that uses them redraws when they change.
 */
object Tokens {

    private var themeState by mutableStateOf(Theme.AMOLED)
    private var accentState by mutableStateOf(Accent.BLUE)
    private var projectorState by mutableStateOf(false)
    /**
     * Sets the look of the whole app, once, at the root. [projectorMode] is independent of the theme: the chosen [theme] and [accent] are kept as they are and come back the moment the mode
     * is turned off. Every colour below is read from this state, so a change redraws exactly the screens that use it.
     */
    fun apply(theme: Theme, accent: Accent, projectorMode: Boolean) { themeState = theme; accentState = accent; projectorState = projectorMode }
    /** True while Projector Mode is on. For the few places that draw something different (the focus frame); colours never need it, they are read from the roles below. */
    val projector get() = projectorState
    /** For a surface that a screen must keep in its own look in the normal themes (the opening screens, a toast) but that Projector Mode draws from the palette. */
    fun pick(normal: Color, projectorColor: Color): Color = if (projectorState) projectorColor else normal

    val background get() = if (projectorState) ProjectorPalette.background else themeState.background
    val panel get() = if (projectorState) ProjectorPalette.panel else themeState.panel        // sidebar and top bar
    val surface get() = panel
    val card get() = if (projectorState) ProjectorPalette.card else themeState.card
    val elevated get() = if (projectorState) ProjectorPalette.elevated else themeState.elevated
    val accent get() = if (projectorState) ProjectorPalette.accent(accentState.color) else accentState.color
    /** The accent, under its older name: the focus colour of Home, the sidebar marker and the opening screen. */
    val gold get() = accent
    /** A lighter shade of the accent, for text and icons that need to stand out on a focused item. */
    val goldHighlight get() = androidx.compose.ui.graphics.lerp(accent, Color.White, 0.35f)
    val focusedSurface get() = if (projectorState) ProjectorPalette.focusedSurface else themeState.focused
    val text get() = if (projectorState) ProjectorPalette.text else Color(0xFFF7F8FA)
    val textSecondary get() = if (projectorState) ProjectorPalette.textSecondary else Color(0xFFADB4BE)
    val textTertiary get() = if (projectorState) ProjectorPalette.textTertiary else Color(0xFF777F8B)
    /** The focus ring and the primary button: white, so the one bright thing on the screen is the thing the remote is on. */
    val focusRing = Color.White
    /** Text on a white or accent fill. */
    val onBright get() = if (projectorState) ProjectorPalette.onBright else Color(0xFF0B0D10)
    val line get() = if (projectorState) ProjectorPalette.line else Color(0x12FFFFFF)                 // white 7 % (24 % in Projector Mode)
    val lineStrong get() = if (projectorState) ProjectorPalette.lineStrong else Color(0x24FFFFFF)     // white 14 % (40 % in Projector Mode)

    // ---- Dimming layers. Named by what they are for, so a screen asks for the role and never for a colour; none of them is used over the video itself.
    /** The shade behind a menu or the sidebar while it is open. */
    val scrim get() = if (projectorState) ProjectorPalette.scrim else Color(0x73000000)
    /** The shade behind a dialog. */
    val scrimStrong get() = if (projectorState) ProjectorPalette.scrimStrong else Color(0x8C000000)
    /** A hero or banner: the side the title and the buttons are on, fading to clear across the picture. */
    val heroTextScrimStrong get() = if (projectorState) ProjectorPalette.heroTextScrimStrong else themeState.background.copy(alpha = 0.92f)
    val heroTextScrimMiddle get() = if (projectorState) ProjectorPalette.heroTextScrimMiddle else themeState.background.copy(alpha = 0.4f)
    val heroTextScrimClear get() = Color.Transparent
    /** Where the middle and the clear end of that fade are (as a share of the width): in Projector Mode the fade is shorter, so the picture itself stays visible on the right. */
    val heroScrimMiddleStop get() = if (projectorState) 0.38f else 0.5f
    val heroScrimClearStop get() = if (projectorState) 0.72f else 0.85f
    val heroTopScrim get() = if (projectorState) ProjectorPalette.heroTopScrim else themeState.background.copy(alpha = 0.75f)
    val heroBottomScrim get() = background
    /** The tint under a portrait poster shown on a hero that only has a portrait picture. */
    val heroPosterTint get() = if (projectorState) ProjectorPalette.heroPosterTint else themeState.background.copy(alpha = 0.55f)
    /** The side of a sheet that holds text, over the page. */
    val sheetScrimMid get() = if (projectorState) ProjectorPalette.sheetScrimMid else Color(0x8C000000)
    val sheetScrimMidStrong get() = if (projectorState) ProjectorPalette.sheetScrimMidStrong else Color(0x99000000)
    /** The player's own controls: the top and bottom bars, a menu over the picture, a chip, a round button and the track of a progress bar. The picture itself is never touched. */
    val playerCenterScrim get() = if (projectorState) ProjectorPalette.playerCenterScrim else Color(0xCC000000)
    val playerControlsScrim get() = if (projectorState) ProjectorPalette.playerControlsScrim else Color(0xB3000000)
    val playerControlsScrimStrong get() = if (projectorState) ProjectorPalette.playerControlsScrimStrong else Color(0xD9000000)
    val playerControlsScrimBottom get() = if (projectorState) ProjectorPalette.playerControlsScrimStrong else Color(0xE6000000)
    val playerMenuScrim get() = if (projectorState) ProjectorPalette.playerMenuScrim else Color(0xF2000000)
    val playerChip get() = if (projectorState) ProjectorPalette.playerChip else Color(0x59000000)
    val playerButton get() = if (projectorState) ProjectorPalette.playerButton else Color(0x73000000)
    val playerTrack get() = if (projectorState) ProjectorPalette.playerTrack else Color(0x66000000)
    /** A small label or round badge over artwork (the year, the lock, the new-episode mark), and the unfilled part of a progress bar over artwork. */
    val chipScrim get() = if (projectorState) ProjectorPalette.chipScrim else Color(0xB3000000)
    val chipScrimSoft get() = if (projectorState) ProjectorPalette.chipScrimSoft else Color(0xA6000000)
    val progressTrack get() = if (projectorState) ProjectorPalette.progressTrack else Color(0x66000000)
    /** The dark edge beside a focus ring that keeps it visible on bright artwork. */
    val ringBand get() = if (projectorState) ProjectorPalette.ringBand else Color.Black
    val success get() = if (projectorState) ProjectorPalette.success else Color(0xFF38B981)
    val warning get() = if (projectorState) ProjectorPalette.warning else Color(0xFFE0A93B)
    val danger get() = if (projectorState) ProjectorPalette.danger else Color(0xFFD9534F)
    val playPill get() = accent     // primary actions use the accent (the lifted one in Projector Mode), with dark text

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
    val sidebarExpanded get() = (UiScale.widthDp * 0.23f).coerceIn(200f, 280f).dp
    /** The folder column is narrower than the main sidebar (about 19 % of the screen), so the page keeps most of the width. */
    val folderPanelWidth get() = (UiScale.widthDp * (250f / 960f)).coerceIn(200f, 320f).dp          // 250 dp on a 960 dp wide television: wide enough for most folder names on one or two lines

    /** Hero title 40; screen title 32; section title 23; card title 17; navigation 17; metadata 14; badge 13. */
    val hero = 34.sp; val display = 28.sp; val pageTitle = 28.sp; val title = 20.sp; val heading = 16.sp
    val nav = 15.sp; val body = 15.sp; val row = 15.sp; val small = 13.sp; val caption = 12.sp; val eyebrow = 11.sp
}

/** Poster widths for a 1280 dp wide screen, scaled by the real width (the phone layout keeps its own sizes). */
val app.streamsetu.core.settings.PosterSize.tv: androidx.compose.ui.unit.Dp get() = when (this) {
    app.streamsetu.core.settings.PosterSize.COMPACT -> 140.ui
    app.streamsetu.core.settings.PosterSize.STANDARD -> 172.ui
    app.streamsetu.core.settings.PosterSize.LARGE -> 208.ui
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
