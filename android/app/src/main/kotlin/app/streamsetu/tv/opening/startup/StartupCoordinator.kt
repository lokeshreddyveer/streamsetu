package app.streamsetu.tv.opening.startup

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.streamsetu.tv.opening.domain.OpeningVariant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** The version a What's New belongs to: the version name and the build, so a new build of the same version also counts as an update. */
object AppRelease {
    val current: String get() = "${app.streamsetu.tv.BuildConfig.VERSION_NAME} (${app.streamsetu.tv.BuildConfig.VERSION_CODE})"
    val name: String get() = app.streamsetu.tv.BuildConfig.VERSION_NAME
}

/**
 * Owns the opening for the whole process: the plan, the clock, the end, and what is saved. It lives as long as the process, so turning the device, a recreated activity or
 * a return from the background never starts the opening again; a new process (a real cold launch) does. The screen only draws what this says: time comes from the frame
 * clock (the first frame's time is kept here, never made again by a redraw), and the end is reached from the elapsed time, so no cancelled timer can leave the opening on
 * screen. Once it has completed, nothing of it runs.
 */
object StartupCoordinator {
    private const val PREFS = "ui"
    private const val INTRO_DONE = "intro_done"
    private const val SEEN = "whatsnew_seen_version"
    /** No frame seen yet (any real frame time, even 0, is a time). */
    private const val UNSET = Long.MIN_VALUE
    private const val MODE = "opening_mode"
    private const val REPLAY = "opening_replay_full"

    /** The Opening setting (Settings, Appearance). Read at the next launch. */
    fun mode(context: Context): OpeningMode = OpeningMode.of(context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(MODE, null))
    fun setMode(context: Context, mode: OpeningMode) { context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(MODE, mode.id).apply() }
    /** "Replay the full story" (Settings): the next launch plays the full story once more. */
    fun replayFullNextLaunch(context: Context) { context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(REPLAY, true).apply() }

    var plan by mutableStateOf<LaunchPlan?>(null); private set
    /** Milliseconds into the story, as last drawn. */
    var elapsedMs by mutableFloatStateOf(0f); private set
    /** 0..1 through the exit fade. */
    var exitProgress by mutableFloatStateOf(0f); private set
    /** True when What's New is to be shown (after the opening of an update), until the person continues. */
    var showWhatsNew by mutableStateOf(false); private set
    /** The plain look: flat colours and simple masks, for a device that cannot keep up (a low-memory device, or slow first frames). */
    var lightweight by mutableStateOf(false); private set
    /** For review (debug builds only): the opening frozen at this moment, never ending. */
    var frozenAtMs by mutableStateOf<Float?>(null); private set

    private var prefs: android.content.SharedPreferences? = null
    /** A test run or SS_SKIP_INTRO: nothing is shown and nothing is saved. */
    private var quiet = false
    private var startNanos = UNSET
    private var exitStartNanos = UNSET
    private var lastNanos = 0L
    private var slowFrames = 0
    private var countedFrames = 0
    private var initWork: (suspend () -> Unit)? = null
    private var scope: CoroutineScope? = null

    var machine = StartupMachine(onCompleted = { finish() }); private set
    val state get() = machine.state
    /** True while the opening layer is on screen. */
    val visible get() = machine.state != StartupState.NOT_STARTED && machine.state != StartupState.COMPLETED

    /**
     * Called by the activity on every creation; only the first call of a process does anything. [init] is the app's own start-up work (it runs alongside the opening);
     * [suppressed] is a test run or SS_SKIP_INTRO; [frozenAt] the review freeze (debug builds only).
     */
    fun begin(context: Context, scope: CoroutineScope, reducedMotion: Boolean, suppressed: Boolean, frozenAt: Float?, frozenVariant: OpeningVariant? = null, init: suspend () -> HasSources) {
        if (machine.state != StartupState.NOT_STARTED) return
        this.scope = scope
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).also { prefs = it }
        lightweight = runCatching { (context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager).isLowRamDevice }.getOrDefault(false)
        frozenAtMs = frozenAt
        if (suppressed && frozenAt == null) { quiet = true; plan = LaunchPlan.NONE; machine.start(); machine.planned(LaunchPlan.NONE); machine.initFinished(true); machine.exitFinished(); return }
        machine.start()
        val introDone = p.getBoolean(INTRO_DONE, false)
        val seen = p.getString(SEEN, null)
        val current = AppRelease.current
        val mode = OpeningMode.of(p.getString(MODE, null))
        val replay = p.getBoolean(REPLAY, false)
        if (replay) p.edit().putBoolean(REPLAY, false).apply()
        // When the saved settings settle it (the usual later launch), the fast opening starts on the first frame and the start-up runs alongside it. Otherwise the
        // database says whether this is a new install or an update; the page stays on its plain background for those few milliseconds.
        if (frozenAt != null) applyPlan(LaunchPlan(frozenVariant ?: OpeningVariant.STANDARD, whatsNew = false, newInstall = false))
        else if (LaunchPlan.settledWithoutDatabase(introDone, seen, current)) applyPlan(LaunchPlan.decide(introDone, true, true, seen, current, reducedMotion, false, mode, replay))
        initWork = {
            val found = runCatching { withTimeout(8_000) { withContext(Dispatchers.IO) { init() } } }
            if (plan == null) applyPlan(LaunchPlan.decide(introDone, found.getOrNull()?.any ?: false, found.getOrNull()?.connections ?: false, seen, current, reducedMotion, false, mode, replay))
            machine.initFinished(found.isSuccess)
        }
        scope.launch { initWork?.invoke() }
        // The hard fallback: whatever happens to the frame clock (a window that never draws, a device that stops delivering frames), the opening cannot stay up. Its own time
        // plus a margin later it ends, and the app is revealed as soon as it is ready. Posted on the main thread, outside any screen, so no rebuilt screen can cancel it.
        val limit = (plan?.variant ?: OpeningVariant.FIRST_INSTALL).durationMs + 4_000L
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ forceEnd() }, limit)
    }

    /** The fallback's end: the story counts as told; if the exit has not finished, it is finished now. */
    private fun forceEnd() {
        if (!visible || frozenAtMs != null) return
        machine.animationFinished()
        if (machine.state == StartupState.TRANSITIONING) { exitProgress = 1f; machine.exitFinished() }
    }

    /** What the start-up found: whether any connection (or draft) exists, and whether a working one does. */
    data class HasSources(val any: Boolean, val connections: Boolean)

    private fun applyPlan(p: LaunchPlan) { plan = p; machine.planned(p); p.variant?.let { app.streamsetu.tv.opening.presentation.OpeningSound.start(it) } }

    /**
     * One frame, at the frame clock's [nanos]. Moves the story on, ends it when its time is up, runs the exit fade, and notices slow frames. Pure arithmetic on the saved
     * start time: a recomposition, a recreated activity or a pause only changes how many frames are drawn, never where the story is.
     */
    fun onFrame(nanos: Long) {
        val variant = plan?.variant ?: return
        frozenAtMs?.let { elapsedMs = it; return }
        when (machine.state) {
            StartupState.ANIMATING, StartupState.AWAITING_DESTINATION, StartupState.INITIALIZING, StartupState.READY, StartupState.FAILED -> {
                if (startNanos == UNSET || nanos < startNanos) startNanos = nanos
                elapsedMs = ((nanos - startNanos) / 1_000_000f).coerceAtMost(variant.holdMs.toFloat())
                if (elapsedMs >= variant.holdMs) machine.animationFinished()
                // The exit is timed from this frame when the app was already ready.
                if (machine.state == StartupState.TRANSITIONING) exitStartNanos = nanos
                noteFrame(nanos)
            }
            StartupState.TRANSITIONING -> {
                if (exitStartNanos == UNSET || nanos < exitStartNanos) exitStartNanos = nanos
                exitProgress = ((nanos - exitStartNanos) / 1_000_000f / variant.exitMs).coerceIn(0f, 1f)
                if (exitProgress >= 1f) machine.exitFinished()
            }
            else -> {}
        }
    }

    /** If the first frames come slowly (over 28 ms on average), the rest of the opening is drawn in the plain look. */
    private fun noteFrame(nanos: Long) {
        if (lastNanos != 0L && countedFrames < 20) {
            countedFrames++
            if (nanos - lastNanos > 28_000_000L) slowFrames++
            if (countedFrames == 20 && slowFrames >= 8) lightweight = true
        }
        lastNanos = nanos
    }

    /** Only for tests: a fresh process, as far as the opening is concerned. */
    internal fun resetForTests() {
        machine = StartupMachine(onCompleted = { finish() }); plan = null; elapsedMs = 0f; exitProgress = 0f; showWhatsNew = false; lightweight = false; frozenAtMs = null
        startNanos = UNSET; exitStartNanos = UNSET; lastNanos = 0L; slowFrames = 0; countedFrames = 0; swallowUp = -1; quiet = false
    }

    fun retry() { if (machine.state == StartupState.FAILED) { machine.retry(); scope?.launch { initWork?.invoke() } } }
    fun continueAnyway() = machine.continueAnyway()

    /**
     * Keys while the opening is on screen (the activity hands every key here first). The opening cannot be skipped: a key pressed while it plays is simply ignored (Back
     * included, so it never leaves the app), and the release of that same key is ignored too, so it does not land on the app underneath. The media keys still reach the player.
     * Once the opening has gone, nothing is taken. Returns true when the key was taken.
     */
    private var swallowUp = -1
    fun onKey(keyCode: Int, down: Boolean): Boolean {
        if (!down && keyCode == swallowUp) { swallowUp = -1; return true }
        if (!visible || machine.state == StartupState.FAILED) return false
        if (keyCode in MEDIA_KEYS) return false
        if (down) swallowUp = keyCode
        return true
    }
    private val MEDIA_KEYS = setOf(
        android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, android.view.KeyEvent.KEYCODE_MEDIA_PLAY, android.view.KeyEvent.KEYCODE_MEDIA_PAUSE, android.view.KeyEvent.KEYCODE_MEDIA_STOP,
        android.view.KeyEvent.KEYCODE_MEDIA_NEXT, android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS, android.view.KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, android.view.KeyEvent.KEYCODE_MEDIA_REWIND,
        android.view.KeyEvent.KEYCODE_VOLUME_UP, android.view.KeyEvent.KEYCODE_VOLUME_DOWN, android.view.KeyEvent.KEYCODE_VOLUME_MUTE,
    )

    /** The opening is gone: what it means is saved once (a new install has seen this version; an update goes on to What's New). */
    private fun finish() {
        val p = plan ?: return
        if (quiet) return
        prefs?.edit()?.apply {
            putBoolean(INTRO_DONE, true)
            if (p.newInstall) putString(SEEN, AppRelease.current)
        }?.apply()
        if (p.whatsNew) showWhatsNew = true
    }

    /** What's New was read: it is not shown again for this version. */
    fun whatsNewDone() {
        showWhatsNew = false
        prefs?.edit()?.putString(SEEN, AppRelease.current)?.apply()
    }
}
