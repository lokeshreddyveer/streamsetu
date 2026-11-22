package app.streamsetu.tv.opening

import app.streamsetu.tv.opening.domain.Easing
import app.streamsetu.tv.opening.domain.OpeningMotionState
import app.streamsetu.tv.opening.domain.OpeningTimeline
import app.streamsetu.tv.opening.domain.OpeningVariant
import app.streamsetu.tv.opening.domain.Scene
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** The "Tune In" timeline: scenes in order without gaps, every keyframe inside its variant, frames that change smoothly, the hero beats where they belong, and the lockup at the end. */
class OpeningTimelineTests {
    private val animated = listOf(OpeningVariant.FIRST_INSTALL, OpeningVariant.STANDARD)

    @Test fun scenesRunInOrderWithoutGapsAndEndAtTheDuration() {
        for (v in OpeningVariant.entries) {
            assertEquals(0, v.scenes.first().startMs)
            v.scenes.zipWithNext().forEach { (a, b) -> assertEquals("$v ${a.scene} ends where ${b.scene} starts", a.endMs, b.startMs) }
            assertEquals(v.durationMs, v.scenes.last().endMs)
            assertEquals(v.durationMs - v.exitMs, v.holdMs)
        }
        assertEquals(Scene.MATCH_CUT, OpeningVariant.FIRST_INSTALL.scenes.last().scene)
        assertEquals(Scene.MATCH_CUT, OpeningVariant.STANDARD.scenes.last().scene)
        assertEquals(listOf(Scene.STILL, Scene.FADE), OpeningVariant.REDUCED.scenes.map { it.scene })
        assertEquals(7500, OpeningVariant.FIRST_INSTALL.durationMs); assertEquals(2800, OpeningVariant.STANDARD.durationMs)
    }

    @Test fun everyKeyframeLiesInsideItsVariantAndBeforeTheMatchCut() {
        for (v in animated) {
            val k = v.keys!!
            for (r in listOfNotNull(k.set, k.dot, k.sweep, k.twitch, k.snow, k.warm, k.push, k.easeBack, k.ribbonRear, k.ribbonFront, k.swell, k.press, k.glint, k.sheen, k.name, k.tagline)) {
                assertTrue("$v $r", r.first >= 0 && r.last <= v.holdMs && r.first < r.last)
            }
            assertEquals(v.holdMs..v.durationMs, k.cut)
            // The ribbon draws behind the set first, then round the front.
            assertTrue(k.ribbonRear.first < k.ribbonFront.first)
            // The hero (the press-in) falls in the hero scene.
            val hero = v.scenes.first { it.scene == Scene.HERO }
            assertTrue(k.press.first >= hero.startMs && k.press.first < hero.endMs)
        }
    }

    @Test fun theShortCutHasItsOwnTimingsNotTheFullStorySpedUp() {
        val full = OpeningVariant.FIRST_INSTALL; val short = OpeningVariant.STANDARD
        val ratio = full.durationMs.toFloat() / short.durationMs
        assertTrue(abs(full.keys!!.press.first / ratio - short.keys!!.press.first) > 50f)
        assertTrue(full.keys!!.easeBack != null && short.keys!!.easeBack == null)
    }

    @Test fun framesChangeSmoothlyFromOneMillisecondToTheNext() {
        for (v in animated) {
            var prev = OpeningTimeline.state(v, 0f)
            for (ms in 1..v.holdMs + 50) {
                val s = OpeningTimeline.state(v, ms.toFloat())
                val pairs = listOf(prev.roomGlow to s.roomGlow, prev.set to s.set, prev.dot to s.dot, prev.swell to s.swell, prev.press to s.press, prev.warm to s.warm,
                    prev.camera to s.camera, prev.ribbonRear to s.ribbonRear, prev.ribbonFront to s.ribbonFront, prev.glint to s.glint, prev.name to s.name, prev.tagline to s.tagline, prev.snow to s.snow)
                // The short cut moves almost three times as quickly as the full story.
                val limit = if (v == OpeningVariant.STANDARD) 0.06f else 0.03f
                pairs.forEachIndexed { i, (a, b) -> assertTrue("$v at $ms ms, value $i jumped from $a to $b", abs(a - b) <= limit) }
                prev = s
            }
        }
    }

    @Test fun theCameraPushStaysInsideTheBriefAndNothingFlashes() {
        for (v in animated) {
            var maxCam = 1f
            for (ms in 0..v.durationMs step 5) { val s = OpeningTimeline.state(v, ms.toFloat()); maxCam = maxOf(maxCam, s.camera); assertTrue(s.camera >= 0.98f); assertTrue("snow stays faint", s.snow <= 0.12f) }
            assertTrue("push between 3 % and 5 %", maxCam - 1f in 0.03f..0.05f)
        }
    }

    @Test fun theStoryEndsOnTheLockupAndReducedMotionIsTheStill() {
        for (v in animated) {
            val end = OpeningTimeline.state(v, v.holdMs.toFloat())
            assertEquals(OpeningMotionState.LOCKUP.copy(camera = 1f + OpeningTimeline.PUSH), end)
            assertEquals(end, OpeningTimeline.state(v, v.durationMs + 5000f))
            val start = OpeningTimeline.state(v, 0f)
            assertEquals(0f, start.name); assertEquals(0f, start.swell); assertEquals(0f, start.ribbonFront)
        }
        assertEquals(OpeningMotionState.LOCKUP, OpeningTimeline.state(OpeningVariant.REDUCED, 0f))
        assertEquals(OpeningMotionState.LOCKUP, OpeningTimeline.state(OpeningVariant.REDUCED, 900f))
    }

    @Test fun scenesAreFoundByTime() {
        assertEquals(Scene.DARK, OpeningTimeline.sceneAt(OpeningVariant.FIRST_INSTALL, 0))
        assertEquals(Scene.HERO, OpeningTimeline.sceneAt(OpeningVariant.FIRST_INSTALL, 4600))
        assertEquals(Scene.WARM_WRAP, OpeningTimeline.sceneAt(OpeningVariant.STANDARD, 1500))
        assertEquals(Scene.MATCH_CUT, OpeningTimeline.sceneAt(OpeningVariant.STANDARD, 2799))
        assertNull(OpeningTimeline.sceneAt(OpeningVariant.FIRST_INSTALL, 7500))
    }

    @Test fun easingsStartAtZeroEndAtOneAndNeverLeaveTheRange() {
        for (e in listOf(Easing::easeOut, Easing::easeIn, Easing::cubicInOut, Easing::smoothstep, Easing::slowInOut)) {
            assertEquals(0f, e(0f), 1e-5f); assertEquals(1f, e(1f), 1e-5f)
            assertEquals(0f, e(-1f), 1e-5f); assertEquals(1f, e(2f), 1e-5f)
            var last = 0f
            for (i in 0..100) { val y = e(i / 100f); assertTrue(y in 0f..1f && y >= last - 1e-6f); last = y }
        }
        assertEquals(0f, Easing.bump(0f), 1e-5f); assertEquals(1f, Easing.bump(0.5f), 1e-5f)
    }
}
