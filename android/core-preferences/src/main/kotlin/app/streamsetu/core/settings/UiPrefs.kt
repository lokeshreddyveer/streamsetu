package app.streamsetu.core.settings

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class PosterSize(val label: String, val dp: Int) { COMPACT("Compact", 96), STANDARD("Standard", 112), LARGE("Large", 134) }
enum class AnimationLevel(val label: String) { FULL("Full"), REDUCED("Reduced"), OFF("Off") }

/** Appearance and layout choices. Each one saves the moment it changes and is read by the screens that use it. */
class UiPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("ui", Context.MODE_PRIVATE)

    private fun <T> flow(v: T) = MutableStateFlow(v)

    private val _language = flow(prefs.getString("language", "SYSTEM") ?: "SYSTEM")
    /** SYSTEM, en, hi or te: the language of the app's own text. */
    val language: StateFlow<String> = _language
    fun setLanguage(v: String) { prefs.edit().putString("language", v).apply(); _language.value = v }

    private val _theme = flow(prefs.getString("theme", "OBSIDIAN") ?: "OBSIDIAN")
    /** OBSIDIAN, AMOLED, MIDNIGHT, SLATE or FOREST: the page and card colours. */
    val theme: StateFlow<String> = _theme
    fun setTheme(v: String) { prefs.edit().putString("theme", v).apply(); _theme.value = v }
    private val _accent = flow(prefs.getString("accent", "CYAN") ?: "CYAN")
    /** CYAN, GOLD, VIOLET, GREEN, ROSE or BLUE: the colour of highlights and primary buttons. */
    val accent: StateFlow<String> = _accent
    fun setAccent(v: String) { prefs.edit().putString("accent", v).apply(); _accent.value = v }

    private val _poster = flow(PosterSize.entries.firstOrNull { it.name == prefs.getString("poster", null) } ?: PosterSize.STANDARD)
    val posterSize: StateFlow<PosterSize> = _poster
    fun setPosterSize(v: PosterSize) { prefs.edit().putString("poster", v.name).apply(); _poster.value = v }

    private val _meta = flow(prefs.getBoolean("posterMeta", true))
    val showPosterMeta: StateFlow<Boolean> = _meta
    fun setShowPosterMeta(v: Boolean) { prefs.edit().putBoolean("posterMeta", v).apply(); _meta.value = v }

    private val _banner = flow(prefs.getBoolean("banner", true))
    val bannerEnabled: StateFlow<Boolean> = _banner
    fun setBannerEnabled(v: Boolean) { prefs.edit().putBoolean("banner", v).apply(); _banner.value = v }

    private val _bannerSecs = flow(prefs.getInt("bannerSecs", 9))
    val bannerSeconds: StateFlow<Int> = _bannerSecs
    fun setBannerSeconds(v: Int) { prefs.edit().putInt("bannerSecs", v).apply(); _bannerSecs.value = v }

    private val _anim = flow(AnimationLevel.entries.firstOrNull { it.name == prefs.getString("anim", null) } ?: AnimationLevel.FULL)
    val animation: StateFlow<AnimationLevel> = _anim
    fun setAnimation(v: AnimationLevel) { prefs.edit().putString("anim", v.name).apply(); _anim.value = v }

    private val _contrast = flow(prefs.getBoolean("contrast", false))
    val highContrastFocus: StateFlow<Boolean> = _contrast
    fun setHighContrastFocus(v: Boolean) { prefs.edit().putBoolean("contrast", v).apply(); _contrast.value = v }

    private val _shortcuts = flow(prefs.getBoolean("shortcuts", true))
    val showShortcuts: StateFlow<Boolean> = _shortcuts
    fun setShowShortcuts(v: Boolean) { prefs.edit().putBoolean("shortcuts", v).apply(); _shortcuts.value = v }

    /** The order of the shortcut chips under the banner, per section (MOVIE / SERIES), as saved names. */
    fun shortcutOrder(section: String, default: List<String>): List<String> {
        val saved = prefs.getString("order.$section", null)?.split(',')?.filter { it in default }.orEmpty()
        return saved + default.filter { it !in saved }
    }
    fun setShortcutOrder(section: String, order: List<String>) { prefs.edit().putString("order.$section", order.joinToString(",")).apply() }

    /** The order of Home's rows, as saved ids; rows not listed keep their default place after the listed ones. */
    fun homeOrder(default: List<String>): List<String> {
        val saved = prefs.getString("homeOrder", null)?.split(',')?.filter { it in default }.orEmpty()
        return saved + default.filter { it !in saved }
    }
    fun setHomeOrder(order: List<String>) { prefs.edit().putString("homeOrder", order.joinToString(",")).apply() }

    private val _epgOffset = flow(prefs.getInt("epgOffsetMin", 0))
    /** Minutes added to every guide time, for a provider whose guide is shifted. */
    val epgOffsetMinutes: StateFlow<Int> = _epgOffset
    fun setEpgOffsetMinutes(v: Int) { prefs.edit().putInt("epgOffsetMin", v).apply(); _epgOffset.value = v }

    private val _group = flow(prefs.getBoolean("groupDuplicates", true))
    /** Live TV shows one row for a channel that comes in several qualities or from several connections. */
    val groupDuplicates: StateFlow<Boolean> = _group
    fun setGroupDuplicates(v: Boolean) { prefs.edit().putBoolean("groupDuplicates", v).apply(); _group.value = v }

    private val _homeHidden = flow(prefs.getString("homeHidden", "")!!.split(',').filter { it.isNotBlank() }.toSet())
    /** Home rows the person turned off. */
    val homeHidden: StateFlow<Set<String>> = _homeHidden
    fun setHomeRowHidden(id: String, hidden: Boolean) { val n = if (hidden) _homeHidden.value + id else _homeHidden.value - id; prefs.edit().putString("homeHidden", n.joinToString(",")).apply(); _homeHidden.value = n }

    // ---- Interface sounds ----
    private val _soundsOn = flow(prefs.getBoolean("soundsOn", false))
    val soundsEnabled: StateFlow<Boolean> = _soundsOn
    fun setSoundsEnabled(v: Boolean) { prefs.edit().putBoolean("soundsOn", v).apply(); _soundsOn.value = v }
    private val _soundTheme = flow(prefs.getString("soundTheme", "SIGNATURE")!!)
    /** SIGNATURE (all tones), MINIMAL (only the important ones) or SILENT. */
    val soundTheme: StateFlow<String> = _soundTheme
    fun setSoundTheme(v: String) { prefs.edit().putString("soundTheme", v).apply(); _soundTheme.value = v }
    private val _soundVol = flow(prefs.getInt("soundVol", 50))
    val soundVolume: StateFlow<Int> = _soundVol
    fun setSoundVolume(v: Int) { prefs.edit().putInt("soundVol", v).apply(); _soundVol.value = v }
    private val _navTones = flow(prefs.getBoolean("navTones", true)); val navTones: StateFlow<Boolean> = _navTones
    fun setNavTones(v: Boolean) { prefs.edit().putBoolean("navTones", v).apply(); _navTones.value = v }
    private val _selTones = flow(prefs.getBoolean("selTones", true)); val selectionTones: StateFlow<Boolean> = _selTones
    fun setSelectionTones(v: Boolean) { prefs.edit().putBoolean("selTones", v).apply(); _selTones.value = v }
    private val _confTones = flow(prefs.getBoolean("confTones", true)); val confirmationTones: StateFlow<Boolean> = _confTones
    fun setConfirmationTones(v: Boolean) { prefs.edit().putBoolean("confTones", v).apply(); _confTones.value = v }
    private val _errTones = flow(prefs.getBoolean("errTones", true)); val errorTones: StateFlow<Boolean> = _errTones
    fun setErrorTones(v: Boolean) { prefs.edit().putBoolean("errTones", v).apply(); _errTones.value = v }
    private val _soundPlayback = flow(prefs.getString("soundPlayback", "REDUCED")!!)
    /** What happens to interface sounds while a video is playing: OFF, REDUCED or ON. */
    val soundsDuringPlayback: StateFlow<String> = _soundPlayback
    fun setSoundsDuringPlayback(v: String) { prefs.edit().putString("soundPlayback", v).apply(); _soundPlayback.value = v }
}
