package app.streamsetu.tv

import android.content.Context
import app.streamsetu.core.data.repo.LimitStore

/** Viewing limits and the day's watched time, kept on this device in shared preferences. */
class SharedPrefsLimitStore(context: Context) : LimitStore {
    private val prefs = context.getSharedPreferences("viewing_limits", Context.MODE_PRIVATE)
    override fun get(key: String): String? = prefs.getString(key, null)
    override fun put(key: String, value: String?) { prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
}
