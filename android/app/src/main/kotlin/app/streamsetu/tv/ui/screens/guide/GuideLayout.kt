package app.streamsetu.tv.ui.screens.guide

/**
 * The maths of the guide's timeline, kept apart from the screen so it can be tested. The visible time window is a whole number of half hours that fits the room beside the channel
 * column, and the minutes are then stretched to fill that room exactly, so the grid always reaches the right margin whatever the screen.
 */
internal object GuideLayout {
    const val MIN_WINDOW_MIN = 90
    const val MAX_WINDOW_MIN = 300
    private const val STEP = 30

    /** The width left for the timeline: the screen, less the margins on both sides and the channel column. */
    fun trackWidthDp(screenDp: Float, startMarginDp: Float, endMarginDp: Float, labelDp: Float): Float =
        (screenDp - startMarginDp - endMarginDp - labelDp).coerceAtLeast(0f)

    /** How many minutes the window shows: as many whole half hours as fit at [preferredDpPerMin], at least [MIN_WINDOW_MIN] and at most [MAX_WINDOW_MIN]. */
    fun windowMinutes(trackDp: Float, preferredDpPerMin: Float): Int {
        if (trackDp <= 0f || preferredDpPerMin <= 0f) return MIN_WINDOW_MIN
        val fit = (trackDp / preferredDpPerMin / STEP).toInt() * STEP
        return fit.coerceIn(MIN_WINDOW_MIN, MAX_WINDOW_MIN)
    }

    /** The dp one minute takes, so that [windowMin] minutes are exactly [trackDp] wide. */
    fun dpPerMinute(trackDp: Float, windowMin: Int): Float = if (windowMin <= 0 || trackDp <= 0f) 0f else trackDp / windowMin

    /** A ruler label is left out when the current-time marker would sit on it. */
    fun rulerLabelVisible(labelXDp: Float, nowXDp: Float?, labelWidthDp: Float = 72f): Boolean =
        nowXDp == null || nowXDp < labelXDp - 6f || nowXDp > labelXDp + labelWidthDp
}
