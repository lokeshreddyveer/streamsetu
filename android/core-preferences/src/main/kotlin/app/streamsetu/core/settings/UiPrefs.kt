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
}
