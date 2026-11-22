package app.streamsetu.tv.opening

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.tv.opening.domain.OpeningVariant
import app.streamsetu.tv.opening.startup.AppRelease
import app.streamsetu.tv.opening.startup.StartupCoordinator
import app.streamsetu.tv.opening.startup.StartupCoordinator.HasSources
import app.streamsetu.tv.opening.startup.StartupState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The process-wide owner of the opening: it plays once per process, a rebuilt screen continues it rather than restarting it, its end comes from the elapsed time (so it cannot
 * stay on screen), a key skips it, and what it means is saved once.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class StartupCoordinatorTests {
    private val ctx: Context get() = ApplicationProvider.getApplicationContext()
    private val prefs get() = ctx.getSharedPreferences("ui", Context.MODE_PRIVATE)
    private val ms = 1_000_000L

    @Before fun fresh() { StartupCoordinator.resetForTests(); prefs.edit().clear().commit() }
    @After fun done() { StartupCoordinator.resetForTests() }

    private fun begin(any: Boolean = false, connections: Boolean = false, reduced: Boolean = false, fail: Boolean = false) {
        StartupCoordinator.begin(ctx, CoroutineScope(Dispatchers.Main.immediate), reduced, suppressed = false, frozenAt = null) { if (fail) error("database") else HasSources(any, connections) }
        repeat(50) { if (StartupCoordinator.machine.initOk == null) { shadowOf(android.os.Looper.getMainLooper()).idle(); Thread.sleep(10) } }
    }
    /** Frames every 16 ms from [from] to [to] (in ms of the frame clock). */
    private fun frames(from: Long, to: Long) { var t = from; while (t <= to) { StartupCoordinator.onFrame(t * ms); t += 16 } }

    @Test fun aNewInstallPlaysTheFullOpeningOnceAndSavesItsEnd() {
        begin()
        assertEquals(OpeningVariant.FIRST_INSTALL, StartupCoordinator.plan?.variant)
        frames(1000, 1000 + 7030)
        assertEquals(StartupState.TRANSITIONING, StartupCoordinator.state)
        frames(8040, 8040 + 520)
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
        assertTrue(prefs.getBoolean("intro_done", false)); assertEquals(AppRelease.current, prefs.getString("whatsnew_seen_version", null))
        assertFalse(StartupCoordinator.showWhatsNew)
        // A second call in the same process (a recreated activity, a warm resume) does not play it again.
        StartupCoordinator.begin(ctx, CoroutineScope(Dispatchers.Main.immediate), false, false, null) { HasSources(false, false) }
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state); assertFalse(StartupCoordinator.visible)
    }

    @Test fun aRebuiltScreenContinuesWhereTheStoryWas() {
        begin()
        frames(5000, 5800)
        val at = StartupCoordinator.elapsedMs
        // The activity is recreated (turning the device): the new screen keeps sending frames on the same clock; the story does not start again.
        frames(5816, 5900)
        assertTrue(StartupCoordinator.elapsedMs > at && StartupCoordinator.elapsedMs < 1000f)
    }

    @Test fun theOpeningSettingIsSavedAndReadBack() {
        StartupCoordinator.setMode(ctx, app.streamsetu.tv.opening.startup.OpeningMode.OFF)
        assertEquals(app.streamsetu.tv.opening.startup.OpeningMode.OFF, StartupCoordinator.mode(ctx))
        prefs.edit().putBoolean("intro_done", true).putString("whatsnew_seen_version", AppRelease.current).commit()
        begin(any = true, connections = true)
        assertEquals(null, StartupCoordinator.plan?.variant)
        assertEquals("with the opening off, the app is revealed as soon as it is ready", StartupState.TRANSITIONING, StartupCoordinator.state)
    }

    @Test fun aLongPauseEndsTheStoryInsteadOfLeavingItOnScreen() {
        begin()
        frames(0, 300)
        // In the background no frames arrive; the first frame back is far later, and the story is over.
        StartupCoordinator.onFrame(60_000 * ms)
        assertEquals(StartupState.TRANSITIONING, StartupCoordinator.state)
        StartupCoordinator.onFrame(60_000 * ms + 600 * ms)
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
    }

    @Test fun anUpdateShowsWhatsNewAfterTheShortCut() {
        prefs.edit().putBoolean("intro_done", true).putString("whatsnew_seen_version", "0.0.1 (1)").commit()
        begin(any = true, connections = true)
        assertEquals(OpeningVariant.STANDARD, StartupCoordinator.plan?.variant)
        frames(0, 2670); frames(2686, 2900)
        assertTrue(StartupCoordinator.showWhatsNew)
        StartupCoordinator.whatsNewDone()
        assertFalse(StartupCoordinator.showWhatsNew); assertEquals(AppRelease.current, prefs.getString("whatsnew_seen_version", null))
    }

    @Test fun laterLaunchesPlayTheShortCutWhichNoKeyCanSkip() {
        prefs.edit().putBoolean("intro_done", true).putString("whatsnew_seen_version", AppRelease.current).commit()
        begin(any = true, connections = true)
        assertEquals(OpeningVariant.STANDARD, StartupCoordinator.plan?.variant)
        frames(0, 100)
        assertTrue("a key during the opening is ignored", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_DPAD_CENTER, down = true))
        assertTrue("Back is ignored, never leaves the app", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_BACK, down = true))
        assertEquals("nothing skips it", StartupState.ANIMATING, StartupCoordinator.state)
        assertTrue("the release of a key pressed during it does not reach the app", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_BACK, down = false))
        assertFalse("media keys pass through", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, down = true))
        frames(116, 2670)
        assertEquals(StartupState.TRANSITIONING, StartupCoordinator.state)
        frames(2686, 2900)
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
        assertFalse("keys go to the app once it is gone", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_DPAD_CENTER, down = true))
        assertFalse(StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_DPAD_CENTER, down = false))
    }

    @Test fun ifNoFramesArriveTheFallbackStillEndsIt() {
        prefs.edit().putBoolean("intro_done", true).putString("whatsnew_seen_version", AppRelease.current).commit()
        begin(any = true, connections = true)
        assertTrue(StartupCoordinator.visible)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(2800 + 4100))
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
    }

    @Test fun reducedMotionShowsTheStillLockupThenTheApp() {
        begin(reduced = true)
        assertEquals(OpeningVariant.REDUCED, StartupCoordinator.plan?.variant)
        frames(0, 900)
        assertEquals("the still holds for its second", StartupState.ANIMATING, StartupCoordinator.state)
        frames(916, 1030)
        assertEquals(StartupState.TRANSITIONING, StartupCoordinator.state)
        frames(1040, 1480)
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
    }

    @Test fun aFailedStartUpWaitsOnTheRecoveryPanelAndContinueAlwaysGetsOut() {
        begin(fail = true)
        frames(0, 7100)
        assertEquals(StartupState.FAILED, StartupCoordinator.state)
        assertFalse("keys go to the recovery panel", StartupCoordinator.onKey(android.view.KeyEvent.KEYCODE_DPAD_CENTER, down = true))
        StartupCoordinator.continueAnyway()
        frames(7116, 7700)
        assertEquals(StartupState.COMPLETED, StartupCoordinator.state)
    }
}
