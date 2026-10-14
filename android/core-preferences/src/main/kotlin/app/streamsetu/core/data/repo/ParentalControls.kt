package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.model.Category
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Hides categories whose names mark adult content. On by default; the choice is kept on this device. */
class ParentalControls(context: Context) {
    private val prefs = context.getSharedPreferences("parental", Context.MODE_PRIVATE)
    private val _hide = MutableStateFlow(prefs.getBoolean(KEY, true))
    val hideAdult: StateFlow<Boolean> = _hide

    fun setHideAdult(on: Boolean) { prefs.edit().putBoolean(KEY, on).apply(); _hide.value = on }

    fun visible(category: Category, hide: Boolean = _hide.value) = !hide || !isAdultName(category.name)

    companion object {
        private const val KEY = "hide_adult"
        private val words = Regex("""(^|[^a-z])(xxx|adult|adults|porn|erotic|18\+|sex|playboy|hustler)([^a-z]|$)""", RegexOption.IGNORE_CASE)
        fun isAdultName(name: String) = words.containsMatchIn(name)
    }
}
