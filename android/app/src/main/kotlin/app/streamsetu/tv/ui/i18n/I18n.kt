package app.streamsetu.tv.ui.i18n

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject

/**
 * The app's words in other languages (Hindi and Telugu). Screens write their text in English; every piece of text drawn by [app.streamsetu.tv.ui.components.Label] is looked up here
 * and replaced when the chosen language has it, and left in English when it does not. Texts with a changing part ("Season 3", "12 min left") are matched by a template.
 * The tables are in assets/i18n/<code>.json. A language is chosen in Settings, Appearance; "System" follows the phone.
 */
object I18n {
    /** Bumped whenever the language changes, so every Label that read it draws again. */
    private var revision by mutableIntStateOf(0)

    private var strings: Map<String, String> = emptyMap()
    private var templates: List<Pair<Regex, String>> = emptyList()
    @Volatile private var active = "en"

    val languages = listOf("SYSTEM" to "System", "en" to "English", "hi" to "हिन्दी", "te" to "తెలుగు")

    /** Chooses the language from the setting ("SYSTEM", "en", "hi" or "te"). */
    fun apply(context: Context, setting: String) {
        val code = if (setting == "SYSTEM") java.util.Locale.getDefault().language else setting
        val use = if (code == "hi" || code == "te") code else "en"
        if (use == active && (use == "en" || strings.isNotEmpty())) return
        if (use == "en") { strings = emptyMap(); templates = emptyList() }
        else runCatching {
            val root = JSONObject(context.assets.open("i18n/$use.json").bufferedReader().use { it.readText() })
            strings = root.getJSONObject("strings").let { o -> o.keys().asSequence().associateWith { o.getString(it) } }
            templates = root.getJSONObject("templates").let { o -> o.keys().asSequence().map { k -> templateRegex(k) to o.getString(k) }.toList() }
        }.onFailure { strings = emptyMap(); templates = emptyList() }
        active = use
        revision++
    }

    /** "Season {}" to ^Season (.+?)$ */
    fun templateRegex(key: String): Regex = Regex("^" + key.split("{}").joinToString("(.+?)") { Regex.escape(it) } + "$")

    /** The text in the chosen language, or [s] itself. */
    fun tr(s: String): String {
        @Suppress("UNUSED_VARIABLE") val read = revision                    // makes a composable that calls this draw again when the language changes
        if (strings.isEmpty() || s.isBlank()) return s
        strings[s]?.let { return it }
        for ((re, out) in templates) {
            val m = re.matchEntire(s) ?: continue
            var i = 0
            return Regex("\\{\\}").replace(out) { m.groupValues.getOrNull(++i) ?: "" }
        }
        return s
    }
}
