package app.streamsetu.tv

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool

enum class UISoundEvent(val raw: String, val group: SoundGroup, val minimal: Boolean) {
    FOCUS_MOVE("ui_focus", SoundGroup.NAVIGATION, false),
    SIDEBAR_MOVE("ui_sidebar", SoundGroup.NAVIGATION, false),
    SELECT("ui_select", SoundGroup.SELECTION, true),
    NAVIGATE_FORWARD("ui_forward", SoundGroup.NAVIGATION, true),
    NAVIGATE_BACK("ui_back", SoundGroup.NAVIGATION, true),
    MENU_OPEN("ui_menu_open", SoundGroup.NAVIGATION, true),
    MENU_CLOSE("ui_menu_close", SoundGroup.NAVIGATION, false),
    FAVORITE_ADD("ui_fav_add", SoundGroup.CONFIRMATION, true),
    FAVORITE_REMOVE("ui_fav_remove", SoundGroup.CONFIRMATION, false),
    WATCH_LATER_ADD("ui_later_add", SoundGroup.CONFIRMATION, true),
    WATCH_LATER_REMOVE("ui_later_remove", SoundGroup.CONFIRMATION, false),
    FOLDER_REORDER("ui_reorder", SoundGroup.NAVIGATION, false),
    FOLDER_MOVE_FIRST("ui_move_first", SoundGroup.CONFIRMATION, false),
    FOLDER_LOCK("ui_lock", SoundGroup.CONFIRMATION, true),
    FOLDER_UNLOCK("ui_unlock", SoundGroup.CONFIRMATION, true),
    SUCCESS("ui_success", SoundGroup.CONFIRMATION, true),
    ERROR("ui_error", SoundGroup.ERROR, true),
    PLAYBACK_START("ui_play", SoundGroup.SELECTION, true),
}

enum class SoundGroup { NAVIGATION, SELECTION, CONFIRMATION, ERROR }

/** What the person chose, as plain values so the rules can be tested. */
data class SoundSettings(
    val enabled: Boolean = true, val theme: String = "SIGNATURE", val volume: Int = 50,
    val navigation: Boolean = true, val selection: Boolean = true, val confirmation: Boolean = true, val error: Boolean = true,
    val duringPlayback: String = "REDUCED",
)

/**
 * The rules for when a sound plays and how loud. Pure, so it can be tested without a device.
 *  - Focus ticks are rate-limited, and during fast D-pad movement they get quieter and rarer (adaptive intensity), so moving through 100 channels does not rattle.
 *  - Sounds that arrive while a newer one is due are dropped, never queued.
 *  - The master volume of the device is never touched: the gain is only for our own tone.
 */
class SoundPolicy {
    private val recentFocus = ArrayDeque<Long>()
    private var lastFocusAt = Long.MIN_VALUE / 2

    /** The gain (0..1) to play [e] with, or null for silence. */
    fun decide(e: UISoundEvent, now: Long, s: SoundSettings, videoPlaying: Boolean): Float? {
        if (!s.enabled || s.theme == "SILENT" || s.volume <= 0) return null
        if (s.theme == "MINIMAL" && !e.minimal) return null
        val allowed = when (e.group) { SoundGroup.NAVIGATION -> s.navigation; SoundGroup.SELECTION -> s.selection; SoundGroup.CONFIRMATION -> s.confirmation; SoundGroup.ERROR -> s.error }
        if (!allowed) return null
        var gain = (s.volume / 100f) * 0.4f                       // the default 50 % is about 20 % of the tone's full level
        if (videoPlaying) when (s.duringPlayback) { "OFF" -> return null; "REDUCED" -> gain *= 0.5f }
        if (e == UISoundEvent.FOCUS_MOVE || e == UISoundEvent.SIDEBAR_MOVE) {
            while (recentFocus.isNotEmpty() && now - recentFocus.first() > 700) recentFocus.removeFirst()
            val busy = recentFocus.size
            val minGap = if (busy >= 7) 130 else if (busy >= 4) 85 else 45
            if (now - lastFocusAt < minGap) return null
            lastFocusAt = now; recentFocus.addLast(now)
            if (busy >= 7) gain *= 0.4f else if (busy >= 4) gain *= 0.7f
        }
        return gain.coerceIn(0f, 1f)
    }
}

/** Short interface tones from a SoundPool: preloaded once, never decoded while navigating, no audio focus taken, device volume untouched. */
object UISound {
    private val policy = SoundPolicy()
    private var pool: SoundPool? = null
    private val ids = HashMap<Pair<String, UISoundEvent>, Int>()
    private val suffixes = mapOf("SIGNATURE" to "", "WOOD" to "_wood", "CRYSTAL" to "_crystal", "SOFT" to "_soft", "ARCADE" to "_arcade")
    private var settings: () -> SoundSettings = { SoundSettings() }
    private var videoPlaying: () -> Boolean = { false }
    @Volatile private var lastDpadAt = 0L

    fun init(context: Context, settings: () -> SoundSettings, videoPlaying: () -> Boolean) {
        if (pool != null) return
        this.settings = settings; this.videoPlaying = videoPlaying
        val p = SoundPool.Builder().setMaxStreams(3)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()).build()
        suffixes.forEach { (theme, suffix) ->
            UISoundEvent.entries.forEach { e ->
                val res = context.resources.getIdentifier(e.raw + suffix, "raw", context.packageName)
                if (res != 0) ids[theme to e] = p.load(context, res, 1)
            }
        }
        pool = p
    }

    /** A D-pad key was pressed: focus changes within a moment of it count as the person moving, not the app placing focus. */
    fun noteDpad() { lastDpadAt = System.currentTimeMillis() }

    /** The focus ticks only for the remote's own movement. */
    fun focusMoved(e: UISoundEvent) { if (System.currentTimeMillis() - lastDpadAt < 250) play(e) }

    fun play(e: UISoundEvent) {
        val p = pool ?: return
        val chosen = settings()
        val id = ids[chosen.theme to e] ?: ids["SIGNATURE" to e] ?: return
        val g = policy.decide(e, System.currentTimeMillis(), chosen, videoPlaying()) ?: return
        p.play(id, g, g, 1, 0, 1f)
    }

    /** Stops everything when the app leaves the screen. */
    fun pause() { pool?.autoPause() }
    fun resume() { pool?.autoResume() }
}
