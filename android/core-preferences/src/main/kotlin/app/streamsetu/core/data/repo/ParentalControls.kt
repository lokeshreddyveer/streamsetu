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

    /** A 4-digit PIN for locked folders. Only a salted hash is kept, on this device. */
    val hasPin: Boolean get() = prefs.getString("pin_hash", null) != null
    fun setPin(pin: String) {
        val salt = java.util.UUID.randomUUID().toString()
        prefs.edit().putString("pin_salt", salt).putString("pin_hash", hash(salt, pin)).apply()
    }
    fun clearPin() { prefs.edit().remove("pin_salt").remove("pin_hash").apply() }
    fun checkPin(pin: String): Boolean {
        val salt = prefs.getString("pin_salt", null) ?: return false
        return hash(salt, pin) == prefs.getString("pin_hash", null)
    }
    private fun hash(salt: String, pin: String) = java.security.MessageDigest.getInstance("SHA-256").digest((salt + pin).toByteArray()).joinToString("") { "%02x".format(it) }

    fun visible(category: Category, hide: Boolean = _hide.value) = !hide || !isAdultName(category.name)

    companion object {
        private const val KEY = "hide_adult"
        private val words = Regex("""(^|[^a-z])(xxx|adult|adults|porn|erotic|18\+|sex|playboy|hustler)([^a-z]|$)""", RegexOption.IGNORE_CASE)
        fun isAdultName(name: String) = words.containsMatchIn(name)
    }
}
