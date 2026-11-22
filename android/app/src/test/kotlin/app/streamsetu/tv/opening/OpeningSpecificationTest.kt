package app.streamsetu.tv.opening

import app.streamsetu.tv.opening.domain.OpeningVariant
import app.streamsetu.tv.opening.rendering.OpeningColors
import app.streamsetu.tv.opening.rendering.TuneInGeometry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The Android opening against the canonical specification at the root of the repository (motion/specification). Every platform draws the same opening from those files;
 * this fails the moment the Kotlin tables, colours or geometry and the JSON say different things.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class OpeningSpecificationTest {
    private val dir = File("../../motion/specification")
    private fun json(name: String) = JSONObject(File(dir, name).also { assertTrue("missing ${it.path}", it.isFile) }.readText())

    @Test fun identityAndArtboard() {
        val spec = json("opening-motion.json")
        assertEquals("streamsetu.tune-in", spec.getString("id"))
        assertEquals(4, spec.getInt("version"))
        assertEquals(1000, spec.getJSONObject("artboard").getInt("width"))
        assertEquals(600, spec.getJSONObject("artboard").getInt("height"))
    }

    @Test fun everyVariantMatchesItsSceneTable() {
        val variants = json("opening-motion.json").getJSONObject("variants")
        assertEquals(OpeningVariant.entries.map { it.id }.toSet(), variants.keys().asSequence().toSet())
        for (v in OpeningVariant.entries) {
            val j = variants.getJSONObject(v.id)
            assertEquals("${v.id} duration", j.getInt("durationMs"), v.durationMs)
            val scenes = j.getJSONArray("scenes")
            assertEquals("${v.id} scene count", scenes.length(), v.scenes.size)
            for (i in 0 until scenes.length()) {
                val s = scenes.getJSONObject(i); val k = v.scenes[i]
                assertEquals("${v.id} scene $i", s.getString("name"), k.scene.id)
                assertEquals("${v.id} ${k.scene.id} start", s.getInt("startMs"), k.startMs)
                assertEquals("${v.id} ${k.scene.id} end", s.getInt("endMs"), k.endMs)
            }
        }
    }

    /** The beats inside each cut (keyframesMs for the short cut, keyframesMsFirstInstall for the full story). */
    @Test fun keyframesMatchTheSpecification() {
        val spec = json("opening-motion.json")
        fun range(o: JSONObject, name: String) = o.getJSONArray(name).let { it.getInt(0)..it.getInt(1) }
        fun mid(r: IntRange) = (r.first + r.last) / 2
        val s = spec.getJSONObject("keyframesMs"); val k = OpeningVariant.STANDARD.keys!!
        assertEquals(s.getInt("dotAppears"), k.dot.first)
        assertEquals(s.getInt("lightSweepStart")..s.getInt("lightSweepEnd"), k.sweep)
        assertEquals(range(s, "antennaTwitch"), k.twitch); assertEquals(s.getInt("snowPeak"), mid(k.snow))
        assertEquals(range(s, "screenWarm"), k.warm); assertEquals(range(s, "ribbonRearDraw"), k.ribbonRear); assertEquals(range(s, "ribbonFrontDraw"), k.ribbonFront)
        assertEquals(range(s, "dotToPlay"), k.swell); assertEquals(range(s, "heroPressIn"), k.press); assertEquals(s.getInt("glint"), mid(k.glint))
        assertEquals(range(s, "ribbonSheen"), k.sheen); assertEquals(range(s, "wordmark"), k.name); assertEquals(range(s, "tagline"), k.tagline); assertEquals(range(s, "matchCutExpand"), k.cut)
        val f = spec.getJSONObject("keyframesMsFirstInstall"); val x = OpeningVariant.FIRST_INSTALL.keys!!
        assertEquals(f.getInt("dotAppears"), x.dot.first); assertEquals(range(f, "lightSweep"), x.sweep); assertEquals(range(f, "antennaTwitch"), x.twitch); assertEquals(range(f, "snow"), x.snow)
        assertEquals(range(f, "screenWarm"), x.warm); assertEquals(range(f, "ribbonRearDraw"), x.ribbonRear); assertEquals(range(f, "ribbonFrontDraw"), x.ribbonFront)
        assertEquals(range(f, "dotToPlay"), x.swell); assertEquals(range(f, "heroPressIn"), x.press); assertEquals(f.getInt("glint"), mid(x.glint))
        assertEquals(range(f, "ribbonSheen"), x.sheen); assertEquals(range(f, "wordmark"), x.name); assertEquals(range(f, "tagline"), x.tagline); assertEquals(range(f, "matchCutExpand"), x.cut)
        // The launch plan names the variants the app plays.
        val plan = spec.getJSONObject("launchPlan")
        assertEquals(OpeningVariant.FIRST_INSTALL.id, plan.getString("newInstallFirstLaunch")); assertEquals(OpeningVariant.STANDARD.id, plan.getString("everyOtherLaunch"))
        assertEquals(OpeningVariant.REDUCED.id, plan.getString("reduceMotion"))
    }

    /** The layered artwork's own measurements (motion/assets/tune-in/manifest.json) are the ones the renderer uses. */
    @Test fun layerGeometryMatchesTheManifest() {
        val m = JSONObject(File("../../motion/assets/tune-in/manifest.json").readText()); val geo = TuneInGeometry()
        assertEquals(1024, m.getJSONObject("canvas").getInt("width"))
        val play = m.getJSONObject("playButton").getJSONArray("center"); assertEquals(play.getDouble(0).toFloat(), geo.play.x, 0.01f); assertEquals(play.getDouble(1).toFloat(), geo.play.y, 0.01f)
        val w = m.getJSONObject("screen").getJSONArray("windowBBox"); assertEquals(w.getDouble(0).toFloat(), geo.window.left, 0.01f); assertEquals(w.getDouble(3).toFloat(), geo.window.bottom, 0.01f)
        val ribbon = m.getJSONObject("ribbon"); val line = ribbon.getJSONArray("centerline")
        assertEquals(line.length(), TuneInGeometry.CENTRE_LINE.size); assertEquals(ribbon.getInt("rearPointCount"), TuneInGeometry.REAR_POINTS)
        for (i in 0 until line.length()) { assertEquals(line.getJSONArray(i).getDouble(0).toFloat(), TuneInGeometry.CENTRE_LINE[i][0], 0.01f); assertEquals(line.getJSONArray(i).getDouble(1).toFloat(), TuneInGeometry.CENTRE_LINE[i][1], 0.01f) }
        val layers = m.getJSONArray("layers"); val left = (0 until layers.length()).map { layers.getJSONObject(it) }.first { it.getString("name") == "antenna-left" }
        assertEquals(left.getJSONObject("pivot").getDouble("x").toFloat(), geo.antennaLeftPivot.x, 0.01f)
        assertEquals(left.getDouble("maxTwitchDeg").toFloat(), geo.maxTwitchDeg, 0.01f)
    }

    @Test fun coloursMatchTheTokens() {
        val c = json("design-tokens.json").getJSONObject("color")
        fun hex(color: androidx.compose.ui.graphics.Color) = "#%06X".format(color.value.toLong().ushr(32).toInt() and 0xFFFFFF)
        assertEquals(c.getString("background"), hex(OpeningColors.background))
        assertEquals(c.getString("backgroundGlow"), hex(OpeningColors.backgroundGlow))
        assertEquals(c.getString("brandTeal"), hex(OpeningColors.teal))
        assertEquals(c.getString("brandIceTeal"), hex(OpeningColors.iceTeal))
        assertEquals(c.getString("brandSilver"), hex(OpeningColors.silver))
        assertEquals(c.getString("cream"), hex(OpeningColors.cream))
        assertEquals(c.getString("foreground"), hex(OpeningColors.foreground))
        assertEquals(c.getString("foregroundSecondary"), hex(OpeningColors.foregroundSecondary))
    }

    @Test fun geometryMatchesTheTokens() {
        val g = json("design-tokens.json").getJSONObject("geometry"); val geo = TuneInGeometry()
        val mark = g.getJSONObject("mark")
        assertEquals(mark.getDouble("centerX").toFloat(), geo.markCenter.x, 0.01f)
        assertEquals(mark.getDouble("centerY").toFloat(), geo.markCenter.y, 0.01f)
        assertEquals(mark.getDouble("size").toFloat(), geo.markSize, 0.01f)
        assertEquals(g.getDouble("wordmarkBaselineY").toFloat(), geo.nameBaseline, 0.01f)
        assertEquals(g.getDouble("taglineBaselineY").toFloat(), geo.taglineBaseline, 0.01f)
    }
}
