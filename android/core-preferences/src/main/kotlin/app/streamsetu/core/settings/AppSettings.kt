package app.streamsetu.core.settings

import android.content.Context
import app.streamsetu.core.playback.BufferingMode
import app.streamsetu.core.playback.EnginePreference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The Mac's `AppSettings`: every control saves the moment it changes and survives restarts. Read by the player and the Settings screens. */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private fun <T> flow(initial: T) = MutableStateFlow(initial)

    private val _engine = flow(EnginePreference.from(prefs.getString("engine", null)))
    val enginePreference: StateFlow<EnginePreference> = _engine
    fun setEngine(v: EnginePreference) { prefs.edit().putString("engine", v.name).apply(); _engine.value = v }

    private val _buffering = flow(BufferingMode.from(prefs.getString("buffering", null)))
    val bufferingMode: StateFlow<BufferingMode> = _buffering
    fun setBuffering(v: BufferingMode) { prefs.edit().putString("buffering", v.name).apply(); _buffering.value = v }

    private val _audioLang = flow(prefs.getString("audioLang", "") ?: "")
    val audioLanguage: StateFlow<String> = _audioLang
    fun setAudioLanguage(v: String) { prefs.edit().putString("audioLang", v).apply(); _audioLang.value = v }

    private val _subLang = flow(prefs.getString("subLang", "") ?: "")
    val subtitleLanguage: StateFlow<String> = _subLang
    fun setSubtitleLanguage(v: String) { prefs.edit().putString("subLang", v).apply(); _subLang.value = v }

    private val _subsDefault = flow(prefs.getBoolean("subsDefault", false))
    val subtitlesByDefault: StateFlow<Boolean> = _subsDefault
    fun setSubtitlesByDefault(v: Boolean) { prefs.edit().putBoolean("subsDefault", v).apply(); _subsDefault.value = v }

    private val _playNext = flow(prefs.getBoolean("playNext", true))
    val playNextAutomatically: StateFlow<Boolean> = _playNext
    fun setPlayNext(v: Boolean) { prefs.edit().putBoolean("playNext", v).apply(); _playNext.value = v }

    private val _remember = flow(prefs.getBoolean("remember", true))
    val rememberPosition: StateFlow<Boolean> = _remember
    fun setRememberPosition(v: Boolean) { prefs.edit().putBoolean("remember", v).apply(); _remember.value = v }

    private val _resume = flow(prefs.getBoolean("resume", true))
    val resumeAutomatically: StateFlow<Boolean> = _resume
    fun setResumeAutomatically(v: Boolean) { prefs.edit().putBoolean("resume", v).apply(); _resume.value = v }

    private val _info = flow(prefs.getBoolean("streamInfo", false))
    val showStreamInfo: StateFlow<Boolean> = _info
    fun setShowStreamInfo(v: Boolean) { prefs.edit().putBoolean("streamInfo", v).apply(); _info.value = v }
}
