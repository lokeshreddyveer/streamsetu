package app.streamsetu.tv.opening.startup

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.streamsetu.tv.opening.domain.OpeningVariant

/**
 * The start-up steps, the same on every platform. The opening and the app's own start-up run side by side and may finish in either order; whichever comes second moves on,
 * and the app is revealed exactly once.
 */
enum class StartupState { NOT_STARTED, STARTING, ANIMATING, INITIALIZING, AWAITING_DESTINATION, READY, FAILED, TRANSITIONING, COMPLETED }

/** The person's choice in Settings, Opening: automatic (the full story on the first ever launch, the short cut on every other) or off. */
enum class OpeningMode(val id: String, val label: String) {
    AUTOMATIC("auto", "Automatic"), OFF("off", "Off");
    companion object { fun of(id: String?) = entries.firstOrNull { it.id == id } ?: AUTOMATIC }
}

/** What this launch shows: which opening (none when it is off or in a test run), and whether What's New follows it. */
data class LaunchPlan(val variant: OpeningVariant?, val whatsNew: Boolean, val newInstall: Boolean) {
    companion object {
        val NONE = LaunchPlan(null, whatsNew = false, newInstall = false)

        /**
         * Pure, so it can be tested; the rules are the launchPlan block of motion/specification/opening-motion.json. [introDone]: an opening has been seen to its end on this
         * device. [hasSources]: a connection or a draft exists. [hasConnections]: a working (not draft) connection exists. [seenVersion]: the version whose What's New was last
         * shown. [suppressed]: a test run or SS_SKIP_INTRO. [replayFull]: the person asked (Settings) for the full story once more.
         * The first ever launch of a new install gets the full story; every other launch the short cut, and the first after an update then What's New. Reduced motion shows
         * the still lockup instead; the Off setting shows none (What's New still follows an update).
         */
        fun decide(introDone: Boolean, hasSources: Boolean, hasConnections: Boolean, seenVersion: String?, current: String, reducedMotion: Boolean, suppressed: Boolean,
                   mode: OpeningMode = OpeningMode.AUTOMATIC, replayFull: Boolean = false): LaunchPlan {
            if (suppressed) return NONE
            val newInstall = !introDone && !hasSources
            val update = !newInstall && hasConnections && seenVersion != current
            val story = when {
                mode == OpeningMode.OFF -> null
                reducedMotion -> OpeningVariant.REDUCED
                newInstall || replayFull -> OpeningVariant.FIRST_INSTALL
                else -> OpeningVariant.STANDARD
            }
            return LaunchPlan(story, whatsNew = update, newInstall = newInstall)
        }

        /** True when the saved settings alone settle the plan, so the first frame can start at once without reading the database: an install that has seen this version. */
        fun settledWithoutDatabase(introDone: Boolean, seenVersion: String?, current: String) = introDone && seenVersion == current
    }
}

/**
 * The start-up state machine, without any Android in it (so the order of events can be tested). Compose reads [state], so the screen follows it.
 * [onReveal] is called exactly once, when the app is revealed (the exit begins); [onCompleted] exactly once, when the opening layer is gone.
 */
class StartupMachine(private val onReveal: () -> Unit = {}, private val onCompleted: () -> Unit = {}) {
    var state by mutableStateOf(StartupState.NOT_STARTED); private set
    var animationDone = false; private set
    /** null while the app's start-up is still running; true when it finished, false when it failed. */
    var initOk by mutableStateOf<Boolean?>(null); private set
    private var revealed = false
    private var completed = false
    /** Every state passed through, in order (for tests and the start-up trace). */
    val history = mutableListOf(StartupState.NOT_STARTED)

    private fun go(s: StartupState) { if (state != s) { state = s; history += s } }

    /** The process has started the opening (once per process). */
    fun start() { if (state == StartupState.NOT_STARTED) go(StartupState.STARTING) }

    /** The plan is known: the opening plays (the reduced-motion still counts: it is held for its second), or, with none, only the start-up is waited for. */
    fun planned(plan: LaunchPlan) {
        if (state != StartupState.STARTING) return
        if (plan.variant == null) { animationDone = true; go(if (initOk == null) StartupState.INITIALIZING else StartupState.AWAITING_DESTINATION); settle() }
        else go(StartupState.ANIMATING)
    }

    /** The story reached its end (or was skipped). */
    fun animationFinished() {
        if (animationDone || state == StartupState.NOT_STARTED || state == StartupState.STARTING) return
        animationDone = true
        if (state == StartupState.ANIMATING) go(StartupState.AWAITING_DESTINATION)
        settle()
    }

    /** The app's own start-up finished: [ok] false means it failed and the recovery screen is shown. */
    fun initFinished(ok: Boolean) {
        if (initOk != null && state != StartupState.AWAITING_DESTINATION && state != StartupState.INITIALIZING) return
        initOk = ok
        settle()
    }

    /** From the recovery screen: try the start-up again. */
    fun retry() { if (state == StartupState.FAILED) { initOk = null; go(StartupState.AWAITING_DESTINATION) } }

    /** From the recovery screen: go into the app anyway. */
    fun continueAnyway() { if (state == StartupState.FAILED) { go(StartupState.READY); beginExit() } }

    /** The exit fade has ended: the opening layer leaves the screen for good. */
    fun exitFinished() {
        if (state != StartupState.TRANSITIONING || completed) return
        completed = true
        go(StartupState.COMPLETED)
        onCompleted()
    }

    private fun settle() {
        if (!animationDone) return
        if (state != StartupState.AWAITING_DESTINATION && state != StartupState.INITIALIZING) return
        when (initOk) {
            null -> {}
            true -> { go(StartupState.READY); beginExit() }
            false -> go(StartupState.FAILED)
        }
    }

    private fun beginExit() {
        go(StartupState.TRANSITIONING)
        if (!revealed) { revealed = true; onReveal() }
    }
}
