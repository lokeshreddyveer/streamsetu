package app.streamsetu.tv.opening.rendering

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure

/** The opening's colours (motion/specification/design-tokens.json): teal and cream only, on a near-black deep teal. */
object OpeningColors {
    val background = Color(0xFF04090D)
    val backgroundGlow = Color(0xFF0A2A33)
    val teal = Color(0xFF1FA7B8)
    val iceTeal = Color(0xFF8FD8E3)
    val silver = Color(0xFFC9D2DA)
    val cream = Color(0xFFF2EEE6)
    val foreground = Color(0xFFF5F7FC)
    val foregroundSecondary = Color(0xFF9AA4AE)
    /** The teal the screen opens into at the match-cut. */
    val matchCut = Color(0xFF0B3A47)
}

/**
 * Where things are. The mark sits in a 330-unit square on the 1000 x 600 artboard (design-tokens.json); inside it the layered artwork (motion/assets/tune-in) is drawn on its
 * own 1024 x 1024 canvas, and everything below is in that canvas's units, from its manifest.json: the antenna pivots, the play button's centre, the screen's window, and the
 * ribbon's centre-line with its widths (the draw-on follows it: the part behind the set first, then round the front to its free end). Built once; the paths and their
 * measures are reused every frame.
 */
class TuneInGeometry {
    val markCenter = Offset(500f, 270f)
    val markSize = 330f
    val mark = Rect(markCenter.x - markSize / 2, markCenter.y - markSize / 2, markCenter.x + markSize / 2, markCenter.y + markSize / 2)
    val nameBaseline = 478f
    val taglineBaseline = 520f
    /** Canvas units to artboard units. */
    val k = markSize / CANVAS

    val canvas = Rect(0f, 0f, CANVAS, CANVAS)
    val antennaLeftPivot = Offset(454.5f, 222f)
    val antennaRightPivot = Offset(529.4f, 226f)
    val maxTwitchDeg = 6f
    val play = Offset(501.6f, 501.3f)
    val window = Rect(175f, 264f, 857f, 833f)
    val windowRound = RoundRect(window, CornerRadius(135f), CornerRadius(120f), CornerRadius(120f), CornerRadius(150f))
    val windowPath = Path().apply { addRoundRect(windowRound) }
    /** The right antenna's ball, where the one glint lands. */
    val glintArea = Rect(600f, 15f, 700f, 110f)
    /** The screen's window on the artboard (the match-cut opens from it). */
    val windowOnArtboard = Rect(mark.left + window.left * k, mark.top + window.top * k, mark.left + window.right * k, mark.top + window.bottom * k)

    val centreLine: List<Offset> = CENTRE_LINE.map { Offset(it[0], it[1]) }
    val rearPath = Path().apply { centreLine.take(REAR_POINTS).forEachIndexed { i, p -> if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) } }
    val frontPath = Path().apply { centreLine.drop(REAR_POINTS - 1).forEachIndexed { i, p -> if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) } }
    val rearMeasure = PathMeasure().apply { setPath(rearPath, false) }
    val frontMeasure = PathMeasure().apply { setPath(frontPath, false) }
    /** Wide enough to uncover the whole band where it is widest (with its soft edge). */
    val rearReveal = (WIDTHS.take(REAR_POINTS).max() * 1.6f)
    val frontReveal = (WIDTHS.drop(REAR_POINTS).max() * 1.5f)
    val trimmedRear = Path(); val trimmedFront = Path()

    companion object {
        const val CANVAS = 1024f
        const val REAR_POINTS = 10
        val CENTRE_LINE = arrayOf(
            floatArrayOf(884.9f, 334.1f), floatArrayOf(895.2f, 353.2f), floatArrayOf(903.8f, 373.0f), floatArrayOf(910.3f, 393.4f), floatArrayOf(915.5f, 414.4f), floatArrayOf(919.9f, 435.9f),
            floatArrayOf(924.1f, 458.1f), floatArrayOf(932.0f, 463.6f), floatArrayOf(943.1f, 461.8f), floatArrayOf(953.6f, 458.9f), floatArrayOf(954.0f, 511.4f), floatArrayOf(936.0f, 547.3f),
            floatArrayOf(908.2f, 578.2f), floatArrayOf(876.2f, 605.1f), floatArrayOf(840.8f, 627.3f), floatArrayOf(803.2f, 646.1f), floatArrayOf(764.9f, 663.2f), floatArrayOf(725.5f, 677.7f),
            floatArrayOf(685.6f, 690.5f), floatArrayOf(645.1f, 701.8f), floatArrayOf(604.5f, 712.5f), floatArrayOf(564.0f, 723.1f), floatArrayOf(522.8f, 731.4f), floatArrayOf(481.6f, 739.4f),
            floatArrayOf(440.5f, 747.8f), floatArrayOf(399.0f, 754.4f), floatArrayOf(357.6f, 761.0f), floatArrayOf(316.6f, 770.0f), floatArrayOf(275.7f, 779.4f), floatArrayOf(235.2f, 790.3f),
            floatArrayOf(195.1f, 802.7f), floatArrayOf(157.6f, 821.4f), floatArrayOf(122.0f, 843.3f), floatArrayOf(93.3f, 871.9f),
        )
        val WIDTHS = floatArrayOf(1.0f, 19.5f, 39.7f, 60.6f, 81.0f, 99.4f, 114.7f, 92.3f, 50.3f, 8.0f, 67.9f, 46.8f, 89.5f, 109.5f, 125.9f, 127.2f, 133.2f, 134.5f, 135.8f, 135.9f,
            132.9f, 131.7f, 132.2f, 130.3f, 130.1f, 131.1f, 127.9f, 127.1f, 124.4f, 123.3f, 111.2f, 107.8f, 103.5f, 85.4f).toList()
    }
}
