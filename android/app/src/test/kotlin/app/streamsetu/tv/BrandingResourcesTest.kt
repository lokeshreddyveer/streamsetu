package app.streamsetu.tv

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.util.zip.Inflater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The launcher icon, TV banner and in-app logos: every file the manifest and the adaptive icon point at exists, at the size its use needs,
 * and the artwork stays inside the area every launcher mask keeps. Reads the source resources, so it runs as a plain JVM test.
 */
class BrandingResourcesTest {
    private val res = File("src/main/res")
    private val densities = mapOf("mdpi" to 1.0, "hdpi" to 1.5, "xhdpi" to 2.0, "xxhdpi" to 3.0, "xxxhdpi" to 4.0)

    /** A decoded 8-bit RGB or RGBA PNG (the formats these resources use). AWT is not on the Android unit-test classpath. */
    private class Png(val width: Int, val height: Int, val hasAlpha: Boolean, private val px: IntArray) {
        fun getRGB(x: Int, y: Int) = px[y * width + x]
    }

    private fun image(path: String): Png {
        val f = File(res, path)
        assertTrue("missing $path", f.isFile)
        val input = DataInputStream(f.inputStream().buffered())
        val sig = ByteArray(8); input.readFully(sig)
        assertTrue("not a PNG: $path", sig.contentEquals(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)))
        var w = 0; var h = 0; var type = -1; val idat = ByteArrayOutputStream()
        while (true) {
            val len = input.readInt(); val kind = String(ByteArray(4).also { input.readFully(it) }, Charsets.US_ASCII)
            val data = ByteArray(len).also { input.readFully(it) }; input.readInt()
            when (kind) {
                "IHDR" -> { w = java.nio.ByteBuffer.wrap(data).int; h = java.nio.ByteBuffer.wrap(data, 4, 4).int; type = data[9].toInt()
                    assertEquals("$path: 8 bits per channel", 8, data[8].toInt()); assertEquals("$path: not interlaced", 0, data[12].toInt()) }
                "IDAT" -> idat.write(data)
                "IEND" -> break
            }
        }
        val bpp = when (type) { 2 -> 3; 6 -> 4; else -> error("$path: PNG colour type $type is not handled here") }
        val raw = ByteArray((w * bpp + 1) * h)
        Inflater().run {
            setInput(idat.toByteArray()); var n = 0
            while (n < raw.size && !finished()) { val got = inflate(raw, n, raw.size - n); if (got == 0 && (needsInput() || needsDictionary())) error("$path: image data is truncated"); n += got }
            end()
        }
        val stride = w * bpp; val prev = ByteArray(stride); val cur = ByteArray(stride); val px = IntArray(w * h)
        for (y in 0 until h) {
            val filter = raw[y * (stride + 1)].toInt(); System.arraycopy(raw, y * (stride + 1) + 1, cur, 0, stride)
            for (i in 0 until stride) {
                val a = if (i >= bpp) cur[i - bpp].toInt() and 0xFF else 0; val b = prev[i].toInt() and 0xFF; val c = if (i >= bpp) prev[i - bpp].toInt() and 0xFF else 0
                val add = when (filter) { 0 -> 0; 1 -> a; 2 -> b; 3 -> (a + b) / 2
                    4 -> { val p = a + b - c; val pa = Math.abs(p - a); val pb = Math.abs(p - b); val pc = Math.abs(p - c); if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c }
                    else -> error("$path: bad filter $filter") }
                cur[i] = ((cur[i].toInt() and 0xFF) + add).toByte()
            }
            for (x in 0 until w) {
                val o = x * bpp; val al = if (bpp == 4) cur[o + 3].toInt() and 0xFF else 255
                px[y * w + x] = (al shl 24) or ((cur[o].toInt() and 0xFF) shl 16) or ((cur[o + 1].toInt() and 0xFF) shl 8) or (cur[o + 2].toInt() and 0xFF)
            }
            System.arraycopy(cur, 0, prev, 0, stride)
        }
        return Png(w, h, type == 6, px)
    }

    private fun alpha(img: Png, x: Int, y: Int) = (img.getRGB(x, y) ushr 24) and 0xFF

    @Test fun `manifest points at the launcher icon and the TV banner`() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertEquals(2, Regex("""android:icon="@mipmap/ic_launcher"""").findAll(manifest).count())
        assertEquals(2, Regex("""android:roundIcon="@mipmap/ic_launcher_round"""").findAll(manifest).count())
        assertEquals(2, Regex("""android:banner="@drawable/tv_banner"""").findAll(manifest).count())
        assertTrue("the TV launcher entry", manifest.contains("android.intent.category.LEANBACK_LAUNCHER"))
    }

    @Test fun `adaptive icons name a background, a foreground and a monochrome layer that exist`() {
        for (name in listOf("ic_launcher", "ic_launcher_round")) {
            val xml = File(res, "mipmap-anydpi-v26/$name.xml").readText()
            assertTrue(xml.contains("""<background android:drawable="@drawable/ic_launcher_background" />"""))
            assertTrue(xml.contains("""<foreground android:drawable="@mipmap/ic_launcher_foreground" />"""))
            assertTrue(xml.contains("""<monochrome android:drawable="@mipmap/ic_launcher_monochrome" />"""))
        }
        assertTrue(File(res, "drawable/ic_launcher_background.xml").isFile)
        assertTrue(File(res, "drawable-night/ic_launcher_background.xml").isFile)
    }

    @Test fun `every density has its launcher files at the right size`() {
        for ((d, k) in densities) {
            val legacy = Math.round(48 * k).toInt(); val layer = Math.round(108 * k).toInt()
            for (n in listOf("ic_launcher", "ic_launcher_round")) image("mipmap-$d/$n.png").let { assertEquals("$d $n", legacy, it.width); assertEquals(legacy, it.height) }
            for (p in listOf("mipmap-$d/ic_launcher_foreground.png", "mipmap-night-$d/ic_launcher_foreground.png", "mipmap-$d/ic_launcher_monochrome.png"))
                image(p).let { assertEquals(p, layer, it.width); assertEquals(p, layer, it.height) }
        }
    }

    @Test fun `the round legacy icon is round`() {
        for (d in densities.keys) {
            val img = image("mipmap-$d/ic_launcher_round.png")
            assertEquals("$d corner should be clear", 0, alpha(img, 0, 0))
            assertEquals("$d centre should be solid", 255, alpha(img, img.width / 2, img.height / 2))
        }
    }

    @Test fun `the themed icon glyph stays inside the 66dp safe circle`() {
        val img = image("mipmap-xxxhdpi/ic_launcher_monochrome.png")          // 432px = 108dp, so 4px per dp
        val c = (img.width - 1) / 2.0
        var far = 0.0
        for (y in 0 until img.height) for (x in 0 until img.width) if (alpha(img, x, y) > 8) far = maxOf(far, Math.hypot(x - c, y - c))
        assertTrue("glyph reaches ${far / 4}dp from the centre", far / 4 <= 33.0)
        assertTrue("glyph is too small to read", far / 4 >= 24.0)
    }

    @Test fun `the colour foreground keeps its artwork inside the 66dp safe circle, on its background colour`() {
        for ((q, drawable) in listOf("" to "drawable", "night-" to "drawable-night")) {
            val colour = Regex("""android:color="#([0-9A-Fa-f]{6})"""").find(File(res, "$drawable/ic_launcher_background.xml").readText())!!.groupValues[1].toInt(16)
            for ((d, k) in densities) {
                val img = image("mipmap-$q$d/ic_launcher_foreground.png")
                assertEquals("$q$d: the foreground's backdrop is the background drawable's colour", colour, img.getRGB(2, 2) and 0xFFFFFF)
                val c = (img.width - 1) / 2.0
                for (y in 0 until img.height) for (x in 0 until img.width) {
                    if (Math.hypot(x - c, y - c) / k <= 33.0) continue        // the safe circle every mask keeps
                    val p = img.getRGB(x, y)
                    val diff = maxOf(Math.abs((p shr 16 and 0xFF) - (colour shr 16 and 0xFF)), Math.abs((p shr 8 and 0xFF) - (colour shr 8 and 0xFF)), Math.abs((p and 0xFF) - (colour and 0xFF)))
                    // a faint shadow may cross the line; any part of the TV itself differs from the backdrop by far more than this
                    assertTrue("$q$d: artwork at ($x,$y) lies outside the safe circle and can be cut by a mask", diff <= 16)
                }
            }
        }
    }

    @Test fun `the TV banner is an opaque 16 by 9 image and the in-app art has its sizes`() {
        image("drawable-nodpi/tv_banner.png").let { assertEquals(320, it.width); assertEquals(180, it.height); assertFalse("banner must be opaque", it.hasAlpha) }
        image("drawable-nodpi/brand_logo.png").let { assertEquals(256, it.width); assertEquals(256, it.height) }
        image("drawable-nodpi/brand_wordmark.png").let { assertEquals(960, it.width); assertEquals(540, it.height); assertEquals("wordmark corner should be transparent", 0, alpha(it, 0, 0)) }
    }

    @Test fun `no leftover launcher layers from the previous icon`() {
        for (d in densities.keys) assertFalse("drawable-$d/ic_launcher_foreground.png is superseded by the mipmap one", File(res, "drawable-$d/ic_launcher_foreground.png").exists())
        // Android requires the night qualifier before the density one; the reverse order fails the build.
        val bad = res.listFiles()!!.map { it.name }.filter { Regex("""-(l|m|h|xh|xxh|xxxh)dpi-night""").containsMatchIn(it) }
        assertTrue("misordered resource folders: $bad", bad.isEmpty())
    }
}
