package app.streamsetu.core.sync

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * What a read of a playlist is doing, for the "Connecting" card: a stage and how far it is. [total] is 0 while it is not known (a list that is still being read); [done] never goes down within a stage
 * and a stage that has a total ends with done == total.
 */
data class SyncProgress(val stage: Stage, val done: Int, val total: Int) {
    enum class Stage(val label: String) {
        SIGNING_IN("Signing in"), READING_CHANNELS("Reading channels"), READING_MOVIES("Reading movies"), READING_SERIES("Reading series"),
        SAVING_CHANNELS("Saving channels"), SAVING_MOVIES("Saving movies"), SAVING_SERIES("Saving series"), SAVING_PEOPLE("Saving cast and directors"),
    }

    /** 0..1 when the total is known, otherwise null (the bar then only moves). */
    val fraction: Float? get() = if (total > 0) (done.toFloat() / total).coerceIn(0f, 1f) else null

    /** "Saving movies 12,000 of 66,000", "Reading movies 24,000", or "Signing in…". */
    fun text(): String {
        val n = java.text.NumberFormat.getIntegerInstance(java.util.Locale.US)
        return when { total > 0 -> "${stage.label} ${n.format(done)} of ${n.format(total)}"; done > 0 -> "${stage.label} ${n.format(done)}"; else -> "${stage.label}…" }
    }
}

/** Carries the progress listener of one read down to the code that writes the catalog (a read of one playlist is one coroutine, several may run at once for different playlists). */
class ProgressSink(val report: (SyncProgress) -> Unit) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<ProgressSink>
}

/** One line per stage in logcat (tag StreamSetuSync): the stage, a row count and milliseconds. Nothing else: no addresses, names, titles or credentials. */
object SyncLog {
    const val TAG = "StreamSetuSync"
    fun stage(stage: String, rows: Int, ms: Long) { runCatching { android.util.Log.i(TAG, "stage=$stage rows=$rows ms=$ms") } }
}
