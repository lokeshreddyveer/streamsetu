package app.streamsetu.tv.opening

import app.streamsetu.tv.opening.domain.OpeningVariant
import app.streamsetu.tv.opening.startup.LaunchPlan
import app.streamsetu.tv.opening.startup.OpeningMode
import app.streamsetu.tv.opening.startup.StartupMachine
import app.streamsetu.tv.opening.startup.StartupState
import app.streamsetu.tv.opening.startup.StartupState.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The start-up order: the opening and the app's start-up can finish in either order, the app is revealed exactly once, and nothing can leave it stuck. */
class StartupMachineTests {
    private val signature = LaunchPlan(OpeningVariant.FIRST_INSTALL, whatsNew = false, newInstall = true)
    private fun machine(): Triple<StartupMachine, IntArray, IntArray> { val r = IntArray(1); val c = IntArray(1); return Triple(StartupMachine({ r[0]++ }, { c[0]++ }), r, c) }

    @Test fun animationFirstThenInitialization() {
        val (m, revealed, completed) = machine()
        m.start(); m.planned(signature); assertEquals(ANIMATING, m.state)
        m.animationFinished(); assertEquals(AWAITING_DESTINATION, m.state); assertEquals(0, revealed[0])
        m.initFinished(true); assertEquals(TRANSITIONING, m.state); assertEquals(1, revealed[0])
        m.exitFinished(); assertEquals(COMPLETED, m.state); assertEquals(1, completed[0])
        assertEquals(listOf(NOT_STARTED, STARTING, ANIMATING, AWAITING_DESTINATION, READY, TRANSITIONING, COMPLETED), m.history)
    }

    @Test fun initializationFirstThenAnimation() {
        val (m, revealed, _) = machine()
        m.start(); m.planned(signature); m.initFinished(true)
        assertEquals("the story is never cut short by a fast start-up", ANIMATING, m.state); assertEquals(0, revealed[0])
        m.animationFinished(); assertEquals(TRANSITIONING, m.state); assertEquals(1, revealed[0])
    }

    @Test fun initializationBeforeThePlanIsKnown() {
        val (m, revealed, _) = machine()
        m.start(); m.initFinished(true); assertEquals(STARTING, m.state)
        m.planned(signature); m.animationFinished(); assertEquals(TRANSITIONING, m.state); assertEquals(1, revealed[0])
    }

    @Test fun theAppIsRevealedAndCompletedExactlyOnceWhateverArrivesTwice() {
        val (m, revealed, completed) = machine()
        m.start(); m.planned(signature)
        repeat(3) { m.animationFinished(); m.initFinished(true) }
        repeat(3) { m.exitFinished() }
        m.continueAnyway(); m.retry(); m.start(); m.planned(signature)
        assertEquals(1, revealed[0]); assertEquals(1, completed[0]); assertEquals(COMPLETED, m.state)
    }

    @Test fun aFailedStartUpShowsRecoveryAndBothWaysOutWork() {
        val (m, revealed, _) = machine()
        m.start(); m.planned(signature); m.initFinished(false); m.animationFinished()
        assertEquals(FAILED, m.state); assertEquals(0, revealed[0])
        m.retry(); assertEquals(AWAITING_DESTINATION, m.state)
        m.initFinished(true); assertEquals(TRANSITIONING, m.state); assertEquals(1, revealed[0])

        val (m2, revealed2, _) = machine()
        m2.start(); m2.planned(signature); m2.animationFinished(); m2.initFinished(false)
        assertEquals(FAILED, m2.state)
        m2.continueAnyway(); assertEquals(TRANSITIONING, m2.state); assertEquals(1, revealed2[0])
    }

    @Test fun noOpeningOnlyWaitsForTheStartUp() {
        val (m, revealed, _) = machine()
        m.start(); m.planned(LaunchPlan.NONE); assertEquals(INITIALIZING, m.state); assertTrue(m.animationDone)
        m.initFinished(true); assertEquals(TRANSITIONING, m.state); assertEquals(1, revealed[0])
    }

    @Test fun theReducedMotionStillIsHeldLikeAnyOtherOpening() {
        val (m, revealed, _) = machine()
        m.start(); m.planned(LaunchPlan(OpeningVariant.REDUCED, false, false)); m.initFinished(true)
        assertEquals("the still is shown for its second before the app", ANIMATING, m.state); assertEquals(0, revealed[0])
        m.animationFinished(); assertEquals(TRANSITIONING, m.state)
    }

    @Test fun eventsBeforeTheStartAreIgnored() {
        val (m, _, _) = machine()
        m.animationFinished(); m.exitFinished(); m.planned(signature)
        assertEquals(NOT_STARTED, m.state); assertFalse(m.animationDone)
    }

    // ---- The launch plan ----
    private fun plan(introDone: Boolean = true, any: Boolean = true, connections: Boolean = true, seen: String? = "1.0 (1)", reduced: Boolean = false, suppressed: Boolean = false, mode: OpeningMode = OpeningMode.AUTOMATIC, replay: Boolean = false) =
        LaunchPlan.decide(introDone, any, connections, seen, "1.0 (1)", reduced, suppressed, mode, replay)

    @Test fun theFirstLaunchOfANewInstallGetsTheFullStoryAndNoWhatsNew() {
        val p = plan(introDone = false, any = false, connections = false, seen = null)
        assertEquals(OpeningVariant.FIRST_INSTALL, p.variant); assertTrue(p.newInstall); assertFalse(p.whatsNew)
    }

    @Test fun anUpdateGetsTheShortCutThenWhatsNew() {
        val p = plan(seen = "0.9 (1)")
        assertEquals(OpeningVariant.STANDARD, p.variant); assertTrue(p.whatsNew); assertFalse(p.newInstall)
        // An install from before the opening existed (nothing saved yet, but connections) is an update too.
        assertTrue(plan(introDone = false, seen = null).whatsNew)
    }

    @Test fun everyOtherLaunchGetsTheShortCut() {
        assertEquals(LaunchPlan(OpeningVariant.STANDARD, false, false), plan())
        assertEquals(OpeningVariant.STANDARD, plan(any = false, connections = false, seen = "0.9 (1)").variant)
    }

    @Test fun theOpeningSettingCanTurnItOffAndTheFullStoryCanBeReplayed() {
        assertEquals(null, plan(mode = OpeningMode.OFF).variant)
        // Off still shows What's New after an update, and still counts a new install as one.
        assertTrue(plan(seen = "0.9 (1)", mode = OpeningMode.OFF).whatsNew)
        assertTrue(plan(introDone = false, any = false, connections = false, seen = null, mode = OpeningMode.OFF).newInstall)
        assertEquals(OpeningVariant.FIRST_INSTALL, plan(replay = true).variant)
        // Reduced motion wins over a replay.
        assertEquals(OpeningVariant.REDUCED, plan(replay = true, reduced = true).variant)
        assertEquals(OpeningMode.AUTOMATIC, OpeningMode.of(null)); assertEquals(OpeningMode.OFF, OpeningMode.of("off"))
    }

    @Test fun reducedMotionKeepsThePlanButShowsTheStillLockup() {
        val p = plan(seen = "0.9 (1)", reduced = true)
        assertEquals(OpeningVariant.REDUCED, p.variant); assertTrue(p.whatsNew)
    }

    @Test fun testRunsAndTheSkipSwitchShowNothing() { assertEquals(LaunchPlan.NONE, plan(introDone = false, any = false, connections = false, seen = null, suppressed = true)) }

    @Test fun onlyAnInstallThatHasSeenThisVersionIsSettledWithoutTheDatabase() {
        assertTrue(LaunchPlan.settledWithoutDatabase(true, "1.0 (1)", "1.0 (1)"))
        assertFalse(LaunchPlan.settledWithoutDatabase(false, "1.0 (1)", "1.0 (1)"))
        assertFalse(LaunchPlan.settledWithoutDatabase(true, null, "1.0 (1)"))
    }

    @Test fun everyStateIsReachable() {
        val seen = mutableSetOf<StartupState>()
        val (a, _, _) = machine(); a.start(); a.planned(signature); a.animationFinished(); a.initFinished(false); a.continueAnyway(); a.exitFinished(); seen += a.history
        val (b, _, _) = machine(); b.start(); b.planned(LaunchPlan.NONE); seen += b.history
        assertEquals(StartupState.entries.toSet(), seen)
    }
}
