package app.streamsetu.tv.ui.screens.library

import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.ui.motion.LocalReducedMotion
import app.streamsetu.core.ui.motion.Motion
import app.streamsetu.tv.ui.components.Focusable
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.components.TvButton
import app.streamsetu.tv.ui.components.TvFocusStyle
import app.streamsetu.tv.ui.phone.glossy
import app.streamsetu.tv.ui.phone.isPhoneDevice
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.delay

/**
 * The ways to connect offered on the welcome screen, each mapped onto the connection kinds the app already has. A tile with more than one kind opens the form with a small chooser
 * between them at the top. There is no tile for a single stream: the app has no connection kind for one.
 */
internal enum class ConnectTile(val title: String, private val subtitle: String, val icon: ImageVector, private val kinds: List<SourceType>) {
    PLAYLIST_LINK("Playlist link", "An M3U or M3U8 address", Icons.Filled.Link, listOf(SourceType.M3U)),
    XTREAM("Xtream Codes", "Server, user name and password", Icons.Filled.Dns, listOf(SourceType.XTREAM)),
    MEDIA_SERVER("Media server", "Plex, Jellyfin or Emby", Icons.Filled.VideoLibrary, listOf(SourceType.PLEX, SourceType.JELLYFIN, SourceType.EMBY)),
    TUNER("TV tuner or receiver", "HDHomeRun, TVHeadend or Enigma2", Icons.Filled.SettingsInputAntenna, listOf(SourceType.HDHOMERUN, SourceType.TVHEADEND, SourceType.ENIGMA2)),
    FILES("Files and folders", "A playlist file, a folder of videos or WebDAV", Icons.Filled.Folder, listOf(SourceType.LOCAL_FILE, SourceType.LOCAL_FOLDER, SourceType.WEBDAV)),
    STALKER("Stalker portal", "Portal address and MAC", Icons.Filled.Router, listOf(SourceType.STALKER));

    /** The kinds behind this tile. A television has no folder picker, so a folder of videos is offered on a phone or tablet only, as in the add menus. */
    fun kinds(phone: Boolean): List<SourceType> = if (phone) kinds else kinds - SourceType.LOCAL_FOLDER
    fun subtitle(phone: Boolean): String = if (this == FILES && !phone) "A playlist file or a WebDAV share" else subtitle

    companion object {
        /** The tile a connection kind belongs to; none for an add-on, which is managed in Settings. */
        fun of(kind: SourceType): ConnectTile? = entries.firstOrNull { kind in it.kinds }
        /** The short name of one kind inside a group tile's chooser. */
        fun choiceLabel(kind: SourceType): String = when (kind) {
            SourceType.LOCAL_FILE -> "Playlist file"
            SourceType.LOCAL_FOLDER -> "Folder of videos"
            SourceType.ENIGMA2 -> "Enigma2"
            else -> kind.label
        }
    }
}


/**
 * The colours of the start and setup screens, by role. Two looks share the same layouts: [BrandLook], the fixed brand palette of the first-run welcome (it appears before the person has
 * chosen anything), and [ThemeLook], which follows the chosen theme, accent and Projector Mode for the connection form opened from inside the app. Every value is read from state when
 * it is used, so a change of theme redraws the page.
 */
internal interface StartLook {
    val base: Color
    val surface: Color
    val surfaceFocused: Color
    val hairline: Color
    /** Focus rings, hairlines that light up, and the glow around a focused item. */
    val focus: Color
    /** The backdrop's two glows. */
    val glow: Color
    val glow2: Color
    /** The sliding pill of a segmented chooser. */
    val pill: Color
    /** A text field's own fill, inside the form card. */
    val field: Color
    /** The main button's fill (top and bottom of its soft gradient) and its text. */
    val primaryTop: Color
    val primaryBottom: Color
    val onPrimary: Color
    /** The quietest text; no darker than this, so it still reads on the page. */
    val quiet: Color
    /** The dark vignette at the edges; never in Projector Mode, which cannot show dark edges. */
    val vignette: Boolean
}

/** The brand palette: near-black with teal and silver-blue light. Projector Mode still draws the surfaces from its own palette (see [Tokens.pick]). */
internal object BrandLook : StartLook {
    private val teal = Color(0xFF3CC6D6)
    override val base get() = Tokens.pick(Color(0xFF05080C), Tokens.background)
    override val surface get() = Tokens.pick(Color(0x0DFFFFFF), Tokens.card)
    override val surfaceFocused get() = Tokens.pick(Color(0x17FFFFFF), Tokens.focusedSurface)
    override val hairline get() = Tokens.pick(Color(0x1AFFFFFF), Tokens.lineStrong)
    override val focus get() = teal
    override val glow get() = Color(0xFF1FA7B8)
    override val glow2 get() = Color(0xFF8FA7C0)
    override val pill get() = Tokens.pick(Color(0x26FFFFFF), Tokens.elevated)
    override val field get() = Tokens.pick(Color(0x59000000), Tokens.background)
    // The brand's teal (#1FA7B8) at the top, deepening a little towards the bottom so its white label keeps a 3:1 contrast for large text.
    override val primaryTop get() = Tokens.pick(Color(0xFF1FA7B8), Tokens.accent)
    override val primaryBottom get() = Tokens.pick(Color(0xFF137A88), Tokens.accent)
    override val onPrimary get() = Tokens.pick(Color.White, Tokens.onBright)
    override val quiet get() = Tokens.pick(Color(0xFF9AA4AE), Tokens.textTertiary)
    override val vignette get() = !Tokens.projector
}

/** The chosen theme: its page, card and line colours, and its accent for focus, glows and the main button (with the theme's dark text on it, as on every accent button in the app). */
internal object ThemeLook : StartLook {
    override val base get() = Tokens.background
    override val surface get() = Tokens.card
    override val surfaceFocused get() = Tokens.focusedSurface
    override val hairline get() = Tokens.lineStrong
    override val focus get() = Tokens.accent
    override val glow get() = Tokens.accent
    override val glow2 get() = lerp(Tokens.accent, Color.White, 0.5f)
    override val pill get() = Tokens.elevated
    override val field get() = Tokens.pick(Tokens.background, Tokens.background)
    override val primaryTop get() = Tokens.accent
    override val primaryBottom get() = Tokens.accent
    override val onPrimary get() = Tokens.onBright
    // The theme's secondary text: its tertiary grey is darker than these pages allow.
    override val quiet get() = Tokens.textSecondary
    override val vignette get() = !Tokens.projector
}

/** Which look the start and setup screens are drawn in; the welcome provides nothing and gets the brand. */
internal val LocalStartLook = staticCompositionLocalOf<StartLook> { BrandLook }

/**
 * True when movement should be left out: the app's own setting (the television provides it), or Android's animator duration scale set to 0, which the phone layout does not otherwise read.
 * Only opacity changes are kept then.
 */
@Composable
internal fun reducedMotion(): Boolean {
    val context = LocalContext.current
    val systemOff = remember { runCatching { android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false) }
    return LocalReducedMotion.current || systemOff
}

@Composable
private fun rememberPhone(): Boolean { val context = LocalContext.current; return remember { isPhoneDevice(context) } }

/** The press and focus spring of these pages: a response of about 0.32 s with a little give (damping 0.82). */
internal fun <T> pressSpring() = spring<T>(dampingRatio = 0.82f, stiffness = 385f)

/**
 * Press feel for a finger: while pressed the item shrinks to 0.97 and dims a little, and springs back on release; a tap gives a light tick (Android's own haptics setting decides
 * whether it is felt). [onPress] is told when a press starts (a tile plays its icon then). With reduced motion only the dim remains.
 */
@Composable
internal fun Modifier.pressable(role: Role, onPress: (() -> Unit)? = null, onClick: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val reduced = reducedMotion()
    val k by animateFloatAsState(if (pressed) 1f else 0f, if (reduced) snap() else pressSpring(), label = "press")
    val view = LocalView.current
    LaunchedEffect(pressed) { if (pressed) onPress?.invoke() }
    return this
        .graphicsLayer { if (!reduced) { val sc = 1f - 0.03f * k; scaleX = sc; scaleY = sc }; alpha = 1f - 0.12f * k }
        .clickable(interactionSource = source, indication = null, role = role) {
            view.performHapticFeedback(if (role == Role.Tab && android.os.Build.VERSION.SDK_INT >= 23) HapticFeedbackConstants.CONTEXT_CLICK else HapticFeedbackConstants.VIRTUAL_KEY)
            onClick()
        }
}

/** Content rising a little into place and fading in once, after [order] x 40 ms, so a page settles in reading order. With reduced motion it is simply there. */
@Composable
internal fun Modifier.riseIn(order: Int): Modifier {
    val reduced = reducedMotion()
    val a = remember { Animatable(if (reduced) 1f else 0f) }
    LaunchedEffect(Unit) { if (!reduced) { delay(order * 40L); a.animateTo(1f, tween(450, easing = Motion.Standard)) } }
    return this.graphicsLayer { alpha = a.value; translationY = (1f - a.value) * 14.dp.toPx() }
}

private const val EYEBROW = "STREAMSETU"
private const val HEADLINE = "Your streams. One home."
private const val SUBLINE = "Bring the playlists, logins and media servers you already have. StreamSetu keeps them together and plays them."
/** The spec's section label is "Or choose how you connect", the "Or" following the paste field; there is no paste field on Android (nothing here detects a pasted link's type), so the "Or" is left out. */
private const val SECTION = "Choose how you connect"
private const val LEGAL = "StreamSetu does not include any channels, movies or subscriptions. You bring your own provider."
private val TRUST = listOf(Icons.Filled.Lock to "Logins stay encrypted on this device", Icons.Filled.PersonOff to "No account needed", Icons.Filled.Inventory2 to "Nothing is included: you bring your own")

/** The four large tiles of the television's first row; the rest are the smaller "More ways" row. */
private val tvMain = listOf(ConnectTile.PLAYLIST_LINK, ConnectTile.XTREAM, ConnectTile.MEDIA_SERVER, ConnectTile.TUNER)
/** The smaller tiles. A store-style build (-PstoreBuild) leaves out the Stalker / MAG portal type. */
private val tvMore = listOfNotNull(ConnectTile.FILES, ConnectTile.STALKER.takeIf { !app.streamsetu.tv.BuildConfig.STORE_BUILD })

/**
 * The television welcome, read from a sofa and driven by the remote: the floating symbol and the headline in the top-left third, a row of four large tiles (the first takes the remote),
 * a row of smaller ones with Continue Previous Setup beside them when there is a draft, then the trust line and the remote hint. No paste field: there is no keyboard.
 */
@Composable
internal fun TvWelcome(onTile: (ConnectTile) -> Unit, onResume: (() -> Unit)?) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { app.streamsetu.tv.ui.components.requestFocusSoon(first, 8) }
    Box(Modifier.fillMaxSize()) {
        StartBackground(Offset(0.12f, 0.2f))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.safeHorizontal + 8.dp, vertical = Tokens.safeVertical)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                FloatingSymbol(104.dp, Modifier.riseIn(0))
                Column(Modifier.riseIn(1)) {
                    Label(EYEBROW, 13.sp, Tokens.textSecondary, FontWeight.Bold, letterSpacing = 3.sp)
                    Label(HEADLINE, 48.sp, Tokens.text, FontWeight.Bold, letterSpacing = (-1).sp)
                    Label(SUBLINE, 20.sp, Tokens.textSecondary, maxLines = 2, modifier = Modifier.widthIn(max = 640.dp).padding(top = 2.dp))
                }
            }
            Label(SECTION, 16.sp, Tokens.textSecondary, FontWeight.SemiBold, modifier = Modifier.padding(top = 16.dp, bottom = 12.dp).riseIn(2))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                tvMain.forEachIndexed { i, t ->
                    TvConnectTile(t, t.title, t.subtitle(false), large = true, order = 3 + i, modifier = Modifier.weight(1f), focus = if (i == 0) first else null) { onTile(t) }
                }
            }
            Label("More ways", 14.sp, LocalStartLook.current.quiet, FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp, bottom = 8.dp).riseIn(7))
            // The smaller tiles sit in the same four columns as the large ones above, so Down from a large tile lands on the one below it.
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                tvMore.forEachIndexed { i, t -> TvConnectTile(t, t.title, t.subtitle(false), large = false, order = 8 + i, modifier = Modifier.weight(1f)) { onTile(t) } }
                if (onResume != null) TvConnectTile(null, "Continue Previous Setup", "Finish a connection you saved", large = false, order = 10, modifier = Modifier.weight(1f), fallback = Icons.Filled.Edit, onClick = onResume)
                repeat(tvMain.size - tvMore.size - (if (onResume != null) 1 else 0)) { Spacer(Modifier.weight(1f)) }
            }
            Row(Modifier.padding(top = 18.dp).riseIn(11), horizontalArrangement = Arrangement.spacedBy(28.dp)) { TRUST.forEach { (icon, text) -> TrustItem(icon, text, 15.sp) } }
            Label(LEGAL, 13.sp, LocalStartLook.current.quiet, modifier = Modifier.padding(top = 10.dp).riseIn(12))
            Label("Arrow keys move  ·  OK chooses  ·  hold OK for options  ·  Back goes back", 13.sp, LocalStartLook.current.quiet, modifier = Modifier.padding(top = 4.dp).riseIn(12))
        }
    }
}

/**
 * The phone and tablet welcome: one scrolling column clear of the status and navigation bars. The floating symbol, the headline, the tiles two to a row, Continue Previous Setup when there
 * is a draft, then the trust lines. No remote hints, and no paste field (nothing on Android works out a pasted link's type yet).
 */
@Composable
internal fun PhoneWelcome(onTile: (ConnectTile) -> Unit, onResume: (() -> Unit)?) {
    Box(Modifier.fillMaxSize()) {
        StartBackground(Offset(0.5f, 0.1f))
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).windowInsetsPadding(WindowInsets.systemBars).padding(horizontal = 20.dp, vertical = 16.dp).widthIn(max = 640.dp).align(Alignment.TopCenter),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            FloatingSymbol(128.dp, Modifier.padding(top = 8.dp).riseIn(0))
            Column(Modifier.padding(top = 12.dp).riseIn(1), horizontalAlignment = Alignment.CenterHorizontally) {
                Label(EYEBROW, 12.sp, Tokens.textSecondary, FontWeight.Bold, letterSpacing = 3.sp)
                Label(HEADLINE, 32.sp, Tokens.text, FontWeight.Bold, maxLines = 2, letterSpacing = (-0.6).sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
                Label(SUBLINE, 16.sp, Tokens.textSecondary, maxLines = 4, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
            }
            Label(SECTION, 15.sp, Tokens.text, FontWeight.SemiBold, modifier = Modifier.fillMaxWidth().padding(top = 28.dp, bottom = 10.dp).riseIn(2))
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ConnectTile.entries.filter { it != ConnectTile.STALKER || !app.streamsetu.tv.BuildConfig.STORE_BUILD }.chunked(2).forEachIndexed { row, pair ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        pair.forEachIndexed { i, t -> PhoneConnectTile(t, t.subtitle(true), 3 + row * 2 + i, Modifier.weight(1f).fillMaxHeight()) { onTile(t) } }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
            if (onResume != null) PhonePill("Continue Previous Setup", onResume, Modifier.padding(top = 16.dp).fillMaxWidth().riseIn(9), icon = Icons.Filled.Edit)
            Column(Modifier.fillMaxWidth().padding(top = 26.dp).riseIn(10), verticalArrangement = Arrangement.spacedBy(10.dp)) { TRUST.forEach { (icon, text) -> TrustItem(icon, text, 14.sp) } }
            Label(LEGAL, 12.sp, LocalStartLook.current.quiet, maxLines = 3, modifier = Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 8.dp).riseIn(11))
        }
    }
}

@Composable
private fun TrustItem(icon: ImageVector, text: String, size: TextUnit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Image(icon, null, Modifier.size(with(androidx.compose.ui.platform.LocalDensity.current) { size.toDp() + 2.dp }), colorFilter = ColorFilter.tint(Tokens.textSecondary))
        Label(text, size, Tokens.textSecondary, maxLines = 2)
    }
}

/**
 * One way to connect, for the remote. Focus shows as a ring and a hairline in the look's focus colour, a lighter fill, a soft glow around the tile, a springy lift to 1.05 and the icon
 * playing its animation. The lift is on the outer box, so the glow grows with the tile; the rows leave more room around the tiles than the lift and the glow take, so neither is ever
 * cut off. With reduced motion there is no lift. A large tile stacks the icon over the title; a small one sets them side by side.
 */
@Composable
private fun TvConnectTile(tile: ConnectTile?, title: String, subtitle: String, large: Boolean, order: Int, modifier: Modifier, focus: FocusRequester? = null, fallback: ImageVector? = null, onClick: () -> Unit) {
    val look = LocalStartLook.current
    var focused by remember { mutableStateOf(false) }
    var play by remember { mutableIntStateOf(0) }
    val reduced = reducedMotion()
    val glow by animateFloatAsState(if (focused) 1f else 0f, if (reduced) snap() else tween(150), label = "tileGlow")
    val lift by animateFloatAsState(if (focused && !reduced) 1.05f else 1f, if (reduced) snap() else pressSpring(), label = "tileLift")
    val radius = 20.dp
    val shape = RoundedCornerShape(radius)
    Box(modifier.riseIn(order).graphicsLayer { scaleX = lift; scaleY = lift }.drawWithCache {
        val stroke = Stroke(3.dp.toPx()); val ring = 3.dp.toPx(); val corner = radius.toPx()
        onDrawBehind { if (!Tokens.projector) softGlow(look.focus, glow, corner, stroke, ring) }
    }) {
        Focusable(onClick, (if (focus != null) Modifier.focusRequester(focus) else Modifier).fillMaxWidth().height(if (large) 146.dp else 76.dp).semantics { role = Role.Button },
            shape = shape, container = look.surface, focusedContainer = look.surfaceFocused, scaleOnFocus = 1f, ring = look.focus, ringWidth = 3.dp, onFocus = { focused = it; if (it) play++ }) { f ->
            Box(Modifier.matchParentSize().border(1.dp, if (f) look.focus.copy(alpha = 0.6f) else look.hairline, shape))
            if (large) Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 14.dp)) {
                TileIcon(tile, 44.dp, play = play, appearDelayMs = order * 40L + 300, fallback = fallback)
                Spacer(Modifier.height(10.dp))
                Label(title, 19.sp, Tokens.text, FontWeight.SemiBold)
                Label(subtitle, 14.sp, if (f) Tokens.text else Tokens.textSecondary, maxLines = 2, modifier = Modifier.padding(top = 2.dp))
            } else Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TileIcon(tile, 38.dp, play = play, appearDelayMs = order * 40L + 300, fallback = fallback)
                Column(Modifier.weight(1f)) {
                    Label(title, 16.sp, Tokens.text, FontWeight.SemiBold)
                    Label(subtitle, 13.sp, if (f) Tokens.text else Tokens.textSecondary, maxLines = 2)
                }
            }
        }
    }
}

/** One way to connect, for a finger: a 14 dp rounded surface with the icon, the title and the description. The icon plays when the tile is pressed. */
@Composable
private fun PhoneConnectTile(tile: ConnectTile, subtitle: String, order: Int, modifier: Modifier, onClick: () -> Unit) {
    val look = LocalStartLook.current
    val shape = RoundedCornerShape(14.dp)
    var play by remember { mutableIntStateOf(0) }
    Column(modifier.riseIn(order).pressable(Role.Button, onPress = { play++ }, onClick = onClick).clip(shape).background(look.surface).border(1.dp, look.hairline, shape).padding(14.dp)) {
        TileIcon(tile, 40.dp, play = play, appearDelayMs = order * 40L + 300)
        Label(tile.title, 15.sp, Tokens.text, FontWeight.SemiBold, maxLines = 2, modifier = Modifier.padding(top = 10.dp))
        Label(subtitle, 13.sp, Tokens.textSecondary, maxLines = 3, modifier = Modifier.padding(top = 2.dp))
    }
}

// ---- The connection form's own pieces (SetupScreen) ----

/** The form's header: the tile's icon, "Connect <tile>", and one line under it (the tile's description, or the exact kind when a saved connection is being edited). */
@Composable
internal fun ConnectHeader(kind: SourceType, phone: Boolean, showKind: Boolean) {
    val tile = ConnectTile.of(kind)
    val title = "Connect " + (tile?.title ?: kind.label)
    val line = if (showKind || tile == null) kind.label else tile.subtitle(phone)
    if (phone) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        TileIcon(tile, 48.dp, appearDelayMs = 250, fallback = Icons.Filled.Extension)
        Column(Modifier.weight(1f)) {
            Label(title, 24.sp, Tokens.text, FontWeight.Bold, maxLines = 2, letterSpacing = (-0.3).sp)
            Label(line, 14.sp, Tokens.textSecondary, maxLines = 2)
        }
    } else Column {
        TileIcon(tile, 56.dp, appearDelayMs = 250, fallback = Icons.Filled.Extension)
        Label(title, 30.sp, Tokens.text, FontWeight.Bold, maxLines = 3, letterSpacing = (-0.5).sp, modifier = Modifier.padding(top = 16.dp))
        Label(line, 18.sp, Tokens.textSecondary, maxLines = 2, modifier = Modifier.padding(top = 4.dp))
    }
}

/** The quiet link back to the ways to connect. */
@Composable
internal fun BackLink(phone: Boolean, onClick: () -> Unit) {
    val look = LocalStartLook.current
    val text = "All connection types"
    if (phone) Row(Modifier.heightIn(min = 48.dp).pressable(Role.Button, onClick = onClick).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Image(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
        Label(text, 14.sp, Tokens.textSecondary, FontWeight.Medium)
    } else Focusable(onClick, Modifier.semantics { role = Role.Button }, shape = RoundedCornerShape(50), container = Color.Transparent, focusedContainer = look.surfaceFocused, ring = look.focus, style = TvFocusStyle.DENSE) { f ->
        Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(Icons.AutoMirrored.Filled.ArrowBack, null, Modifier.size(16.dp), colorFilter = ColorFilter.tint(if (f) Tokens.text else Tokens.textSecondary))
            Label(text, 15.sp, if (f) Tokens.text else Tokens.textSecondary, FontWeight.Medium)
        }
    }
}

/** The segmented chooser between the kinds of a group tile (Plex, Jellyfin or Emby). The selected pill slides from one option to the next. */
@Composable
internal fun KindChooser(kinds: List<SourceType>, chosen: SourceType, phone: Boolean, onPick: (SourceType) -> Unit) {
    val look = LocalStartLook.current
    val shape = RoundedCornerShape(50)
    val n = kinds.size
    val index = kinds.indexOf(chosen).coerceAtLeast(0)
    val reduced = reducedMotion()
    val at by animateFloatAsState(index.toFloat(), if (reduced) snap() else pressSpring(), label = "pill")
    Row(Modifier.fillMaxWidth().background(look.surface, shape).border(1.dp, look.hairline, shape).padding(4.dp).drawBehind {
        val gap = 4.dp.toPx(); val w = (size.width - gap * (n - 1)) / n
        drawRoundRect(look.pill, Offset(at * (w + gap), 0f), Size(w, size.height), CornerRadius(size.height / 2))
    }, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        kinds.forEach { k ->
            val on = k == chosen
            val label = ConnectTile.choiceLabel(k)
            if (phone) Box(Modifier.weight(1f).heightIn(min = 40.dp).pressable(Role.Tab) { onPick(k) }, Alignment.Center) {
                Label(label, 14.sp, if (on) Tokens.text else Tokens.textSecondary, if (on) FontWeight.SemiBold else FontWeight.Normal)
            } else Focusable({ onPick(k) }, Modifier.weight(1f).semantics { role = Role.Tab }, shape = shape, container = Color.Transparent, focusedContainer = Tokens.pick(Color(0x1AFFFFFF), Tokens.focusedSurface), ring = look.focus, style = TvFocusStyle.DENSE) { f ->
                Box(Modifier.fillMaxWidth().padding(vertical = 9.dp), Alignment.Center) { Label(label, 16.sp, if (on || f) Tokens.text else Tokens.textSecondary, if (on) FontWeight.SemiBold else FontWeight.Normal) }
            }
        }
    }
}

/** The one surface that holds the form's fields: 20 dp corners on a television, 14 dp on a phone. */
@Composable
internal fun FormCard(phone: Boolean, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val look = LocalStartLook.current
    val shape = RoundedCornerShape(if (phone) 14.dp else 20.dp)
    Column(modifier.fillMaxWidth().background(look.surface, shape).border(1.dp, look.hairline, shape).padding(if (phone) 16.dp else 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
}

/**
 * A field with its label above it. The label is the placeholder's own name (the part before any example in brackets), so the placeholders stay exactly as they were. On focus the
 * field's hairline turns to the focus colour with a soft glow, and the label lifts and brightens a little.
 *
 * On a television it behaves like the app's other fields (OK starts typing, Done or Back ends it), with the focus colour instead of the white frame. On a phone it is a plain text field
 * that is typed in straight away when tapped.
 */
@Composable
internal fun FormField(value: String, onChange: (String) -> Unit, placeholder: String, secret: Boolean = false, focus: FocusRequester? = null) {
    val look = LocalStartLook.current
    val phone = rememberPhone()
    val reduced = reducedMotion()
    var active by remember { mutableStateOf(false) }
    val k by animateFloatAsState(if (active) 1f else 0f, if (reduced) snap() else tween(180), label = "field")
    val shape = RoundedCornerShape(if (phone) 12.dp else 14.dp)
    val glow = Modifier.drawWithCache {
        val stroke = Stroke(2.dp.toPx()); val ring = 2.dp.toPx(); val corner = (if (phone) 12.dp else 14.dp).toPx()
        onDrawBehind { softGlow(look.focus, k, corner, stroke, ring, rings = 4) }
    }
    val outline = Modifier.border(1.dp, lerp(look.hairline, look.focus, k), shape)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Label(placeholder.substringBefore(" (").substringBefore(": "), 14.sp, lerp(Tokens.textSecondary, Tokens.text, k), FontWeight.SemiBold, modifier = Modifier.graphicsLayer { translationY = -2.dp.toPx() * k })
        val transform = if (secret) PasswordVisualTransformation() else VisualTransformation.None
        val options = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else KeyboardType.Text, imeAction = ImeAction.Done)
        if (phone) {
            val focusManager = LocalFocusManager.current
            BasicTextField(value, onChange, (if (focus != null) Modifier.focusRequester(focus) else Modifier).fillMaxWidth().then(glow).onFocusChanged { active = it.isFocused },
                textStyle = TextStyle(color = Tokens.text, fontSize = 16.sp), singleLine = true, cursorBrush = SolidColor(look.focus), visualTransformation = transform,
                keyboardOptions = options, keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                decorationBox = { inner ->
                    Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape).background(look.field).then(outline).padding(horizontal = 16.dp, vertical = 13.dp), Alignment.CenterStart) {
                        if (value.isEmpty()) Label(placeholder, 16.sp, look.quiet)
                        inner()
                    }
                })
        } else TvField(value, onChange, placeholder, secret, focus, transform, options, shape, Modifier.then(glow), outline) { active = it }
    }
}

/** The television field: the row takes the remote, OK starts typing with the on-screen keyboard, Done ends it and gives the remote back to the row (the same steps as the app's other fields). */
@Composable
private fun TvField(value: String, onChange: (String) -> Unit, placeholder: String, secret: Boolean, focus: FocusRequester?, transform: VisualTransformation, options: KeyboardOptions,
                    shape: RoundedCornerShape, modifier: Modifier, outline: Modifier, onActive: (Boolean) -> Unit) {
    val look = LocalStartLook.current
    var editing by remember { mutableStateOf(false) }
    var rowFocused by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val requester = remember { FocusRequester() }
    val rowRequester = remember { FocusRequester() }
    var gotFocus by remember { mutableStateOf(false) }
    LaunchedEffect(editing) { gotFocus = false; if (editing) { runCatching { requester.requestFocus() }; keyboard?.show() } }
    LaunchedEffect(editing, rowFocused) { onActive(editing || rowFocused) }
    Focusable({ editing = true }, (if (focus != null) Modifier.focusRequester(focus) else Modifier).fillMaxWidth().then(modifier).focusRequester(rowRequester), shape = shape,
        container = look.field, focusedContainer = look.field, scaleOnFocus = 1f, ring = look.focus, onFocus = { rowFocused = it }) { _ ->
        Box(Modifier.matchParentSize().then(outline))
        Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp)) {
            if (editing) BasicTextField(value, onChange, Modifier.fillMaxWidth().focusRequester(requester).onFocusChanged { f -> if (f.isFocused) gotFocus = true else if (gotFocus) editing = false },
                textStyle = TextStyle(color = Tokens.text, fontSize = Tokens.body), singleLine = true, cursorBrush = SolidColor(look.focus), visualTransformation = transform, keyboardOptions = options,
                keyboardActions = KeyboardActions(onDone = { editing = false; keyboard?.hide(); runCatching { rowRequester.requestFocus() } }))
            else if (value.isEmpty()) Label(placeholder, Tokens.body, look.quiet)
            else Label(if (secret) "•".repeat(value.length.coerceAtMost(24)) else value, Tokens.body, Tokens.text)
        }
    }
}

/**
 * The main action (Connect, Enter Home): large, filled with the look's primary colour, with a soft light crossing it every 4 s while it waits. On a television focus adds a white ring,
 * a glow and a small springy lift; on a phone a press springs. [lit] false draws it dimmer (there is not enough filled in yet), as the form did before.
 */
@Composable
internal fun PrimaryAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, lit: Boolean = true) {
    val look = LocalStartLook.current
    val phone = rememberPhone()
    val reduced = reducedMotion()
    val sweep = if (reduced) null else rememberInfiniteTransition(label = "primary").animateFloat(0f, 1f, infiniteRepeatable(keyframes { durationMillis = 4000; 0f at 0 using LinearEasing; 1f at 1100; 1f at 4000 }), label = "sweep")
    var focused by remember { mutableStateOf(false) }
    val glow by animateFloatAsState(if (focused) 1f else 0f, if (reduced) snap() else tween(150), label = "primaryGlow")
    val lift by animateFloatAsState(if (focused && !reduced) 1.04f else 1f, if (reduced) snap() else pressSpring(), label = "primaryLift")
    val shape = RoundedCornerShape(50)
    val face: @Composable BoxScope.() -> Unit = {
        Box(Modifier.matchParentSize().graphicsLayer { alpha = if (lit) 1f else 0.55f }.drawWithCache {
            val fill = Brush.verticalGradient(listOf(look.primaryTop, look.primaryBottom))
            val w = size.width * 0.35f
            val light = Brush.horizontalGradient(0f to Color.Transparent, 0.5f to Color.White.copy(alpha = 0.26f), 1f to Color.Transparent, startX = 0f, endX = w)
            onDrawBehind {
                drawRect(fill)
                val s = sweep?.value ?: 1f
                if (s < 1f && lit) translate(-w + (size.width + 2 * w) * s, 0f) { drawRect(light, Offset.Zero, Size(w, size.height)) }
            }
        })
        Row(Modifier.align(Alignment.Center).padding(horizontal = if (phone) 24.dp else 30.dp, vertical = if (phone) 13.dp else 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // On the dimmed fill the theme's dark text would lose its contrast, so the label turns light until the button is lit.
            val ink = if (lit) look.onPrimary else Tokens.text
            if (icon != null) Image(icon, null, Modifier.size(if (phone) 20.dp else 22.dp), colorFilter = ColorFilter.tint(ink))
            Label(text, if (phone) 17.sp else 20.sp, ink, FontWeight.Bold)
        }
    }
    if (phone) Box(modifier.heightIn(min = 52.dp).pressable(Role.Button, onClick = onClick).clip(shape), content = face)
    else Box(modifier.graphicsLayer { scaleX = lift; scaleY = lift }.drawWithCache {
        val stroke = Stroke(3.dp.toPx()); val ring = 3.dp.toPx()
        onDrawBehind { if (!Tokens.projector) softGlow(look.focus, glow, size.height / 2, stroke, ring) }
    }) {
        Focusable(onClick, Modifier.heightIn(min = 56.dp).semantics { role = Role.Button }, shape = shape, container = Color.Transparent, focusedContainer = Color.Transparent, scaleOnFocus = 1f,
            ring = Color.White, ringWidth = 3.dp, onFocus = { focused = it }, content = { face() })
    }
}

/** A quiet text-style action (Save as Draft, Cancel): no fill at rest, a light fill and the focus ring when the remote is on it. */
@Composable
internal fun QuietAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val look = LocalStartLook.current
    if (rememberPhone()) Box(modifier.heightIn(min = 44.dp).pressable(Role.Button, onClick = onClick).padding(horizontal = 12.dp), Alignment.Center) { Label(text, 15.sp, Tokens.textSecondary, FontWeight.SemiBold) }
    else Focusable(onClick, modifier.semantics { role = Role.Button }, shape = RoundedCornerShape(50), container = Color.Transparent, focusedContainer = look.surfaceFocused, ring = look.focus, style = TvFocusStyle.DENSE) { f ->
        Label(text, 15.sp, if (f) Tokens.text else Tokens.textSecondary, FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
    }
}

/** A secondary button of the form: the remote's pill on a television, a 44 dp touch pill on a phone. */
@Composable
internal fun SetupAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    if (rememberPhone()) PhonePill(text, onClick, modifier, icon = icon, primary = primary) else TvButton(text, onClick, modifier, icon = icon, primary = primary)
}

/** The phone's pill button (the same glossy look as the app's other pills) with the press feel of these pages. */
@Composable
internal fun PhonePill(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, primary: Boolean = false) {
    val shape = RoundedCornerShape(22.dp)
    Row(modifier.heightIn(min = 44.dp).pressable(Role.Button, onClick = onClick).clip(shape).glossy(shape, fill = Tokens.elevated, accent = primary).padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
        if (icon != null) Image(icon, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(if (primary) Color.White else Tokens.text))
        Label(text, 15.sp, if (primary) Color.White else Tokens.text, FontWeight.SemiBold, maxLines = 2, textAlign = TextAlign.Center)
    }
}
