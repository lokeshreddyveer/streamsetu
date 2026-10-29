package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.model.Category
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Hides categories whose names mark adult content. On by default; the choice is kept on this device. */
class ParentalControls(context: Context) {
    private val prefs = context.getSharedPreferences("parental", Context.MODE_PRIVATE)
    private val _hide = MutableStateFlow(prefs.getBoolean(KEY, true))
    private val _kids = MutableStateFlow(false)
    private val _effective = MutableStateFlow(_hide.value)
    /** Adult folders are hidden: by the person's choice, or always while a kids profile is in use. */
    val hideAdult: StateFlow<Boolean> = _effective
    /** A kids profile is in use: adult folders stay hidden and locked folders cannot be opened with the PIN. */
    val kids: StateFlow<Boolean> = _kids

    fun setHideAdult(on: Boolean) { prefs.edit().putBoolean(KEY, on).apply(); _hide.value = on; _effective.value = on || _kids.value }
    fun setKids(on: Boolean) { _kids.value = on; _effective.value = _hide.value || on }

    /** A 4-digit PIN for locked folders. Only a salted hash is kept, on this device. */
    val hasPin: Boolean get() = prefs.getString("pin_hash", null) != null
    fun setPin(pin: String) {
        val salt = java.util.UUID.randomUUID().toString()
        prefs.edit().putString("pin_salt", salt).putString("pin_hash", hash(salt, pin)).apply()
    }
    fun clearPin() { prefs.edit().remove("pin_salt").remove("pin_hash").apply() }
    private val throttle = app.streamsetu.core.model.PinThrottle("folders", { prefs.getString(it, null) }, { k, v -> prefs.edit().apply { if (v == null) remove(k) else putString(k, v) }.apply() })
    /** Seconds until a try is allowed again, or null. Every screen that asks for this PIN shares one count of wrong tries. */
    fun lockedForSeconds(): Int? = throttle.lockedForMs()?.let { ((it + 999) / 1000).toInt() }
    fun checkPin(pin: String): Boolean {
        if (_kids.value) return false
        return throttle.attempt {
            val salt = prefs.getString("pin_salt", null)
            val stored = prefs.getString("pin_hash", null)
            if (salt == null || stored == null) false
            else when (app.streamsetu.core.model.PinHash.verify(pin, salt.toByteArray(), stored)) {
                app.streamsetu.core.model.PinHash.Check.RIGHT -> true
                app.streamsetu.core.model.PinHash.Check.RIGHT_BUT_OLD -> { prefs.edit().putString("pin_hash", hash(salt, pin)).apply(); true }          // stored the old, fast way: now stored properly
                app.streamsetu.core.model.PinHash.Check.WRONG -> false
            }
        } == app.streamsetu.core.model.PinThrottle.Outcome.Right
    }
    /** What is stored for a PIN: see [app.streamsetu.core.model.PinHash]. */
    private fun hash(salt: String, pin: String) = app.streamsetu.core.model.PinHash.make(pin, salt.toByteArray())

    fun visible(category: Category, hide: Boolean = _effective.value) = !hide || !isAdultName(category.name)

    companion object {
        private const val KEY = "hide_adult"
        private val words = Regex("""(^|[^a-z])(xxx|adult|adults|porn|erotic|18\+|sex|playboy|hustler)([^a-z]|$)""", RegexOption.IGNORE_CASE)
        fun isAdultName(name: String) = words.containsMatchIn(name)
    }
}
