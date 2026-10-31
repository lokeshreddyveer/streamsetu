package app.streamsetu.tv.trace

import android.util.Log

/**
 * Switches for finding out which part of a screen costs frames, for test builds only: each one turns a single thing off so the same key sequence can be run with and without it.
 * Every switch is off unless the device was told `setprop log.tag.SSDIAG_<NAME> VERBOSE`, which is read once when the app starts (restart the app after changing one).
 * A release build never reads them. None of them is a feature or a setting: they exist to measure, and what they find is fixed in the screen itself.
 *
 *   SSDIAG_ARTWORK   channel logos and folder icons are not drawn (their space stays)
 *   SSDIAG_SCALE     a focused card does not grow
 *   SSDIAG_RING      the focus ring and the dark band behind it are not drawn
 *   SSDIAG_ONELINE   channel names are cut to one line
 *   SSDIAG_META      the "on now" line, the "+N" count and the favourite heart are not drawn
 *   SSDIAG_PREVIEW   the now/next and guide pane beside the Live TV channels is not built
 *   SSDIAG_MARQUEE   the focused folder name does not slide sideways
 *   SSDIAG_INDEXER   the cast indexer does not start
 */
object Diag {
    @Volatile var artwork = false; private set
    @Volatile var scale = false; private set
    @Volatile var ring = false; private set
    @Volatile var oneLine = false; private set
    @Volatile var meta = false; private set
    @Volatile var preview = false; private set
    @Volatile var marquee = false; private set
    @Volatile var indexer = false; private set

    fun refresh(debuggable: Boolean) {
        fun on(name: String) = debuggable && Log.isLoggable("SSDIAG_$name", Log.VERBOSE)
        artwork = on("ARTWORK"); scale = on("SCALE"); ring = on("RING"); oneLine = on("ONELINE"); meta = on("META"); preview = on("PREVIEW"); marquee = on("MARQUEE"); indexer = on("INDEXER")
        val active = listOfNotNull("ARTWORK".takeIf { artwork }, "SCALE".takeIf { scale }, "RING".takeIf { ring }, "ONELINE".takeIf { oneLine }, "META".takeIf { meta }, "PREVIEW".takeIf { preview }, "MARQUEE".takeIf { marquee }, "INDEXER".takeIf { indexer })
        if (active.isNotEmpty()) Log.i("Diag", "switched off for this run: ${active.joinToString()}")
    }
}
